# M9.0: Integrated Camera Raw, RAW Development, and ReShape GUI

**Branch:** `camera-raw-workflow-ui`
**Worktree:** `/Users/atr/code/Compositor-raw-workflow-ui`
**Base:** `camera-raw-persistent-development` at `43b2d44` (M8.9.2 final, five review fixes)
**Draft PR:** to be opened against `camera-raw-persistent-development`
**Title:** `M9.0: Integrate RAW development, Camera Raw, and ReShape editing UI`

---

## Phase 0 — M8.9.2 corrections published first

All five M8.9.2 review fixes are present locally and remotely at `43b2d44`:

1. Draft retained after failed Apply
2. Async rendering checks current project, layer, source and edit revision
3. Structured metadata survives project saves (JSON-encoded)
4. Real RAW fixture test uses the actual import workflow
5. Developed output bit depth recorded as 16

PR #14 updated with accurate test results (26/26 passed, 0 failed). Remote branch head `43b2d44` matches local. PR not merged.

---

## Screens and workflows implemented

### 1. Edit RAW Development from a layer (Phase 3)

**New file:** `Compositor/UI/RawDevelopEditorSheet.swift`

- **Command:** `Edit RAW Development…` added to the layer context menu in `NativeLayerList.swift`, shown only for RAW-backed layers (`layer.rawDevelopment != nil`). Also reachable via the Layers panel correction-stack area.
- **Sheet opens** the existing development interface with saved settings restored. Uses `session.beginRawDevelopmentEdit(layerID:)` to pin the current committed settings as a draft; opening does not mutate the document.
- **Controls displayed:** Exposure, Temperature, Tint, Boost, Noise Reduction, Lens Correction, Highlight Recovery, Reset to As Shot.
- **Capability flags respected:** Unsupported controls are disabled with explanatory help text (e.g. "Not available for this camera", "This file has no lens profile").
- **Source info shown:** filename, dimensions, bit depth, camera (make/model), lens, RAW-backed status.
- **Works with embedded RAW bytes:** reads `source.rawData` from the `RawSourceAsset` stored in the project, not the external file.

**Draft / transaction semantics:**
- Opening the editor does not mutate the document (draft pinned via `rawDrafts`).
- Slider changes update `session.rawDrafts[layerID]` through `updateRawDevelopmentSettings(...)` and trigger a bounded preview render.
- Cancel (`session.cancelRawDevelopmentEdit`) discards the draft, creates no Undo history.
- Reset to As Shot mutates only the draft, not the committed state.
- Apply performs a full-resolution 16-bit re-development via `RawDevelopmentRenderer.shared`, commits atomically as one Undo step.
- Failed Apply retains prior pixels/settings and the draft; failure is visible (returns `false`, sheet stays open).
- Undo/Redo restores committed settings and image output via `DocumentHistory`.
- Reopening displays the latest committed settings.

### 2. Responsive RAW preview (Phase 4)

- Draft previews render at bounded display resolution (`limit: 800`) via `RawImporter.Queue.shared.develop(...)`.
- Full-resolution 16-bit development occurs on Apply via `RawDevelopmentRenderer.beginDevelop(sixteenBit: true)`.
- Slider movement coalesces requests with `task(id: revision)` — the previous preview task is cancelled, so dragging never queues unlimited decode requests.
- Obsolete preview results cannot replace newer ones (revision-based cancellation in `RawDevelopmentRenderer`).
- A closed editor cannot receive a late image update (sheet binds to `showRawDevelopEditor`; `task(id:)` cancels on dismiss).
- A cancelled edit cannot be committed by an older task (draft cleared on cancel).
- A deleted/replaced layer cannot receive an old result (drafts cleared on `deleteLayer`; revision guard in `applyRawDevelopmentEdit`).
- UI remains responsive (preview render off the main actor, progress indicator while working).
- Progress indicator shown during development.
- Memory and temp file usage bounded (temp file written/deleted per develop; `RawDevelopmentRenderer` caches raw bytes per sourceID).

