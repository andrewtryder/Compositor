# Worktree Consolidation Cleanup Report

**Date:** Friday, Nov 13, 2026  
**Repository:** `/Users/atr/code/Compositor`  
**Task:** Consolidate all 17 local Compositor worktrees into one

## Summary

Reduced the local Git worktree count from 17 to exactly one. The primary
`/Users/atr/code/Compositor` directory remains the primary repository directory
and is now checked out onto the consolidated `integration/compositor-camera-raw`
branch, tracking `origin/integration/compositor-camera-raw`.

## 1. Original 17 Worktrees

| # | Path | Branch | Head SHA |
|---|------|--------|----------|
| 1 | `/Users/atr/code/Compositor` (primary) | `camera-raw-geometry-upright` | `7568a31` |
| 2 | `/Users/atr/code/Compositor-correction-stack-acceleration` | `camera-raw-accelerated-correction-stack` | `578beb5` |
| 3 | `/Users/atr/code/Compositor-geometry-backend` | `camera-raw-geometry-backend` | `1b50a80` |
| 4 | `/Users/atr/code/Compositor-geometry-integration` | `camera-raw-unified-geometry-backend` | `01513cd` |
| 5 | `/Users/atr/code/Compositor-geometry-ui` | `camera-raw-modern-geometry-ui` | `44684eb` |
| 6 | `/Users/atr/code/Compositor-integration` | `integration/compositor-camera-raw` | `8fb68cc` |
| 7 | `/Users/atr/code/Compositor-lens-naming` | `camera-raw-lens-correction-naming` | `cab4c7b` |
| 8 | `/Users/atr/code/Compositor-nondestructive-geometry` | `camera-raw-nondestructive-geometry` | `8455d41` |
| 9 | `/Users/atr/code/Compositor-perspective-framing` | `camera-raw-perspective-intensity-framing` | `2f3d1cc` |
| 10 | `/Users/atr/code/Compositor-raw-persistence` | `camera-raw-persistent-development` | `43b2d44` |
| 11 | `/Users/atr/code/Compositor-raw-workflow-ui` | `camera-raw-workflow-ui` | `69488cd` |
| 12 | `/Users/atr/code/Compositor-reshape-adaptive` | `camera-raw-reshape-adaptive` | `4016e60` |
| 13 | `/Users/atr/code/Compositor-reshape-advanced` | `camera-raw-reshape-advanced` | `1f374d8` |
| 14 | `/Users/atr/code/Compositor-reshape-local` | `camera-raw-reshape-local-geometry` | `7fa7f95` |
| 15 | `/Users/atr/code/Compositor-reshape-mesh` | `camera-raw-reshape-mesh` | `ff4b979` |
| 16 | `/Users/atr/code/Compositor-reshape-persistent` | `camera-raw-reshape-persistence` | `f4757c9` |
| 17 | `/Users/atr/code/Compositor-volume-metal` | `camera-raw-volume-metal` | `ffb781d` |

All 16 feature/integration worktree branches are represented as ancestor commits
in the consolidated `integration/compositor-camera-raw` branch (verified via
`git log`). No branch was deleted remotely.

## 2. Directories Removed

All 16 linked worktree directories were removed using `git worktree remove`
(clean, no `--force`, no `rm -rf`):

- `Compositor-correction-stack-acceleration`
- `Compositor-geometry-backend`
- `Compositor-geometry-integration`
- `Compositor-geometry-ui`
- `Compositor-integration`
- `Compositor-lens-naming`
- `Compositor-nondestructive-geometry`
- `Compositor-perspective-framing`
- `Compositor-raw-persistence`
- `Compositor-raw-workflow-ui`
- `Compositor-reshape-adaptive`
- `Compositor-reshape-advanced`
- `Compositor-reshape-local`
- `Compositor-reshape-mesh`
- `Compositor-reshape-persistent`
- `Compositor-volume-metal`

No blocked removals. The primary `/Users/atr/code/Compositor` directory was not
removed.

## 3. Preservation (Backup)

All valuable local work was preserved before any removal.

**Backup location:** `/Users/atr/Documents/Compositor-worktree-backups/20261113-215314/`

