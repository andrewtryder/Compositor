# Milestone 8 — Mesh foundation + GPU-resident preview (through 8.1)

Manual ReShape mesh deformation as a document-level tool (peer to Liquify). Not Camera Raw. Not AI.

## Branch and baseline

| Item | Value |
| --- | --- |
| Worktree | `/Users/atr/code/Compositor-reshape-mesh` |
| Branch | `camera-raw-reshape-mesh` |
| Baseline | `ffb781dda07d16efdf968c981a83da8fc8add00f` (`camera-raw-volume-metal` Milestone 7 docs) |
| Host | Mac15,6 (Apple M3 Pro), macOS 27.0.1 |
| Builds measured | Debug and Release via `xcodebuild test`, ad-hoc signing |

Research preserved (exact contents from the investigation worktree):

- `work/geometry-validation/reports/VIEWPOINT_6_REFERENCE.md`
- `work/geometry-validation/reports/VIEWPOINT_6_RESHAPE_ANALYSIS.md`
- `work/geometry-validation/reports/MILESTONE_8_ARCHITECTURE.md`

No DxO images, `.dvp` files, private photographs, or proprietary resources were copied into source.

## Architecture phases completed

| Phase | Status |
| --- | --- |
| 0 — Branch + research preserved | Done |
| 1 — Mesh model, sticky borders, propagation, fold prevention | Done |
| 2 — Interactive overlay + tool UI (Apply / Cancel / Reset) | Done |
| 3 — CPU reference + Metal path + fallback | Done |
| 8.1 — GUI drag→preview→Apply smoke | Done (coordinate automation) |
| 8.1 — GPU-resident interactive preview | Done |
| Automated tests + parity | Done (extended) |
| Performance measurements | Done (Debug measured; Release see below) |

Out of scope (remaining Milestone 8 / later): multi-select, rotate/scale modes, subdivide/merge, custom non-square grids, non-destructive mesh persistence / project-format bump, AI masks, Camera Raw / Metal Volume / lens-correction UI changes.

## Files changed

### New

- `Compositor/Document/MeshWarpGrid.swift`
- `Compositor/Document/MeshWarpRaster.swift`
- `Compositor/Rendering/MetalMeshWarp.swift` — buffer kernel (Apply/parity) + texture kernel + `MetalMeshWarpSession` + `MeshWarpRenderer`
- `Compositor/Document/MeshWarpEdit.swift`
- `Compositor/UI/MeshWarpControls.swift`
- `CompositorTests/MeshWarpTests.swift`
- `CompositorTests/MeshWarpPerformanceTests.swift`

### Modified

- `Compositor/Document/EditorSession.swift` — `NavigationTool.reshape`, `meshWarpEdit`
- `Compositor/ContentView.swift` — ReShape tool header
- `Compositor/UI/CommandPalette.swift` — ReShape entry
- `Compositor/Rendering/EditorCanvas.swift` — GPU `place(live:)` preview; CG readback fallback; pointer drag
- `Compositor/Rendering/TransformOverlay.swift` — mesh overlay
- Reports under `work/geometry-validation/reports/`

## Mesh data structure

Dimensions are **control-point counts** (an 8×8 mesh has 64 points and 7×7 cells). Presets: 4×4, 8×8, 16×16.

Each point has rest UV, current UV, border status. Coordinates are normalized layer UV `(0,0)` top-left → `(1,1)` bottom-right, mapped through `LayerTransform` and `CanvasViewport` (zoom-invariant UV↔document).

## Interpolation and inverse mapping

Each cell is two triangles along the `(0,0)–(1,1)` diagonal. Rasterization is destination→source piecewise-affine with premultiplied bilinear sampling (out-of-range neighbors contribute 0). Fold / degeneracy checks reject moves that invert or collapse triangles. Sticky Borders pin edge points; Propagation blends neighbors by distance with a falloff.

## Preview / Apply architecture (8.1)

### Bottleneck before 8.1