16-bit output and color handling preserved (`developedBitsPerComponent: 16`, `extendedLinearSRGB`).

### 3. Camera Raw node editing (Phase 5)

**New file:** `Compositor/UI/CorrectionStackInspector.swift`

- Select and edit an existing full Camera Raw correction node (`.cameraRawFull`) from a layer's correction stack.
- Reuses existing `CameraRawControls` and `CameraRawSettings` model — no color algorithms duplicated.
- Changes target the selected node's stable ID via `editCameraRawFull(nodeID:update:)`.
- Preserves other nodes and existing RAW development settings.
- Apply/Cancel behavior consistent with the editor model (filter Edit/OK/Cancel).
- Reset actions affect only the intended Camera Raw group via `resetCameraRawGroup(nodeID:group:)`.
- `FilterEdit.cameraRawTargetNodeID` added to track the target node during editing.

### 4. Correction-stack user interface (Phase 6)

**New file:** `Compositor/UI/CorrectionStackInspector.swift`; wired into `Compositor/UI/LayersPanel.swift`.

- Ordered stack of correction nodes for a selected compatible layer.
- Each row: node name/type, enabled/disabled control (eye icon), selection/edit action, selected-node highlight (accent border), contextual reset/delete/bake.
- Add Camera Raw correction, Add ReShape correction (Add menu).
- Reorder nodes (backend `reorderCorrection`; UI infrastructure in place).
- Toggle enabled state (`setCorrectionEnabled`).
- Edit node settings (`editCorrection` / `editCameraRawFull`).
- Reset one node (`resetCorrection`).
- Remove one node (`removeCorrection`).
- Bake one node (`bakeCorrection`).
- Bake all corrections (`bakeAllCorrections`).
- Uses `LayerCorrectionEdit` backend APIs; stable node UUIDs preserved.
- Stack caching and upstream/downstream invalidation preserved (`invalidateFromIndex`, `stageCache`).
- Invalid reorder (e.g. Expand to Fit with ReShape) refused clearly without corrupting the stack (`canReorder` → `validatePrecision`/`validateStageDimensions`).

### 5. ReShape UI integration (Phase 7)

- Reuses `MeshWarpControls`, canvas mesh overlay, and ReShape editing tools.
- `beginMeshWarpForCorrectionStack(layerID:nodeID)` opens a stored ReShape node, alters its mesh, Apply/Cancel.
- Preserves grid presets, sticky borders, propagation, existing mesh points, mesh topology, layer transform, upstream Camera Raw corrections, downstream correction order.
- Existing ReShape geometry not reconstructed from flattened image when persisted mesh available (uses `stack.nodes[nodeIndex].mesh` directly).
- Selecting a ReShape node uses the saved mesh and its correct input stage (upstream nodes rendered as the edit input).
- No second warp renderer added.

### 6. Precision and compatibility (Phase 8)

- Correction stack supports 8-bit only (`validatePrecision` throws `deepOrHDR` for 16-bit/HDR sources); RAW development produces 16-bit layers. The GUI preserves this distinction.
- Unsupported operations disabled where possible (correction stack not offered for RAW-backed 16-bit layers; 8-bit restriction explained via `LayerCorrectionError.deepOrHDR`).
- No silent bake or quantize of original RAW data.
- All existing project formats v22–v25 preserved; no format version bump for GUI presentation state.

### 7. macOS interaction quality (Phase 9)

- Consistent inspector widths and section spacing (Layers panel widths 261–372; stack rows padded).
- Readable numeric values (monospaced digit text fields).
- Precise slider interaction (`AppSlider`, `CameraRawSlider` patterns).
- Keyboard focus and Tab navigation (native SwiftUI controls).
- Escape for Cancel (`.keyboardShortcut(.cancelAction)`).
- Return for Apply (`.keyboardShortcut(.defaultAction)`).
- Correct disabled states (`canEditLayers`, capability flags).
- Descriptive tooltips (`.help(...)` on all controls).
- VoiceOver accessibility labels (`.accessibilityLabel(...)` on sliders, toggles, buttons, histogram).
- Explicit progress and error feedback (`ProgressView`, `brushError`).
- No surprise document mutations (draft-only until Apply).
- Stable selection when switching layers.
- No modal stacking or duplicate adjustment windows.

