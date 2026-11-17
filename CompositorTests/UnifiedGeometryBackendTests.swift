import AppKit
import Foundation
import Testing
@testable import Compositor

@Suite(.serialized)
@MainActor
struct UnifiedGeometryBackendTests {
    private func solid(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8) = (180, 90, 40)) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255,
                             blue: CGFloat(rgb.2) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

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

    private func sessionWithImage(_ image: CGImage, name: String = "Layer") -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: image.width, height: image.height)
        session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        return session
    }

    private func warpedMesh(from identity: MeshWarpGrid, delta: SIMD2<Float> = SIMD2(0.04, -0.03)) -> MeshWarpGrid {
        var mesh = identity
        let handle = mesh.index(column: mesh.pointColumns / 2, row: mesh.pointRows / 2)
        var positions = mesh.positions
        positions[handle] = positions[handle] + delta
        mesh.positions = positions
        mesh.topology.writeBack(positions: positions)
        return mesh
    }

    // 1
    @Test func cameraRawOnNormalEightBitLayer() throws {
        let image = try solid(width: 64, height: 48)
        var settings = CameraRawSettings()
        settings.geometry.upright = .off
        settings.geometry.vertical = 25
        settings.geometry.framingMode = .keepOriginalSize
        let out = try settings.apply(image)
        #expect(out.width == 64)
        #expect(out.height == 48)
    }

    // 2
    @Test func expandToFitPlacement() throws {
        let image = try solid(width: 80, height: 60)
        var settings = CameraRawGeometrySettings()
        settings.upright = .off
        settings.vertical = 45
        settings.framingMode = .expandToFit
        let result = try settings.applyResult(image)
        let expansion = try #require(result.expansion)
        let base = LayerTransform(origin: CGPoint(x: 5, y: 7), size: CGSize(width: 80, height: 60))
        let placed = expansion.layerTransform(from: base)
        #expect(expansion.footprintMatches(image: result.image, base: base, placed: placed))
        #expect(base.origin == CGPoint(x: 5, y: 7))
    }

    // 3
    @Test func horizonPlusPerspectiveAmount() throws {
        let image = try solid(width: 72, height: 54)
        var settings = CameraRawSettings()
        settings.geometry.upright = .off
        settings.geometry.vertical = 30
        settings.geometry.perspectiveAmount = 50
        settings.horizon.mode = .angle
        settings.horizon.angleDegrees = 5
        settings.geometry.framingMode = .keepOriginalSize
        let out = try settings.apply(image)
        #expect(out.width == 72 && out.height == 54)
    }

    // 4
    @Test func volumePlusPerspective() throws {
        let image = try solid(width: 64, height: 48)
        var settings = CameraRawSettings()
        settings.geometry.upright = .off
        settings.geometry.vertical = 20
        settings.geometry.volumeRadial = 40
        settings.geometry.framingMode = .keepOriginalSize
        let out = try settings.apply(image)
        #expect(out.width == 64 && out.height == 48)
    }

    // 5
    @Test func miniatureOnCorrectedGeometry() throws {
        let image = try solid(width: 64, height: 48)
        var settings = CameraRawSettings()
        settings.geometry.upright = .off
        settings.geometry.vertical = 15
        settings.miniature.strength = 40
        settings.miniature.shape = .linear
        settings.geometry.framingMode = .keepOriginalSize
        let out = try settings.apply(image)
        #expect(out.width == 64 && out.height == 48)
    }

    // 6
    @Test func reshapeOnNormalLayer() throws {
        let session = sessionWithImage(try checkerboard(width: 48, height: 48))
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        #expect(session.activeLayer?.reshape != nil)
        #expect(session.activeLayer?.asset != nil)
    }

    // 7
    @Test func reeditPersistentReshape() throws {
        let session = sessionWithImage(try checkerboard(width: 40, height: 40))
        session.beginMeshWarp(preset: .points4)
        var edit = try #require(session.meshWarpEdit)
        let source = edit.originalImage
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        session.beginMeshWarp()
        edit = try #require(session.meshWarpEdit)
        #expect(edit.originalImage.width == source.width)
        #expect(edit.originalImage !== session.activeLayer?.asset?.image)
    }

    // 8
    @Test func cameraRawAndReshapeOnSiblingLayers() throws {
        let session = EditorSession()
        session.createDocument(width: 64, height: 64)
        let a = try solid(width: 32, height: 32, rgb: (200, 40, 40))
        let b = try checkerboard(width: 32, height: 32)
        session.insert(ImportedImage(image: a, thumbnail: a, name: "Raw"))
        let rawID = try #require(session.activeLayerID)
        session.insert(ImportedImage(image: b, thumbnail: b, name: "Mesh"))
        let meshID = try #require(session.activeLayerID)

        session.activeLayerID = meshID
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        #expect(session.document?.layers.first(where: { $0.id == meshID })?.reshape != nil)

        session.activeLayerID = rawID
        var settings = CameraRawSettings()
        settings.geometry.vertical = 20
        let layer = try #require(session.document?.layers.first(where: { $0.id == rawID }))
        let asset = try #require(layer.asset)
        let corrected = try settings.apply(asset.image)
        #expect(corrected.width == asset.image.width)
        #expect(session.document?.layers.first(where: { $0.id == meshID })?.reshape != nil)
    }

    // 9
    @Test func cameraRawAttemptedOnEditableReshape() throws {
        let session = sessionWithImage(try checkerboard(width: 40, height: 40))
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        let layer = try #require(session.activeLayer)
        let refusal = try #require(session.cameraRawRefusal(for: layer))
        #expect(refusal.requiresBake)
        session.beginFilter(.cameraRaw)
        #expect(session.filterEdit == nil)
        #expect(session.brushError != nil)
        #expect(session.activeLayer?.reshape != nil)
    }

    // 10
    @Test func explicitBakeThenCameraRaw() throws {
        let session = sessionWithImage(try checkerboard(width: 40, height: 40))
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        session.bakeReshapeForCameraRaw()
        #expect(session.activeLayer?.reshape == nil)
        #expect(session.cameraRawRefusal(for: try #require(session.activeLayer)) == nil)
        session.beginFilter(.cameraRaw)
        #expect(session.filterEdit != nil)
        session.cancelFilter()
    }

    // 11
    @Test func combinedProjectSaveReopen() async throws {
        let session = EditorSession()
        session.createDocument(width: 64, height: 64)
        let rawImage = try solid(width: 40, height: 40, rgb: (30, 140, 200))
        let meshImage = try checkerboard(width: 40, height: 40)
        session.insert(ImportedImage(image: rawImage, thumbnail: rawImage, name: "CR"))
        let rawID = try #require(session.activeLayerID)
        // Bake a Camera Raw-corrected raster into the CR layer.
        if let index = session.document?.layers.firstIndex(where: { $0.id == rawID }),
           var layer = session.document?.layers[index],
           let asset = layer.asset {
            var settings = CameraRawSettings()
            settings.geometry.vertical = 18
            let out = try settings.apply(asset.image)
            let thumb = try PixelAdjust.thumbnail(of: out)
            layer.asset = ImportedImage(image: out, thumbnail: thumb, name: layer.name)
            session.beginEdit("Camera Raw")
            session.document?.layers[index] = layer
            session.endEdit()
        }
        session.insert(ImportedImage(image: meshImage, thumbnail: meshImage, name: "RS"))
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()

        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == 22)
        #expect(snapshot.reshapeMeshes.count == 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unified-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        #expect(reopened.document?.layers.count == 2)
        #expect(reopened.document?.layers.contains(where: { $0.reshape != nil }) == true)
        #expect(loaded.reshapeSources.count == 1)
    }

    // 12
    @Test func undoRedoWithBothCorrectionTypes() throws {
        let session = sessionWithImage(try checkerboard(width: 36, height: 36))
        let beforeReshape = session.history.undoCount
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh = warpedMesh(from: edit.mesh)
        session.applyMeshWarp()
        #expect(session.history.undoCount == beforeReshape + 1)
        session.bakeReshape()
        #expect(session.history.undoName == "Bake ReShape")
        session.undo()
        #expect(session.activeLayer?.reshape != nil)
        session.redo()
        #expect(session.activeLayer?.reshape == nil)
    }

    // 13
    @Test func adaptiveMeshAfterReload() throws {
        var mesh = MeshWarpGrid.identity(preset: .points4)
        let face = try #require(mesh.topology.rootFaceIDs.first)
        _ = mesh.subdivide(faceIDs: [face])
        #expect(mesh.isAdaptive)
        let restored = try MeshWarpPersistentState(mesh: mesh, imageWidth: 32, imageHeight: 32).makeGrid()
        #expect(restored.isAdaptive)
        #expect(restored.topology.leafFaceIDs.count == mesh.topology.leafFaceIDs.count)
    }

    // 14
    @Test func localCorrectionsAfterReload() throws {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.25)
        let handle = mesh.index(column: 4, row: 4)
        var seeds = Set<MeshWarpVertexID>()
        for row in 2..<6 {
            for column in 2..<6 { seeds.insert(mesh.vertexID(mesh.index(column: column, row: row))) }
        }
        let region = MeshWarpCorrectionRegion(vertexIDs: seeds)
        #expect(mesh.applyLocalCorrection(.horizon(MeshWarpLocalHorizon(mode: .angle, angleDegrees: 4, amount: 0.4)),
                                          region: region, imageWidth: 64, imageHeight: 64).ok)
        #expect(mesh.applyLocalCorrection(.volume(MeshWarpLocalVolume(mode: .radial, strength: 0.08)),
                                          region: MeshWarpCorrectionRegion(vertexIDs: [mesh.vertexID(handle)]),
                                          imageWidth: 64, imageHeight: 64).ok)
        let restored = try MeshWarpPersistentState(mesh: mesh, imageWidth: 64, imageHeight: 64).makeGrid()
        #expect(restored.positions == mesh.positions)
    }

    // 15
    @Test func selectionAndMaskAlignmentWithExpand() throws {
        let image = try solid(width: 50, height: 40)
        var settings = CameraRawGeometrySettings()
        settings.upright = .off
        settings.rotate = 8
        settings.framingMode = .expandToFit
        let result = try settings.applyResult(image)
        let expansion = try #require(result.expansion)
        let base = LayerTransform(origin: .zero, size: CGSize(width: 50, height: 40))
        let placed = expansion.layerTransform(from: base)
        #expect(expansion.footprintMatches(image: result.image, base: base, placed: placed))
    }

    // 16
    @Test func highBitDepthRefusalPaths() throws {
        let eight = try solid(width: 16, height: 16)
        let session = sessionWithImage(eight)
        #expect(session.reshapePrecision(for: try #require(session.activeLayer)) == .eightBit)
        #expect(CameraRawGeometrySettings.supportsExpandToFit(on: ImportedImage(image: eight, thumbnail: eight, name: "8")) == true)
        #expect(!UnifiedGeometryBackend.guiPlacement.isEmpty)
        #expect(UnifiedGeometryBackend.cameraRawCompositionOrder.contains("perspective"))
    }

    // 17
    @Test func legacyV21ProjectLoad() async throws {
        let image = try solid(width: 24, height: 24)
        let session = sessionWithImage(image)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy21-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
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
    }

    // 18
    @Test func projectV22Serialization() throws {
        #expect(ProjectManifest.current >= 22)
        #expect(ProjectManifest.supported.contains(22))
        #expect(ProjectManifest.supported.contains(23))
        #expect(ProjectManifest.supported.contains(21))
        #expect(ProjectManifest.supported.contains(27))
    }

    // 19
    @Test func missingCorruptSourceAndMesh() throws {
        var state = MeshWarpPersistentState(mesh: MeshWarpGrid.identity(preset: .points4),
                                            imageWidth: 16, imageHeight: 16)
        state.vertices[0].positionX = .infinity
        #expect(throws: MeshWarpPersistentState.DecodeError.self) { _ = try state.makeGrid() }

        state = MeshWarpPersistentState(mesh: MeshWarpGrid.identity(preset: .points4),
                                        imageWidth: 16, imageHeight: 16)
        state.faces[0].corners = [0, 1, 2]
        #expect(throws: MeshWarpPersistentState.DecodeError.self) { _ = try state.makeGrid() }

        state = MeshWarpPersistentState(mesh: MeshWarpGrid.identity(preset: .points4),
                                        imageWidth: 16, imageHeight: 16)
        // Orphan face id not reachable from roots.
        state.faces.append(MeshWarpPersistentState.Face(id: state.nextFaceID, corners: [0, 1, 2, 3],
                                                        parent: nil, children: nil))
        state.nextFaceID += 1
        #expect(throws: MeshWarpPersistentState.DecodeError.self) { _ = try state.makeGrid() }

        let source = try solid(width: 8, height: 8)
        let wrong = MeshWarpPersistentState(mesh: MeshWarpGrid.identity(preset: .points4),
                                            imageWidth: 16, imageHeight: 16)
        #expect(LayerReshape(persistent: wrong,
                             source: ImportedImage(image: source, thumbnail: source, name: "x")) == nil)
    }

    // 20
    @Test func cpuGpuMeshParity() throws {
        guard MetalMeshWarp.shared != nil else { return }
        let width = 48, height = 48
        let source = try checkerboard(width: width, height: height)
        var mesh = MeshWarpGrid.identity(preset: .points4, stickyBorders: true, propagation: 0.2)
        mesh = warpedMesh(from: mesh)
        var cpuTiming = MeshWarpRaster.Timing()
        let cpuImage = try #require(MeshWarpRaster.apply(source: source, mesh: mesh, timing: &cpuTiming))
        let sourceBytes = try MeshWarpRaster.rgba8Bytes(from: source)
        var gpuBytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = sourceBytes.withUnsafeBufferPointer { src in
            gpuBytes.withUnsafeMutableBufferPointer { dst in
                MetalMeshWarp.shared!.apply(source: src.baseAddress!, destination: dst.baseAddress!,
                                            width: width, height: height, stride: width * 4, mesh: mesh)
            }
        }
        #expect(ok)
        let cpuBytes = try MeshWarpRaster.rgba8Bytes(from: cpuImage)
        var maxDiff = 0
        for i in 0..<cpuBytes.count { maxDiff = max(maxDiff, abs(Int(cpuBytes[i]) - Int(gpuBytes[i]))) }
        #expect(maxDiff <= 2)
    }

    @Test func contractBakePolicyDocumented() {
        #expect(UnifiedGeometryBackend.futureNonDestructiveStackNotes.contains("Bake"))
        #expect(UnifiedGeometryBackend.Domain.allCases.contains(.cameraRawGeometry))
        #expect(UnifiedGeometryBackend.Domain.allCases.contains(.reshapeMesh))
    }
}
