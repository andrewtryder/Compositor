import CoreGraphics
import Foundation
import Testing
@testable import Compositor

struct CameraRawGeometrySafetyTests {
    private func solidImage(width: Int, height: Int, rgba: (UInt8, UInt8, UInt8, UInt8) = (180, 90, 40, 255)) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(red: CGFloat(rgba.0) / 255, green: CGFloat(rgba.1) / 255,
                             blue: CGFloat(rgba.2) / 255, alpha: CGFloat(rgba.3) / 255)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// 16-bit gradient with mid-channel values that 8-bit cannot represent exactly (odd 16-bit codes).
    private func sixteenBitGradient(width: Int, height: Int) throws -> CGImage {
        let context = try DeepLayer.context(width: width, height: height)
        guard let data = context.data else { throw ExportError.render }
        let row = context.bytesPerRow / 2
        let pixels = data.assumingMemoryBound(to: UInt16.self)
        for y in 0..<height {
            for x in 0..<width {
                let t = Double(x) / Double(max(width - 1, 1))
                // Odd codes in the open interval so dithering to 8-bit cannot be lossless.
                let value = UInt16(1 + Int(t * 65533)) | 1
                let i = y * row + x * 4
                pixels[i] = value
                pixels[i + 1] = value
                pixels[i + 2] = value
                pixels[i + 3] = 65_535
            }
        }
        return try #require(context.makeImage())
    }

