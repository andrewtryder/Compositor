# Milestone 8.3 — Adaptive ReShape Subdivide / Merge

Branch: `camera-raw-reshape-adaptive`  
Worktree: `/Users/atr/code/Compositor-reshape-adaptive`  
Baseline: Milestone 8.2 `1f374d89b839ff61142124e5dc95d9336addd124` (PR #7)  
Status: implemented locally — **not committed yet**

## Topology design

Authoritative structure: `MeshWarpTopology`

| Entity | Role |
| --- | --- |
| `MeshWarpVertexID` | Stable vertex identity (never retargeted) |
| `MeshWarpVertex` | `rest` (source UV) + `position` (destination UV) |
| `MeshWarpFaceID` / `MeshWarpFace` | Quad corners TL→TR→BR→BL; optional parent + 4 children |
| `MeshWarpEdgeKey` → midpoint | Shared edge midpoints |
| Leaf faces | Only leaves emit triangles |

`MeshWarpGrid` always owns a topology. Regular presets build it via `MeshWarpTopology.regular`. Dense `positions` / `rest` arrays mirror `topology.order` for hit-testing and existing edit APIs.

### Conventions

- Control-point count (preset): original lattice size (`pointColumns` × `pointRows`)
- After subdiv: `positions.count` grows; preset size is unchanged
- Triangle winding: per leaf, `(TL,TR,BR)` and `(TL,BR,BL)` — same as Milestone 8.1
- Propagation: pixel-space linear weight (8.2), distances on rest UVs
- Sticky borders: classified from rest UV (`MeshWarpTopology.borderKind`)

## Subdivide algorithm

`subdivide(faceIDs:)` — conforming 1→4 split:

1. Queue selected leaf faces.
2. For each face, enqueue **leaf neighbors** that share an edge (conforming).
3. Create/reuse shared edge midpoints: average rest + average position (exact on edges).
4. Create center: rest = mean of corners; **position = sample through the parent’s two-triangle affine map** (barycentric) so the rendered warp does not change.
5. Insert four child faces; mark parent non-leaf.
6. Rollback the face if leaf triangles become invalid.

Budgets: `maxPoints` (10 000), `maxFaces` (20 000), `maxSubdivisionDepth` (8).

## Merge rules

`merge(faceIDs:)` groups selected leaves by parent.

**Accept** when all four children of a parent are selected, are leaves, and child-exclusive vertices lie within `mergeDeformationTolerance` (1e-4) of the parent bilinear prediction.

**Reject** incomplete groups, non-leaves, missing parents, or deformed child-only vertices (explicit reason — no silent discard of local edits).

Successful merge removes children, restores the parent leaf, and drops unreferenced exclusive vertices / edge midpoints.

## Edge conformity / T-junctions

**Strategy: conforming subdivision.** Introducing a midpoint on a shared edge always schedules the neighboring leaf for the same 1→4 split. Leaf sets never retain hanging T-junctions that could crack when midpoints move.

## Vertex IDs

- Regular lattice: IDs `0..<N` match initial order indices.
- New verts: monotonic `nextVertexID` (append to `order`).
- Merge: retired IDs are removed from `order` / `vertices`; selection prunes via `prune(to:)`.
- IDs are never reused for unrelated points in-session.

## Transform integration

Existing tryMove / selection transforms operate on dense indices; sticky + propagation unchanged. Overlay draws `topology.leafEdges()`. Midpoint and center verts are selectable and editable.

## History

`MeshWarpHistorySnapshot` stores the full `MeshWarpGrid` (including topology) + selection. Subdivide / Merge push one tool-local step each. Apply remains one document entry; Cancel drops the session.

Keyboard ⌘Z binding still deferred (same as 8.2).

## Pixel preservation

Identity subdiv: exact byte match.  
Deformed subdiv: center sampled through prior triangles; tests allow ≤1 channel (parity band).

## CPU / GPU parity

Same `triangles()` feed CPU raster and Metal. Source texture still uploaded once per session; only triangle buffers update after topology ops.

## Performance

Not yet timed in this pass for 1024² / 4k / 6k. Architecture preserves upload-once; cost is O(leaf faces) triangle rebuild per preview. Measure before shipping 8.3.

## Tests

`MeshWarpTopologyTests` — regular equivalence, single/neighbor/nested subdiv, shared mids, identity + deformed preservation, child move, valid/invalid merge, undo/redo, sticky, propagation, CPU/GPU parity, cancel.

Plus existing `MeshWarpTests` / `MeshWarpAdvancedTests`.

## Known limitations

- Conforming subdivision can widen into neighbor cascades (potentially far across the connected mesh); locality/perf follow-up is Milestone 8.4 Phase 1.
- Large-canvas (1024² / 4k / 6k) adaptive performance measurements were not collected in this checkpoint.
- No Subdivide/Merge GUI controls.
- No mesh persistence / project-format bump.
- Standard keyboard Undo (⌘Z) remains unconnected; tool-local Undo/Redo APIs only.
- Not claiming full ViewPoint QuadTree parity.

## Proposed commit (do not create yet)

```
ReShape: add adaptive mesh subdivision and merge
```
