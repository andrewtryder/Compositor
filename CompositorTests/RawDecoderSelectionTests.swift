import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Compositor

/// M12.5: which decoder a RAW is developed with, whether a request for RAW 9 was genuinely honoured, what the
/// selected version's controls are, and that none of it disturbs a project that never asked for one.
///
/// The decision logic is separated from `CIRAWFilter` precisely so the unsupported paths — a file that does not list
/// v9, a request that silently keeps another version — are tested without depending on which decoders this machine
/// happens to have. The fixture tests at the end exercise the real decoder, and say they are skipped when the
/// untracked DNG or CR2 is absent.
@MainActor
struct RawDecoderSelectionTests {

    // MARK: - Verdict: a request that was not honoured is not support

    @Test func listedAndHonouredVersionIsApplied() {
        let verdict = RawDecoderSelection.verdict(requested: "9", supported: ["8", "9"], effective: "9")
        #expect(verdict == .applied(effective: "9"))
        #expect(verdict.isApplied)
        #expect(verdict.effectiveVersion == "9")
        #expect(verdict.explanation == nil)
    }

    /// The measured CR2 behaviour: v9 is not listed, and assigning it leaves v7 in place. That is not support, and the
    /// API reports no error, so only the read-back distinguishes it from the DNG that really runs v9.
    @Test func versionNotListedIsRefused() {
        let verdict = RawDecoderSelection.verdict(requested: "9", supported: ["6", "7"], effective: "7")
        #expect(verdict == .notListed(requested: "9", supported: ["6", "7"]))
        #expect(!verdict.isApplied, "a version the file does not list is not support")
        #expect(verdict.effectiveVersion == nil)
        let reason = try? #require(verdict.explanation)
        #expect(reason?.contains("does not offer") == true, "the refusal says the file does not offer it")
    }

    /// The other silent-failure shape: the version is listed but the filter keeps another one. Shown as applied, it
    /// would display RAW 9 over a different decoder's pixels, so it is a refusal with the effective version named.
    @Test func listedButIgnoredVersionIsRefused() {
        let verdict = RawDecoderSelection.verdict(requested: "9", supported: ["8", "9"], effective: "8")
        #expect(verdict == .ignored(requested: "9", effective: "8"))
        #expect(!verdict.isApplied)
        #expect(verdict.effectiveVersion == "8", "the version that was actually used is still reported")
        let reason = try? #require(verdict.explanation)
        #expect(reason?.contains("developed with version 8") == true)
    }

    /// The `9` and `9.dng` spellings are the same decoder. A DNG that lists only `9.dng` must still be offered RAW 9,
    /// and the read-back is against the spelling that was actually requested.
    @Test func eitherSpellingCountsAsRaw9() {
        #expect(RawDecoderSelection.offersRaw9(supported: ["9"]))
        #expect(RawDecoderSelection.offersRaw9(supported: ["9.dng"]))
        #expect(RawDecoderSelection.offersRaw9(supported: ["6.dng", "7.dng", "8", "8.dng", "9", "9.dng"]))
        #expect(!RawDecoderSelection.offersRaw9(supported: ["6", "7"]))
        #expect(!RawDecoderSelection.offersRaw9(supported: []))
        // The DNG spelling is honoured under its own name.
        #expect(RawDecoderSelection.verdict(requested: "9.dng", supported: ["9.dng"], effective: "9.dng").isApplied)
    }

    @Test func systemDefaultIsAlwaysAvailable() {
        #expect(RawDecoderSelection.isAvailable(.systemDefault, supported: []))
        #expect(RawDecoderSelection.isAvailable(.systemDefault, supported: ["6", "7"]))
        #expect(!RawDecoderSelection.isAvailable(.appleRAW9, supported: ["6", "7"]))
        #expect(RawDecoderSelection.isAvailable(.appleRAW9, supported: ["8", "9"]))
    }

