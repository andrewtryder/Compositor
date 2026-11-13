import AppKit
import Foundation
import Testing
@testable import Compositor

@Suite(.serialized)
@MainActor
struct MeshWarpTopologyTests {
    private let maximumChannelError = 1

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

    private func maxChannelError(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    private func centerIndex(of mesh: MeshWarpGrid) -> Int {
        mesh.index(column: mesh.pointColumns / 2, row: mesh.pointRows / 2)
    }

    private func render(_ source: CGImage, mesh: MeshWarpGrid) throws -> CGImage {
        var timing = MeshWarpRaster.Timing()
        return try #require(MeshWarpRaster.apply(source: source, mesh: mesh, timing: &timing))
    }

    @Test func regularGridTopologyMatchesLegacyTriangleCount() {
        let mesh = MeshWarpGrid.identity(preset: .points8)
        #expect(mesh.topology.order.count == 64)
        #expect(mesh.topology.rootFaceIDs.count == 49)
        #expect(mesh.triangles().count == 49 * 2)
        #expect(!mesh.isAdaptive)
    }

    @Test func singleCellSubdivisionCreatesFourLeavesAndSharedMids() {
        var mesh = MeshWarpGrid.identity(preset: .points4)
        let face = mesh.topology.rootFaceIDs[0]
        let beforeCount = mesh.pointCount
        let result = mesh.subdivide(faceIDs: [face])
        #expect(!result.succeeded.isEmpty)
        #expect(mesh.isAdaptive)
        #expect(mesh.topology.faces[face]?.isLeaf == false)
        #expect(mesh.topology.faces[face]?.children?.count == 4)
        // One isolated cell on a 4×4 grid has neighbors — conforming may subdivide more.
        #expect(mesh.pointCount > beforeCount)
        // Midpoints are shared: edge map non-empty.
        #expect(!mesh.topology.edgeMidpoints.isEmpty)
    }

    @Test func neighboringSubdivisionSharesEdgeMidpoint() {
        var mesh = MeshWarpGrid.identity(preset: .points8)
        let a = mesh.topology.rootFaceIDs[0]
        let neighbors = mesh.topology.neighbors(of: a)
        #expect(!neighbors.isEmpty)
        let b = neighbors[0]
        let result = mesh.subdivide(faceIDs: [a])
        #expect(result.succeeded.contains(a))
        // Conforming should have subdivided the neighbor too.
        #expect(mesh.topology.faces[b]?.isLeaf == false || result.succeeded.contains(b))
        // Shared edge has one midpoint entry.
        #expect(!mesh.topology.edgeMidpoints.isEmpty)
    }

    @Test func nestedSubdivisionIncreasesDepth() throws {
        var mesh = MeshWarpGrid.identity(preset: .points4, stickyBorders: false, propagation: 0)
        var face = mesh.topology.rootFaceIDs[mesh.topology.rootFaceIDs.count / 2]
        for depth in 0..<3 {
            let result = mesh.subdivide(faceIDs: [face])
            #expect(!result.succeeded.isEmpty, "depth \(depth)")
            let children = try #require(mesh.topology.faces[face]?.children)
            face = children[0]
            #expect(mesh.topology.depth(of: face) == depth + 1)
        }
    }

    @Test func identityRemainsIdentityAfterSubdivision() throws {
        let source = try checkerboard(width: 64, height: 64, cell: 8)
        var mesh = MeshWarpGrid.identity(preset: .points8)
        #expect(mesh.isIdentity)
        let before = try rgba8(try render(source, mesh: mesh))
        let face = mesh.topology.rootFaceIDs[10]
        let result = mesh.subdivide(faceIDs: [face])
        #expect(!result.succeeded.isEmpty)
        #expect(mesh.isIdentity)
        let after = try rgba8(try render(source, mesh: mesh))
        #expect(maxChannelError(before, after) == 0)
    }

    @Test func deformedImageUnchangedImmediatelyAfterSubdivision() throws {
        let source = try checkerboard(width: 80, height: 80, cell: 10)
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0)
        let handle = centerIndex(of: mesh)
        let moved = mesh.tryMove(index: handle, to: mesh.positions[handle] + SIMD2(0.07, -0.05),
                                 imageWidth: 80, imageHeight: 80)
        #expect(moved)
        let before = try rgba8(try render(source, mesh: mesh))
        // Subdivide a face away from the handle's cell if possible; still must preserve mapping.
        let face = mesh.topology.rootFaceIDs[0]
        let result = mesh.subdivide(faceIDs: [face])
        #expect(!result.succeeded.isEmpty)
        let after = try rgba8(try render(source, mesh: mesh))
        #expect(maxChannelError(before, after) <= 1)
    }

