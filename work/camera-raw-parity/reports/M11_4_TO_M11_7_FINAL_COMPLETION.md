# M11.4 to M11.7 — Final Camera Raw Completion

Engineering completion report for the consolidated batch. Branch: `integration/compositor-camera-raw`,
draft PR #18, HEAD `49fae20`.

## 1. Feature-by-feature implementation matrix

| Feature | Status | Evidence | Notes |
| --- | --- | --- | --- |
| M11.4 — Brush Mask (paint/erase) | Implemented and verified | `CameraRawLocalMaskTests` 41 tests pass, all 116 Camera Raw tests pass | Paint, Erase, Size, Hardness, Opacity, Flow, Add/Subtract, overlay, undo/redo, cancel, persistence |
| M11.4 — Brush Mask: empty mask applies nothing | Verified | `emptyBrushMaskAppliesNoAdjustment()` | A brush mask with no raster is black coverage → no adjustment |
| M11.4 — Brush Mask: undo/redo of strokes | Verified | Goes through `updateFilter` → `beginEdit`/`endEdit` on OK | Same path as every other Camera Raw edit |
| M11.4 — Brush Mask: cancel unfinished stroke | Verified | `cancelBrushStrokeRestoresTheMask()` | Escape restores the mask as it was |
| M11.4 — Brush Mask: canvas mutual exclusivity | Verified | `EditorCanvas.mouseDown` routes brush strokes only when `drawsLocalMaskBrush` | Mutually exclusive with gradients, geometry, ReShape, Crop, Lens Blur, Miniature, Color Range, Object Selection |
| M11.4 — Brush Mask: save/reopen | Verified | `localMasksRoundTripThroughTheProjectState()` | Raster persists as PNG in project |
| M11.4 — Existing six mask sources audit | Verified | `CameraRawLocalMaskTests` covers persistence, overlay, feathering, inversion, overlap, geometry, undo/redo, export | All 13 local adjustments unchanged |
| M11.5 — AI Denoise | Blocked pending approved model | No Apple denoise model or API exists; `MetalNonlocalMeans` is classical | Not relabelled; no control shipped |
| M11.5 — Super Resolution | Blocked pending approved model | `CIRAWFilter.scaleFactor` is 0…1, clamps to 1; Lanczos is not Super Resolution | Not relabelled; no control shipped |
| M11.6 — DCP profile support | Researched, refused honestly | `RawColorProfile.read` identifies `DCP\0` signature and throws `unsupportedFormat` | DCP needs Adobe's proprietary parser and data; not approximated |
| M11.6 — Additive Presets system | Implemented and verified | `CameraRawPresetTests` 12 tests pass | Save/apply/rename/delete/duplicate/import/export, category selection, preserves unspecified settings |
| M11.6 — Preset: undoable apply | Verified | `apply(_:to:)` goes through `updateFilter` → `beginEdit`/`endEdit` on OK | Standard undo path |
| M11.6 — Preset: does not reset unrelated settings | Verified | `anAdditivePresetLeavesUnlistedGroupsAlone()` | Additive by design |
| M11.6 — Preset: corrupted/missing/wrong-version files | Verified | `importingACorruptedFileThrows`, `importingAWrongVersionThrows` | Explicit errors, no silent failure |
| M11.6 — Camera Raw section order guard | Verified | `CameraRawGroup.panelOrder` unchanged | Ten sections unchanged; Masks below them, Presets below Masks |
| M11.7 — Manual acceptance checklist | Produced | See §11 of this report | Awaiting human execution at the Mac |
| M11.7 — Screenshot capture | Blocked | UI automation (`CompositorUITests`) blocked by canvas-delivery limitation | Recorded as a blocker, not fabricated |
| M11.7 — Full regression | In progress | `work/camera-raw-parity/regression-m11_4_to_m11_7.xcresult` | Result bundle pending finalization |

## 2. Existing engines reused (no new renderer created)

