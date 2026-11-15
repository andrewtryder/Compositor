# M10.9 — Anamorphic De-squeeze and Geometry-Aware Crop

Milestone 10.9 adds two things to Advanced Geometry, both additive and both behind the existing
Camera Raw section machinery:

1. **Anamorphic De-squeeze** — one horizontal scale factor that restores a squeezed photograph's
   intended proportions, as a true pixel transform with correct layer placement.
2. **Crop After Transform** — a geometry-aware crop that plans on the *corrected* image, after
   de-squeeze / Volume / Perspective / framing, with aspect constraints and an armed canvas mode.

No existing control moved. The Camera Raw section order — Light, Color, Color Grading, Effects,
Curve, Color Mixer, Detail, Optics, Geometry, Calibration — is unchanged and guarded by test
(`CameraRawGroup.panelOrder`). Both new subsections are appended at the bottom of Advanced
Geometry, after Miniature / Tilt-Shift, collapsed by default.

## 1. The coordinate-system audit

Everything in this milestone hinges on keeping five coordinate systems distinct. The audit mapped
them before implementation (full note: `work/camera-raw-parity/reports/.m10_9_design_notes.md`):

| # | System | Lives in | Changed by |
| --- | --- | --- | --- |
| 1 | Source pixel dimensions | the layer asset's bitmap (`edit.original.image`, `FilterJob.image`) | Lensfun / manual distortion, Upright solver guides |
| 2 | Corrected pixel dimensions | the bitmap after the geometry block (`CameraRawGeometryResult.image`) | de-squeeze (new), Volume, Perspective, framing, crop (new) |
| 3 | Document-space layer footprint | `LayerTransform` on the layer, for a variable-size result `expansion.layerTransform(from: base)` | both, via the same expansion |
| 4 | Corrected image's crop rectangle | `CameraRawGeometryCropRequest.manualCropScalars` (CG pixel space, top-left origin) | crop-after-transform only |
| 5 | Document canvas dimensions | `CanvasDocument.size` | neither — the canvas is never resized here (the Crop tool does that, untouched) |

De-squeeze changes 1→2 (and 3 via the expansion); crop-after-transform changes 2→4 (and 3 via
`cropping(to:)` on the expansion); the document canvas (5) is untouched. Conflating them is the
classic bug — placing the crop in the wrong grid would silently crop the wrong picture.

## 2. Anamorphic De-squeeze

### Placement and controls

A **Anamorphic De-squeeze** subsection is appended at the bottom of Advanced Geometry, below
Miniature / Tilt-Shift, collapsed by default (`anamorphicExpanded = false`). When opened:

| Control | Identifier | Notes |
| --- | --- | --- |
| Ratio picker | `anamorphicRatioPicker` | Off / 1.0×, 1.33×, 1.5×, 1.6×, 2.0×, Custom |
| Custom ratio field | `anamorphicRatioField` | Numeric, 1…8; visible only for Custom |
| Active-state text | `anamorphicActiveState` | "Off" or "1.50×" in the collapsed header |
| Disclosure | `anamorphicDisclosure` | Collapsed by default |
| Reset | `anamorphicReset` | Back to Off |

`CameraRawAnamorphicPreset` maps ratios to menu entries and back; a ratio within 0.005 of a named
preset reads back as that preset, anything else as Custom (test: `deSqueezePresetsMatchTheirRatios`).

### The transform

`CameraRawGeometrySettings.applyDeSqueeze` renders one horizontal Lanczos resample —
`CILanczosScaleTransform` with `inputScale: 1.0, inputAspectRatio: ratio` through
`PixelAdjust.render` — to `round(w·ratio) × h`. Ratio 1 (Off), or any ratio whose rounded output
equals the input, returns the input unchanged with no expansion: no resampler touch, bit-exact
(test: `deSqueezeIdentitySkipsResample`, run on photograph pixels). Output size is checked against
`DocumentLimits.maxSide` / `maxSurfacePixels` *before* allocation; a ratio past the limits throws
`ProjectError.tooLarge` rather than guessing a smaller one (test: `deSqueezeRefusedPastDocumentLimits`).

