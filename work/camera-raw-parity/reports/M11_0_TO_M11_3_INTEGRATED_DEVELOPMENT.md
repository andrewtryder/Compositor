# M11.0 – M11.3 — Integrated photographic development

Four milestones, one engineering batch, one regression:

| Milestone | Subject | Commit |
| --- | --- | --- |
| M11.0 | Depth-Aware Lens Blur (Optics › Lens Blur › Depth Focus) | `d84a51a` |
| M11.1 | Photographic color profiles and sensor-aware white balance | `47a5735` |
| M11.2 | Advanced detail enhancement (Raw Details, sensor-stage chroma reduction) | `fc2f039` |
| M11.3 | Camera Raw local masks and adjustments | `ee70735` |

Branch `integration/compositor-camera-raw`, draft PR #18. No control was removed, renamed,
repositioned or disabled. The Camera Raw section order — Light, Color, Color Grading, Effects,
Curve, Color Mixer, Detail, Optics, Geometry, Calibration — is unchanged and guarded by
`CameraRawGroup.panelOrder`.

## 1. Final feature matrix

### M11.0 — Depth Focus

| Item | Status |
| --- | --- |
| Focus source picker (Focus Region / Depth Focus) | **Implemented and verified** |
| Focal Depth, Depth Range | **Implemented and verified** |
| Blur Amount, Aperture, Falloff, Highlights (shared) | **Implemented and verified** |
| Show Depth (depth-map visualization, preview only) | **Implemented and verified** |
| Set Focus (depth from a clicked point) | **Implemented and verified** |
| Depth model status (unavailable / loading / failed / ready) | **Implemented and verified** |
| Prepare Depth Model is an explicit button | **Implemented and verified** — opening Lens Blur never downloads |
| Focus Region unchanged | **Verified byte-identical** at default |

### M11.1 — Profiles and white balance

