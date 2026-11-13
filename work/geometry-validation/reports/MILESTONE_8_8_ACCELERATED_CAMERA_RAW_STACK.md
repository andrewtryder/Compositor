# Milestone 8.8 — Accelerated correction stacks and full Camera Raw

Branch: `camera-raw-accelerated-correction-stack`  
Base head: `b6ef2fe20ebf4f0c044d12711486b3ebef74c4ff`  
Existing draft PR: https://github.com/andrewtryder/Compositor/pull/13

## Root cause of the original slow two-node stack

M8.7 cold CR→ReShape at 6000×4000 measured **~16.7 s**. Instrumentation showed:

1. **Camera Raw geometry** runs entirely on CPU (`CameraRawGeometryBackend.apply`) — typically several seconds at 24 MP.
2. **ReShape** used one-shot `MeshWarpRenderer.apply`, which allocates fresh shared Metal buffers, uploads the full RGBA source, runs the kernel, and readbacks every evaluation — even when only the mesh changed.
3. Interactive `MeshWarpEdit.commitImage` (~234 ms) already used a **resident** `MetalMeshWarpSession`; the stack path did not.

Cache hits (~0.12 ms) were already correct; the cold path paid full CPU CR + one-shot Metal every time.

Metal usage must not be inferred from `MTLCreateSystemDefaultDevice()` alone. Stage timings now record command completion, fallback reasons, upload/kernel/sync/readback splits, and tests assert Metal when the device path is available.

## GPU session architecture

`LayerCorrectionGPUContext` (session-owned on `EditorSession.correctionGPUContext`):

- Reuses source/destination textures per resolution key (bounded slot count, `maximumSlots = 2`).
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

### Synchronization policy (M8.8.1 hardening)

All slot metadata and dictionary mutation happen while holding an `NSLock`. `withLeasedSlot(key:body:)` obtains exclusive access to a slot (creating it if needed), runs `body` while the lock is released, and merges the returned `SlotResult` back under the lock. Callers must not nest or interleave leases on the same key, and must not call `invalidate`/`invalidateAll` concurrently with a lease.

- **Source identity safety**: the source `CGImage` is strongly retained (`Slot.sourceImage`) for as long as its uploaded texture is treated as current, so `ObjectIdentifier` cannot be reused by a different CGImage to cause false source-reuse hits.
- **Destination texture safety**: the slot's last command buffer is `waitUntilCompleted()` before the destination is rewritten.
- **Eviction safety**: victim slots are waited on before removal from the dictionary.
- **Failure paths**: failed Metal allocation or command execution fall back to CPU `MeshWarpRaster` without leaving stale pixels in resident slots.
- **Readback**: performed while holding the slot lease, then the `CGImage` is handed out.

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

## Measured performance

See `MILESTONE_8_8_PERF.txt` for actual M8.7 vs M8.8 medians side by side (measured in Debug on Apple M3 Pro, macOS 27.0.1).

Key results (Debug vs Release baseline):

| Size | Scenario | M8.7 (Release) | M8.8 (Debug) |
|---|---|---:|---:|
| 6000×4000 | Full MeshWarpEdit.commitImage | 233.78 ms | 268.73 ms |
| 6000×4000 | CR→ReShape cold (two-node) | 16672.60 ms | 16347.26 ms |
| 6000×4000 | ReShape only (resident GPU) | NOT MEASURED | 553.81 ms |
| 6000×4000 | Edit second node (upstream cached) | NOT MEASURED | 247.16 ms |
| 6000×4000 | Cache hit (stack re-render) | 0.12 ms | 0.08 ms |
| 6000×4000 | CPU MeshWarpRaster fallback | 47701.15 ms | 47106.64 ms |

M8.8 was measured in Debug; M8.7 in Release, so percentage speedup is indicative only. The two-node cold path is dominated by CPU Camera Raw geometry time, not the mesh stage; the mesh stage itself dropped from multi-second one-shot Metal (M8.7) to resident-GPU render (~554 ms for ReShape-only at 6000×4000 in Debug).

## ReleaseTestable test-host crash diagnosis

Both focused suites (`NonDestructiveCameraRawTests`, `NonDestructiveGeometryStackTests`) crash with `SIGABRT` under `ReleaseTestable` **before the test-host process establishes a connection**. Root cause: dyld library-load failure for Sparkle.framework — an ad-hoc code-signing Team ID mismatch in the test harness environment (`CODE_SIGN_IDENTITY=-`), not an application logic failure.

- Crash: `Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle ... code signature ... not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs`.
- Crash reports: `Compositor-2026-11-13-102606.ips` and `Compositor-2026-11-13-102742.ips` in `~/Library/Logs/DiagnosticReports/`.
- This is environmental; the same suites pass fully in Debug configuration.
- Production Release builds cleanly with `ENABLE_TESTABILITY=NO`.

## Export behavior

Export flattens the rendered layer `asset` (display). Baking commits stack output into ordinary pixels and clears the stack. Undo restores prior stack + caches regenerate on next render.

## Remaining limitations

- No GUI for the correction stack / full Camera Raw Smart Filter chrome.
- Expand to Fit + ReShape still unsupported (variable-size remapping not implemented).
- Full Camera Raw grade remains CPU Filter path (GPU lookup exists inside Filter for some tables; stack does not yet keep CR textures resident).
- 8-bit layers only for ND stacks.
- At most one geometry and one full Camera Raw node per stack.
- ReleaseTestable test-host crash is environmental (ad-hoc signing Team ID mismatch); not an application bug.

## Tests added (M8.8.1)

`NonDestructiveCameraRawTests`:
- `gpuContextSameSizeDifferentSource` — same-size slot must not collide across different sources.
- `gpuContextRepeatedSourceReplacement` — replacing then restoring a source must not serve stale pixels.
- `gpuContextCacheInvalidation` — invalidate then re-render must still use Metal.
- `gpuContextInvalidateAll` — invalidateAll then re-render must still use Metal.
- `gpuContextFallsBackWithoutStalePixels` — CPU fallback must produce correct warped output.

## Pending work

- ReleaseTestable test execution remains blocked by the ad-hoc signing Team ID mismatch; requires a properly signed test host to run optimized suites. Documented above; not categorized as an application logic failure.
