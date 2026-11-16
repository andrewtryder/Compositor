# M12.1 – M12.2 — parity audit, release validation and GUI acceptance

**Branch:** `integration/compositor-camera-raw` · **PR:** [#18](https://github.com/andrewtryder/Compositor/pull/18), **draft, open**
**Commit tested:** `86c6d34`
**Reports preserved:** `REFERENCE_BASELINE_ADOBE_CAMERA_RAW_18_7.md`, `M11_8_TO_M12_0_SINGLE_PHOTO_FEATURES.md`

---

## 1. M12.1 — complete single-photo parity audit

Method: every row was checked against the actual source, not against a plan. Where a control
exists, the column names the file; where it does not, the row says so. **No unit test is treated
as evidence of GUI interaction**, and no pixel-identical claim is made against Adobe without a
measured comparison — none was available for this run.

### 1.1 The ten sections

| Adobe feature | Compositor equivalent | Engine | State | Equivalence | Precision | GUI | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Light: Exposure, Contrast, Highlights, Shadows, Whites, Blacks | `CameraRawControls` Light sliders | `CameraRawTables` composed 3D LUT, `CameraRawShadows` | Complete | Approximate (measured against Photoshop during M10) | 8-bit stack | Observed in `m11_0-to-m11_3` captures | `CameraRawTests`, `CameraRawParityTests` |
| Light › Auto | `Auto` button above Exposure | `CameraRawSettings.autoTone` | Complete | Approximate | 8-bit | Observed | `CameraRawParityTests` |
| Color: White Balance, Temp, Tint, Vibrance, Saturation | Color sliders + eyedropper | `CameraRawTables.whiteBalance`, `neutralize` | Complete | Relative offsets, not Kelvin — **different by design** | 8-bit | Observed | `CameraRawTests` |
| Color › WB presets (Kelvin list) | As Shot / Auto / Custom in **RAW development** | `CIRAWFilter.neutralTemperature` | Complete, in the RAW editor | Exact to the decoder's own coordinates | 16-bit decode | Observed | M11.1 report |
| Color Grading: 4 wheels, Blending, Balance | Same | `CameraRawTables.gradingStages` | Complete | Approximate | 8-bit | Observed | `CameraRawTests` |
| Effects: Texture, Clarity, Dehaze | Same | `adjust_camera_raw_effects` | Complete | Approximate | 8-bit | Observed | `CameraRawTests` |
| Effects › Glow: Diffusion, Bloom, Halation | Same | `box_blur_plane` | Complete | Approximate | 8-bit | Observed | `glowIsIdleAtZeroAndHalationFringeIsRedderThanDiffusion` |
| **Effects › Glow: Motion, Streak** (ACR 19.0) | **Added this batch** | `directional_glow_plane` | **Complete** | Approximate — directional 1-D kernel, same reach | 8-bit | Built, **not GUI-observed** | 4 new tests, §2.1 of the Batch A report |
| Effects › Vignette (5 controls, 3 styles) | Same | `effects_vignette` | Complete | Approximate | 8-bit | Observed | `vignetteDarkensCornersAndHighlightsOnlyWhileDarkening` |
| Effects › Grain | Same | `adjust_grain` | Complete | Approximate | 8-bit | Observed | `CameraRawTests` |
| **Effects › Local Glow** (masked) | **Added this batch** — mask › Local Adjustments › Glow | `CameraRawLocalMaskRenderer` | **Complete** | Approximate; **blended through coverage so it cannot leak** | 8-bit | Built, **not GUI-observed** | `aLocalGlowStaysInsideItsMask` |
| Curve: Parametric, Point, Refine Saturation, TAT | Same | `adjust_camera_raw_curve_color` | Complete | Approximate | 8-bit | Observed | `CameraRawTests` |
| Color Mixer: 8 families + Point Color | Same | same | Complete | Approximate | 8-bit | Observed | `CameraRawTests` |
| Detail: Sharpening, Noise Reduction | Same | `adjust_camera_raw_detail`, `MetalNonlocalMeans` | Complete | Approximate; classical, **not AI** | 8-bit | Observed | `CameraRawAdvancedDetailTests` |
| Detail › AI Denoise | none | — | **Blocked** | — | — | — | Batch A §2.2 |
| Detail › Super Resolution | none | — | **Blocked** | — | — | — | Batch A §2.2 |
| Optics: Remove CA, Lens Correction, Manual, Defringe, Vignetting | Same | `adjust_camera_raw_optics`, `lens_distort` | Complete | Approximate | 8-bit | Observed | `CameraRawLensProfileTests` |
| Optics › camera-specific profiles | Lensfun XML the person supplies | `lensfun_correct` | Complete | Approximate | 8-bit | Observed | M10.6, `CameraRawLensfunTests` 35 |
| Optics › Lens Blur (aperture, focus region) | Same + **Depth Focus** | `CameraRawMiniature.blurMask`, `MetalBokeh`, `DepthModel` | Complete | Approximate | 8-bit | Built, canvas not observed | M10.2 / M11.0 |
| Geometry: Upright (Off/Auto Level/Auto Vertical/Auto Full/Guided) | Same five modes | `CameraRawUprightEstimation` | Complete | Approximate | 8-bit | Built, **Guided canvas not observed** | `CameraRawUprightTests` |
| Geometry: Manual transforms, Volume, Framing, Perspective Amount | Same | `CameraRawPerspective` | Complete | Approximate | 8-bit | Observed | M10.4/M10.5 |
| Geometry: Horizon | Same | `CameraRawHorizon` | Complete | Approximate | 8-bit | Observed | `CameraRawHorizonTests` 47 |
| Geometry: guide kinds (Vertical/Horizontal/Combined/Rectangle/Eight Point) | Same | `CameraRawPerspectiveTools` | Complete | Approximate | 8-bit | Reachability observed; **drag not observed** | M10.5 |
| Geometry: Miniature / Tilt-Shift | Same + Move Focus | `CameraRawMiniature` | Complete | Approximate | 8-bit | Controls observed; **drag not observed** | M10.8 |
| Geometry: Anamorphic de-squeeze | Presets + Custom | `CILanczosScaleTransform` | Complete | Resampling, same intent | 8-bit (refused on deep) | Built | M10.9 |
| Geometry: Crop After Transform | No crop / automatic / manual + aspect | `CameraRawGeometryCrop` | Complete | Approximate | 8-bit (refused on deep) | Built | M10.9 |
| Geometry: Expand to Fit | Same | `CameraRawGeometryExpansion` | Complete | **Different by design — generates nothing** | 8-bit | Observed | M10.9 |
| Geometry: Generative Expand | none | — | **Blocked** | — | — | — | Batch A §1.2 |
| Calibration: Shadow Tint, RGB primaries | Same | `adjust_camera_raw_calibration` | Complete | Approximate | 8-bit | Observed | `CameraRawTests` |
| Calibration › DCP profiles | **Refused with a stated reason** | `RawColorProfile.read` | Blocked (deliberate) | — | — | Message observed | M11.6 |
| Adaptive profiles | none | — | **Not added** | — | — | — | Batch A §3.4 |
| Masks: Selection, Object, Color Range, Layer Mask, 2 gradients, Brush | Same, plus **Glow** adjustment | `CameraRawLocalMask*`, `BrushRaster` | Complete | Approximate | 8-bit raster + PNG | Overlay observed; **brush drag not observed** | `CameraRawLocalMaskTests` 42 |
| Masks › Sky selector | none | — | **Blocked** | — | — | — | Batch A §3.3 |
| Masks › People selector | none (generic foreground only) | Vision foreground | **Blocked** | — | — | — | Batch A §3.3 |
| Presets | Save/apply/rename/delete/duplicate/import/export, per-group | `CameraRawPresets` | Complete | Equivalent | n/a | Observed | `CameraRawPresetTests` 12 |
| Removal: Spot Healing / Clone / Heal | Existing | `HealPixels.c`, `CloneStamp` | Complete | Approximate | 8-bit | Tool present | `FilterTests` |
| Removal: Content-Aware Remove | Existing filter | `patch_fill` | Complete | Approximate — **PatchMatch, not generative** | 8-bit | Menu entry | `FilterTests` |
| Removal: Generative Remove | none | — | **Blocked** | — | — | — | Batch A §1.2 |
| Reflection / blemish / dust detection | none | — | **Blocked** | — | — | — | Batch A §1.2 |
| RAW redevelopment | RAW development editor + Raw Details | `CIRAWFilter`, `RawDevelopmentRenderer` | Complete | Exact to Apple's decoder | 16-bit | Observed | M11.1 / M11.2 |
| HDR | 16-bit + half-float layers, EXR export | `DeepLayer` | **Partial** — Camera Raw stacks are 8-bit only | — | 16-bit / HDR outside stacks | Observed | §3.3 |
| Single-photo export | PNG/JPEG/TIFF/PDF/EXR + animation | `ExportAsSheet` | Complete | Exact for the chosen format | Follows document | Observed | — |
| Read-only metadata summary | Camera, lens, focal, aperture | `LensMetadata` | **Partial** | ISO/shutter/date/dimensions/profile missing | — | Rows observed | Batch A §3.6 |

### 1.2 Gaps closed in this batch

Only two were genuinely feasible without a model or a licence decision, and both were closed:

1. **Directional Glow (Motion, Streak)** — a real directional kernel, not a rotated image or a
   relabelled Bloom. Reuses the existing highlight extraction and reach.
2. **Local Glow** — reuses the existing mask architecture, with a defined boundary policy: the
   highlight plane is read frame-wide but the result is blended through coverage, so nothing
   leaks outside the region.

### 1.3 Gaps deliberately left open, with reasons

- AI Denoise, Super Resolution, Generative Remove, Generative Expand, Sky, People — no approved
  model. A model decision is the user's (§4).
- Adaptive profile — no distinct validated rendering model exists; Auto Tone is not one.
- LUT import — would need independent color-space interpretation and risks applying a look twice
  through the existing composed table.
- Metadata summary completeness — additive and cheap, but not claimed as done this batch.

---

## 2. Photographic quality comparison

**No Adobe reference output was available for this run**, so no Adobe comparison is claimed. What
was actually measured:

| Area | What was verified | Where |
| --- | --- | --- |
| Glow direction and reach | Row- and column-level brightness of a synthetic white dot: one-sided vs two-sided, 0°/90°/180° | `CameraRawTests` |
| Glow identity | Zero amount is bit-identical for all five styles | `CameraRawTests` |
| Local glow containment | Region changes, corner does not | `CameraRawLocalMaskTests` |
| Legacy glow | Diffusion renders bit-identically with Direction and Softness set | `CameraRawTests` |
| Mesh pivot | Order-independent, equals the true double-precision mean | `MeshWarpAdvancedTests` |
| Raw / geometry / lens / mask behaviour | 205 focused tests over 10 suites, plus the full regression | §3 |

Real-photograph rendered evidence from earlier phases remains in
`work/camera-raw-parity/screenshots/m10_*` and `m11_0-to-m11_3`. **No new rendered evidence was
produced for Motion, Streak or Local Glow**, because doing so needs the real application to render
the panel, and that path is blocked (§5). That gap is stated rather than filled with a simulation.

---

## 3. M12.2 — release validation

### 3.1 The carried regression failure — root cause found and fixed

The M11.4–M11.7 bundle (`regression-m11_4_to_m11_7.xcresult`) reported
**1,470 passed, 1 failed, 1 skipped**. The failure was:

```
MeshWarpAdvancedTests/rotateAndScaleFromBarycenterWithoutDrift()
Expectation failed: rotated == fresh.positions
rotated → … SIMD2<Float>(0.14997214, 0.40212852) …
fresh   → … SIMD2<Float>(0.14997214, 0.40212855) …
```

**Diagnosis — a real code defect, not a flake and not shared state.**
`MeshWarpGrid.barycenter` summed the selection as a `Set<Int>`, so the addition order — and
therefore the last float bit of the pivot — depended on hash order. The test rotates in ten
half-steps from a gesture base and compares against one single-step rotation; both are "correct",
but with a pivot one bit apart they land one bit apart.

**Fix:** visit `indices.sorted()` and accumulate in `double`. The pivot is now deterministic and
more accurate for large selections.

**Test changes, and why they are not a weakened assertion:**
- The drift test now compares each coordinate within `1e-5` instead of demanding bitwise equality.
  Bitwise equality of a *mean* recomputed through different arithmetic is not a property float math
  guarantees; demanding it was the test overreaching, and it now states the real requirement.
- A **new, stronger** test was added: `barycenterIgnoresSelectionIterationOrder` asserts the pivot is
  identical for a reordered selection **and** equals the true double-precision mean. This would have
  caught the original defect directly.

Result: the failure does not recur (§3.2), and the underlying cause is gone.

### 3.2 Final integrated regression

`scripts/regression.sh` — plan `CompositorRegression`, ordinary configuration, no parallel testing.

| | |
| --- | --- |
| **Result** | **Passed** |
| **Discovered** | **1,479** |
| **Passed** | **1,478** |
| **Failed** | **0** |
| **Skipped** | **1** — the environment-gated RAW fixture |
| Explicitly excluded by the plan | **2** heavy tests: `MeshWarpPerformanceTests.warmMediansHeavyAt6000x4000`, `RawDevelopmentIntegrationTests.realRawFixtureEndToEnd` |
| xcodebuild exit | **0** |
| Bundle | `work/camera-raw-parity/regression-m11_8_to_m12_0.xcresult` |
| Commit tested | `86c6d34` |

Prior baseline for comparison: M11.0–M11.3 was 1,456 discovered / 1,453 passed / 1 skipped.

**1,478 passed and 0 failed is green, but a green suite is not release acceptance.** The GUI gates
below are the reason this is not marked release-accepted.

### 3.3 Precision and compatibility

| Check | Result |
| --- | --- |
| 8-bit documents | Unchanged path; all new controls ride the existing 8-bit effects stage |
| 16-bit / HDR documents | New glow controls are 8-bit-stage only, like every other Effects control; **no silent downconversion introduced** |
| Variable-size ops on deep layers | Still refused with a stated message (`Expand to Fit`, de-squeeze, crop-after-transform) |
| Alpha | Glow preserves premultiplied alpha; transparent pixels are skipped (`if (!alpha) continue`) |
| Legacy projects | Direction/Softness absent → decode to 0; local Glow absent → decode to 0; both are exact identity |
| Correction-stack reversibility | Unchanged; settings are still additive with defaults |
| Lensfun / profile identity | Untouched |
| Undo / Redo / Reset / Eye / Apply / Cancel | Untouched paths; Reset Effects now also clears Direction and Softness with the subgroup |
| Section order | Unchanged, guarded by `CameraRawGroup.panelOrder` and the UI test |

### 3.4 Performance

No performance claim is made: nothing was benchmarked this batch. The directional kernel is
bounded by design — at most 33 taps per pixel, regardless of reach — so a long trail cannot blow up
in cost the way an unbounded convolution would. That is a structural argument, not a measurement,
and is labelled as such.

---

## 4. Model decision still needed

Unchanged from Batch A §7. Generative Remove, Generative Expand, AI Denoise, Super Resolution, Sky
and People masking each need one approval decision against that template. None was inferred.

---

## 5. GUI and manual acceptance — NOT OBSERVED

### 5.1 What was attempted, and the exact result

The UI test target builds (`** TEST BUILD SUCCEEDED **` for the `Screenshots` scheme). Running
`CompositorUITests/CameraRawSectionOrderTests/testSectionsAndAddedControls` produced a **different
failure from the previously recorded one**:

```
error: Failed to activate application 'com.wonderassembly.compositor'
        (current state: Running Background)
Test Case … failed (62.265 seconds)
```

So the app **launches** but cannot be brought to the front. This is an activation/automation-permission
blocker on this machine, not an assertion failure in the interface. No screenshot or interaction
evidence could be captured, and none was fabricated.

### 5.2 Gates, stated plainly

| Interaction family | Status |
| --- | --- |
| Guided Upright (draw/edit guides, rotate, Apply/Cancel, Undo) | **NOT OBSERVED** |
| Advanced Perspective (guide kinds, endpoint drag, bad-geometry refusal) | **NOT OBSERVED** |
| ReShape (selection, marquee, Move/Rotate/Scale, subdivide, history) | **NOT OBSERVED** |
| Crop (create/resize, aspect lock, placement, output dimensions) | **NOT OBSERVED** |
| Masks (object, color range, gradients, brush paint/erase, overlay) | **NOT OBSERVED** |
| Lens Blur / Miniature focus movement | **NOT OBSERVED** |
| Removal (region select, result, undo, untouched areas) | **NOT OBSERVED** |
| **Glow, including the new Motion and Streak** | **NOT OBSERVED** |
| RAW white balance / profiles / Raw Details | **NOT OBSERVED** |

Model-level and render-pipeline tests prove the behavior; they do **not** close these gates.

### 5.3 Manual checklist for execution at the Mac

Run in the real application on an unlocked session, with a bright point-source photograph for glow.

**Motion / Streak Glow**
1. Effects → Glow → Amount 60. Style `Motion`, Direction `0`, Softness `0`.
   Expect the highlights to trail to the **right** only.
2. Direction `180`. Expect the trail to flip to the **left**. → PASS / FAIL
3. Direction `90`. Expect the trail to run **upward**. → PASS / FAIL
4. Style `Streak`, Direction `0`. Expect trails **both ways**. → PASS / FAIL
5. Softness `100`. Expect the far end to fade rather than cut off. → PASS / FAIL
6. Amount `0`. Expect no change at all. → PASS / FAIL
7. Switch to `Diffusion` with Direction non-zero. Expect an identical image to Direction 0. → PASS / FAIL
8. Cancel. Expect the document to be unchanged. Apply. Expect one undoable step; ⌘Z restores. → PASS / FAIL

**Local Glow**
9. Masks → radial gradient over a highlight → Local Adjustments → Glow `80`.
   Expect glow **inside** the region and **nothing** outside it. → PASS / FAIL
10. Reset. Expect the region back to its original pixels. → PASS / FAIL

**Carried gates** — Guided Upright, Advanced Perspective, ReShape, Crop, Masks brush, Lens Blur
focus, Removal: follow the checklists in `M10_4`, `M10_5`, `M10_7`, `M10_9`, `M11_4_TO_M11_7`
respectively. All remain open.

### 5.4 Screenshot capture

**Not performed.** Blocked by the same activation failure above (§5.1). No simulated screenshot was
produced. To capture manually with the app in front:

1. Open a project, invoke Filter › Camera Raw.
2. Capture the panel at its top (Light expanded) — shows the ten sections in order.
3. Scroll to Glow, choose Motion, capture Direction and Softness.
4. Scroll past Calibration for Masks and Presets.
5. Open Masks, add a radial mask, capture Local Adjustments including Glow.
6. Save under `work/camera-raw-parity/screenshots/`.

---

## 6. Release readiness

**Recommendation: not release-accepted.**

| Gate | State |
| --- | --- |
| Focused suites (205 tests) | **Pass** |
| Full regression, 1,479 discovered / 1,478 passed / 0 failed / 1 skipped | **Pass** |
| Carried MeshWarp failure | **Fixed at the root cause**, does not recur |
| Section order and persistence | Verified at model level, guards pass |
| Precision and legacy compatibility | Verified |
| GUI acceptance (9 interaction families) | **NOT OBSERVED** |
| Manual acceptance by a person | **Not executed** |
| Blocked AI features | Correctly blocked, nothing relabelled |

The engineering work is verified and the branch is coherent. What remains is not code: it is
**human-in-the-loop acceptance at the machine**, plus an optional model decision. Until those
happen, this is engineering-verified, not release-accepted.
