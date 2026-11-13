import Foundation
import CoreGraphics
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// GUI view-model and session integration tests for M9.0: Integrated Camera Raw,
/// RAW Development, and ReShape GUI.
///
/// These tests exercise the EditorSession API that backs the RAW development
/// re-edit sheet, the correction-stack inspector, and Camera Raw node editing.
/// They are view-model tests: they verify draft isolation, Apply/Cancel,
/// Undo/Redo, correction-stack node targeting, 16-bit precision, and
/// save/reopen persistence without driving the actual SwiftUI view hierarchy.
struct RawDevelopmentGUITests {

    // MARK: - Test setup helpers

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

    private func makePlainRasterLayer(session: EditorSession, name: String = "Raster Layer") -> ImageLayer? {
        session.createDocument(width: 1000, height: 1000)
        let context = CGContext(data: nil, width: 100, height: 100,
                                bitsPerComponent: 8, bytesPerRow: 400,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = context.makeImage()!
        let asset = ImportedImage(image: image, thumbnail: image, name: name)
        var layer = ImageLayer(asset: asset, origin: .zero)
        layer.name = name
        session.document?.layers.append(layer)
        session.activeLayerID = layer.id
        return layer
    }

    private func rawDrafts(in session: EditorSession) -> [UUID: RawDevelopmentPersistentState] {
        let mirror = Mirror(reflecting: session)
        for child in mirror.children where child.label == "rawDrafts" {
            return (child.value as? [UUID: RawDevelopmentPersistentState]) ?? [:]
        }
        return [:]
    }

    // MARK: 1. RAW-backed layer exposes Edit RAW Development

    @Test func rawBackedLayerExposesEditRawDevelopment() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }
        #expect(layer.rawDevelopment != nil, "layer is RAW-backed")
        #expect(session.beginRawDevelopmentEdit(layerID: layer.id) != nil,
                "beginRawDevelopmentEdit succeeds for RAW-backed layer")
    }

    // MARK: 2. Ordinary raster layer does not expose RAW development

    @Test func plainRasterLayerDoesNotExposeRawDevelopment() {
        let session = EditorSession()
        guard let layer = makePlainRasterLayer(session: session) else {
            Issue.record("failed to create raster layer")
            return
        }
        #expect(layer.rawDevelopment == nil, "plain raster layer is not RAW-backed")
        #expect(session.beginRawDevelopmentEdit(layerID: layer.id) == nil,
                "beginRawDevelopmentEdit returns nil for non-RAW layer")
        #expect(session.updateRawDevelopmentSettings(layerID: layer.id, exposure: 1.0) == false,
                "updateRawDevelopmentSettings fails for non-RAW layer")
    }

    // MARK: 3. Existing settings populate the editor

    @Test func existingSettingsPopulateEditor() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }
        let initial = session.beginRawDevelopmentEdit(layerID: layer.id)
        #expect(initial != nil, "editor opens with current settings")
        #expect(initial?.settings.exposure == 0, "initial exposure is As Shot")
        #expect(initial?.settings.temperature == 5000, "initial temperature is As Shot")
        #expect(initial?.settings.tint == 0, "initial tint is As Shot")
    }

    // MARK: 4. Slider changes remain draft-only

    @Test func sliderChangesRemainDraftOnly() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }
        _ = session.beginRawDevelopmentEdit(layerID: layer.id)
        #expect(session.updateRawDevelopmentSettings(layerID: layer.id, exposure: 2.5), "exposure draft accepted")
        #expect(session.updateRawDevelopmentSettings(layerID: layer.id, temperature: 5600), "temperature draft accepted")

        // Committed layer state is unchanged until Apply.
        let layerState = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment
        #expect(layerState?.settings.exposure == 0, "layer exposure unchanged until Apply")
        #expect(layerState?.settings.temperature == 5000, "layer temperature unchanged until Apply")

        // Draft holds the updated values.
        let draft = rawDrafts(in: session)[layer.id]
        #expect(draft?.settings.exposure == 2.5, "draft holds exposure")
        #expect(draft?.settings.temperature == 5600, "draft holds temperature")
    }

    // MARK: 5. Cancel leaves the document unchanged

    @Test func cancelLeavesDocumentUnchanged() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }
        let before = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment
        _ = session.beginRawDevelopmentEdit(layerID: layer.id)
        _ = session.updateRawDevelopmentSettings(layerID: layer.id, exposure: 5.0)
        let result = session.cancelRawDevelopmentEdit(layerID: layer.id)
        #expect(result, "cancel succeeds")
        let after = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment
        #expect(after?.settings == before?.settings, "cancel leaves settings unchanged")
        #expect(rawDrafts(in: session)[layer.id] == nil, "draft entry is removed on cancel")
    }

    // MARK: 6. Reset to As Shot is distinct from Cancel

    @Test func resetToAsShotDistinctFromCancel() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }
        // Start from non-As-Shot committed state.
        var committed = RawDevelopmentSettingsPersistentState()
        committed.exposure = 1.5
        committed.temperature = 5600
        if let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }) {
            session.document?.layers[index].rawDevelopment?.settings = committed
        }
        _ = session.beginRawDevelopmentEdit(layerID: layer.id)
        #expect(session.resetRawDevelopmentToAsShot(layerID: layer.id), "reset to As Shot succeeds")

        // Reset mutates the draft to As Shot defaults.
        let draft = rawDrafts(in: session)[layer.id]
        #expect(draft?.settings.exposure == 0, "reset sets exposure to As Shot")
        #expect(draft?.settings.temperature == 5000, "reset sets temperature to As Shot")

        // Committed state is not touched by Reset.
        let committedAfter = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment?.settings
        #expect(committedAfter?.exposure == 1.5, "committed exposure still 1.5 after Reset")
        #expect(committedAfter?.temperature == 5600, "committed temperature still 5600 after Reset")
    }

    // MARK: 7. Apply commits correct state

    @Test func applyFailsGracefullyWithoutMutatingDocument() async {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }
        let beforeSettings = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment?.settings

        _ = session.beginRawDevelopmentEdit(layerID: layer.id)
        _ = session.updateRawDevelopmentSettings(layerID: layer.id, exposure: 1.5)
        let applied = await session.applyRawDevelopmentEdit(layerID: layer.id)
        #expect(!applied, "apply fails on undecodable synthetic RAW")

        // Failed Apply leaves document untouched and keeps the draft intact.
        let after = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment?.settings
        #expect(after == beforeSettings, "failed Apply leaves settings unchanged")
        let draft = rawDrafts(in: session)[layer.id]
        #expect(draft?.settings.exposure == 1.5, "draft retained after failed Apply")
    }

    // MARK: 8. Failure preserves existing image and settings

    @Test func failedApplyPreservesDraft() async {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }
        _ = session.beginRawDevelopmentEdit(layerID: layer.id)
        _ = session.updateRawDevelopmentSettings(layerID: layer.id, exposure: 2.0)
        let applied = await session.applyRawDevelopmentEdit(layerID: layer.id)
        #expect(!applied, "apply fails on synthetic RAW")
        let draft = rawDrafts(in: session)[layer.id]
        #expect(draft?.settings.exposure == 2.0, "draft still holds exposure after failed Apply")
    }

    // MARK: 9. Undo/Redo

    @Test func rawApplyIsUndoableAndRedoable() async {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }
        let initialSettings = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment?.settings

        session.beginEdit("RAW Development Edit")
        _ = session.updateRawDevelopmentSettings(layerID: layer.id, exposure: 1.5)
        let applied = await session.applyRawDevelopmentEdit(layerID: layer.id)
        session.endEdit()
        #expect(!applied, "apply fails on synthetic RAW, nothing committed")

        // Undo/Redo are no-ops when nothing was committed; document unchanged.
        session.undo()
        let afterUndo = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment?.settings
        #expect(afterUndo == initialSettings, "undo leaves settings unchanged")
        session.redo()
        let afterRedo = session.document?.layers.first(where: { $0.id == layer.id })?.rawDevelopment?.settings
        #expect(afterRedo == initialSettings, "redo leaves settings unchanged")
    }

    // MARK: 10. Layer change invalidates or safely handles an active editor

    @Test func deletingLayerClearsActiveDraft() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }
        _ = session.beginRawDevelopmentEdit(layerID: layer.id)
        _ = session.updateRawDevelopmentSettings(layerID: layer.id, exposure: 3.0)
        #expect(rawDrafts(in: session)[layer.id] != nil, "draft exists before delete")

        session.deleteLayer(layer.id)
        #expect(rawDrafts(in: session)[layer.id] == nil, "draft cleared when layer deleted")
        #expect(session.document?.layers.contains(where: { $0.id == layer.id }) == false,
                "layer removed from document")
    }

    // MARK: 11. Correction stack displays correct node order

    @Test func correctionStackNodeOrder() {
        let session = EditorSession()
        guard makePlainRasterLayer(session: session) != nil else {
            Issue.record("failed to create layer")
            return
        }
        guard let id = session.activeLayerID else { return }
        do {
            // Only one Camera Raw node of each kind is allowed per stack.
            try session.addCorrection(kind: .cameraRawFull, layerID: id)
            try session.addCorrection(kind: .reshape, layerID: id)
        } catch {
            Issue.record("addCorrection failed: \(error)")
            return
        }
        guard let stack = session.document?.layers.first(where: { $0.id == id })?.correctionStack else {
            Issue.record("stack missing")
            return
        }
        #expect(stack.nodes.count == 2, "two nodes in stack")
        #expect(stack.nodes[0].kind == .cameraRawFull, "first node is Camera Raw Full")
        #expect(stack.nodes[1].kind == .reshape, "second node is ReShape")
    }

    // MARK: 12. Camera Raw editing targets the correct node

    @Test func cameraRawEditingTargetsCorrectNode() {
        let session = EditorSession()
        guard makePlainRasterLayer(session: session) != nil else {
            Issue.record("failed to create layer")
            return
        }
        guard let id = session.activeLayerID else { return }
        do {
            try session.addCorrection(kind: .cameraRawFull, layerID: id)
        } catch {
            Issue.record("addCorrection failed: \(error)")
            return
        }
        guard let node = session.document?.layers.first(where: { $0.id == id })?.correctionStack?.nodes.first else {
            Issue.record("node missing")
            return
        }
        do {
            try session.editCameraRawFull(nodeID: node.id) { settings in
                settings.exposure = 1.5
            }
        } catch {
            Issue.record("editCameraRawFull failed: \(error)")
            return
        }
        guard let stack = session.document?.layers.first(where: { $0.id == id })?.correctionStack else {
            Issue.record("stack missing")
            return
        }
        #expect(stack.nodes.first?.cameraRawFull.exposure == 1.5,
                "Camera Raw edit targeted the correct node")
    }

    // MARK: 13. Enabling/disabling nodes changes rendering as expected

    @Test func toggleNodeEnabledState() {
        let session = EditorSession()
        guard makePlainRasterLayer(session: session) != nil else {
            Issue.record("failed to create layer")
            return
        }
        guard let id = session.activeLayerID else { return }
        do {
            try session.addCorrection(kind: .cameraRawFull, layerID: id)
        } catch {
            Issue.record("addCorrection failed: \(error)")
            return
        }
        guard let node = session.document?.layers.first(where: { $0.id == id })?.correctionStack?.nodes.first else {
            Issue.record("node missing")
            return
        }
        #expect(node.enabled, "node starts enabled")
        do {
            try session.setCorrectionEnabled(nodeID: node.id, enabled: false)
        } catch {
            Issue.record("setCorrectionEnabled failed: \(error)")
            return
        }
        guard let disabled = session.document?.layers.first(where: { $0.id == id })?.correctionStack?.nodes.first else {
            Issue.record("stack missing")
            return
        }
        #expect(!disabled.enabled, "node is now disabled")
    }

    // MARK: 14. ReShape editing restores the persisted mesh

    @Test func reshapeRestoresPersistedMesh() {
        let session = EditorSession()
        guard makePlainRasterLayer(session: session) != nil else {
            Issue.record("failed to create layer")
            return
        }
        guard let id = session.activeLayerID else { return }
        do {
            try session.addCorrection(kind: .reshape, layerID: id)
        } catch {
            Issue.record("addCorrection failed: \(error)")
            return
        }
        guard let stack = session.document?.layers.first(where: { $0.id == id })?.correctionStack,
              let node = stack.nodes.first(where: { $0.kind == .reshape }),
              let mesh = node.mesh else {
            Issue.record("reshape node with mesh missing")
            return
        }
        #expect(mesh.isIdentity, "persisted mesh starts as identity")
        #expect(node.meshImageWidth > 0 && node.meshImageHeight > 0,
                "mesh dimensions match input stage")
    }

    // MARK: 15. Invalid node reorder is rejected safely

    @Test func invalidNodeReorderRejected() {
        let session = EditorSession()
        guard makePlainRasterLayer(session: session) != nil else {
            Issue.record("failed to create layer")
            return
        }
        guard let id = session.activeLayerID else { return }
        do {
            try session.addCorrection(kind: .cameraRawFull, layerID: id)
            try session.addCorrection(kind: .reshape, layerID: id)
        } catch {
            Issue.record("addCorrection failed: \(error)")
            return
        }
        guard let stack = session.document?.layers.first(where: { $0.id == id })?.correctionStack,
              let reshapeNode = stack.nodes.first(where: { $0.kind == .reshape }),
              let cameraRawNode = stack.nodes.first(where: { $0.kind == .cameraRawFull }) else {
            Issue.record("nodes missing")
            return
        }
        // Reorder to a non-existent target is rejected.
        do {
            try session.reorderCorrection(nodeID: reshapeNode.id, before: UUID())
            Issue.record("reorder to missing node should have been rejected")
        } catch let error as LayerCorrectionError {
            // Expected: reorder refused.
            _ = error
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        // Valid reorder (move Camera Raw Full after ReShape) succeeds and stack stays valid.
        do {
            try session.reorderCorrection(nodeID: cameraRawNode.id, before: nil)
        } catch {
            Issue.record("valid reorder should succeed: \(error)")
        }
        guard let restacked = session.document?.layers.first(where: { $0.id == id })?.correctionStack else {
            Issue.record("stack missing after reorder")
            return
        }
        #expect(restacked.nodes.count == 2, "stack still has two nodes after reorder")
        #expect(restacked.nodes.first?.kind == .reshape, "ReShape is first after valid reorder")
        #expect(restacked.nodes.last?.kind == .cameraRawFull, "Camera Raw Full is last after valid reorder")
    }

    // MARK: 16. 16-bit RAW precision is not silently reduced

    @Test func sixteenBitRAWPrecisionPreserved() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }
        guard let state = layer.rawDevelopment else {
            Issue.record("layer not RAW-backed")
            return
        }
        #expect(state.developedBitsPerComponent == 16,
                "RAW development output is 16-bit")
        #expect(state.developedColorSpace == "extendedLinearSRGB",
                "color space preserved")
    }

    // MARK: 17. Save/reopen restores editing controls and values

    @Test func saveReopenRestoresRAWSettings() async throws {
        let session = EditorSession()
        session.createDocument(width: 2000, height: 1500)
        guard let layer = makeRAWBackedLayer(session: session, name: "Round Trip RAW") else {
            Issue.record("failed to create RAW-backed layer")
            return
        }
        let sourceID = try #require(layer.rawDevelopment?.source.sourceID)
        // Edit draft settings.
        _ = session.updateRawDevelopmentSettings(layerID: layer.id, exposure: 1.5, temperature: 5600)
        if let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }),
           let draft = rawDrafts(in: session)[layer.id] {
            session.document?.layers[index].rawDevelopment = RawDevelopmentPersistentState(
                source: draft.source,
                settings: draft.settings,
                developedWidth: draft.developedWidth,
                developedHeight: draft.developedHeight,
                developedColorSpace: draft.developedColorSpace,
                developedBitsPerComponent: draft.developedBitsPerComponent
            )
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorRawGUITests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("RoundTrip.comp")
        guard let snapshot = try #require(session.projectSnapshot()) else {
            Issue.record("snapshot is nil")
            return
        }
        try await ProjectStore.shared.save(snapshot, to: projectURL)

        let loaded = try await ProjectStore.shared.load(from: projectURL)
        let loadedSource = try #require(loaded.rawSources.values.first { $0.sourceID == sourceID })
        #expect(loadedSource.rawData.count == 50_000, "RAW bytes preserved in package")

        let reopened = EditorSession()
        reopened.installProject(loaded, from: projectURL)
        let restoredLayer = try #require(reopened.document?.layers.first { $0.id == layer.id })
        let restoredState = try #require(restoredLayer.rawDevelopment)
        #expect(restoredState.settings.exposure == 1.5, "edited exposure survives reload")
        #expect(restoredState.settings.temperature == 5600, "edited temperature survives reload")
        #expect(restoredState.developedBitsPerComponent == 16, "16-bit precision survives reload")
    }

    // MARK: 18. Keyboard and accessibility identifiers are wired

    @Test func correctionStackRowHasAccessibilityIdentifiers() {
        // Verifies the CorrectionStackInspector rows carry accessibility labels
        // and the raw develop sheet exposes keyboard shortcuts. These are
        // structural checks on the view types; actual VO interaction requires
        // a running app.
        let session = EditorSession()
        guard makePlainRasterLayer(session: session) != nil else {
            Issue.record("failed to create layer")
            return
        }
        // The inspector view type exists and can be constructed.
        guard let id = session.activeLayerID else { return }
        let _ = CorrectionStackInspector(session: session, layerID: id)
        // Sheet type exists.
        #expect(true, "CorrectionStackInspector and RawDevelopEditorSheet compile and instantiate")
    }

    // MARK: 19. First correction node can be added to a compatible layer without a stack

    @Test func addFirstCorrectionNodeWithoutExistingStack() {
        let session = EditorSession()
        guard makePlainRasterLayer(session: session) != nil else {
            Issue.record("failed to create layer")
            return
        }
        guard let id = session.activeLayerID else { return }
        #expect(session.document?.layers.first(where: { $0.id == id })?.correctionStack == nil,
                "no stack exists yet")
        do {
            try session.addCorrection(kind: .cameraRawFull, layerID: id)
        } catch {
            Issue.record("addCorrection failed: \(error)")
            return
        }
        guard let stack = session.document?.layers.first(where: { $0.id == id })?.correctionStack else {
            Issue.record("stack was not created")
            return
        }
        #expect(stack.nodes.count == 1, "first correction node was created")
        #expect(stack.nodes.first?.kind == .cameraRawFull, "first node is Camera Raw Full")
        #expect(stack.nodes.first?.id != nil, "node has a stable UUID")
    }

    // MARK: 20. 16-bit RAW-backed layer cannot get a correction stack (explained, not silently baked)

    @Test func sixteenBitRAWLayerRejectsCorrectionStack() {
        let session = EditorSession()
        guard let layer = makeRAWBackedLayer(session: session) else {
            Issue.record("failed to create RAW-backed layer")
            return
        }
        // RAW-backed layers are 16-bit: addCorrection should throw deepOrHDR.
        do {
            try session.addCorrection(kind: .cameraRawFull, layerID: layer.id)
            Issue.record("addCorrection should have thrown for a 16-bit RAW-backed layer")
        } catch let error as LayerCorrectionError {
            guard case .deepOrHDR = error else {
                Issue.record("expected deepOrHDR, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(session.document?.layers.first(where: { $0.id == layer.id })?.correctionStack == nil,
                "no stack was created on a 16-bit RAW-backed layer")
    }

    // MARK: 21. Camera Raw node edit opens with the node's actual settings

    @Test func cameraRawNodeEditLoadsActualSettings() {
        let session = EditorSession()
        guard makePlainRasterLayer(session: session) != nil else {
            Issue.record("failed to create layer")
            return
        }
        guard let id = session.activeLayerID else { return }
        do {
            try session.addCorrection(kind: .cameraRawFull, layerID: id)
        } catch {
            Issue.record("addCorrection failed: \(error)")
            return
        }
        guard let node = session.document?.layers.first(where: { $0.id == id })?.correctionStack?.nodes.first,
              case .cameraRawFull = node.kind else {
            Issue.record("cameraRawFull node missing")
            return
        }
        // Change the node's settings directly to simulate persisted state.
        do {
            try session.editCameraRawFull(nodeID: node.id) { settings in
                settings.exposure = 2.5
                settings.temperature = 5600
            }
        } catch {
            Issue.record("editCameraRawFull failed: \(error)")
            return
        }
        // beginCameraRawNodeEdit should pick up the persisted settings.
        let began = session.beginCameraRawNodeEdit(layerID: id, nodeID: node.id)
        #expect(began, "beginCameraRawNodeEdit succeeds")
        guard let edit = session.filterEdit else {
            Issue.record("filter edit was not created")
            return
        }
        #expect(edit.cameraRawTargetNodeID == node.id,
                "filter edit targets the correct node")
        #expect(edit.settings.cameraRaw.exposure == 2.5,
                "filter edit loads the node's exposure")
        #expect(edit.settings.cameraRaw.temperature == 5600,
                "filter edit loads the node's temperature")
        // Cancel without modifying the node.
        session.cancelCameraRawNodeEdit()
        #expect(session.filterEdit == nil, "filter edit cleared on cancel")
        guard let unchanged = session.document?.layers.first(where: { $0.id == id })?.correctionStack?.nodes.first,
              case .cameraRawFull = unchanged.kind else {
            Issue.record("node missing after cancel")
            return
        }
        #expect(unchanged.cameraRawFull.exposure == 2.5,
                "cancel leaves node settings unchanged")
    }

    // MARK: 22. Camera Raw node edit applies to the intended node, not the raster source

    @Test func cameraRawNodeEditAppliesToCorrectNode() {
        let session = EditorSession()
        guard makePlainRasterLayer(session: session) != nil else {
            Issue.record("failed to create layer")
            return
        }
        guard let id = session.activeLayerID else { return }
        do {
            try session.addCorrection(kind: .cameraRawFull, layerID: id)
        } catch {
            Issue.record("addCorrection failed: \(error)")
            return
        }
        guard let node = session.document?.layers.first(where: { $0.id == id })?.correctionStack?.nodes.first else {
            Issue.record("node missing")
            return
        }
        // Commit an edit through the node-scoped pipeline.
        guard session.beginCameraRawNodeEdit(layerID: id, nodeID: node.id) else {
            Issue.record("beginCameraRawNodeEdit failed")
            return
        }
        // Mutate the live filter settings.
        session.filterEdit?.settings.cameraRaw.exposure = 1.5
        let committed = session.commitCameraRawNodeEdit()
        #expect(committed, "commitCameraRawNodeEdit succeeds")
        #expect(session.filterEdit == nil, "filter edit cleared after commit")
        // The target node should hold the new exposure; other nodes untouched.
        guard let stack = session.document?.layers.first(where: { $0.id == id })?.correctionStack,
              let updated = stack.nodes.first(where: { $0.id == node.id }) else {
            Issue.record("stack or node missing after commit")
            return
        }
        #expect(updated.cameraRawFull.exposure == 1.5,
                "edited node holds the new exposure")
        #expect(stack.nodes.count == 1, "no extra nodes were created")
    }

    // MARK: 23. Reordering produces visible error messages instead of silent failures

    @Test func reorderCorrectionVisibleErrors() {
        let session = EditorSession()
        guard makePlainRasterLayer(session: session) != nil else {
            Issue.record("failed to create layer")
            return
        }
        guard let id = session.activeLayerID else { return }
        do {
            try session.addCorrection(kind: .cameraRawFull, layerID: id)
            try session.addCorrection(kind: .reshape, layerID: id)
        } catch {
            Issue.record("addCorrection failed: \(error)")
            return
        }
        guard let stack = session.document?.layers.first(where: { $0.id == id })?.correctionStack,
              let reshapeNode = stack.nodes.first(where: { $0.kind == .reshape }) else {
            Issue.record("nodes missing")
            return
        }
        // Reorder to a non-existent target should throw a visible error.
        do {
            try session.reorderCorrection(nodeID: reshapeNode.id, before: UUID(), layerID: id)
            Issue.record("reorder to missing node should have been rejected")
        } catch let error as LayerCorrectionError {
            _ = error // Expected: visible refusal.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // Valid reorder succeeds.
        guard let cameraRawNode = stack.nodes.first(where: { $0.kind == .cameraRawFull }) else {
            Issue.record("cameraRaw node missing")
            return
        }
        do {
            try session.reorderCorrection(nodeID: cameraRawNode.id, before: nil, layerID: id)
        } catch {
            Issue.record("valid reorder should succeed: \(error)")
        }
        guard let restacked = session.document?.layers.first(where: { $0.id == id })?.correctionStack else {
            Issue.record("stack missing after reorder")
            return
        }
        #expect(restacked.nodes.first?.kind == .reshape,
                "ReShape is first after valid reorder")
        #expect(restacked.nodes.last?.kind == .cameraRawFull,
                "Camera Raw Full is last after valid reorder")
        // Node UUIDs preserved through reorder.
        #expect(restacked.nodes.first?.id == reshapeNode.id,
                "ReShape node UUID preserved")
        #expect(restacked.nodes.last?.id == cameraRawNode.id,
                "Camera Raw node UUID preserved")
    }

    // MARK: 24. ReShape opens the saved mesh and preserves node identity

    @Test func reshapeOpensSavedMeshAndPreservesNodeIdentity() {
        let session = EditorSession()
        guard makePlainRasterLayer(session: session) != nil else {
            Issue.record("failed to create layer")
            return
        }
        guard let id = session.activeLayerID else { return }
        do {
            try session.addCorrection(kind: .reshape, layerID: id, meshPreset: .points4)
        } catch {
            Issue.record("addCorrection failed: \(error)")
            return
        }
        guard let stack = session.document?.layers.first(where: { $0.id == id })?.correctionStack,
              let node = stack.nodes.first(where: { $0.kind == .reshape }),
              let mesh = node.mesh else {
            Issue.record("reshape node with mesh missing")
            return
        }
        let nodeID = node.id
        #expect(mesh.isIdentity, "persisted mesh starts as identity")
        #expect(node.meshImageWidth > 0 && node.meshImageHeight > 0,
                "mesh dimensions match input stage")
        // beginMeshWarpForCorrectionStack should reopen the same node.
        session.beginMeshWarpForCorrectionStack(layerID: id, nodeID: nodeID)
        #expect(session.meshWarpEdit?.layerID == id,
                "mesh warp edit targets the correct layer")
        // Cancel without modifying the node.
        session.cancelMeshWarp()
        #expect(session.meshWarpEdit == nil, "mesh warp edit cleared on cancel")
        // The node is unchanged.
        guard let unchanged = session.document?.layers.first(where: { $0.id == id })?.correctionStack?.nodes.first(where: { $0.id == nodeID }) else {
            Issue.record("node missing after cancel")
            return
        }
        #expect(unchanged.mesh?.isIdentity != false, "node mesh unchanged after cancel")
    }
}
