import CoreGraphics
import Foundation
import simd

nonisolated struct MeshWarpFaceID: Hashable, Sendable, Codable {
    var rawValue: Int
    init(_ rawValue: Int) { self.rawValue = rawValue }
}

/// Undirected edge key between two stable vertex IDs.
nonisolated struct MeshWarpEdgeKey: Hashable, Sendable {
    let a: MeshWarpVertexID
    let b: MeshWarpVertexID
    init(_ x: MeshWarpVertexID, _ y: MeshWarpVertexID) {
        if x.rawValue <= y.rawValue { a = x; b = y } else { a = y; b = x }
    }
}

nonisolated struct MeshWarpVertex: Equatable, Sendable {
    var id: MeshWarpVertexID
    var rest: SIMD2<Float>
    var position: SIMD2<Float>
}

/// Quad corners in UV order: top-left, top-right, bottom-right, bottom-left
/// (matching the regular lattice cell `(c,r), (c+1,r), (c+1,r+1), (c,r+1)`).
nonisolated struct MeshWarpFace: Equatable, Sendable {
    var id: MeshWarpFaceID
    var corners: [MeshWarpVertexID] // count 4
    var parent: MeshWarpFaceID?
    var children: [MeshWarpFaceID]? // nil = leaf; else exactly 4

    var isLeaf: Bool { children == nil }

    init(id: MeshWarpFaceID, corners: [MeshWarpVertexID], parent: MeshWarpFaceID? = nil,
         children: [MeshWarpFaceID]? = nil) {
        precondition(corners.count == 4)
        self.id = id
        self.corners = corners
        self.parent = parent
        self.children = children
    }
}

nonisolated struct MeshWarpTopologyRejection: Equatable, Sendable {
    var face: MeshWarpFaceID
    var reason: String
}

nonisolated struct MeshWarpTopologyResult: Equatable, Sendable {
    var succeeded: [MeshWarpFaceID]
    var rejected: [MeshWarpTopologyRejection]
    var message: String {
        if rejected.isEmpty { return "OK (\(succeeded.count))" }
        let details = rejected.map { "\($0.face.rawValue): \($0.reason)" }.joined(separator: "; ")
        return "succeeded \(succeeded.count); rejected: \(details)"
    }
    var ok: Bool { !succeeded.isEmpty && rejected.isEmpty }
}

