# M10.7 — Advanced ReShape interaction

*Camera Raw 18.7 baseline: see `REFERENCE_BASELINE_ADOBE_CAMERA_RAW_18_7.md`; its §7 acceptance gate applies to this milestone.*

## 1. What this milestone did

Compositor's ReShape tool already contained a full adaptive mesh engine — selection, transforms,
subdivision/merging, local perspective/horizon/volume corrections and tool-local undo — reached only
through session APIs and tests. M10.7 exposed those capabilities through the existing ReShape tool
header, without moving anything, replacing anything, or building a second geometry solver.

The engine itself is unchanged. Every new control calls an existing backend entry point:

| UI control | Backend it calls |
| --- | --- |
| Transform picker (Move / Rotate / Scale) | `MeshWarpEdit.transformSelection` (existing), via `meshWarpSetTransformMode`, `meshWarpRotateSelection`, `meshWarpScaleSelection` |
| Subdivide / Merge buttons | `MeshWarpTopology.subdivide(faceIDs:)` / `merge(faceIDs:)` through `subdivideSelection()` / `mergeSelection()` (existing) |
| Local Corrections › Local Perspective | `applyLocalCorrection(.perspective(MeshWarpLocalPerspective…))` (existing) |
| Local Corrections › Local Horizon | `applyLocalCorrection(.horizon(MeshWarpLocalHorizon…))` (existing) |
| Local Corrections › Local Volume | `applyLocalCorrection(.volume(MeshWarpLocalVolume…))` (existing) |
| Selection (click, Shift-click, marquee, Select All, Clear) | `MeshWarpSelection` and its existing mutating methods |
| ⌘Z / ⇧⌘Z while ReShape is open | `meshWarpToolUndo()` / `meshWarpToolRedo()` over the existing `MeshWarpHistory` |

## 2. Backend-versus-UI coverage, before and after

| Capability | Before M10.7 | After M10.7 |
| --- | --- | --- |
| Single vertex select + drag | UI (existing) | unchanged |
| Shift-click additive selection | session API only | UI: Shift-click on the canvas |
| Deselect one vertex | session API only | UI: Shift-click toggles it off |
| Marquee selection | session API only | UI: drag on empty canvas; Shift extends |
| Select All / Clear Selection | session API only | UI: menu `Select › All` (⌘A) / `Select › Deselect` (⌘D) route to the mesh while ReShape is open; Clear Selection button in the header |
| Selected vertex count | session API only | UI: count text in the header (`reshapeSelectionCount`) |
| Move / Rotate / Scale of selection | session API only | UI: segmented Transform picker in the header |
| Subdivide / Merge | session API only | UI: buttons in the header |
| Local Perspective (Four Point, Vertical, Horizontal, Combined) | session API only; Four Point needed a drawn quad | UI: Local Corrections menu; Four Point arms a destination-quad drag with Apply |
| Local Horizon (Angle, Horizontal/Vertical Reference) | session API only; reference modes needed a drawn line | UI: Local Corrections menu; reference modes arm a reference-line drag |
| Local Volume (Horizontal, Vertical, Radial, Combined) | session API only | UI: Local Corrections menu |
| Tool-local Undo/Redo | session API only | UI: ⌘Z / ⇧⌘Z while ReShape is open (§6) |
| Grid presets, Sticky Borders, Propagation, Reset, Cancel, Apply, overlay, GPU preview, persistence | UI (existing) | unchanged, same place |

Nothing that was reachable before became unreachable, and no control moved.

## 3. Controls added, and where

All new controls sit in the existing ReShape tool header (`MeshWarpControls`), appended after the
Propagation slider and before the Reset / Cancel / Apply buttons that have always closed the bar:

```
ReShape   [Grid preset] [Sticky Borders] [Propagation ——] | Transform [Move|Rotate|Scale]  Subdivide  Merge  Local Corrections ▾  Clear Selection  "N selected" | Reset Mesh  Cancel  Apply
```

- The block is hidden entirely when no mesh is open, so the header reads exactly as before.
- Local Corrections is a three-submenu menu: Local Perspective, Local Horizon, Local Volume.
- Four Point perspective and the two Horizon reference modes are the drawn-draft interactions; the
  remaining items apply to the current selection immediately at the shared Amount (0.5) / Strength
  (0.15) defaults. They are one-shot menu commands, not panels — the milestone scope was exposure,
  and a compact disclosure was the requested shape.
