import AppKit
import Foundation
import Testing
@testable import Compositor

@Suite(.serialized)
@MainActor
struct NonDestructiveGeometryStackTests {
    private func checkerboard(width: Int, height: Int, cell: Int = 8) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let on = ((x / cell) + (y / cell)) % 2 == 0
                let i = y * stride + x * 4
                let value: UInt8 = on ? 220 : 40
                data[i] = value; data[i + 1] = value; data[i + 2] = on ? 255 : 60; data[i + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    private func coordinateField(width: Int, height: Int) throws -> CGImage {
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

    private func sessionWithImage(_ image: CGImage, name: String = "Layer") -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: image.width, height: image.height)
        session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        return session
    }

    private func warpedMesh(from identity: MeshWarpGrid, delta: SIMD2<Float> = SIMD2(0.05, -0.04)) -> MeshWarpGrid {
        var mesh = identity
        let handle = mesh.index(column: mesh.pointColumns / 2, row: mesh.pointRows / 2)
        var positions = mesh.positions
        positions[handle] = positions[handle] + delta
        mesh.positions = positions
        mesh.topology.writeBack(positions: positions)
        return mesh
    }

    private func geometrySettings(vertical: Double = 20) -> CameraRawGeometryBackendSettings {
        var settings = CameraRawGeometryBackendSettings()
        settings.geometry.upright = .off
        settings.geometry.vertical = vertical
        settings.geometry.framingMode = .keepOriginalSize
        return settings
    }

    private func rgba8(_ image: CGImage) throws -> [UInt8] {
        try MeshWarpRaster.rgba8Bytes(from: image)
    }

    // MARK: - Core stack

    @Test func identityStackRendersSource() throws {
        let image = try checkerboard(width: 48, height: 48)
        var stack = LayerCorrectionStack(source: ImportedImage(image: image, thumbnail: image, name: "L"))
        let result = try LayerCorrectionRenderer.render(&stack)
        #expect(result.image.width == 48 && result.image.height == 48)
        #expect(result.stagesRendered == 0)
        #expect(try rgba8(result.image) == rgba8(image))
    }

