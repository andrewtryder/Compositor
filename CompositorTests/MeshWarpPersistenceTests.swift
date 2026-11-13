import AppKit
import Foundation
import Testing
@testable import Compositor

@Suite(.serialized)
@MainActor
struct MeshWarpPersistenceTests {
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

    private func rgba8(_ image: CGImage) throws -> [UInt8] {
        try MeshWarpRaster.rgba8Bytes(from: image)
    }

    private func centerIndex(of mesh: MeshWarpGrid) -> Int {
        mesh.index(column: mesh.pointColumns / 2, row: mesh.pointRows / 2)
    }

    private func sessionWithLayer(width: Int = 64, height: Int = 64) throws -> (EditorSession, UUID, CGImage) {
        let image = try checkerboard(width: width, height: height)
        let session = EditorSession()
        session.createDocument(width: width, height: height)
        let asset = ImportedImage(image: image, thumbnail: image, name: "Layer")
        session.insert(asset)
        let id = try #require(session.activeLayerID)
        return (session, id, image)
    }

    private func warpedMesh(from identity: MeshWarpGrid, delta: SIMD2<Float> = SIMD2(0.04, -0.03)) -> MeshWarpGrid {
        var mesh = identity
        let handle = centerIndex(of: mesh)
        var positions = mesh.positions
        positions[handle] = positions[handle] + delta
        mesh.positions = positions
        mesh.topology.writeBack(positions: positions)
        return mesh
    }

    // MARK: - Serialization