The result's placement is a center-anchored `CameraRawGeometryExpansion`: coverage
`CGRect(x: -(outW − w)/2, y: 0, width: outW, height: h)` in the input's pixel space — the captured
frame's center stays put. A 2× de-squeeze of a 60×40 frame covers `−30…90` in input x, which the
expansion struct already permits and places correctly (test: `deSqueezeTwoTimesWidensAndPlacesCenterAnchored`).

### Order in the pipeline

`compositionOrder` in `CameraRawGeometryBackend` is now:

1. `lensDistortion` — lens models are calibrated on the sensor grid, so they see squeezed pixels
2. `anamorphicDeSqueeze` — **new**; restores true proportions
3. `volume`
4. `perspective` (+ Horizon composed into the destination corners)
5. `framingCrop` — Keep Original Size / Expand to Fit
6. `cropAfterTransform` — **new**; crop coordinates live in the final corrected space
7. `miniature`
8. `colorGrade`

One resample total: the de-squeeze is the only new sampling pass, and it is skipped entirely at
Off. The de-squeeze expansion is composed with the perspective stage's expansion inside
`applyResult` via `CameraRawGeometryExpansion.composing(_:)`, so every existing consumer
(`FilterEdit` preview/commit placement, `CameraRawGeometryBackend.apply` crop folding,
`LayerCorrectionRenderer`, `commitCorrectionStack(expandPlacement:)`) keeps its
single-expansion contract unchanged (test: `deSqueezeExecutionOrderRunsBeforePerspective`).

## 3. Crop After Transform

### Placement and controls

A **Crop After Transform** subsection is appended after the de-squeeze subsection, collapsed by
default. When opened:

| Control | Identifier | Notes |
| --- | --- | --- |
| Mode picker | `cropAfterTransformModePicker` | No crop (default) / Automatic opaque crop / Manual rect |
| Manual X / Y / W / H | `cropAfterTransformX` … `cropAfterTransformH` | Corrected-image pixels, top-left origin |
| Aspect picker | `cropAfterTransformAspectPicker` | Free / Original / Fixed |
| Fixed aspect field | `cropAfterTransformAspectRatio` | Width over height, visible only for Fixed |
| Constrain to image | `cropAfterTransformConstrain` | Intersect with opaque pixels / bounds |
| Edit on Image | `cropAfterTransformEdit` | Enters the armed canvas mode (§4) |
| Reset Crop | `cropAfterTransformReset` | Back to No crop |

### The plan

`CameraRawSettings.applyResult` runs `CameraRawGeometryCrop.plan` on the corrected image **after**
geometry and **before** Miniature / Lens Blur, matching `compositionOrder`'s `cropAfterTransform`
slot, then folds the plan rect into the expansion with `cropping(to:)`. The aspects: Free keeps
the dragged rect; Original fits the source image's aspect; Fixed takes the numeric ratio — through
the existing `constraining(toAspect:)` (test: `cropAfterTransformManualRectIsHonoredAndAspectConstrained`).

- **No additional crop is a true no-op.** The request's default `constrainToImage = true` makes
  `plan` fall back to the opaque inscribed rect — right for the geometry-only backend node path
  (existing behavior, preserved), but wrong as "no crop". The filter path therefore gates on the
  new `CameraRawGeometryCropRequest.isNoCrop` (`!automaticOpaqueCrop && manualCrop == nil`);
  older projects (no `crop` key → default request) render exactly as before
  (test: `cropAfterTransformNoCropIsANoop`).
- **A pipeline bug this milestone caught:** the evidence test
  `identityIsBitExactAndCropKeepsItsRect` failed because `CameraRawSettings.adjustsGeometry`
  ignored the crop request — crop-only settings never entered the geometry block at all. Fixed by
  including `!crop.isNoCrop` in it; the test now proves a manual crop commits exactly the kept
  rectangle, pixel-identical to the source crop, with the placement carrying its true position
  (test: `cropAfterTransformFoldsIntoExpansion`).
- **No double crop**: with Constrain Crop on, geometry already removed transparent margins, so
  the plan's opaque scan lands on an already-opaque image and intersects to the same rect.
- **Reset / bypass**: cleared by Geometry reset (`copy(.geometry)`, now including `crop`) and the
  Geometry eye (`applying(showsGeometry: false)`), both covered by test
  (`resetGeometryClearsCropAndDeSqueeze`, `geometryEyeBypassesCropAndDeSqueeze`).
