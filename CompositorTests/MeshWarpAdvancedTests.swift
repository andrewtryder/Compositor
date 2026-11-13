import AppKit
import Foundation
import Testing
@testable import Compositor

@Suite(.serialized)
@MainActor
struct MeshWarpAdvancedTests {
    private func centerIndex(of mesh: MeshWarpGrid) -> Int {
        mesh.index(column: mesh.pointColumns / 2, row: mesh.pointRows / 2)
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

    // MARK: - Propagation formula

    @Test func propagationWeightMatchesRecoveredFormula() {
        let n: Float = 1000
        // p = 0 → only d ≈ 0 keeps weight 1
        #expect(MeshWarpGrid.propagationWeight(distancePixels: 0, propagation: 0, extentPixels: n) == 1)
        #expect(MeshWarpGrid.propagationWeight(distancePixels: 1, propagation: 0, extentPixels: n) == 0)
        #expect(MeshWarpGrid.propagationWeight(distancePixels: 100, propagation: 0, extentPixels: n) == 0)
        // p = 1 → global
        #expect(MeshWarpGrid.propagationWeight(distancePixels: 0, propagation: 1, extentPixels: n) == 1)
        #expect(MeshWarpGrid.propagationWeight(distancePixels: 500, propagation: 1, extentPixels: n) == 1)
        #expect(MeshWarpGrid.propagationWeight(distancePixels: 9999, propagation: 1, extentPixels: n) == 1)
        // Intermediate: exact sample
        // w = 1 + (0.5 - 1) * 250 / (1000 * 0.5 + 0.0001) = 1 - 250 / 500.0001
        let w = MeshWarpGrid.propagationWeight(distancePixels: 250, propagation: 0.5, extentPixels: n)
        let expected = 1 + (0.5 - 1) * 250 / (n * 0.5 + MeshWarpGrid.propagationEpsilon)
        #expect(abs(w - expected) < 1e-5)
        #expect(w > 0 && w < 1)
    }

    @Test func propagationZeroMovesOnlyHandle() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0)
        let handle = centerIndex(of: mesh)
        let neighbor = mesh.index(column: mesh.pointColumns / 2 + 1, row: mesh.pointRows / 2)
        let before = mesh.positions[neighbor]
        let ok = mesh.tryMove(index: handle, to: mesh.positions[handle] + SIMD2(0.06, -0.04),
                              imageWidth: 200, imageHeight: 200)
        #expect(ok)
        #expect(mesh.positions[neighbor] == before)
        #expect(mesh.positions[handle] != mesh.rest[handle])
    }

    @Test func propagationOneMovesGlobalInterior() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 1)
        let handle = centerIndex(of: mesh)
        let far = mesh.index(column: 1, row: 1)
        let before = mesh.positions[far]
        let ok = mesh.tryMove(index: handle, to: mesh.positions[handle] + SIMD2(0.05, 0.04),
                              imageWidth: 200, imageHeight: 200)
        #expect(ok)
        #expect(mesh.positions[far] != before)
    }

    @Test func repeatedDragFromBaseDoesNotAccumulateDrift() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.5)
        let handle = centerIndex(of: mesh)
        let neighbor = mesh.index(column: mesh.pointColumns / 2 + 1, row: mesh.pointRows / 2)
        let base = mesh.positions
        let target = base[handle] + SIMD2(0.08, -0.05)
        for _ in 0..<12 {
            let stepOK = mesh.tryMove(index: handle, to: target, imageWidth: 256, imageHeight: 256, base: base)
            #expect(stepOK)
        }
        let once = mesh.positions[neighbor]
        var again = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.5)
        let againOK = again.tryMove(index: handle, to: target, imageWidth: 256, imageHeight: 256, base: base)
        #expect(againOK)
        #expect(abs(again.positions[neighbor].x - once.x) < 1e-5)
        #expect(abs(again.positions[neighbor].y - once.y) < 1e-5)
    }

    // MARK: - Sticky borders

    @Test func stickyCornersRemainPinned() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.8)
        let corner = mesh.index(column: 0, row: 0)
        #expect(mesh.borderKind(corner) == .corner)
        let cornerRejected = mesh.tryMove(index: corner, to: SIMD2(0.1, 0.1), imageWidth: 100, imageHeight: 100)
        #expect(!cornerRejected)
        let handle = centerIndex(of: mesh)
        let moved = mesh.tryMove(index: handle, to: mesh.positions[handle] + SIMD2(0.05, 0.05),
                                 imageWidth: 100, imageHeight: 100)
        #expect(moved)
        #expect(mesh.positions[corner] == mesh.rest[corner])
    }

    @Test func stickyEdgeSlidesAlongEdge() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0)
        let left = mesh.index(column: 0, row: 3)
        #expect(mesh.borderKind(left) == .leftEdge)
        let ok = mesh.tryMove(index: left, to: SIMD2(0.4, 0.55), imageWidth: 100, imageHeight: 100)
        #expect(ok)
        #expect(abs(mesh.positions[left].x) < 1e-6)
        #expect(abs(mesh.positions[left].y - 0.55) < 1e-5)

        let top = mesh.index(column: 3, row: 0)
        #expect(mesh.borderKind(top) == .topEdge)
        let topOK = mesh.tryMove(index: top, to: SIMD2(0.4, 0.3), imageWidth: 100, imageHeight: 100)
        #expect(topOK)
        #expect(abs(mesh.positions[top].y) < 1e-6)
        #expect(abs(mesh.positions[top].x - 0.4) < 1e-5)
    }

    @Test func stickyAllFourEdgesAndCorners() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0)
        let corners = [
            mesh.index(column: 0, row: 0),
            mesh.index(column: 7, row: 0),
            mesh.index(column: 0, row: 7),
            mesh.index(column: 7, row: 7),
        ]
        for c in corners {
            let rejected = mesh.tryMove(index: c, to: SIMD2(0.5, 0.5), imageWidth: 64, imageHeight: 64)
            #expect(!rejected)
        }
        // Fresh mesh per edge so sequential slides cannot fold neighboring cells.
        let edgeMoves: [(Int, Int, SIMD2<Float>)] = [
            (0, 2, SIMD2(0.2, 0.02)),  // left: keep x=0, nudge y
            (7, 2, SIMD2(-0.2, -0.02)), // right
            (2, 0, SIMD2(0.02, 0.2)),  // top: keep y=0, nudge x
            (2, 7, SIMD2(-0.02, -0.2)), // bottom
        ]
        for (column, row, delta) in edgeMoves {
            var edgeMesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0)
            let e = edgeMesh.index(column: column, row: row)
            let target = edgeMesh.positions[e] + delta
            let slid = edgeMesh.tryMove(index: e, to: target, imageWidth: 64, imageHeight: 64)
            #expect(slid, "edge \(column),\(row)")
            #expect(edgeMesh.isBorder(e))
            switch edgeMesh.borderKind(e) {
            case .leftEdge: #expect(abs(edgeMesh.positions[e].x) < 1e-6)
            case .rightEdge: #expect(abs(edgeMesh.positions[e].x - 1) < 1e-6)
            case .topEdge: #expect(abs(edgeMesh.positions[e].y) < 1e-6)
            case .bottomEdge: #expect(abs(edgeMesh.positions[e].y - 1) < 1e-6)
            default: Issue.record("expected edge kind")
            }
        }
    }

    // MARK: - Selection

    @Test func selectionUsesStableVertexIDs() {
        var selection = MeshWarpSelection()
        selection.selectOnly(index: 5)
        selection.toggle(index: 7)
        #expect(selection.contains(index: 5))
        #expect(selection.contains(index: 7))
        selection.toggle(index: 5)
        #expect(!selection.contains(index: 5))
        selection.selectAll(pointCount: 16)
        #expect(selection.count == 16)
        selection.clear()
        #expect(selection.isEmpty)

        let mesh = MeshWarpGrid.identity(preset: .points8)
        selection.selectMarquee(uvRect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                                mesh: mesh, additive: false)
        #expect(!selection.isEmpty)
        // Zoom / image size do not change ID meaning:
        #expect(selection.ids.allSatisfy { $0.rawValue >= 0 && $0.rawValue < mesh.pointCount })
    }

    // MARK: - Move / Rotate / Scale

    @Test func rotateSelectionAboutBarycenter() throws {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        let a = mesh.index(column: 3, row: 3)
        let b = mesh.index(column: 4, row: 3)
        let selected: Set<Int> = [a, b]
        let base = mesh.positions
        let pivot = try #require(MeshWarpGrid.barycenter(indices: selected, in: base))
        // Modest angle keeps the regular lattice free of folds.
        let angle = Float.pi / 12
        let rotated = mesh.applySelectionTransform(selected: selected, imageWidth: 128, imageHeight: 128, base: base) { point in
            let relative = point - pivot
            let c = cos(angle), s = sin(angle)
            return pivot + SIMD2(relative.x * c - relative.y * s, relative.x * s + relative.y * c)
        }
        #expect(rotated)
        let mid = (mesh.positions[a] + mesh.positions[b]) * 0.5
        #expect(abs(mid.x - pivot.x) < 1e-4)
        #expect(abs(mid.y - pivot.y) < 1e-4)
        let beforeDist = MeshWarpGrid.pixelDistance(base[a], base[b], width: 128, height: 128)
        let afterDist = MeshWarpGrid.pixelDistance(mesh.positions[a], mesh.positions[b], width: 128, height: 128)
        #expect(abs(beforeDist - afterDist) < 1e-3)
        // Unselected with prop 0 stay put
        let other = mesh.index(column: 1, row: 1)
        #expect(mesh.positions[other] == base[other])
    }

    @Test func uniformScaleSelectionWithPropagation() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.6)
        let selected: Set<Int> = [
            mesh.index(column: 3, row: 3),
            mesh.index(column: 4, row: 3),
            mesh.index(column: 3, row: 4),
            mesh.index(column: 4, row: 4),
        ]
        let base = mesh.positions
        guard let pivot = MeshWarpGrid.barycenter(indices: selected, in: base) else {
            Issue.record("missing barycenter")
            return
        }
        let neighbor = mesh.index(column: 2, row: 3)
        let before = base[neighbor]
        let scaled = mesh.applySelectionTransform(selected: selected, imageWidth: 200, imageHeight: 200, base: base) { point in
            pivot + (point - pivot) * 1.25
        }
        #expect(scaled)
        #expect(mesh.positions[neighbor] != before)
        // Corners stay pinned under sticky
        let corner = mesh.index(column: 0, row: 0)
        #expect(mesh.positions[corner] == mesh.rest[corner])
    }

    @Test func invalidFoldingTransformRejected() {
        var mesh = MeshWarpGrid.identity(preset: .points4, stickyBorders: false, propagation: 0)
        let selected: Set<Int> = [mesh.index(column: 1, row: 1)]
        let base = mesh.positions
        let target = base[mesh.index(column: 2, row: 1)]
        let ok = mesh.applySelectionTransform(selected: selected, imageWidth: 64, imageHeight: 64, base: base) { _ in
            target
        }
        #expect(!ok)
        #expect(mesh.positions == base)
    }

    // MARK: - Tool-local history

    @Test func toolLocalHistoryUndoRedo() throws {
        let source = try checkerboard(width: 64, height: 48)
        let session = EditorSession()
        session.createDocument(width: 64, height: 48)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Hist"))
        session.beginMeshWarp(preset: .points8)
        let edit = try #require(session.meshWarpEdit)
        let handle = centerIndex(of: edit.mesh)
        edit.beginGesture()
        #expect(edit.moveSelected(toPrimaryDestination: edit.mesh.positions[handle] + SIMD2(0.07, -0.05),
                                   primary: handle))
        edit.endGesture()
        #expect(!edit.mesh.isIdentity)
        #expect(edit.history.canUndo)
        #expect(edit.toolUndo())
        #expect(edit.mesh.isIdentity)
        #expect(edit.toolRedo())
        #expect(!edit.mesh.isIdentity)
        // Cancel does not touch document history
        let before = try MeshWarpRaster.rgba8Bytes(from: source)
        session.cancelMeshWarp()
        #expect(session.meshWarpEdit == nil)
        let after = try MeshWarpRaster.rgba8Bytes(from: try #require(session.activeLayer?.asset?.image))
        #expect(before == after)
    }

    // MARK: - Subdivide / Merge

    @Test func subdivideMergeSupportedOnAdaptiveTopology() {
        #expect(MeshWarpGrid.topologyOpsSupported)
        var mesh = MeshWarpGrid.identity(preset: .points8)
        let face = mesh.topology.rootFaceIDs[mesh.topology.rootFaceIDs.count / 2]
        let result = mesh.subdivide(faceIDs: [face])
        #expect(!result.succeeded.isEmpty)
        #expect(mesh.isAdaptive)
    }

    // MARK: - Parity still holds with new propagation

    @Test func cpuGpuParityWithLinearPropagation() throws {
        guard MetalMeshWarp.shared != nil else { return }
        let width = 80, height = 64
        let source = try checkerboard(width: width, height: height, cell: 4)
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.35)
        let moved = mesh.tryMove(index: centerIndex(of: mesh),
                                 to: SIMD2(0.58, 0.42),
                                 imageWidth: width, imageHeight: height)
        #expect(moved)
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
        for i in cpuBytes.indices {
            maxDiff = max(maxDiff, abs(Int(cpuBytes[i]) - Int(gpuBytes[i])))
        }
        #expect(maxDiff <= 1)
    }
}