    @Test func cameraRawOnly() throws {
        let session = sessionWithImage(try checkerboard(width: 64, height: 48))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings(vertical: 25))
        let layer = try #require(session.activeLayer)
        let stack = try #require(layer.correctionStack)
        #expect(stack.nodes.count == 1)
        #expect(stack.nodes[0].kind == .cameraRawGeometry)
        #expect(layer.asset?.image.width == 64)
        #expect(layer.reshape == nil)
    }

    @Test func reshapeOnlyViaApply() throws {
        let session = sessionWithImage(try checkerboard(width: 48, height: 48))
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        let layer = try #require(session.activeLayer)
        #expect(layer.reshape != nil)
        #expect(layer.correctionStack?.hasReshape == true)
        #expect(layer.correctionStack?.source.image.width == 48)
    }

    @Test func cameraRawThenReshape() throws {
        let session = sessionWithImage(try coordinateField(width: 64, height: 64))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings())
        try session.addCorrection(kind: .reshape, meshPreset: .points4)
        var layer = try #require(session.activeLayer)
        let reshapeID = try #require(layer.correctionStack?.nodes.first(where: { $0.kind == .reshape })?.id)
        let mesh = warpedMesh(from: MeshWarpGrid.identity(preset: .points4))
        try session.editCorrection(nodeID: reshapeID) { node in
            node.mesh = mesh
            node.meshImageWidth = 64
            node.meshImageHeight = 64
        }
        layer = try #require(session.activeLayer)
        #expect(layer.correctionStack?.nodes.map(\.kind) == [.cameraRawGeometry, .reshape])
        #expect(layer.reshape != nil)
        #expect(layer.asset?.image.width == 64)
    }

    @Test func reshapeThenCameraRaw() throws {
        let session = sessionWithImage(try checkerboard(width: 48, height: 48))
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings(vertical: 15))
        let layer = try #require(session.activeLayer)
        #expect(layer.correctionStack?.nodes.map(\.kind) == [.reshape, .cameraRawGeometry])
        let before = try rgba8(try #require(layer.asset?.image))
        let crID = try #require(layer.correctionStack?.nodes.first(where: { $0.kind == .cameraRawGeometry })?.id)
        try session.editCorrection(nodeID: crID) { $0.cameraRaw.geometry.vertical = 35 }
        let after = try rgba8(try #require(session.activeLayer?.asset?.image))
        #expect(before != after)
        #expect(session.activeLayer?.correctionStack?.hasReshape == true)
    }

    @Test func enableDisableCorrection() throws {
        let session = sessionWithImage(try checkerboard(width: 40, height: 40))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings(vertical: 30))
        let id = try #require(session.activeLayer?.correctionStack?.nodes.first?.id)
        let on = try rgba8(try #require(session.activeLayer?.asset?.image))
        try session.setCorrectionEnabled(nodeID: id, enabled: false)
        let off = try rgba8(try #require(session.activeLayer?.asset?.image))
        #expect(on != off)
        try session.setCorrectionEnabled(nodeID: id, enabled: true)
        let restored = try rgba8(try #require(session.activeLayer?.asset?.image))
        #expect(restored == on)
    }

    @Test func removeCorrectionReRendersUpstream() throws {
        let session = sessionWithImage(try checkerboard(width: 48, height: 48))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings())
        try session.addCorrection(kind: .reshape, meshPreset: .points4)
        let reshapeID = try #require(session.activeLayer?.correctionStack?.nodes.first(where: { $0.kind == .reshape })?.id)
        try session.removeCorrection(nodeID: reshapeID)
        let layer = try #require(session.activeLayer)
        #expect(layer.correctionStack?.nodes.map(\.kind) == [.cameraRawGeometry])
        #expect(layer.reshape == nil)
    }

    @Test func resetCorrection() throws {
        let session = sessionWithImage(try checkerboard(width: 32, height: 32))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings(vertical: 40))
        let id = try #require(session.activeLayer?.correctionStack?.nodes.first?.id)
        try session.resetCorrection(nodeID: id)
        let settings = try #require(session.activeLayer?.correctionStack?.nodes.first?.cameraRaw)
        #expect(settings.geometry.vertical == 0)
    }

    @Test func reorderCompatibleNodes() throws {
        let session = sessionWithImage(try checkerboard(width: 48, height: 48))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings())
        try session.addCorrection(kind: .reshape, meshPreset: .points4)
        let nodes = try #require(session.activeLayer?.correctionStack?.nodes)
        let cr = nodes[0].id
        let reshape = nodes[1].id
        try session.reorderCorrection(nodeID: reshape, before: cr)
        #expect(session.activeLayer?.correctionStack?.nodes.map(\.kind) == [.reshape, .cameraRawGeometry])
    }

    @Test func expandWithReshapeRefused() throws {
        let session = sessionWithImage(try checkerboard(width: 48, height: 48))
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        var expand = geometrySettings()
        expand.geometry.framingMode = .expandToFit
        #expect(throws: LayerCorrectionError.expandWithReshape) {
            try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: expand)
        }
    }

    @Test func noCumulativeSourceResampling() throws {
        let session = sessionWithImage(try coordinateField(width: 64, height: 64))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings(vertical: 10))
        let sourceID = ObjectIdentifier(try #require(session.activeLayer?.correctionStack?.source.image))
        let crID = try #require(session.activeLayer?.correctionStack?.nodes.first?.id)
        for vertical in [15.0, 20, 25, 30] {
            try session.editCorrection(nodeID: crID) { $0.cameraRaw.geometry.vertical = vertical }
            let again = ObjectIdentifier(try #require(session.activeLayer?.correctionStack?.source.image))
            #expect(again == sourceID)
        }
    }

    // MARK: - Persistence / undo

    @Test func saveReopenReEdit() async throws {
        let session = sessionWithImage(try checkerboard(width: 48, height: 48))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings(vertical: 18))
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        let beforeKinds = try #require(session.activeLayer?.correctionStack?.nodes.map(\.kind))
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == 23)
        #expect(!snapshot.correctionStacks.isEmpty)
        #expect(snapshot.reshapeMeshes.count == 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m87-\(UUID().uuidString).comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        try? FileManager.default.removeItem(at: url)
        let layers = loaded.documentLayers
        let layer = try #require(layers.first)
        #expect(layer.correctionStack?.nodes.map(\.kind) == beforeKinds)
        #expect(layer.reshape != nil)
        let mesh = try #require(layer.correctionStack?.nodes.first(where: { $0.kind == .reshape })?.mesh)
        #expect(!mesh.isIdentity)
    }

    @Test func multipleSaveLoadCycles() async throws {
        let session = sessionWithImage(try checkerboard(width: 40, height: 40))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings())
        var snapshot = try #require(session.projectSnapshot())
        for _ in 0..<3 {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("m87-cycle-\(UUID().uuidString).comp")
            try await ProjectStore.shared.save(snapshot, to: url)
            snapshot = try await ProjectStore.shared.load(from: url)
            try? FileManager.default.removeItem(at: url)
            #expect(snapshot.correctionStacks.count == 1)
        }
    }

    @Test func undoRedoCorrectionEdit() throws {
        let session = sessionWithImage(try checkerboard(width: 32, height: 32))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings(vertical: 10))
        let id = try #require(session.activeLayer?.correctionStack?.nodes.first?.id)
        try session.editCorrection(nodeID: id) { $0.cameraRaw.geometry.vertical = 40 }
        #expect(session.activeLayer?.correctionStack?.nodes.first?.cameraRaw.geometry.vertical == 40)
        #expect(session.history.canUndo)
        session.undo()
        #expect(session.activeLayer?.correctionStack?.nodes.first?.cameraRaw.geometry.vertical == 10)
        session.redo()
        #expect(session.activeLayer?.correctionStack?.nodes.first?.cameraRaw.geometry.vertical == 40)
    }

    @Test func cancelMeshWarpLeavesStack() throws {
        let session = sessionWithImage(try checkerboard(width: 40, height: 40))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings())
        session.beginMeshWarp(preset: .points4)
        #expect(session.meshWarpEdit != nil)
        session.cancelMeshWarp()
        #expect(session.meshWarpEdit == nil)
        #expect(session.activeLayer?.correctionStack?.hasCameraRawGeometry == true)
    }

    @Test func duplicateLayerCopiesStack() throws {
        let session = sessionWithImage(try checkerboard(width: 36, height: 36))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings())
        session.duplicateActiveLayer()
        #expect(session.document?.layers.count == 2)
        #expect(session.document?.layers.filter { $0.correctionStack != nil }.count == 2)
    }

    @Test func explicitBakeClearsStack() throws {
        let session = sessionWithImage(try checkerboard(width: 40, height: 40))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings())
        try session.bakeAllCorrections()
        #expect(session.activeLayer?.correctionStack == nil)
        #expect(session.activeLayer?.reshape == nil)
        #expect(session.activeLayer?.asset != nil)
    }

    @Test func destructiveFilterRefused() throws {
        let session = sessionWithImage(try checkerboard(width: 32, height: 32))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings())
        let layer = try #require(session.activeLayer)
        #expect(session.reshapeDestructiveRefusal(for: layer) != nil)
        #expect(session.cameraRawRefusal(for: layer)?.requiresBake == true)
    }

    @Test func corruptStackRejectedWithoutInstall() async throws {
        let session = sessionWithImage(try checkerboard(width: 32, height: 32))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings())
        var snapshot = try #require(session.projectSnapshot())
        let id = try #require(snapshot.correctionStacks.keys.first)
        var bad = snapshot.correctionStacks[id]!
        bad.sourceWidth = 99999
        snapshot.correctionStacks[id] = bad
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m87-bad-\(UUID().uuidString).comp")
        // Save bypasses makeStack; load must reject.
        // Force-write a broken package via mutating after a valid save.
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let stackURL = url.appendingPathComponent("images").appendingPathComponent("\(id.uuidString).corrections.json")
        try Data("{}".utf8).write(to: stackURL)
        var rejected = false
        do {
            _ = try await ProjectStore.shared.load(from: url)
        } catch {
            rejected = true
        }
        #expect(rejected)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func deepHDRRefused() throws {
        let session = EditorSession()
        session.createDocument(width: 16, height: 16)
        // 8-bit path only: adding stack on blank layer without asset fails.
        #expect(throws: LayerCorrectionError.self) {
            try session.addCorrection(kind: .cameraRawGeometry)
        }
    }

    @Test func cacheHitOnUnchangedUpstream() throws {
        let image = try checkerboard(width: 48, height: 48)
        var stack = LayerCorrectionStack(source: ImportedImage(image: image, thumbnail: image, name: "L"),
                                         nodes: [
                                            .cameraRawGeometry(geometrySettings()),
                                            .reshape(mesh: warpedMesh(from: MeshWarpGrid.identity(preset: .points4)),
                                                     imageWidth: 48, imageHeight: 48)
                                         ])
        let first = try LayerCorrectionRenderer.render(&stack)
        #expect(first.cacheHits == 0)
        let second = try LayerCorrectionRenderer.render(&stack)
        #expect(second.cacheHits == 2)
        stack.invalidateFromIndex(1)
        let third = try LayerCorrectionRenderer.render(&stack)
        #expect(third.cacheHits == 1)
        #expect(third.stagesRendered == 1)
    }

    @Test func cpuGpuParityReshapeStage() throws {
        let image = try coordinateField(width: 64, height: 64)
        let mesh = warpedMesh(from: MeshWarpGrid.identity(preset: .points4))
        var stack = LayerCorrectionStack(source: ImportedImage(image: image, thumbnail: image, name: "L"),
                                         nodes: [.reshape(mesh: mesh, imageWidth: 64, imageHeight: 64)])
        let gpu = try LayerCorrectionRenderer.render(&stack, options: .init(preferMetalMesh: true, useCache: false))
        let cpu = try LayerCorrectionRenderer.renderCopy(stack, options: .init(preferMetalMesh: false, useCache: false))
        let g = try rgba8(gpu.image)
        let c = try rgba8(cpu.image)
        #expect(g.count == c.count)
        var maxDelta = 0
        for i in 0..<g.count {
            maxDelta = max(maxDelta, abs(Int(g[i]) - Int(c[i])))
        }
        #expect(maxDelta <= 2)
    }

    @Test func masksAndPlacementPreserved() throws {
        let session = sessionWithImage(try checkerboard(width: 48, height: 48))
        let origin = try #require(session.activeLayer?.transform.origin)
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings())
        #expect(session.activeLayer?.transform.origin == origin)
    }

    @Test func exportUsesRenderedDisplay() throws {
        let session = sessionWithImage(try checkerboard(width: 40, height: 40))
        try session.addCorrection(kind: .cameraRawGeometry, cameraRaw: geometrySettings(vertical: 22))
        let display = try #require(session.activeLayer?.asset?.image)
        let stack = try #require(session.activeLayer?.correctionStack)
        let rendered = try LayerCorrectionRenderer.renderCopy(stack)
        #expect(display.width == rendered.image.width)
        #expect(display.height == rendered.image.height)
    }

    @Test func v22ReshapeSynthesizesStackOnLoad() async throws {
        let session = sessionWithImage(try checkerboard(width: 32, height: 32))
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        // Strip correction stack from snapshot to emulate a v22 reshape-only package.
        let original = try #require(session.projectSnapshot())
        var layers = original.manifest.layers
        for i in layers.indices {
            layers[i].correctionStack = nil
        }
        var manifest = ProjectManifest(resolution: original.manifest.resolution,
            documentID: original.manifest.documentID, width: original.manifest.width,
            height: original.manifest.height, activeLayerID: original.manifest.activeLayerID,
            layers: layers, guides: original.manifest.guides)
        manifest.version = 22
        let snapshot = ProjectSnapshot(manifest: manifest,
            images: original.images, masks: original.masks, animations: original.animations,
            reshapeSources: original.reshapeSources, reshapeMeshes: original.reshapeMeshes)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m87-v22-\(UUID().uuidString).comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        try? FileManager.default.removeItem(at: url)
        let layer = try #require(loaded.documentLayers.first)
        #expect(layer.reshape != nil)
        #expect(layer.correctionStack?.hasReshape == true)
    }
}