    @Test func identityMeshSerializationRoundTrip() throws {
        let mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.25)
        let state = MeshWarpPersistentState(mesh: mesh, imageWidth: 64, imageHeight: 64)
        let data = try state.encodedJSON()
        let decoded = try MeshWarpPersistentState.decode(from: data)
        let restored = try decoded.makeGrid()
        #expect(restored == mesh)
        #expect(decoded.imageWidth == 64)
        #expect(decoded.schemaVersion == MeshWarpPersistentState.schemaVersion)
    }

    @Test func regularMeshRoundTrip() throws {
        var mesh = MeshWarpGrid.identity(preset: .points4, stickyBorders: false, propagation: 0.5)
        mesh = warpedMesh(from: mesh)
        let restored = try MeshWarpPersistentState(mesh: mesh, imageWidth: 32, imageHeight: 48).makeGrid()
        #expect(restored.positions == mesh.positions)
        #expect(restored.rest == mesh.rest)
        #expect(restored.stickyBorders == false)
        #expect(abs(restored.propagation - 0.5) < 1e-6)
        #expect(restored.topology.order == mesh.topology.order)
    }

    @Test func adaptiveMeshRoundTrip() throws {
        var mesh = MeshWarpGrid.identity(preset: .points4, stickyBorders: true, propagation: 0.2)
        let face = try #require(mesh.topology.rootFaceIDs.first)
        let result = mesh.subdivide(faceIDs: [face])
        #expect(!result.succeeded.isEmpty)
        mesh = warpedMesh(from: mesh, delta: SIMD2(0.02, 0.01))
        let restored = try MeshWarpPersistentState(mesh: mesh, imageWidth: 40, imageHeight: 40).makeGrid()
        #expect(restored.topology.leafFaceIDs.count == mesh.topology.leafFaceIDs.count)
        #expect(restored.topology.order == mesh.topology.order)
        #expect(restored.positions == mesh.positions)
        #expect(restored.isAdaptive)
    }

    @Test func nestedSubdivisionRoundTrip() throws {
        var mesh = MeshWarpGrid.identity(preset: .points4)
        let root = try #require(mesh.topology.rootFaceIDs.first)
        _ = mesh.subdivide(faceIDs: [root])
        let child = try #require(mesh.topology.faces[root]?.children?.first)
        _ = mesh.subdivide(faceIDs: [child])
        let restored = try MeshWarpPersistentState(mesh: mesh, imageWidth: 32, imageHeight: 32).makeGrid()
        #expect(restored.topology.faces.count == mesh.topology.faces.count)
        #expect(Set(restored.topology.leafFaceIDs.map(\.rawValue)) == Set(mesh.topology.leafFaceIDs.map(\.rawValue)))
    }

    @Test func hangingEdgeTopologyRoundTrip() throws {
        var mesh = MeshWarpGrid.identity(preset: .points4)
        let roots = mesh.topology.rootFaceIDs
        guard roots.count >= 2 else { return }
        _ = mesh.subdivide(faceIDs: [roots[0]])
        #expect(!mesh.topology.edgeMidpoints.isEmpty)
        let beforeTris = mesh.triangles().count
        let restored = try MeshWarpPersistentState(mesh: mesh, imageWidth: 32, imageHeight: 32).makeGrid()
        #expect(restored.topology.edgeMidpoints.count == mesh.topology.edgeMidpoints.count)
        #expect(restored.triangles().count == beforeTris)
    }

    @Test func mergeAfterReloading() throws {
        var mesh = MeshWarpGrid.identity(preset: .points4)
        let root = try #require(mesh.topology.rootFaceIDs.first)
        _ = mesh.subdivide(faceIDs: [root])
        let children = try #require(mesh.topology.faces[root]?.children)
        var restored = try MeshWarpPersistentState(mesh: mesh, imageWidth: 32, imageHeight: 32).makeGrid()
        let merge = restored.merge(faceIDs: Set(children))
        #expect(!merge.succeeded.isEmpty)
        #expect(!restored.isAdaptive)
    }

    @Test func stableVertexAndFaceIDs() throws {
        var mesh = MeshWarpGrid.identity(preset: .points8)
        let handle = centerIndex(of: mesh)
        let vertexID = mesh.vertexID(handle)
        let faceID = try #require(mesh.topology.rootFaceIDs.first)
        mesh = warpedMesh(from: mesh)
        let restored = try MeshWarpPersistentState(mesh: mesh, imageWidth: 64, imageHeight: 64).makeGrid()
        #expect(restored.index(of: vertexID) == handle)
        #expect(restored.topology.faces[faceID] != nil)
        #expect(restored.topology.order.map(\.rawValue) == mesh.topology.order.map(\.rawValue))
    }

    @Test func stickyAndPropagationPersistence() throws {
        let mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0.77)
        let restored = try MeshWarpPersistentState(mesh: mesh, imageWidth: 16, imageHeight: 16).makeGrid()
        #expect(restored.stickyBorders == false)
        #expect(abs(restored.propagation - 0.77) < 1e-6)
    }

    @Test func localPerspectivePersistence() throws {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.3)
        // Use a soft horizontal keystone over a wider seed set so fold rejection is unlikely.
        var seeds = Set<MeshWarpVertexID>()
        for row in 2..<6 {
            for column in 2..<6 {
                seeds.insert(mesh.vertexID(mesh.index(column: column, row: row)))
            }
        }
        let region = MeshWarpCorrectionRegion(vertexIDs: seeds)
        let status = mesh.applyLocalCorrection(
            .perspective(MeshWarpLocalPerspective(mode: .horizontal, amount: 0.12)),
            region: region, imageWidth: 64, imageHeight: 64, base: mesh.positions)
        #expect(status.ok, "\(status.reason)")
        let restored = try MeshWarpPersistentState(mesh: mesh, imageWidth: 64, imageHeight: 64).makeGrid()
        #expect(restored.positions == mesh.positions)
    }

    @Test func localHorizonPersistence() throws {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.2)
        let handle = centerIndex(of: mesh)
        let region = MeshWarpCorrectionRegion(vertexIDs: [mesh.vertexID(handle)])
        let status = mesh.applyLocalCorrection(
            .horizon(MeshWarpLocalHorizon(mode: .angle, angleDegrees: 6, amount: 0.5)),
            region: region, imageWidth: 64, imageHeight: 64, base: mesh.positions)
        #expect(status.ok)
        let restored = try MeshWarpPersistentState(mesh: mesh, imageWidth: 64, imageHeight: 64).makeGrid()
        #expect(restored.positions == mesh.positions)
    }

    @Test func localVolumePersistence() throws {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.2)
        let handle = centerIndex(of: mesh)
        let region = MeshWarpCorrectionRegion(vertexIDs: [mesh.vertexID(handle)])
        let status = mesh.applyLocalCorrection(
            .volume(MeshWarpLocalVolume(mode: .radial, strength: 0.12)),
            region: region, imageWidth: 64, imageHeight: 64, base: mesh.positions)
        #expect(status.ok)
        let restored = try MeshWarpPersistentState(mesh: mesh, imageWidth: 64, imageHeight: 64).makeGrid()
        #expect(restored.positions == mesh.positions)
    }

    @Test func rejectsMalformedTopology() throws {
        var state = MeshWarpPersistentState(mesh: MeshWarpGrid.identity(preset: .points4),
                                            imageWidth: 16, imageHeight: 16)
        state.vertices[0].restX = .nan
        #expect(throws: MeshWarpPersistentState.DecodeError.self) {
            _ = try state.makeGrid()
        }
        state = MeshWarpPersistentState(mesh: MeshWarpGrid.identity(preset: .points4),
                                        imageWidth: 16, imageHeight: 16)
        state.faces[0].corners = [0, 1]
        #expect(throws: MeshWarpPersistentState.DecodeError.self) {
            _ = try state.makeGrid()
        }
    }

    // MARK: - Layer apply / project

    @Test func saveReopenPixelEquivalence() async throws {
        let (session, _, sourceImage) = try sessionWithLayer()
        session.beginMeshWarp(preset: .points8)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        let layer = try #require(session.activeLayer)
        #expect(layer.reshape != nil)
        #expect(layer.reshape?.source.image.width == sourceImage.width)
        let warped = try #require(layer.asset?.image)
        let before = try rgba8(warped)

        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == 22)
        #expect(snapshot.manifest.layers.first?.reshape != nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reshape-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        let again = try #require(reopened.activeLayer)
        #expect(again.reshape != nil)
        #expect(again.reshape?.mesh.positions == layer.reshape?.mesh.positions)
        let after = try rgba8(try #require(again.asset?.image))
        #expect(before == after)
    }

    @Test func editReapplyWithoutCumulativeResampling() throws {
        let (session, _, _) = try sessionWithLayer(width: 48, height: 48)
        session.beginMeshWarp(preset: .points4)
        var edit = try #require(session.meshWarpEdit)
        let sourceWidth = edit.originalImage.width
        let sourceHeight = edit.originalImage.height
        edit.mesh = warpedMesh(from: edit.mesh, delta: SIMD2(0.05, 0))
        session.applyMeshWarp()

        session.beginMeshWarp()
        edit = try #require(session.meshWarpEdit)
        #expect(edit.originalImage.width == sourceWidth)
        #expect(edit.originalImage.height == sourceHeight)
        let display = try #require(session.activeLayer?.asset?.image)
        #expect(edit.originalImage !== display)
        let meshBefore = edit.mesh
        edit.mesh = warpedMesh(from: edit.mesh, delta: SIMD2(0, 0.04))
        session.applyMeshWarp()
        let reshape = try #require(session.activeLayer?.reshape)
        #expect(reshape.mesh.positions != meshBefore.positions)
        #expect(reshape.source.image.width == sourceWidth)
        #expect(reshape.source.image.height == sourceHeight)
    }

    @Test func multipleSaveLoadCycles() async throws {
        let (session, _, _) = try sessionWithLayer()
        session.beginMeshWarp(preset: .points8)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        let expected = try #require(session.activeLayer?.reshape?.mesh.positions)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reshape-cycles-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        for _ in 0..<3 {
            let snapshot = try #require(session.projectSnapshot())
            try await ProjectStore.shared.save(snapshot, to: url)
            let loaded = try await ProjectStore.shared.load(from: url)
            session.installProject(loaded, from: url)
            #expect(session.activeLayer?.reshape?.mesh.positions == expected)
        }
    }

    @Test func oneDocumentUndoEntryPerApply() throws {
        let (session, _, _) = try sessionWithLayer()
        let undoBefore = session.history.undoCount
        session.beginMeshWarp(preset: .points8)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        #expect(session.history.undoCount == undoBefore + 1)
        #expect(session.history.undoName == "ReShape")
        #expect(session.activeLayer?.reshape != nil)
        session.undo()
        #expect(session.activeLayer?.reshape == nil)
        #expect(session.canRedo)
        session.redo()
        #expect(session.activeLayer?.reshape != nil)
        #expect(session.history.undoName == "ReShape")
    }

    @Test func cancelDoesNotChangePersistentMesh() throws {
        let (session, _, _) = try sessionWithLayer()
        session.beginMeshWarp(preset: .points8)
        var edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        let mesh = try #require(session.activeLayer?.reshape?.mesh)
        let display = try #require(session.activeLayer?.asset?.image)

        session.beginMeshWarp()
        edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh, delta: SIMD2(-0.06, 0.05))
        session.cancelMeshWarp()
        #expect(session.meshWarpEdit == nil)
        #expect(session.activeLayer?.reshape?.mesh == mesh)
        #expect(session.activeLayer?.asset?.image === display)
    }

    @Test func bakeClearsMeshKeepsPixels() throws {
        let (session, id, _) = try sessionWithLayer()
        session.beginMeshWarp(preset: .points8)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        let pixels = try #require(session.activeLayer?.asset?.image)
        session.bakeReshape(layerID: id)
        #expect(session.activeLayer?.reshape == nil)
        #expect(session.activeLayer?.asset?.image === pixels)
    }

    @Test func paintingRefusedUntilBake() throws {
        let (session, _, _) = try sessionWithLayer()
        session.beginMeshWarp(preset: .points8)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        session.tool = .brush
        #expect(!session.canPaint)
        #expect(session.reshapeDestructiveRefusal(for: try #require(session.activeLayer)) != nil)
    }

    @Test func existingProjectsWithoutReshapeLoad() async throws {
        let image = try checkerboard(width: 32, height: 32)
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Plain"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        let current = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(current, to: url)
        let manifestURL = url.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.version = 21
        for i in manifest.layers.indices { manifest.layers[i].reshape = nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == 21)
        #expect(loaded.reshapeMeshes.isEmpty)
        #expect(loaded.manifest.layers.allSatisfy { $0.reshape == nil })
    }
}
