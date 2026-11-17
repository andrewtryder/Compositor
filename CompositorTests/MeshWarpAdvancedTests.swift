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

    // MARK: - Exposed selection and transform interaction (M10.7)

    private func sessionWithMesh(width: Int = 96, height: Int = 72) throws -> (EditorSession, MeshWarpEdit) {
        let source = try checkerboard(width: width, height: height)
        let session = EditorSession()
        session.createDocument(width: width, height: height)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Expose"))
        session.beginMeshWarp(preset: .points8)
        let edit = try #require(session.meshWarpEdit)
        return (session, edit)
    }

    /// UV of a lattice vertex in document points for a document sized to the source image.
    private func documentPoint(_ edit: MeshWarpEdit, column: Int, row: Int) -> CGPoint {
        // transform.point maps UV (0…1) into document space; build the UV directly.
        let uv = CGPoint(x: CGFloat(column) / CGFloat(edit.mesh.pointColumns - 1),
                         y: CGFloat(row) / CGFloat(edit.mesh.pointRows - 1))
        return edit.transform.point(uv)
    }

    @Test func marqueeSelectsAndClearsThroughSession() throws {
        let (session, edit) = try sessionWithMesh(width: 96, height: 96)
        // The lattice spans the whole layer, whose transform fills the 96×96 document, so a vertex
        // at rest UV (c/7, r/7) sits at (c/7·96, r/7·96) points. A window over columns 2–4, rows 2–4
        // catches exactly those nine vertices.
        let spacing = 96.0 / 7.0
        let rect = CGRect(x: spacing * 1.9, y: spacing * 1.9,
                          width: spacing * 2.2, height: spacing * 2.2)
        session.meshWarpSelectMarquee(documentRect: rect, additive: false)
        #expect(edit.selection.indices(in: edit.mesh).count == 9,
                "the window covers the 3×3 block of vertices, corners included")

        session.meshWarpClearSelection()
        #expect(edit.selection.indices(in: edit.mesh).isEmpty)
        #expect(edit.selectedIndex == nil)
    }

    @Test func marqueeDragThroughSessionSelectsRegion() throws {
        let (session, edit) = try sessionWithMesh(width: 96, height: 96)
        let spacing = 96.0 / 7.0
        session.meshWarpBeginMarquee(at: CGPoint(x: spacing * 1.9, y: spacing * 1.9), additive: false)
        session.meshWarpContinueMarquee(to: CGPoint(x: spacing * 4.1, y: spacing * 4.1))
        #expect(edit.marqueeDraft != nil, "the overlay has a rectangle to draw while the drag runs")
        session.meshWarpEndMarquee()
        #expect(edit.marqueeDraft == nil)
        #expect(edit.selection.indices(in: edit.mesh).count == 9)
    }

    @Test func shiftClickTogglesThroughSession() throws {
        let (session, edit) = try sessionWithMesh(width: 96, height: 96)
        let a = edit.mesh.index(column: 3, row: 3)
        let pixel = documentPoint(edit, column: 3, row: 3)
        #expect(session.meshWarpBeginDrag(at: pixel, viewRadius: 6, viewportScale: 1, shift: false))
        session.meshWarpEndDrag()
        #expect(edit.selection.indices(in: edit.mesh) == [a])

        let b = edit.mesh.index(column: 4, row: 3)
        let pixelB = documentPoint(edit, column: 4, row: 3)
        #expect(session.meshWarpBeginDrag(at: pixelB, viewRadius: 6, viewportScale: 1, shift: true))
        #expect(edit.selection.contains(index: b, in: edit.mesh), "Shift adds the second point")
        session.meshWarpEndDrag()
        #expect(edit.selection.count == 2)

        // Shift again removes it.
        #expect(session.meshWarpBeginDrag(at: pixelB, viewRadius: 6, viewportScale: 1, shift: true))
        #expect(!edit.selection.contains(index: b, in: edit.mesh))
        session.meshWarpEndDrag()
        #expect(edit.selection.count == 1)
    }

    @Test func selectAllThenMoveMovesWholeInterior() throws {
        let (session, edit) = try sessionWithMesh(width: 96, height: 96)
        session.meshWarpSelectAll()
        #expect(edit.selection.count == edit.mesh.pointCount)

        edit.beginGesture()
        let handle = edit.mesh.index(column: 4, row: 4)
        let moved = edit.transformSelection(mode: .move, translation: SIMD2(0.03, 0.02))
        #expect(moved)
        edit.endGesture()
        #expect(edit.history.canUndo)
        // Corners stay pinned under sticky borders; interior points moved.
        #expect(edit.mesh.positions[0] == edit.mesh.rest[0])
        #expect(edit.mesh.positions[handle] != edit.mesh.rest[handle])
    }

    @Test func rotateAndScaleFromBarycenterWithoutDrift() throws {
        let (session, edit) = try sessionWithMesh(width: 128, height: 128)
        for row in 2...5 {
            for column in 2...5 {
                edit.selection.add(edit.mesh.vertexID(edit.mesh.index(column: column, row: row)))
            }
        }
        edit.mesh.stickyBorders = false
        edit.beginGesture()
        // Ten half-angle steps from the same base must land exactly where ten full halves do:
        // the session's gesture-base rule means each update re-measures from the gesture start.
        let half: Float = .pi / 24
        for _ in 0..<10 {
            #expect(session.meshWarpRotateSelection(by: half))
        }
        edit.endGesture()
        let rotated = edit.mesh.positions

        var fresh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false,
                                          propagation: edit.mesh.propagation)
        let base = fresh.positions
        let selected = Set((2...5).flatMap { row in (2...5).map { fresh.index(column: $0, row: row) } })
        let pivot = MeshWarpGrid.barycenter(indices: selected, in: base)!
        _ = fresh.applySelectionTransform(selected: selected, imageWidth: 128, imageHeight: 128, base: base) { point in
            let relative = point - pivot
            let c = cos(half), s = sin(half)
            return pivot + SIMD2(relative.x * c - relative.y * s, relative.x * s + relative.y * c)
        }
        #expect(zip(rotated, fresh.positions).allSatisfy { abs($0.x - $1.x) < 1e-5 && abs($0.y - $1.y) < 1e-5 },
                "the last write matches the single-step result to float precision")
    }

    /// The pivot a gesture rotates about has to be the same however the selection set happens to iterate, or the
    /// drift test above becomes a coin toss on the set's hash order.
    @Test func barycenterIgnoresSelectionIterationOrder() throws {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        let selected = Set((2...5).flatMap { row in (2...5).map { mesh.index(column: $0, row: row) } })
        let base = mesh.positions
        let pivot = try #require(MeshWarpGrid.barycenter(indices: selected, in: base))

        // The same vertices inserted in a different order must give the identical pivot, bit for bit.
        var reversed: [Int] = []
        for row in (2...5).reversed() {
            for column in (2...5).reversed() { reversed.append(mesh.index(column: column, row: row)) }
        }
        let other = try #require(MeshWarpGrid.barycenter(indices: Set(reversed), in: base))
        #expect(pivot == other, "the float sum cannot depend on set order")

        // And it is the true mean, not merely a repeatable one.
        let count = Double(selected.count)
        let meanX = selected.reduce(0.0) { $0 + Double(base[$1].x) } / count
        let meanY = selected.reduce(0.0) { $0 + Double(base[$1].y) } / count
        #expect(abs(Double(pivot.x) - meanX) < 1e-7 && abs(Double(pivot.y) - meanY) < 1e-7)
        _ = mesh
    }

    @Test func foldingRotationIsRefusedAndLeavesMeshUnchanged() throws {
        let (session, edit) = try sessionWithMesh(width: 64, height: 64)
        let selected: Set<Int> = [edit.mesh.index(column: 3, row: 3), edit.mesh.index(column: 4, row: 3)]
        for index in selected { edit.selection.add(edit.mesh.vertexID(index)) }
        edit.mesh.stickyBorders = false
        let before = edit.mesh.positions
        edit.beginGesture()
        #expect(!session.meshWarpRotateSelection(by: .pi), "a half-turn folds the two-cell strip")
        // The refused gesture leaves the mesh where it was and records nothing.
        #expect(edit.mesh.positions == before)
        #expect(edit.history.canUndo == false)
        edit.cancelGesture()
    }

    @Test func scaleGestureFromBarycenterScalesSelection() throws {
        let (session, edit) = try sessionWithMesh(width: 128, height: 128)
        for row in 3...4 {
            for column in 3...4 {
                edit.selection.add(edit.mesh.vertexID(edit.mesh.index(column: column, row: row)))
            }
        }
        edit.beginGesture()
        #expect(session.meshWarpScaleSelection(by: 1.2))
        edit.endGesture()
        #expect(edit.history.canUndo)
        let a = edit.mesh.index(column: 3, row: 3)
        let b = edit.mesh.index(column: 4, row: 3)
        let before = MeshWarpGrid.pixelDistance(edit.mesh.rest[a], edit.mesh.rest[b], width: 128, height: 128)
        let after = MeshWarpGrid.pixelDistance(edit.mesh.positions[a], edit.mesh.positions[b], width: 128, height: 128)
        #expect(abs(after - before * 1.2) < 0.5, "the two selected columns are 1.2× farther apart in pixels")
        #expect(edit.toolUndo())
        #expect(edit.mesh.positions[a] == edit.mesh.rest[a], "Undo puts the gesture back")
    }

    @Test func escapeCancelsInFlightGestureWithoutHistory() throws {
        let (session, edit) = try sessionWithMesh(width: 96, height: 96)
        let handle = edit.mesh.index(column: 3, row: 3)
        edit.beginGesture()
        #expect(edit.moveSelected(toPrimaryDestination: edit.mesh.positions[handle] + SIMD2(0.08, 0.06),
                                  primary: handle))
        #expect(!edit.mesh.isIdentity)
        // The canvas maps Escape here; the session call it makes is what the test exercises.
        session.meshWarpCancelGesture()
        #expect(edit.mesh.isIdentity, "the dragged state is gone")
        #expect(edit.history.canUndo == false, "a cancelled gesture records nothing")
        #expect(edit.gestureBasePositions == nil)
    }

    @Test func nonFiniteRotateAndScaleAreRefused() throws {
        let (session, edit) = try sessionWithMesh(width: 64, height: 64)
        edit.selection.add(edit.mesh.vertexID(edit.mesh.index(column: 3, row: 3)))
        edit.beginGesture()
        let before = edit.mesh.positions
        #expect(!session.meshWarpRotateSelection(by: .nan))
        #expect(!session.meshWarpScaleSelection(by: .nan))
        #expect(!session.meshWarpScaleSelection(by: 0))
        #expect(!session.meshWarpScaleSelection(by: -1.5))
        #expect(edit.mesh.positions == before)
        edit.cancelGesture()
    }

    @Test func toolUndoRedoRestoresSelection() throws {
        let (session, edit) = try sessionWithMesh(width: 96, height: 96)
        let handle = edit.mesh.index(column: 3, row: 3)
        edit.selection.selectOnly(index: handle, in: edit.mesh)
        edit.beginGesture()
        #expect(edit.moveSelected(toPrimaryDestination: edit.mesh.positions[handle] + SIMD2(0.05, -0.04),
                                  primary: handle))
        edit.endGesture()
        let movedSelection = edit.selection
        #expect(movedSelection.count == 1)

        session.meshWarpClearSelection()
        #expect(edit.selection.isEmpty)
        #expect(edit.toolUndo())
        #expect(edit.selection == movedSelection, "Undo restores the selection alongside the mesh")
        #expect(edit.toolRedo())
        #expect(edit.selection.isEmpty, "Redo replays the clear")
    }

    @Test func subdivideMergeButtonsRouteThroughSessionWithReasons() throws {
        let (session, edit) = try sessionWithMesh(width: 96, height: 96)
        // No selection: the button reports a meaningful refusal rather than silently doing nothing.
        let empty = edit.subdivideSelection()
        #expect(empty.succeeded.isEmpty)

        // A single interior vertex subdivides only the cells it touches.
        edit.selection.selectOnly(index: edit.mesh.index(column: 4, row: 4), in: edit.mesh)
        let leavesBefore = edit.mesh.topology.leafFaceIDs.count
        let result = edit.subdivideSelection()
        #expect(!result.succeeded.isEmpty)
        #expect(edit.mesh.topology.leafFaceIDs.count > leavesBefore)
        #expect(edit.mesh.topology.leafFaceIDs.count == leavesBefore + 12,
                "four faces each split 1→4 (net +3 leaves each)")
        #expect(edit.history.canUndo)

        // Merge needs a complete child group; a fresh lattice has none, so the reason says so.
        let merge = edit.mergeSelection()
        #expect(merge.succeeded.isEmpty)
        #expect(!merge.rejected.isEmpty)

        // Selecting the subdivided parent's four children completes the group and merges back.
        let parent = result.succeeded[0]
        let children = edit.mesh.topology.faces[parent]!.children!
        edit.selection.clear()
        for child in children {
            for corner in edit.mesh.topology.faces[child]!.corners {
                edit.selection.add(corner)
            }
        }
        let mergeComplete = edit.mergeSelection()
        #expect(mergeComplete.succeeded.contains(parent))
        #expect(edit.mesh.topology.faces[parent]?.isLeaf == true)
    }

    @Test func localCorrectionsApplyToSelectionOnly() throws {
        let (session, edit) = try sessionWithMesh(width: 128, height: 128)
        edit.mesh.stickyBorders = false
        edit.mesh.propagation = 0
        var ids: Set<MeshWarpVertexID> = []
        for row in 3...4 {
            for column in 3...4 {
                ids.insert(edit.mesh.vertexID(edit.mesh.index(column: column, row: row)))
            }
        }
        edit.selection = MeshWarpSelection()
        for id in ids { edit.selection.add(id) }
        let far = edit.mesh.index(column: 1, row: 6)
        let farBefore = edit.mesh.positions[far]

        let perspective = session.applyMeshWarpLocalCorrection(
            .perspective(MeshWarpLocalPerspective(mode: .vertical, amount: 0.3)))
        #expect(perspective.ok, "\(perspective.reason)")
        #expect(edit.history.canUndo)

        let horizon = session.applyMeshWarpLocalCorrection(
            .horizon(MeshWarpLocalHorizon(mode: .angle, angleDegrees: 4, amount: 0.5)))
        #expect(horizon.ok, "\(horizon.reason)")

        let volume = session.applyMeshWarpLocalCorrection(
            .volume(MeshWarpLocalVolume(mode: .combined, strength: 0.15, strengthVertical: 0.1)))
        #expect(volume.ok, "\(volume.reason)")

        // Propagation 0: the untouched corner stays exactly where it was.
        #expect(edit.mesh.positions[far] == farBefore)

        // Three completed operations, three undo steps.
        #expect(edit.toolUndo())
        #expect(edit.toolUndo())
        #expect(edit.toolUndo())
        #expect(edit.mesh.isIdentity, "three undos return the mesh to rest")
    }

    @Test func horizonReferenceDragFeedsLocalHorizon() throws {
        let (session, edit) = try sessionWithMesh(width: 96, height: 96)
        for row in 3...4 {
            for column in 3...4 {
                edit.selection.add(edit.mesh.vertexID(edit.mesh.index(column: column, row: row)))
            }
        }
        edit.mesh.stickyBorders = false

        // Armed, the next drag draws the reference; the canvas calls these three in order.
        session.meshWarpBeginHorizonReference()
        session.meshWarpBeginHorizonDrag(at: CGPoint(x: 20, y: 40))
        session.meshWarpContinueHorizonDrag(to: CGPoint(x: 70, y: 30))
        session.meshWarpEndHorizonDrag()
        #expect(edit.horizonReference != nil, "a long enough line commits")
        #expect(edit.horizonReferenceDraft == nil)
        #expect(edit.isDrawingHorizonReference == false)

        let correction = try #require(session.meshWarpLocalHorizonCorrection(
            mode: .horizontalReference, angleDegrees: 0, amount: 0.4))
        // The drawn line rises to the right in document space (y down), so levelling turns clockwise
        // in image pixels; the endpoints arrive in layer pixels either way.
        #expect(correction.referenceA != correction.referenceB)
        let status = session.applyMeshWarpLocalCorrection(.horizon(correction))
        #expect(status.ok, "\(status.reason)")

        // A second, too-short line is discarded rather than committed.
        session.meshWarpBeginHorizonReference()
        session.meshWarpBeginHorizonDrag(at: CGPoint(x: 30, y: 40))
        session.meshWarpContinueHorizonDrag(to: CGPoint(x: 30.5, y: 40))
        session.meshWarpEndHorizonDrag()
        #expect(edit.horizonReference == nil, "a line too short to read an angle is dropped")
    }

    @Test func fourPointNeedsFourSelectedVerticesAndApplies() throws {
        let (session, edit) = try sessionWithMesh(width: 128, height: 128)
        edit.mesh.stickyBorders = false
        // One vertex only: the action refuses with a reason instead of guessing.
        edit.selection.selectOnly(index: edit.mesh.index(column: 3, row: 3), in: edit.mesh)
        session.meshWarpBeginQuadDestination()
        session.meshWarpBeginQuadDrag(at: CGPoint(x: 20, y: 20))
        session.meshWarpContinueQuadDrag(to: CGPoint(x: 60, y: 60))
        session.meshWarpEndQuadDrag()
        let refused = session.meshWarpApplyQuadDestination()
        #expect(!refused.ok)
        #expect(refused.reason.contains("four"))

        // Four vertices of one cell: the drawn rectangle becomes the destination quad. The source
        // quad is those four points as they stand, so a modestly moved rectangle maps into them
        // without inverting anything.
        let spacing = 128.0 / 7.0
        let cell = edit.mesh.topology.rootFaceIDs[3 * 7 + 3]
        edit.selection.clear()
        for corner in edit.mesh.topology.faces[cell]!.corners {
            edit.selection.add(corner)
        }
        let sourceRect = CGRect(x: spacing * 2.6, y: spacing * 2.6, width: spacing * 0.8, height: spacing * 0.8)
        session.meshWarpBeginQuadDestination()
        session.meshWarpBeginQuadDrag(at: sourceRect.origin)
        session.meshWarpContinueQuadDrag(to: CGPoint(x: sourceRect.maxX, y: sourceRect.maxY))
        session.meshWarpEndQuadDrag()
        #expect(edit.drawnQuadDestination != nil)
        let applied = session.meshWarpApplyQuadDestination()
        #expect(applied.ok, "\(applied.reason)")
        #expect(!edit.mesh.isIdentity)
        #expect(edit.history.canUndo)
        #expect(edit.drawnQuadDestination == nil, "the committed rectangle is cleared")
    }

    @Test func applyAndCancelStillBehave() throws {
        let (session, edit) = try sessionWithMesh(width: 64, height: 64)
        let handle = edit.mesh.index(column: 3, row: 3)
        edit.beginGesture()
        #expect(edit.moveSelected(toPrimaryDestination: edit.mesh.positions[handle] + SIMD2(0.05, 0.04),
                                  primary: handle))
        edit.endGesture()

        // Cancel leaves the layer untouched.
        let before = try MeshWarpRaster.rgba8Bytes(from: try #require(session.activeLayer?.asset?.image))
        session.cancelMeshWarp()
        #expect(session.meshWarpEdit == nil)
        #expect(try MeshWarpRaster.rgba8Bytes(from: try #require(session.activeLayer?.asset?.image)) == before)

        // Apply makes the one document entry, as before.
        session.beginMeshWarp(preset: .points8)
        let second = try #require(session.meshWarpEdit)
        let undoBefore = session.history.undoCount
        let index = second.mesh.index(column: 3, row: 3)
        second.beginGesture()
        #expect(second.moveSelected(toPrimaryDestination: second.mesh.positions[index] + SIMD2(0.05, 0.04),
                                    primary: index))
        second.endGesture()
        session.applyMeshWarp()
        #expect(session.history.undoCount == undoBefore + 1)
        #expect(session.history.undoName == "ReShape")
        #expect(session.activeLayer?.reshape != nil)
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
