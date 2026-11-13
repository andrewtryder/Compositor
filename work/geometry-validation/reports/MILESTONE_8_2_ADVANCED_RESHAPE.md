# Milestone 8.2 — Advanced ReShape (backend)

Branch: `camera-raw-reshape-advanced`  
Worktree: `/Users/atr/code/Compositor-reshape-advanced`  
Baseline: `ff4b979150e46b0aac07f2bde5318025ec8f8ff9` (Milestone 8.1 / PR #4)  
Status: **implementation complete for Phases 1–5; Subdivide/Merge deferred** (not committed yet)

No GUI redesign. No screenshots. No new ViewPoint RE. Geometry-backend / Auto Perspective / Metal Volume untouched.

## Architecture

| Layer | Role |
| --- | --- |
| `MeshWarpGrid` | Regular UV lattice, linear propagation, sticky constraints, selection transforms, fold checks |
| `MeshWarpSelection` | Stable `MeshWarpVertexID` multi-select (shift / marquee / all / clear) |
| `MeshWarpHistory` | Tool-local undo/redo snapshots (positions + selection) |
| `MeshWarpEdit` | Session state, gesture base snapshots (anti-drift), GPU-resident preview |
| `MetalMeshWarp` / `MeshWarpRaster` | Unchanged triangle raster; source texture immutable during edit |
| Document Apply | One `beginEdit("ReShape")` / `endEdit()` entry; Cancel drops session |

## Verified ViewPoint behavior being reproduced (clean-room)

From prior recovery (`TransformationWithPropagation::GetWeightForPropagation`):

```
w = clamp(1 + (p - 1) * d / (n * p + ε), 0, 1)
```

- `p` ∈ [0,1] propagation strength  
- `d` Euclidean distance in **pixel space** between rest UVs mapped by image size  
- `n = max(imageWidth, imageHeight)`  
- `ε = 1e-4`

Sticky Borders (recovered semantics):

| Class | Behavior |
| --- | --- |
| Corner | Pinned when sticky |
| Non-corner border | Slides along its edge |
| Interior | Free (fold-checked) |

## Independent algorithms selected

- Linear falloff weight (above) — **not** TPS / Laplacian / global energy  
- Absolute displacement from gesture-start snapshot — avoids cumulative drift  
- Selection transforms: full transform on selection; neighbors get the same transform scaled by weight to nearest selected rest point  
- Pivot = selection barycenter  
- Fold rejection unchanged (`trianglesValid`)

## Propagation equations

See formula above. Extremes:

- `p = 0` → only `d ≈ 0` (the handle) receives `w = 1`  
- `p = 1` → `w = 1` for all vertices  

## Border constraints

`constrainSticky(index:proposed:)` projects edge moves onto the edge line and rejects corner motion when sticky. Applied to primary moves, propagated neighbors, and selection transforms.

## Selection transformations

- Stable IDs: `MeshWarpVertexID(rawValue: index)` valid until preset/topology change  
- Modes: Move / Rotate / Scale (+ reset selected points to rest)  
- Multi-select drag uses translation of the primary relative to gesture base  

## Topology representation

Still a **regular grid** (`pointColumns` × `pointRows`) with two triangles per cell. Compatible with existing Metal triangle upload.

### Subdivide / Merge

**Incomplete.** `MeshWarpGrid.topologyOpsSupported == false`. Local adaptive quads (shared midpoints / child groups) are deferred rather than faking a global density change or copying DxO QuadTree structure. Stubs return `false` with an explicit message.

## Rendering and parity

- GPU-resident preview preserved; source texture not rewritten during editing  
- CPU fallback preserved  
- `cpuGpuParityWithLinearPropagation` expects max channel error ≤ 1  

## Performance

No intentional change to the Metal kernel path. Triangle buffer still updates per drag; source upload once per session. New selection/history costs are CPU-side O(points). Re-measure after commit if needed; 8.1 timing baselines remain in `MILESTONE_8_MESH_PERF*.txt`.

## Test results

| Suite | Debug | Release |
| --- | --- | --- |
| `MeshWarpAdvancedTests` | passed | passed (after provisional `ENABLE_TESTABILITY`) |
| `MeshWarpTests` | passed (sticky test updated for edge slide) | passed |

Covered: propagation formula samples, prop 0/1, anti-drift, sticky corners/edges, selection IDs, rotate/scale, fold reject, tool history, Apply/Cancel isolation, Subdivide/Merge incomplete markers, CPU/GPU parity.

Release `ENABLE_TESTABILITY = YES` is **provisional** (same rationale as PR #6): required for `@testable import Compositor` under Release; must be limited to test builds before production distribution. Optimization settings unchanged.

## Known limitations

- Local Subdivide/Merge not implemented  
- Marquee / shift / transform modes are model + session APIs; polished multi-tool GUI deferred  
- Tool Undo/Redo not yet bound to ⌘Z while ReShape is open (API: `meshWarpToolUndo` / `meshWarpToolRedo`)  
- No non-destructive mesh persistence / project-format bump  
- 8-bit layers only (unchanged from 8.1)  
- GUI validation of advanced transforms not in this milestone  

## Code-complete vs awaiting GUI validation

| Feature | Code | GUI validation |
| --- | --- | --- |
| Linear propagation | Complete | Pending |
| Sticky edge slide | Complete | Pending |
| Multi-select model | Complete | Pending (overlay shows selection) |
| Move/Rotate/Scale | Complete (session APIs) | Pending |
| Tool-local history | Complete | Pending (key binding) |
| Subdivide/Merge | Incomplete | — |
| GPU preview / Apply | Complete (8.1) | Done in 8.1 smoke |

## Proposed commit message (do not create yet)

```
ReShape: linear propagation, sticky edge slide, multi-select transforms

Replace smoothstep falloff with the recovered pixel-space weight; pin
corners while sliding edges; add selection, similarity transforms, and
tool-local history. Defer adaptive Subdivide/Merge.
```
