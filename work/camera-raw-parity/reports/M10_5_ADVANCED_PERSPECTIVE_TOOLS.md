# M10.5 — Advanced Perspective Tools

Compositor already had the perspective solvers: `CameraRawPerspectiveTools` could solve Vertical, Horizontal,
Combined, Rectangle and Eight Point guides, and manual keystone was reachable through the sliders in Manual
Transformations. None of it had a way in. This milestone adds the panel and canvas that reach it, without writing a
second solver, changing Upright, or moving anything that came before.

Reference: Photoshop 2026 / Adobe Camera Raw 18.7, whose Geometry tab offers the same set under "Upright" and
"Guided".

## 1. What was added, and where

One collapsed subsection, **Advanced Perspective Tools**, is appended to the end of Advanced Geometry — after
Horizon, below Perspective Amount and Framing. Nothing above it changed position, and every one of the ten Camera Raw
sections keeps its order.

| Inside the subsection | Control |
| --- | --- |
| Header | `advancedPerspectiveDisclosure`, `advancedPerspectiveActiveTool` |
| Tool selector | `advancedPerspectiveToolPicker`, one row per kind |
| Instructions | `advancedPerspectiveInstructions` |
| Drawing | `advancedPerspectiveDraw` ("Draw on Image" / "Stop Drawing") |
| Point count | `advancedPerspectiveCount` |
| Problem report | `advancedPerspectiveIssue` |
| Clearing | `advancedPerspectiveClear` |
| Keystone summary | `advancedPerspectiveManualSummary` |

It starts collapsed, so an existing workflow is untouched until it is opened. The seven tool kinds are
`CameraRawPerspectiveToolKind`: Automatic, Vertical Guides, Horizontal Guides, Combined Guides, Rectangle, Eight
Point, Manual Keystone.

Default is **Automatic**, which leaves the Upright mode above entirely in charge — the subsection adds a way to reach
the other solvers, it does not compete with the one already there.

## 2. How the tools compose with what was there

`CameraRawPerspectiveTools.applying(_:to:)` maps a tool state onto a *copy* of the geometry settings used for
rendering. Stored values are never rewritten by a selection, which is what makes switching safe:

- **A guide tool is selected** → the copy's manual vertical/horizontal/rotate are zeroed, so the guides are not
  solved on top of a keystone that was already applied. The stored slider values survive untouched.
- **Manual Keystone is selected** → the copy's Upright is set to `.off`, so the sliders correct the picture instead.
  The stored Upright mode survives: choosing Automatic again brings the Guided correction straight back.
- **Automatic** → the copy is the settings as they stand. Identity.

Verified by `legacyUprightModesAreUnchangedByAnAutomaticTool`, `inactiveToolStateNeverReachesTheRenderer`,
`switchingToolsPreservesEachToolsWork`, `switchingAwayFromAnIncompleteToolLeavesNoGeometry` and
`manualKeystoneMirrorsTheExistingSliders`.

### No duplicate sliders

Manual Keystone deliberately has **no sliders of its own**. The numbers belong to Manual Transformations, and a
second set would be a second owner for them. The subsection reports what those sliders say
(`advancedPerspectiveManualSummary`, e.g. "Vertical +3 · Horizontal -1 · Rotate +0.4°") and explains, when Upright
is not off, that the sliders are standing in for it. `manualKeystoneMirrorsTheExistingSliders` and
`selectingManualKeystoneSeedsTheMirrorFromTheSliders` hold that line.

## 3. Canvas interaction

`EditorSession` owns the state; `EditorCanvas` routes the mouse. Each mode takes canvas gestures **exclusively** —
only one of `drawingCameraRawPerspectiveTool`, `drawingCameraRawGeometryGuide` and `drawingCameraRawHorizonReference`
can be armed — so a drag can never be claimed by two tools.

| Gesture | Result |
| --- | --- |
| Drag | A draft line; the correction previews live as it is dragged |
| Release | Commits the guide |
| Escape | Cancels the draft and restores the exact original point |
| Delete | Removes the selected handle |
| Clear | Removes only that tool's points; other tools keep theirs |

