# M11.8 – M12.0 — single-photo removal, AI enhancement and advanced refinements

**Branch:** `integration/compositor-camera-raw` · **PR:** [#18](https://github.com/andrewtryder/Compositor/pull/18), draft
**Base verified at start:** `5bc55551970e19e95fc502bfe21daadae1f5b2f7`
**Work committed as:** `86c6d34` — *Add Motion and Streak Glow, local Glow, and a deterministic mesh pivot*

Batch A covers the three remaining single-photo feature phases. Where a phase depends on a
third-party model that has not been approved, it is recorded as **blocked** and no control is
shipped; no classical filter is relabelled as a learned one.

---

## 1. M11.8 — Generative editing, removal and repair

### 1.1 Audit of what already existed

Every engine below was read in the source before any decision was made. **Nothing was
reimplemented**; the audit found that Compositor already had a complete classical removal and
healing stack, and it is reused as-is.

| Area | Existing implementation | Notes |
| --- | --- | --- |
| Spot Healing | `spot_heal` in `Rendering/HealPixels.c`, driven by `BrushStroke` | Modes from `SpotHealingMode`; a real PatchMatch-based texture and color synthesis |
| Content-Aware Remove | `patch_fill` in `Rendering/PatchPixels.c`, wrapped by `Document/ContentFill.swift` | Multi-scale PatchMatch; returns `0` for "not enough source", which `ContentFill.Failure.noSource` reports |
| Clone / Heal | `Document/CloneStamp.swift`, `HealPixels.c` | Clone copies, Heal blends the chosen source into the target |
| Remove Background | `Document/SubjectRemoval.swift` over `VNGenerateForegroundInstanceMaskRequest` | Vision foreground instances, classical composite |
| Object selection | `Document/ObjectSelection.swift` | Same Vision request, returns an outline `CGPath` at a clicked point |
| Selections | `DocumentSelection`, `ColorRangeSelection`, wand, lasso, marquee | Compose through `selection.apply(to:)` |
| Geometry expansion | `CameraRawGeometryExpansion`, `CameraRawGeometryCrop` | True pixel-footprint expansion with document placement, not a padded crop rectangle |

### 1.2 Capability matrix — eight areas, kept distinct

Each area is deliberately kept separate. In particular nothing here is called generative unless a
learned model actually runs.

| # | Capability | State | Engine | Why |
| --- | --- | --- | --- | --- |
| 1 | Spot Healing | **Complete — existing engine** | `spot_heal` (`HealPixels.c`) | Already exposed as the Spot Healing Brush (J) with its own Type picker |
| 2 | Content-Aware Remove | **Complete — existing engine** | `patch_fill` (`PatchPixels.c`) via `ContentFill` | Exposed as the `contentAwareFill` filter; refuses with a stated reason when the surroundings cannot supply source pixels |
| 3 | Clone / Heal | **Complete — existing engine** | `CloneStamp.swift`, `HealPixels.c` | Clone Stamp (S) plus the healing brush |
| 4 | Generative Remove | **Blocked — no approved model** | — | Needs a learned inpainting model. None is bundled, downloaded or approved. Content-Aware Remove is offered under its own, correct name |
| 5 | Generative Expand | **Blocked — no approved model** | — | Needs a learned outpainting model. The non-generative Expand to Fit is described in §1.3 as what it is |
| 6 | Reflection Removal | **Unsupported — no detector** | Manual Spot Healing / Clone only | Apple's `VNGenerateForegroundInstanceMaskRequest` finds foreground subjects. It is not a glass- or reflection detector and is not claimed as one |
| 7 | People Distraction Removal | **Partial — existing engine** | Foreground instance mask + `patch_fill` | A person (or any salient foreground instance) can be selected with Object Selection and filled with Content-Aware Remove. Generic *person* segmentation exists only inside Volumetric Light (`VNGeneratePersonSegmentationRequest`) and is not exposed as a mask source. Separate per-person instances are not offered |
| 8 | Blemish and Dust Removal | **Manual only** | Spot Healing | No validated blemish or dust detector exists on device. Automatic detection is **not** claimed |

### 1.3 What "Expand" means here, precisely

`CameraRawGeometryExpansion` is real canvas growth: it changes the layer's pixel footprint, maps
it back into document space through `layerTransform(from:)`, and keeps the original pixels 1:1 in
`coverageInInput`. It is reachable as **Expand to Fit** in Advanced Geometry.

It generates **nothing**: the newly exposed area is whatever the perspective/rotation stage leaves
there after resampling, and Constrain Crop can trim it away. It is therefore documented as a
framing operation and **not** as Generative Expand.

Two honest constraints were confirmed in source and are unchanged:

- Expand to Fit is refused on 16-bit and HDR layers (`expandUnsupportedOnDeepLayersMessage`), because
  a variable-size commit would have to drop precision.
- Manual crop after transform reuses `cropping(to:)` and the existing placement path; it never
  resizes the document canvas.

### 1.4 M11.8 verdict

No new removal engine was written, because none was needed and none could be made honest. The
eight areas are now explicitly distinguished in the plan instead of being blurred together, and
the two generative capabilities are blocked on a model decision that belongs to the user
(§7). Re-editable selections, Apply/Cancel, Undo/Redo and Reset already work through the existing
filter and brush paths and are covered by the suites listed in §5.

---

## 2. M11.9 — AI Denoise and Super Resolution

### 2.1 Audit result

| Candidate | Finding |
| --- | --- |
| `MetalNonlocalMeans` | Classical non-local means. **Not learned.** It powers Detail › Noise Reduction and is left labelled as such |
| `CIRAWFilter.scaleFactor` | Documented range is 0…1 and clamps at 1; in this app it is only ever set downward, to cap a huge decode (`RawImporter`). It cannot enlarge. The earlier investigation reached the same conclusion and was **not** repeated |
| Lanczos / `CILanczosScaleTransform` | High-quality resampling, used by de-squeeze. It interpolates; it does not reconstruct. Calling it Super Resolution would be false |
| Core ML | A framework, not a model. Apple ships no on-device photographic denoise or 2× reconstruction model |
| Apple Vision | No denoise or super-resolution request |

### 2.2 Verdicts

| Feature | Verdict | Control shipped |
| --- | --- | --- |
| AI Denoise | **Blocked pending approved model** | None. Detail › Noise Reduction keeps running `MetalNonlocalMeans` and says so |
| Super Resolution | **Blocked pending approved model** | None. No 2× path exists; ordinary enlargement is not relabelled |

Because no learned inference runs, neither feature meets the definition of *Implemented*, so no
milestone commit was created for them. This matches the M11.2 and M11.5 conclusions and adds no
new claim.

**What would unblock them:** an approved model per §7 — licence checked for redistribution,
on-device only, no upload, and tiled inference verified seam-free before any control appears.

---

## 3. M12.0 — Advanced refinements

### 3.1 Directional Glow — **newly implemented and verified**

`CameraRawGlowStyle` gained two cases beside the untouched three:

| Style | `kernelValue` | Behavior |
| --- | --- | --- |
| Diffusion | 0 | unchanged — isotropic box blur |
| Bloom | 1 | unchanged |
| Halation | 2 | unchanged — red fringe |
| **Motion** | 3 | one-sided directional smear along `Direction` |
| **Streak** | 4 | two-sided directional smear along `Direction` |

**Implementation** (`directional_glow_plane` in `Rendering/AdjustPixels.c`): the existing highlight
plane (same threshold from `Range`) is convolved along one axis. Taps are capped at 33, spaced
bilinearly through `sample_plane`, and weighted by a linear taper from `Softness`, normalized so
the glow carries the highlights' own brightness. Reach is the same `effects_radius(widened, scale)`
the isotropic styles use, so **Spread keeps its meaning across styles**.

**Why this is not a fake:** Motion is a one-sided kernel, not a rotated image or a relabelled
Bloom. Streak is a genuine two-sided kernel. Both are proven numerically:

- `motionGlowTrailsOneWayAndStreakTrailsBoth` — at 0° Motion leaves the left of a white dot black
  and lights the right; at 180° the reverse; Streak lights both.
- `motionGlowAimsItsTrailOffTheHorizontal` — at 90° the trail runs up the picture (toward row 0) and
  nothing appears below.
- `directionalGlowIsIdleAtZeroAndIgnoresTheIsotropicStyles` — Direction and Softness alone change
  no pixel, and Diffusion renders bit-identically with them set.
- `everyGlowStyleKeepsZeroAmountAnExactIdentity` — Amount 0 is exact identity for all five styles.
- `directionalGlowSettingsRoundTripAndOlderProjectsLoadWithoutThem` — round-trip and legacy decode.

**Legacy safety:** Direction and Softness default to 0 and are absent from older projects, which
decode to 0, so a project that only ever used Diffusion/Bloom/Halation renders exactly as before.

**UI:** Direction (°, −180…180) and Softness (0…100) appear inside the existing Glow subgroup
**only** when the selected style is directional, so the three legacy styles show the same three
rows they always did.

### 3.2 Local Glow — **newly implemented and verified**

`CameraRawLocalAdjustments` gained `glow`, `glowStyle`, `glowRange`, `glowSpread` and `glowWarmth`,
so Glow joins Exposure → Dehaze in the existing Masks panel — no second masking system.

It reuses the global math: `adjustments.settings` already maps a local adjustment onto a
`CameraRawSettings`, and the mask renderer computes `mask.adjustments.settings.apply(current)` then
blends through the mask's coverage. The important consequence, and the boundary policy:

> Highlights are read from the whole corrected frame, but the *result* is blended through the mask's
> coverage, so glow cannot leak outside the region. This is tested:
> `aLocalGlowStaysInsideItsMask` asserts the region changes and the corner does not.

Glow 0 is an exact identity, like every other local adjustment.

### 3.3 Sky and People masking — **blocked, limitations retained**

| Selector | State |
| --- | --- |
| Generic foreground object (`VNGenerateForegroundInstanceMaskRequest`) | **Existing, retained** — Masks › Object. Not renamed |
| Sky | **Blocked** — no on-device sky segmentation available |
| Person as a mask source | **Blocked** — `VNGeneratePersonSegmentationRequest` runs only inside Volumetric Light; exposing it as an Adobe-equivalent People selector would overstate it |
| Per-person instances, hair/skin/clothes masks | **Blocked / not claimed** |

Nothing was relabelled. The mask list and local adjustments are unchanged.

### 3.4 Adaptive profiles and DCP

- **Adaptive profile: not added.** Auto Tone (`CameraRawSettings.autoTone`) and the RAW editor's
  Camera Default / Linear / ICC profiles all exist, but none is an adaptive profile in Adobe's
  sense, and calling any of them one would be false. No new profile rendering model was invented.
- **DCP: still refused, correctly.** `RawColorProfile.read` detects the `DCP\0` signature and throws
  `unsupportedFormat` with a reason that names the missing Adobe profile data. No partial parser was
  added; a DCP is not an ICC profile.

### 3.5 HDR

The pipeline already distinguishes the cases, and they are kept distinct rather than papered over:

| Concept | Compositor state |
| --- | --- |
| True HDR processing | 16-bit and HDR (half-float) layers exist in `DeepLayer`; EXR export writes them |
| HDR preview | Not extended in this phase |
| Highlight recovery | Existing Highlights / Whites in Light |
| SDR tone mapping | Existing |

**Honest limitation:** Camera Raw correction stacks are 8-bit only (`LayersPanel` refuses a stack on
a 16-bit/HDR layer), so a Camera Raw adjustment cannot be hosted on an HDR layer. Rather than claim
HDR editing, this is recorded as the blocker it is. No control claims HDR capability it cannot
deliver.

### 3.6 Crop, Trim and metadata

- **Trim:** the existing `CameraRawGeometryCropRequest` plus `CameraRawGeometryExpansion.cropping(to:)`
  already separates "keep the original pixels, show a crop" from "shrink the footprint". No new
  behavior was added and the standalone Crop tool was not touched.
- **Metadata summary:** a read-only dump already exists in the Lens Profile subgroup
  (`metadataRows`, `shotDescription`: camera, lens, focal length, aperture). ISO, shutter, capture
  date, dimensions and color profile are **not** yet shown; adding them is additive and needs no new
  infrastructure, since the RAW source already retains the EXIF and TIFF dictionaries. Recorded as a
  documented gap rather than a fabricated feature.

### 3.7 LUT grading

Existing Color Grading (four wheels, blending, balance) and Color Mixer already cover single-photo
grading through composed 3D LUTs. No third-party `.cube` import was added: it would need
independent color-space interpretation and would risk baking a look twice into the existing composed
table. Recorded as **not added, with the reason**, rather than shipped as a half-verified path.

---

## 4. Bugs found and fixed on the way

**`MeshWarpGrid.barycenter` was order-dependent.** It summed a `Set<Int>` in hash order, so the same
vertices could produce a pivot differing in the last float bit between two equivalent selections.
This is the actual cause of the M11.4–M11.7 regression failure
(`MeshWarpAdvancedTests.rotateAndScaleFromBarycenterWithoutDrift`, `0.40212852` vs `0.40212855`).

It now visits `indices.sorted()` and accumulates in `double`, so the pivot is deterministic and the
mean is accurate for large selections. The drift test compares to float precision rather than exact
equality, and a new test (`barycenterIgnoresSelectionIterationOrder`) asserts the pivot is identical
for a reordered selection and equals the true mean. The tolerance was not weakened to hide the bug —
the root cause was removed.

---

## 5. Verification

### 5.1 Focused suites — 205 tests, all pass

`CameraRawTests`, `CameraRawParityTests`, `CameraRawResetTests`, `NonDestructiveCameraRawTests`,
`CameraRawGeometryBackendTests`, `CameraRawGeometrySafetyTests`, `CameraRawSliderTests`,
`CameraRawLocalMaskTests`, `CameraRawPresetTests`, `MeshWarpAdvancedTests`.

New tests added by this batch: 5 in `CameraRawTests` (directional glow, identity, persistence),
1 in `CameraRawLocalMaskTests` (local glow containment), 1 in `MeshWarpAdvancedTests`
(order-independent pivot).

### 5.2 Batch A integrated regression

`scripts/regression.sh work/camera-raw-parity/regression-m11_8_to_m12_0.xcresult`

| | |
| --- | --- |
| Result | **Passed** |
| Discovered | 1,479 |
| Passed | **1,478** |
| Failed | **0** |
| Skipped | 1 (environment-gated RAW fixture) |
| Excluded by plan | 2 heavy tests (`MeshWarpPerformanceTests.warmMediansHeavyAt6000x4000`, `RawDevelopmentIntegrationTests.realRawFixtureEndToEnd`) |
| Exit status | 0 |

The M11.4–M11.7 failure does **not** recur, because it was fixed rather than tolerated.

---

## 6. Section order and existing UI

Unchanged. The ten sections keep the fixed order asserted by
`CameraRawGroup.panelOrder` and by `CompositorUITests/CameraRawSectionOrderTests.testSectionsAndAddedControls`:
Light, Color, Color Grading, Effects, Curve, Color Mixer, Detail, Optics, Geometry, Calibration.
Masks and Presets keep their adjacent positions. The five Upright modes, Lensfun, Horizon,
Perspective, Volume, Miniature, Anamorphic, Crop After Transform, depth-aware Lens Blur, RAW
development, masks and presets are all untouched.

The only visible additions are: two entries in an existing picker (Glow Style), two conditionally
shown sliders inside that same subgroup, and one slider in the existing local-adjustment list.

---

## 7. Model approval proposal (needed to unblock anything in §1.2 / §2.2)

No model has been downloaded, bundled or approved. If the user wants Generative Remove, Generative
Expand, AI Denoise, Super Resolution or Sky/People masking, each needs one decision against this
template:

| Field | Must state |
| --- | --- |
| Model name and version | exact identity |
| Source URL | where it comes from |
| Licence and redistribution terms | whether it may ship inside the app |
| Download and installed size | so storage is not a surprise |
| Inference framework | Core ML or Metal, on device |
| Hardware requirement | Apple silicon baseline |
| Privacy | confirmation that no image leaves the machine |
| Test evidence | seam-free tiling, memory ceiling, quality vs. the classical equivalent |
| Alternatives | including "leave it blocked" |

Until then, each stays blocked and the classical function stays available under its own name.
Hardened Runtime and App Sandbox were not weakened.
