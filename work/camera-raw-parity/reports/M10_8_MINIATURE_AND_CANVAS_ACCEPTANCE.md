# M10.8 — Complete Canvas Acceptance + Miniature / Tilt-Shift

Milestone 10.8 had two halves. The first exposed the miniature/tilt-shift engine that has been in the
render pipeline since the Camera Raw geometry work, through the Geometry panel and the canvas, in the
same shape as every other Camera Raw section. The second was meant to close the three canvas
interaction gates that earlier milestones recorded as *not observed* — Guided Upright (M9.1.6),
Advanced Perspective (M10.5) and ReShape (M10.7) — under live acceptance. It did not close them: a
screen lock interrupted the first gate attempt, an unlocked re-run then proved that synthetic
`CGEvent` drags never reach the canvas at all, so all three stand honestly at NOT OBSERVED (§5).
This report records what was attempted, what passed, and what still stands unobserved.

No existing control moved. The Camera Raw section order — Light, Color, Color Grading, Effects, Curve,
Color Mixer, Detail, Optics, Geometry, Calibration — is unchanged and guarded by test
(`CameraRawPerspectiveToolsTests.theAdvancedSectionIsAppendedAfterHorizonAndKeepsEverySection`, which
checks `CameraRawGroup.panelOrder` verbatim).

## 1. The Miniature engine, already there

`CameraRawMiniature` has rendered miniature/tilt-shift since the geometry milestone: a masked variable
blur (`CIMaskedVariableBlur`) with a linear band or circular region kept sharp, everything outside
blurred. It runs in the composition order between framing crop and color grading
(`CameraRawGeometryBackend.compositionOrder`). What was missing was any way to reach it: no panel
control, no canvas interaction, no reset path.

## 2. Panel exposure

A **Miniature / Tilt-Shift** subsection is appended at the bottom of Advanced Geometry, below Advanced
Perspective Tools, collapsed by default (`miniatureExpanded = false`). When opened it offers:

| Control | Identifier | Notes |
| --- | --- | --- |
| Shape: Linear / Circular | `miniatureShapePicker` | Segmented; Linear is the default |
| Amount 0…100 | `miniatureAmount` | 0 = off; the header state text follows it |
| Angle −45…45 | `miniatureAngle` | Linear only — hidden for Circular, which has no direction |
| Focus Size | `miniatureFocusSize` | Fraction of the frame kept sharp |
| Falloff | `miniatureFalloff` | Softness of the sharp-to-blurred transition |
| Center X / Y | `miniatureCenterX`, `miniatureCenterY` | Focus position, normalized |
| Symmetric Blur | `miniatureSymmetricBlur` | Linear only; off blurs one side only |
| Move Focus on Image | `miniatureMoveFocus` | Enters the canvas focus mode (§3) |
| Reset Miniature | `miniatureReset` | Returns every parameter to identity |

Every subsection control flows through the same `update` path as the rest of Camera Raw, so Undo,
project persistence and the Geometry reset all cover it with no new machinery.

**Persistence and format-compatibility audit.** Nothing saved changed in this milestone. Miniature has
persisted inside the version-23 correction stack since the geometry work (the stack schema stores
`CameraRawGeometryBackendSettings`, miniature included, with its own `schemaVersion` 1), so the panel
exposure writes fields older readers already understand. The new-looking `center` on
`CameraRawMiniatureSettings` is a computed property over the existing `centerX`/`centerY`, not a
stored field, and every stored field decodes with `decodeIfPresent` defaults, so a pre-M10.8 stack
JSON loads unchanged. The canvas-mode state (`movesCameraRawMiniatureFocus`,
`cameraRawMiniatureDragOriginalCenter`) lives on `FilterEdit`, session-only like its Lens Blur
sibling, and is never serialized. `ProjectManifest.current` therefore stays at 25, and
`docs/project-format.md` needs no change.

### The `symmetricPosition` audit

`CameraRawMiniatureSettings.symmetricPosition` exists in the engine but does not participate in mask
generation: `CameraRawMiniature.blurMask()` never reads it. The audit confirmed it renders nothing in
any shape, so **no control was exposed for it**. It stays internal, documented in
`CameraRawMiniature.swift` as deferred, and a guard test asserts no `miniatureSymmetricPosition`
identifier appears in the panel source. Exposing a dead toggle would have been worse than deferring
it: the setting persists in the schema (backward compatible, identity default) so a future engine
change can pick it up without a format bump.

