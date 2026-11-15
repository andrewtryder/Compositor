# Camera Raw parity — gap analysis and additive plan

Status: living document. Every milestone is additive. No existing control, section, order or
default is moved, renamed or removed.

**Reference:** Photoshop 2026 / **Adobe Camera Raw 18.7**, as supplied by the user in six screenshots.
That is the authoritative baseline — see
[`REFERENCE_BASELINE_ADOBE_CAMERA_RAW_18_7.md`](REFERENCE_BASELINE_ADOBE_CAMERA_RAW_18_7.md).
`work/geometry-validation/UI_SPEC_ADOBE_CAMERA_RAW_2016.md` describes Camera Raw 9.6 and is **archived
historical research**, not a specification; nothing in it is an implementation requirement.

## 1. What Compositor already has

| Section | Existing controls | Engine behind them |
| --- | --- | --- |
| Light | Exposure, Contrast, Highlights, Shadows, Whites, Blacks | `CameraRawTables` (composed 3D LUT), `CameraRawShadows` (adaptive kernel) |
| Color | White Balance (Custom / Auto), Temperature, Tint, Vibrance, Saturation, eyedropper | `CameraRawTables.whiteBalance`, `CameraRawSettings.neutralize` |
| Color Grading | 4 wheels, Blending, Balance | `CameraRawTables.gradingStages` |
| Effects | Texture, Clarity, Dehaze, Glow (style/range/spread/warmth), Vignette (style/midpoint/roundness/feather/highlights), Grain (amount/size/roughness) | `adjust_camera_raw_effects`, `adjust_grain` |
| Curve | Parametric, Point (RGB/R/G/B), Refine Saturation, Targeted Adjustment | `adjust_camera_raw_curve_color` |
| Color Mixer | HSL for 8 families, Point Color (8 points, ranges, visualize) | `adjust_camera_raw_curve_color` |
| Detail | Sharpening (amount/radius/detail/masking), Noise Reduction (luminance/detail/contrast, color/detail/smoothness) | `adjust_camera_raw_detail`, `MetalNonlocalMeans` |
| Optics | Remove CA, Generic Lens Correction (distortion/vignetting), Manual Distortion, Defringe (eyedropper, hue ranges), Lens Vignetting | `adjust_camera_raw_optics`, `lens_distort` |
| Geometry | Upright strip (Off, Auto Level, Auto Vertical, Auto Full, Guided), Manual Transformations, Constrain Crop, Advanced (Perspective Amount, Framing, Volume, Auto EXIF, **Horizon**) | `CameraRawGeometrySettings`, `CameraRawPerspective`, `CameraRawHorizon`, `CameraRawUprightEstimation` |
| Calibration | Process version, Shadow Tint, RGB primaries | `adjust_camera_raw_calibration` |

Adjacent systems that must stay where they are: the Crop tool, RAW development editor, Lens
Effects, the non-destructive correction stack (`cameraRawFull` node) and ReShape.

## 2. What Adobe Camera Raw 2026 has that Compositor does not surface

Rows M10.1–M10.6 are now **done**; they are kept here because the table is the record of what the
reference added and where each control was placed. The one row still open is M10.7.

