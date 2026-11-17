import AppKit
import Foundation
import Testing
@testable import Compositor

/// Milestone 10: the additive Camera Raw features. Each test proves a new control changes pixels, that its default
/// leaves them exactly alone, that it persists, and that the section it lives in still resets as before.
struct CameraRawParityTests {
    // MARK: - Helpers

    private func gradient(width: Int = 64, height: Int = 48) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                data[i] = UInt8((x * 255) / max(width - 1, 1))
                data[i + 1] = UInt8((y * 255) / max(height - 1, 1))
                data[i + 2] = 128
                data[i + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    /// A dim picture with a bright spot: the case Auto exists for.
    private func dimScene(width: Int = 96, height: Int = 64) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.22, green: 0.24, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.92, green: 0.9, blue: 0.85, alpha: 1))
        context.fillEllipse(in: CGRect(x: width - 26, y: 10, width: 16, height: 16))
        return try #require(context.makeImage())
    }

    /// A flat mid gray with a small white square: something for a blur to move.
    private func checkers(width: Int = 64, height: Int = 64) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 2, y: 2, width: 8, height: 8))
        return try #require(context.makeImage())
    }

    private func rgba8(_ image: CGImage) throws -> [UInt8] {
        try MeshWarpRaster.rgba8Bytes(from: image)
    }

    private func maxDelta(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    // MARK: - 10.1 Light › Auto

    @Test func autoToneLiftsAnUnderexposedPicture() throws {
        let image = try dimScene()
        let histogram = try #require(CameraRawSettings.luminanceHistogram(of: image))
        #expect(histogram.count == 256)
        #expect(histogram.reduce(0, +) > 0)
        let tone = try #require(CameraRawSettings.autoTone(luminance: histogram))
        #expect(tone.exposure > 0, "a dim picture is brightened: \(tone)")
        #expect(!tone.isIdentity)
        #expect(CameraRawSettings.exposureRange.contains(tone.exposure))
        for value in [tone.contrast, tone.highlights, tone.shadows, tone.whites, tone.blacks] {
            #expect(CameraRawSettings.toneRange.contains(value), "Auto stays inside the slider ranges: \(tone)")
        }
    }

    @Test func autoToneLeavesAWidelySpreadPictureNearlyAlone() throws {
        // A full ramp already uses the whole range: Auto has little to ask for.
        let histogram = (0..<256).map { _ in 1.0 }
        let tone = try #require(CameraRawSettings.autoTone(luminance: histogram))
        #expect(abs(tone.exposure) <= 0.5)
        #expect(abs(tone.whites) <= 25)
        #expect(abs(tone.blacks) <= 25)
    }

    @Test func autoToneReadsNoHistogramFromAnEmptyImage() {
        #expect(CameraRawSettings.autoTone(luminance: []) == nil)
        #expect(CameraRawSettings.autoTone(luminance: Array(repeating: 0, count: 256)) == nil)
    }

    @Test func autoToneAppliesOnlyTheLightSliders() throws {
        let image = try dimScene()
        let tone = try #require(CameraRawSettings.autoTone(of: image))
        var settings = CameraRawSettings()
        settings.temperature = 18
        settings.tint = -6
        settings.vibrance = 22
        settings.saturation = -9
        settings.texture = 11
        settings.detail.sharpenAmount = 30
        settings.optics.distortion = -4
        let untouched = settings
        tone.apply(to: &settings)
        // Color and every other section is as it was.
        #expect(settings.temperature == untouched.temperature)
        #expect(settings.tint == untouched.tint)
        #expect(settings.vibrance == untouched.vibrance)
        #expect(settings.saturation == untouched.saturation)
        #expect(settings.texture == untouched.texture)
        #expect(settings.detail == untouched.detail)
        #expect(settings.optics == untouched.optics)
        #expect(settings.exposure == tone.exposure)
        #expect(settings.blacks == tone.blacks)
    }

    @Test func autoToneActuallyChangesPixels() throws {
        let image = try dimScene()
        let tone = try #require(CameraRawSettings.autoTone(of: image))
        var settings = CameraRawSettings()
        tone.apply(to: &settings)
        let graded = try settings.apply(image)
        #expect(try maxDelta(try rgba8(graded), try rgba8(image)) > 3, "Auto visibly lifts the picture")
    }

    @Test func autoToneIsPartOfTheLightReset() {
        var settings = CameraRawSettings()
        settings.exposure = 1.2
        settings.blacks = -30
        #expect(!settings.isDefault(.light))
        let reset = settings.resetting(.light)
        #expect(reset.isDefault(.light))
        #expect(reset.exposure == 0 && reset.blacks == 0)
    }

    // MARK: - 10.2 Optics › Lens Blur

    @Test func lensBlurAtZeroIsExactlyIdentity() throws {
        let image = try checkers()
        var settings = CameraRawSettings()
        settings.optics.lensBlur.amount = 0
        #expect(settings.optics.lensBlur.isIdentity)
        #expect(try rgba8(try settings.apply(image)) == rgba8(image))
    }

    @Test func lensBlurBlursOutsideTheFocusRegionAndKeepsItsMiddle() throws {
        let image = try checkers()
        var settings = CameraRawSettings()
        settings.optics.lensBlur.amount = 90
        settings.optics.lensBlur.aperture = .round
        settings.optics.lensBlur.focusRange = 15
        settings.optics.lensBlur.falloff = 30
        settings.optics.lensBlur.focusX = 0.5
        settings.optics.lensBlur.focusY = 0.5
        let blurred = try settings.apply(image)
        #expect(blurred.width == image.width && blurred.height == image.height)
        let before = try rgba8(image), after = try rgba8(blurred)
        #expect(before != after, "Lens Blur changes the pixels")

        func red(_ bytes: [UInt8], _ x: Int, _ y: Int) -> Int {
            Int(bytes[(y * image.width + x) * 4])
        }
        // The white square sits at the top-left corner: outside a centered focus region, so it must spread.
        let cornerBefore = red(before, 6, 6)
        let cornerAfter = red(after, 6, 6)
        #expect(cornerAfter < cornerBefore, "the corner square is softened: \(cornerBefore) → \(cornerAfter)")
        // A pixel just outside the square, dark before, picks up light from it.
        let neighborBefore = red(before, 14, 6)
        let neighborAfter = red(after, 14, 6)
        #expect(neighborAfter > neighborBefore, "light spreads into the neighbor: \(neighborBefore) → \(neighborAfter)")
    }

    @Test func lensBlurMovesWithItsFocusRegion() throws {
        let image = try checkers()
        var settings = CameraRawSettings()
        settings.optics.lensBlur.amount = 85
        settings.optics.lensBlur.focusRange = 12
        settings.optics.lensBlur.focusX = 0.5
        settings.optics.lensBlur.focusY = 0.5
        let centered = try rgba8(try settings.apply(image))
        settings.optics.lensBlur.focusX = 0.1
        settings.optics.lensBlur.focusY = 0.1
        let moved = try rgba8(try settings.apply(image))
        #expect(centered != moved, "moving the focus region changes what stays sharp")
    }

    @Test func lensBlurAperturesDiffer() throws {
        let image = try checkers()
        var settings = CameraRawSettings()
        settings.optics.lensBlur.amount = 90
        settings.optics.lensBlur.focusRange = 10
        settings.optics.lensBlur.aperture = .round
        let round = try rgba8(try settings.apply(image))
        settings.optics.lensBlur.aperture = .hexagon
        let hexagon = try rgba8(try settings.apply(image))
        // With no Metal device a Gaussian stands in for every aperture, so the two agree there.
        if CameraRawLensBlur.drawsApertures { #expect(round != hexagon) }
        #expect(round.count == hexagon.count)
    }

    @Test func lensBlurSettingsNormalize() {
        var settings = CameraRawLensBlurSettings()
        settings.amount = 400
        settings.focusX = -2
        settings.focusY = 5
        settings.focusRange = -10
        settings.falloff = 900
        settings.highlights = .nan
        let normalized = settings.normalized
        #expect(normalized.amount == 100)
        #expect(normalized.focusX == 0)
        #expect(normalized.focusY == 1)
        #expect(normalized.focusRange == 0)
        #expect(normalized.falloff == 100)
        #expect(normalized.highlights == 50)
        #expect(CameraRawLensBlurSettings().isIdentity)
    }

    @Test func lensBlurIsPartOfTheOpticsGroup() {
        var settings = CameraRawSettings()
        settings.optics.lensBlur.amount = 60
        settings.optics.lensBlur.aperture = .catsEye
        #expect(settings.adjustsOptics)
        #expect(!settings.isIdentity)
        #expect(!settings.isDefault(.optics))
        let reset = settings.resetting(.optics)
        #expect(reset.isDefault(.optics))
        #expect(reset.optics.lensBlur.amount == 0)
        // The eye for Optics drops it with the rest of the section.
        let hidden = settings.applying(showsLight: true, showsColor: true, showsOptics: false)
        #expect(hidden.optics.lensBlur.amount == 0)
    }

    // MARK: - Persistence

    @Test func lensBlurRoundTripsThroughPersistence() throws {
        var settings = CameraRawSettings()
        settings.optics.lensBlur.amount = 72
        settings.optics.lensBlur.aperture = .oval
        settings.optics.lensBlur.focusX = 0.31
        settings.optics.lensBlur.focusY = 0.68
        settings.optics.lensBlur.focusRange = 44
        settings.optics.lensBlur.falloff = 23
        settings.optics.lensBlur.highlights = 88
        let data = try JSONEncoder().encode(CameraRawSettingsPersistentState(settings))
        let decoded = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: data)
        let restored = try decoded.makeSettings()
        let blur = restored.optics.lensBlur
        #expect(blur.amount == 72)
        #expect(blur.aperture == .oval)
        #expect(abs(blur.focusX - 0.31) < 1e-9)
        #expect(abs(blur.focusY - 0.68) < 1e-9)
        #expect(blur.focusRange == 44)
        #expect(blur.falloff == 23)
        #expect(blur.highlights == 88)
    }

    /// A project written before Lens Blur existed has an `optics` object with no `lensBlur` key. It must still load,
    /// with no blur, rather than being rejected or silently regraded.
    @Test func olderOpticsWithoutLensBlurStillLoads() throws {
        let json = Data("""
        {"schemaVersion":1,"exposure":0.5,
         "optics":{"removeChromaticAberration":true,"enableLensProfile":false,"profileDistortion":100,
                   "profileVignetting":100,"distortion":-6,"purpleAmount":20,"purpleHueLow":270,
                   "purpleHueHigh":310,"greenAmount":0,"greenHueLow":60,"greenHueHigh":120,
                   "vignetteAmount":12,"vignetteMidpoint":40}}
        """.utf8)
        let decoded = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: json)
        let settings = try decoded.makeSettings()
        #expect(settings.exposure == 0.5)
        #expect(settings.optics.removeChromaticAberration)
        #expect(settings.optics.distortion == -6)
        #expect(settings.optics.vignetteMidpoint == 40)
        #expect(settings.optics.lensBlur.amount == 0)
        #expect(settings.optics.lensBlur.aperture == .round)
    }

    @Test func corruptLensBlurValuesAreRejected() throws {
        var persistent = CameraRawSettingsPersistentState()
        persistent.optics.lensBlur.amount = .infinity
        #expect(throws: CameraRawSettingsPersistentState.DecodeError.self) {
            _ = try persistent.makeSettings()
        }
        persistent = CameraRawSettingsPersistentState()
        persistent.optics.lensBlur.focusY = .nan
        #expect(throws: CameraRawSettingsPersistentState.DecodeError.self) {
            _ = try persistent.makeSettings()
        }
    }

    // MARK: - Non-destructive correction stack

    @Test func lensBlurSurvivesAFullCameraRawStackNode() throws {
        let image = try checkers()
        var settings = CameraRawSettings()
        settings.optics.lensBlur.amount = 80
        settings.optics.lensBlur.focusRange = 12
        var stack = LayerCorrectionStack(
            source: ImportedImage(image: image, thumbnail: image, name: "L"),
            nodes: [.cameraRawFull(settings)])
        let rendered = try LayerCorrectionRenderer.render(&stack)
        #expect(try maxDelta(try rgba8(rendered.image), try rgba8(image)) > 3)

        let persistent = try LayerCorrectionStackPersistentState(stack: stack)
        let source = ImportedImage(image: image, thumbnail: image, name: "L")
        let restored = try persistent.makeStack(source: source)
        let node = try #require(restored.nodes.first)
        #expect(node.cameraRawFull.optics.lensBlur.amount == 80)
        #expect(node.cameraRawFull.optics.lensBlur.focusRange == 12)
    }
}
