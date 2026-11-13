# Milestone 8.8 — Accelerated correction stacks and full Camera Raw

Branch: `camera-raw-accelerated-correction-stack`  
Base: `camera-raw-nondestructive-geometry` (PR #12 head `8455d41`)

## Root cause of the original slow two-node stack

M8.7 cold CR→ReShape at 6000×4000 measured **~16.7 s**. Instrumentation showed:

1. **Camera Raw geometry** runs entirely on CPU (`CameraRawGeometryBackend.apply`) — typically several seconds at 24 MP.
2. **ReShape** used one-shot `MeshWarpRenderer.apply`, which allocates fresh shared Metal buffers, uploads the full RGBA source, runs the kernel, and readbacks every evaluation — even when only the mesh changed.
3. Interactive `MeshWarpEdit.commitImage` (~234 ms) already used a **resident** `MetalMeshWarpSession`; the stack path did not.

Cache hits (~0.12 ms) were already correct; the cold path paid full CPU CR + one-shot Metal every time.

Metal usage must not be inferred from `MTLCreateSystemDefaultDevice()` alone. Stage timings now record command completion, fallback reasons, upload/kernel/sync/readback splits, and tests assert Metal when the device path is available.

## GPU session architecture

`LayerCorrectionGPUContext` (session-owned on `EditorSession.correctionGPUContext`):

- Reuses source/destination textures per resolution key (bounded slot count).
- Uploads upstream source only when `ObjectIdentifier(CGImage)` changes.
- Rewrites triangle buffers on every mesh change.
- Waits for the prior command buffer before rewriting a destination texture.
- Falls back to `MeshWarpRaster` with an explicit reason string.
- Never stored in serializable document models.

Render modes:

| Mode | Path |
|---|---|
| Interactive GPU preview | `MetalMeshWarpSession` inside `MeshWarpEdit` |
| Full-resolution stack evaluation | `LayerCorrectionRenderer` + optional `gpuContext` |
| Final CPU-readable commit/export | CGImage readback after command completion |

## Memory / cache ownership

- Stage caches remain session-only on `LayerCorrectionStack.stageCache`.
- `invalidateFromIndex` keeps upstream entries and retags their revision.
- Enable/disable, reorder, bake, and source replacement bump or invalidate correctly.
- Soft bound: `maximumCachedStages` (16) and GPU `maximumSlots` (2).
- Baking or clearing a stack calls `correctionGPUContext.invalidateAll()`.

## Full Camera Raw persistence model

- New node kind: `cameraRawFull`.
- Live type: `CameraRawSettings` (unchanged Filter model).
- On-disk: `CameraRawSettingsPersistentState` (schema 1) — explicit defaults for missing keys.
- Stack schema: write **1** for geometry/reshape-only; write **2** when `cameraRawFull` is present.
- Project format: **24** when full Camera Raw is present; **23** for geometry stacks; **22** reshape-only.
- Evaluation calls `CameraRawSettings.applyResult` — no duplicate color engine.
- Expand to Fit + ReShape still refused (not silently coerced).

Coverage: light, color/WB, mixer, grading, curve, effects, detail/NR, optics, geometry, calibration, horizon, perspective tools, Miniature.

## Compatibility / migration

| Package | Behavior |
|---|---|
| v22 reshape-only | Unchanged |
| v23 geometry/reshape stacks (schema 1) | Load/save unchanged |
| v24 + `cameraRawFull` | New; rejected by older builds |
| Missing CR color keys | Explicit defaults (do not regrade old photos) |

## Numerical comparison

- Full Camera Raw stack output matches standalone `CameraRawSettings.apply` byte-for-byte on synthetic fixtures.
- CPU/GPU mesh parity target retained: ≤1 channel delta on checkerboard identity/nontrivial meshes.
- Cached vs uncached pixel equality asserted.

## Cold / warm performance

See `MILESTONE_8_8_PERF.txt` for measured medians. Expected shape:

- Mesh-only cold approaches resident GPU + readback (not CPU tens of seconds).
- Two-node cold still includes CPU Camera Raw geometry/full grade time; mesh stage is no longer the multi-second Metal one-shot tax.
- Editing the second node reuses the upstream stage cache.
- Cache hits remain sub-millisecond.

## Export behavior

Export flattens the rendered layer `asset` (display). Baking commits stack output into ordinary pixels and clears the stack. Undo restores prior stack + caches regenerate on next render.

## Remaining limitations

- No GUI for the correction stack / full Camera Raw Smart Filter chrome.
- Expand to Fit + ReShape still unsupported (variable-size remapping not implemented).
- Full Camera Raw grade remains CPU Filter path (GPU lookup exists inside Filter for some tables; stack does not yet keep CR textures resident).
- 8-bit layers only for ND stacks.
- At most one geometry and one full Camera Raw node per stack.