/// Adaptive quad mesh with shared edge midpoints and parent/child faces.
/// Triangle generation walks **leaf** faces only (two triangles per leaf, same winding as the regular grid).
nonisolated struct MeshWarpTopology: Equatable, Sendable {
    var vertices: [MeshWarpVertexID: MeshWarpVertex]
    /// Dense draw / hit-test order. Indices into parallel `MeshWarpGrid.positions` match this order.
    var order: [MeshWarpVertexID]
    var faces: [MeshWarpFaceID: MeshWarpFace]
    /// Initial regular cells (depth-0 faces).
    var rootFaceIDs: [MeshWarpFaceID]
    /// Shared edge → midpoint vertex (when the edge has been split by subdivision).
    var edgeMidpoints: [MeshWarpEdgeKey: MeshWarpVertexID]
    var nextVertexID: Int
    var nextFaceID: Int

    static let maxFaces = 20_000
    static let maxVertices = MeshWarpGrid.maxPoints
    static let maxSubdivisionDepth = 8
    /// Soft cap on emitted triangles (2 per regular leaf; more with hanging-edge fans).
    static let maxTriangles = 40_000
    /// Merge refuses when a child-only vertex drifts farther than this from the parent bilinear prediction.
    static let mergeDeformationTolerance: Float = 1e-4

    var pointCount: Int { order.count }
    var leafFaceIDs: [MeshWarpFaceID] {
        faces.values.filter(\.isLeaf).map(\.id)
    }

    func index(of id: MeshWarpVertexID) -> Int? {
        order.firstIndex(of: id)
    }

    func id(at index: Int) -> MeshWarpVertexID? {
        order.indices.contains(index) ? order[index] : nil
    }

    /// Build a regular lattice topology matching `MeshWarpGrid.identity`.
    static func regular(pointColumns: Int, pointRows: Int) -> MeshWarpTopology? {
        guard pointColumns >= 2, pointRows >= 2,
              pointColumns * pointRows <= MeshWarpGrid.maxPoints else { return nil }
        var vertices: [MeshWarpVertexID: MeshWarpVertex] = [:]
        var order: [MeshWarpVertexID] = []
        order.reserveCapacity(pointColumns * pointRows)
        for row in 0..<pointRows {
            let v = Float(row) / Float(pointRows - 1)
            for column in 0..<pointColumns {
                let u = Float(column) / Float(pointColumns - 1)
                let id = MeshWarpVertexID(row * pointColumns + column)
                let uv = SIMD2(u, v)
                vertices[id] = MeshWarpVertex(id: id, rest: uv, position: uv)
                order.append(id)
            }
        }
        var faces: [MeshWarpFaceID: MeshWarpFace] = [:]
        var roots: [MeshWarpFaceID] = []
        var faceID = 0
        for row in 0..<(pointRows - 1) {
            for column in 0..<(pointColumns - 1) {
                let i00 = MeshWarpVertexID(row * pointColumns + column)
                let i10 = MeshWarpVertexID(row * pointColumns + column + 1)
                let i11 = MeshWarpVertexID((row + 1) * pointColumns + column + 1)
                let i01 = MeshWarpVertexID((row + 1) * pointColumns + column)
                let id = MeshWarpFaceID(faceID)
                faceID += 1
                faces[id] = MeshWarpFace(id: id, corners: [i00, i10, i11, i01])
                roots.append(id)
            }
        }
        return MeshWarpTopology(vertices: vertices, order: order, faces: faces, rootFaceIDs: roots,
                                edgeMidpoints: [:], nextVertexID: pointColumns * pointRows, nextFaceID: faceID)
    }

    func syncArrays() -> (positions: [SIMD2<Float>], rest: [SIMD2<Float>]) {
        var positions: [SIMD2<Float>] = []
        var rest: [SIMD2<Float>] = []
        positions.reserveCapacity(order.count)
        rest.reserveCapacity(order.count)
        for id in order {
            let v = vertices[id]!
            positions.append(v.position)
            rest.append(v.rest)
        }
        return (positions, rest)
    }

    mutating func writeBack(positions: [SIMD2<Float>]) {
        guard positions.count == order.count else { return }
        for (index, id) in order.enumerated() {
            vertices[id]?.position = positions[index]
        }
    }

    func triangles() -> [MeshWarpTriangle] {
        var list: [MeshWarpTriangle] = []
        list.reserveCapacity(leafFaceIDs.count * 2)
        for faceID in leafFaceIDs {
            guard let face = faces[faceID], face.corners.count == 4 else { continue }
            // Start from the regular two-triangle split, then bisect any edge that already has a
            // hanging midpoint. This stays crack-free without cascading 1→4 neighbor splits and
            // never emits the zero-area (corner, mid, corner) fan triangles.
            let c = face.corners
            var corners: [(MeshWarpVertexID, MeshWarpVertexID, MeshWarpVertexID)] = [
                (c[0], c[1], c[2]),
                (c[0], c[2], c[3]),
            ]
            let edged: [(MeshWarpVertexID, MeshWarpVertexID)] = [
                (c[0], c[1]), (c[1], c[2]), (c[2], c[3]), (c[3], c[0]),
            ]
            for (a, b) in edged {
                guard let mid = edgeMidpoints[MeshWarpEdgeKey(a, b)] else { continue }
                var next: [(MeshWarpVertexID, MeshWarpVertexID, MeshWarpVertexID)] = []
                next.reserveCapacity(corners.count + 1)
                for tri in corners {
                    if let split = Self.splitTriangle(tri, edgeA: a, edgeB: b, mid: mid) {
                        next.append(contentsOf: split)
                    } else {
                        next.append(tri)
                    }
                }
                corners = next
            }
            for tri in corners {
                guard let v0 = vertices[tri.0], let v1 = vertices[tri.1], let v2 = vertices[tri.2]
                else { continue }
                list.append(MeshWarpTriangle(destination: (v0.position, v1.position, v2.position),
                                             source: (v0.rest, v1.rest, v2.rest)))
            }
        }
        return list
    }

    /// If `tri` contains undirected edge (edgeA,edgeB), replace it with two triangles through `mid`.
    private static func splitTriangle(
        _ tri: (MeshWarpVertexID, MeshWarpVertexID, MeshWarpVertexID),
        edgeA: MeshWarpVertexID, edgeB: MeshWarpVertexID, mid: MeshWarpVertexID
    ) -> [(MeshWarpVertexID, MeshWarpVertexID, MeshWarpVertexID)]? {
        let ids = [tri.0, tri.1, tri.2]
        guard ids.contains(edgeA), ids.contains(edgeB),
              let other = ids.first(where: { $0 != edgeA && $0 != edgeB }) else {
            return nil
        }
        return [(edgeA, mid, other), (mid, edgeB, other)]
    }

    /// Corner + hanging edge midpoints in winding order (TL → TR → BR → BL).
    func vertexRing(of face: MeshWarpFace) -> [MeshWarpVertexID] {
        let c = face.corners
        guard c.count == 4 else { return c }
        var ring: [MeshWarpVertexID] = []
        ring.reserveCapacity(8)
        let pairs = [(c[0], c[1]), (c[1], c[2]), (c[2], c[3]), (c[3], c[0])]
        for (a, b) in pairs {
            ring.append(a)
            if let mid = edgeMidpoints[MeshWarpEdgeKey(a, b)] {
                ring.append(mid)
            }
        }
        return ring
    }

    func leafEdges() -> [(MeshWarpVertexID, MeshWarpVertexID)] {
        var edges: [(MeshWarpVertexID, MeshWarpVertexID)] = []
        for faceID in leafFaceIDs {
            guard let face = faces[faceID] else { continue }
            let ring = vertexRing(of: face)
            guard ring.count >= 2 else { continue }
            for index in 0..<ring.count {
                edges.append((ring[index], ring[(index + 1) % ring.count]))
            }
        }
        return edges
    }

    /// Number of hanging midpoints on the four edges of a leaf face.
    func hangingMidpointCount(of faceID: MeshWarpFaceID) -> Int {
        guard let face = faces[faceID], face.isLeaf else { return 0 }
        return edgeKeys(of: face).reduce(0) { $0 + (edgeMidpoints[$1] == nil ? 0 : 1) }
    }

    func depth(of faceID: MeshWarpFaceID) -> Int {
        var d = 0
        var current = faces[faceID]?.parent
        while let p = current {
            d += 1
            current = faces[p]?.parent
        }
        return d
    }

    /// Faces that share an edge with `faceID`.
    func neighbors(of faceID: MeshWarpFaceID) -> [MeshWarpFaceID] {
        guard let face = faces[faceID] else { return [] }
        let keys = edgeKeys(of: face)
        var result: [MeshWarpFaceID] = []
        for (otherID, other) in faces where otherID != faceID && other.isLeaf {
            let otherKeys = Set(edgeKeys(of: other))
            if keys.contains(where: { otherKeys.contains($0) }) {
                result.append(otherID)
            }
        }
        return result
    }

    private func edgeKeys(of face: MeshWarpFace) -> [MeshWarpEdgeKey] {
        let c = face.corners
        return [
            MeshWarpEdgeKey(c[0], c[1]),
            MeshWarpEdgeKey(c[1], c[2]),
            MeshWarpEdgeKey(c[2], c[3]),
            MeshWarpEdgeKey(c[3], c[0]),
        ]
    }

    /// Classify sticky behavior from rest UV (image-normalized).
    static func borderKind(rest: SIMD2<Float>, epsilon: Float = 1e-5) -> MeshWarpBorderKind {
        let left = rest.x <= epsilon, right = rest.x >= 1 - epsilon
        let top = rest.y <= epsilon, bottom = rest.y >= 1 - epsilon
        if (left || right) && (top || bottom) { return .corner }
        if left { return .leftEdge }
        if right { return .rightEdge }
        if top { return .topEdge }
        if bottom { return .bottomEdge }
        return .interior
    }

    // MARK: - Subdivide

    /// Local 1→4 subdivision of selected leaf faces.
    ///
    /// Neighbors are **not** force-subdivided. Shared edge midpoints become hanging nodes on
    /// adjacent leaves; `triangles()` fans those rings so the surface stays crack-free without
    /// cascading refinement across the mesh. When a leaf already carries midpoints on all four
    /// edges (every neighbor split that boundary), it is promoted to a full 1→4 split in a
    /// bounded follow-up pass — still local, never a whole-mesh flood.
    ///
    /// The whole request is applied on a trial copy and committed atomically: budget / validity
    /// failures leave `self` unchanged.
    mutating func subdivide(faceIDs: Set<MeshWarpFaceID>) -> MeshWarpTopologyResult {
        var trial = self
        var succeeded: [MeshWarpFaceID] = []
        var rejected: [MeshWarpTopologyRejection] = []

        let requested = faceIDs.sorted { $0.rawValue < $1.rawValue }
        guard !requested.isEmpty else {
            return MeshWarpTopologyResult(succeeded: [], rejected: [])
        }

        // Preflight: refuse the entire op if any requested face is over depth or the worst-case
        // vertex/face growth would exceed budgets (no partial mutation of `self`).
        var pendingLeaves = 0
        for faceID in requested {
            guard let face = trial.faces[faceID] else {
                rejected.append(.init(face: faceID, reason: "unknown face"))
                continue
            }
            if !face.isLeaf {
                rejected.append(.init(face: faceID, reason: "not a leaf"))
                continue
            }
            if trial.depth(of: faceID) >= Self.maxSubdivisionDepth {
                rejected.append(.init(face: faceID, reason: "max subdivision depth"))
                continue
            }
            pendingLeaves += 1
        }
        if pendingLeaves == 0 {
            return MeshWarpTopologyResult(succeeded: [], rejected: rejected)
        }
        // Worst case: each split adds ≤5 verts and +3 net faces (4 children − 1 parent leaf),
        // plus a short promotion wave bounded by the same request's neighborhood.
        let estimatedFaces = trial.faces.count + pendingLeaves * 4 + pendingLeaves * 4
        let estimatedVerts = trial.order.count + pendingLeaves * 5 + pendingLeaves * 5
        let estimatedTris = estimatedFaces * 2
        if estimatedFaces > Self.maxFaces || estimatedVerts > Self.maxVertices
            || estimatedTris > Self.maxTriangles {
            let reasons = requested.compactMap { id -> MeshWarpTopologyRejection? in
                guard trial.faces[id]?.isLeaf == true else { return nil }
                return .init(face: id, reason: "mesh budget exceeded")
            }
            return MeshWarpTopologyResult(succeeded: [], rejected: reasons.isEmpty ? rejected : reasons)
        }
        if !rejected.isEmpty {
            // Mixed valid/invalid request → reject entirely (atomic).
            let reasons = requested.compactMap { id -> MeshWarpTopologyRejection? in
                if rejected.contains(where: { $0.face == id }) { return rejected.first { $0.face == id } }
                return .init(face: id, reason: "rejected with incomplete request")
            }
            return MeshWarpTopologyResult(succeeded: [], rejected: reasons)
        }

        for faceID in requested {
            if let error = trial.splitLeaf(faceID) {
                return MeshWarpTopologyResult(succeeded: [],
                                              rejected: [.init(face: faceID, reason: error)])
            }
            succeeded.append(faceID)
        }

        // Bounded promotion: leaves that inherited four hanging midpoints become regular children.
        var promote = trial.leafFaceIDs.filter { trial.hangingMidpointCount(of: $0) == 4 }
        var promoteGuard = 0
        while !promote.isEmpty, promoteGuard < Self.maxFaces {
            promoteGuard += 1
            let faceID = promote.removeFirst()
            guard trial.faces[faceID]?.isLeaf == true else { continue }
            guard trial.hangingMidpointCount(of: faceID) == 4 else { continue }
            if trial.depth(of: faceID) >= Self.maxSubdivisionDepth { continue }
            if trial.faces.count + 4 > Self.maxFaces || trial.order.count + 5 > Self.maxVertices {
                return MeshWarpTopologyResult(succeeded: [],
                                              rejected: [.init(face: faceID, reason: "mesh budget exceeded")])
            }
            if let error = trial.splitLeaf(faceID) {
                return MeshWarpTopologyResult(succeeded: [],
                                              rejected: [.init(face: faceID, reason: error)])
            }
            // Newly created neighbors may now sit at four midpoints.
            for neighbor in trial.neighbors(of: faceID) where trial.hangingMidpointCount(of: neighbor) == 4 {
                promote.append(neighbor)
            }
        }

        if trial.order.count > Self.maxVertices || trial.faces.count > Self.maxFaces
            || trial.triangles().count > Self.maxTriangles {
            return MeshWarpTopologyResult(succeeded: [],
                                          rejected: succeeded.map {
                                              .init(face: $0, reason: "mesh budget exceeded")
                                          })
        }
        if !MeshWarpGrid.leafTrianglesValid(trial) {
            return MeshWarpTopologyResult(succeeded: [],
                                          rejected: succeeded.map {
                                              .init(face: $0, reason: "degenerate child triangle")
                                          })
        }

        self = trial
        return MeshWarpTopologyResult(succeeded: succeeded, rejected: [])
    }

    /// Diagnostics for locality / growth tests.
    struct SubdivisionGrowth: Sendable {
        var initialVertices: Int
        var finalVertices: Int
        var initialFaces: Int
        var finalFaces: Int
        var initialLeaves: Int
        var finalLeaves: Int
        var requestedCount: Int
        var succeededCount: Int
        var neighborsRefined: Int
        var maxPropagationDistance: Int
        var subdivisionMilliseconds: Double
        var triangleRebuildMilliseconds: Double
        var triangleCount: Int
        var estimatedTopologyBytes: Int
    }

    /// Measure growth from subdividing `faceIDs` (mutates self on success).
    mutating func measureSubdivision(faceIDs: Set<MeshWarpFaceID>) -> (MeshWarpTopologyResult, SubdivisionGrowth) {
        let initialVertices = order.count
        let initialFaces = faces.count
        let initialLeaves = leafFaceIDs.count
        let beforeNeighborLeaves = Set(faceIDs.flatMap { neighbors(of: $0) })

        let t0 = Date()
        let result = subdivide(faceIDs: faceIDs)
        let subdivisionMilliseconds = Date().timeIntervalSince(t0) * 1000

        let t1 = Date()
        let tris = triangles()
        let triangleRebuildMilliseconds = Date().timeIntervalSince(t1) * 1000

        // Neighbors that were force-promoted (four hanging midpoints → 1→4), not merely hanging.
        // Exclude faces that were themselves in the request set.
        let refinedNeighbors = beforeNeighborLeaves
            .subtracting(faceIDs)
            .filter { faces[$0]?.isLeaf == false }
            .count
        // With hanging-edge fans, requested splits do not enqueue neighbors. Forced promotion of a
        // neighbor counts as propagation distance 1; a whole-mesh flood would be ≫ 1.
        let maxDist = refinedNeighbors == 0 ? 0 : 1

        let growth = SubdivisionGrowth(
            initialVertices: initialVertices,
            finalVertices: order.count,
            initialFaces: initialFaces,
            finalFaces: faces.count,
            initialLeaves: initialLeaves,
            finalLeaves: leafFaceIDs.count,
            requestedCount: faceIDs.count,
            succeededCount: result.succeeded.count,
            neighborsRefined: refinedNeighbors,
            maxPropagationDistance: maxDist,
            subdivisionMilliseconds: subdivisionMilliseconds,
            triangleRebuildMilliseconds: triangleRebuildMilliseconds,
            triangleCount: tris.count,
            estimatedTopologyBytes: order.count * 32 + faces.count * 64 + edgeMidpoints.count * 24
        )
        return (result, growth)
    }

    private mutating func splitLeaf(_ faceID: MeshWarpFaceID) -> String? {
        guard var face = faces[faceID], face.isLeaf else { return "not a leaf" }
        let c = face.corners
        guard c.count == 4,
              let v0 = vertices[c[0]], let v1 = vertices[c[1]],
              let v2 = vertices[c[2]], let v3 = vertices[c[3]] else { return "missing corners" }

        // Snapshot for rollback if the split produces invalid triangles.
        let rollback = self

        let m01 = midpoint(of: MeshWarpEdgeKey(c[0], c[1]), a: v0, b: v1)
        let m12 = midpoint(of: MeshWarpEdgeKey(c[1], c[2]), a: v1, b: v2)
        let m23 = midpoint(of: MeshWarpEdgeKey(c[2], c[3]), a: v2, b: v3)
        let m30 = midpoint(of: MeshWarpEdgeKey(c[3], c[0]), a: v3, b: v0)

        // Center rest is the parameter midpoint; destination is sampled through the existing
        // two-triangle affine map so subdivision does not change the rendered warp.
        let centerRest = (v0.rest + v1.rest + v2.rest + v3.rest) * 0.25
        let centerPos = Self.mapThroughQuad(rest: centerRest, v0: v0, v1: v1, v2: v2, v3: v3)
        let centerID = allocateVertex(rest: centerRest, position: centerPos)

        let childCorners: [[MeshWarpVertexID]] = [
            [c[0], m01, centerID, m30], // TL
            [m01, c[1], m12, centerID], // TR
            [centerID, m12, c[2], m23], // BR
            [m30, centerID, m23, c[3]], // BL
        ]
        var childIDs: [MeshWarpFaceID] = []
        for corners in childCorners {
            let id = MeshWarpFaceID(nextFaceID)
            nextFaceID += 1
            faces[id] = MeshWarpFace(id: id, corners: corners, parent: faceID)
            childIDs.append(id)
        }
        face.children = childIDs
        faces[faceID] = face

        if !MeshWarpGrid.leafTrianglesValid(self) {
            self = rollback
            return "degenerate child triangle"
        }
        return nil
    }

    private mutating func midpoint(of key: MeshWarpEdgeKey, a: MeshWarpVertex, b: MeshWarpVertex) -> MeshWarpVertexID {
        if let existing = edgeMidpoints[key] { return existing }
        let rest = (a.rest + b.rest) * 0.5
        // Edge midpoints stay affine combinations — exact on both triangles that share the edge.
        let position = (a.position + b.position) * 0.5
        let id = allocateVertex(rest: rest, position: position)
        edgeMidpoints[key] = id
        return id
    }

    /// Maps a rest UV through the parent leaf's two-triangle surface into destination UV.
    private static func mapThroughQuad(rest query: SIMD2<Float>,
                                       v0: MeshWarpVertex, v1: MeshWarpVertex,
                                       v2: MeshWarpVertex, v3: MeshWarpVertex) -> SIMD2<Float> {
        // Triangles match `triangles()`: (0,1,2) and (0,2,3).
        if let b = barycentric(query, v0.rest, v1.rest, v2.rest), b.x >= -1e-5, b.y >= -1e-5, b.z >= -1e-5 {
            return v0.position * b.x + v1.position * b.y + v2.position * b.z
        }
        if let b = barycentric(query, v0.rest, v2.rest, v3.rest), b.x >= -1e-5, b.y >= -1e-5, b.z >= -1e-5 {
            return v0.position * b.x + v2.position * b.y + v3.position * b.z
        }
        return (v0.position + v1.position + v2.position + v3.position) * 0.25
    }

    private static func barycentric(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>,
                                    _ c: SIMD2<Float>) -> SIMD3<Float>? {
        let v0 = b - a, v1 = c - a, v2 = p - a
        let d00 = v0.x * v0.x + v0.y * v0.y
        let d01 = v0.x * v1.x + v0.y * v1.y
        let d11 = v1.x * v1.x + v1.y * v1.y
        let d20 = v2.x * v0.x + v2.y * v0.y
        let d21 = v2.x * v1.x + v2.y * v1.y
        let denom = d00 * d11 - d01 * d01
        guard abs(denom) > 1e-12 else { return nil }
        let v = (d11 * d20 - d01 * d21) / denom
        let w = (d00 * d21 - d01 * d20) / denom
        let u = 1 - v - w
        return SIMD3(u, v, w)
    }

    private mutating func allocateVertex(rest: SIMD2<Float>, position: SIMD2<Float>) -> MeshWarpVertexID {
        let id = MeshWarpVertexID(nextVertexID)
        nextVertexID += 1
        vertices[id] = MeshWarpVertex(id: id, rest: rest, position: position)
        order.append(id)
        return id
    }

    // MARK: - Merge

    /// Merge a complete set of four leaf children back into their parent.
    mutating func merge(faceIDs: Set<MeshWarpFaceID>) -> MeshWarpTopologyResult {
        var succeeded: [MeshWarpFaceID] = []
        var rejected: [MeshWarpTopologyRejection] = []

        // Group selected leaves by parent.
        var byParent: [MeshWarpFaceID: Set<MeshWarpFaceID>] = [:]
        for id in faceIDs {
            guard let face = faces[id], face.isLeaf, let parent = face.parent else {
                rejected.append(.init(face: id, reason: "not a mergeable leaf"))
                continue
            }
            byParent[parent, default: []].insert(id)
        }

        for (parentID, selectedChildren) in byParent {
            guard let parent = faces[parentID], let children = parent.children, children.count == 4 else {
                rejected.append(.init(face: parentID, reason: "parent missing children"))
                continue
            }
            let childSet = Set(children)
            guard selectedChildren == childSet else {
                rejected.append(.init(face: parentID, reason: "incomplete child group"))
                continue
            }
            // All four must still be leaves.
            guard children.allSatisfy({ faces[$0]?.isLeaf == true }) else {
                rejected.append(.init(face: parentID, reason: "child is not a leaf"))
                continue
            }
            if let error = validateMergeDeformation(parentID: parentID, children: children) {
                rejected.append(.init(face: parentID, reason: error))
                continue
            }
            if let error = performMerge(parentID: parentID, children: children) {
                rejected.append(.init(face: parentID, reason: error))
            } else {
                succeeded.append(parentID)
            }
        }
        return MeshWarpTopologyResult(succeeded: succeeded, rejected: rejected)
    }

    private func validateMergeDeformation(parentID: MeshWarpFaceID, children: [MeshWarpFaceID]) -> String? {
        guard let parent = faces[parentID] else { return "missing parent" }
        let c = parent.corners
        guard let v0 = vertices[c[0]], let v1 = vertices[c[1]],
              let v2 = vertices[c[2]], let v3 = vertices[c[3]] else { return "missing corners" }

        func predicted(rest: SIMD2<Float>) -> SIMD2<Float> {
            // Bilinear from parent corners in rest-parameter space of the parent quad.
            let minX = min(v0.rest.x, v1.rest.x, v2.rest.x, v3.rest.x)
            let maxX = max(v0.rest.x, v1.rest.x, v2.rest.x, v3.rest.x)
            let minY = min(v0.rest.y, v1.rest.y, v2.rest.y, v3.rest.y)
            let maxY = max(v0.rest.y, v1.rest.y, v2.rest.y, v3.rest.y)
            let sx = max(maxX - minX, 1e-8)
            let sy = max(maxY - minY, 1e-8)
            let u = (rest.x - minX) / sx
            let v = (rest.y - minY) / sy
            let top = v0.position * (1 - u) + v1.position * u
            let bot = v3.position * (1 - u) + v2.position * u
            return top * (1 - v) + bot * v
        }

        let exclusive = exclusiveVertices(parent: parent, children: children)
        for id in exclusive {
            guard let vertex = vertices[id] else { continue }
            let expected = predicted(rest: vertex.rest)
            let delta = vertex.position - expected
            if (delta.x * delta.x + delta.y * delta.y).squareRoot() > Self.mergeDeformationTolerance {
                return "child vertices deformed; merge would discard edits"
            }
        }
        return nil
    }

    private func exclusiveVertices(parent: MeshWarpFace, children: [MeshWarpFaceID]) -> Set<MeshWarpVertexID> {
        var childVerts = Set<MeshWarpVertexID>()
        for id in children {
            if let face = faces[id] { childVerts.formUnion(face.corners) }
        }
        return childVerts.subtracting(parent.corners)
    }

    private mutating func performMerge(parentID: MeshWarpFaceID, children: [MeshWarpFaceID]) -> String? {
        guard var parent = faces[parentID] else { return "missing parent" }
        let exclusive = exclusiveVertices(parent: parent, children: children)

        // Remove child faces.
        for id in children { faces.removeValue(forKey: id) }
        parent.children = nil
        faces[parentID] = parent

        // Drop exclusive vertices if no remaining face references them.
        var referenced = Set<MeshWarpVertexID>()
        for face in faces.values {
            referenced.formUnion(face.corners)
        }
        for id in exclusive where !referenced.contains(id) {
            vertices.removeValue(forKey: id)
            order.removeAll { $0 == id }
            edgeMidpoints = edgeMidpoints.filter { $0.value != id }
        }
        // Clear edge midpoint entries for parent edges if the midpoint vertex was removed.
        let parentEdges = [
            MeshWarpEdgeKey(parent.corners[0], parent.corners[1]),
            MeshWarpEdgeKey(parent.corners[1], parent.corners[2]),
            MeshWarpEdgeKey(parent.corners[2], parent.corners[3]),
            MeshWarpEdgeKey(parent.corners[3], parent.corners[0]),
        ]
        for key in parentEdges {
            if let mid = edgeMidpoints[key], vertices[mid] == nil {
                edgeMidpoints.removeValue(forKey: key)
            } else if let mid = edgeMidpoints[key], !referenced.contains(mid) {
                // Midpoint still exists only for this parent edge — remove if unused.
                edgeMidpoints.removeValue(forKey: key)
                vertices.removeValue(forKey: mid)
                order.removeAll { $0 == mid }
            }
        }
        return nil
    }

    func leafFacesTouching(vertexIDs: Set<MeshWarpVertexID>) -> Set<MeshWarpFaceID> {
        var result = Set<MeshWarpFaceID>()
        for (id, face) in faces where face.isLeaf {
            if face.corners.contains(where: { vertexIDs.contains($0) }) {
                result.insert(id)
            }
        }
        return result
    }
}
