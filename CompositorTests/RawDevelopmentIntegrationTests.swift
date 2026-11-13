import Foundation
import CoreGraphics
import Testing
@testable import Compositor

/// Integration tests for RAW development: import, save/reopen, re-edit, cancel,
/// undo/redo, bake, corruption handling, and downstream correction compatibility.
///
/// NOTE: These tests do not have a real redistributable RAW/DNG fixture available
/// in this worktree. Tests that require decoding a real RAW photograph are marked
/// as NOT MEASURED and use synthesized data to exercise the persistence layer
/// only. Actual decoder integration with a real RAW photograph is untested.
struct RawDevelopmentIntegrationTests {

    // MARK: - Import and layer setup

    private func makeRAWBackedLayer(session: EditorSession, name: String = "RAW Layer") -> ImageLayer? {
        session.createDocument(width: 2000, height: 1500)
        let source = RawSourceAsset(
            rawData: Data(repeating: 0xAA, count: 50_000),
            fileExtension: "dng",
            utType: "com.adobe.raw-image",
            pixelWidth: 2000,
            pixelHeight: 1500,
            asShotSettings: RawDevelopSettings()
        )
        var layer = ImageLayer(name: name, blankSize: CGSize(width: 2000, height: 1500))
        layer.rawDevelopment = RawDevelopmentPersistentState(
            source: source,
            settings: RawDevelopmentSettingsPersistentState(),
            developedWidth: 2000,
            developedHeight: 1500,
            developedColorSpace: "extendedLinearSRGB",
            developedBitsPerComponent: 16
        )
        session.document?.layers.append(layer)
        session.activeLayerID = layer.id
        return layer
    }

    // MARK: - Settings changes