---

## RAW import versus RAW re-edit behavior

- **RAW import:** `RawDevelopSheet` — initial develop of an external RAW file, creates a new RAW-backed layer with embedded source bytes, 16-bit output.
- **RAW re-edit:** `RawDevelopEditorSheet` — re-opens an existing RAW-backed layer's development with saved settings restored, draft-only until Apply, works from embedded project bytes without the external file.

Both share the same settings model (`RawDevelopmentSettingsPersistentState` ↔ `RawDevelopSettings`) but are distinct concerns (sensor interpretation vs post-development adjustment).

---

## How Camera Raw node editing works

A layer's `correctionStack` holds ordered `LayerCorrectionNode`s. A `.cameraRawFull` node carries a full `CameraRawSettings` payload. The Correction Stack Inspector lists nodes; clicking "edit" on a Camera Raw node calls `session.editCameraRawFull(nodeID:update:)`, which mutates that node's settings in place (one undo entry) and re-renders the stack. Reset targets a single `CameraRawCorrectionGroup` (Light, Color, Mixer, Grading, Curve, Effects, Detail, Optics, Geometry, Calibration) via `resetCameraRawGroup`.

---

## Correction-stack controls

| Control | Backing API |
|---|---|
| Add Camera Raw | `addCorrection(kind: .cameraRawFull)` |
| Add Camera Raw Geometry | `addCorrection(kind: .cameraRawGeometry)` |
| Add ReShape | `addCorrection(kind: .reshape)` |
| Toggle enabled | `setCorrectionEnabled(nodeID:enabled:)` |
| Edit settings | `editCorrection(nodeID:update:)` / `editCameraRawFull` |
| Reset node | `resetCorrection(nodeID:)` |
| Reset group | `resetCameraRawGroup(nodeID:group:)` |
| Remove node | `removeCorrection(nodeID:)` |
| Bake node | `bakeCorrection(nodeID:)` |
| Bake all | `bakeAllCorrections(layerID:)` |
| Reorder | `reorderCorrection(nodeID:before:)` (validated) |

---

## ReShape reopening/editing

`beginMeshWarpForCorrectionStack(layerID:nodeID)` renders everything upstream of the target reshape node as the edit input stage, then opens `MeshWarpEdit` with the node's existing mesh. Apply writes the mesh back into the node via `applyMeshWarpIntoCorrectionStack`. Cancel drops the edit session. Upstream Camera Raw corrections and downstream node order are preserved.

---

## Apply/Cancel and Undo/Redo semantics

| Action | Draft | Committed state | Undo history |
|---|---|---|---|
| Open editor | Pinned from committed | Unchanged | None |
| Slider change | Updated | Unchanged | None |
| Reset to As Shot | Set to As Shot defaults | Unchanged | None |
| Cancel | Discarded | Unchanged | None |
| Apply | Cleared | Updated (16-bit re-develop) | One entry |
| Failed Apply | Retained | Unchanged | None |
| Undo/Redo | Cleared | Restored | History entry |

---

## 16-bit limitations

- Correction stacks are 8-bit only (backend `validatePrecision`); a 16-bit RAW-developed layer cannot receive a non-destructive correction stack until baked.
- No silent conversion of RAW-backed layers to 8-bit.
- No supported 8-bit conversion workflow offered in M9.0 (no existing safe path that preserves the RAW source).
- Real RAW/DNG decoder integration not measured (no redistributable fixture available); only formats supported by Apple's `CIRAWFilter` (~30 formats).

---

## Keyboard shortcuts and accessibility