- Out-of-bounds / degenerate rects plan to nil → no crop, never a corrupt layer.

## 4. The armed canvas crop mode

**Edit on Image** reuses the armed-mode pattern of Miniature focus and the Horizon reference:

- `FilterEdit` gains `editsCameraRawCrop`, `cameraRawCropDragTarget`
  (a `CameraRawCropDragTarget`: eight handles or a fresh `rectangle`) and
  `cameraRawCropDragOriginalScalars`, captured when arming begins.
- Arming is exclusive: it ends Miniature focus, perspective tools, Horizon reference and Guided
  drawing, exactly as each of those ends the others. `EditorSession.beginCameraRawCropEditing()`.
- While armed, the preview renders **uncropped**: `FilterJob.editsCameraRawCrop` neutralizes the
  crop request in `previewJob`, so the rectangle can be drawn over the whole corrected picture.
  `FilterEdit.renderSettings()` leaves the committed settings alone — only the preview is neutral.
- Coordinates map view → document → corrected pixels through
  `BrushRaster.pixelToDocument(preparedTransform, width/height: preparedPreview)` — the *placed*
  preview transform, which already includes de-squeeze/perspective placement. The rectangle is
  therefore drawn and grabbed on the transformed image, never on the source grid.
- A press grabs a handle under the pointer (12 pt tolerance, document-scaled) or starts a new
  rectangle at the press point; a drag moves the grabbed handle with the opposite anchor fixed;
  Escape restores the captured scalars exactly and disarms, with no history entry
  (`cancelCameraRawCropEditing`). The panel button and Return end the mode keeping the rect
  (`endCameraRawCropEditing(cancelled:)`), and the next render writes the genuinely cropped output.
- Aspect constraints from the panel apply on commit through `plan`; the canvas drag itself is
  free-form, and `constrainToImage` clamps the drag into the corrected bounds.