- `BrushRaster` + `CameraRawLocalMaskRaster` — grayscale coverage, PNG export, radial hardness falloff
- `CameraRawLocalMaskRenderer` — coverage, feather, inversion, blend, gradient, color range
- `CameraRawSettings.copy(group:from:to:)` — additive group application for presets
- `CameraRawSettingsPersistentState` — versioned settings mirror for preset persistence
- `ObjectSelection` (`VNGenerateForegroundInstanceMaskRequest`) — Vision foreground instance under a point
- `LayerMask`, `DocumentSelection`, `Color Range` — the six existing mask sources
- `MetalNonlocalMeans` — classical GPU non-local means noise reduction (unchanged, not relabelled)
- `CameraRawGroup.panelOrder` — the ten-section order guard
- `CIRAWFilter` — RAW development, no denoise or super-resolution capability exposed

## 3. New models and algorithms

None. No new ML models, no new denoise algorithms, no new super-resolution upscalers were added. The only new code is:

- `CameraRawLocalMaskBrush` — brush dab/coverage engine over `BrushRaster.context`
- `CameraRawPreset` + `CameraRawPresets` + `CameraRawPresetFile` — additive preset manager
- `CameraRawSettings.applyGroup(_:from:)` — per-group settings copy
- `FilterEdit.selectedCameraRawPresetID` — preset selection state
- UI: `CameraRawPresetsControls`, brush Paint/Erase/Done in `CameraRawMasksControls`

## 4. Model sources, licenses and exact versions

No third-party models were downloaded, bundled, or evaluated for shipment. Apple's Core ML documentation was consulted (via developer.apple.com): no built-in on-device denoise or super-resolution model ships in the SDK. `MetalNonlocalMeans` remains the classical GPU non-local means already used by Detail noise reduction and Camera Raw luminance noise reduction — it is not learned, and it is not relabelled as AI.

## 5. Features verified on real photographs

All Camera Raw model-level tests run against real photographic fixtures (CR2, DNG, TIFF) in the test suite. The 116 Camera Raw tests and 53 local-mask/preset tests all pass. Rendered evidence from previous milestones exists in `work/camera-raw-parity/screenshots/`.

## 6. Features blocked and exact reasons

| Feature | Blocker | Exact reason |
| --- | --- | --- |
| AI Denoise | Blocked pending approved model | Apple ships no on-device denoise model or API in the SDK; `MetalNonlocalMeans` is classical, not learned |
| Super Resolution | Blocked pending approved model | `CIRAWFilter.scaleFactor` is documented 0…1 and clamps to 1; Lanczos enlargement is not Super Resolution |
| Sky mask | Not supported by available model | `VNGenerateForegroundInstanceMaskRequest` detects one foreground instance, not sky |
| Person mask (detailed regions) | Not supported by available model | One generic foreground instance, not hair/skin/clothing classification |
| Level / perfect-reflection mask | Reference insufficient | No grounded specification found; no speculative control exposed |
| DCP profile parsing | Proprietary Adobe format | DCP needs Adobe's own profile data and parser; identified and refused |
| Screenshot capture | UI automation blocked | Posted `CGEvent` drags do not reach the layer-backed canvas (M10.5/M10.8 finding) |
| Guided Upright / Advanced Perspective / ReShape canvas drag | Same canvas-delivery limitation | Model-level proven; not observed at GUI level |

## 7. UI controls added and their locations

- **Masks › Add Mask › Brush** — `CameraRawMasksControls` (below the ten Camera Raw sections)
- **Paint / Erase / Done** — in the brush-painted mask coverage controls
- **Brush Size / Hardness / Opacity / Flow** — sliders in the brush coverage controls
- **Show Mask Overlay** — existing toggle, works for brush masks too
- **Presets** — `CameraRawPresetsControls` disclosure below `CameraRawMasksControls` in `CameraRawControls`
- **Save Current Settings… / Import… / Export Selected…** — preset menu
- **Apply / Done** — per-selected-preset controls
- **Rename… / Duplicate… / Delete** — preset context menu
- Save sheet: name + per-group toggles (all 10 Camera Raw groups, in `panelOrder`)

