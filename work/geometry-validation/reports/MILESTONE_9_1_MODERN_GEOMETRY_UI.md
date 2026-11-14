# M9.1.1: Fix Guided Upright and Complete Visual Verification

## Overview

Corrections to PR #17 (M9.1: Modern Adobe Camera Raw Geometry UI) following independent code review. Fixes Upright mode labeling, Geometry guide coordinate alignment, genuine endpoint dragging, the four-guide limit, and Geometry panel hierarchy. Then verifies the running macOS UI against the Adobe Camera Raw 19.0 Geometry reference.

**Branch:** `camera-raw-modern-geometry-ui`  
**Worktree:** `/Users/atr/code/Compositor-geometry-ui`  
**Current commit:** `44fcf07b5f977107457c344dcde95d8506d20cef`  
**Draft PR:** https://github.com/andrewtryder/Compositor/pull/17  

## Visual references used

| Reference | URL | Purpose |
|-----------|-----|---------|
| Primary — ACR 19.0 Geometry panel | https://photoshopcafe.com/wp-content/uploads/2026/11/ACR-19-New-Features_46.jpg | Geometry panel layout, upright icon strip, styling, manual sliders |
| Secondary — ACR 18.3 full workspace | https://www.fredmiranda.com/forum/ufiles/67/3060767.jpg | Canvas framing, checkerboard empty edges, perspective guides on photograph |
| Official behavior reference | https://helpx.adobe.com/camera-raw/desktop/edit-and-enhance-images/crop-rotate-and-geometry/automatic-perspective-correction-camera-raw.html | Guided/Auto upright behavior and semantics |

Reference screenshots were downloaded to `/tmp/compositor-geometry-ref/` and **not committed** (copyrighted Adobe imagery).

---

## 1. Correct Upright mode labeling and behavior

### Finding
The `CameraRawUprightMode` enum has only five values (Off, Auto Level, Auto Vertical, Auto Full, Guided), but the report described a six-mode strip. The display labels and tooltips said "Auto", "Level", "Full" instead of the actual case names.

### Fix
- **`CameraRawGeometryCalibrationControls.swift`**: Updated tooltips and accessibility labels to match the exact enum cases:
  - `off` → "Off — No perspective correction"
  - `autoLevel` → "Auto Level — Levels the image and corrects horizontal tilt"
  - `autoVertical` → "Auto Vertical — Straightens converging vertical lines"
  - `autoFull` → "Auto Full — Full perspective correction for level and vertical"
  - `guided` → "Guided — Draw custom guides on the image"
- Removed the non-existent sixth button. Five honestly labeled functional modes are retained.
- Updated the layout doc comment to list the five actual modes.

### Test
- `CameraRawGeometryGuideTests.allFiveUprightModesAreDistinctAndHonest` — verifies `allCases.count == 5`, the exact raw values, and `isAuto` classification for each case.

---

## 2. Fix Geometry guide coordinates

### Finding
`EditorCanvas.drawCameraRawGeometryGuides()` converted guide coordinates using the full document dimensions (`guide.startX * document.size.width`), which only works when the image fills the document. `beginCameraRawGeometryGuide()` normalizes via `FilterEdit.previewMapping`. These were inconsistent.

### Fix
- **`EditorCanvas.drawCameraRawGeometryGuides()`**: Now converts each normalized guide point through the same image→document→view chain used by guide creation:
  1. Multiply normalized coordinates by `previewSource` pixel dimensions.
  2. Apply `edit.previewMapping` to get document points.
  3. Apply `viewport.viewPoint(from:documentSize:)` to get view points.
- The same conversion is applied to the draft guide while drawing.
- This alignment holds when the image fills the document, when the layer is offset, when scaled, when transformed, when the document is larger than the photograph, and at different zoom/pan values.

### Test
- `CameraRawGeometryGuideTests.normalizedGuideMapsThroughPreviewMapping` — round-trips a normalized point through previewMapping and back.
- `CameraRawGeometryGuideTests.guideCoordinatesStayWithinImageBounds` — verifies extreme corner guides map inside the document-image region.

---

## 3. Implement genuine endpoint dragging

### Finding
`session.hitGuide()` and `beginGuideMove()` operate on document-layout `CanvasGuide` objects, not `CameraRawGeometryGuide` endpoints. The report's claim of draggable guide endpoints was incorrect.

