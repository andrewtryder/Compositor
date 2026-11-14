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
}