| Item | Status |
| --- | --- |
| As Shot (the camera's own reading, named in K) | **Implemented and verified** on a real CR2 |
| Auto (solved through the decoder's sensor model) | **Implemented and verified** — cast 0.9646 → 0.9223 |
| Custom Kelvin and Tint, absolute, re-developing the sensor | **Implemented and verified** |
| Camera Default profile (the decoder's own render) | **Implemented and verified** — delta 0.0 |
| Linear profile (the same decode without its tone curve) | **Implemented and verified** — 100% of pixels moved |
| ICC profile supplied by the person, with strength | **Implemented and verified** — Display P3 moved 97% |
| DCP | **Researched, refused honestly** — identified, not approximated |
| Camera Raw Filter Temperature / Tint stay relative | **Preserved** — labelled as relative, not relabelled as Kelvin |

### M11.2 — Detail enhancement

| Enhancement | Status | Why |
| --- | --- | --- |
| Raw Details | **IMPLEMENTED AND VERIFIED** | Drives `CIRAWFilter.detailAmount` / `sharpnessAmount` / `contrastAmount` / `moireReductionAmount`, on the sensor data before it becomes pixels. Detail energy 10.32 → 16.41 across 89% of pixels on a real CR2; at matched energy an unsharp mask halos 3788 pixels against Raw Details' 1112, so it is not sharpening renamed. |
| Sensor-stage chroma noise reduction | **IMPLEMENTED AND VERIFIED** | `colorNoiseReductionAmount` runs on the mosaic data, a different operation from Detail's rendered-picture Color slider. Chroma energy halved, 31.70 → 16.98 at 100%. |
| AI Denoise | **RESEARCHED, BLOCKED** | There is no Apple denoise model or API in the SDK, and `MetalNonlocalMeans` is a classical non-local-means filter, not a learned one. No control is shipped. |
| Super Resolution | **RESEARCHED, BLOCKED** | `CIRAWFilter.scaleFactor` is documented `0...1` and a requested 2× clamps to 1, measured here. Lanczos enlargement of a rendered layer would be enlargement, not Super Resolution, and is not labelled as such. No control is shipped. |
| Raw Details offsets are relative, not absolute | **Implemented and verified** | The EOS 5DS R's decode arrives with sharpness 0.7205 applied; a slider meaning "zero sharpness" at its middle would take the camera's rendering away. The baseline is captured from a freshly built filter and travels with the project. |
| Enabling Raw Details with every offset at zero | **Verified byte-identical** to As Shot | |

### M11.3 — Local masks

| Item | Status |
| --- | --- |
| Selection → mask | **Implemented and verified** |
| Object Selection (Vision foreground instance) → mask | **Implemented and verified** |
| Color Range → mask, with eyedropper and Fuzziness | **Implemented and verified** |
| Layer Mask → mask | **Implemented and verified** |
| Linear gradient mask, draggable on the canvas | **Implemented and verified** |
| Radial gradient mask, draggable on the canvas | **Implemented and verified** |
| Exposure, Contrast, Highlights, Shadows, Whites, Blacks | **Implemented and verified** |
| Temperature, Tint (relative, as the pixels are already developed) | **Implemented and verified** |
| Vibrance, Saturation, Texture, Clarity, Dehaze | **Implemented and verified** |
| Add / select / rename / delete / enable / invert / feather / show overlay | **Implemented and verified** |
| Correct mapping through lens distortion, de-squeeze, geometry and Crop After Transform | **Implemented and verified** — a 4° rotation carries the mask, 98.26% of its work still inside the middle half |
| Neutral mask is pixel-identical | **Verified** |
| Global grade not applied twice | **Verified** |
| Persistence in `CameraRawSettingsPersistentState` and the `.cameraRawFull` correction node | **Implemented and verified** — reopened project develops byte-identically |
| Brush-painted mask | **Not offered.** A Brush kind would need its own canvas paint mode; the five capture paths and two gradients already cover every mask source the milestone requires. No control is shown for it. |
| Adobe-style People / Sky segmentation | **Not claimed.** Object Selection is Vision's foreground instance, labelled as such. |

## 2. Engines that already existed

Nothing below was built for these milestones; each was reached through a new control or a new
routing into the same code.

| Engine | Used by |
| --- | --- |
| `DepthModel` (Core ML relative-depth estimator, already used by Volumetric Light) | M11.0 |
| `CameraRawLensBlur`, `CameraRawMiniature.blurMask`, `MetalBokeh`, `BokehShape` | M11.0 |
| `CIRAWFilter` (sensor decode, neutral temperature/tint, detail and noise controls) | M11.0–M11.2 |
| `RawSourceAsset`, `RawImporter`, `RawDevelopmentRenderer` — retained RAW bytes and re-development | M11.1, M11.2 |
| `CameraRawTables`, `CameraRawShadows`, `adjust_camera_raw_effects`, `adjust_camera_raw_detail` | M11.3 |
| `DocumentSelection`, `Selection`, `BrushRaster`, `ObjectSelection`, `color_range_mask`, `LayerMask` | M11.3 |
| `LayerCorrectionStack`, `LayerCorrectionRenderer` with the `.cameraRawFull` node | M11.3 |
| `CameraRawGeometryBackend`, `CameraRawPerspectiveTools`, `CameraRawHorizon`, `CameraRawGeometryCrop`, `CameraRawSettings.applyLensDistort` | M11.3 (mask warping) |
| `PixelAdjust`, `ImageAdjustmentPixels`, `DeepLayer` precision handling | all four |

## 3. New code

| File | What it is |
| --- | --- |
| `Compositor/Document/RawColorProfile.swift` | The photographic profile model: Camera Default, Linear, ICC; DCP refused. Applies once to developed pixels. |
| `Compositor/Document/RawWhiteBalance.swift` | As Shot / Auto / Custom on the decoder's own absolute coordinates, with the gray-world cast solver. |
| `Compositor/Document/CameraRawLocalMask.swift` | `CameraRawLocalMaskKind`, `CameraRawLocalMaskRaster`, `CameraRawLocalAdjustments`, `CameraRawLocalMask`, `CameraRawLocalMaskRenderer`, `WarpedCoverageCache`. |
| `Compositor/Document/CameraRawLocalMaskEditing.swift` | The `EditorSession` mask API: add from selection / layer mask / object / color / gradient, edit, delete, canvas drags. |
| `Compositor/UI/CameraRawMasksControls.swift` | The mask list, coverage controls and local adjustment sliders, below the ten sections. |
| `RawDetailSettings` additions in `RawSourceAsset.swift` | The decoder baseline and the four relative offsets. |

## 4. Processing and model architecture

### Where each stage sits in the pipeline

```
RAW decode (CIRAWFilter)
  └─ M11.1 white balance  (absolute Kelvin/tint, sensor data)
  └─ M11.1 profile        (Camera Default / Linear / ICC, once)
  └─ M11.2 Raw Details    (sensor data, before it becomes pixels)
  └─ M11.2 chroma reduction (mosaic data)
        ↓  developed pixels
Lensfun (optional) → lens distortion → de-squeeze → Volume → Perspective → Horizon
  → framing → Crop After Transform → Miniature → Lens Blur  ← M11.0 Depth Focus blends
                                                              on the pre-warp frame
  → global Camera Raw grade (tables, shadows, effects, detail, optics)
  → M11.3 local masks, one after another, each over the last
```

Depth Focus blends on the captured frame *before* geometry, so de-squeeze, perspective and crop
carry the discs along with the picture; Focus Region keeps its long-standing place *after* the
warp, so its result is exactly what it was before M11.0.

Local masks read the corrected frame — after de-squeeze, geometry, crop, Miniature, Lens Blur and
the global grade — so a region lands on the pixels it was drawn over and the global grade is never
applied twice. Captured coverage is run through the same spatial stages the picture was, and cached
per mask and per stage set, so moving an Exposure slider re-walks no warp.

### Model sizes and downloads

| Model | Size | Acquisition |
| --- | --- | --- |
| Depth model (`DepthModel`) | about 3 MB | Already existed. `prepare()` may download it, but only from the explicit **Prepare Depth Model** button; opening Lens Blur never fetches anything. |
| No new model ships with M11.0–M11.3 | — | No AI Denoise or Super Resolution model, because no suitable licensed Apple-native one exists. |

### Precision

Camera Raw and all local masks run on 8-bit premultiplied RGBA through `PixelAdjust`, exactly as
every existing Camera Raw stage does; a 16-bit or HDR layer is handled by the existing
`DeepLayer` path that guards the filter, not by a second pipeline. The ICC profile is applied at
16 bits when the develop itself was deep. No stage silently drops 16-bit precision.

## 5. Exact controls added

Every control below is reachable, and nothing unimplemented is shown.

### M11.0 — Optics › Lens Blur

Focus picker (`lensBlurFocusModePicker`); with Depth Focus selected, Focal Depth, Depth Range,
Falloff, Highlights, **Set Focus** (`lensBlurSetDepthFocus`), **Show Depth**
(`lensBlurShowDepth`), the relative-depth note, model status, and **Prepare Depth Model**
(`lensBlurPrepareDepthModel`). Focus Region keeps Focus Range, Falloff, Highlights and **Move
Focus**.

### M11.1 / M11.2 — RAW development editor

White Balance picker with As Shot (named in K) / Auto / Custom, Temperature and Tint sliders;
Profile picker with Camera Default / Linear / ICC, **Choose ICC…**, the profile's name and color
space, and its strength. Raw Details toggle with Detail, Sharpness, Contrast and Moire offsets, the
camera's own baseline printed beside them, and the one-line explanation that the amounts are
relative to the camera's decode.

### M11.3 — Camera Raw panel, below Calibration

A **Masks** group: **Add Mask** menu (From Selection, From Layer Mask, Linear Gradient, Radial
Gradient, Object Selection…, Color Range…), the mask list with an enable dot, name, kind and a
context menu (Rename…, Enable/Disable, Invert, Delete), then for the selected mask: **Show
Overlay**, **Invert**, Delete, **Feather**, **Draw Gradient** (gradients), the eyedropper and
**Fuzziness** (Color Range), and the thirteen local adjustment sliders with **Reset**.

## 6. Focused test results per phase

| Phase | Suites | Result |
| --- | --- | --- |
| M11.0 | `CameraRawDepthBlurTests` (23), plus Lens Blur, Camera Raw and persistence | pass |
| M11.1 | `RawColorProfileTests` (16), `RawColorProfileRawEvidenceTests` (5), plus RAW development and Camera Raw | 139 tests, pass |
| M11.2 | `CameraRawAdvancedDetailTests`, `CameraRawAdvancedDetailEvidenceTests`, plus the M11.1 and Camera Raw suites | 155 tests, pass |
| M11.3 | `CameraRawLocalMaskTests` (35), `CameraRawLocalMaskEvidenceTests` (5), plus Camera Raw, persistence, correction-stack, Depth Blur, Miniature and Geometry Guide suites | 107 tests in the affected suites, pass |

### M11.3 evidence, measured on `sigma-40art-sample.CR2`

A soft ellipse over the middle of a 900 × 900 native-resolution window:

| Measurement | Result |
| --- | --- |
| Frame moved by the mask | 32.17%, mean delta 9.49 |
| Corners outside the ellipse | byte-identical |
| Center luma | 151.23 → 193.65 |
| Coverage at Exposure 0.4 vs 1.2 | identical — the region does not move with the amount |
| Correction stack, `.cameraRawFull` node | 32.28% moved, mask still editable in the node |
| 4° rotation | 32.39% moved, 98.26% of it inside the middle half |
| Save and reopen | byte-identical, stored mask 900 × 900, 12 KB |

## 7. Full regression

`scripts/regression.sh`, checked-in `CompositorRegression` plan, heavy tests left in
`CompositorHeavy`. Finalized `.xcresult`:
`work/camera-raw-parity/regression-m11_0_to_m11_3.xcresult`.

| Measure | Count |
| --- | --- |
| Discovered | 1456 |
| Selected by the plan | 1454 |
| Excluded by `CompositorRegression.xctestplan` | 2 |
| **Passed** | **1453** |
| **Failed** | **0** |
| **Skipped** | **1** |
| Expected failures | 0 |
| Result | **Passed** |

The two exclusions are the designated heavy tests, which stay runnable through `CompositorHeavy`:
`MeshWarpPerformanceTests/warmMediansHeavyAt6000x4000()` and
`RawDevelopmentIntegrationTests/realRawFixtureEndToEnd()`.

The one skip is `RawDevelopmentIntegrationTests/realRawFixtureSmokePreview()`, which is gated on
the `COMPOSITOR_RAW_FIXTURE_PATH` environment variable: with no fixture path set its Enable trait
skips it rather than reporting a pass that would hide the decoder never having been exercised. It
is not a disabled or weakened assertion. The M11.0–M11.3 RAW evidence suites find their own
fixture through `GeometryValidationFixtures` and did run — their measurements are in §6.

Section-order guards, read from the same run:

```
✔ Test cameraRawSectionOrderIsUnchanged() passed
✔ Test localMasksAreNotATopLevelCameraRawSection() passed
```

No failure occurred, so nothing was isolated or rerun; the single run above is the final
verification, per the accelerated strategy.

### 7.1 What the run covers

| Area | Confirmation |
| --- | --- |
| Camera Raw section order | `CameraRawGroup.panelOrder` unchanged, and Masks is not an eleventh section |
| RAW redevelopment | `RawDevelopment*`, `RawColorProfile*`, `RawWhiteBalance` suites all passed |
| Lensfun | `CameraRawLensfun*`, `CameraRawLensProfile*` passed; the provider is still optional and off by default |
| Geometry and ReShape | all geometry, perspective, horizon, miniature, de-squeeze and Mesh Warp suites passed, including the Mesh Warp Metal/CPU benchmarks |
| Project persistence and correction stacks | `NonDestructiveCameraRawTests`, `LayerCorrection*`, `CameraRawPersistence` and the project-format suites passed |
| Image quality on existing fixtures | every pre-existing Camera Raw, levels, curve and photographic fixture assertion still passes |

### 7.2 M11.3 canvas interactions

The gradient drag, the Color Range eyedropper and the armed Object Selection click are exercised
through `EditorSession`'s own API by `CameraRawLocalMaskTests` — the same entry points
`EditorCanvas` calls — so their logic is covered by the run above. The pointer gestures themselves
were not observed in a running app (see §11).

## 8. Photographic comparisons

The real-photograph evidence lives in the test suites rather than in hand-captured plates, so every
number above can be reproduced by running the suite:

| Suite | Fixture | What it measures |
| --- | --- | --- |
| `CameraRawDepthBlurTests` | synthetic depth | band selection, falloff, geometry order, alpha, bit-exactness |
| `RawColorProfileRawEvidenceTests` | `sigma-40art-sample.CR2` | As Shot delta 0.0, Auto cast, Linear and Display P3 movement |
| `CameraRawAdvancedDetailEvidenceTests` | `sigma-40art-sample.CR2` | detail energy, halo counts against an unsharp mask, chroma energy |
| `CameraRawLocalMaskEvidenceTests` | `sigma-40art-sample.CR2` | region movement, byte-identical outside, stack round-trip, rotation, reopen |

## 9. UI screenshots

The consolidated batch directory is `work/camera-raw-parity/screenshots/m11_0-to-m11_3/`, with a
subfolder per feature. Compositor's Camera Raw panel and RAW development editor are their own
docked dialogs, so a panel capture is taken from that dialog as an element rather than as a
whole-screen grab.

**Not captured.** `CompositorUITests` is blocked on this machine by Automation Mode authentication,
and the screen captures come back blank — the same blocker recorded for M10.4, M10.5, M10.7, M10.8
and M10.9. No programmatically rendered UI has been presented as a real screenshot in its place. The
accessibility identifiers every capture needs are in place (`lensBlurFocusModePicker`,
`lensBlurShowDepth`, `lensBlurPrepareDepthModel`; the mask controls' labels), so the screenshot
suite can be run once the automation permission is granted.

## 10. Unsupported cases, refused honestly

| Case | Behaviour |
| --- | --- |
| Depth Focus with no depth model | The picture keeps its own pixels; the panel says the model is not installed and needs an explicit download. No radial blur is presented as depth-aware. |
| Depth Focus labelled as physical distance | Never. Controls say "relative: 0 is farthest and 100 nearest, not a measured distance". |
| DCP profile | Identified and refused with a sentence explaining why; not approximated. |
| AI Denoise | No control. No Apple model exists; `MetalNonlocalMeans` is not relabelled. |
| Super Resolution | No control. `scaleFactor` clamps to 1, so no develop is larger than native. |
| Camera Raw Temperature / Tint as Kelvin | Not relabelled. They stay relative and say so; absolute Kelvin lives in RAW re-development. |
| A mask kind with nothing to capture from | Refuses with a sentence rather than making a mask that covers everything. |
| An entirely black mask | Not blended at all — there is nothing to blend. |

## 11. Manual acceptance gates — unchanged

These remain **NOT OBSERVED**, exactly as before this batch, and no attempt was made to claim
otherwise:

- Guided Upright canvas drawing — NOT OBSERVED.
- Advanced Perspective canvas drawing — NOT OBSERVED.
- ReShape canvas gestures — NOT OBSERVED.
- Crop After Transform canvas drawing — NOT OBSERVED.

The new M11.3 canvas interactions (gradient drags, the Color Range eyedropper, the armed Object
Collection click) are covered by unit tests that drive the `EditorSession` API directly — the same
layer the canvas calls — but the pointer gestures themselves were not observed in a running app for
the same automation reason. They are **NOT OBSERVED** as gestures.

## 12. Remaining feature gaps

| Gap | Reason | Where it would go |
| --- | --- | --- |
| Brush-painted local mask | Needs a paint mode of its own on the canvas | Masks group |
| Adobe-style People / Sky segmentation | Vision's foreground instance is not a subject classifier | Masks group |
| AI Denoise | No Apple-native model or API; no licensed model was approved | RAW development / Detail |
| Super Resolution | `CIRAWFilter.scaleFactor` cannot exceed 1 | RAW development |
| Camera Raw Level (perfect-reflection) masks | Not requested for this batch | Masks group |
| Depth Focus as calibrated meters | The depth estimate is relative | Lens Blur |
| DCP profile support | Proprietary parser and profile data | RAW development |
| Photoshop Presets panel | Out of scope: new top-level UI | — |
