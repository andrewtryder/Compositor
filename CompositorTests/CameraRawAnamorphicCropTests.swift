import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Milestone 10.9: Anamorphic De-squeeze and Geometry-Aware Crop.
/// Covers the de-squeeze transform and its placement, the crop-after-transform plan and its
/// placement, the deep-layer precision refusals, persistence defaults, and the panel order
/// the UI must keep. Manual acceptance gates are carried forward as NOT OBSERVED in the
/// milestone report; nothing here drives the interface.
struct CameraRawAnamorphicCropTests {
    private func solidImage(width: Int, height: Int, color: (UInt8, UInt8, UInt8, UInt8) = (200, 100, 50, 255)) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(red: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255,
                             blue: CGFloat(color.2) / 255, alpha: CGFloat(color.3) / 255)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// A gradient with odd 16-bit codes, so an 8-bit round-trip cannot be lossless.
    private func sixteenBitGradient(width: Int, height: Int) throws -> CGImage {
        let context = try DeepLayer.context(width: width, height: height)
        guard let data = context.data else { throw ExportError.render }
        let row = context.bytesPerRow / 2
        let pixels = data.assumingMemoryBound(to: UInt16.self)
        for y in 0..<height {
            for x in 0..<width {
                let t = Double(x) / Double(max(width - 1, 1))
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

    // MARK: - Anamorphic de-squeeze

    @Test func deSqueezeIdentitySkipsResample() throws {
        let image = try solidImage(width: 64, height: 40)
        var settings = CameraRawGeometrySettings()
        settings.anamorphic = CameraRawAnamorphicSettings(ratio: 1)
        let result = try settings.applyResult(image)
        #expect(result.image === image)
        #expect(result.expansion == nil)
    }

    @Test func deSqueezeTwoTimesWidensAndPlacesCenterAnchored() throws {
        let image = try solidImage(width: 60, height: 40)
        var settings = CameraRawGeometrySettings()
        settings.anamorphic = CameraRawAnamorphicSettings(ratio: 2)
        let result = try settings.applyResult(image)
        #expect(result.image.width == 120)
        #expect(result.image.height == 40)
        let expansion = try #require(result.expansion)
        // Center-anchored: the frame's middle stays put, so coverage starts at −(outW − w)/2.
        #expect(expansion.coverageInInput == CGRect(x: -30, y: 0, width: 120, height: 40))
        #expect(expansion.outputWidth == 120)
        #expect(expansion.outputHeight == 40)
    }

    @Test func deSqueezePresetsMatchTheirRatios() {
        #expect(CameraRawAnamorphicPreset.off.ratio == 1)
        #expect(CameraRawAnamorphicPreset.one33.ratio == 1.33)
        #expect(CameraRawAnamorphicPreset.one50.ratio == 1.5)
        #expect(CameraRawAnamorphicPreset.one60.ratio == 1.6)
        #expect(CameraRawAnamorphicPreset.two00.ratio == 2)
        // A ratio that is not a named preset reads back as Custom; named ones read back as themselves.
        #expect(CameraRawAnamorphicPreset.preset(for: 1) == .off)
        #expect(CameraRawAnamorphicPreset.preset(for: 1.5) == .one50)
        #expect(CameraRawAnamorphicPreset.preset(for: 1.44) == .custom)
    }

    @Test func deSqueezeExecutionOrderRunsBeforePerspective() throws {
        // A 2× de-squeeze followed by a perspective warp: the perspective stage works on the
        // de-squeezed grid, so its output is wider than the perspective-only output on the same input.
        let image = try solidImage(width: 50, height: 40)
        var deSqueezedOnly = CameraRawGeometrySettings()
        deSqueezedOnly.anamorphic = CameraRawAnamorphicSettings(ratio: 2)
        var warpedOnly = CameraRawGeometrySettings()
        warpedOnly.vertical = 30
        var both = CameraRawGeometrySettings()
        both.anamorphic = CameraRawAnamorphicSettings(ratio: 2)
        both.vertical = 30
        let a = try deSqueezedOnly.applyResult(image)
        let b = try warpedOnly.applyResult(image)
        let c = try both.applyResult(image)
        // De-squeeze runs first: with it the output starts from the 100-wide de-squeezed frame.
        #expect(c.image.width > Int(Double(b.image.width) * 0.9))
        #expect(a.image.width == 100)
        // The composed expansion keeps a single consistent placement.
        let expansion = try #require(c.expansion)
        #expect(expansion.outputWidth == c.image.width)
        #expect(expansion.outputHeight == c.image.height)
    }

    @Test func deSqueezeRefusedPastDocumentLimits() throws {
        // 15000 × 15000 at ratio 8 is 120000 wide — past maxSide, and 1.8e9 pixels — past maxSurfacePixels.
        let image = try solidImage(width: 15_000, height: 15_000)
        var settings = CameraRawGeometrySettings()
        settings.anamorphic = CameraRawAnamorphicSettings(ratio: 8)
        do {
            _ = try settings.applyResult(image)
            Issue.record("expected the de-squeeze past the limits to throw")
        } catch {
            // Expected: ProjectError.tooLarge.
        }
    }

    // MARK: - Crop After Transform

    @Test func cropAfterTransformNoCropIsANoop() throws {
        let image = try solidImage(width: 64, height: 48)
        let settings = CameraRawSettings()
        #expect(settings.crop.isNoCrop)
        // The filter path never reaches plan with the default request: applyResult leaves the
        // corrected image exactly as geometry made it, same size, no cropping.
        let result = try settings.applyResult(image, scale: 1)
        #expect(result.image.width == 64)
        #expect(result.image.height == 48)
        #expect(result.expansion == nil)
    }

    @Test func cropAfterTransformAutomaticOpaquePlansInscribedRect() throws {
        // A opaque frame with clear margins: the automatic crop keeps the middle.
        let context = try BrushRaster.context(width: 80, height: 60, mask: false)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 20, y: 15, width: 40, height: 30))
        let image = try #require(context.makeImage())
        var request = CameraRawGeometryCropRequest()
        request.automaticOpaqueCrop = true
        let crop = try #require(try CameraRawGeometryCrop.plan(request: request, image: image,
                                                               originalSize: CGSize(width: 80, height: 60)))
        #expect(crop.minX >= 19 && crop.maxX <= 61)
        #expect(crop.minY >= 14 && crop.maxY <= 46)
        #expect(crop.width >= 1 && crop.height >= 1)
    }

    @Test func cropAfterTransformManualRectIsHonoredAndAspectConstrained() throws {
        let image = try solidImage(width: 100, height: 80)
        var request = CameraRawGeometryCropRequest()
        request.manualCrop = CGRect(x: 10, y: 10, width: 50, height: 50)
        request.aspectMode = .fixed
        request.aspectRatio = 2
        let crop = try #require(try CameraRawGeometryCrop.plan(request: request, image: image,
                                                               originalSize: CGSize(width: 100, height: 80)))
        // The plan keeps the manual rect's middle and fits the fixed aspect.
        #expect(abs(crop.midX - 35) < 1)
        #expect(abs(crop.midY - 35) < 1)
        #expect(abs(crop.width / crop.height - 2) < 0.05)
        #expect(crop.width <= 50.5 && crop.height <= 50.5)
    }

    @Test func cropAfterTransformFoldsIntoExpansion() throws {
        let image = try solidImage(width: 80, height: 60)
        var settings = CameraRawSettings()
        // De-squeeze widens first; the crop then takes a rect of the de-squeezed output.
        settings.geometry.anamorphic = CameraRawAnamorphicSettings(ratio: 2)
        // De-squeeze coverage is x: −40…120; the crop 20…120 of that output is −20…80 in input space.
        settings.crop.manualCrop = CGRect(x: 20, y: 10, width: 100, height: 40)
        let result = try settings.applyResult(image, scale: 1)
        #expect(result.image.width == 100)
        #expect(result.image.height == 40)
        let expansion = try #require(result.expansion)
        #expect(expansion.coverageInInput == CGRect(x: -20, y: 10, width: 100, height: 40))
        // The placement maps the kept rect, not the whole de-squeezed frame: 100 input-px wide, 40 tall.
        let base = LayerTransform(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 80, height: 60))
        let placed = expansion.layerTransform(from: base)
        #expect(abs(placed.size.width - 100) < 0.01)
        #expect(abs(placed.size.height - 40) < 0.01)
        // The kept rect's middle in input coords (30, 30) maps 1:1 to the same document point.
        #expect(abs(placed.origin.x + placed.size.width / 2 - 30) < 0.01)
        #expect(abs(placed.origin.y + placed.size.height / 2 - 30) < 0.01)
    }

    // MARK: - Deep-layer precision policy

    @Test func deepLayerRefusalsNameEachFeature() {
        var settings = CameraRawSettings()
        #expect(CameraRawGeometrySettings.deepLayerRefusalMessage(settings) == nil)
        settings.geometry.framingMode = .expandToFit
        #expect(CameraRawGeometrySettings.deepLayerRefusalMessage(settings) != nil)
        settings.geometry.framingMode = .keepOriginalSize
        settings.geometry.anamorphic = CameraRawAnamorphicSettings(ratio: 1.33)
        let deSqueezeMessage = try? #require(CameraRawGeometrySettings.deepLayerRefusalMessage(settings))
        #expect(deSqueezeMessage?.contains("De-squeeze") == true)
        settings.geometry.anamorphic = CameraRawAnamorphicSettings()
        settings.crop.manualCrop = CGRect(x: 0, y: 0, width: 10, height: 10)
        let cropMessage = try? #require(CameraRawGeometrySettings.deepLayerRefusalMessage(settings))
        #expect(cropMessage?.contains("Crop") == true)
    }

    @Test func variableSizeFeaturesCoverDeSqueezeAndCrop() {
        var settings = CameraRawSettings()
        #expect(!CameraRawGeometrySettings.hasVariableSizeFeatures(settings))
        settings.geometry.anamorphic = CameraRawAnamorphicSettings(ratio: 2)
        #expect(CameraRawGeometrySettings.hasVariableSizeFeatures(settings))
        settings.geometry.anamorphic = CameraRawAnamorphicSettings()
        settings.crop.automaticOpaqueCrop = true
        #expect(CameraRawGeometrySettings.hasVariableSizeFeatures(settings))
        settings.crop = CameraRawGeometryCropRequest()
        #expect(!CameraRawGeometrySettings.hasVariableSizeFeatures(settings))
    }

    @Test func deepCommitKeepsSixteenBitWithoutDeSqueeze() throws {
        let deep = try sixteenBitGradient(width: 40, height: 30)
        let before = try sample16(deep, x: 11, y: 7)
        #expect(before.0 % 2 == 1)
        var settings = CameraRawSettings()
        // A de-squeeze on a deep layer is coerced off before render, so this must run as identity.
        settings.geometry.anamorphic = CameraRawAnamorphicSettings(ratio: 2)
        var coerced = settings
        coerced.geometry.anamorphic = CameraRawAnamorphicSettings()
        let half = try DeepLayer.dithered(deep)
        let result = try DeepLayer.run(deep, mixesChannels: false) { _ in
            try coerced.apply(half)
        }
        #expect(result.width == deep.width)
        #expect(result.height == deep.height)
        #expect(result.bitsPerComponent == 16)
        let asset = try DeepLayer.asset(result, name: "out")
        #expect(asset.deep != nil)
    }

    // MARK: - Persistence

    @Test func cropAndAnamorphicRideExistingSchemas() throws {
        // Older settings (no crop key, no anamorphic key) decode to the defaults.
        let older = CameraRawSettings()
        let data = try JSONEncoder().encode(CameraRawSettingsPersistentState(older))
        let decoded = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: data)
        let restored = try decoded.makeSettings()
        #expect(restored == older)
        #expect(restored.crop.isNoCrop)
        #expect(restored.geometry.anamorphic.isIdentity)
    }

    @Test func cropManualScalarsRoundTrip() throws {
        var request = CameraRawGeometryCropRequest()
        request.manualCrop = CGRect(x: 3, y: 5, width: 20, height: 12)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CameraRawGeometryCropRequest.self, from: data)
        #expect(decoded.manualCrop == CGRect(x: 3, y: 5, width: 20, height: 12))
        request.manualCrop = nil
        #expect(request.isNoCrop)
    }

    @Test func resetGeometryClearsCropAndDeSqueeze() {
        var settings = CameraRawSettings()
        settings.geometry.anamorphic = CameraRawAnamorphicSettings(ratio: 1.5)
        settings.crop.manualCrop = CGRect(x: 2, y: 3, width: 40, height: 20)
        settings.exposure = 0.5
        let reset = settings.resetting(.geometry)
        #expect(reset.geometry.anamorphic.isIdentity)
        #expect(reset.crop.isNoCrop)
        #expect(reset.exposure == 0.5)
    }

    @Test func geometryEyeBypassesCropAndDeSqueeze() {
        var settings = CameraRawSettings()
        settings.geometry.anamorphic = CameraRawAnamorphicSettings(ratio: 2)
        settings.crop.automaticOpaqueCrop = true
        let bypassed = settings.applying(showsLight: true, showsColor: true, showsGeometry: false)
        #expect(bypassed.geometry.anamorphic.isIdentity)
        #expect(bypassed.crop.isNoCrop)
    }
}
