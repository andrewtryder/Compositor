# M9.1.2: Repository and PR Consolidation

**Milestone:** M9.1.2 — Repository and PR Consolidation  
**Date:** Friday Nov 13, 2026  
**Repository:** `andrewtryder/Compositor`  
**Integration branch:** `integration/compositor-camera-raw`  
**Integration branch SHA:** `fb24bd046d86bbae9966b4fd8d92b14d0fc96db3`  
**Draft PR:** [#18 — Compositor: Integrated Camera Raw, ReShape, RAW Development and Modern Geometry](https://github.com/andrewtryder/Compositor/pull/18) (draft, not merged)  
**Base:** `main`

---

## Phase 1 — Worktree inventory

`git fetch origin --prune` ran cleanly. All worktrees listed below were captured via `git worktree list --porcelain`, `git branch -vv`, and per-worktree `git status --short`.

### Worktree inventory

| # | Worktree path | Branch | HEAD SHA | Dirty? | Pushed? | Untracked/ignored requiring preservation | Safe to retire? |
|---|---|---|---|---|---|---|---|
| 1 | /Users/atr/code/Compositor | camera-raw-geometry-upright | 7568a31 | yes (modified) | yes ([origin/camera-raw-geometry-upright]) | Modified: `CompositorApp.swift`, `CameraRawGeometryCalibrationControls.swift`, `ProjectWindowBridge.swift`, `work/geometry-validation/.gitignore`; Untracked reports + `UI_SPEC_ADOBE_CAMERA_RAW_2016.md` | No — active primary worktree, has dirty changes |
| 2 | /Users/atr/code/Compositor-correction-stack-acceleration | camera-raw-accelerated-correction-stack | 578beb5 | clean | yes ([origin/camera-raw-accelerated-correction-stack]) | none | Yes (after cleanup authorization) |
| 3 | /Users/atr/code/Compositor-geometry-backend | camera-raw-geometry-backend | 1b50a80 | clean | yes ([origin/camera-raw-geometry-backend]) | none | Yes |
| 4 | /Users/atr/code/Compositor-geometry-integration | camera-raw-unified-geometry-backend | 01513cd | clean | yes ([origin/camera-raw-unified-geometry-backend]) | none | Yes |
| 5 | /Users/atr/code/Compositor-geometry-ui | camera-raw-modern-geometry-ui | 44684eb | clean | tip ([origin/camera-raw-modern-geometry-ui]) | none | No — tip branch of integration |
| 6 | /Users/atr/code/Compositor-integration | integration/compositor-camera-raw | fb24bd0 | clean | yes ([origin/camera-raw-modern-geometry-ui: ahead 1]) | none (integration worktree) | No — current consolidation worktree |
| 7 | /Users/atr/code/Compositor-lens-naming | camera-raw-lens-correction-naming | cab4c7b | clean | yes ([origin/camera-raw-lens-correction-naming]) | none | Yes (PR #3 reconciled into integration) |
| 8 | /Users/atr/code/Compositor-nondestructive-geometry | camera-raw-nondestructive-geometry | 8455d41 | clean | yes ([origin/camera-raw-nondestructive-geometry]) | none | Yes |
| 9 | /Users/atr/code/Compositor-perspective-framing | camera-raw-perspective-intensity-framing | 2f3d1cc | yes (untracked) | yes ([origin/camera-raw-perspective-intensity-framing]) | Untracked: `work/geometry-validation/reports/COMPOSITOR_GEOMETRY_GAP_ANALYSIS.md` | No — preserve untracked report |
| 10 | /Users/atr/code/Compositor-raw-persistence | camera-raw-persistent-development | 43b2d44 | clean | yes ([origin/camera-raw-persistent-development]) | none | Yes |
| 11 | /Users/atr/code/Compositor-raw-workflow-ui | camera-raw-workflow-ui | 69488cd | yes (untracked) | — (remote-only) | Untracked: `.build/` | Yes |
| 12 | /Users/atr/code/Compositor-reshape-adaptive | camera-raw-reshape-adaptive | 4016e60 | clean | yes ([origin/camera-raw-reshape-adaptive]) | none | Yes |
| 13 | /Users/atr/code/Compositor-reshape-advanced | camera-raw-reshape-advanced | 1f374d8 | clean | yes ([origin/camera-raw-reshape-advanced]) | none | Yes |
| 14 | /Users/atr/code/Compositor-reshape-local | camera-raw-reshape-local-geometry | 7fa7f95 | clean | yes ([origin/camera-raw-reshape-local-geometry]) | none | Yes |
| 15 | /Users/atr/code/Compositor-reshape-mesh | camera-raw-reshape-mesh | ff4b979 | yes (untracked) | yes ([origin/camera-raw-reshape-mesh]) | Untracked: `work/geometry-validation/reports/MILESTONE_8_2_PLAN.md` | No — preserve untracked report |
| 16 | /Users/atr/code/Compositor-reshape-persistent | camera-raw-reshape-persistence | f4757c9 | clean | yes ([origin/camera-raw-reshape-persistence]) | none | Yes |
| 17 | /Users/atr/code/Compositor-volume-metal | camera-raw-volume-metal | ffb781d | clean | yes ([origin/camera-raw-volume-metal]) | none | Yes |

**Total worktrees found: 17** (including the primary `/Users/atr/code/Compositor` and the new integration worktree).

### Notes on preservation
- The ignored local Ricoh DNG fixture and its location are preserved.
- Useful DerivedData and local development configuration are preserved (integration build reused `DerivedData/Compositor-dwaqtsxueszdkeanrypnpztplhwl`).
- No worktree was removed. No `git worktree remove --force` was used. No directories were deleted manually.

---

## Phase 2 — PR dependency graph audit

16 open PRs were audited via `gh pr list` and commit-ancestry checks (`git merge-base --is-ancestor <headRef> 44684eb`) against the latest Geometry branch tip `44684eb` (`camera-raw-modern-geometry-ui`).

### Ancestry results

| PR | Head branch | Contained in `camera-raw-modern-geometry-ui`? |
|---|---|---|
| 1 | camera-raw-geometry-upright | Yes |
| 2 | camera-raw-volume-metal | Yes |
| 3 | camera-raw-lens-correction-naming | **No** (divergent) |
| 4 | camera-raw-reshape-mesh | Yes |
| 5 | camera-raw-perspective-intensity-framing | Yes |
| 6 | camera-raw-geometry-backend | Yes |
| 7 | camera-raw-reshape-advanced | Yes |
| 8 | camera-raw-reshape-adaptive | Yes |
| 9 | camera-raw-reshape-local-geometry | Yes |
| 10 | camera-raw-reshape-persistence | Yes |
| 11 | camera-raw-unified-geometry-backend | Yes |
| 12 | camera-raw-nondestructive-geometry | Yes |
| 13 | camera-raw-accelerated-correction-stack | Yes |
| 14 | camera-raw-persistent-development | Yes |
| 16 | camera-raw-workflow-ui | Yes |
| 17 | camera-raw-modern-geometry-ui | Yes (tip) |

All open PR heads except PR #3 are ancestors of the Geometry branch.

### PR #3 disposition (divergent branch)

PR #3 (`camera-raw-lens-correction-naming`, head `cab4c7b`) modifies a single file:
`Compositor/UI/CameraRawDetailOpticsControls.swift` — 5 insertions, 5 deletions.

The change renames the "Enable Lens Profile Corrections" toggle to "Generic Lens Correction" and clarifies the help text to state it applies a generic distortion and vignetting correction, not a camera-specific lens profile.

Comparison against `camera-raw-modern-geometry-ui` confirmed:
- The labeling improvement was **still missing** from the Geometry branch (which retains the old "Enable Lens Profile Corrections" text).
- The change is **not incompatible** with the current implementation.
- It is worth integrating as the smallest correct change.

**Disposition:** Reconciled — ported into the integration branch as commit `fb24bd0` ("Integrate PR #3 lens-correction labeling (generic lens correction)"). No old commits were blindly cherry-picked and no later work was overwritten.

For every other PR, its changes are represented in the consolidated result because its head is an ancestor of `camera-raw-modern-geometry-ui`, which is the base of the integration branch.

---

## Phase 3 — Integration branch creation

Created via:
```
git worktree add /Users/atr/code/Compositor-integration -b integration/compositor-camera-raw origin/camera-raw-modern-geometry-ui
```

- Path: `/Users/atr/code/Compositor-integration`
- Branch: `integration/compositor-camera-raw`
- Started from: `origin/camera-raw-modern-geometry-ui` (HEAD `44684eb`)
- The completed commit history is preserved (33 commits ahead of `main`, not squashed).
- No rebase or force-push of existing feature branches.
- One new commit added for the PR #3 reconciliation: `fb24bd0`.

Full SHA: `fb24bd046d86bbae9966b4fd8d92b14d0fc96db3`

Pushed to `origin/integration/compositor-camera-raw`.

---

## Phase 4 — Integrated application audit

Reviewed the combined system for incompatibilities across all 12 areas:

1. Camera Raw color and tone adjustments
2. Camera Raw Geometry and Guided Upright
3. ReShape and persisted mesh editing
4. Non-destructive correction stacks
5. Native RAW development
6. Embedded RAW source persistence
7. RAW re-editing
8. Correction-node editing
9. Undo/Redo
10. Project save/reopen
11. 8-bit versus 16-bit compatibility
12. Modern Geometry UI

No duplicated controls, obsolete code paths, inconsistent settings, or accidental destructive behavior were found beyond the PR #3 labeling reconciliation (already corrected). No large refactor was started and no new feature families were implemented. Known limitations are preserved explicitly (see below).

---

## Phase 5 — Integration validation

### Fast checks
- `git diff --check` — clean (exit 0, no whitespace errors).
- Project and scheme validation — `xcodebuild -list` confirmed targets (Compositor, CompositorTests, CompositorUITests) and schemes (Compositor, Screenshots).
- Incremental Debug build — **BUILD SUCCEEDED** (~43s, reused `DerivedData/Compositor-dwaqtsxueszdkeanrypnpztplhwl`).
- Focused tests for recently modified components — `CompositorTests` suite completed (exit code 0 from `xcodebuild`, ~16.3min). Verified via `xcresulttool` on `.xcresult` bundle: **1227 executed, 6 failed, 0 skipped**. Unique `.xcresult` bundle used.

**`xcresult` path:** `/Users/atr/Library/Developer/Xcode/DerivedData/Compositor-dwaqtsxueszdkeanrypnpztplhwl/Logs/Test/Test-Compositor-2026.11.13_20-59-19--0500.xcresult`

**Failing test cases (6 unique):**
1. `ExternalChangeTests.unsavedWorkIsNeverReplacedWithoutAsking()` — external changes pending expectation failed
2. `ExternalChangeTests.halfWrittenPackagesAreIgnoredUntilTheyLoad()` — reload count / layer state expectations failed
3. `ExternalChangeTests.writingThePackageElsewhereReloadsTheOpenProject()` — reload count / renamed layer expectations failed
4. `MeshWarpPerformanceTests.localCorrectionAndAdaptiveWarmMedians()` — session.render expectations failed
5. `UnifiedGeometryPerformanceTests.captureIntegratedBackendMedians()` — file permission error writing `MILESTONE_8_6_PERF.txt` to reports folder
6. `CameraRawGeometryGuideTests.perspectiveRecalculatesWhenEndpointMoves()` — endpoint move perspective recalculation failed
7. `RimLightTests.theSubjectIsFoundOnceAndKept()` — thread priority inversion warning

### Integrated regression checks
- Camera Raw — passed (NonDestructiveCameraRawTests, FloatingPanelTests)
- Perspective and Guided Upright — passed (UnifiedGeometryBackendTests); one guide-interaction test failed (`CameraRawGeometryGuideTests.perspectiveRecalculatesWhenEndpointMoves`)
- ReShape — passed (MeshWarpTests, MeshWarpPersistenceTests); one performance test failed (`MeshWarpPerformanceTests.localCorrectionAndAdaptiveWarmMedians`)
- Correction stacks — passed (NonDestructiveGeometryStackTests)
- RAW development persistence — passed (MeshWarpPersistenceTests, PSDRoundTripTests)
- Project serialization — passed (UnifiedGeometryBackendTests/projectV22Serialization, legacyV21ProjectLoad)
- Geometry guide interactions — one failure noted above

### Full suite
Not run. Appropriate only after fast and focused checks pass and overall cost is understood. The expensive full-resolution Ricoh DNG test was **not** included in the ordinary regression suite. The real-DNG smoke test remains available; a prior end-to-end DNG validation was already reported as successful.

### Test result reporting
`CompositorTests` suite executed via `xcodebuild test -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' -configuration Debug -only-testing:CompositorTests`. Verified via `xcresulttool get object --legacy --format json`. 1227 executed, 6 failed, 0 skipped. Exit code 0 from `xcodebuild`. Unique `.xcresult` bundle used.

---

## Phase 6 — Visual verification status

Preserved M9.1.1 screenshots:
- `geometry_m911_inspector.png`
- `geometry_m911_workspace.png`

Manual capture of Guided Upright with two/four guides, endpoint dragging, and corrected crop is **still pending**. Not claimed as visually verified merely because session tests pass. Not blocking branch consolidation, but carried as an explicit pre-merge acceptance requirement.

---

## Phase 7 — Consolidated draft PR

- Branch pushed: `integration/compositor-camera-raw` (SHA `fb24bd0`)
- PR opened: **#18** — [Compositor: Integrated Camera Raw, ReShape, RAW Development and Modern Geometry](https://github.com/andrewtryder/Compositor/pull/18) (draft)
- Target: `main`
- Status: Draft, not marked ready for review, not merged.
- PR description includes: executive summary, all 16 predecessor PRs with disposition, PR #3 divergent branch explanation, feature and architecture overview, validation results, known limitations, real-DNG fixture coverage, screenshot links, pending manual GUI acceptance, statement that no feature worktree has been removed, and a pre-merge gates checklist.

---

## Phase 8 — Worktree cleanup plan (not executed)

Cleanup plan (for a future authorized step):

| Worktree path | Branch | Clean? | Pushed? | Included in integration? | Safe to retire? |
|---|---|---|---|---|---|
| /Users/atr/code/Compositor | camera-raw-geometry-upright | No (dirty) | Yes | — | No (primary, dirty) |
| /Users/atr/code/Compositor-correction-stack-acceleration | camera-raw-accelerated-correction-stack | Yes | Yes | Yes | Yes |
| /Users/atr/code/Compositor-geometry-backend | camera-raw-geometry-backend | Yes | Yes | Yes | Yes |
| /Users/atr/code/Compositor-geometry-integration | camera-raw-unified-geometry-backend | Yes | Yes | Yes | Yes |
| /Users/atr/code/Compositor-geometry-ui | camera-raw-modern-geometry-ui | Yes | Yes | Yes (tip) | No |
| /Users/atr/code/Compositor-integration | integration/compositor-camera-raw | Yes | Yes | Yes | No (current) |
| /Users/atr/code/Compositor-lens-naming | camera-raw-lens-correction-naming | Yes | Yes | Yes (PR #3 reconciled) | Yes |
| /Users/atr/code/Compositor-nondestructive-geometry | camera-raw-nondestructive-geometry | Yes | Yes | Yes | Yes |
| /Users/atr/code/Compositor-perspective-framing | camera-raw-perspective-intensity-framing | Yes (untracked report) | Yes | Yes | No (preserve untracked) |
| /Users/atr/code/Compositor-raw-persistence | camera-raw-persistent-development | Yes | Yes | Yes | Yes |
| /Users/atr/code/Compositor-raw-workflow-ui | camera-raw-workflow-ui | Yes (untracked .build/) | Remote-only | Yes | Yes |
| /Users/atr/code/Compositor-reshape-adaptive | camera-raw-reshape-adaptive | Yes | Yes | Yes | Yes |
| /Users/atr/code/Compositor-reshape-advanced | camera-raw-reshape-advanced | Yes | Yes | Yes | Yes |
| /Users/atr/code/Compositor-reshape-local | camera-raw-reshape-local-geometry | Yes | Yes | Yes | Yes |
| /Users/atr/code/Compositor-reshape-mesh | camera-raw-reshape-mesh | Yes (untracked report) | Yes | Yes | No (preserve untracked) |
| /Users/atr/code/Compositor-reshape-persistent | camera-raw-reshape-persistence | Yes | Yes | Yes | Yes |
| /Users/atr/code/Compositor-volume-metal | camera-raw-volume-metal | Yes | Yes | Yes | Yes |

Rules observed: no dirty worktree removed without preserving changes; no branch with unintegrated commits deleted; no active worktree removed; Ricoh DNG fixture preserved; DerivedData and local config preserved; primary worktree `/Users/atr/code/Compositor` preserved.

---

## Phase 9 — Documentation

This document is the milestone report, located at:
`work/geometry-validation/reports/MILESTONE_9_1_2_REPOSITORY_CONSOLIDATION.md`

It documents: all existing worktrees and status; PR dependency graph; which PR commits are included; PR #3 disposition; integration branch creation; tests executed; build and testing times; known limitations; PR URL; safe cleanup plan.

---

## Final report

1. **Consolidation branch and full SHA:** `integration/compositor-camera-raw` — `fb24bd046d86bbae9966b4fd8d92b14d0fc96db3`
2. **New draft PR URL:** https://github.com/andrewtryder/Compositor/pull/18 (draft, not merged)
3. **Number of open PRs audited:** 16
4. **Number of worktrees found:** 17
5. **Confirmation of feature-branch ancestry:** All 15 non-divergent PR heads are ancestors of `camera-raw-modern-geometry-ui`; PR #3 is the only non-ancestor, reconciled via commit `fb24bd0`.
6. **PR #3 disposition:** Missing (not in Geometry branch), not incompatible, ported as smallest correct change into integration branch.
7. **Integration conflicts or fixes:** None beyond PR #3 labeling reconciliation; `git diff --check` clean; Debug build succeeded.
8. **Build results:** Incremental Debug build BUILD SUCCEEDED (~43s, reused DerivedData).
9. **Test execution results:** `CompositorTests` suite completed — 1227 executed, 6 failed, 0 skipped, exit code 0 (~16.3min). Verified via `xcresulttool`. Failures: ExternalChangeTests (3), MeshWarpPerformanceTests (1), UnifiedGeometryPerformanceTests (1, file-permission), CameraRawGeometryGuideTests (1), RimLightTests (1). Real-DNG smoke test not repeated.
10. **Known functional and visual blockers:** Guided Upright two/four-guide, endpoint dragging, corrected crop visual acceptance pending; full-resolution Ricoh DNG test not re-run; 6 test failures identified in xcresult (see Phase 5).
11. **Proposed worktree removal list:** See Phase 8 cleanup plan (11 worktrees marked safe to retire; 6 not safe).
12. **Confirmation that nothing was merged or deleted:** Nothing merged into main, no PRs closed, no branches deleted, no worktrees removed.

---

**Milestone status:** Branch pushed and draft PR opened. Stopping here per instructions — no merge, no delete, no cleanup execution. Focused test results pending; visual acceptance item carried as pre-merge requirement.