### Preserved items

- **Primary worktree dirty diff** (staged + unstaged): `primary-worktree.diff`
  - `Compositor/CompositorApp.swift`
  - `Compositor/UI/CameraRawGeometryCalibrationControls.swift`
  - `Compositor/UI/ProjectWindowBridge.swift`
  - `work/geometry-validation/.gitignore`
- **Primary worktree stash**: `stash@{0}` — "Primary worktree dirty changes
  (camera-raw-geometry-upright) pre-consolidation backup", originating branch
  `camera-raw-geometry-upright`. Recorded so switching branches cannot lose it.
  Stash was *not* applied to the integration branch (may conflict with newer work).
- **Primary worktree untracked reports/documents/research**: backed up under
  `primary-worktree-untracked/` (includes `UI_SPEC_ADOBE_CAMERA_RAW_2016.md`,
  all `VIEWPOINT_6_*` reports, `MILESTONE_*` reports, `COMPOSITOR_GEOMETRY_GAP_ANALYSIS.md`,
  `viewpoint6-research/` with inputs, screenshots, ghidra notes, exports).
- **DNG test fixture**: `Ricoh-GR-III.DNG` backed up to
  `dng-fixture/Ricoh-GR-III.DNG`. Checksum verified before and after copy:
  `05513ee72f7cac4165534c9f64995412084f414a033c80c473c79fd94154292e` (match).
- **Other worktree untracked files**: backed up under
  `perspective-framing-untracked/` and `reshape-mesh-untracked/`
  (reports, `.gitignore`, inputs, Swift helpers).
- **`.build/` cache** (raw-workflow-ui): not backed up — regenerable build
  artifact, confirmed tiny (8.0K). Removed as a known-regenerable cache.

### Checksums

| File | SHA-256 |
|------|---------|
| `dng-fixture/Ricoh-GR-III.DNG` | `05513ee72f7cac4165534c9f64995412084f414a033c80c473c79fd94154292e` |
| `primary-worktree.diff` | `fd3ab654515332bed8d014a687f1ef032d870dd581fbc3004b125e21bed9650f` |

All backup files were confirmed present after copying.

## 4. Current State

### Sole worktree

```
worktree /Users/atr/code/Compositor
HEAD 8fb68cc5c166ae49f08da8e4f4a2a111dd4c6ca8
branch refs/heads/integration/compositor-camera-raw
```

- **Branch:** `integration/compositor-camera-raw`
- **Upstream tracking:** `origin/integration/compositor-camera-raw`
- **HEAD SHA:** `8fb68cc5c166ae49f08da8e4f4a2a111dd4c6ca8`
- **Remote SHA:** `8fb68cc5c166ae49f08da8e4f4a2a111dd4c6ca8` (matches)
- **Working tree:** clean (only untracked research files remain, all backed up)
- **Stash:** `stash@{0}` recoverable

## 5. Remote / PR Status

- **PR #18:** https://github.com/andrewtryder/Compositor/pull/18
- **State:** OPEN
- **Draft:** true (unchanged)
- **Head ref:** `integration/compositor-camera-raw`
- **Head repository owner:** andrewtryder

No remote branches were deleted. No GitHub PRs were closed. No force-push was
performed. PR #18 was not merged into main.

## 6. Data Safety Confirmation

- No active process (xcodebuild, git, build, test) was using any candidate
  worktree at removal time (verified via `ps`).
- Every dirty/untracked file was backed up before removal.
- Backup integrity verified (file presence + checksums for the DNG fixture and diff).
- The integration branch HEAD was confirmed to match `origin/integration/compositor-camera-raw` before and after the switch.
- All important old local changes remain recoverable from both the backup folder
  and the Git stash.
- The Ricoh GR III DNG fixture is preserved outside retired directories.
- No forced operations were used (`git worktree remove` without `--force`,
  no `rm -rf` against a worktree, no `git clean -fdx`, no forced branch deletion,
  no force-push).

## 7. Next Step

This report is committed and pushed to `integration/compositor-camera-raw`
(after the single-worktree state is verified), per the consolidation plan. The
branch is not merged into main.
