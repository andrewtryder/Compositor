import Foundation
import simd

/// One logical ReShape tool operation (not one document history entry).
nonisolated struct MeshWarpHistorySnapshot: Equatable, Sendable {
    var mesh: MeshWarpGrid
    var selection: MeshWarpSelection

    var positions: [SIMD2<Float>] { mesh.positions }
}

/// Bounded undo/redo stack for an open ReShape session.
/// Continuous pointer drags should push once at end-of-gesture, not per mouse move.
nonisolated final class MeshWarpHistory: @unchecked Sendable {
    private var undoStack: [MeshWarpHistorySnapshot] = []
    private var redoStack: [MeshWarpHistorySnapshot] = []
    private let limit: Int

    init(limit: Int = 64) {
        self.limit = max(1, limit)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func clear() {
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
    }

    /// Records `before` as the state to restore on Undo. Call before mutating the mesh for a
    /// completed logical operation (end of drag, transform commit, subdivide, merge, reset, …).
    func push(_ before: MeshWarpHistorySnapshot) {
        undoStack.append(before)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll(keepingCapacity: true)
    }

    func undo(current: MeshWarpHistorySnapshot) -> MeshWarpHistorySnapshot? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    func redo(current: MeshWarpHistorySnapshot) -> MeshWarpHistorySnapshot? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