## 3. Canvas focus interaction

**Move Focus on Image** reuses the Lens Blur pattern exactly: `EditorSession` gains
`movesCameraRawMiniatureFocus` (mutually exclusive with every other canvas mode through the existing
`begin*` helpers), `FilterEdit` carries `cameraRawMiniatureDragOriginalCenter`, and `EditorCanvas`
routes mouse-down/dragged/up to `moveCameraRawMiniatureFocus(to:)`, shows the same crosshair-class
cursor family, and restores the previous mode on Escape with the original center and no history
entry. While the mode is active, drawing guides, perspective tools, horizon reference and Lens Blur
focus are all refused — one canvas gesture at a time, as everywhere else.

`.geometry` reset (and the panel's Reset Miniature) clear the mode's transient state too.

## 4. Tests

`CompositorTests/CameraRawMiniatureTests.swift` — 26 tests, pass:
identity defaults; parameter clamping and normalization (including non-finite input falling back to
strength 0); focus geometry; linear and circular mask generation; angle tilt; falloff; symmetric
blur; the `symmetricPosition` audit; pipeline composition order; `EditorSession` exclusivity and
Escape cancel; persistence round-trip.

`CompositorTests/CameraRawMiniatureEvidenceTests.swift` — renders the checked-in photographs through
`CameraRawSettings.applyResult`, the same path the panel commits; `scripts/miniature-evidence.sh`
copies the pictures out of the sandboxed test host, as `perspective-evidence.sh` does for M10.5.

UI: `CameraRawSectionOrderTests` extended — the subsection exists below the advanced tools, starts
collapsed, exposes every identifier from §2, hides Angle for Circular, and exposes no
`symmetricPosition` control. `ScreenshotTests` gained steps 20–22 (§6).

## 5. Canvas acceptance gates — the honest record

The three open gates were assessed individually. The blocker documented in M10.5 §5.3 stands:
XCUITest's drag synthesis does not reach the layer-backed canvas in this app. This milestone added
one new avenue (a proof-of-delivery harness), hit one new blocker (the screen lock), and then
answered the underlying delivery question with an unlocked re-run; all three outcomes are recorded.

**The new avenue.** `CompositorUITests/CanvasDragTests.swift` re-tries `CGEvent` posting from the
runner — the thing M10.5 found "silently dropped" — with a difference: this time every test reads
the panel back after the drag (the Upright `N/4 guides` count, the advanced tools' line counter), so
a dropped drag **fails the test** instead of passing vacuously. M10.5's attempt could not tell
delivery from silence; this one can. Two gates have tests: A (Guided Upright, armed via the
`geometryDrawGuides` button and judged by `geometryGuideCount`, a new identifier this milestone
adds) and B (Advanced Perspective vertical guides, judged by `advancedPerspectiveCount`).

**The new blocker, then the unlocked re-run.** The first run never reached its assertions: the
Mac's screen locked (`CGSSessionScreenIsLocked = 1`, confirmed from the session dictionary) between
the regression run and the gate attempt, and a locked screen hides application windows from
Accessibility (even Finder reported zero windows), drops posted events, refuses display capture,
and leaves XCUITest unable to activate the app — both tests failed at activation ("current state:
Running Background"), before any drag was posted.

The screen was then unlocked and the same committed tests were re-run to completion. This time the
app activated, the panels were driven for real (the Upright arm button clicked; counters read back
as `0 of 2 lines` / `0/4 guides` before the drag), synthetic `CGEvent` drags were posted at the
canvas center, and the counters were read back after: still `0 of 2 lines` and `0/4 guides`. The
delivery question is therefore answered, not left open: posted `CGEvent` drags are **not** delivered
to this layer-backed canvas view even when correctly targeted at its frame. The verdicts below stand
as NOT OBSERVED on automation evidence, with the panel-side and model-side proofs unchanged — a
hardware drag, or a person at the machine per the M10.5 §5.4 and M10.7 §9 checklists, remains the
only path that has ever moved these counters.

| Gate | Verdict | What was tried | What is proven instead |
| --- | --- | --- | --- |
| A — M9.1.6 Guided Upright canvas interactions | **NOT OBSERVED** | `CanvasDragTests` run locked (activation blocked) and re-run unlocked to completion; `CGEvent` drag posted at the canvas, counter unchanged (`0/4 guides`) | Model-level guide math + rendered corrections |
| B — M10.5 Advanced Perspective canvas interactions | **NOT OBSERVED** | Same, via `testAdvancedPerspectiveVerticalGuideReceivesACanvasDrag`; counter unchanged (`0 of 2 lines`) after the unlocked drag | 44 `CameraRawPerspectiveToolsTests` + rendered corrections |
| C — M10.7 ReShape canvas interactions | **NOT OBSERVED** | Not attempted: A and B delivered no drag, and a marquee needs a mesh open, which the panel alone does not create | 99 mesh tests + rendered transforms |

None of the three gates is claimed as passed. The panel-facing side of each feature is proven by real
UI automation; the canvas gesture itself remains proven at model level and through the render
pipeline, with the manual checklists of M10.5 §5.4 and M10.7 §9 as the person-at-the-machine path.
`CanvasDragTests` remains the standing automation path; since synthetic `CGEvent` input does not
reach the layer-backed canvas, a green run would require a different input route (e.g. an
XCUIElement gesture API that dispatches through the app, or hardware-in-the-loop), and until one
exists the honest verdict for canvas gesture delivery is NOT OBSERVED.

## 6. Evidence

- **Rendered**: `work/camera-raw-parity/screenshots/m10_8-rendered/` — `stone-house-miniature.png`
  and `window-wall-miniature.png`: before / linear band / circular region sheets from the real
  pipeline on the checked-in photographs.
- **UI**: `work/camera-raw-parity/screenshots/m10_8-ui/` — 25 captures from real automation. Step 20
  shows the subsection collapsed (the "Off" state visible), 21 the full Linear block (Shape, Amount,
  Angle, Focus Size, Falloff, Center X/Y, Symmetric Blur, Move Focus, Reset), 22 the Circular
  selection with the Angle control correctly gone.

A capture lesson worth keeping: the subsection's rows publish to the accessibility tree only after
the panel list has been *walked* end-to-end in small scroll steps — the same treatment
`CameraRawSectionOrderTests` needed in M10.5. A large scroll teleports past lazy rows without
publishing them, and a scroll that carries the disclosure row out of view recycles it and resets its
`@State` expansion. `ScreenshotTests` now walks the list the proven way and re-opens the subsection
if a scroll recycled it, and a missing capture is recorded loudly (`MISSING` in the name plus a tree
diagnosis attachment) instead of skipping silently.

## 7. Regression

Full ordinary regression through `scripts/regression.sh` (plan `CompositorRegression`, heavy tests
excluded by the plan; no 6000×4000 benchmark run): **run: 1333 tests, 1332 passed, 0 failed, 1
skipped** (environment-gated RAW fixture), bundle
`work/camera-raw-parity/regression-m10_8.xcresult`, xcodebuild exit status 0. The M10.7-era failure
(`leavingTheCanvasRestoresTheArrowWithEveryTool`) did not recur. The M10.7 record in
`FEATURE_PARITY_PLAN.md` had left its regression line dangling; it is filled from that milestone's
archived bundle (1305 tests, 1303 passed, 1 failed, 1 skipped).

Focused suites: `CameraRawMiniatureTests` 26 tests, pass; `CameraRawPerspectiveToolsTests` (the
panel-order guard included), pass; six further Camera Raw geometry/reset suites, pass;
`CameraRawMiniatureEvidenceTests` 2 tests, pass. UI: `ScreenshotTests.testMainScreens` (25 captures)
and `CameraRawSectionOrderTests`, both pass via the `Screenshots` scheme.

## 8. Manual acceptance checklist

For a person at the machine, with a picture open and `Filter › Camera Raw Filter…` up:

1. Open **Geometry** → **Advanced Geometry**, scroll to the end. Is **Miniature / Tilt-Shift** below
   Advanced Perspective Tools, and is it collapsed?
2. Open it. Do the Linear controls appear, with Amount 0 and the header reading "Off"?
3. Raise **Amount**. Does the picture blur outside a horizontal band, with the band sharp?
4. Switch **Shape** to **Circular**. Does Angle disappear, and does the blur move outside a circle?
5. Press **Move Focus on Image** and drag on the canvas. Does the sharp region follow the drag, and
   does Escape put the focus back where it was with no undo step?
6. Press **Reset Miniature**. Does everything return to identity, and does the header read "Off"
   again?
7. Choose a Perspective tool and draw guides. Do the Miniature controls and the guide drawing stay
   out of each other's way (one canvas mode at a time)?