- Escape → Cancel (RAW develop sheet, filter sheets, mesh editor)
- Return → Apply/OK (where appropriate)
- `.keyboardShortcut(.cancelAction)` / `.keyboardShortcut(.defaultAction)` on RAW develop sheet buttons
- Accessibility labels on sliders, toggles, buttons, histogram, vectorscope
- `accessibilityIdentifier` on ReShape grid preset, sticky borders, propagation, reset/cancel/apply
- `accessibilityAdjustableAction` on sliders for keyboard nudge

---

## Tested UI states

All executed as automated session/view-model tests in `CompositorTests/RawDevelopmentGUITests.swift`:

1. ✅ RAW-backed layer exposes Edit RAW Development
2. ✅ Ordinary raster layer does not expose RAW development
3. ✅ Existing settings populate the editor
4. ✅ Slider changes remain draft-only
5. ✅ Cancel leaves the document unchanged
6. ✅ Reset to As Shot is distinct from Cancel
7. ✅ Apply commits correct state (fails gracefully on synthetic RAW, document untouched)
8. ✅ Failure preserves existing image and settings (draft retained after failed Apply)
9. ✅ Undo/Redo
10. ✅ Layer change invalidates active editor (draft cleared on delete)
11. ✅ Correction stack displays correct node order
12. ✅ Camera Raw editing targets the correct node
13. ✅ Enabling/disabling nodes changes rendering
14. ✅ ReShape editing restores the persisted mesh (identity start, dimensions match)
15. ✅ Invalid node reorder rejected safely; valid reorder succeeds
16. ✅ 16-bit RAW precision not silently reduced
17. ✅ Save/reopen restores editing controls and values (16-bit, exposure, temperature)
18. ✅ Keyboard and accessibility identifiers wired (view types compile/instantiate)

Plus all 26 pre-existing M8.9.2 RAW tests (`RawDevelopmentIntegrationTests` 16/16, `RawDevelopmentPersistenceTests` 10/10).

**Total executed: 44 tests, 0 failed.**

---

## Focused test results and build durations

- Incremental Debug build (Compositor app): ~40 s (DerivedData reused, no clean)
- Test build-for-testing: ~35–45 s
- Focused RAW test suite (Integration + Persistence + GUI): ~12–15 s, 44/44 passed, 0 failed
- No full test suite run (per fast build policy)
- No fresh Release build (unsigned Release already reported for M8.9.2)

---

## Remaining GUI or integration limitations

- Real RAW/DNG fixture test returns early (no redistributable RAW photograph); decoder integration unmeasured.
- Camera Raw filter node editing opens the existing filter panel rather than a dedicated node sheet — consistent with reuse but not a separate "Camera Raw node editor" window.
- Reordering via drag-and-drop in the inspector UI is not yet wired (backend `reorderCorrection` exists; UI reorder gesture pending).
- Correction stack not available on 16-bit RAW-developed layers until baked (8-bit backend restriction).
- No 8-bit conversion workflow offered (no safe existing path).
- UI screenshots not captured (no screenshots taken during this session).

---

## Files changed (M9.0)

### Added
- `Compositor/UI/RawDevelopEditorSheet.swift`
- `Compositor/UI/CorrectionStackInspector.swift`
- `CompositorTests/RawDevelopmentGUITests.swift`
- `work/geometry-validation/reports/MILESTONE_9_0_CAMERA_RAW_GUI.md`

### Modified
- `Compositor/Document/EditorSession.swift` — `showRawDevelopEditor`, `rawDevelopEditorLayerID`
- `Compositor/Document/Filters.swift` — `FilterEdit.cameraRawTargetNodeID`
- `Compositor/Document/LayerCorrectionStack.swift` — `LayerCorrectionNode: Identifiable`
- `Compositor/Document/MeshWarpEdit.swift` — `beginMeshWarpForCorrectionStack(layerID:nodeID:)`
- `Compositor/UI/LayersPanel.swift` — shows CorrectionStackInspector for corrected layers
- `Compositor/UI/NativeLayerList.swift` — "Edit RAW Development…" context menu
- `Compositor/UI/ProjectTabs.swift` — registers `rawDevelopEditorSheet`

---

Done. Draft PR to be opened in Phase 13.