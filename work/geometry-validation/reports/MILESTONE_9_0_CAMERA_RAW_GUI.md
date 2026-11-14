# M9.0.2: Diagnose Real RAW Failure and Eliminate Excessive Test Runtime

**Branch:** `camera-raw-workflow-ui`
**Worktree:** `/Users/atr/code/Compositor-raw-workflow-ui`
**Base:** `camera-raw-workflow-ui` at `camera-raw-workflow-ui` head
**Draft PR:** https://github.com/andrewtryder/Compositor/pull/16
**Title:** `M9.0.2: Diagnose Real RAW Failure and Eliminate Excessive Test Runtime`

---

## 1. Exact original failure (from `.xcresult`)

**Failing bundle:** `Test-Compositor-2026.11.13_17-15-37--0500.xcresult`
**Test:** `RawDevelopmentIntegrationTests/realRawFixtureEndToEnd()`
**Result:** Failed
**Failure message:** `Expectation failed: applied: Apply succeeds through RawDevelopmentRenderer`
**Wall-clock duration:** ~16 minutes (980.4 s)

**Stack trace:** None captured — the bundle's activity tree was empty (no activity timing recorded).

**Root cause (confirmed test logic defect):**

The original `realRawFixtureEndToEnd()`:
1. Began a RAW edit.
2. Changed exposure.
3. Saved without applying.
4. Opened a new session.
5. Called `Apply` without beginning a new edit.

This contradicts Compositor's intentional non-persistent draft behavior:
- `applyRawDevelopmentEdit(layerID:)` requires an active entry in `rawDrafts` (`EditorSession.swift:895`).
- `installProject()` clears `rawDrafts.removeAll()` (`EditorSession+Projects.swift:140`).
- Draft settings are intentionally NOT serialized across save/reopen (only committed state persists).

So after reopening, `rawDrafts[layerID]` was `nil`, `applyRawDevelopmentEdit` returned `false`, and the test failed.

The test also contained an incorrect comment claiming "draft settings survive serialization", which is false by design.

---

## 2. Test corrections (`CompositorTests/RawDevelopmentIntegrationTests.swift`)

The corrected sequence honors non-persistent draft behavior:

1. Import and develop the real RAW (as-shot).
2. Save the project with its initial committed settings (no draft).
3. Reopen in a fresh session.
4. Assert that no uncommitted draft was persisted (`rawDrafts` empty; settings are As Shot).
5. Call `beginRawDevelopmentEdit(layerID:)` on the reopened document.
6. Set exposure to +1.5 through `updateRawDevelopmentSettings()`.
7. Apply and verify development succeeded.
8. Confirm pixels changed and metadata is correct.
9. Test Undo/Redo and source-byte integrity.

The incorrect comment claiming draft settings survive serialization was removed. Production persistence was NOT modified to save uncommitted drafts.

---

## 3. Diagnostics and instrumentation added

Added scoped diagnostic timings (elapsed time + memory footprint) for each expensive stage:

- Opening the RAW decoder and reading As Shot settings.
- Initial full-resolution RAW develop (import).
- Converting the developed image into a DeepLayer asset.
- Creating the project snapshot.
- Saving the project package.
- Loading the package.
- Installing the reopened project.
- Second full-resolution RAW develop (Apply).
- Pixel comparison.
- Undo/Redo.

Each stage logs start, completion, duration, output dimensions, component depth, and memory delta. Example log format:
`[TIMING] Import + initial RAW develop: 1.234s, memory delta: 45 MB  5632x3756, 84 MB bytes`

Added a fast smoke test `realRawFixtureSmokePreview()` that validates Apple's decoder can open the real DNG and produce a bounded 800px preview, without full-resolution development. This runs with ordinary focused RAW test runs.

Added `computeChecksum()` (FNV-1a) for bounded pixel-change assertions.

---

## 4. Real fixture details

- **File:** `Tests/TestFixtures/Ricoh-GR-III.DNG`
- **MD5:** `a67d21155d31649d7dfbc8cf4118a77d`
- **Size:** 31.8 MB
- **Environment gate:** `COMPOSITOR_RAW_FIXTURE_PATH` (must be set; test skips cleanly when absent)