    /// The requested strings are what the read-back compares against, so they must match what the API reports. These
    /// are the values the probes on this machine measured, not invented spellings.
    @Test func requestedVersionsAreTheReportedStrings() {
        #expect(RawDecoderChoice.systemDefault.requestedVersions.isEmpty,
                "System Default asks for nothing, so the filter keeps its own choice")
        let requested = RawDecoderChoice.appleRAW9.requestedVersions.map(\.rawValue)
        #expect(requested == ["9", "9.dng"])
        #expect(RawDecoderChoice.raw9EffectiveVersions == ["9", "9.dng"])
    }

    // MARK: - Capability state: the selected decoder governs the controls

    /// What the Ricoh GR III DNG reported under each version. The selected version's flags — not the default
    /// decoder's — decide which controls are offered.
    @Test func capabilitiesDescribeTheVersionInEffect() {
        let raw9 = RawDecoderCapabilities(
            defaultVersion: "8", supportedVersions: ["6.dng", "7.dng", "8", "8.dng", "9", "9.dng"],
            effectiveVersion: "9",
            supportsLuminanceNoiseReduction: true, supportsColorNoiseReduction: false,
            supportsDetail: false, supportsSharpness: true, supportsContrast: true,
            supportsMoireReduction: false, supportsHighlightRecovery: true, supportsLensCorrection: false,
            detailAmount: 0, sharpnessAmount: 0.8534411, contrastAmount: 0, moireAmount: 0)
        #expect(raw9.isRaw9)
        #expect(raw9.supportsLuminanceNoiseReduction, "luminance noise reduction survives RAW 9")
        #expect(raw9.supportsSharpness && raw9.supportsContrast, "sharpness and contrast remain usable")
        #expect(!raw9.supportsColorNoiseReduction)
        #expect(!raw9.supportsDetail)
        #expect(!raw9.supportsMoireReduction)
        #expect(raw9.offersAnyRawDetail, "two controls survive, so the group is not hidden")

        var settings = RawDevelopSettings()
        RawImporter.applyCapabilities(raw9, to: &settings)
        #expect(settings.decoder == .systemDefault, "applyCapabilities does not choose a decoder")
        #expect(settings.effectiveDecoderVersion == "9")
        #expect(settings.supportsNoiseReduction)
        #expect(!settings.supportsColorNoiseReduction)
        #expect(settings.supportsRawDetail)
        #expect(!settings.supportsDetail && settings.supportsSharpness && settings.supportsContrast)
        #expect(!settings.supportsMoire)
        #expect(settings.unavailableRawDetailControls == [.detail, .moire])
    }

    /// The system decoder on the same file: everything available, and a different baseline. The two versions' baselines
    /// differ (sharpness 0.85 under both, moiré 0.5 → 0), which is why they are recaptured rather than carried across.
    @Test func theTwoVersionsHaveDifferentBaselines() {
        let v8 = RawDecoderCapabilities(
            defaultVersion: "8", supportedVersions: ["8", "9"], effectiveVersion: "8",
            supportsLuminanceNoiseReduction: true, supportsColorNoiseReduction: true,
            supportsDetail: true, supportsSharpness: true, supportsContrast: true,
            supportsMoireReduction: true, supportsHighlightRecovery: true, supportsLensCorrection: false,
            detailAmount: 0, sharpnessAmount: 0.8534411, contrastAmount: 0, moireAmount: 0.5)
        let v9 = RawDecoderCapabilities(
            defaultVersion: "8", supportedVersions: ["8", "9"], effectiveVersion: "9",
            supportsLuminanceNoiseReduction: true, supportsColorNoiseReduction: false,
            supportsDetail: false, supportsSharpness: true, supportsContrast: true,
            supportsMoireReduction: false, supportsHighlightRecovery: true, supportsLensCorrection: false,
            detailAmount: 0, sharpnessAmount: 0.8534411, contrastAmount: 0, moireAmount: 0)
        #expect(v8.baseline.sharpness == v9.baseline.sharpness, "sharpness survives, so its baseline is unchanged")
        #expect(v8.baseline.moire == 0.5 && v9.baseline.moire == 0, "moiré's baseline is the version's own")
        #expect(v8.baseline != v9.baseline)
    }

    // MARK: - Value retention and per-control gating

    /// Switching decoder must not discard a single adjustment. The values stay in the settings; what changes is which
    /// of them the selected version applies.
    @Test func switchingDecoderKeepsEveryAdjustmentValue() {
        var settings = RawDevelopSettings()
        settings.exposure = 0.75
        settings.temperature = 5200
        settings.tint = 12
        settings.boost = 0.8
        settings.noiseReduction = 0.4
        settings.colorNoiseReduction = 0.65
        settings.rawDetail = RawDetailSettings(enabled: true, detail: 0.5, sharpness: 0.1, contrast: 0.2, moire: 0.3)
        settings.decoder = .systemDefault
        settings.supportsColorNoiseReduction = true
        settings.supportsDetail = true
        settings.supportsSharpness = true
        settings.supportsContrast = true
        settings.supportsMoire = true

        let before = settings
        var after = settings
        after.decoder = .appleRAW9
        RawImporter.applyCapabilities(RawDecoderCapabilities(
            defaultVersion: "8", supportedVersions: ["8", "9"], effectiveVersion: "9",
            supportsLuminanceNoiseReduction: true, supportsColorNoiseReduction: false,
            supportsDetail: false, supportsSharpness: true, supportsContrast: true,
            supportsMoireReduction: false, supportsHighlightRecovery: true, supportsLensCorrection: false),
            to: &after)

        #expect(after.exposure == before.exposure)
        #expect(after.temperature == before.temperature)
        #expect(after.tint == before.tint)
        #expect(after.boost == before.boost)
        #expect(after.noiseReduction == before.noiseReduction)
        #expect(after.colorNoiseReduction == 0.65, "Color Noise Reduction's amount is kept while RAW 9 cannot use it")
        #expect(after.rawDetail.detail == 0.5 && after.rawDetail.moire == 0.3, "unavailable offsets are kept too")

        // ...and switching back restores them to the render, because they were never cleared.
        var back = after
        back.decoder = .systemDefault
        RawImporter.applyCapabilities(RawDecoderCapabilities(
            defaultVersion: "8", supportedVersions: ["8", "9"], effectiveVersion: "8",
            supportsLuminanceNoiseReduction: true, supportsColorNoiseReduction: true,
            supportsDetail: true, supportsSharpness: true, supportsContrast: true,
            supportsMoireReduction: true, supportsHighlightRecovery: true, supportsLensCorrection: false),
            to: &back)
        #expect(back.colorNoiseReduction == 0.65, "the amount returns with the decoder that applies it")
        #expect(back.rawDetail.detail == 0.5 && back.rawDetail.moire == 0.3)
        #expect(back.effectiveRawDetail == back.rawDetail, "every offset is in effect again")
    }

    /// The effective Raw Details the renderer sends is restricted to what the version offers, so an unsupported setter
    /// is never called and an inert amount is never counted as an adjustment.
    @Test func effectiveRawDetailIsRestrictedToTheSelectedVersion() {
        var settings = RawDevelopSettings()
        settings.rawDetail = RawDetailSettings(enabled: true, detail: 0.5, sharpness: 0.1, contrast: 0.2, moire: 0.3)
        settings.supportsRawDetail = true
        settings.supportsDetail = false
        settings.supportsSharpness = true
        settings.supportsContrast = true
        settings.supportsMoire = false

        let effective = settings.effectiveRawDetail
        #expect(effective.detail == 0, "RAW 9 cannot take a Detail amount")
        #expect(effective.moire == 0, "RAW 9 cannot take a Moiré amount")
        #expect(effective.sharpness == 0.1 && effective.contrast == 0.2, "the supported sliders keep their values")
        #expect(settings.rawDetail.detail == 0.5, "the settings themselves are untouched")
        #expect(settings.isRawDetailEffective)
    }

    /// Raw Details whose only non-zero amounts are the two RAW 9 cannot use is not adjusting anything, so a render must
    /// not report it as active. Treating it as an adjustment would make Reset appear disabled for a no-op.
    @Test func inertOffsetsDoNotCountAsAnAdjustment() {
        var settings = RawDevelopSettings()
        settings.rawDetail = RawDetailSettings(enabled: true, detail: 0.5, moire: 0.4)
        settings.supportsRawDetail = true
        settings.supportsDetail = false
        settings.supportsSharpness = true
        settings.supportsContrast = true
        settings.supportsMoire = false
        #expect(!settings.isRawDetailEffective, "neither set amount is in effect")
        #expect(settings.rawDetail.isIdentity(settingAside: [.detail, .moire]))
        #expect(!settings.rawDetail.isIdentity, "the saved values are still there, so switching back applies them")
        #expect(settings.isAsShot, "nothing is being adjusted, so this is still As Shot")
    }

    @Test func rawDetailIsIdentityWhenOnlyDisableIsSet() {
        let detail = RawDetailSettings(enabled: false, detail: 2, sharpness: 0.2)
        #expect(detail.isIdentity)
        #expect(detail.isIdentity(settingAside: []))
    }

    // MARK: - Persistence: absence means legacy system-default behaviour

    /// A project written before the decoder field existed decodes with the system's decoder, and with every Raw Details
    /// control its decoder had available — not with the field's type default read as "unavailable".
    @Test func legacySettingsDecodeAsSystemDefault() throws {
        // Written by the build before this field existed: no decoder, no per-control flags.
        let legacy = """
        {"schemaVersion":1,"exposure":0.5,"temperature":5400,"tint":6,"boost":0.9,
         "noiseReduction":0.2,"lensCorrection":false,"highlightRecovery":true,
         "asShotTemperature":5000,"asShotTint":0,"asShotNoiseReduction":0.1,
         "asShotLensCorrection":false,"asShotHighlightRecovery":false,
         "supportsNoiseReduction":true,"supportsLensCorrection":false,"supportsHighlightRecovery":true,
         "supportsRawDetail":true}
        """
        let decoded = try JSONDecoder().decode(RawDevelopmentSettingsPersistentState.self,
                                               from: Data(legacy.utf8))
        #expect(decoded.selectedDecoder == .systemDefault, "an absent decoder means the decoder it was saved with")
        #expect(decoded.decoder == nil, "nothing was invented into the file")
        #expect(decoded.offersDetail, "a decoder that had detail reconstruction kept every control")
        #expect(decoded.offersSharpness && decoded.offersContrast && decoded.offersMoire)
        #expect(decoded.unavailableRawDetailControls.isEmpty)

        let live = decoded.makeSettings()
        #expect(live.decoder == .systemDefault)
        #expect(live.supportsDetail && live.supportsSharpness && live.supportsContrast && live.supportsMoire,
                "legacy projects keep the controls they used")
        #expect(live.effectiveDecoderVersion.isEmpty, "no effective version was ever recorded for them")
    }

    /// The nested Raw Details record was synthesized before `moire` existed. Synthesized decoding of a nested type
    /// rejects a missing key, so this is the case that a default value alone would not have saved.
    @Test func legacyNestedRawDetailWithoutMoireDecodes() throws {
        let legacy = """
        {"schemaVersion":1,"supportsRawDetail":true,
         "rawDetail":{"enabled":true,"detail":0.25,"contrast":0.1}}
        """
        let decoded = try JSONDecoder().decode(RawDevelopmentSettingsPersistentState.self,
                                               from: Data(legacy.utf8))
        #expect(decoded.rawDetail.enabled)
        #expect(decoded.rawDetail.detail == 0.25)
        #expect(decoded.rawDetail.contrast == 0.1)
        #expect(decoded.rawDetail.sharpness == 0)
        #expect(decoded.rawDetail.moire == 0, "a missing field takes its neutral zero rather than failing the load")
    }

    @Test func decoderChoiceRoundTripsThroughPersistence() throws {
        var settings = RawDevelopSettings()
        settings.decoder = .appleRAW9
        settings.effectiveDecoderVersion = "9"
        settings.supportsColorNoiseReduction = false
        settings.supportsDetail = false
        settings.supportsSharpness = true
        settings.supportsContrast = true
        settings.supportsMoire = false
        settings.supportsRawDetail = true

        let persistent = RawDevelopmentSettingsPersistentState(settings)
        let encoded = try JSONEncoder().encode(persistent)
        let decoded = try JSONDecoder().decode(RawDevelopmentSettingsPersistentState.self, from: encoded)
        #expect(decoded.selectedDecoder == .appleRAW9)
        #expect(decoded.effectiveDecoderVersion == "9")
        #expect(!decoded.offersDetail && !decoded.offersMoire)
        #expect(decoded.offersSharpness && decoded.offersContrast)

        let live = decoded.makeSettings()
        #expect(live.decoder == .appleRAW9)
        #expect(live.effectiveDecoderVersion == "9")
        #expect(!live.supportsColorNoiseReduction && !live.supportsDetail && !live.supportsMoire)
    }

    /// An unknown decoder name is a corrupt or newer project. It must not quietly become the system decoder, because
    /// that would redevelop a RAW 9 frame with another decoder without saying so.
    @Test func unknownDecoderNameIsInvalidRatherThanSilentlyDefaulted() {
        var settings = RawDevelopmentSettingsPersistentState()
        settings.decoder = "Apple RAW 12"
        #expect(!settings.isValid(), "a decoder this build cannot honour is not silently replaced")
        settings.decoder = RawDecoderChoice.appleRAW9.rawValue
        #expect(settings.isValid())
    }

    /// Reset to As Shot restores the camera's development, but the decoder is not an adjustment: a person who chose
    /// RAW 9 and reset their sliders keeps RAW 9.
    @Test func resetLeavesTheDecoderAlone() {
        var settings = RawDevelopmentSettingsPersistentState()
        settings.decoder = RawDecoderChoice.appleRAW9.rawValue
        settings.exposure = 2
        settings.supportsDetail = false
        settings.supportsMoire = false
        settings.supportsSharpness = true
        settings.supportsContrast = true

        settings.reset()
        #expect(settings.exposure == 0)
        #expect(settings.selectedDecoder == .appleRAW9, "Reset is about adjustments, not which decoder develops")
    }

    /// The live settings' own Reset follows the same rule.
    @Test func liveSettingsResetLeavesTheDecoderAlone() {
        var settings = RawDevelopSettings()
        settings.decoder = .appleRAW9
        settings.exposure = 1.5
        settings.reset()
        #expect(settings.decoder == .appleRAW9)
        #expect(settings.exposure == 0)
    }

    // MARK: - RawDetailSettings isIdentity with a version's unavailable controls

    @Test func isIdentitySettingAsideIgnoresOnlyTheNamedControls() {
        let detail = RawDetailSettings(enabled: true, sharpness: 0.1)
        #expect(!detail.isIdentity)
        #expect(detail.isIdentity(settingAside: [.sharpness]))
        #expect(!detail.isIdentity(settingAside: [.detail]), "unrelated controls being unavailable changes nothing")
    }

    // MARK: - Capabilities read back from settings (for a layer whose bytes are held)

    @Test func capabilitiesFromSettingsDescribeTheSavedDecoder() {        var settings = RawDevelopSettings()
        settings.decoder = .appleRAW9
        settings.effectiveDecoderVersion = "9"
        settings.supportsNoiseReduction = true
        settings.supportsColorNoiseReduction = false
        settings.supportsRawDetail = true
        settings.supportsDetail = false
        settings.supportsSharpness = true
        settings.supportsContrast = true
        settings.supportsMoire = false
        settings.rawDetailDefaults = RawDetailBaseline(detail: 0, sharpness: 0.85, contrast: 0, moire: 0)

        let capabilities = RawDecoderCapabilities(settings)
        #expect(capabilities.isRaw9)
        #expect(!capabilities.supportsColorNoiseReduction && !capabilities.supportsDetail)
        #expect(capabilities.supportsSharpness && capabilities.supportsContrast)
        #expect(capabilities.baseline.sharpness == 0.85)
        #expect(capabilities.offersAnyRawDetail)
    }

    /// Undo and Redo restore the decoder choice with the rest of the development, proved on a document small enough that
    /// history keeps both sides. The fixture Apply test cannot: one 24 MP 16-bit frame exceeds the history's retained
    /// byte budget, so its redo side is trimmed by a pre-existing rule unrelated to decoder selection.
    @Test func decoderChoiceSurvivesUndoAndRedo() throws {
        let session = EditorSession()
        session.createDocument(width: 64, height: 48)
        let source = RawSourceAsset(
            rawData: Data(repeating: 0x5A, count: 4_096), fileExtension: "dng",
            utType: "com.adobe.raw-image", pixelWidth: 64, pixelHeight: 48,
            asShotSettings: RawDevelopSettings())
        var layer = ImageLayer(name: "Undo", blankSize: CGSize(width: 64, height: 48))
        layer.rawDevelopment = RawDevelopmentPersistentState(
            source: source, settings: RawDevelopmentSettingsPersistentState(),
            developedWidth: 64, developedHeight: 48, developedColorSpace: "extendedLinearSRGB",
            developedBitsPerComponent: 16)
        session.document?.layers.append(layer)
        session.activeLayerID = layer.id

        // Commit a RAW 9 development the way Apply does, without developing pixels.
        session.beginEdit("Apply RAW Development")
        var v9 = RawDevelopmentSettingsPersistentState()
        v9.decoder = RawDecoderChoice.appleRAW9.rawValue
        v9.effectiveDecoderVersion = "9"
        v9.supportsColorNoiseReduction = false
        v9.supportsDetail = false
        v9.supportsMoire = false
        v9.supportsSharpness = true
        v9.supportsContrast = true
        v9.supportsRawDetail = true
        v9.colorNoiseReduction = 0.45
        session.document?.layers[0].rawDevelopment?.settings = v9
        session.endEdit()

        #expect(session.canUndo, "one undoable step, nothing to redo yet")
        #expect(!session.canRedo, "nothing to redo before the undo")
        session.undo()
        #expect(session.document?.layers[0].rawDevelopment?.settings.selectedDecoder == .systemDefault,
                "Undo returns to the system decoder")
        #expect(session.canRedo, "the RAW 9 step is now redoable")
        session.redo()
        let redone = session.document?.layers[0].rawDevelopment?.settings
        #expect(redone?.selectedDecoder == .appleRAW9, "Redo restores RAW 9")
        #expect(redone?.effectiveDecoderVersion == "9")
        #expect(redone?.colorNoiseReduction == 0.45, "with the adjustment RAW 9 cannot apply")
        #expect(redone?.offersDetail == false && redone?.offersMoire == false)
        #expect(redone?.offersSharpness == true && redone?.offersContrast == true)
    }

    /// The editor sheet gates the four Raw Details sliders on whether detail reconstruction is on. That state has to
    /// be read from the draft, not from the sheet's own snapshot of it: a toggle that writes the draft and leaves the
    /// snapshot stale renders a set of sliders nobody can reach, which is exactly what the GUI walk found (M12.5).
    @Test func enablingRawDetailLandsInTheDraftTheSheetReadsItFrom() throws {
        let session = EditorSession()
        session.createDocument(width: 64, height: 48)
        let source = RawSourceAsset(
            rawData: Data(repeating: 0x5A, count: 4_096), fileExtension: "dng",
            utType: "com.adobe.raw-image", pixelWidth: 64, pixelHeight: 48,
            asShotSettings: RawDevelopSettings())
        var layer = ImageLayer(name: "Details", blankSize: CGSize(width: 64, height: 48))
        layer.rawDevelopment = RawDevelopmentPersistentState(
            source: source, settings: RawDevelopmentSettingsPersistentState(),
            developedWidth: 64, developedHeight: 48, developedColorSpace: "extendedLinearSRGB",
            developedBitsPerComponent: 16)
        session.document?.layers.append(layer)
        session.activeLayerID = layer.id
        _ = session.beginRawDevelopmentEdit(layerID: layer.id)

        #expect(session.rawDrafts[layer.id]?.settings.makeSettings().rawDetail.enabled == false,
                "starts off")

        // What the toggle's `set` does, with nothing else in between.
        var detail = session.rawDrafts[layer.id]?.settings.makeSettings().rawDetail ?? RawDetailSettings()
        detail.enabled = true
        #expect(session.updateRawDevelopmentSettings(layerID: layer.id, rawDetail: detail))

        #expect(session.rawDrafts[layer.id]?.settings.makeSettings().rawDetail.enabled == true,
                "the sheet reads this back, so the sliders are reachable")
    }

    // MARK: - The renderer must not lose a develop that finished before it was awaited
    /// A develop can complete between `beginDevelop` and `waitForDevelop`. The renderer used to drop the finished task,
    /// which made the caller read a completed develop as unknown and report Apply as failed — measured while writing
    /// the RAW 9 Apply/Undo/Redo test. The result is kept until it is asked for.
    @Test func aDevelopThatFinishesFirstIsStillDelivered() async throws {
        let renderer = RawDevelopmentRenderer()
        // An unreadable source fails immediately, which is the shape that finished before anyone awaited it.
        let source = RawSourceAsset(
            rawData: Data(), fileExtension: "dng", utType: "com.adobe.raw-image",
            pixelWidth: 4, pixelHeight: 4, asShotSettings: RawDevelopSettings())
        let revision = await renderer.beginDevelop(source: source, settings: RawDevelopSettings())
        // Give the task every chance to finish and be collected before anyone waits on it — the exact order that made
        // the old cleanup drop the task and report the develop as unknown.
        for _ in 0..<20 { await Task.yield() }
        let result = try #require(await renderer.waitForDevelop(revision: revision),
                                  "a completed develop is delivered, not reported as unknown")
        // An empty RAW cannot decode, so the answer is that failure — not a cancellation, which would mean the work
        // was abandoned rather than attempted.
        if case let .failure(error) = result {
            #expect(!(error is CancellationError))
        }

        // A revision this renderer never started is still honestly unknown rather than invented.
        #expect(await renderer.waitForDevelop(revision: revision + 1000) == nil,
                "a revision this renderer never started stays unknown")
    }
}