Per-tool storage is separate, so a Rectangle does not disturb four Combined guides. `eachToolReadsItsOwnStoredPoints`,
`deletingAHandleRemovesOnlyThatGuide`, `clearingAToolLeavesTheOthersAlone` and `escapeRestoresTheOriginalDragState`
cover this.

Rectangle corners are placed one click at a time and can be taken back: the getter returns however many corners
are placed so far, which is what lets a half-drawn rectangle be corrected rather than wiped.

## 4. Numerical safety

Every point is validated before it can reach a solver. The cases below are each a test:

| Case | Behaviour |
| --- | --- |
| Non-finite coordinate | Dropped on read; never rendered (`corruptToolPointsAreDroppedRatherThanRendered`) |
| Duplicate points | Rejected as insufficient |
| Zero-length segment | Reported as a problem, not silently accepted (`degenerateGeometryIsRejected`) |
| Collinear points | Insufficient, not a degenerate homography |
| Invalid rectangle corner order | Enforced (`rectangleCornerOrderIsEnforced`) |
| Self-intersecting rectangle | Refused (`anExtremeRectangleIsRefusedRatherThanFolded`) |
| Eight Point with fewer than four segments | Applies nothing (`eightPointNeedsAllFourSegments`) |

Sanitizing happens on read, not before analysis: an earlier version stripped bad points first, which turned every
diagnosis into "insufficient points" and hid what was actually wrong. `problem(in:width:height:)` now inspects the
stored state directly.

## 5. Evidence

### 5.1 Rendered through the real pipeline

`CameraRawPerspectiveEvidenceTests` runs the checked-in photographs through `CameraRawSettings.applyResult` — the
same path the panel previews and Apply commits — and writes before/after pairs to
`work/camera-raw-parity/screenshots/m10_5-rendered/`. `scripts/perspective-evidence.sh` copies them out of the
sandboxed test host.

`corrections.csv` from the last run, on `stone-house.jpg` at 520×347 (180,440 pixels):

| Tool | Pixels changed | Max channel delta |
| --- | --- | --- |
| Vertical Guides | 155,912 | 255 |
| Horizontal Guides | 147,045 | 255 |
| Combined Guides | 163,788 | 255 |
| Rectangle | 151,593 | 255 |
| Eight Point | 149,466 | 255 |

The Perspective Amount blend is captured separately at 0 / 50 / 100, showing identity, half and full.

### 5.2 Panel screenshots

Twenty captures in `work/camera-raw-parity/screenshots/m10_5-ui/`, produced by `ScreenshotTests` through real UI
automation. 12 and 13 show the subsection collapsed and open; 14 shows the tool menu with all seven kinds; 15–19
show each tool's selected state with its own instructions and count wording.

### 5.3 What is **not** captured, and why

**No screenshot shows guides actually drawn on the canvas.** That gate is not passed and is not being claimed as
passed.

XCUITest's drag synthesis (`press(forDuration:thenDragTo:)` on a window coordinate) does not reach the canvas in this
app. The panel's own counter — the thing that would prove a drag landed — stayed at zero after every attempt, so a
capture would have shown an empty canvas and proved nothing. `CGEvent` posting was tried too; it is silently dropped
unless the runner holds accessibility permission.

The honest statement is: the drag-and-drop behaviour is proven at the model level, by the 44 tests in
`CameraRawPerspectiveToolsTests`, and the correction it produces is proven through the real rendering pipeline by the
pictures in §5.1. What is missing is a photograph of a drag in flight, from an automation harness that cannot deliver
one.

### 5.4 Manual acceptance checklist

For a person at the machine, with a picture open and `Filter › Camera Raw Filter…` up:

1. Open **Geometry** → **Advanced Geometry**, scroll to the end. Is **Advanced Perspective Tools** below Horizon,
   and is it collapsed?
2. Open it. Does the tool menu list all seven, and does the header read "Off"?
3. Choose **Vertical Guides** and press **Draw on Image**. Drag two lines along converging building edges. Does the
   picture straighten, and does the count read "2 of 8 lines"?
4. Choose **Rectangle** and click four corners round a face, top-left first. Does the face square up? Click a fifth
   time — does nothing happen?
