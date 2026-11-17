import CoreGraphics
import Foundation
import simd

/// Multi-point selection for ReShape. Uses stable `MeshWarpVertexID` values that survive
/// subdivision; pruned on merge / preset when IDs leave the mesh.
nonisolated struct MeshWarpSelection: Equatable, Sendable {
    private(set) var ids: Set<MeshWarpVertexID> = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    /// Dense indices into the current `mesh.positions` array for selected IDs that still exist.
    func indices(in mesh: MeshWarpGrid) -> Set<Int> {
        Set(ids.compactMap { mesh.index(of: $0) })
    }

    /// Convenience when the mesh order still matches raw IDs (regular lattice, append-only subdiv).
    var indices: Set<Int> { Set(ids.map(\.rawValue)) }

    mutating func clear() { ids.removeAll() }

    mutating func selectOnly(_ id: MeshWarpVertexID) {
        ids = [id]
    }

    mutating func selectOnly(index: Int, in mesh: MeshWarpGrid) {
        guard let id = mesh.topology.id(at: index) else { return }
        selectOnly(id)
    }

    mutating func selectOnly(index: Int) {
        selectOnly(MeshWarpVertexID(index))
    }

    /// Shift-click: add if absent, remove if present.
    mutating func toggle(_ id: MeshWarpVertexID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    mutating func toggle(index: Int, in mesh: MeshWarpGrid) {
        guard let id = mesh.topology.id(at: index) else { return }
        toggle(id)
    }

    mutating func toggle(index: Int) { toggle(MeshWarpVertexID(index)) }

    mutating func add(_ id: MeshWarpVertexID) { ids.insert(id) }

    mutating func add(indices: [Int], in mesh: MeshWarpGrid) {
        for index in indices {
            if let id = mesh.topology.id(at: index) { ids.insert(id) }
        }
    }

    mutating func selectAll(in mesh: MeshWarpGrid) {
        ids = Set(mesh.topology.order)
    }

    mutating func selectAll(pointCount: Int) {
        ids = Set((0..<pointCount).map(MeshWarpVertexID.init))
    }

    /// Replace selection with vertices inside the UV marquee (current mesh positions).
    mutating func selectMarquee(uvRect: CGRect, mesh: MeshWarpGrid, additive: Bool) {
        let hit = mesh.indicesInside(uvRect: uvRect).compactMap { mesh.topology.id(at: $0) }
        if additive {
            ids.formUnion(hit)
        } else {
            ids = Set(hit)
        }
    }

    func contains(index: Int, in mesh: MeshWarpGrid) -> Bool {
        guard let id = mesh.topology.id(at: index) else { return false }
        return ids.contains(id)
    }

    func contains(index: Int) -> Bool { ids.contains(MeshWarpVertexID(index)) }

    /// Drop IDs that no longer exist after merge / preset / topology change.
    mutating func prune(to mesh: MeshWarpGrid) {
        let valid = Set(mesh.topology.order)
        ids = ids.intersection(valid)
    }

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
