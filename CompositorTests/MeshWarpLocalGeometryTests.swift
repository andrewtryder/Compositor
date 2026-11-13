import AppKit
import Foundation
import Testing
@testable import Compositor

@Suite(.serialized)
@MainActor
struct MeshWarpLocalGeometryTests {
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

    private func render(_ source: CGImage, mesh: MeshWarpGrid) throws -> CGImage {
        var timing = MeshWarpRaster.Timing()
        return try #require(MeshWarpRaster.apply(source: source, mesh: mesh, timing: &timing))
    }

    private func selectInterior(mesh: inout MeshWarpGrid, columns: Int = 2, rows: Int = 2) -> MeshWarpCorrectionRegion {
        var ids: Set<MeshWarpVertexID> = []
        let c0 = mesh.pointColumns / 2 - columns / 2
        let r0 = mesh.pointRows / 2 - rows / 2
        for r in r0..<(r0 + rows) {
            for c in c0..<(c0 + columns) {
                ids.insert(mesh.vertexID(mesh.index(column: c, row: r)))
            }
        }
        return MeshWarpCorrectionRegion(vertexIDs: ids, faceIDs: mesh.topology.leafFacesTouching(vertexIDs: ids))
    }

    // MARK: - Adaptive growth (Phase 1)

    @Test func subdivisionGrowthLocalityMatrix() {
        struct Case { let name: String; let pick: (MeshWarpGrid) -> Set<MeshWarpFaceID> }
        for n in [4, 8, 16] {
            let preset = MeshWarpGrid.Preset(rawValue: n)!
            let cols = n - 1
            let cases: [Case] = [
                Case(name: "central") { mesh in
                    [mesh.topology.rootFaceIDs[(cols / 2) * cols + cols / 2]]
                },
                Case(name: "boundary") { mesh in
                    [mesh.topology.rootFaceIDs[0]]
                },
                Case(name: "twoAdjacent") { mesh in
                    let a = mesh.topology.rootFaceIDs[(cols / 2) * cols + cols / 2]
                    let b = mesh.topology.neighbors(of: a)[0]
                    return [a, b]
                },
                Case(name: "distant") { mesh in
                    [mesh.topology.rootFaceIDs[0], mesh.topology.rootFaceIDs[cols * cols - 1]]
                },
            ]
            for testCase in cases {
                var mesh = MeshWarpGrid.identity(preset: preset)
                let faces = testCase.pick(mesh)
                let (result, growth) = mesh.topology.measureSubdivision(faceIDs: faces)
                mesh.syncFromTopology()
                #expect(result.ok, "\(n)×\(n) \(testCase.name)")
                #expect(growth.neighborsRefined == 0, "\(n)×\(n) \(testCase.name) refined neighbors")
                #expect(growth.maxPropagationDistance == 0, "\(n)×\(n) \(testCase.name) cascade")
                #expect(growth.finalVertices < growth.initialVertices + faces.count * 6)
                #expect(growth.finalLeaves < growth.initialLeaves * 2 || n == 4)
            }

            // Nested child refinement stays on one lineage.
            var nested = MeshWarpGrid.identity(preset: preset)
            var face = nested.topology.rootFaceIDs[(cols / 2) * cols + cols / 2]
            let before = nested.pointCount
            for _ in 0..<3 {
                let (result, growth) = nested.topology.measureSubdivision(faceIDs: [face])
                nested.syncFromTopology()
                #expect(result.ok)
                #expect(growth.neighborsRefined == 0)
                face = nested.topology.faces[face]!.children![0]
            }
            // Three nested splits add ≤5 verts each (shared mids may reduce that).
            #expect(nested.pointCount - before <= 20)
            #expect(nested.pointCount < before * 3)
        }
    }

    @Test func budgetRejectsWithoutPartialMutation() {
        var mesh = MeshWarpGrid.identity(preset: .points4)
        // Exhaust depth on one lineage, then demand another level — must leave mesh unchanged.
        var face = mesh.topology.rootFaceIDs[4]
        for _ in 0..<MeshWarpTopology.maxSubdivisionDepth {
            let result = mesh.subdivide(faceIDs: [face])
            #expect(result.ok)
            face = mesh.topology.faces[face]!.children![0]
        }
        let snapshot = mesh
        let rejected = mesh.subdivide(faceIDs: [face])
        #expect(rejected.succeeded.isEmpty)
        #expect(rejected.rejected.contains(where: { $0.reason.contains("depth") }))
        #expect(mesh == snapshot)
    }