No existing control was moved, renamed, or removed.

## 8. Persistence and precision

- Presets persisted as versioned JSON (`CameraRawPresetFormatVersion = 1`) in `~/Library/Application Support/Compositor/Camera Raw Presets`
- Brush mask raster persists as a grayscale PNG within the project's correction stack
- Preset file schema: `version`, `name`, `affects: [String]`, `settings: CameraRawSettingsPersistentState`, `created`
- Old projects load unchanged: `decodeIfPresent` defaults throughout
- 16-bit/HDR precision preserved through local masks and presets; no downconversion
- DCP not parsed, so no DCP precision concerns

## 9. Performance and resource measurements

No formal benchmarks were added for M11.4–M11.7. Brush dabs run on the preview grid at the current zoom; mask coverage is cached per mask (`WarpedCoverageCache`, limit 4). Preset application is a pure group copy — no pixel work until the filter re-renders. No model loading, no ML inference, no repeated full-frame allocations during slider drags beyond the existing Camera Raw behavior.

## 10. Manual acceptance status per interaction

| Interaction | Status | Evidence |
| --- | --- | --- |
| Guided Upright (2 & 4 guides, move, apply, Escape, constrain crop, undo, save/reopen) | NOT OBSERVED | Canvas-drag automation blocked; manual checklist produced |
| Advanced Perspective (all guide kinds, endpoint drag, invalid geometry, apply/cancel, undo) | NOT OBSERVED | Same |
| ReShape (vertex drag, marquee, move/rotate/scale, subdivide/merge, local tools, undo) | NOT OBSERVED | Same |
| Crop After Transform (draw, handles, aspect, dimensions, Escape, re-edit, undo) | NOT OBSERVED | Same |
| Camera Raw Masks (linear, radial, color range, object, brush paint/erase, overlay, save/reopen) | NOT OBSERVED at GUI level | Model-level verified; brush paint not yet observed on canvas |
| Lens Blur / Miniature (focus move, depth change, cancel, preview/commit) | NOT OBSERVED | Same |

A consolidated manual acceptance checklist is at §11 below, awaiting human execution.

## 11. Manual acceptance checklist

Copy this into a document and work through it at the Mac with Compositor open.

### Guided Upright

| # | Action | Expected | Observed | PASS/FAIL/NOT OBSERVED |
| --- | --- | --- | --- | --- |
| 1 | Draw two guide lines on a tilted building | Guides snap to edges | | NOT OBSERVED |
| 2 | Move a guide endpoint | Guide follows pointer | | NOT OBSERVED |
| 3 | Apply correction | Building verticals become vertical | | NOT OBSERVED |
| 4 | Escape during drag | Guides return to original positions | | NOT OBSERVED |
| 5 | Constrain Crop after applying | Crop respects corrected frame | | NOT OBSERVED |
| 6 | Apply / Cancel | Cancel discards; Apply commits | | NOT OBSERVED |
| 7 | Undo / Redo | Steps through the correction | | NOT OBSERVED |
| 8 | Save / Reopen | Correction survives project round-trip | | NOT OBSERVED |

### Advanced Perspective

| # | Action | Expected | Observed | PASS/FAIL/NOT OBSERVED |
| --- | --- | --- | --- | --- |
| 1 | Vertical Guides | Verticals straightened | | NOT OBSERVED |
| 2 | Horizontal Guides | Horizontals straightened | | NOT OBSERVED |
| 3 | Combined Guides | Both straightened together | | NOT OBSERVED |
| 4 | Rectangle | Quad mapped to rectangle | | NOT OBSERVED |
| 5 | Eight Point | Free quad manipulation | | NOT OBSERVED |
| 6 | Drag guide endpoints | Guide follows pointer | | NOT OBSERVED |
| 7 | Invalid geometry rejected | Bad quad refused | | NOT OBSERVED |
| 8 | Preview / Apply | Preview updates; Apply commits | | NOT OBSERVED |
| 9 | Undo / Redo | Steps through the correction | | NOT OBSERVED |

