# M10.6 — Calibrated Lensfun optical corrections

Status: complete for the supported models. A user-imported Lensfun database now drives a genuine
calibrated correction: vignetting, lateral chromatic aberration and lens distortion, applied in one
fused resample before geometry. Apple Native stays the default and needs nothing. Lensfun stays
opt-in, user-imported, and is refused wherever it cannot be applied safely — including where Apple's
own correction is still in the pixels.

Reference: Photoshop 2026 / Adobe Camera Raw 18.7, whose Optics tab applies a camera-specific lens
correction behind the user's back by default. Compositor's answer keeps the correction behind an
explicit choice of provider and an explicit database install, and states in the panel what is
correcting the picture at all times.

## 1. Architecture selected (§3): Compositor's own engine over Lensfun data

Option A, recorded in the M10.6 design notes and unchanged since M10.3's §2 ruled out the library:

* **No Lensfun code is built, shipped, downloaded or run.** The corrected equations are small and
  fully specified in Lensfun's public source (LGPL-3.0); Compositor implements the *calibration
  models* — the semantics of the data format — with its own C kernel and Swift interpolation. The
  LGPL attaches to Lensfun's object code, not to the mathematical definitions of its data format.
* The database stays **CC BY-SA 3.0 user-imported data**, parsed by Compositor's own Swift reader.
  Attribution stays in the panel (M10.3 §2), and the import is strictly user-initiated: the open
  panel is the only path in, and nothing is fetched, ever.
* Library validation, Hardened Runtime, App Sandbox and code signing are untouched. A separately
  signed helper (option B) would either weaken library validation, require per-architecture
  signing infrastructure the project does not have, or ship third-party executable code for an
  optional feature — and it would do so in every copy of the app, for a database most users never
  install. **The UI and the docs say plainly that the engine is Compositor's own** (`Importing
  reads Lensfun's XML profile data only. No Lensfun code is installed or run…`), which is the
  distinction §3 asks to be made clear.