5. Press **Clear Rectangle**. Does the correction go, and do the vertical guides from step 3 survive?
6. Choose **Manual Keystone**. Do the sliders above drive the picture, and does the summary follow them?
7. Choose **Automatic**. Does your Guided Upright correction come back unchanged?

## 6. Regression hardening

Three things were fixed on the way through, all of them found by this milestone's test runs rather than invented.

### `FloatingPanelTests`

The suite failed for developers whose saved window frame differed from a fresh install's. It now establishes a known
editor frame (`usePredictableEditorWindow()`) and restores the previous one afterwards, so the test is about panel
placement and nothing else. It does not wipe the developer's preferences.

### `TiledLayerTests`

`paintingAtTheLayersEdgeDoesNotChangeIt` failed intermittently — never alone, only when sharing a process with other
suites. The diagnostic from the M10.5 run: *546 pixels differ, in x 100…667 y 650…650; first at 100,650: masked
[203, 87, 230, 255] painting [201, 90, 245, 255]*, worst delta 15 against a tolerance of 2.

The test compares a tiled draw against the same pixels drawn as one image. That is a pixel-exactness assertion, and
Core Graphics picks different resampling paths for the two when the process is competing for cores. **The tolerance
was not widened** — that would hide a real difference. Instead `TiledLayerTests` moved into a group of its own
(`QUIET_SUITES`) that runs with parallel testing off, after the parallel groups have finished.

### `scripts/ci-tests.sh`

Two fixes:

1. **Join before counting.** Every group is now waited on before any `.xcresult` is read. Reading a count while
   `xcodebuild` is still running finds an unfinalised bundle and reports zero — which is how M10.4's `rest` count
   check managed to look at a bundle that did not exist yet.
2. **A group that runs no tests fails the run.** The check that caught `rest` selecting nothing is applied to every
   group, so a future filter-list mistake cannot report green.

### `ScreenshotTests` throughput

The suite took **327 s** and is now **108 s**, without weakening any assertion. Where the time went, measured from the
run's own activity log:

| Cost | Before | Cause |
| --- | --- | --- |
| Element snapshots | 659 × ~0.28 s | Every `.frame`, `.exists` and `.isHittable` is a round trip to the app |
| Scroll events | 1,896 × ~18 ms | Five loops of ninety tiny scrolls of −60 |
| App-idle waits | 30 s | XCUITest already waits after every interaction |
| Fixed sleeps | ~21 s | A second on top of each of the above |

The fixes were to coalesce scrolling into a dozen large steps, cache the canvas rect once instead of recomputing it
per drag, and drop the fixed sleeps that only repeated XCUITest's own idle wait.

## 7. Test summary

| Suite | Tests | Covers |
| --- | --- | --- |
| `CameraRawPerspectiveToolsTests` | 44 | All seven kinds, validation, composition, persistence, undo |
| `CameraRawPerspectiveEvidenceTests` | 2 | Real photographs through the real pipeline |
| `CameraRawSectionOrderTests` | 2 | Ten sections in order; every M10.5 control reachable in a running app |
| `ScreenshotTests` | 1 | Twenty captures including the M10.5 panel states |

The 44 tests map onto the milestone's 25 requirements as follows: kinds and defaults (1, 2), per-tool storage and
switching (3, 4), canvas gestures and Escape (5, 6, 7), keystone synchronisation (8, 9), composition with Upright,
Horizon, Volume, amount and crop (10–14), numerical safety (15–20), persistence and undo (21, 22), panel structure and
identifiers (23, 24), and capacity (25).

## 8. Deliberate non-goals

- **No second solver.** Everything routes through the existing `CameraRawPerspectiveTools`.
- **No new keystone sliders.** Manual Transformations stays the one owner.
- **No Upright behaviour change.** The five modes and Guided Upright are untouched; the new subsection defers to them.
- **No crop/volume/framing changes.** Those keep their existing pipeline, which `volumeRemainsIndependentOfThePerspectiveTools`,
  `constrainCropIsLeftToTheExistingPipeline` and `previewAndCommittedRenderTheSamePixels` guard.
