import CoreGraphics
import Foundation
import simd

/// Multi-point selection for ReShape. Uses stable `MeshWarpVertexID` values (grid indices
/// that remain valid until topology / preset changes), not screen-space slots.
nonisolated struct MeshWarpSelection: Equatable, Sendable {
    private(set) var ids: Set<MeshWarpVertexID> = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    var indices: Set<Int> { Set(ids.map(\.rawValue)) }

    mutating func clear() { ids.removeAll() }

    mutating func selectOnly(_ id: MeshWarpVertexID) {
        ids = [id]
    }

    mutating func selectOnly(index: Int) {
        selectOnly(MeshWarpVertexID(index))
    }

    /// Shift-click: add if absent, remove if present.
    mutating func toggle(_ id: MeshWarpVertexID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    mutating func toggle(index: Int) { toggle(MeshWarpVertexID(index)) }

    mutating func add(_ id: MeshWarpVertexID) { ids.insert(id) }

    mutating func add(indices: [Int]) {
        for index in indices { ids.insert(MeshWarpVertexID(index)) }
    }

    mutating func selectAll(pointCount: Int) {
        ids = Set((0..<pointCount).map(MeshWarpVertexID.init))
    }

    /// Replace selection with vertices inside the UV marquee (current mesh positions).
    mutating func selectMarquee(uvRect: CGRect, mesh: MeshWarpGrid, additive: Bool) {
        let hit = mesh.indicesInside(uvRect: uvRect).map(MeshWarpVertexID.init)
        if additive {
            ids.formUnion(hit)
        } else {
            ids = Set(hit)
        }
    }

    func contains(index: Int) -> Bool { ids.contains(MeshWarpVertexID(index)) }

    /// Drop IDs that no longer exist after a preset / topology change.
    mutating func prune(pointCount: Int) {
        ids = Set(ids.filter { $0.rawValue >= 0 && $0.rawValue < pointCount })
    }
}

/// Transform mode for a selected vertex set.
nonisolated enum MeshWarpTransformMode: String, CaseIterable, Sendable {
    case move
    case rotate
    case scale
}
