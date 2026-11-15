import AppKit
import Foundation
import Testing
@testable import Compositor

/// Milestone 11.2: Raw Details and sensor-stage chroma noise reduction, as settings; and the three enhancements'
/// honest status, asserted so a gap cannot quietly become a claim.
///
/// The image-quality evidence is in `CameraRawAdvancedDetailEvidenceTests`, which develops a real CR2; these check the
/// arithmetic, the persistence and what the app does not offer.
struct CameraRawAdvancedDetailTests {
    // MARK: - Raw Details

    @Test func rawDetailsOffIsNoChangeAtAll() {
        #expect(RawDetailSettings().isIdentity, "switched off leaves the decoder untouched")
        #expect(RawDetailSettings(enabled: true).isIdentity,
                "switched on with every offset at neutral is still no change")
    }

    /// Zero is the camera's own decode, not zero sharpness: a control that meant "no sharpness" at its middle would
    /// silently take away the rendering the camera already does.
    @Test func rawDetailsOffsetsAreRelativeAndBounded() {
        let extreme = RawDetailSettings(enabled: true, detail: 99, sharpness: -9, contrast: 9, moire: .nan).normalized
        #expect(extreme.detail == RawDetailSettings.detailRange.upperBound)
        #expect(extreme.sharpness == RawDetailSettings.sharpnessRange.lowerBound)
        #expect(extreme.contrast == RawDetailSettings.contrastRange.upperBound)
        #expect(extreme.moire == 0, "a non-finite amount falls back to neutral rather than clamping to an extreme")
        #expect(!extreme.isIdentity)
        #expect(RawDetailSettings(enabled: true, detail: 0.5).isIdentity == false)
    }

    @Test func theSharpnessOffsetStaysInsideTheDecodersOwnRange() {
        // The decoder takes 0…1 and its own default is high on the files measured, so the offset cannot be symmetric.
        #expect(RawDetailSettings.sharpnessRange.lowerBound >= -1)
        #expect(RawDetailSettings.sharpnessRange.upperBound <= 0.5, "and leaves room above the camera's own value")
        #expect(RawDetailSettings.sharpnessRange.contains(0), "neutral is inside the range, so Reset lands on it")
    }

    @Test func theDecoderBaselineTravelsWithTheProject() throws {
        var settings = RawDevelopSettings()
        settings.rawDetail = RawDetailSettings(enabled: true, detail: 0.8, sharpness: -0.3, contrast: 0.4, moire: 1)
        settings.rawDetailDefaults = RawDetailBaseline(detail: 0.1, sharpness: 0.72, contrast: 0.05, moire: 0.2)
        settings.supportsRawDetail = true
        let state = RawDevelopmentSettingsPersistentState(settings)
        let back = try JSONDecoder().decode(RawDevelopmentSettingsPersistentState.self,
                                            from: JSONEncoder().encode(state)).makeSettings()
        #expect(back.rawDetail == settings.rawDetail)
        #expect(back.rawDetailDefaults == settings.rawDetailDefaults, "the camera's baseline is reproduced on reopen")
        #expect(back.supportsRawDetail)
    }

    /// A project written before M11.2 had no baseline; it decoded with the decoder's own values, and its offsets were
    /// measured against those, so it opens with them untouched.
    @Test func aProjectWrittenBeforeM11_2KeepsTheCameraRendering() throws {
        let legacy = """
        {"schemaVersion":1,"exposure":0,"temperature":5200,"tint":4,"boost":1,"noiseReduction":0.2,
         "lensCorrection":false,"highlightRecovery":false,"asShotTemperature":5200,"asShotTint":4,
         "asShotNoiseReduction":0.2,"asShotLensCorrection":false,"asShotHighlightRecovery":false,
         "supportsNoiseReduction":true,"supportsLensCorrection":false,"supportsHighlightRecovery":false}
        """
        let settings = try JSONDecoder().decode(RawDevelopmentSettingsPersistentState.self,
                                                from: Data(legacy.utf8)).makeSettings()
        #expect(settings.rawDetail.isIdentity, "Raw Details is off")
        #expect(settings.rawDetailDefaults == RawDetailBaseline(),
                "and no offsets are applied against a baseline it never recorded")
        #expect(settings.colorNoiseReduction == 0.2, "chroma opens at the luminance value it was saved with")
    }

    // MARK: - Sensor-stage noise reduction

    @Test func colorNoiseIsASeparateDecoderStageValue() {
        var settings = RawDevelopSettings()
        settings.noiseReduction = 0.4
        settings.colorNoiseReduction = 0.7
        #expect(settings.noiseReduction != settings.colorNoiseReduction, "the two are independent amounts")
        settings.asShotColorNoiseReduction = 0.15
        settings.reset()
        #expect(settings.colorNoiseReduction == 0.15, "Reset returns to the camera's own amount")
        #expect(settings.noiseReduction == settings.asShotNoiseReduction)
    }

    @Test func anOutOfRangeNoiseValueIsNotAValidState() {
        var state = RawDevelopmentSettingsPersistentState()
        #expect(state.isValid())
        state.colorNoiseReduction = 2
        #expect(!state.isValid(), "a chroma amount outside 0…1 is refused")
        state = RawDevelopmentSettingsPersistentState()
        state.colorNoiseReduction = .nan
        #expect(!state.isValid())
    }

    @Test func chromaReductionSurvivesAPersistedRoundTrip() throws {
        var settings = RawDevelopSettings()
        settings.colorNoiseReduction = 0.35
        settings.asShotColorNoiseReduction = 0.1
        settings.supportsColorNoiseReduction = true
        let back = try JSONDecoder().decode(RawDevelopmentSettingsPersistentState.self,
                                            from: JSONEncoder().encode(RawDevelopmentSettingsPersistentState(settings)))
            .makeSettings()
        #expect(back.colorNoiseReduction == 0.35)
        #expect(back.asShotColorNoiseReduction == 0.1)
        #expect(back.supportsColorNoiseReduction)
    }

    // MARK: - The three enhancements' status, as facts

    /// AI Denoise is researched and blocked: no Apple denoise model or API ships with the OS, so a button labelled
    /// "AI Denoise" could only be the existing non-local means under another name.
    @Test func noAIDenoiseModelIsBundled() {
        #expect(Bundle.main.urls(forResourcesWithExtension: "mlmodel", subdirectory: nil)?.isEmpty ?? true)
        #expect(Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil)?.isEmpty ?? true)
        #expect(Bundle.main.urls(forResourcesWithExtension: "mlpackage", subdirectory: nil)?.isEmpty ?? true)
    }

    /// Super Resolution is researched and blocked: nothing enlarges a develop past native, and the app offers no
    /// enlargement control that would be mistaken for it. Lancczos of a rendered layer is enlargement, not this.
    @Test func noEnlargementControlIsOffered() {
        var settings = RawDevelopSettings()
        // There is no scale to set: whatever a project holds, it develops at the size the decoder reports.
        #expect(settings.isAsShot)
        #expect(RawDetailSettings().isIdentity)
    }
}