    private func sample16(_ image: CGImage, x: Int, y: Int) throws -> (UInt16, UInt16, UInt16, UInt16) {
        let canonical = try DeepLayer.canonical(image)
        guard let data = canonical.data else { throw ExportError.render }
        let pixels = data.assumingMemoryBound(to: UInt16.self)
        let row = canonical.bytesPerRow / 2
        let i = y * row + x * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    @Test func expandUnsupportedOnDeepAsset() throws {
        let deep = try sixteenBitGradient(width: 32, height: 24)
        let asset = try DeepLayer.asset(deep, name: "deep")
        #expect(!CameraRawGeometrySettings.supportsExpandToFit(on: asset))
        #expect(asset.deep != nil)
    }

    @Test func deepExpandCommitKeepsSixteenBitPrecision() throws {
        let deep = try sixteenBitGradient(width: 40, height: 30)
        let before = try sample16(deep, x: 11, y: 7)
        #expect(before.0 % 2 == 1)
        var settings = CameraRawSettings()
        settings.geometry.upright = .off
        settings.geometry.vertical = 45
        settings.geometry.framingMode = .expandToFit
        // Simulate the coerced Keep Original Size path used for deep layers.
        settings.geometry.framingMode = .keepOriginalSize
        let half = try DeepLayer.dithered(deep)
        let result = try DeepLayer.run(deep, mixesChannels: true) { _ in
            try settings.apply(half)
        }
        #expect(result.width == deep.width)
        #expect(result.height == deep.height)
        #expect(result.bitsPerComponent == 16)
        // Geometry-warped pixels move; verify depth and that we did not collapse to an 8-bit asset path.
        let asset = try DeepLayer.asset(result, name: "out")
        #expect(asset.deep != nil)
        #expect(asset.deep?.bitsPerComponent == 16)
    }

    @Test func croppedExpansionTransformMatchesCoverageNotUnion() {
        // Simulate Expand then Constrain Crop: kept rect sits entirely inside the original bounds.
        let expansion = CameraRawGeometryExpansion(
            inputWidth: 100, inputHeight: 100,
            coverageInInput: CGRect(x: 20, y: 25, width: 50, height: 40))
        let base = LayerTransform(origin: CGPoint(x: 10, y: 15), size: CGSize(width: 200, height: 200), rotation: 12)
        let placed = expansion.layerTransform(from: base)
        #expect(abs(placed.size.width - 100) < 0.01) // 50/100 * 200
        #expect(abs(placed.size.height - 80) < 0.01)
        #expect(expansion.footprintMatches(image: {
            // Synthetic size check without rendering: build a tiny blank of the expected size.
            let ctx = try! BrushRaster.context(width: 50, height: 40, mask: false)
            return ctx.makeImage()!
        }(), base: base, placed: placed))
        // Union with original bounds would have produced 100×100 layer pixels → size 200×200 — must not.
        #expect(abs(placed.size.width - 200) > 1)
    }

    @Test func expandThenCropFootprintConsistent() throws {
        let image = try solidImage(width: 80, height: 60)
        var settings = CameraRawGeometrySettings()
        settings.upright = .off
        settings.rotate = 18
        settings.framingMode = .expandToFit
        settings.constrainCrop = true
        let result = try settings.applyResult(image)
        let expansion = try #require(result.expansion)
        #expect(expansion.outputWidth == result.image.width)
        #expect(expansion.outputHeight == result.image.height)
        let base = LayerTransform(origin: CGPoint(x: 5, y: 8), size: CGSize(width: 80, height: 60), flipX: true)
        let placed = expansion.layerTransform(from: base)
        #expect(expansion.footprintMatches(image: result.image, base: base, placed: placed))
        #expect(placed.flipX)
        #expect(abs(placed.rotation - 0) < 0.01 || placed.rotation == base.rotation)
    }

    @Test func horizonComposedBeforeExpandChangesFootprint() throws {
        let image = try solidImage(width: 100, height: 80)
        var geometry = CameraRawGeometrySettings()
        geometry.upright = .off
        geometry.vertical = 30
        geometry.framingMode = .expandToFit
        let without = try geometry.applyResult(image)
        let with = try geometry.applyResult(image, horizonDegrees: 12)
        #expect(with.image.width > 0)
        // Horizon rotates destination corners before framing; bounds generally differ from perspective-only.
        let same = without.image.width == with.image.width && without.image.height == with.image.height
            && without.expansion?.coverageInInput == with.expansion?.coverageInInput
        #expect(!same)
    }

    @Test func horizonDoesNotDoubleWithAutoLevelGuides() {
        var settings = CameraRawGeometryBackendSettings()
        settings.geometry.upright = .autoLevel
        settings.horizon.mode = .angle
        settings.horizon.angleDegrees = 10
        #expect(!CameraRawGeometryBackend.shouldApplyHorizon(settings))
        settings.horizon.mode = .automatic
        #expect(CameraRawGeometryBackend.shouldApplyHorizon(settings))
    }

    @Test func perspectiveToolVerticalGuidesWarpPixels() throws {
        // Vertical tapering grid → vertical guides straighten.
        let width = 64, height = 64
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(2)
        for x in [16, 32, 48] {
            context.move(to: CGPoint(x: x - 8, y: 4))
            context.addLine(to: CGPoint(x: x + 8, y: height - 4))
            context.strokePath()
        }
        let image = try #require(context.makeImage())
        var tools = CameraRawPerspectiveToolState()
        tools.kind = .verticalGuides
        tools.verticalGuides = [
            CameraRawGeometryGuide(startX: 0.2, startY: 0.05, endX: 0.35, endY: 0.95),
            CameraRawGeometryGuide(startX: 0.65, startY: 0.05, endX: 0.8, endY: 0.95)
        ]
        var settings = CameraRawSettings()
        settings.perspectiveTools = tools
        settings.geometry.framingMode = .keepOriginalSize
        let out = try settings.apply(image)
        #expect(out.width == width)
        #expect(out.height == height)
        // Output must differ from identity (guides produce a warp).
        let before = try BrushRaster.copy(image)
        let after = try BrushRaster.copy(out)
        #expect(before.data != after.data)
    }

    @Test func hvRatioMatchesAspectPolish() throws {
        let image = try solidImage(width: 50, height: 50)
        var a = CameraRawGeometrySettings()
        a.aspect = 40
        var b = CameraRawGeometrySettings()
        b.aspect = CameraRawPerspectiveTools.aspectFromHorizontalVerticalRatio(40)
        let ca = a.outputCorners(width: 50, height: 50)
        let cb = b.outputCorners(width: 50, height: 50)
        for (p, q) in zip(ca, cb) {
            #expect(hypot(p.x - q.x, p.y - q.y) < 1e-9)
        }
        _ = image
    }

    @Test func cropPlanOpaqueInscribed() throws {
        let context = try BrushRaster.context(width: 40, height: 30, mask: false)
        context.clear(CGRect(x: 0, y: 0, width: 40, height: 30))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 8, y: 6, width: 20, height: 16))
        let image = try #require(context.makeImage())
        var request = CameraRawGeometryCropRequest()
        request.automaticOpaqueCrop = true
        request.constrainToImage = true
        let crop = try #require(try CameraRawGeometryCrop.plan(request: request, image: image,
                                                               originalSize: CGSize(width: 40, height: 30)))
        #expect(crop.width >= 1 && crop.height >= 1)
        #expect(crop.maxX <= 40 && crop.maxY <= 30)
    }

    @Test func miniatureImpulseKeepsCenterSharp() throws {
        let width = 64, height = 64
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 30, y: 30, width: 4, height: 4))
        context.fill(CGRect(x: 4, y: 4, width: 3, height: 3))
        let image = try #require(context.makeImage())
        var settings = CameraRawMiniatureSettings()
        settings.strength = 0
        let identity = try CameraRawMiniature.apply(image, settings: settings)
        #expect(identity.width == width)
        settings.strength = 90
        settings.shape = .circular
        settings.focusSize = 0.15
        settings.centerX = 0.5
        settings.centerY = 0.5
        let blurred = try CameraRawMiniature.apply(image, settings: settings)
        func luma(_ img: CGImage, _ x: Int, _ y: Int) throws -> Int {
            let copy = try BrushRaster.copy(img)
            let px = copy.data!.assumingMemoryBound(to: UInt8.self)
            let i = y * copy.bytesPerRow + x * 4
            return Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])
        }
        // Corner impulse should be softened more than the center impulse.
        let centerBefore = try luma(image, 31, 31)
        let centerAfter = try luma(blurred, 31, 31)
        let cornerBefore = try luma(image, 5, 5)
        let cornerAfter = try luma(blurred, 5, 5)
        let centerDrop = abs(centerBefore - centerAfter)
        let cornerDrop = abs(cornerBefore - cornerAfter)
        #expect(cornerDrop >= centerDrop)
    }

    @Test func cameraRawApplyRunsHorizonAndMiniature() throws {
        let image = try solidImage(width: 48, height: 36)
        var settings = CameraRawSettings()
        settings.horizon.mode = .angle
        settings.horizon.angleDegrees = 6
        settings.miniature.strength = 50
        settings.miniature.shape = .linear
        settings.geometry.framingMode = .keepOriginalSize
        let out = try settings.apply(image)
        #expect(out.width == 48)
        #expect(out.height == 36)
    }

    @Test func markerPointSurvivesExpandPlacement() throws {
        // Bright marker at a known input pixel; Expand placement maps coverage mid consistently.
        let width = 60, height = 40
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(gray: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 28, y: 18, width: 4, height: 4))
        let image = try #require(context.makeImage())
        var settings = CameraRawGeometrySettings()
        settings.upright = .off
        settings.rotate = 10
        settings.framingMode = .expandToFit
        let result = try settings.applyResult(image)
        let expansion = try #require(result.expansion)
        let base = LayerTransform(origin: CGPoint(x: 100, y: 50), size: CGSize(width: width, height: height))
        let placed = expansion.layerTransform(from: base)
        #expect(expansion.footprintMatches(image: result.image, base: base, placed: placed))
        // Input marker (30, 20) → document via base; same point relative to coverage → placed.
        let toDoc = BrushRaster.pixelToDocument(base, width: width, height: height)
        let expected = CGPoint(x: 30, y: 20).applying(toDoc)
        let inExpanded = CGPoint(x: 30 - expansion.coverageInInput.minX, y: 20 - expansion.coverageInInput.minY)
        let got = inExpanded.applying(BrushRaster.pixelToDocument(placed, width: result.image.width, height: result.image.height))
        #expect(hypot(expected.x - got.x, expected.y - got.y) < 1.5)
    }
}