Interactive preview called `MeshWarpRenderer.apply` every drag: CGImage→RGBA bytes, Metal buffer upload of the full source, kernel, readback, CGImage rebuild. At 6000×4000 Debug, kernel ~25 ms but preview E2E ~452 ms.

### GPU-resident path

1. On `MeshWarpEdit` begin, `MetalMeshWarpSession` uploads the original layer once into a reusable source texture and allocates a destination texture.
2. Each drag packs only triangle control-point data, encodes `mesh_warp_texture`, and waits for completion (ordering / no stale frames).
3. Preview is exposed as `CIImage(mtlTexture:)` and drawn with `placement.place(live:…)` on the GPU canvas — **no per-drag CPU readback**.
4. Source texture is never rewritten during the session (no progressive blur).
5. Apply re-renders the current mesh into the resident destination (if needed) and readbacks once into a `CGImage` for `layerByEditingPixels`.
6. Cancel / Reset / invalidate bump generation and drop the session; in-flight work is waited before teardown.
7. If Metal session creation fails, preview falls back to `MeshWarpRenderer` (Metal buffer or CPU).

CG canvas (`CompositorCPUCanvas` or GPU unsupported frames) still needs pixels; it readbacks once for that frame only.

## GUI smoke evidence (8.1)

Observed on Debug `Compositor.app` (pid 25512) with Computer Use coordinate automation (handles are not AX-exposed):

1. Imported `reshape-smoke-grid.png` (512×512 checker) → layer `reshape-smoke-grid`.
2. Selected **ReShape** → 8×8 mesh overlay aligned to the image; Sticky Borders on; Propagation ~25%; Apply disabled on identity.
3. Dragged a central control point (viewport-mapped from screenshot handle centroids; not hard-coded after zoom). Selected handle turned yellow and followed the pointer; mesh lines and checkerboard deformed locally; no folds or transparent holes observed.
4. **Apply** → mesh overlay dismissed; Transform tool active; warped pixels committed to the same layer; canvas remained 512×512; layer thumbnail updated.
5. **Undo** (⌘Z) → identity checker restored. **Redo** (⇧⌘Z) → warp restored.
6. Separate edit: drag then **Cancel** → previous Apply result retained; history unchanged by Cancel.
7. Separate edit: drag then **Reset Mesh** → identity mesh (Apply disabled); underlying committed layer unchanged.

Real photograph: not available in this worktree without importing private assets; synthetic grid was used. No private photos were staged.

## CPU/GPU parity

Tolerance: **max channel error ≤ 1**.

`MeshWarpTests.cpuGpuParityOnNontrivialMeshes` passed. Additional 8.1 tests passed:

- `gpuResidentPreviewMatchesApply` (preview destination readback == Apply)
- `rapidDragsStayOrderedAndCancelDropsGPUWork`
- `switchingGridSizesResetsPreview`
- `deepLayerIsRefused`
- Apply / Undo / Redo / Cancel session coverage
- Zoom-invariant UV mapping
- Cross-layer isolation

## Performance

Warm medians. Raw Debug: `MILESTONE_8_MESH_PERF.txt` / `MILESTONE_8_MESH_PERF_DEBUG.txt`. Host Mac15,6.

### Before (Debug, buffer path E2E as “preview”)

| Size | kernel | preview E2E | Apply E2E |
| --- | ---: | ---: | ---: |
| 1024×1024 | 3.23 ms | 19.4 ms | 19.8 ms |
| 4000×3000 | 13.0 ms | 200 ms | 200 ms |
| 6000×4000 | 25.9 ms | 452 ms | 388 ms |

### After (Debug, GPU-resident session)

| Size | meshUpdate | CPU | upload | kernel | readback | previewBuffer | residentPreview | residentKernel | Apply |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1024×1024 | 0.04 ms | 1960 ms | 0.28 ms | 2.04 ms | 0.18 ms | 17.4 ms | **1.88 ms** | 1.77 ms | 10.7 ms |
| 4000×3000 | 0.03 ms | 22237 ms | 3.96 ms | 13.0 ms | 2.86 ms | 184 ms | **13.0 ms** | 12.8 ms | 119 ms |
| 6000×4000 | 0.02 ms | 45437 ms | 11.6 ms | 25.3 ms | 6.17 ms | 305 ms | **25.3 ms** | 25.2 ms | 205 ms |