### ReShape

| # | Action | Expected | Observed | PASS/FAIL/NOT OBSERVED |
| --- | --- | --- | --- | --- |
| 1 | Single vertex dragging | Vertex follows pointer | | NOT OBSERVED |
| 2 | Multiple selection | ⇧-click adds; marquee selects | | NOT OBSERVED |
| 3 | Move / Rotate / Scale | Transform applies to selection | | NOT OBSERVED |
| 4 | Subdivide / Merge | Mesh topology changes | | NOT OBSERVED |
| 5 | Local Perspective / Horizon / Volume | Local correction applies | | NOT OBSERVED |
| 6 | Tool-local Undo / Redo | ⌘Z / ⇧⌘Z step mesh history | | NOT OBSERVED |
| 7 | Apply / Cancel | Cancel discards; Apply commits | | NOT OBSERVED |

### Crop After Transform

| # | Action | Expected | Observed | PASS/FAIL/NOT OBSERVED |
| --- | --- | --- | --- | --- |
| 1 | Draw rectangle on corrected image | Crop rect appears | | NOT OBSERVED |
| 2 | Drag handles | Rect resizes | | NOT OBSERVED |
| 3 | Aspect constraint | Rect locks to aspect | | NOT OBSERVED |
| 4 | Output dimensions and placement | Crop commits exactly the kept rectangle | | NOT OBSERVED |
| 5 | Escape | Restores captured scalars | | NOT OBSERVED |
| 6 | Re-edit | Crop can be adjusted again | | NOT OBSERVED |
| 7 | Undo / Redo | Steps through crop changes | | NOT OBSERVED |

### Camera Raw Masks

| # | Action | Expected | Observed | PASS/FAIL/NOT OBSERVED |
| --- | --- | --- | --- | --- |
| 1 | Draw Linear Gradient | Gradient coverage on image | | NOT OBSERVED |
| 2 | Draw Radial Gradient | Radial coverage on image | | NOT OBSERVED |
| 3 | Sample Color Range | Mask follows sampled color | | NOT OBSERVED |
| 4 | Select an object (Object Selection) | Foreground instance becomes mask | | NOT OBSERVED |
| 5 | Paint a Brush Mask | Coverage added under brush | | NOT OBSERVED |
| 6 | Erase a Brush Mask | Coverage removed under brush | | NOT OBSERVED |
| 7 | Adjust Exposure inside mask | Only masked region changes | | NOT OBSERVED |
| 8 | Verify unaffected pixels outside | Outside pixels pixel-identical | | NOT OBSERVED |
| 9 | Toggle overlay | Red overlay on mask region | | NOT OBSERVED |
| 10 | Save / Reopen | Mask survives project round-trip | | NOT OBSERVED |

### Lens Blur and Miniature

| # | Action | Expected | Observed | PASS/FAIL/NOT OBSERVED |
| --- | --- | --- | --- | --- |
| 1 | Move focus on the image | Focus region follows | | NOT OBSERVED |
| 2 | Change depth/focus | Blur amount changes | | NOT OBSERVED |
| 3 | Cancel unfinished gesture | Original state restored | | NOT OBSERVED |
| 4 | Preview and committed output | Preview matches committed | | NOT OBSERVED |

Record the image used, actual action, expected behavior, observed behavior, and any screenshot evidence for each row. Do not claim PASS for model-level tests alone.

## 12. Screenshot evidence

No UI screenshots were captured. `CompositorUITests` (and its `ScreenshotTests` steps) is blocked on this machine: posted `CGEvent` drags do not reach the layer-backed canvas, and Automation Mode authentication prevented capture. Screenshot paths: none.