    @Test func childPointMovementProducesLocalizedDeformation() throws {
        let source = try checkerboard(width: 64, height: 64, cell: 8)
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        let face = mesh.topology.rootFaceIDs[20]
        let subdivChild = mesh.subdivide(faceIDs: [face])
        #expect(!subdivChild.succeeded.isEmpty)
        let children = try #require(mesh.topology.faces[face]?.children)
        let centerID = mesh.topology.faces[children[0]]!.corners[2] // center of TL child == shared center
        // Find true center: child TL corners [c0, m01, center, m30]
        let trueCenter = mesh.topology.faces[children[0]]!.corners[2]
        let index = try #require(mesh.index(of: trueCenter))
        let before = try rgba8(try render(source, mesh: mesh))
        let ok = mesh.tryMove(index: index, to: mesh.positions[index] + SIMD2(0.04, 0.03),
                              imageWidth: 64, imageHeight: 64)
        #expect(ok)
        let after = try rgba8(try render(source, mesh: mesh))
        #expect(before != after)
        _ = centerID
    }

    @Test func validMergeRestoresParentLeaf() {
        var mesh = MeshWarpGrid.identity(preset: .points8)
        let face = mesh.topology.rootFaceIDs[5]
        let subdivMerge = mesh.subdivide(faceIDs: [face])
        #expect(!subdivMerge.succeeded.isEmpty)
        let children = Set(mesh.topology.faces[face]!.children!)
        let merge = mesh.merge(faceIDs: children)
        #expect(merge.succeeded.contains(face))
        #expect(mesh.topology.faces[face]?.isLeaf == true)
    }

    @Test func incompleteMergeRejected() {
        var mesh = MeshWarpGrid.identity(preset: .points8)
        let face = mesh.topology.rootFaceIDs[5]
        let subdivIncomplete = mesh.subdivide(faceIDs: [face])
        #expect(!subdivIncomplete.succeeded.isEmpty)
        let children = mesh.topology.faces[face]!.children!
        let merge = mesh.merge(faceIDs: [children[0], children[1]])
        #expect(merge.succeeded.isEmpty)
        #expect(!merge.rejected.isEmpty)
        #expect(mesh.topology.faces[face]?.isLeaf == false)
    }