`residentPreview` tracks encode+wait for the texture path (no source re-upload, no readback). Interactive preview latency is now dominated by the Metal kernel itself. Full canvas present still adds Core Image / drawable work on top; pointer interaction stayed responsive on the 512 smoke grid and is expected to remain smooth at typical photo sizes given ~13 ms resident work at 12 MP.

Release: `Compositor` Release **app** builds cleanly. The Release **CompositorTests** target currently fails to compile against the Release module (`Unable to resolve Swift module dependency to a compatible module: 'Compositor'`), so warm Release medians were not captured in this pass. Interactive preview is already kernel-bound in Debug (`residentPreview ≈ residentKernel`), so Release is not expected to change the qualitative conclusion; re-measure Release after the test-module issue is cleared.

## Undo / Redo / Cancel

Apply records one `"ReShape"` history entry. Undo restores pre-Apply pixels; Redo reapplies. Cancel never touches history. Reset restores identity mesh without baking. Confirmed in automated tests and GUI smoke.

## CPU fallback

Still used as reference and when Metal is unavailable. Algorithm already rasterizes per-triangle destination bounding boxes (not a full per-pixel search over all triangles). Cost at large sizes is dominated by scalar nested loops + bilinear sampling over many overlapping triangle bboxes (~22–45 s Debug at 12–24 MP). **Deferred**: vectorization / tighter cell lookup without changing the deformation math. UI should keep Metal primary; if CPU fallback is forced on a large image, run off the main interactive path (current Apply path blocks until complete — known limitation).

## Unsupported / gated

- Deep / HDR layers refused at begin (message requires 8-bit); cannot silently flatten.
- No cross-layer edits; masks / transforms left as at begin; canvas size stable.
- Transparent borders remain transparent outside content.
- No editable mesh persistence / project-format bump yet.

## Remaining blockers / follow-ups

1. Release warm medians file (clean Release suite) — confirm parity with Debug resident gains.
2. Optional: share `GPUCanvasRenderer` command queue so preview encode need not `waitUntilCompleted` before CI present (further cut main-thread wait).
3. Adaptive lower-resolution drag preview only if main-thread wait remains perceptible at 6K after queue sharing — do not reduce Apply quality.
4. AX identifiers for individual mesh handles (automation currently uses coordinates).
5. Later phases: subdiv/merge, region transforms, AI selection, mesh persistence.

## Proposed commit (do not create yet)

```
Add interactive ReShape mesh with GPU-resident preview and CPU fallback
```

### Proposed staged-file list

```
Compositor/ContentView.swift
Compositor/Document/EditorSession.swift
Compositor/Document/MeshWarpEdit.swift
Compositor/Document/MeshWarpGrid.swift
Compositor/Document/MeshWarpRaster.swift
Compositor/Rendering/EditorCanvas.swift
Compositor/Rendering/MetalMeshWarp.swift
Compositor/Rendering/TransformOverlay.swift
Compositor/UI/CommandPalette.swift
Compositor/UI/MeshWarpControls.swift
CompositorTests/MeshWarpTests.swift
CompositorTests/MeshWarpPerformanceTests.swift
work/geometry-validation/reports/MILESTONE_8_ARCHITECTURE.md
work/geometry-validation/reports/MILESTONE_8_MESH_FOUNDATION.md
work/geometry-validation/reports/MILESTONE_8_MESH_PERF.txt
work/geometry-validation/reports/MILESTONE_8_MESH_PERF_DEBUG.txt
work/geometry-validation/reports/VIEWPOINT_6_REFERENCE.md
work/geometry-validation/reports/VIEWPOINT_6_RESHAPE_ANALYSIS.md
```

Stop before commit or push pending approval.