    @Test func hangingEdgeFanPreservesNonAffineMapping() throws {
        let source = try checkerboard(width: 64, height: 64, cell: 8)
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        // Non-affine: move two corners of one diagonal differently so the two triangles disagree.
        let i10 = mesh.index(column: 4, row: 3)
        let i01 = mesh.index(column: 3, row: 4)
        let moved10 = mesh.tryMove(index: i10, to: mesh.positions[i10] + SIMD2(0.06, -0.02),
                                   imageWidth: 64, imageHeight: 64)
        let moved01 = mesh.tryMove(index: i01, to: mesh.positions[i01] + SIMD2(-0.03, 0.05),
                                   imageWidth: 64, imageHeight: 64)
        #expect(moved10)
        #expect(moved01)
        let before = try rgba8(try render(source, mesh: mesh))
        let face = mesh.topology.rootFaceIDs[3 * 7 + 3]
        let result = mesh.subdivide(faceIDs: [face])
        #expect(result.ok)
        let after = try rgba8(try render(source, mesh: mesh))
        #expect(maxChannelError(before, after) <= 1)
    }

    // MARK: - Identity

    @Test func localCorrectionsIdentity() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0)
        let region = selectInterior(mesh: &mesh)
        let base = mesh.positions
        for correction in [
            MeshWarpLocalCorrection.perspective(.identity),
            .horizon(.identity),
            .volume(.identity),
            .identity,
        ] {
            var trial = mesh
            let status = trial.applyLocalCorrection(correction, region: region,
                                                    imageWidth: 100, imageHeight: 100, base: base)
            #expect(status.ok)
            #expect(trial.positions == base)
        }
    }

    // MARK: - Perspective

    @Test func localPerspectiveFourPointKnownMapping() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        let region = selectInterior(mesh: &mesh, columns: 3, rows: 3)
        let w: Float = 100, h: Float = 100
        let src: [SIMD2<Float>] = [SIMD2(30, 30), SIMD2(70, 30), SIMD2(70, 70), SIMD2(30, 70)]
        let dst: [SIMD2<Float>] = [SIMD2(32, 28), SIMD2(68, 32), SIMD2(72, 72), SIMD2(28, 68)]
        let perspective = MeshWarpLocalPerspective(mode: .fourPoint, sourceQuad: src,
                                                   destinationQuad: dst, amount: 1)
        let status = mesh.applyLocalCorrection(.perspective(perspective), region: region,
                                               imageWidth: Int(w), imageHeight: Int(h))
        #expect(status.ok)
        #expect(!mesh.isIdentity)
    }

    @Test func localPerspectiveModesAndDegeneracy() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        let region = selectInterior(mesh: &mesh)
        for mode in MeshWarpLocalPerspectiveMode.allCases where mode != .fourPoint {
            var trial = mesh
            let p = MeshWarpLocalPerspective(mode: mode, amount: 0.5)
            let status = trial.applyLocalCorrection(.perspective(p), region: region,
                                                    imageWidth: 128, imageHeight: 128)
            #expect(status.ok)
        }
        // Degenerate quad rejected.
        var bad = mesh
        let degenerate = MeshWarpLocalPerspective(
            mode: .fourPoint,
            sourceQuad: [.zero, .zero, SIMD2(1, 1), SIMD2(0, 1)],
            destinationQuad: [.zero, SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)],
            amount: 1
        )
        let status = bad.applyLocalCorrection(.perspective(degenerate), region: region,
                                              imageWidth: 128, imageHeight: 128)
        #expect(!status.ok)
        #expect(bad.isIdentity)
    }

    // MARK: - Horizon

    @Test func localHorizonLevelsReferences() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        let region = selectInterior(mesh: &mesh, columns: 3, rows: 3)
        let horizontal = MeshWarpLocalHorizon(mode: .horizontalReference,
                                              referenceA: SIMD2(10, 20), referenceB: SIMD2(50, 40),
                                              amount: 0.25)
        #expect(abs(horizontal.levelingRadians() + atan2(Float(20), Float(40))) < 1e-5)

        let reversed = MeshWarpLocalHorizon(mode: .horizontalReference,
                                            referenceA: SIMD2(50, 40), referenceB: SIMD2(10, 20),
                                            amount: 1)
        #expect(abs(horizontal.levelingRadians() - reversed.levelingRadians()) < 1e-5
                || abs(abs(horizontal.levelingRadians() - reversed.levelingRadians()) - Float.pi) < 1e-3)

        let before = mesh.positions
        let horizStatus = mesh.applyLocalCorrection(.horizon(horizontal), region: region,
                                                    imageWidth: 100, imageHeight: 100)
        #expect(horizStatus.ok)
        #expect(mesh.positions != before)

        var verticalMesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        let vertical = MeshWarpLocalHorizon(mode: .verticalReference,
                                            referenceA: SIMD2(40, 10), referenceB: SIMD2(55, 80),
                                            amount: 0.25)
        let vertStatus = verticalMesh.applyLocalCorrection(.horizon(vertical), region: region,
                                                           imageWidth: 100, imageHeight: 100)
        #expect(vertStatus.ok)
    }

    @Test func localHorizonZeroIsIdentity() {
        var mesh = MeshWarpGrid.identity(preset: .points8)
        let region = selectInterior(mesh: &mesh)
        let h = MeshWarpLocalHorizon(mode: .angle, angleDegrees: 15, amount: 0)
        let status = mesh.applyLocalCorrection(.horizon(h), region: region,
                                               imageWidth: 100, imageHeight: 100)
        #expect(status.ok)
        #expect(mesh.isIdentity)
    }

    // MARK: - Volume

    @Test func localVolumeAllModes() {
        var mesh0 = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        let region = selectInterior(mesh: &mesh0, columns: 3, rows: 3)
        for mode in MeshWarpLocalVolumeMode.allCases {
            var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
            let volume = MeshWarpLocalVolume(mode: mode, strength: 0.12, strengthVertical: 0.10)
            let status = mesh.applyLocalCorrection(.volume(volume), region: region,
                                                   imageWidth: 128, imageHeight: 128)
            #expect(status.ok, "\(mode.rawValue)")
            #expect(!mesh.isIdentity, "\(mode.rawValue)")
            var idMesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
            let zero = MeshWarpLocalVolume(mode: mode, strength: 0)
            let zeroStatus = idMesh.applyLocalCorrection(.volume(zero), region: region,
                                                         imageWidth: 128, imageHeight: 128)
            #expect(zeroStatus.ok)
            #expect(idMesh.isIdentity)
        }
    }

    // MARK: - Propagation / sticky / disjoint

    @Test func propagationWeightsLocalCorrection() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        let region = selectInterior(mesh: &mesh, columns: 2, rows: 2)
        let volume = MeshWarpLocalVolume(mode: .radial, strength: 0.08)
        let none = mesh
        let noneStatus = mesh.applyLocalCorrection(.volume(volume), region: region,
                                                   imageWidth: 128, imageHeight: 128)
        #expect(noneStatus.ok)

        var mid = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0.25)
        let midStatus = mid.applyLocalCorrection(.volume(volume), region: region,
                                                 imageWidth: 128, imageHeight: 128)
        #expect(midStatus.ok)

        let movedNone = zip(none.positions, mesh.positions).filter { $0 != $1 }.count
        let movedMid = zip(none.positions, mid.positions).filter { $0 != $1 }.count
        #expect(movedMid > movedNone)

        // Extreme strength + full propagation that would fold is rejected with an explicit status
        // (no silent remap to a different transform).
        var extreme = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 1)
        let strong = MeshWarpLocalVolume(mode: .radial, strength: 0.4)
        let extremeStatus = extreme.applyLocalCorrection(.volume(strong), region: region,
                                                         imageWidth: 128, imageHeight: 128)
        #expect(!extremeStatus.ok)
        #expect(extremeStatus.reason.contains("fold"))
        #expect(extreme.isIdentity)
    }

    @Test func stickyBordersSurviveLocalPerspective() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.25)
        // Interior patch near the top edge; sticky corners stay pinned even under propagation.
        var ids: Set<MeshWarpVertexID> = []
        for r in 1...3 {
            for c in 2...4 {
                ids.insert(mesh.vertexID(mesh.index(column: c, row: r)))
            }
        }
        let region = MeshWarpCorrectionRegion(vertexIDs: ids)
        let cornerBefore = mesh.positions[0]
        let p = MeshWarpLocalPerspective(mode: .vertical, amount: 0.15)
        let status = mesh.applyLocalCorrection(.perspective(p), region: region,
                                               imageWidth: 100, imageHeight: 100)
        #expect(status.ok)
        #expect(mesh.positions[0] == cornerBefore)
    }

    @Test func disjointRegionsStayIndependent() {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        let a = MeshWarpVertexID(mesh.index(column: 1, row: 1))
        let b = MeshWarpVertexID(mesh.index(column: 6, row: 6))
        let region = MeshWarpCorrectionRegion(vertexIDs: [a, b], policy: .independent)
        let components = region.connectedComponents(in: mesh)
        #expect(components.count == 2)

        let volume = MeshWarpLocalVolume(mode: .radial, strength: 0.15)
        let beforeA = mesh.positions[mesh.index(of: a)!]
        let beforeB = mesh.positions[mesh.index(of: b)!]
        let status = mesh.applyLocalCorrection(.volume(volume), region: region,
                                               imageWidth: 100, imageHeight: 100)
        #expect(status.ok)
        let center = mesh.index(column: 4, row: 4)
        #expect(mesh.positions[center] == mesh.rest[center])
        #expect(mesh.positions[mesh.index(of: a)!] != beforeA || mesh.positions[mesh.index(of: b)!] != beforeB)
    }

    // MARK: - Adaptive + local + history + pixels

    @Test func localPerspectiveAfterSubdivision() throws {
        let source = try checkerboard(width: 64, height: 64, cell: 8)
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0.2)
        let face = mesh.topology.rootFaceIDs[24]
        let subdiv = mesh.subdivide(faceIDs: [face])
        #expect(subdiv.ok)
        let region = selectInterior(mesh: &mesh, columns: 3, rows: 3)
        let before = try rgba8(try render(source, mesh: mesh))
        let p = MeshWarpLocalPerspective(mode: .combined, amount: 0.4)
        let status = mesh.applyLocalCorrection(.perspective(p), region: region,
                                               imageWidth: 64, imageHeight: 64)
        #expect(status.ok)
        let after = try rgba8(try render(source, mesh: mesh))
        #expect(before != after)
    }

    @Test func compositionMovePerspectiveHorizonVolume() throws {
        let source = try checkerboard(width: 48, height: 48, cell: 6)
        let session = EditorSession()
        session.createDocument(width: 48, height: 48)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Local"))
        session.beginMeshWarp(preset: .points8)
        let edit = try #require(session.meshWarpEdit)
        edit.mesh.stickyBorders = false
        edit.mesh.propagation = 0.25

        let handle = edit.mesh.index(column: 4, row: 4)
        edit.selection.selectOnly(index: handle, in: edit.mesh)
        edit.beginGesture()
        let moved = edit.moveSelected(toPrimaryDestination: edit.mesh.positions[handle] + SIMD2(0.03, -0.02),
                                      primary: handle)
        #expect(moved)
        edit.endGesture()

        edit.selection.clear()
        for r in 2...5 {
            for c in 2...5 {
                edit.selection.add(edit.mesh.vertexID(edit.mesh.index(column: c, row: r)))
            }
        }
        let p = edit.applyLocalCorrection(.perspective(MeshWarpLocalPerspective(mode: .vertical, amount: 0.35)))
        let h = edit.applyLocalCorrection(.horizon(MeshWarpLocalHorizon(mode: .angle, angleDegrees: 4, amount: 0.5)))
        let v = edit.applyLocalCorrection(.volume(MeshWarpLocalVolume(mode: .combined, strength: 0.2, strengthVertical: 0.15)))
        #expect(p.ok)
        #expect(h.ok)
        #expect(v.ok)

        let u1 = edit.toolUndo()
        let u2 = edit.toolUndo()
        let r1 = edit.toolRedo()
        #expect(u1)
        #expect(u2)
        #expect(r1)

        let cpu = try rgba8(try render(source, mesh: edit.mesh))
        #expect(cpu.count == 48 * 48 * 4)

        session.cancelMeshWarp()
        let afterCancel = try rgba8(try #require(session.activeLayer?.asset?.image))
        #expect(afterCancel == (try rgba8(source)))
    }

    @Test func cpuGpuParityAfterLocalVolume() throws {
        guard MetalMeshWarp.shared != nil else { return }
        let width = 64, height = 64
        let source = try checkerboard(width: width, height: height, cell: 4)
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.2)
        let region = selectInterior(mesh: &mesh, columns: 3, rows: 3)
        let status = mesh.applyLocalCorrection(.volume(MeshWarpLocalVolume(mode: .horizontal, strength: 0.3)),
                                               region: region, imageWidth: width, imageHeight: height)
        #expect(status.ok)
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

    @Test func noCumulativeResamplingAcrossLocalOps() throws {
        let source = try checkerboard(width: 40, height: 40, cell: 5)
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: false, propagation: 0)
        let region = selectInterior(mesh: &mesh)
        let first = try rgba8(try render(source, mesh: mesh))
        let h = mesh.applyLocalCorrection(.horizon(MeshWarpLocalHorizon(mode: .angle, angleDegrees: 3, amount: 0.4)),
                                          region: region, imageWidth: 40, imageHeight: 40)
        #expect(h.ok)
        let mid = try rgba8(try render(source, mesh: mesh))
        let v = mesh.applyLocalCorrection(.volume(MeshWarpLocalVolume(mode: .radial, strength: 0.12)),
                                          region: region, imageWidth: 40, imageHeight: 40)
        #expect(v.ok)
        let last = try rgba8(try render(source, mesh: mesh))
        #expect(first != mid)
        #expect(mid != last)
        let again = try rgba8(try render(source, mesh: mesh))
        #expect(again == last)
    }
}
