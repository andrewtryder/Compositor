# Milestone 8.4 — Local Perspective, Horizon, and Volume on ReShape

Branch: `camera-raw-reshape-local-geometry`  
Worktree: `/Users/atr/code/Compositor-reshape-local`  
Baseline: Milestone 8.3 `4016e600ee835aaf006bcc338cffa14be57dfe50` (PR #8)  
Status: implemented locally — **not committed / not pushed**

## Selected-region representation

`MeshWarpCorrectionRegion` holds:

- Stable `vertexIDs` and optional `faceIDs`
- `MeshWarpDisjointRegionPolicy`: `.independent` (default) or `.unified`
- Pivot = barycenter of each component’s snapshot positions
- Bounding box from component UV extents → pixel half-extent for local models

`connectedComponents` walks leaf-face adjacency among selected seeds so disconnected patches do not share a bbox unless `.unified` is requested.

Coordinates:

| Space | Role |
| --- | --- |
| Rest UV | Sticky classification, propagation distances |
| Current / snapshot UV | Mesh positions at operation start |
| Image pixels | Homography / horizon / volume math |
| Document | Overlay hit-testing only (unchanged) |

Each local op snapshots positions at begin; displacements are absolute from that snapshot (no accumulative intermediate writes).

## Local perspective

`MeshWarpLocalPerspective` / `.perspective(...)` via `MeshWarpGrid.applyLocalCorrection`.

Modes: `fourPoint` (DLT homography), `vertical`, `horizontal`, `combined` (local keystone undo about the region pivot). Amount 0…1; 0 is identity.

`MeshWarpHomography.fromCorrespondences` builds a normalized 3×3 from four pixel pairs; rejects degenerate quads, singular matrices, non-finite mappings.

Blending: `output = current + weight * (projected − current)` with propagation weights on non-seeds (same recovered ViewPoint-style linear weight as Milestone 8.2).

## Local horizon

`MeshWarpLocalHorizon`: manual `angle`, `horizontalReference`, `verticalReference`. Endpoint order does not change the leveling angle (undirected). Amount scales the leveling rotation about the region pivot.

## Local volume

`MeshWarpLocalVolume` modes: `horizontal`, `vertical`, `radial`, `combined`. Strength ≈ −1…1 with excursion clamp relative to region half-extent. Independent of Camera Raw `volume_deform` / Metal volume (not merged).

## Unified execution path

`MeshWarpGrid.applyLocalCorrection`:

1. Snapshot positions  
2. Resolve components  
3. Desired pixel → UV per seed  
4. Propagation blend for others  
5. Sticky constraints  
6. Leaf-triangle validity (fold / degeneracy)  
7. Atomic install into topology + dense arrays  

`MeshWarpEdit.applyLocalCorrection` wraps that with tool-local history + GPU preview refresh. Common Metal mesh rasterizer only — no per-tool full-image resample.

## Propagation and sticky borders

Unchanged formulas. Seeds get the full desired map (sticky-constrained). Non-seeds interpolate toward the same correction. Corners stay pinned when sticky; edges slide. Folding installs are rejected with `MeshWarpLocalStatus` (no silent alternate transform).

## Adaptive topology compatibility

Phase 1 replaced cascade conforming with **hanging-edge triangulation**:

- Requested leaves only receive 1→4 splits (atomic trial + commit).
- Shared midpoints hang on neighbor leaves; `triangles()` bisects the regular two-triangle split along hanging edges (no zero-area fan).
- Leaves that inherit midpoints on all four edges are force-promoted (bounded), not a whole-mesh flood.
- Budgets: `maxVertices`, `maxFaces`, `maxSubdivisionDepth`, `maxTriangles` — over-budget ops leave topology unchanged.

## Fold / degeneracy rejection

- Homography: degenerate quads, singular / non-finite maps  
- Volume: non-finite or excessive travel  
- Install: `leafTrianglesValid` orientation + area checks  

## GPU rendering and CPU/GPU parity

Same `mesh.triangles()` feed CPU `MeshWarpRaster` and Metal. Source texture remains session-resident; local ops only refresh triangle buffers. Parity tests allow ≤1 channel.

## Undo / Redo

Each successful local correction pushes one `MeshWarpHistory` snapshot (mesh + selection). Composition Move → Perspective → Horizon → Volume is undoable stepwise. Cancel drops the session; Apply is one document entry. Keyboard ⌘Z still unwired.

## Performance

See `/tmp/MILESTONE_8_4_LOCAL_PERF.txt` from `MeshWarpPerformanceTests.localCorrectionAndAdaptiveWarmMedians` (kernel ms ≠ pointer-to-display latency). Regular vs adaptive kernels compared at 1024² / 4k / 6k.

## Tests

`CompositorTests/MeshWarpLocalGeometryTests.swift` — growth locality, budgets, identity, perspective / horizon / volume, propagation, sticky, disjoint regions, adaptive composition, history, CPU/GPU parity, no cumulative resampling.

## Known limitations

- No unified GUI; no screenshot tests  
- No mesh persistence / project-format bump  
- ⌘Z not connected  
- Local models are clean-room approximations — not claiming DxO numerical equivalence  
- Strong local volume + high propagation can fold and is rejected rather than auto-clamped  
- Geometry-backend / Auto Perspective / Camera Raw volume branches not merged  

## Proposed commit (do not create yet)

```
ReShape: add adaptive local perspective, horizon and volume corrections
```
