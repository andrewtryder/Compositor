import CoreGraphics
import Foundation
import simd

/// Classification of a control point for Sticky Borders.
nonisolated enum MeshWarpBorderKind: Equatable, Sendable {
    case interior
    case corner
    case leftEdge
    case rightEdge
    case topEdge
    case bottomEdge

    var isCorner: Bool {
        if case .corner = self { return true }
        return false
    }

    var isEdgeSlide: Bool {
        switch self {
        case .leftEdge, .rightEdge, .topEdge, .bottomEdge: return true
        default: return false
        }
    }
}

/// Stable identity for a control point on the current topology.
/// Indices remain stable across edits until a preset change or (future) topology op.
nonisolated struct MeshWarpVertexID: Hashable, Sendable, Codable {
    var rawValue: Int
    init(_ rawValue: Int) { self.rawValue = rawValue }
}

/// ReShape mesh: starts as a regular lattice and may gain adaptive leaf quads via Subdivide.
/// `pointColumns` / `pointRows` are the **original** control-point counts. After subdivision,
/// `positions.count` / `topology.order` grow; stable `MeshWarpVertexID` values never retarget.
/// Coordinates are normalized layer UV: (0,0) top-left → (1,1) bottom-right.
nonisolated struct MeshWarpGrid: Equatable, Sendable {
    /// Original lattice control points across (X). Must be ≥ 2.
    var pointColumns: Int
    /// Original lattice control points down (Y). Must be ≥ 2.
    var pointRows: Int
    /// Current destination positions in UV (dense order matching `topology.order`).
    var positions: [SIMD2<Float>]
    /// Bind / rest pose in UV (same order).
    var rest: [SIMD2<Float>]
    var stickyBorders: Bool
    /// 0…1. ViewPoint-style linear propagation strength (not a UV radius).
    var propagation: Float
    /// Authoritative adaptive topology (shared edges, leaf quads). Always present.
    var topology: MeshWarpTopology

    var pointCount: Int { positions.count }
    var cellColumns: Int { pointColumns - 1 }
    var cellRows: Int { pointRows - 1 }
    var isAdaptive: Bool { topology.leafFaceIDs.count != cellColumns * cellRows }

    static let presets = [4, 8, 16]
    static let maxPoints = 10_000
    /// Reject triangle updates whose |signed area| in UV falls below this.
    static let minimumTriangleArea: Float = 1e-8
    /// Matches recovered `TransformationWithPropagation` ε.
    static let propagationEpsilon: Float = 0.0001

    enum Preset: Int, CaseIterable, Sendable {
        case points4 = 4, points8 = 8, points16 = 16
        var label: String { "\(rawValue)×\(rawValue)" }
    }

    /// Uniform rest lattice. Fails when the point count is out of range.
    static func identity(pointColumns: Int, pointRows: Int,
                         stickyBorders: Bool = true, propagation: Float = 0) -> MeshWarpGrid? {
        guard let topology = MeshWarpTopology.regular(pointColumns: pointColumns, pointRows: pointRows)
        else { return nil }
        let arrays = topology.syncArrays()
        return MeshWarpGrid(pointColumns: pointColumns, pointRows: pointRows,
                            positions: arrays.positions, rest: arrays.rest,
                            stickyBorders: stickyBorders,
                            propagation: max(0, min(1, propagation)),
                            topology: topology)
    }

    static func identity(preset: Preset, stickyBorders: Bool = true, propagation: Float = 0) -> MeshWarpGrid {
        identity(pointColumns: preset.rawValue, pointRows: preset.rawValue,
                 stickyBorders: stickyBorders, propagation: propagation)!
    }

    func index(column: Int, row: Int) -> Int { row * pointColumns + column }
    func column(of index: Int) -> Int { index % pointColumns }
    func row(of index: Int) -> Int { index / pointColumns }
    func vertexID(_ index: Int) -> MeshWarpVertexID {
        topology.id(at: index) ?? MeshWarpVertexID(index)
    }
    func index(of id: MeshWarpVertexID) -> Int? { topology.index(of: id) }

    func borderKind(_ index: Int) -> MeshWarpBorderKind {
        guard rest.indices.contains(index) else { return .interior }
        return MeshWarpTopology.borderKind(rest: rest[index])
    }

    func isBorder(_ index: Int) -> Bool { borderKind(index) != .interior }
    func isCorner(_ index: Int) -> Bool { borderKind(index).isCorner }

    var isIdentity: Bool {
        zip(positions, rest).allSatisfy { abs($0.x - $1.x) < 1e-7 && abs($0.y - $1.y) < 1e-7 }
    }

    mutating func resetToRest() {
        positions = rest
        topology.writeBack(positions: positions)
    }

    mutating func syncFromTopology() {
        let arrays = topology.syncArrays()
        positions = arrays.positions
        rest = arrays.rest
    }

    /// UV → layer pixel centers space uses width/height of the bitmap.
    static func pixel(fromUV uv: SIMD2<Float>, width: Int, height: Int) -> SIMD2<Float> {
        SIMD2(uv.x * Float(max(width - 1, 0)), uv.y * Float(max(height - 1, 0)))
    }

    static func uv(fromPixel pixel: SIMD2<Float>, width: Int, height: Int) -> SIMD2<Float> {
        let sx = Float(max(width - 1, 1)), sy = Float(max(height - 1, 1))
        return SIMD2(pixel.x / sx, pixel.y / sy)
    }

    static func extentPixels(width: Int, height: Int) -> Float {
        Float(max(max(width, height), 1))
    }

    static func pixelDistance(_ a: SIMD2<Float>, _ b: SIMD2<Float>, width: Int, height: Int) -> Float {
        let pa = pixel(fromUV: a, width: width, height: height)
        let pb = pixel(fromUV: b, width: width, height: height)
        let d = pa - pb
        return (d.x * d.x + d.y * d.y).squareRoot()
    }

    /// Recovered ViewPoint propagation weight (clean-room):
    /// `w = clamp(1 + (p - 1) * d / (n * p + ε), 0, 1)`.
    static func propagationWeight(distancePixels d: Float, propagation p: Float, extentPixels n: Float) -> Float {
        let prop = max(0, min(1, p))
        let extent = max(n, 1)
        let denom = extent * prop + propagationEpsilon
        let raw = 1 + (prop - 1) * max(0, d) / denom
        return max(0, min(1, raw))
    }

    /// Hit-test in UV. `radius` is in UV units.
    func hitTest(uv: SIMD2<Float>, radius: Float) -> Int? {
        var best: Int?, bestDistance = radius * radius
        for (index, position) in positions.enumerated() {
            let d = position - uv
            let distance = d.x * d.x + d.y * d.y
            if distance <= bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Vertices whose **current** UV lies inside the axis-aligned marquee (inclusive).
    func indicesInside(uvRect: CGRect) -> [Int] {
        positions.indices.filter { index in
            let p = positions[index]
            return uvRect.contains(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
        }
    }

    /// Project / reject a proposed UV under Sticky Borders.
    /// Corners stay pinned when sticky; edge points slide along their edge; interior free.
    func constrainSticky(index: Int, proposed: SIMD2<Float>) -> SIMD2<Float>? {
        let clamped = SIMD2(max(0, min(1, proposed.x)), max(0, min(1, proposed.y)))
        guard stickyBorders else { return clamped }
        switch borderKind(index) {
        case .corner:
            return nil
        case .leftEdge:
            return SIMD2(0, clamped.y)
        case .rightEdge:
            return SIMD2(1, clamped.y)
        case .topEdge:
            return SIMD2(clamped.x, 0)
        case .bottomEdge:
            return SIMD2(clamped.x, 1)
        case .interior:
            return clamped
        }
    }

    /// Attempt to move `index` to `destination` (and neighbors by propagation).
    /// When `base` is provided (pointer-drag snapshot), displacements are absolute from that
    /// snapshot so repeated updates do not accumulate drift.
    @discardableResult
    mutating func tryMove(index: Int, to destination: SIMD2<Float>,
                          imageWidth: Int, imageHeight: Int,
                          base: [SIMD2<Float>]? = nil) -> Bool {
        guard positions.indices.contains(index) else { return false }
        let snapshot = base ?? positions
        guard snapshot.count == positions.count else { return false }

        guard let primary = constrainSticky(index: index, proposed: destination) else { return false }
        let delta = primary - snapshot[index]
        if abs(delta.x) < 1e-12, abs(delta.y) < 1e-12 {
            // Still allow installing when base differs from current (resume after rejected fold).
            if base == nil { return true }
        }

        var trial = snapshot
        trial[index] = primary

        let selected = Set([index])
        let extent = Self.extentPixels(width: imageWidth, height: imageHeight)
        let prop = propagation
        if prop > 1e-9 {
            for other in positions.indices where other != index {
                let distance = Self.pixelDistance(rest[other], rest[index],
                                                  width: imageWidth, height: imageHeight)
                let weight = Self.propagationWeight(distancePixels: distance, propagation: prop,
                                                    extentPixels: extent)
                if weight <= 1e-9 { continue }
                let proposed = snapshot[other] + delta * weight
                if let constrained = constrainSticky(index: other, proposed: proposed) {
                    trial[other] = constrained
                } else {
                    trial[other] = snapshot[other]
                }
            }
        } else {
            // Propagation 0: only the primary moves (already written).
            _ = selected
        }

        return install(trial)
    }

    /// Convenience for tests / callers that omit image size (uses 1000×1000 extent).
    @discardableResult
    mutating func tryMove(index: Int, to destination: SIMD2<Float>) -> Bool {
        tryMove(index: index, to: destination, imageWidth: 1000, imageHeight: 1000, base: nil)
    }

    /// Apply a rigid / similarity transform to selected vertices; unselected follow propagation
    /// weights based on distance to the nearest selected rest point.
    @discardableResult
    mutating func applySelectionTransform(selected: Set<Int>,
                                          imageWidth: Int, imageHeight: Int,
                                          base: [SIMD2<Float>],
                                          transform: (SIMD2<Float>) -> SIMD2<Float>) -> Bool {
        guard !selected.isEmpty, base.count == positions.count else { return false }
        let valid = selected.filter { positions.indices.contains($0) }
        guard !valid.isEmpty else { return false }

        var trial = base
        let extent = Self.extentPixels(width: imageWidth, height: imageHeight)
        let prop = propagation

        for index in valid {
            let proposed = transform(base[index])
            if let constrained = constrainSticky(index: index, proposed: proposed) {
                trial[index] = constrained
            } else {
                trial[index] = base[index]
            }
        }

        for other in positions.indices where !valid.contains(other) {
            var nearest = Float.greatestFiniteMagnitude
            for seed in valid {
                let d = Self.pixelDistance(rest[other], rest[seed],
                                           width: imageWidth, height: imageHeight)
                nearest = min(nearest, d)
            }
            let weight = Self.propagationWeight(distancePixels: nearest, propagation: prop,
                                                extentPixels: extent)
            if weight <= 1e-9 { continue }
            // Interpolate between base and the transform of this vertex's base position.
            let fullyTransformed = transform(base[other])
            let proposed = base[other] + (fullyTransformed - base[other]) * weight
            if let constrained = constrainSticky(index: other, proposed: proposed) {
                trial[other] = constrained
            } else {
                trial[other] = base[other]
            }
        }

        return install(trial)
    }

    /// Barycenter of the given vertex positions (current or base).
    static func barycenter(indices: Set<Int>, in positions: [SIMD2<Float>]) -> SIMD2<Float>? {
        let list = indices.filter { positions.indices.contains($0) }
        guard !list.isEmpty else { return nil }
        var sum = SIMD2<Float>(0, 0)
        for index in list { sum += positions[index] }
        return sum / Float(list.count)
    }

    private mutating func install(_ trial: [SIMD2<Float>]) -> Bool {
        guard trial.count == positions.count else { return false }
        var trialTopology = topology
        trialTopology.writeBack(positions: trial)
        guard Self.leafTrianglesValid(trialTopology) else { return false }
        positions = trial
        topology = trialTopology
        return true
    }

    /// Validates leaf-face triangles (works for regular and adaptive meshes).
    static func leafTrianglesValid(_ topology: MeshWarpTopology) -> Bool {
        for triangle in topology.triangles() {
            let area = signedArea(triangle.destination.0, triangle.destination.1, triangle.destination.2)
            if abs(area) < minimumTriangleArea { return false }
            let restArea = signedArea(triangle.source.0, triangle.source.1, triangle.source.2)
            if restArea * area < 0 { return false }
        }
        return true
    }

    /// Every cell is split along the diagonal (0,0)-(1,1) in cell space into two triangles.
    static func trianglesValid(pointColumns: Int, pointRows: Int, positions: [SIMD2<Float>]) -> Bool {
        guard let topology = MeshWarpTopology.regular(pointColumns: pointColumns, pointRows: pointRows)
        else { return false }
        var trial = topology
        trial.writeBack(positions: positions)
        return leafTrianglesValid(trial)
    }

    static func signedArea(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
}

/// One destination triangle with corresponding rest (source) vertices.
nonisolated struct MeshWarpTriangle: Sendable {
    var destination: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
    var source: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
}

extension MeshWarpGrid {
    /// Destination triangles in UV, paired with rest UV for source lookup (leaf faces only).
    nonisolated func triangles() -> [MeshWarpTriangle] {
        var topo = topology
        topo.writeBack(positions: positions)
        return topo.triangles()
    }

    static let topologyOpsSupported = true
    static let topologyOpsUnavailableMessage = ""

    /// Subdivide leaf faces that contain any of the selected vertex indices (conforming).
    @discardableResult
    mutating func subdivideSelectedQuads(containingVertexIndices selected: Set<Int>) -> MeshWarpTopologyResult {
        topology.writeBack(positions: positions)
        let ids = Set(selected.compactMap { topology.id(at: $0) })
        let faces = topology.leafFacesTouching(vertexIDs: ids)
        return subdivide(faceIDs: faces)
    }

    @discardableResult
    mutating func subdivide(faceIDs: Set<MeshWarpFaceID>) -> MeshWarpTopologyResult {
        topology.writeBack(positions: positions)
        let result = topology.subdivide(faceIDs: faceIDs)
        syncFromTopology()
        return result
    }

    /// Merge complete four-child groups whose children are all selected (by face or by covering verts).
    @discardableResult
    mutating func mergeSelectedChildGroup(containingVertexIndices selected: Set<Int>) -> MeshWarpTopologyResult {
        topology.writeBack(positions: positions)
        let ids = Set(selected.compactMap { topology.id(at: $0) })
        let faces = topology.leafFacesTouching(vertexIDs: ids)
        return merge(faceIDs: faces)
    }

    @discardableResult
    mutating func merge(faceIDs: Set<MeshWarpFaceID>) -> MeshWarpTopologyResult {
        topology.writeBack(positions: positions)
        let result = topology.merge(faceIDs: faceIDs)
        syncFromTopology()
        return result
    }
}
