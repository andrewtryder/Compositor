import AppKit
import CoreImage
import Foundation
import Testing
@testable import Compositor

/// Milestone 11.0: Optics › Lens Blur's Depth Focus mode.
///
/// Focus Region is the pre-M11.0 behavior and must stay bit-exact at Amount 0 and unchanged in what it renders.
/// Depth Focus reads `DepthMap` estimates — relative depth, 1 nearest — and is tested with synthetic estimates so
/// no model download is needed: the renderer takes the map it is given.
@MainActor
struct CameraRawDepthBlurTests {
    // MARK: - Helpers

    /// Three vertical bands, each with a sharp impulse in its middle, so a band can be told sharp from blurred.
    private func bandedImage(width: Int = 120, height: Int = 60) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        for band in 0..<3 {
            context.fill(CGRect(x: band * width / 3 + 12, y: height / 2 - 3, width: 6, height: 6))
        }
        return try #require(context.makeImage())
    }

    /// A depth estimate with one value per band: `far`, `near`, `middle` left to right.
    private func bandedDepth(width: Int = 120, height: Int = 60, far: Float = 0.10,
                             middle: Float = 0.50, near: Float = 0.90) -> DepthMap {
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let third = x * 3 / width
                values[y * width + x] = third == 0 ? far : third == 1 ? middle : near
            }
        }
        return DepthMap(values: values, width: width, height: height)
    }

    /// A depth estimate that changes smoothly from far at the top to near at the bottom.
    private func rampedDepth(width: Int = 80, height: Int = 80) -> DepthMap {
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { values[y * width + x] = Float(y) / Float(max(1, height - 1)) }
        }
        return DepthMap(values: values, width: width, height: height)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.copy(image)
        let pointer = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: context.bytesPerRow * image.height))
    }

    private func luma(_ image: CGImage, _ x: Int, _ y: Int) throws -> Double {
        let copy = try BrushRaster.copy(image)
        let bytes = try #require(copy.data).assumingMemoryBound(to: UInt8.self)
        let i = y * copy.bytesPerRow + x * 4
        return (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3
    }

    /// How much an impulse at `x` lost: 0 means it is exactly as sharp as it was.
    private func drop(_ source: CGImage, _ result: CGImage, x: Int, y: Int = 30) throws -> Double {
        try abs(luma(source, x, y) - luma(result, x, y))
    }

    private func session(size: CGSize = CGSize(width: 240, height: 160)) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: Int(size.width), height: Int(size.height), mask: false)
        context.setFillColor(CGColor(srgbRed: 0.35, green: 0.45, blue: 0.55, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        session.beginFilter(.cameraRaw)
        return session
    }

    // MARK: - Focus Region is unchanged

    @Test func focusRegionIsTheDefaultAndAmountZeroIsBitExact() throws {
        let image = try bandedImage()
        #expect(CameraRawLensBlurSettings().focusMode == .focusRegion)
        #expect(CameraRawLensBlurSettings().isIdentity)
        // A depth map supplied to a Focus Region blur changes nothing: that mode never reads it.
        var settings = CameraRawLensBlurSettings()
        settings.amount = 60
        let withoutDepth = try CameraRawLensBlur.apply(image, settings: settings)
        let withDepth = try CameraRawLensBlur.apply(image, settings: settings, depth: bandedDepth())
        #expect(try pixels(withoutDepth) == pixels(withDepth), "Focus Region ignores the depth map")
    }

    @Test func defaultSettingsRenderTheSamePixelsAsBeforeDepthFocus() throws {
        // The whole Camera Raw pipeline with a graded picture and no Lens Blur: identity, exactly as before M11.0.
        let image = try bandedImage()
        var settings = CameraRawSettings()
        settings.exposure = 0.3
        settings.contrast = 12
        settings.optics.lensBlur.amount = 0
        let source = try pixels(image)
        let identity = try CameraRawSettings().applyResult(image).image
        #expect(try pixels(identity) == source, "identity Camera Raw is the exact input")
        let graded = try settings.applyResult(image, lensBlurDepth: bandedDepth()).image
        let gradedNoDepth = try settings.applyResult(image).image
        #expect(try pixels(graded) == pixels(gradedNoDepth), "a depth map alone changes nothing")
    }

    // MARK: - Depth Focus

    @Test func depthFocusBlursByDepthAndKeepsTheFocalBandSharp() throws {
        let image = try bandedImage()
        var settings = CameraRawLensBlurSettings()
        settings.amount = 90
        settings.focusMode = .depthFocus
        settings.depthFocalDistance = 10   // the far band
        settings.depthRange = 10
        settings.falloff = 20
        let out = try CameraRawLensBlur.apply(image, settings: settings, depth: bandedDepth())

        let farDrop = try drop(image, out, x: 15)
        let middleDrop = try drop(image, out, x: 55)
        let nearDrop = try drop(image, out, x: 95)
        #expect(farDrop < 12, "the focal band's impulse stays sharp (drop \(farDrop))")
        #expect(middleDrop > farDrop + 10, "the middle band blurs (drop \(middleDrop))")
        #expect(nearDrop > farDrop + 10, "the near band blurs (drop \(nearDrop))")
    }

    @Test func focalDistanceChoosesWhichBandStaysSharp() throws {
        let image = try bandedImage()
        var far = CameraRawLensBlurSettings()
        far.amount = 90
        far.focusMode = .depthFocus
        far.depthFocalDistance = 10
        far.depthRange = 8
        var near = far
        near.depthFocalDistance = 90
        let farOut = try CameraRawLensBlur.apply(image, settings: far, depth: bandedDepth())
        let nearOut = try CameraRawLensBlur.apply(image, settings: near, depth: bandedDepth())
        let farFar = try drop(image, farOut, x: 15)
        let nearFar = try drop(image, nearOut, x: 15)
        let farNear = try drop(image, farOut, x: 95)
        let nearNear = try drop(image, nearOut, x: 95)
        #expect(farFar < nearFar, "focusing far keeps the far band")
        #expect(nearNear < farNear, "focusing near keeps the near band")
        let farPixels = try pixels(farOut)
        let nearPixels = try pixels(nearOut)
        #expect(farPixels != nearPixels, "the two focal distances render differently")
    }

    @Test func aWiderDepthRangeKeepsMoreOfTheSceneSharp() throws {
        let image = try bandedImage()
        var narrow = CameraRawLensBlurSettings()
        narrow.amount = 90
        narrow.focusMode = .depthFocus
        narrow.depthFocalDistance = 50
        narrow.depthRange = 5
        narrow.falloff = 10
        var wide = narrow
        wide.depthRange = 100
        let narrowOut = try CameraRawLensBlur.apply(image, settings: narrow, depth: bandedDepth())
        let wideOut = try CameraRawLensBlur.apply(image, settings: wide, depth: bandedDepth())
        let narrowFar = try drop(image, narrowOut, x: 15)
        let wideFar = try drop(image, wideOut, x: 15)
        #expect(wideFar < narrowFar, "a wider range shields the far band (drop \(wideFar) against \(narrowFar))")
        #expect(try drop(image, wideOut, x: 55) < 12, "the band around the focal distance stays sharp")
    }

    @Test func aRampDepthBlursGentlyFromFarToNear() throws {
        // A smooth estimate: the blur must not step at a band edge, and the near and far halves must differ, which
        // is what depth-dependent blur means.
        let width = 80, height = 80
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        for row in stride(from: 4, to: height, by: 8) {
            context.fill(CGRect(x: 8, y: row, width: 4, height: 3))
            context.fill(CGRect(x: 68, y: row, width: 4, height: 3))
        }
        let image = try #require(context.makeImage())
        var settings = CameraRawLensBlurSettings()
        settings.amount = 85
        settings.focusMode = .depthFocus
        settings.depthFocalDistance = 50
        settings.depthRange = 10
        let out = try CameraRawLensBlur.apply(image, settings: settings, scale: 1, depth: rampedDepth())
        #expect(out.width == width && out.height == height, "the frame keeps its size")
        #expect(try pixels(out) != pixels(image), "a depth blur changes the picture")
        // The middle rows are the focal depth; the top is far and blurs more.
        let middleDrop = try drop(image, out, x: 9, y: 40)
        let topDrop = try drop(image, out, x: 9, y: 6)
        #expect(topDrop > middleDrop, "far rows blur more than the focal band (top \(topDrop), middle \(middleDrop))")
    }

    @Test func withoutAnEstimateDepthFocusLeavesThePictureAloneRatherThanFakingARadialBlur() throws {
        let image = try bandedImage()
        var settings = CameraRawLensBlurSettings()
        settings.amount = 90
        settings.focusMode = .depthFocus
        // No depth passed, and the model is not necessarily loaded in a test host.
        let out = try CameraRawLensBlur.apply(image, settings: settings, depth: nil)
        if DepthModel.isReady {
            #expect(try pixels(out) != pixels(image), "with the model loaded, Depth Focus renders")
        } else {
            #expect(try pixels(out) == pixels(image), "without an estimate the input is returned unchanged")
        }
        #expect(out.width == image.width && out.height == image.height)
    }

    @Test func needsDepthOnlyWhileDepthFocusHasAnAmount() {
        var settings = CameraRawLensBlurSettings()
        #expect(!settings.needsDepth, "Focus Region never needs an estimate")
        settings.focusMode = .depthFocus
        #expect(!settings.needsDepth, "Depth Focus at Amount 0 renders nothing")
        settings.amount = 40
        #expect(settings.needsDepth)
        settings.amount = 0
        #expect(!settings.needsDepth)
    }

    @Test func depthSettingsNormalizeIntoTheirRanges() {
        var settings = CameraRawLensBlurSettings()
        settings.depthFocalDistance = 500
        settings.depthRange = -40
        settings.amount = 300
        let safe = settings.normalized
        #expect(safe.depthFocalDistance == 100)
        #expect(safe.depthRange == 0)
        #expect(safe.amount == 100)
        settings.depthFocalDistance = .nan
        settings.depthRange = .infinity
        let fallback = settings.normalized
        #expect(fallback.depthFocalDistance == 50)
        #expect(fallback.depthRange == 25)
        #expect(fallback.normalized == fallback, "normalization is idempotent")
        #expect(fallback.focalDepth == 0.5)
        #expect(fallback.halfDepthRange == 0.125)
    }

    // MARK: - Depth map plumbing

    @Test func depthMapSamplesAtNormalizedPoints() {
        let map = bandedDepth()
        #expect(abs(Double(map.value(atNormalizedX: 0.05, y: 0.5)) - 0.10) < 0.02)
        #expect(abs(Double(map.value(atNormalizedX: 0.5, y: 0.5)) - 0.50) < 0.02)
        #expect(abs(Double(map.value(atNormalizedX: 0.95, y: 0.5)) - 0.90) < 0.02)
        #expect(map.value(atNormalizedX: -0.1, y: 0.5).isNaN, "outside the map there is no estimate")
        #expect(map.value(atNormalizedX: 0.5, y: 1.4).isNaN)
    }

    @Test func clickToFocusReadsThePointAndGivesItsFocalDistance() throws {
        let image = try bandedImage()
        let map = bandedDepth()
        let far = try #require(CameraRawLensBlur.focalDistance(forDepthAtX: 0.05, y: 0.5, in: image, depth: map))
        let near = try #require(CameraRawLensBlur.focalDistance(forDepthAtX: 0.95, y: 0.5, in: image, depth: map))
        #expect(abs(far - 10) < 2, "a far point reads near zero on the 0–100 scale (got \(far))")
        #expect(abs(near - 90) < 2, "a near point reads near 100 (got \(near))")
    }

    @Test func depthVisualizationShowsTheEstimateAndIsNotABlur() throws {
        let image = try bandedImage()
        var settings = CameraRawLensBlurSettings()
        settings.amount = 0
        settings.focusMode = .depthFocus
        let shown = try CameraRawLensBlur.apply(image, settings: settings, depth: bandedDepth(), visualizeDepth: true)
        #expect(shown.width == image.width && shown.height == image.height)
        // The far band is dark, the near band light: the map, not the picture.
        let far = try luma(shown, 24, 30)
        let near = try luma(shown, 96, 30)
        #expect(far < near, "the estimate is shown far-to-near, not the photograph (far \(far), near \(near))")
        #expect(try luma(shown, 24, 30) < 60, "the far band reads dark")
        #expect(try luma(shown, 96, 30) > 190, "the near band reads light")
    }

    @Test func thePipelineShowsTheDepthMapOnlyWhenAsked() throws {
        let image = try bandedImage()
        var settings = CameraRawSettings()
        settings.optics.lensBlur.amount = 70
        settings.optics.lensBlur.focusMode = .depthFocus
        settings.optics.lensBlur.depthFocalDistance = 50
        let shown = try settings.applyResult(image, lensBlurDepth: bandedDepth(), visualizesLensBlurDepth: true).image
        let blurred = try settings.applyResult(image, lensBlurDepth: bandedDepth()).image
        #expect(try pixels(shown) != pixels(blurred), "the visualization is not the grade")
        #expect(try luma(shown, 24, 30) < 60, "the visualization is the estimate")
    }

    // MARK: - Composition with the rest of the pipeline

    @Test func depthBlurRunsBeforeGeometrySoItFollowsTheCapturedFrame() throws {
        // The estimate is the captured frame's. A warp moves the blurred picture with it, rather than the mask
        // staying behind on the corrected grid.
        let image = try bandedImage(width: 80, height: 60)
        var settings = CameraRawSettings()
        settings.geometry.upright = .off
        settings.geometry.vertical = 20
        settings.geometry.framingMode = .keepOriginalSize
        settings.optics.lensBlur.amount = 70
        settings.optics.lensBlur.focusMode = .depthFocus
        let depthOnly = CameraRawSettings()
        let warped = try settings.applyResult(image, lensBlurDepth: bandedDepth(width: 80, height: 60)).image
        let plain = try depthOnly.applyResult(image).image
        #expect(warped.width == plain.width && warped.height == plain.height)
        #expect(try pixels(warped) != pixels(plain), "the blur and the warp both reach the pixels")
    }

    @Test func alphaAndBoundariesAreWellFormed() throws {
        let width = 64, height = 48
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 24, y: 16, width: 16, height: 16))
        let image = try #require(context.makeImage())
        var settings = CameraRawLensBlurSettings()
        settings.amount = 80
        settings.focusMode = .depthFocus
        let out = try CameraRawLensBlur.apply(image, settings: settings, depth: rampedDepth(width: width, height: height))
        #expect(out.width == width && out.height == height)
        // The clear corner stays clear: a blur spreads colors, never makes transparent pixels opaque.
        let copy = try BrushRaster.copy(out)
        let bytes = try #require(copy.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[3] == 0, "outside the subject stays clear")
    }

    @Test func miniatureAndDepthBlurRemainSeparateStages() throws {
        let image = try bandedImage()
        var miniature = CameraRawSettings()
        miniature.miniature.strength = 80
        var lens = CameraRawSettings()
        lens.optics.lensBlur.amount = 80
        lens.optics.lensBlur.focusMode = .depthFocus
        let a = try pixels(miniature.apply(image))
        let b = try pixels(lens.applyResult(image, lensBlurDepth: bandedDepth()).image)
        var both = miniature
        both.optics.lensBlur = lens.optics.lensBlur
        let c = try pixels(both.applyResult(image, lensBlurDepth: bandedDepth()).image)
        #expect(a != b && c != a && c != b, "both engines run when both are set")
    }

    // MARK: - The session and its persistence

    @Test func thePanelArmsASingleDepthPickAndEndsItOnAClick() throws {
        let session = try session()
        let edit = try #require(session.filterEdit)
        var settings = edit.settings
        settings.cameraRaw.optics.lensBlur.amount = 70
        settings.cameraRaw.optics.lensBlur.focusMode = .depthFocus
        session.updateFilter(settings, preview: true)

        // Without a model or an estimate, arming is refused: no control that cannot work.
        edit.invalidateLensBlurDepth()
        session.selectCameraRawLensBlurDepthFocus()
        if DepthModel.isReady {
            #expect(edit.picksCameraRawLensBlurDepth)
            edit.picksCameraRawLensBlurDepth = false
        } else {
            #expect(!edit.picksCameraRawLensBlurDepth, "no estimate, no pick")
        }

        // A pick on a picture with no estimate leaves the settings as they were.
        let before = edit.settings
        edit.picksCameraRawLensBlurDepth = true
        session.sampleCameraRawLensBlurDepth(at: CGPoint(x: 100, y: 80))
        #expect(!edit.picksCameraRawLensBlurDepth, "the pick is one-shot")
        if !DepthModel.isReady {
            #expect(edit.settings.cameraRaw.optics.lensBlur.depthFocalDistance == before.cameraRaw.optics.lensBlur.depthFocalDistance)
        }
        session.cancelFilter()
    }

    @Test func resettingOpticsClearsDepthFocusWithTheRestOfTheGroup() throws {
        var settings = CameraRawSettings()
        settings.optics.lensBlur.amount = 60
        settings.optics.lensBlur.focusMode = .depthFocus
        settings.optics.lensBlur.depthFocalDistance = 20
        settings.optics.lensBlur.depthRange = 40
        #expect(settings.adjustsOptics)
        let reset = settings.resetting(.optics)
        #expect(reset.optics.lensBlur == CameraRawLensBlurSettings())
        #expect(reset.optics.lensBlur.focusMode == .focusRegion)
    }

    @Test func theOpticsEyeBypassesDepthFocus() throws {
        var settings = CameraRawSettings()
        settings.optics.lensBlur.amount = 60
        settings.optics.lensBlur.focusMode = .depthFocus
        let shown = settings.applying(showsLight: true, showsColor: true, showsOptics: false)
        #expect(shown.optics.lensBlur.isIdentity)
        #expect(!shown.optics.lensBlur.needsDepth)
    }

    @Test func depthFocusSettingsSurviveThePersistenceRoundTrip() throws {
        var settings = CameraRawSettings()
        settings.optics.lensBlur.amount = 72
        settings.optics.lensBlur.focusMode = .depthFocus
        settings.optics.lensBlur.depthFocalDistance = 18
        settings.optics.lensBlur.depthRange = 44
        settings.optics.lensBlur.falloff = 55
        settings.optics.lensBlur.aperture = .hexagon

        let state = CameraRawSettingsPersistentState(settings)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: data)
        let restored = try decoded.makeSettings()
        #expect(restored.optics.lensBlur == settings.optics.lensBlur.normalized)
        #expect(restored.optics.lensBlur.focusMode == .depthFocus)
    }

    @Test func olderLensBlurWithoutDepthKeysDecodesToFocusRegion() throws {
        // A project saved before M11.0 has the seven original keys and nothing else.
        let json = """
        {"amount": 55, "aperture": "Round", "focusX": 0.4, "focusY": 0.6, "focusRange": 30,
         "falloff": 45, "highlights": 60}
        """
        let lensBlur = try JSONDecoder().decode(CameraRawSettingsPersistentState.Optics.LensBlur.self,
                                                from: Data(json.utf8))
        #expect(lensBlur.amount == 55)
        #expect(lensBlur.focusMode == CameraRawLensBlurFocusMode.focusRegion.rawValue,
                "an older project keeps the mode it was saved with")
        #expect(lensBlur.depthFocalDistance == 50)
        #expect(lensBlur.depthRange == 25)
    }

    @Test func aCorruptFocusModeDecodesToFocusRegion() throws {
        var state = CameraRawSettingsPersistentState(CameraRawSettings())
        state.optics.lensBlur.focusMode = "moonlight"
        let restored = try state.makeSettings()
        #expect(restored.optics.lensBlur.focusMode == .focusRegion)
    }

    @Test func depthFocusSurvivesAFullCameraRawCorrectionStackNode() throws {
        let image = try bandedImage(width: 60, height: 40)
        var settings = CameraRawSettings()
        settings.optics.lensBlur.amount = 65
        settings.optics.lensBlur.focusMode = .depthFocus
        settings.optics.lensBlur.depthFocalDistance = 30
        let node = LayerCorrectionNode.cameraRawFull(settings)
        var stack = LayerCorrectionStack(source: ImportedImage(image: image, thumbnail: image, name: "Photo"), nodes: [node])
        let rendered = try LayerCorrectionRenderer.render(&stack)
        #expect(rendered.image.width == 60 && rendered.image.height == 40)
        // The node's settings ride the stack's persistence unchanged.
        let state = try LayerCorrectionStackPersistentState(stack: stack)
        let data = try state.encodedJSON()
        let decoded = try LayerCorrectionStackPersistentState.decode(from: data)
        let restored = try decoded.makeStack(source: ImportedImage(image: image, thumbnail: image, name: "Photo"))
        #expect(restored.nodes.first?.cameraRawFull.optics.lensBlur == settings.optics.lensBlur.normalized)
    }
}