The decoder successfully opened the file and produced a bounded preview and full-resolution development.

---

## 5. Executed test counts

All 17 `RawDevelopmentIntegrationTests` passed, 0 failed:

| Test | Result |
|------|--------|
| `realRawFixtureSmokePreview()` | ✅ passed |
| `realRawFixtureEndToEnd()` | ✅ passed |
| `legacyVersionsLoadWithoutRAWFields()` | ✅ passed |
| `whiteBalanceChangeIsTracked()` | ✅ passed |
| `bakeRawDevelopmentDiscardsEditableOwnership()` | ✅ passed |
| `missingRAWRawDataIsRejected()` | ✅ passed |
| `cancelRawDevelopmentEditDoesNotMutatePersistedState()` | ✅ passed |
| `corruptRAWRawDataDoesNotPartiallyMutateDocument()` | ✅ passed |
| `bakeIsUndoable()` | ✅ passed |
| `duplicateLayerRetainsSourceOwnership()` | ✅ passed |
| `rawSourceBytesSurviveRoundTripThroughSnapshot()` | ✅ passed |
| `exposureChangeDevelopsFromOriginalNotRendered()` | ✅ passed |
| `rawAndCorrectionStackAreDistinct()` | ✅ passed |
| `rawReloadWorksWithoutExternalFile()` | ✅ passed |
| `rawSourceSurvivesProjectSaveAndReopen()` | ✅ passed |
| `duplicateLayersShareRawSourceAfterReopen()` | ✅ passed |
| `rawSettingsEditIsUndoableAndRedoable()` | ✅ passed |

**Total: 17/17 passed, 0 failed.**

The full `CompositorTests` suite was NOT run (per FAST validation policy). The two previously reported flaky GUI tests were not mixed into this run.

---

## 6. Remaining performance limitations

The full-resolution real-DNG end-to-end test still executes two full RAW decodes (initial import + re-develop on Apply). Each full decode of the 31.8 MB Ricoh GR III DNG is seconds of work in Debug configuration. This is inherent to `CIRAWFilter` full-resolution 16-bit development and is not a test bug.

The full test remains an **explicitly selected integration test**, not run with every ordinary focused RAW test run. The fast smoke test (800px preview) covers the cheap decoder check.

If full-resolution performance remains unacceptable, the measured bottleneck is Core Image RAW decode + 16-bit conversion, not test infrastructure or project serialization.

---

## 7. Correctness and performance acceptance

- Test sequence defect corrected ✅
- Existing failure diagnostics extracted from `.xcresult` ✅
- Each expensive stage instrumented ✅
- Small real RAW preview smoke test succeeded ✅
- Full-resolution real test executed ONCE and passed ✅

**Success criterion met:** One real camera DNG successfully passes import → initial development → save → reopen → new edit → Apply → pixel verification → Undo/Redo, with stage-by-stage timing evidence. Routine focused tests no longer invoke expensive full-resolution RAW processing unnecessarily.

---

## Files changed (M9.0.2)

### Modified
- `Compositor.xcodeproj/xcshareddata/xcschemes/Compositor.xcscheme` — `shouldUseLaunchSchemeArgsEnv = "YES"` so `COMPOSITOR_RAW_FIXTURE_PATH` reaches the test process
- `CompositorTests/RawDevelopmentIntegrationTests.swift` — corrected `realRawFixtureEndToEnd()` sequence (new edit before Apply), added scoped timing instrumentation, added `realRawFixtureSmokePreview()`, added `computeChecksum()` and memory helpers
- `work/geometry-validation/reports/MILESTONE_9_0_CAMERA_RAW_GUI.md` — this report

### Unchanged (intentionally)
- Production persistence: no changes to save uncommitted drafts
- `CompositorTests/RawDevelopmentGUITests.swift` — no changes this milestone

### Not committed
- `Tests/TestFixtures/Ricoh-GR-III.DNG` (large binary, gitignored via `.gitignore`)

---

**PR #16** remains open and unmerged. Fixes are committed to the `camera-raw-workflow-ui` branch on this worktree; do not merge.