| Adobe feature | Exists in Compositor? | Reusable engine | Additive placement chosen |
| --- | --- | --- | --- |
| Light › Auto | No | `CameraRawTables.brightness`, `camera_raw_statistics`, histogram code | **M10.1 (done)** — `Auto` button at the top of Light; six sliders keep their order |
| Optics › Lens Blur (focus-area blur, aperture shape) | Engine only, GUI deferred | `CameraRawMiniature.blurMask`, `MetalBokeh`, `BokehShape` | **M10.2 (done)** — `Lens Blur` sub-group at the end of Optics |
| Color › White Balance presets (Kelvin list) | Not applicable: Compositor's WB is relative, not Kelvin | — | Deferred. A Kelvin list needs a sensor baseline Compositor does not have. |
| Detail › Denoise (AI) | Already: Noise Reduction runs `MetalNonlocalMeans` | — | Nothing to add. |
| Optics › camera-specific lens profiles | **M10.6 (done):** calibrated distortion / lateral CA / vignetting from a user-imported Lensfun XML, behind the M10.3 provider and off unless selected | `LensfunDatabaseManager`, `CameraRawLensProfileSettings`, `CameraRawLensfun`, `lensfun_correct` in `LensPixels.c` | **M10.6 (done)** — inside the existing Lens Profile subgroup; Apple Native still the default |
| Geometry › Horizon (independent of Upright) | Engine only before M10.4 | `CameraRawHorizon`, `CameraRawHorizonSettings` | **M10.4 (done)** — `Horizon` appended inside Advanced Geometry |
| Geometry › perspective guide kinds (Vertical / Horizontal / Combined / Rectangle / Eight Point) | Already: exposed by M10.5 | `CameraRawPerspectiveTools`, `CameraRawPerspectiveToolState` | **M10.5 (done)** — `Advanced Perspective Tools` appended after Horizon |
| Geometry › crop aspect after transform | Engine only (`CameraRawGeometryCrop`) | `CameraRawGeometryCrop.plan` | Deferred: changes output size, needs placement work. |
| Optics / Geometry › Miniature (tilt-shift) | Backend only — no Camera Raw UI | `CameraRawMiniature` | **M10.7** — its own framing problem; not a perspective tool |
| Presets / Masks panels | Correction stack + ReShape cover the non-destructive story | — | Out of scope: new top-level UI. |


## 3. Milestone 10.1 — Light › Auto

* **Where it lives now:** nothing; every Light slider is manual.
* **Reused components:** the same luminance measurement Camera Raw's adaptive sliders already
  read (`CameraRawTables.brightness` semantics), plus a 256-bin luminance histogram sampled from
  the preview source at ≤512 px.
* **Adobe difference closed:** ACR's Auto sets the six Light sliders from the picture's tones.
* **Placement:** a compact `Auto` button as the first row of the existing Light section. Exposure
  through Blacks keep their order, defaults, ranges, Option-clipping, scrubbing and reset.
* **Behavior:** pure function `CameraRawSettings.autoTone(of:)` returns exposure, contrast,
  highlights, shadows, whites and blacks; the button applies all six in one undoable change.
* **Not done:** Auto does not touch White Balance (Color › Auto already does that).

## 4. Milestone 10.2 — Optics › Lens Blur

* **Where it lives now:** `CameraRawMiniatureSettings` and `CameraRawMiniature` exist and run in
  the pipeline, but the source notes "GUI deferred" — no control reaches them.
