# Milestone 8.3 — Adaptive ReShape Subdivide / Merge

Branch: `camera-raw-reshape-adaptive` (published) / continued on `camera-raw-reshape-local-geometry`  
Worktree (publish): `/Users/atr/code/Compositor-reshape-adaptive`  
Baseline: Milestone 8.2 `1f374d89b839ff61142124e5dc95d9336addd124` (PR #7)  
Published: commit `4016e600ee835aaf006bcc338cffa14be57dfe50` — draft PR https://github.com/andrewtryder/Compositor/pull/8  
Base: `camera-raw-reshape-advanced` · Head: `camera-raw-reshape-adaptive`

## Topology design

Authoritative structure: `MeshWarpTopology`

| Entity | Role |
| --- | --- |
| `MeshWarpVertexID` | Stable vertex identity (never retargeted) |
| `MeshWarpVertex` | `rest` (source UV) + `position` (destination UV) |
| `MeshWarpFaceID` / `MeshWarpFace` | Quad corners TL→TR→BR→BL; optional parent + 4 children |
| `MeshWarpEdgeKey` → midpoint | Shared edge midpoints |
| Leaf faces | Only leaves emit triangles |

`MeshWarpGrid` always owns a topology. Regular presets build it via `MeshWarpTopology.regular`. Dense `positions` / `rest` arrays mirror `topology.order`.

## Subdivide algorithm (updated in 8.4 Phase 1)

**Publish checkpoint (8.3):** conforming queue that also subdivided edge neighbors (could cascade).

**Locality fix (8.4 worktree):** local 1→4 of **requested leaves only**, atomic trial/commit:

1. Preflight depth + worst-case budget (`maxVertices` / `maxFaces` / `maxTriangles` / `maxSubdivisionDepth`).
2. Split each requested leaf (shared midpoints; center via two-triangle barycentric map).
3. Bounded promotion: leaves that already carry midpoints on all four edges → 1→4.
4. Commit only if the whole trial validates; otherwise leave `self` unchanged.

Neighbors keep hanging midpoints. `triangles()` starts from the regular diagonal pair and **bisects** any edge that has a hanging midpoint (crack-free, no zero-area fan).

## Subdivision-growth measurements (8.4 Phase 1)

Regular grids; one operation each. Neighbors refined = force-promoted leaves **excluding** the request set. Cascade distance 0 means no forced neighbor 1→4.

| Grid | Case | Init V / F (roots) | Final V | Neighbors refined | Max prop. dist | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| 4×4 | central | 16 / 9 | ≤21 | 0 | 0 | ≤5 new verts |
| 4×4 | boundary | 16 / 9 | ≤21 | 0 | 0 | |
| 4×4 | two adjacent | 16 / 9 | ≤26 | 0 | 0 | |
| 4×4 | distant | 16 / 9 | ≤26 | 0 | 0 | |
| 8×8 | central | 64 / 49 | ≤69 | 0 | 0 | |
| 8×8 | boundary | 64 / 49 | ≤69 | 0 | 0 | |
| 8×8 | two adjacent | 64 / 49 | ≤74 | 0 | 0 | |
| 8×8 | distant | 64 / 49 | ≤74 | 0 | 0 | |
| 16×16 | central | 256 / 225 | ≤261 | 0 | 0 | |
| 16×16 | nested ×3 | 256 / 225 | ≤+20 verts | 0 | 0 | one lineage |

Times: see `MeshWarpTopology.measureSubdivision` / `MeshWarpLocalGeometryTests.subdivisionGrowthLocalityMatrix` (Debug host). Peak topology memory ≈ `order*32 + faces*64 + midpoints*24` bytes (estimate field on growth struct).

**Invariant:** subdividing one face does **not** routinely refine the entire connected mesh.

## Merge rules

Unchanged from 8.3 publish: complete undeformed child groups only; deformed children rejected with reason.

## Vertex IDs / history / pixels / parity

Unchanged: stable IDs, tool-local history snapshots, identity subdiv byte-exact, deformed ≤1 channel, CPU/GPU share `triangles()`, source GPU-resident.

## Known limitations

- Large-canvas (1024² / 4k / 6k) adaptive timings collected under Milestone 8.4 perf tests (not in the 8.3 publish commit).
- No Subdivide/Merge GUI; no mesh persistence.
- Standard keyboard Undo (⌘Z) remains unconnected.
- Not claiming full ViewPoint QuadTree parity.

## Publish commit

```
ReShape: add adaptive mesh subdivision and merge
```