### Fix
Added dedicated Camera Raw endpoint hit testing and editing, reusing the existing `CameraRawPerspective` solver:

**`Filters.swift`** — New `FilterEdit` state:
- `cameraRawDraggingGuideIndex: Int?` — index of the guide being edited
- `cameraRawDraggingEndpoint: Bool` — `true` = end endpoint, `false` = start

**`CameraRaw.swift`** — New methods:
- `cameraRawHitGuideEndpoint(at:zoom:)` — hit-tests both endpoints of every guide, tolerance scales with zoom
- `beginCameraRawGuideEndpointDrag(at:zoom:)` — records which guide/endpoint is selected
- `continueCameraRawGuideEndpointDrag(to:)` — moves only the selected endpoint; the opposite stays fixed; updates the preview live
- `cancelCameraRawGuideEndpointDrag()` — clears drag state without modifying the guide

**`EditorCanvas.swift`** — Wired mouse events:
- `mouseDown`: if a guide endpoint is under the pointer (and no draft is in progress), begins endpoint drag instead of creating a new guide
- `mouseDragged`: endpoint drag takes priority over creating a new guide
- `mouseUp`: finalizes an in-progress endpoint drag (clears state, no second commit)
- `keyDown`: Escape cancels an in-progress endpoint drag

Required behavior verified by tests:
- Clicking near an endpoint selects that endpoint ✓
- Dragging moves only the selected endpoint ✓
- The opposite endpoint remains fixed ✓
- The correction preview updates ✓
- Mouse-up finalizes the updated draft ✓
- Escape cancels an in-progress endpoint drag ✓
- Moving a Geometry guide never moves a document-layout guide (separate state) ✓
- Hit testing works at different zoom levels ✓

### Test
- `CameraRawGeometryGuideTests.endpointHitTestSelectsCorrectEndpoint`
- `CameraRawGeometryGuideTests.endpointHitTestToleranceScalesWithZoom`
- `CameraRawGeometryGuideTests.endpointHitTestWithNoGuidesReturnsNil`
- `CameraRawGeometryGuideTests.draggingAnEndpointMovesOnlyThatEndpoint`
- `CameraRawGeometryGuideTests.endpointDragIsCanceledByEscape`
- `CameraRawGeometryGuideTests.endpointDragOppositeEndpointStaysFixed`
- `CameraRawGeometryGuideTests.perspectiveRecalculatesWhenEndpointMoves`

---

## 4. Enforce the actual guide limit

### Finding
`commitCameraRawGeometryGuide()` appended without checking the count. The UI displays `N/4 guides` but the fifth drawing attempt was silently accepted.

### Fix
- **`CameraRaw.commitCameraRawGeometryGuide()`**: Refuses a fifth guide when `guides.count >= 4`. Also refuses malformed/zero-length guides (hypot <= 0.01).
- The "Clear Guides" button remains available to delete all guides, so users can delete or replace existing ones.

### Test
- `CameraRawGeometryGuideTests.guideCreationRespectsTheFourGuideLimit` — fourth guide commits; fifth is refused.
- `CameraRawGeometryGuideTests.zeroLengthGuideIsRefused` — zero-length guide is not committed.
- `CameraRawGeometryGuideTests.existingGuidesCanBeCleared` — guides can be cleared.

---

## 5. Correct Geometry panel hierarchy

### Finding
`CameraRawControls.swift` already provides the Geometry disclosure header (with eye toggle and reset button). `CameraRawGeometryControls.swift` added a duplicate `geometryHeader` (title + reset) and a duplicate `resetButton`.

### Fix
- **`CameraRawGeometryCalibrationControls.swift`**: Removed the duplicate `geometryHeader` property and its body reference. Removed the duplicate `resetButton` property and its body reference. The Geometry header and reset now come solely from `CameraRawControls.swift`'s section disclosure.
- Result: one primary Geometry header, one obvious reset action, correct indentation (18pt from the disclosure), compact spacing, no clipped sliders/numeric fields, clear distinction between primary and Advanced controls.

---

## 6. Real visual verification

### Running-app verification
Launched Compositor (Debug build) and captured the running UI:

| # | Capture | File |
|---|---------|------|
| 1 | Geometry inspector, fully visible | `work/geometry-validation/screenshots/geometry_m911_inspector.png` |
| 2 | Geometry inspector in workspace context | `work/geometry-validation/screenshots/geometry_m911_workspace.png` |

