# Milestone 8.6 — Unified Camera Raw Geometry + Persistent ReShape

Worktree: `/Users/atr/code/Compositor-geometry-integration`  
Branch: `camera-raw-unified-geometry-backend`  
Base: ReShape persistence `f4757c93994fd73dd12750a8cc4bf612bc839118` (PR #10)  
Integrated: Camera Raw geometry `1b50a80f26ca3d881ab00035d5f09bc1c1594828` (PR #6)  
Status: **working tree ready for review — not committed / not pushed**

## Integration approach

1. Created worktree/branch from PR #10 tip.
2. `git merge --no-commit --no-ff` of PR #6 tip to preserve both histories.
3. Only content conflict: `Compositor.xcodeproj/project.pbxproj` Release `ENABLE_TESTABILITY` comment.
4. `Filters.swift` auto-merged cleanly: Expand/Horizon/Miniature path + ReShape bake refusal both present.
5. Added `UnifiedGeometryBackend` contracts and combined tests without folding mesh math into the global homography pipeline.

## Conflict resolutions

| File | Resolution |
| --- | --- |
| `project.pbxproj` | Kept `ENABLE_TESTABILITY = YES` for Release tests; comment documents provisional shipping risk and preference for a future `ReleaseTestable` config |
| `Filters.swift` | Auto-merge retained geometry Expand placement + reshape destructive refusal |
| New Camera Raw geometry sources | Taken from PR #6 |
| ReShape persistence / mesh stack | Taken from PR #10 |

No Auto Full ranking changes. No GUI. No DxO assets.

## Authoritative correction model

| Domain | Owner | Math |
| --- | --- | --- |
| Global Camera Raw geometry | `CameraRawGeometryBackend` / `CameraRawSettings.applyResult` | Lens → Volume → Perspective → Horizon → Framing/Crop → Miniature → color |
| Local editable mesh | `MeshWarp*` + `LayerReshape` | Adaptive UV mesh; GPU-resident preview; Apply from immutable source |
| Document placement | `ImageLayer` / masks / transforms | Independent of either correction’s internal UV/pixel spaces |

They remain **separate operations**. A later Smart-Filter stack is documented in `UnifiedGeometryBackend.futureNonDestructiveStackNotes` but not implemented.

## Layer and source-asset rules

- Ordinary layer + Camera Raw: destructive apply; Expand placement only moves that layer.
- Ordinary layer + ReShape: stores source + mesh + display; re-edit from source.
- Sibling layers: both may coexist in one document/project.
- Camera Raw on editable ReShape: **refused** with bake-required message; data retained.
- Explicit `bakeReshape` / `bakeReshapeForCameraRaw`, then Camera Raw allowed.
- Project v22 round-trips reshape sources/meshes; corrupt reshape rejects without replacing the live document.

## Precision

- Expand to Fit: 8-bit only; 16-bit/HDR coerced to Keep Original Size / refused on deep Expand commit path.
- ReShape: 8-bit only; never silently converts deep/HDR.

## Undo / Redo / save / export

- One document history entry per ReShape Apply / Bake; Camera Raw filter commit uses existing filter history.
- Save/load preserves mesh + source + display; export uses rendered display assets.
- Canvas Size / Image Size / duplicate preserve reshape (from M8.5).

## Tests

- `UnifiedGeometryBackendTests` (21) — Debug **passed**
- Retained: MeshWarp foundation/topology/local/persistence; Camera Raw geometry backend/safety/intensity
- Photographic fixtures (window-wall / stone-house / library-atrium) remain available via existing suites
- Debug regression (persistence + geometry + mesh + local + perf): **passed**
- Release focused (`UnifiedGeometryBackendTests` + `MeshWarpPersistenceTests` + `CameraRawGeometrySafetyTests`): **passed**

## Performance

See `MILESTONE_8_6_PERF.txt` (actual medians). Note: full-res mesh Apply numbers are **CPU raster** wall times; warm GPU preview is separate and much faster. Do not treat Metal kernel time as full interaction latency.

## Remaining GUI requirements (not this milestone)

Documented in `UnifiedGeometryBackend.guiPlacement`:

- Camera Raw → Geometry / Optics
- Edit → Transform → Warp (ReShape)
- Filter → Blur Gallery (Miniature)

## Outstanding backend limitations

- No Smart-Filter non-destructive Camera Raw+ReShape stack on one layer
- No deep/HDR ReShape
- No 16-bit Expand infrastructure
- Release still uses provisional `ENABLE_TESTABILITY=YES` (shipping concern)
- Standard keyboard Undo for tool-local mesh history deferred