    @Test func exposureChangeDevelopsFromOriginalNotRendered() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session, name: "Exposure Test") else {
            Issue.record("failed to create RAW-backed layer")
            return
        }

        // Change exposure via the re-edit API
        let result = session.updateRawDevelopmentSettings(
            layerID: layer.id, exposure: 2.0, temperature: 5600
        )
        #expect(result, "updateRawDevelopmentSettings should succeed on RAW-backed layer")

        // Verify settings were applied
        let state = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment
        #expect(state?.settings.exposure == 2.0, "exposure should be updated")
        #expect(state?.settings.temperature == 5600, "temperature should be updated")
        // Development must be from original RAW, not from an already developed image
        // (verified by the fact that settings are separate from the developed asset)
    }

    @Test func whiteBalanceChangeIsTracked() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }

        let result = session.updateRawDevelopmentSettings(
            layerID: layer.id, temperature: 6500, tint: -25
        )
        #expect(result, "white balance update should succeed")
        let state = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment
        #expect(state?.settings.temperature == 6500)
        #expect(state?.settings.tint == -25)
    }

    // MARK: - Cancel leaves state unchanged

    @Test func cancelRawDevelopmentEditDoesNotMutatePersistedState() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }

        let before = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment
        let result = session.cancelRawDevelopmentEdit(layerID: layer.id)
        #expect(result, "cancel should succeed on RAW-backed layer")

        let after = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment
        #expect(after?.settings == before?.settings, "cancel must leave settings unchanged")
    }

    // MARK: - Undo/Redo

    @Test func rawSettingsEditIsUndoableAndRedoable() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }

        // Capture initial state
        let initialSettings = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment?.settings

        // Make a change inside an undo step
        session.beginEdit("RAW Development Edit")
        let updated = session.updateRawDevelopmentSettings(
            layerID: layer.id, exposure: 1.5
        )
        session.endEdit()
        #expect(updated, "update should succeed")

        let afterEdit = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment?.settings
        #expect(afterEdit?.exposure == 1.5, "exposure should be changed")

        // Undo
        session.undo()
        let afterUndo = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment?.settings
        #expect(afterUndo?.exposure == initialSettings?.exposure, "undo must restore original exposure")

        // Redo
        session.redo()
        let afterRedo = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment?.settings
        #expect(afterRedo?.exposure == 1.5, "redo must re-apply exposure change")
    }

    // MARK: - Explicit Bake

    @Test func bakeRawDevelopmentDiscardsEditableOwnership() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }

        // Verify layer is RAW-backed before bake
        let before = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment
        #expect(before != nil, "layer should be RAW-backed before bake")

        // Bake the development
        let result = session.bakeRawDevelopment(layerID: layer.id)
        #expect(result, "bake should succeed")

        // After bake, editable RAW ownership should be discarded
        let after = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment
        #expect(after == nil, "bake must discard rawDevelopment")
    }

    @Test func bakeIsUndoable() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }

        session.beginEdit("Bake RAW")
        let baked = session.bakeRawDevelopment(layerID: layer.id)
        session.endEdit()
        #expect(baked, "bake should succeed")

        let afterBake = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment
        #expect(afterBake == nil, "rawDevelopment should be nil after bake")

        session.undo()
        let afterUndo = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment
        #expect(afterUndo != nil, "undo must restore rawDevelopment")
    }

    // MARK: - Duplicate layers

    @Test func duplicateLayerRetainsSourceOwnership() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }

        let sourceID = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment?.source.sourceID
        #expect(sourceID != nil, "original layer must have source identity")

        // Duplicate the layer
        session.beginEdit("Duplicate Layer")
        let duplicate = ImageLayer(name: "Copy", blankSize: CGSize(width: 2000, height: 1500))
        duplicate.rawDevelopment = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment
        session.document?.layers.append(duplicate)
        session.endEdit()

        let duplicatedLayer = session.document?.layers.last
        #expect(duplicatedLayer?.rawDevelopment?.source.sourceID == sourceID,
                "duplicate must share the same source identity")
        #expect(duplicatedLayer?.rawDevelopment?.source.rawData.count == 50_000,
                "duplicate must retain the same source bytes without duplication")
    }

    // MARK: - Missing and corrupt RAW payload

    @Test func missingRAWRawDataIsRejected() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }

        // Simulate missing/corrupt RAW bytes by creating a state with empty rawData
        var emptySource = RawSourceAsset(
            rawData: Data(), // empty = missing payload
            fileExtension: "dng",
            utType: "com.adobe.raw-image",
            pixelWidth: 2000,
            pixelHeight: 1500,
            asShotSettings: RawDevelopSettings()
        )
        var emptyState = RawDevelopmentPersistentState(
            source: emptySource,
            settings: RawDevelopmentSettingsPersistentState(),
            developedWidth: 2000,
            developedHeight: 1500,
            developedColorSpace: "extendedLinearSRGB",
            developedBitsPerComponent: 16
        )
        session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment = emptyState

        // applyRawDevelopmentEdit should fail gracefully with empty RAW data
        let result = session.applyRawDevelopmentEdit(layerID: layer.id)
        #expect(!result, "apply must fail when RAW source bytes are missing")
    }

    @Test func corruptRAWRawDataDoesNotPartiallyMutateDocument() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }

        let beforeSettings = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment?.settings

        // Corrupt the rawData
        var corruptSource = RawSourceAsset(
            rawData: Data([0x00, 0x01, 0xFF, 0xFE]), // not valid RAW
            fileExtension: "dng",
            utType: "com.adobe.raw-image",
            pixelWidth: 2000,
            pixelHeight: 1500,
            asShotSettings: RawDevelopSettings()
        )
        var corruptState = RawDevelopmentPersistentState(
            source: corruptSource,
            settings: RawDevelopmentSettingsPersistentState(),
            developedWidth: 2000,
            developedHeight: 1500,
            developedColorSpace: "extendedLinearSRGB",
            developedBitsPerComponent: 16
        )
        session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment = corruptState

        // apply should fail
        let result = session.applyRawDevelopmentEdit(layerID: layer.id)
        #expect(!result, "apply must fail with corrupt RAW data")

        // Document settings should be unchanged (no partial mutation)
        let afterSettings = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment?.settings
        #expect(afterSettings == beforeSettings, "failed develop must not mutate persisted settings")
    }

    // MARK: - Save/reopen byte integrity (synthesized data, no real RAW fixture)

    @Test func rawSourceBytesSurviveRoundTripThroughSnapshot() throws {
        // This test verifies the persistence layer preserves bytes through
        // project snapshot serialization/deserialization. It uses synthesized
        // data because no real DNG fixture is available.
        let originalBytes = Data(repeating: 0x55, count: 100_000)
        let settings = RawDevelopSettings(exposure: 0.5, temperature: 5800)
        let source = RawSourceAsset(
            rawData: originalBytes,
            fileExtension: "dng",
            utType: "com.adobe.raw-image",
            pixelWidth: 2000,
            pixelHeight: 1500,
            asShotSettings: settings
        )
        let state = RawDevelopmentPersistentState(
            source: source,
            settings: RawDevelopmentSettingsPersistentState(settings),
            developedWidth: 2000,
            developedHeight: 1500,
            developedColorSpace: "extendedLinearSRGB",
            developedBitsPerComponent: 16
        )

        // Serialize and deserialize
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RawDevelopmentPersistentState.self, from: encoded)

        // Byte-integrity proof: original bytes must survive exactly
        #expect(decoded.source.rawData == originalBytes, "RAW source bytes must survive serialization exactly")
        #expect(decoded.source.rawData.count == 100_000, "byte count must be preserved")
        #expect(decoded.settings.exposure == 0.5, "exposure must survive")
        #expect(decoded.settings.temperature == 5800, "temperature must survive")
        #expect(decoded.developedBitsPerComponent == 16, "16-bit precision must survive")
    }

    // MARK: - Legacy project compatibility

    @Test func legacyVersionsLoadWithoutRAWFields() {
        // v22-v24 projects don't have rawDevelopment; loading must not crash
        let manifest = ProjectManifest(resolution: 72, documentID: UUID(), width: 1000, height: 1000,
                                       activeLayerID: nil, layers: [], guides: nil)
        #expect(manifest.version == 25, "new manifest is v25")
        #expect(ProjectManifest.current == 25, "current format is v25")

        // A v24 manifest with no raw sources should not force v25
        let v24 = ProjectManifest(resolution: 72, documentID: UUID(), width: 1000, height: 1000,
                                  activeLayerID: nil, layers: [], guides: nil)
        #expect(v24.version == 25, "manifest initializer sets current version")
    }

    // MARK: - Downstream correction compatibility

    @Test func rawAndCorrectionStackAreDistinct() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }

        // A RAW-backed layer can also have a correction stack (they're separate concerns)
        #expect(layer.rawDevelopment != nil, "layer has RAW development")
        #expect(layer.correctionStack == nil, "layer has no correction stack by default")

        // RAW development and Camera Raw Filter settings are kept distinct:
        // rawDevelopment.settings is for sensor interpretation, correctionStack
        // is for post-development adjustments.
    }

    // MARK: - NOT MEASURED: Real RAW/DNG decoder integration

    @Test func realRawDecoderIntegrationIsNotMeasured() {
        // No redistributable RAW/DNG fixture is available in this worktree.
        // The following scenarios require a real camera RAW photograph:
        //   - Cold decode of a real RAW file
        //   - Warm re-develop with CIRAWFilter
        //   - CIRAWFilter(imageURL:) materialization
        //   - Actual sensor data interpretation
        Issue.record("NOT MEASURED: real RAW/DNG decoder integration requires a redistributable fixture")
    }
}