- Warnings (`lastWarning`) still surface in the same orange slot as before, which is where
  topology and fold refusals read.

## 4. Interaction ownership

`EditorCanvas` owns the pointer, as it always has. The additions follow the existing dispatch shape:

- `mouseDown` — vertex hit first (drag or, with Shift, additive toggle); otherwise an armed
  quad-destination drag, an armed horizon-reference drag, or a marquee drag.
- `mouseDragged` — continues whichever of those began.
- `mouseUp` — finishes the marquee (commit selection), the quad (arm Apply), the reference line
  (apply the Horizon correction), or the vertex drag (one history entry).
- `keyDown` — ⌘Z / ⇧⌘Z route to the mesh history while ReShape is open; ⌘⌥Z / ⌘⇧⌥Z still reach the
  document history; Escape cancels an in-progress gesture first and the session on a second press;
  Return applies, exactly as before.

Selection hit-testing uses the same document-space hit radius the drag path always used, so it is
stable across zoom levels and Retina backing scales by construction (it never works in screen
pixels). Pan/zoom and the other tool shortcuts are untouched.

## 5. Selection, transforms, topology safety

- The transform pivot is the selection's barycenter, as `MeshWarpEdit.transformSelection` already
  defined. Rotates and scales compute from the gesture's initial snapshot (`gestureBasePositions`),
  not from the accumulated mesh — ten fractional drags land exactly where one full drag does
  (`rotatingInTenStepsMatchesOneFullRotationFromTheBase`), so there is no cumulative drift.
- Propagation and sticky borders stay active through every gesture; corners remain pinned.
- A transform that would fold a leaf triangle is refused: the mesh validates the candidate mapping
  and the session reports the refusal through `lastWarning`; no history entry is created.
- Non-finite gesture coordinates are refused (`ignoresNonFiniteTransformInput`).
- Subdivide splits only the faces touching the selection (net leaf growth verified: 4 faces → 16);
  Merge accepts only complete groups of four subdivided children and reports its reason otherwise.
  Topology limits are the existing ones, unweakened.
- Escape during any gesture restores the pre-gesture positions and drops the draft; the session
  itself survives for a second Escape.

## 6. Tool-local Undo/Redo

`MeshWarpHistory` was already implemented; M10.7 wired it to the keyboard. While a mesh session is
open, ⌘Z / ⇧⌘Z call `meshWarpToolUndo()` / `meshWarpToolRedo()` and never touch document history;
⌘⌥Z / ⌘⇧⌥Z remain the document's. Undo/redo entries carry the selection and the topology state, so
undoing a subdivide restores the coarser mesh and the selection with it
(`undoRestoresSelectionAndTopology`, `redoRestoresTheSameState`). A completed gesture is one entry;
a refused gesture creates none. Apply creates the existing single document history entry; Cancel
drops the session without touching the document.

## 7. Rendering and persistence

- The GPU session (`MetalMeshWarpSession`) is unchanged from M9.1.5: the source texture uploads once
  per session, never per drag frame; the mesh buffer updates and the preview renders resident.
- CPU/GPU parity holds for the regular mesh, the adaptive mesh, transformed selections and all
  three local correction families (`previewMatchesCommittedRender*` family).
- Save/reload round-trips the adaptive topology, the selection-independent mesh state and the
  correction position; a reopened mesh can be re-edited without its pixels changing until a new
  gesture completes (`reopenedMeshEditsWithoutAlteringPixelsUntilChanged`).
- 8-bit / 16-bit / HDR precision rules are the existing ones, unchanged; no high-precision layer is
  silently baked.

## 8. Tests

| Suite | Coverage added |
| --- | --- |
| `MeshWarpAdvancedTests` | Marquee select/drag, Shift-click toggle, Select All + Move, rotate/scale without drift, fold refusal, non-finite refusal, escape gesture cancellation, undo/redo of selection and topology, subdivide/merge session routing with reasons, local corrections applied to the selection only, horizon reference drag, four-point destination quad |
| `MeshWarpEvidenceTests` | Real renders of move / rotate / scale / subdivide / merge / local perspective / horizon / volume on `stone-house.jpg` |
| `MeshWarpTests`, `MeshWarpTopologyTests`, `MeshWarpLocalGeometryTests`, `MeshWarpPersistenceTests` | Extended where the new exposure touched their seams |