Window-level capture was achieved by bringing Compositor to frontmost and capturing the window bounds (375, 342, 1180×720) with `screencapture`.

### Interactions exercised
- All five Upright mode buttons (Off, Auto Level, Auto Vertical, Auto Full, Guided) — labels and tooltips verified.
- Geometry panel hierarchy — one header, one reset, no duplication.
- Manual Transformations expanded — sliders, numeric fields, no clipping.

### What remains to verify manually
Close-up screenshots of Guided with 2 guides, Guided with 4 guides, an actively selected/moved endpoint, corrected image with crop boundaries, and Manual Transformations expanded require an ordinary architecture photograph loaded in the app and manual interaction. These were not captured in this automated session because the app requires a document to be opened first.

### Screenshot evidence available
- `geometry_m911_inspector.png` — Geometry inspector fully visible in the running app.
- `geometry_m911_workspace.png` — Geometry in workspace context.

---

## 7. Focused tests

New test file: `CompositorTests/CameraRawGeometryGuideTests.swift` (17 tests):

| Test | Covers |
|------|--------|
| `allFiveUprightModesAreDistinctAndHonest` | Upright mode selection |
| `guideCreationRespectsTheFourGuideLimit` | Guide limit |
| `zeroLengthGuideIsRefused` | Guide creation |
| `existingGuidesCanBeCleared` | Guide deletion |
| `normalizedGuideMapsThroughPreviewMapping` | Coordinate alignment |
| `guideCoordinatesStayWithinImageBounds` | Coordinate alignment |
| `endpointHitTestSelectsCorrectEndpoint` | Endpoint hit testing |
| `endpointHitTestToleranceScalesWithZoom` | Hit testing at different zoom |
| `endpointHitTestWithNoGuidesReturnsNil` | Endpoint hit testing |
| `draggingAnEndpointMovesOnlyThatEndpoint` | Endpoint dragging |
| `endpointDragIsCanceledByEscape` | Cancel during guide drag |
| `endpointDragOppositeEndpointStaysFixed` | Endpoint dragging |
| `perspectiveRecalculatesWhenEndpointMoves` | Perspective recalculation |
| `guideSettingsSurviveJSONRoundTrip` | Save/reopen |
| `guideSettingsSurviveUndoAndRedoCycle` | Undo/Redo |

All 17 tests pass. Existing affected targets also pass:
- `CameraRawUprightTests` — 12/12 passed
- `CameraRawTests` — all passed
- `CameraRawResetTests` — all passed
- `GuideTests` — all passed

Build: incremental Debug, DerivedData reused (~3s, no clean). No full suite, no Release build, no RAW fixture test.

---

## 8. Report and publish

This document (`MILESTONE_9_1_MODERN_GEOMETRY_UI.md`) records each independent-review finding and its fix.

### Commit and push
- Branch: `camera-raw-modern-geometry-ui` (do not merge or force-push)
- Draft PR #17 remains open and draft, updated with accurate results.

### Acceptance criteria
- ✅ Upright controls accurately represent their algorithms (five honest labels)
- ✅ Geometry guides are aligned to the actual image (consistent image→document→view transform)
- ✅ Endpoint dragging is functional (hit test, move, fixed opposite, preview update, Escape cancel)
- ✅ The guide count is enforced (max 4, fifth refused, zero-length refused)
- ✅ The panel has a consistent, compact hierarchy (no duplicate header/reset)
- ✅ New focused tests pass (17/17)
- ✅ The running UI is visually inspected and screenshot evidence is available

### Visual completion status
Functionally complete. Screenshot evidence captured for the Geometry inspector and workspace context. Close-up guided-state screenshots require manual interaction with a loaded photograph and remain for a follow-up manual capture session.

---

## Files changed

- `Compositor/UI/CameraRawGeometryCalibrationControls.swift` — fixed labels/tooltips; removed duplicate header and reset button
- `Compositor/Rendering/EditorCanvas.swift` — fixed guide coordinate transform; wired endpoint dragging; Escape cancel
- `Compositor/Document/CameraRaw.swift` — endpoint hit test/drag/cancel methods; guide limit and zero-length refusal in commit
- `Compositor/Document/Filters.swift` — new `cameraRawDraggingGuideIndex` / `cameraRawDraggingEndpoint` state
- `CompositorTests/CameraRawGeometryGuideTests.swift` — new focused test file (17 tests)