    @Test func mergeRejectedWhenChildVerticesDeformed() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        let face = mesh.topology.rootFaceIDs[12]
        let subdivDeform = mesh.subdivide(faceIDs: [face])
        #expect(!subdivDeform.succeeded.isEmpty)
        let children = mesh.topology.faces[face]!.children!
        let center = mesh.topology.faces[children[0]]!.corners[2]
        let index = mesh.index(of: center)!
        let movedCenter = mesh.tryMove(index: index, to: mesh.positions[index] + SIMD2(0.05, 0.04),
                                       imageWidth: 100, imageHeight: 100)
        #expect(movedCenter)
        let merge = mesh.merge(faceIDs: Set(children))
        #expect(merge.succeeded.isEmpty)
        #expect(merge.rejected.contains(where: { $0.reason.contains("deformed") }))
    }

    @Test func topologyUndoRedoViaEditHistory() throws {
        let source = try checkerboard(width: 48, height: 48, cell: 6)
        let session = EditorSession()
        session.createDocument(width: 48, height: 48)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Topo"))
        session.beginMeshWarp(preset: .points8)
        let edit = try #require(session.meshWarpEdit)
        let face = edit.mesh.topology.rootFaceIDs[3]
        edit.selection.selectOnly(index: 0, in: edit.mesh)
        // Select verts of the face so subdivideSelection finds it.
        edit.selection.clear()
        for corner in edit.mesh.topology.faces[face]!.corners {
            edit.selection.add(corner)
        }
        let beforeLeaves = edit.mesh.topology.leafFaceIDs.count
        let result = edit.subdivideSelection()
        #expect(!result.succeeded.isEmpty)
        #expect(edit.mesh.topology.leafFaceIDs.count != beforeLeaves)
        #expect(edit.toolUndo())
        #expect(edit.mesh.topology.faces[face]?.isLeaf == true)
        #expect(edit.toolRedo())
        #expect(edit.mesh.topology.faces[face]?.isLeaf == false)
    }

    @Test func stickyBordersAfterSubdivision() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0)
        let face = mesh.topology.rootFaceIDs[0] // includes image corner
        let subdivSticky = mesh.subdivide(faceIDs: [face])
        #expect(!subdivSticky.succeeded.isEmpty)
        // Original corner vertex remains pinned.
        let cornerIndex = mesh.index(of: MeshWarpVertexID(0))!
        #expect(mesh.isCorner(cornerIndex))
        let cornerMove = mesh.tryMove(index: cornerIndex, to: SIMD2(0.2, 0.2), imageWidth: 64, imageHeight: 64)
        #expect(cornerMove == false)
    }

    @Test func propagationAfterSubdivision() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.5)
        let face = mesh.topology.rootFaceIDs[24]
        let subdivProp = mesh.subdivide(faceIDs: [face])
        #expect(!subdivProp.succeeded.isEmpty)
        let children = mesh.topology.faces[face]!.children!
        let center = mesh.topology.faces[children[0]]!.corners[2]
        let index = mesh.index(of: center)!
        let neighbor = (0..<mesh.pointCount).first { $0 != index && !mesh.isBorder($0) }!
        let before = mesh.positions[neighbor]
        let movedProp = mesh.tryMove(index: index, to: mesh.positions[index] + SIMD2(0.04, 0.03),
                                     imageWidth: 128, imageHeight: 128)
        #expect(movedProp)
        #expect(mesh.positions[neighbor] != before)
    }

    @Test func cpuGpuParityAfterSubdivision() throws {
        guard MetalMeshWarp.shared != nil else { return }
        let width = 64, height = 64
        let source = try checkerboard(width: width, height: height, cell: 4)
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.2)
        let subdivParity = mesh.subdivide(faceIDs: [mesh.topology.rootFaceIDs[15]])
        #expect(!subdivParity.succeeded.isEmpty)
        let movedParity = mesh.tryMove(index: centerIndex(of: mesh), to: SIMD2(0.55, 0.45),
                                       imageWidth: width, imageHeight: height)
        #expect(movedParity)
        let cpu = try rgba8(try render(source, mesh: mesh))
        let sourceBytes = try rgba8(source)
        var gpu = [UInt8](repeating: 0, count: width * height * 4)
        let ok = sourceBytes.withUnsafeBufferPointer { src in
            gpu.withUnsafeMutableBufferPointer { dst in
                MetalMeshWarp.shared!.apply(source: src.baseAddress!, destination: dst.baseAddress!,
                                            width: width, height: height, stride: width * 4, mesh: mesh)
            }
        }
        #expect(ok)
        #expect(maxChannelError(cpu, gpu) <= maximumChannelError)
    }

    @Test func cancelAfterSubdivisionLeavesDocumentUntouched() throws {
        let source = try checkerboard(width: 40, height: 40, cell: 5)
        let session = EditorSession()
        session.createDocument(width: 40, height: 40)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Cancel"))
        let before = try rgba8(source)
        session.beginMeshWarp(preset: .points4)
        let edit = try #require(session.meshWarpEdit)
        _ = edit.mesh.subdivide(faceIDs: [edit.mesh.topology.rootFaceIDs[0]])
        edit.mesh = edit.mesh // keep
        session.cancelMeshWarp()
        let after = try rgba8(try #require(session.activeLayer?.asset?.image))
        #expect(before == after)
    }
}