* **Reused components:** `CameraRawMiniature.blurMask` (focus mask), `MetalBokeh` (aperture-shaped
  discs), `BokehShape` (Round / Hexagon / Oval / Cat's Eye), `PixelAdjust.render`.
* **Adobe difference closed:** ACR's Lens Blur blurs outside a focus region with an aperture shape.
* **Placement:** a `Lens Blur` sub-group at the end of the existing Optics section, after Lens
  Vignetting. Every existing Optics control stays where it is.
* **Behavior:** new `CameraRawLensBlurSettings` + `CameraRawLensBlur.apply`, executed after geometry
  and before the color grade, so it behaves as an optical stage. Amount 0 is exactly identity.
  Aperture shapes come from `MetalBokeh`; without Metal it falls back to a Gaussian blur of the
  same radius and the help text says so.
* **Persistence:** additive fields on the `optics` object in `CameraRawSettingsPersistentState`
  with explicit defaults, so projects saved before this milestone load unchanged (schema stays 1).
* **Reset:** `Reset Optics` clears Lens Blur with the rest of the section, because it is part of it.

## 5. Verification per milestone

1. BEFORE screenshot of the section (`work/camera-raw-parity/screenshots/`).
2. AFTER screenshot from the same `Screenshots.xcscheme` run, showing preexisting controls in
   their original order and position.
3. Focused unit tests: pure-function ranges, identity at default, real pixel change, persistence
   round-trip, backward-compatible decode, section reset.
4. Apply/Cancel and Undo/Redo: both features go through `updateFilter` → one `beginEdit`/`endEdit`
   on OK, nothing on Cancel, exactly like every other Camera Raw slider.

## 6. Verification record — M10.1 and M10.2

### Screenshots (`work/camera-raw-parity/screenshots/`)

The Camera Raw panel is its own docked dialog beside the document window, so the AFTER evidence is
captured from that dialog as an element. A whole-screen grab is mostly desktop and cannot be
cropped to the panel reliably across displays.

| File | Shows |
| --- | --- |
| `BEFORE_10_0_camera_raw_panel.png`, `BEFORE_10_0_editor.png` | The panel and editor before M10. |
| `AFTER_10_0_editor.png` | The editor after M10: canvas, layers and toolbar unchanged. |
| `AFTER_10_1_light_auto.png` | Light: `Auto` above Exposure; Exposure → Blacks unchanged and in order. |
| `AFTER_10_2_optics_lens_blur.png` | Optics scrolled to its end: `Lens Blur` (Amount, Aperture, Focus Range, Falloff, Highlights, Move Focus) after the existing Optics controls, with Geometry and Calibration still below. |

`screenshots/` holds two full-screen BEFORE captures and the editor AFTER; the two panel captures
are produced by `CompositorUITests/ScreenshotTests.swift` steps `07` and `08`.

### Tests

`CompositorTests/CameraRawParityTests.swift` — 16 tests, passing as part of the 116 tests in the
seven Camera Raw suites (`CameraRawTests`, `CameraRawParityTests`, `CameraRawResetTests`,
`NonDestructiveCameraRawTests`, `CameraRawGeometryBackendTests`, `CameraRawGeometrySafetyTests`,
`CameraRawSliderTests`):

| Area | Tests |
| --- | --- |
| Auto Tone | lifts an underexposed picture, leaves a well-spread one nearly alone, no histogram from an empty image, touches only the Light sliders, changes pixels, belongs to Light's reset (6) |
| Lens Blur | zero is exactly identity, blurs outside the focus region and keeps its middle, follows its focus region, apertures differ, settings normalize, part of the Optics group, persistence round-trip, older Optics without Lens Blur loads, corrupt values rejected, survives a full `cameraRawFull` node (10) |

`CompositorUITests/CameraRawSectionOrderTests.swift` — one UI test guarding the non-negotiable
structure: the ten section headers exist, top to bottom, in the fixed order; Light still has
Exposure → Blacks in order with `Auto` above them; Optics still has its Distortion control with
`Lens Blur` below the existing Optics controls; every other section is still reachable.

The screenshot test itself walks the panel: it asserts the `filterPanel` dialog exists, the Light
capture is taken with Light expanded as it opens, and the Optics capture is taken after scrolling
the panel to its end, where `Lens Blur` and its `Move Focus Region` button must exist.

## 7. Milestone 10.3 — Optics › Lens Profile (optional Lensfun provider)

Discovery only: the Lensfun database, the matching and the policy, with no pixel change. See
`M10_3_OPTIONAL_LENSFUN_PROVIDER.md`. The calibrated correction it prepares for is M10.6.

## 8. Milestone 10.4 — Geometry › Horizon

Full report: `M10_4_VIEWPOINT_GEOMETRY_INTEGRATION.md`.

* **Where it lives now:** a `Horizon` subsection appended at the end of `Advanced Geometry`, below the
  Volume rows. No existing row moved; `Perspective Amount`, Framing and Volume keep their order.
* **Reused components:** `CameraRawHorizonSettings` and `CameraRawHorizon` in full — the mode, the angle,
  the amount, the reference endpoints, `rotationDegrees`, `referenceAngle` and `rotationHomography`.
  No second solver, and no second rotation stage: `CameraRawGeometryBackend.compositionOrder` is unchanged.
* **Adobe difference closed:** ACR's Geometry panel has an independent Horizon control with the same five
  modes. Compositor had the backend and no way to reach it.
* **Composition rule:** `shouldApplyHorizon` still refuses Automatic while Auto Level found guides, so a
  picture is never rolled twice. Explicit Angle and references are allowed on top of Upright, which is
  what Camera Raw does.
* **Default:** Off, and Off is a bit-exact identity — `CameraRawHorizon.homography` returns `.identity`, so
  projects saved before this milestone render exactly as they did.
* **Persistence:** `CameraRawHorizonSettings` was already part of `CameraRawSettings`' encoding with its own
  defaults, so the schema version does not change. Non-finite angle, amount and reference values are now
  rejected by the reader rather than rendered.
* **Reset:** `Reset Geometry` clears Horizon with the rest of the section, including the reference draft.
* **Known gap:** the interactive guided acceptance gate was not observed. `CompositorUITests` is blocked by
  Automation Mode authentication on this machine, and the screen captures came back blank. The manual
  checklist is in the report's §5. The identifiers it needs are in place.

## 9. Revised milestone sequence

M10.4 inserted Horizon ahead of the advanced perspective work, because Horizon's backend was finished and
only its controls were missing. The rest shifts by one. M10.5 is now complete as well:

| Milestone | Scope |
| --- | --- |
| M10.5 | **Done.** Advanced Perspective Tool UI — the existing Rectangle, Eight Point, and Vertical / Horizontal / Combined guide kinds, plus Manual Keystone. See `M10_5_ADVANCED_PERSPECTIVE_TOOLS.md`. |
| M10.6 | **Done.** Calibrated Lensfun optical corrections — poly3 / poly5 / ptlens distortion, linear / poly3 lateral CA, PA vignetting — behind the M10.3 provider, user opt-in, no Apple double correction. See `M10_6_CALIBRATED_LENSFUN_CORRECTIONS.md`. |
| M10.7 | Miniature (tilt-shift) controls, and Adaptive ReShape framing and crop behaviour |

### Superseded scope, recorded so it is not started again

`COMPOSITOR_GEOMETRY_GAP_ANALYSIS.md` still proposes "Track A — Intensity + framing controls" as the next
milestone. **Do not start it.** Both halves already exist and are exposed:

| Track A item | Real state |
| --- | --- |
| Perspective intensity 0–100% | `CameraRawGeometrySettings.perspectiveAmount`, default 100, blended homography, `amountSlider` in Advanced Geometry |
| Keep-size vs bounding-box framing | `CameraRawFramingMode.keepOriginalSize` / `.expandToFit`, `Framing` picker in Advanced Geometry |
| Regression tests for both | `CameraRawPerspectiveIntensityFramingTests`, 15 tests |

The gap analysis was written before those landed. Its engineering advice about ViewPoint (keep Compositor's
coverage ranking, do not port Hough or DxO thresholds) is still sound; only its "next milestone" line is stale.

Every milestone from here on cites
[`REFERENCE_BASELINE_ADOBE_CAMERA_RAW_18_7.md`](REFERENCE_BASELINE_ADOBE_CAMERA_RAW_18_7.md) and meets its §7
acceptance gate. Work happens only in the existing worktree on `integration/compositor-camera-raw`; no new
branch, worktree or PR.

## 11. Verification record — M10.4

| What | Result |
| --- | --- |
| `CameraRawHorizonTests` | 47 tests, pass |
| Focused geometry, 12 suites | 185 tests, pass |
| All Camera Raw, 14 suites | 247 tests, pass |
| Before/after on real photographs | `work/geometry-validation/reports/m10_4-evidence/`, written by `CameraRawHorizonEvidenceTests` and copied by `scripts/horizon-evidence.sh` |
| Section order | `CompositorUITests/CameraRawSectionOrderTests` extended with the Geometry and Horizon identifiers, and with an assertion that `Perspective Amount` is still above Horizon |
| Screenshots | `ScreenshotTests` step `11` captures Geometry, scrolled to its end, showing Horizon and the unchanged controls above it. Not run: `CompositorUITests` is blocked here (§5 of the report) |
| Regression | **run: 1204 tests, 1198 passed, 5 environment failures (window geometry), 1 fixture skip.** No Geometry or Camera Raw failure |
| CI | **no evidence exists.** This fork has never triggered Actions. The `ci-tests.sh` selection bug found while auditing it is fixed and verified locally by running the script |

## 11a. Verification record — M10.5

| What | Result |
| --- | --- |
| `CameraRawPerspectiveToolsTests` | 44 tests, pass |
| `CameraRawPerspectiveEvidenceTests` | 2 tests, pass; 11 files written, copied by `scripts/perspective-evidence.sh` |
| Focused geometry regression (`CameraRawTests`, `CameraRawSliderTests`, `CameraRawPerspectiveToolsTests`, `FloatingPanelTests`, `TiledLayerTests`) | 104 tests, pass once the quiet group is sequenced (§6 of the report) |
| Before/after on real photographs | `work/camera-raw-parity/screenshots/m10_5-rendered/`, five corrections plus a Perspective Amount blend, with `corrections.csv` |
| Section order and reachability | `CompositorUITests/CameraRawSectionOrderTests` — `testAdvancedPerspectiveToolsAreReachable` drives Geometry › Advanced Geometry › Advanced Perspective Tools and confirms all seven kinds, by identifier, in a running app. **This ran**: UI automation works on this machine now, unlike during M10.4 |
| Screenshots | `ScreenshotTests` steps `12`–`19`, 20 captures in `work/camera-raw-parity/screenshots/m10_5-ui/`. Suite runtime cut from 327 s to 108 s (§6 of the report) |
| Canvas drag evidence | **not captured.** XCUITest drag synthesis does not reach the canvas; the panel's own counter stayed at zero. Stated as a gap in §5.3 of the report, not claimed as passing. The behaviour is proven at the model level instead |
| CI | **no evidence exists** for the same reason as M10.4; `scripts/ci-tests.sh` was corrected and exercised locally |

## 11b. Verification record — M10.6

| What | Result |
| --- | --- |
| Selected architecture | **A** — built-in Compositor correction code reading the user-imported Lensfun XML; no third-party binary, no runtime download, library validation intact (§3 of the report) |
| Calibration models | Distortion poly3 / poly5 / ptlens; lateral CA linear / poly3; vignetting `pa`. `acm` and decentered lenses parsed, named and refused |
| Pixel pass | One fused per-pixel kernel (`lensfun_correct` in `LensPixels.c`): vignetting multiplier, then green-sampled destination-to-source distortion, then per-channel CA shifts, bilinear on a premultiplied surface — vignetting → CA → distortion, before geometry, in a single resampling |
| Double-correction gate | `CameraRawLensfun.resolve` refuses Apple-corrected decodes and non-redevelopable sources; a redevelopable RAW is redeveloped with Apple correction off before the Lensfun pass touches it. Provider Apple → Lensfun → Apple round-trips with no accumulated pass (test: `providerSwitchingLeavesNoAccumulatedPass`) |
| Numerical comparison | Reference evaluator `work/camera-raw-parity/reports/.m10_6_scratch.py` (mirrors the Lensfun library formulas); `#expect` on exact doubles in `CameraRawLensfunTests` for rescaling, interpolation and the mapping direction; pixel pass checked against hand-computed expected channels |
| Real photographs | `work/camera-raw-parity/screenshots/m10_6-rendered/` — `window-wall.jpg` (Sigma 24-70 Art, distortion + vignetting + CA), `stone-house.jpg` (Tokina 16-28, distortion + CA), `sigma-40art-sample.CR2` (real RAW; vignetting, with Apple-off redevelop), each with corner crops and `lensfun-evidence.csv` / `raw-evidence.csv` |
| UI preservation | Ten Camera Raw sections in order (`CameraRawSectionOrderTests`); real automation captures in `work/camera-raw-parity/screenshots/m10_6-ui/` — Apple Native default, Lensfun without a database, Provider Off, matched profile with the TIFF double-correction refusal |
| Focused suites | `CameraRawLensfunTests` 35, `CameraRawLensProfileTests` 42, `CameraRawLensfunEvidenceTests` 2, `CameraRawLensfunRawEvidenceTests` 1 — all pass |
| Full regression | **run: 1289 tests, 1288 passed, 0 failed, 1 skipped** (environment-gated RAW fixture), bundle `work/camera-raw-parity/regression-m10_6.xcresult`. One pre-existing M10.5-era flake (`resetInThePanelShowsTheSectionAgain`) found via baseline re-run and fixed without touching tolerances |
| Persistence | Provider, lens selection and a database digest persist; legacy documents decode; a changed database is detected and re-resolved, never silently substituted; projects older than the digest load unchanged |

## 12. Verification per milestone