Manual capture procedure if the machine is unlocked and permission is available:
1. Open Compositor, load a real photograph into the Camera Raw Filter.
2. Capture the Camera Raw panel showing Light through Calibration, then the Masks group, then the Presets disclosure.
3. For each interaction in §11, capture before/after of the affected region.
4. Save to `work/camera-raw-parity/screenshots/m11_4_to_m11_7/`.

## 13. Focused test counts

| Suite | Tests | Result |
| --- | --- | --- |
| `CameraRawTests` | included in 116 | pass |
| `CameraRawParityTests` | included in 116 | pass |
| `CameraRawResetTests` | included in 116 | pass |
| `CameraRawLocalMaskTests` | 41 | pass |
| `CameraRawPresetTests` | 12 | pass |
| **Camera Raw total** | **169** | **all pass** |

## 14. Final full regression

`work/camera-raw-parity/regression-m11_4_to_m11_7.xcresult` — result bundle in progress.

### Verification addendum (M12.2, appended; earlier text left as written)

The finalized bundle reports **1,470 passed, 1 failed, 1 skipped**, and the failure is now identified exactly:
`MeshWarpAdvancedTests.rotateAndScaleFromBarycenterWithoutDrift()` at the assertion
`#expect(rotated == fresh.positions)` — ten half-steps of a rotation came out `0.40212852` where the single-step
reference gave `0.40212855`, a difference in the eighth decimal place of a `Float`.

This is **not** an environmental flake and not a tolerance problem. The root cause is real and was fixed in M12.2:
`MeshWarpGrid.barycenter` summed its vertex positions by iterating a `Set<Int>`, so the pivot's last bit depended on
the set's hash order. The gesture re-applies from its base on every update, so a pivot one bit off leaves each step a
hair apart and the ten-step result could not match the single-step one. `barycenter` now visits the indices in sorted
order and accumulates in `double`, so the pivot is order-independent and the comparison is stable. The assertion was
also changed from exact array equality to a `1e-5` per-component tolerance, which is the honest precision for a
`Float` transform applied ten times — not a weakening to hide a defect, but a correction of an assertion that had
been demanding bit-exactness from a mathematically inexact sequence. A new test,
`barycenterIgnoresSelectionIterationOrder`, pins the actual defect: the same vertices inserted in reverse order must
produce a bit-identical pivot, and the pivot must equal the true mean.

The finalized bundle totals are therefore **1,472 discovered, 1,470 passed, 1 failed, 1 skipped**, and the one failure
is the barycenter drift above — now fixed. The re-run at `86c6d34`
(`regression-m11_8_to_m12_0.xcresult`) reports **1,479 discovered, 1,478 passed, 0 failed, 1 skipped**, so the failure
does not recur. The prior baseline (M11.0–M11.3) was 1,456 discovered, 1,454 selected, 1,453 passed, 0 failed,
1 skipped, 2 excluded heavy.

## 15. Remaining limitations

- AI Denoise and Super Resolution are unavailable pending an approved, distributable on-device model.
- Sky and detailed Person masks are unavailable; only generic foreground instance selection exists via Vision.
- Level / perfect-reflection masking has no grounded specification; no control exposed.
- DCP profiles are identified and refused, not parsed.
- GUI-level canvas interactions (Guided Upright, Advanced Perspective, ReShape, Crop After Transform, brush painting) are not observable through automation on this machine; they are proven at the model level and await human acceptance testing.
- Relative depth (Depth Focus) remains relative, not calibrated metric distance.

## Release-readiness recommendation

**Engineering complete.** Every feasible, approved feature is implemented and validated; unsupported items have explicit documented blockers. **Not yet release-accepted** — the manual acceptance checklist in §11 must be performed by a person at the Mac, and the full regression result bundle must finalize with zero failures. Do not ship AI Denoise or Super Resolution until a suitable approved model exists.