Document-space snap targets (the Crop tool's guides) are deliberately not folded in — they would
have to pass through the geometry warp. Recorded as a deviation from the Crop tool's behavior.

## 5. Precision policy — 16-bit / HDR refusal

`DeepLayer.run` demands same-size output, so variable-size operations cannot pass through a
16-bit/HDR layer without an 8-bit surface. Exactly as Expand to Fit does:

- `CameraRawGeometrySettings.deepLayerRefusalMessage(_:)` names the first variable-size feature in
  the settings (Expand → de-squeeze → crop, one message at a time in coercion order).
- `FilterEdit.renderSettings()` and `updateFilter` coerce the features off on a deep asset and set
  `previewError` to the matching message. No 16-bit/HDR layer is ever flattened, baked, or
  downconverted by these features (tests: `deepLayerRefusalsNameEachFeature`,
  `deepCommitKeepsSixteenBitWithoutDeSqueeze` — a coerced de-squeeze runs as identity and the
  result stays 16-bit).
- `hasVariableSizeFeatures(_:)` (Expand ∨ de-squeeze ∨ crop) covers the selection-blend path,
  which needs a matching footprint.

## 6. Persistence

Nothing breaking: `crop` rides `CameraRawSettingsPersistentState` (schema 1) with `decodeIfPresent`
defaults, the correction-stack schema stays at its current version, and `ProjectManifest.current`
stays 25. `docs/project-format.md` needs no change. The saved fields: the whole
`CameraRawGeometryCropRequest` (framing, automaticOpaqueCrop, manualCropScalars, aspectMode,
aspectRatio, constrainToImage) and `geometry.anamorphic` (one ratio), both identity-defaulted so a
pre-M10.9 document loads unchanged (tests: `cropAndAnamorphicRideExistingSchemas`,
`cropManualScalarsRoundTrip`). `FilterEdit` drag state is session-only, never serialized.

## 7. Tests and regression

`CompositorTests/CameraRawAnamorphicCropTests.swift` — 16 tests, pass: de-squeeze identity skip,
2× widening with center-anchored placement, preset round-trips, execution order before perspective,
limit refusals; crop no-op, automatic opaque plan, manual rect with aspect, expansion folding;
deep-layer refusals and variable-size coverage with a coerced 16-bit commit; persistence defaults,
manual-scalars round-trip, Geometry reset and eye bypass.

`CompositorTests/CameraRawAnamorphicEvidenceTests.swift` — renders the report's photographic
evidence through the real pipeline on the checked-in photographs, plus the measured claims:
Off is bit-identical to the input, 2.0× widens to exactly double, a manual crop commits exactly the
kept rectangle. `scripts/anamorphic-evidence.sh` copies the pictures next to this report.

Neighboring suites re-run after the changes: `CameraRawGeometrySafetyTests`,
`CameraRawGeometryBackendTests`, `CameraRawResetTests`, `CameraRawParityTests`,
`UnifiedGeometryBackendTests` — 67 tests, pass. Full ordinary regression through
`scripts/regression.sh` (plan `CompositorRegression`, heavy tests excluded):

*run: 1352 tests, 1351 passed, 0 failed, 1 skipped* (environment-gated RAW fixture), bundle
`work/camera-raw-parity/regression-m10_9.xcresult`, exit 0. The first same-day run failed one
test: `geometryOperationsRunInTheDocumentedOrder` still expected the pre-M10.9 pipeline order;
its expectation now names the M10.9 order, and this superseding run is the milestone's record.

## 8. Evidence

- **Rendered**: `work/camera-raw-parity/screenshots/m10_9-rendered/`
  - `stone-house-anamorphic.png` — the photograph squeezed 2× horizontally, then Off, 1.5× and
    2.0× de-squeeze beside each other: the restored proportions.
  - `window-wall-geometry-crop.png` — before, de-squeezed 2× uncropped, and the 60% crop commit.
- **UI captures**: **not captured.** The `CompositorUITests` automation path is blocked by the
  canvas-delivery limitation recorded in M10.5 §5.3 and M10.8 §5 (posted events do not reach the
  layer-backed canvas). The panel-side identifiers from §2/§3 exist and the subsection layout is
  asserted in source order; a later capture run can walk the list the proven way (small scroll
  steps, re-opening recycled disclosures).

## 9. Manual acceptance checklist

For a person at the machine, with a picture open and `Filter › Camera Raw Filter…` up:

1. Open **Geometry** → **Advanced Geometry**, scroll to the end. Are **Anamorphic De-squeeze** and
   **Crop After Transform** below Miniature / Tilt-Shift, collapsed?
2. Open **Anamorphic De-squeeze**. Is it Off with the header showing "Off"?
3. Pick **2.0×**. Does the picture widen to double with its center staying put? Does the header
   show "2.00×"?
4. Pick **Custom** and type 1.44. Does the menu stay on Custom while the slider is off every
   preset, and the picture widen by a smaller amount?
5. Back to **Off**. Is the picture exactly as it was (no resample, no shift)?
6. Open **Crop After Transform**. Is it **No crop** with the picture unchanged?
7. Choose **Manual rect** and set X/Y/W/H. Does the picture crop to that rect, in corrected-image
   pixels, and does **Original** aspect snap the rect to the source's proportions?
8. Press **Edit on Image** and drag on the canvas. Does a rectangle follow the drag over the whole
   (uncropped) corrected picture, with handles on the stored rect to grab?
9. Press **Escape**. Is the crop put back exactly where it was, with no undo step?
10. Toggle the Geometry eye off. Does the crop and de-squeeze both stop reaching the picture, and
    back on restore?
11. On a 16-bit layer, set a de-squeeze ratio. Is the feature refused with the message about the
    16-bit pipeline, and does the layer stay 16-bit?

## 10. NOT OBSERVED — carried forward

The canvas-interaction gates carry forward from earlier milestones, and this milestone adds one to
the same family:

| Gate | Verdict | Basis |
| --- | --- | --- |
| M9.1.6 Guided Upright canvas drag | NOT OBSERVED | carried from M10.8 §5 |
| M10.5 Advanced Perspective canvas drag | NOT OBSERVED | carried from M10.8 §5 |
| M10.7 ReShape canvas gestures | NOT OBSERVED | carried from M10.8 §5 |
| M10.9 armed crop canvas gestures | **NOT OBSERVED** | model-level drag math and pipeline placement proven by tests; the panel-side button exists; posted-event delivery is the same blocker recorded in M10.8 §5 |

None of these is claimed as passed. A person at the machine per §9 remains the acceptance path.
