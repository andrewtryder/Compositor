import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Milestone 11.1: sensor-aware white balance and photographic color profiles on RAW development.
///
/// The white-balance solver talks to a decoder that cannot be present in a test host, so it is tested against a
/// synthetic sensor model with a known neutral; the profile reader and renderer are tested on real ICC bytes made
/// by ColorSync here. Neither needs a RAW file.
@MainActor
struct RawColorProfileTests {
    // MARK: - Helpers

    /// An image with a strong horizontal gradient and a clear row, so structure and alpha can both be checked.
    private func gradient(width: Int = 32, height: Int = 32) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        for x in 0..<width {
            let value = CGFloat(x) / CGFloat(max(1, width - 1))
            context.setFillColor(red: value, green: 1 - value, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height - 4))
        }
        return try #require(context.makeImage())
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let copy = try BrushRaster.copy(image)
        let pointer = try #require(copy.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: copy.bytesPerRow * image.height))
    }

    /// A real ICC profile's bytes, written by ColorSync, for a wide-gamut working space.
    private func displayP3Profile() throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let data = try #require(space.copyICCData() as Data?)
        #expect(data.count > 256, "a real ICC profile, not a stub")
        return data
    }

    // MARK: - Cast measurement

    @Test func aGrayFrameHasNoCastAndATintedOneDoes() {
        #expect(RawWhiteBalance.cast(red: 0.4, green: 0.4, blue: 0.4) == 0)
        #expect(RawWhiteBalance.cast(red: 0.4, green: 0.4, blue: 0.4).map { $0 < 1e-9 } == true)
        let warm = try? #require(RawWhiteBalance.cast(red: 0.5, green: 0.4, blue: 0.3))
        #expect((warm ?? 0) > 0.3, "a warm frame carries a measurable cast")
        #expect(RawWhiteBalance.cast(red: 0, green: 0, blue: 0) == nil, "black has no cast to speak of")
        #expect(RawWhiteBalance.cast(red: -1, green: 0.2, blue: 0.2) == nil, "negative light is not a color")
    }

    @Test func castOfAPictureIsMeasuredInLinearLight() throws {
        let gray = try gradient()
        let context = try BrushRaster.context(width: gray.width, height: gray.height, mask: false)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: gray.width, height: gray.height))
        let flat = try #require(context.makeImage())
        let cast = try #require(RawWhiteBalance.cast(of: flat))
        #expect(cast < 0.02, "an evenly gray picture measures as neutral (cast \(cast))")
    }

    // MARK: - Solver

    @Test func theSolverFindsTheNeutralOfASyntheticSensorModel() {
        // A model whose cast is a single well around 4800 K and tint 12: the solver must land on it, from a start
        // far away on both axes.
        let solved = RawWhiteBalance.solve(startingAt: (temperature: 7000, tint: -60), rounds: 3) { temperature, tint in
            let t = (Double(temperature) - 4800) / 2000, g = (Double(tint) - 12) / 60
            return abs(t) + abs(g) * 0.5
        }
        let solution = try? #require(solved)
        #expect(abs((solution?.temperature ?? 0) - 4800) < 120, "temperature converges on the neutral (got \(solution?.temperature ?? -1))")
        #expect(abs((solution?.tint ?? 0) - 12) < 6, "tint converges on the neutral (got \(solution?.tint ?? -1))")
        #expect((solution?.cast ?? 1) < 0.2, "the solution's residual cast is small")
    }

    @Test func theSolverKeepsItsStartWhenNothingIsBetter() {
        let solved = RawWhiteBalance.solve(startingAt: (temperature: 5200, tint: 7)) { temperature, tint in
            // Neutral exactly at the start: no candidate is better, so the start is the answer.
            temperature == 5200 && tint == 7 ? 0 : 0.5
        }
        #expect(solved?.temperature == 5200 && solved?.tint == 7, "a frame already neutral is left alone")
    }

    @Test func aDecoderThatCannotMeasureYieldsNoSolution() {
        #expect(RawWhiteBalance.solve(startingAt: (temperature: 5000, tint: 0)) { _, _ in nil } == nil)
    }

    @Test func theSolverStaysInsideTheDecodersRanges() {
        let solved = RawWhiteBalance.solve(startingAt: (temperature: 90_000, tint: 5_000), rounds: 1) { _, _ in 1 }
        let solution = try? #require(solved)
        #expect((solution?.temperature ?? 0) <= RawWhiteBalance.temperatureRange.upperBound)
        #expect((solution?.tint ?? 0) <= RawWhiteBalance.tintRange.upperBound)
        #expect((solution?.temperature ?? 0) >= RawWhiteBalance.temperatureRange.lowerBound)
    }

    // MARK: - Reading a profile

    @Test func anICCProfileIsReadAndIdentified() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m11-1-test-\(UUID().uuidString).icc")
        try displayP3Profile().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try RawColorProfile.read(url: url)
        #expect(read.profile.kind == .icc)
        #expect(read.profile.iccData == read.data)
        #expect(read.profile.name.hasPrefix("m11-1-test-"), "the profile keeps its own name")
        #expect(RawColorProfile.validatedColorSpace(from: read.data) != nil, "Core Graphics accepts it")
    }

    @Test func aDCPIsIdentifiedAndRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m11-1-test-\(UUID().uuidString).dcp")
        try Data("DCP\0\u{2}\0\0\0".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: RawColorProfileError.self) { try RawColorProfile.read(url: url) }
        do {
            _ = try RawColorProfile.read(url: url)
        } catch let error as RawColorProfileError {
            guard case .unsupportedFormat = error else {
                Issue.record("expected an unsupported-format refusal, got \(error)")
                return
            }
            #expect(error.localizedDescription.contains("ICC"), "the refusal says what is supported")
        }
    }

    @Test func garbageIsRefusedRatherThanAccepted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m11-1-test-\(UUID().uuidString).icc")
        try Data(repeating: 0x7F, count: 400).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: RawColorProfileError.self) { try RawColorProfile.read(url: url) }
    }

    // MARK: - Applying a profile

    @Test func cameraDefaultAndLinearChangeNothingHere() throws {
        let image = try gradient()
        let source = try bytes(image)
        #expect(try bytes(RawColorProfile(kind: .cameraDefault).applying(to: image)) == source,
                "the camera's own rendering is done by the decoder, not twice here")
        #expect(try bytes(RawColorProfile(kind: .linear).applying(to: image)) == source,
                "a linear decode is also the decoder's")
    }

    @Test func anICCProfileReallyChangesThePixelsAndKeepsTheFrame() throws {
        let image = try gradient()
        let profile = RawColorProfile(kind: .icc, iccData: try displayP3Profile(), name: "P3", strength: 100)
        let applied = try profile.applying(to: image)
        #expect(applied.width == image.width && applied.height == image.height, "the frame keeps its size")
        #expect(try bytes(applied) != bytes(image), "interpreting the pixels as P3 transforms them")
        let alpha = try bytes(applied)[3]
        #expect(alpha == 255, "coverage is kept")
    }

    @Test func strengthZeroIsExactlyTheInputAndHalfIsHalfway() throws {
        let image = try gradient()
        let data = try displayP3Profile()
        let none = try RawColorProfile(kind: .icc, iccData: data, name: "P3", strength: 0).applying(to: image)
        #expect(try bytes(none) == bytes(image), "zero strength is bit-exact")
        let full = try bytes(RawColorProfile(kind: .icc, iccData: data, name: "P3", strength: 100).applying(to: image))
        let half = try bytes(RawColorProfile(kind: .icc, iccData: data, name: "P3", strength: 50).applying(to: image))
        let source = try bytes(image)
        let index = 5 * 4
        let fullDelta = abs(Int(full[index]) - Int(source[index]))
        let halfDelta = abs(Int(half[index]) - Int(source[index]))
        if fullDelta > 2 { #expect(halfDelta > 0 && halfDelta < fullDelta, "half strength moves halfway") }
    }

    @Test func anICCProfileWithoutBytesIsRefusedNotSilentlyIgnored() throws {
        let image = try gradient()
        #expect(throws: RawColorProfileError.self) {
            try RawColorProfile(kind: .icc, iccData: nil, name: "missing", strength: 100).applying(to: image)
        }
    }

    @Test func aProfileOtherThanICCHasNoStrengthToSet() {
        var profile = RawColorProfile(kind: .linear, iccData: Data([1, 2, 3]), name: "ignored", strength: 20)
        profile = profile.normalized
        #expect(profile.strength == 100, "the decoder's profiles are whole")
        #expect(profile.iccData == nil, "a profile for the decoder carries no ICC bytes")
        #expect(profile.adjusts, "a linear decode is a real change")
        #expect(!RawColorProfile().adjusts, "the default changes nothing")
    }

    // MARK: - Development settings and persistence

    @Test func whiteBalanceModeRecordsHowTheBalanceWasReached() {
        var settings = RawDevelopSettings()
        settings.asShotTemperature = 6100
        settings.asShotTint = -8
        settings.temperature = 6100
        settings.tint = -8
        settings.asShotTemperatureAbsolute = 6100
        settings.asShotTintAbsolute = -8
        #expect(settings.isAsShot, "the default is the camera's reading")
        settings.whiteBalanceMode = .custom
        #expect(!settings.isAsShot, "a custom balance is a change")
        settings.reset()
        #expect(settings.whiteBalanceMode == .asShot && settings.temperature == settings.asShotTemperature)
    }

    @Test func thePersistentStateRoundTripsTheNewFields() throws {
        var settings = RawDevelopSettings()
        settings.whiteBalanceMode = .custom
        settings.temperature = 7300
        settings.tint = 14
        settings.asShotTemperatureAbsolute = 5150
        settings.asShotTintAbsolute = 3
        settings.colorProfile = RawColorProfile(kind: .icc, iccData: try displayP3Profile(), name: "P3 wide", strength: 63)
        let state = RawDevelopmentSettingsPersistentState(settings)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RawDevelopmentSettingsPersistentState.self, from: data)
        #expect(decoded == state, "the state encodes and decodes unchanged")
        let back = decoded.makeSettings()
        #expect(back.whiteBalanceMode == .custom)
        #expect(back.temperature == 7300 && back.tint == 14)
        #expect(back.colorProfile.kind == .icc && back.colorProfile.name == "P3 wide")
        #expect(back.colorProfile.strength == 63)
        #expect(back.colorProfile.iccData == settings.colorProfile.iccData, "the profile travels with the project")
    }

    @Test func aProjectWrittenBeforeM11_1DecodesToTheOldRendering() throws {
        let legacy = """
        {"schemaVersion":1,"exposure":0.5,"temperature":5200,"tint":4,"boost":1,"noiseReduction":0,
         "lensCorrection":false,"highlightRecovery":false,"asShotTemperature":5200,"asShotTint":4,
         "asShotNoiseReduction":0,"asShotLensCorrection":false,"asShotHighlightRecovery":false,
         "supportsNoiseReduction":false,"supportsLensCorrection":false,"supportsHighlightRecovery":false}
        """
        let decoded = try JSONDecoder().decode(RawDevelopmentSettingsPersistentState.self, from: Data(legacy.utf8))
        let settings = decoded.makeSettings()
        #expect(settings.whiteBalanceMode == .asShot, "an older project was saved as shot")
        #expect(settings.colorProfile.kind == .cameraDefault, "and with the camera's own rendering")
        #expect(settings.temperature == 5200, "its own balance is untouched")
    }

    @Test func anOlderRawDevelopmentStateCarriesItsOwnAsShot() throws {
        // A state written before M11.1 has no separate absolute reading: the as-shot settings it carries are it, so
        // As Shot returns the balance the project was developed with.
        let legacy = """
        {"schemaVersion":1,"exposure":0,"temperature":4800,"tint":-6,"boost":1,"noiseReduction":0,
         "lensCorrection":false,"highlightRecovery":false,"asShotTemperature":4800,"asShotTint":-6,
         "asShotNoiseReduction":0,"asShotLensCorrection":false,"asShotHighlightRecovery":false,
         "supportsNoiseReduction":false,"supportsLensCorrection":false,"supportsHighlightRecovery":false}
        """
        let decoded = try JSONDecoder().decode(RawDevelopmentSettingsPersistentState.self, from: Data(legacy.utf8))
        let settings = decoded.makeSettings()
        #expect(settings.whiteBalanceMode == .asShot)
        #expect(settings.temperature == 4800 && settings.tint == -6, "the balance it was developed at is kept")
        #expect(settings.developmentBalance.temperature == 4800 && settings.developmentBalance.tint == -6)
    }

    private func legacySettingsJSON() throws -> String {
        var settings = RawDevelopSettings()
        settings.asShotTemperature = 4800
        settings.asShotTint = -6
        settings.temperature = 4800
        settings.tint = -6
        return String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
    }

    private func makeSource() throws -> RawSourceAsset {
        RawSourceAsset(rawData: Data([0]), fileExtension: "dng", utType: "com.adobe.raw-image",
                       pixelWidth: 4, pixelHeight: 4, asShotSettings: RawDevelopSettings())
    }

    @Test func anInvalidModeOrProfileIsNotAValidState() {
        var state = RawDevelopmentSettingsPersistentState()
        #expect(state.isValid())
        state.whiteBalanceMode = "Made Up"
        #expect(!state.isValid(), "an unknown mode is refused rather than guessed")
        state = RawDevelopmentSettingsPersistentState()
        state.colorProfile.kind = "DCP"
        #expect(!state.isValid(), "a profile kind that cannot be rendered is refused")
    }
}