Consequence stated honestly: a calibration model this build has not implemented (Lensfun's `acm`)
is named and refused, never approximated.

## 2. Supported calibration models (§4, §5, §6, §7)

| Correction | Models supported | Models parsed but refused |
| --- | --- | --- |
| Distortion | `poly3` (1 + k1·r²), `poly5` (1 + k1·r² + k2·r⁴), `ptlens` (1 + c·r + b·r² + a·r³) | `acm`, `none` |
| Lateral chromatic aberration | `linear` (per-channel scale), `poly3` (v + c·r + b·r² per channel) | `acm` |
| Vignetting | `pa` (1 + k1·r² + k2·r⁴ + k3·r⁶) | `acm` |

Preserved with the coefficients (§4):

* the calibration model identifier per sample;
* focal-length samples, per-sample coefficients, and the `real-focal` attribute (with Lensfun's own
  derivation when the attribute is absent: ptlens shrinks by 1 − a − b − c, poly3 by 1 − k1);
* aperture and focus-distance samples for vignetting;
* lens crop factor, the camera's crop factor when the entry mounts there, and `<center x= y=>`
  (read; a decentered lens is refused — this build corrects centered lenses only);
* the `<lensdatabase version>` (1–2 readable), so a file's origin and format are on record.

Never invented: a missing attribute means no correction, never a default. An entry with *any*
unsupported sample keeps its usable samples but reports the unsupported ones — the panel names
"distortion model acm" and so on, and the affected correction does not run.

## 3. Image-processing order (§8)

The calibrated pass rides the existing early-optics stage of `CameraRawSettings.applyResult`,
before any geometry:

```
RAW decode (Apple lens correction off when Lensfun will run)   ← RawImporter / CIRAWFilter
  → calibrated Lensfun pass: vignetting × lateral CA × distortion, ONE resample
  → manual distortion (early, when geometry runs) → volume → perspective → Horizon → crop
  → the per-pixel grade (tables, effects, detail + manual optics kernel)
  → Lens Blur → framing/crop placement
```

* One fused pass in `lensfun_correct` (`LensPixels.c`): per destination pixel, the distortion
  polynomial maps destination → source radius, the per-channel CA scales act on that distorted
  position, the sampled color is multiplied by the vignetting polynomial evaluated at the source
  radius, and one bilinear sample per channel carries the result. **One resample total** — the
  design notes rejected a two-pass warp (band-splitting 16-bit layers through two resamples would
  lose precision; HDR would round-trip through `DeepLayer.normalizing` for nothing).
* Vignetting is effectively pre-resampling (multiplied into the sampled color at its source
  position), which is how the reference's color pass is ordered relative to its geometry pass.
* No calibrated geometric correction can run after the perspective stage: the pass is invoked from
  exactly one place in `applyResult`, ahead of the early distortion, and nowhere else.
* Manual distortion, Defringe, Vignetting, Remove CA and Lens Blur are untouched and independent;
  a calibrated pass plus a manual distortion stack, as the milestone permits, since Off only ends
  the calibrated correction.

Tradeoffs recorded: the pass works on premultiplied 8-bit RGBA (the same surface the whole Camera
Raw kernel works on); 16-bit layers go through `DeepLayer.run`'s band-splitting, which reproduces
16-bit results from 8-bit runs and is exact for this per-pixel fused operation; HDR normalizes to
white for the pass and restores scale after. Vignetting cannot overbrighten past the alpha of the
pixel it lands on (the guard is in the kernel), and a multiplier that would blow a channel up is
clamped to ×20 before it can.

## 4. Double-correction policy (§9), enforced by construction

`CameraRawLensfun.resolve` is the single gate every render path consults — preview, commit, and
correction stack all reach it through the same `applyResult` parameters — and it produces a
correction only when **all** of these hold:

1. the provider is Lensfun, explicitly selected;
2. a database is installed in the session and a profile matches (automatic unambiguous, or a
   manual pick that still exists — a deleted manual lens is reported, never substituted);
3. the source is `redevelopableRaw` — the RAW's bytes are still held — **and** Apple's decoder
   correction is not in the pixels (`appleCorrectionActive == false`);
4. the shot's focal length is known; the models are supported; the coefficients are finite and in
   range; the crop factor exists; the vignetting measurement covers the shot's aperture and a
   focus distance the data can speak to.

Otherwise the resolution is nil with an issue list, and the render is byte-identical to an app
without the feature. The policies, by source:

| Source | Behavior |
| --- | --- |
| Redevelopable RAW, Apple on | Refused; the panel says to turn Apple's correction off first, so the distortion is not corrected twice |
| Redevelopable RAW, Apple off | Genuine calibrated correction; the decode that supplied these pixels ran with the decoder's correction off |
| Previously developed RAW | Refused — the decoder's correction, if any, is baked in and cannot be separated |
| Rendered image (JPEG/TIFF/PNG) | Refused — the camera's own correction may already be in the pixels |
| Off | No calibrated correction; manual and creative effects keep working |

Not a UI toggle over corrected pixels: the RAW redevelopment that supplies a Lensfun pass is the
one that ran with `lensCorrection = false` (`RawImporter.render` and the RAW development editor
both honor the setting), and the evidence test proves the pass changes the pixels of that decode
and leaves Apple-corrected and rendered sources untouched.

Switching Apple → Lensfun → Apple is reversible: the provider is a stored setting, the original
RAW is never modified, each state renders from the decode its policy prescribes, and the
`providerSwitchingLeavesNoAccumulatedPass` test renders Apple-corrected, Lensfun and off states
over the same source and asserts each is what its own policy says, with no pass accumulating.

## 5. RAW redevelopment interaction (§9)

* A normal new RAW still decodes with Apple's supported correction settings by default; nothing
  about the default path changed.
* After a RAW redevelopment, the redeveloped layer asset now **carries the source's lens
  metadata** (`EditorSession.applyRawDevelopmentEdit`), so the Lens Profile panel keeps describing
  and correcting the same lens after a redevelop instead of losing the identity.
* The correction-stack node path refuses a Lensfun pass by policy (stack nodes render baked
  pixels = rendered image), and its panel still reports the installed database honestly rather
  than "none" — the node edit snapshot now goes through the same ensure-loaded read the main
  filter path uses.

## 6. Persistence and database changes (§10)

* `calibrationDigest` (SHA-256 of the installed XML files, already computed by the store) is saved
  with the provider and selection, in the `optics` object, keyed alongside the M10.3 fields with
  per-key defaults: **projects older than the digest load unchanged** (test: `olderProjectsLoadWithoutADigest`).
* Rendering is a pure function of the current database and the stored selection; the digest never
  gates a render. When a reopened project's digest differs from the installed one, the panel says
  so — "The database has changed since this project was saved; the correction now comes from its
  current measurements." — instead of silently substituting. A database update therefore cannot
  quietly swap a lens under a photograph: the identity is stored (manual) or re-matched by the
  same deterministic rule (automatic), and any change is *visible*.
* A missing database never crashes and never silently chooses another profile: resolution reports
  `noDatabase` / `noUsableProfile` and the pixels stay.
* Decision recorded: **exact digest reference, not a calibration snapshot.** A snapshot would copy
  the whole database into every project; the reference makes a data change visible without
  changing what any project renders deterministically. Equal settings + equal database ⇒ equal
  correction (`ResolvedCorrection` is `Equatable`, and the resolution tests assert it).
* Provider, selection and digest are `CameraRawSettings` values: they travel with undo/redo,
  Apply/Cancel (Cancel discards, exactly like every other Camera Raw control), and Reset Optics
  restores Apple Native / no selection / no digest (test: `theProfileResetClearsTheDigestToo`).

## 7. Numerical reference comparison (§11)

Reference values come from a transcription of Lensfun's own routines — `_lf_interpolate`
(`auxfun.cpp`), `InterpolateDistortion` with its per-term focal scaling, `rescale_polynomial_coefficients`
(`mod-coord.cpp`), `ApplyGeometryDistortion`, `ModifyColor_DeVignetting_PA` — kept in
`work/camera-raw-parity/reports/.m10_6_scratch.py` alongside the report. Scenario: the test zoom's
two ptlens samples interpolated at 50 mm, rescaled at crop 1.0, over a 64×64 image.

| Quantity | Reference | Compositor (`numericalReferenceComparison`) | Tolerance | Measured |
| --- | --- | --- | --- | --- |
| Interpolated ptlens a / b / c at 50 mm | 0.017913043478 / −0.012086956522 / 0.001043478261 | asserted equal | 1e-9 | within |
| Interpolated real focal | 50.313043478261 | asserted equal | 1e-9 | within |
| Rescaled a′ / b′ / c′ | 0.231641944836 / −0.066744181443 / 0.002460528987 | asserted equal | 1e-9 | within |
| Normalization (64×64, crop 1) | 9.501175964556208e-03 | asserted equal | 1e-12 | within |
| Destination (62, 32) → source | (62.022752978, 32.000373000) | sampled red channel vs. analytic expectation | 2.0 units (8-bit bilinear rounding) | within |

The hermite interpolation tests additionally pin the FLT_MAX sentinel behavior, the per-term
focal scaling, and the IDW vignetting weights (power 3.5, normalized focal span, aperture as 4/f,
distance as 0.1/d) against hand-computed values. These are not visual judgements: every row is a
`#expect` on a specific double, and the suite runs in CI.

## 8. Photographic verification (§12)

Fixtures are untracked originals beside `work/geometry-validation/originals/`; the tests skip with
an explicit message when a checkout lacks them, and the originals are never overwritten.

Rendered evidence (`scripts/lensfun-evidence.sh` copies the sandboxed host's output into
`work/camera-raw-parity/screenshots/m10_6-rendered/`):

| Photograph | Lens (genuine match) | Corrections applied | Max channel delta (Apple vs Lensfun) | Changed fraction |
| --- | --- | --- | --- | --- |
| `window-wall.jpg` (EOS 6D, 24 mm f/3.2) | Sigma 24-70mm F2.8 DG OS HSM \| Art 017 | distortion + vignetting + lateral CA | 206 | 0.85 |
| `stone-house.jpg` (16 mm) | Tokina AF 16-28mm f/2.8 AT-X Pro SD FX | distortion + lateral CA | 238 | 0.84 |
| `sigma-40art-sample.CR2` (real RAW, 40 mm f/1.4) | Sigma 40mm F1.4 DG HSM \| Art 018 | vignetting (pa) | 199 (Off→Lensfun) | 0.98 |

`lensfun-evidence.csv` and `raw-evidence.csv` hold the full tables, including the two identity
rows the acceptance criteria care about: Apple Native on a rendered source changes nothing (max
delta 0, fraction 0.0000), and Lensfun with no database changes nothing. Side-by-side PNGs and
corner crops (`*-corner-top-left.png`, `*-corner-bottom-right.png`) show the corrections where
they act; the RAW comparison is rendered from the same CR2 bytes decoded three ways
(Apple on / Apple off + Lensfun / off).

UI captures (real automation through `CompositorUITests/LensfunScreenshotTests`, in
`work/camera-raw-parity/screenshots/m10_6-ui/`):

| File | Shows |
| --- | --- |
| `21 Lens Profile Apple Native default.png` | The default a user who never installs Lensfun keeps |
| `22 Lensfun chosen, no database.png` | The import control; the statement that nothing changes without a database |
| `24 Lensfun with database, profile matched, refused on a TIFF.png` | Provider Lensfun, database installed (1 lens, 1 camera), "Matched Sigma 24-70mm…", the calibrated rows, and the refusal: a TIFF may already carry the camera's own correction, and applying another would double it |
| `23 Provider Off.png` | Both providers out of the way; manual Optics unaffected |

The green "Applying…" state is not in these captures because the harness's source is a TIFF, which
policy refuses — the refusal wording is asserted in `CameraRawLensProfileTests` instead, and the
rendered proof of the state itself is `CameraRawLensfunRawEvidenceTests`. That is stated rather
than hidden, per §12's honesty rule.

## 9. Test results (§11, §13)

Focused suites (this milestone, all passing):

| Suite | Count | Covers |
| --- | --- | --- |
| `CameraRawLensfunTests` | 35 | Interpolation (hermite, splines, IDW), rescaling, normalization, resolution gates, refusal issues, pixel pass (barrel, edges, dimensions, CA, vignetting, blow-up guard), order before geometry, provider switching without accumulation, acm refusal, invalid coefficients, digest persistence, legacy decode, reset |
| `CameraRawLensProfileTests` | 42 (whole suite) | M10.3 discovery + the M10.6 policy: Apple default, opt-in, refusal sentences, `canApplyLensfunCorrection` |
| `CameraRawLensfunEvidenceTests` | 2 | Real photographs through the real pipeline; the refused pass on Apple-corrected pixels |
| `CameraRawLensfunRawEvidenceTests` | 1 | The real CR2: Apple vs Lensfun vs Off from the same bytes |

Full regression (`scripts/regression.sh`, plan `CompositorRegression`, finalized bundle
`work/camera-raw-parity/regression-m10_6.xcresult`):

* **1289 tests, 1288 passed, 0 failed, 1 skipped** — the skip is
  `RawDevelopmentIntegrationTests.realRawFixtureSmokePreview`, which requires
  `COMPOSITOR_RAW_FIXTURE_PATH` to point at a readable RAW and is environment-gated by design.
* 141 suites passed, 0 failed; `TiledLayerTests` and the window suites ran in their quiet group
  as the M10.5 fix prescribes (§13: the plan's fix still selects the intended tests — the
  enumeration preflight lists the same two exclusions and the quiet suites passed).
* One flake was found and fixed on the way through, honestly:
  `CameraRawResetTests.resetInThePanelShowsTheSectionAgain` failed **both with and without** the
  M10.6 work (verified by stashing the M10.6 diff and re-running at the M10.5 baseline — same
  single failure), because M10.5's keystone mirror made `normalized()` refresh
  `perspectiveTools.manualVertical` from `geometry.vertical`, and this test's hand-built
  expectation predated that invariant. The expectation now compares against
  `edited().resetting(.effects).normalized` — no tolerance was changed.

UI test run: `LensfunScreenshotTests` through the `Screenshots` scheme — 1 passed, and the four
captures above were regenerated and installed into `m10_6-ui/`.

## 10. Remaining limitations (§14)

* **`acm` models are parsed, reported and refused** — the panel names them; nothing is corrected
  with them. Implementing them (the multi-term polynomial space Lensfun 0.3 added) is the natural
  next increment.
* **Decentered lenses are refused** (`<center x= y=>` with non-zero offsets): the fused kernel
  corrects centered lenses. The panel says the profile's model is not applied rather than
  correcting about the wrong center.
* **Non-1:1 calibration aspect and per-calibration-set crop overrides** are outside this pass; the
  entries this build accepts are centered, aspect-1 calibrations, which is what the published
  database overwhelmingly contains.
* **Distance-dependent vignetting needs a real policy.** When an entry measures the same
  focal/aperture at several distances with differing coefficients, the shot's actual focus
  distance is unknown and vignetting stays off (`vignettingDistanceUnknown`), as the milestone
  directs. The exception is a measurement that repeats itself: an entry whose coefficients are
  identical at every distance it lists is distance-independent and used without guessing. A
  per-shot focus-distance input (EXIF rarely carries one) would unlock the general case.
* **8-bit surface precision.** The calibrated pass works on the same premultiplied 8-bit surface
  the rest of the Camera Raw kernel uses; 16-bit layers keep precision through `DeepLayer.run`'s
  band-splitting, and HDR through normalize/restore, but the pass itself is not a 16-bit kernel.
  This matches every other Camera Raw stage and is recorded in the kernel's header comment.
* **The evidence photographs are untracked** — a fresh checkout skips the photographic tests
  rather than inventing pictures; the RAW fixture likewise.

## 11. Files changed

New: `Compositor/Document/CameraRawLensfun.swift` (interpolation, coordinate math, resolution,
apply), `lensfun_correct` in `Compositor/Rendering/LensPixels.c/.h` (the fused kernel),
`CompositorTests/CameraRawLensfunTests.swift`, `CameraRawLensfunEvidenceTests.swift`,
`CameraRawLensfunRawEvidenceTests.swift`, `CompositorUITests/LensfunScreenshotTests.swift`,
`scripts/lensfun-evidence.sh`.

Extended: `LensfunXMLParser.swift` (coefficients, center, translated-model guard),
`LensfunDatabase.swift` (full calibration value types, distance-independent recognition),
`LensfunDatabaseManager.swift` (`ensureLoadedForEdit`), `CameraRawLensProfile.swift`
(`calibrationDigest`, `adjustsPixels`, policy), `CameraRaw.swift` (the gated pass, Lensfun
standing aside from the identity shortcut), `Filters.swift` (`FilterJob`/`FilterEdit` plumbing,
metadata after redevelop), `EditorSession.swift` (node-edit database snapshot, redevelop carries
lens metadata), `CameraRawSettingsPersistence.swift` (digest key), `CameraRawLensProfileControls.swift`
(per-correction status and refusal sentences), `Screenshots.xcscheme` (the UI suite).