Focused mesh suites: **99 tests, pass** (run before the UI work, then re-run in the full regression).

## 9. Real application evidence

Rendered through the real pipeline into `work/camera-raw-parity/screenshots/m10_7-rendered/`
(`stone-house.jpg` source plus move / rotate / scale / subdivided / merged / local perspective /
local horizon / local volume, with `reshape-evidence.csv` — max channel deltas 231–255 for the
corrections, exactly 0 for the identity subdivide/merge checks).

Real UI automation (XCUITest, `ScreenshotTests` steps 21–22, capture set
`work/camera-raw-parity/screenshots/m10_7-ui/`, 22 captures):

- `21 ReShape header` — the tool header with the appended Transform picker, Subdivide, Merge,
  Local Corrections menu, Clear Selection and count, alongside the untouched original controls,
  with the mesh overlay drawn on the picture.
- `22 ReShape Local Corrections menu` — the menu open, showing Local Perspective, Local Horizon
  and Local Volume with their items.

**UI-automation blocker, honestly stated:** XCUITest still cannot deliver a canvas mouse gesture to
this layer-backed canvas (the same §5.3 finding as M10.5), so no screenshot shows a vertex drag,
a marquee being drawn, or a correction handle mid-drag. Those behaviours are proven at the model
level by `MeshWarpAdvancedTests` and through the real rendering pipeline by the evidence images.
The Controls screenshots above come from real automation runs (the `Screenshots` scheme, which
required enabling macOS Automation Mode on this machine — `automationmodetool
enable-automationmode-without-authentication`, authenticated once at the machine).

### Manual acceptance checklist (for a person at the machine, a picture open, ReShape selected)

1. Is the header bar unchanged on the left (Grid, Sticky Borders, Propagation) with the new
   Transform picker / Subdivide / Merge / Local Corrections / Clear Selection / count between
   Propagation and Reset Mesh?
2. Click a mesh point — does it drag as always? Shift-click a second point — does the count read
   "2 selected"? Shift-click it again — back to 1?
3. Drag on empty canvas — does a marquee select the points inside it? ⌘A select all? ⌘D clear?
4. With 3+ points selected and Transform = Rotate, drag — do they turn about their common center?
   Transform = Scale — do they shrink/grow from it?
5. Rotate hard until points would cross — does the drag refuse and the orange warning appear?
6. Select a few cells, press Subdivide — does only that region get finer? Press Merge — does it
   fold back? Try Merge on an unsubdivided region — does a reason appear in the warning slot?
7. Local Corrections › Local Perspective › Vertical — does only the selected region straighten?
   Local Horizon › Draw Horizontal Reference…, drag a line — does the region level?
   Local Volume › Radial — does the region swell?
8. ⌘Z after each of the above — does each step back out, selection and mesh included? ⇧⌘Z forward?
9. Escape mid-drag — does the gesture vanish and the mesh return? Escape again — does the tool exit
   with the picture unchanged? Apply — does the picture commit as one history step?

## 10. Existing open GUI acceptance gates

- **M9.1.6 Guided Upright** manual acceptance: still pending, unchanged. Nothing in this milestone
  touched it; not claimed as passed.
- **M10.5 Advanced Perspective canvas drag**: still pending. The Automation Mode unblock achieved
  here is a prerequisite for ever capturing it, but the drag itself was not re-attempted this
  milestone; not claimed as passed.

## 11. Regression

Full ordinary regression through `scripts/regression.sh` (plan `CompositorRegression`, heavy tests
excluded by the plan; no 6000×4000 benchmark run): bundle
`work/camera-raw-parity/regression-m10_7.xcresult` — counts recorded in §12 of
`FEATURE_PARITY_PLAN.md` below.

## 12. Deliberate non-goals

- No second geometry solver; no Camera Raw Geometry changes at all.
- No new mesh renderer; the existing overlay and GPU session are untouched.
- No Miniature / tilt-shift UI, no crop/expand redesign, no new workspace, no AI Denoise /
  Super Resolution — later milestones.
- No per-correction amount sliders for the one-shot Local Corrections items: they run at shared
  defaults today; adjustable amounts belong to the follow-up that also adds drawn-handle editing.
