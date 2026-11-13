# Milestone 8.5 — Persistent, Non-Destructive ReShape

Branch: `camera-raw-reshape-persistence`  
Worktree: `/Users/atr/code/Compositor-reshape-persistent`  
Baseline: Milestone 8.4 `7fa7f958236c2224742be580744dae5fb6563583` (draft PR #9)  
Status: implemented locally — Debug `MeshWarpPersistenceTests` all passed (20/20); commit/push when requested

## Model

Each editable ReShape layer keeps three pieces of state:

1. **Immutable source** (`LayerReshape.source`) — the unwarped 8-bit bitmap Apply always samples from.
2. **Mesh** (`LayerReshape.mesh` / `MeshWarpPersistentState`) — stable vertex/face IDs, rest + current UV, adaptive topology, sticky borders, propagation.
3. **Rendered display** (`ImageLayer.asset`) — last Apply output for canvas, export, and thumbnails.

The in-progress `MeshWarpEdit` session is never project state. Cancel drops the session only.

## Apply / Re-edit / Cancel / Bake

| Action | Behavior |
| --- | --- |
| Apply | Validate mesh → render from source → store reshape + display → one document undo |
| Re-edit | Restore mesh + source into a new GPU-resident session (not the warped display) |
| Cancel | Discard session; persistent reshape unchanged |
| Identity Apply | Clears reshape and restores source as display (one undo) when reshape existed |
| Bake ReShape | Clears reshape; keeps current display pixels as ordinary layer content |

## Destructive-op policy

Operations that would replace layer pixels refuse while `reshape` is present:

- Painting / Smudge / Liquify / Gradient (layer pixels)
- Filters, Levels, Hue/Saturation
- Merge

Mask painting, layer transforms, visibility/opacity/blend, duplicate, export, and delete are allowed. Canvas Size preserves reshape. Image Size resamples both display and source and updates mesh image dimensions (UV identity preserved).

## Project format (v22)

- `ProjectManifest.current = 22`
- Optional `reshape: { sourceFile, meshFile }` on image layers
- Assets: `<uuid>.reshape-source.png`, `<uuid>.reshape.json`
- Triangle buffers are **not** serialized; triangulation is reconstructed on load
- Existing v1–21 projects load unchanged; corrupt reshape rejects without replacing the live document

## Tests

`CompositorTests/MeshWarpPersistenceTests.swift` covers identity/regular/adaptive/nested/hanging-edge round-trips, merge-after-reload, stable IDs, sticky/propagation, local Perspective/Horizon/Volume persistence, save/reopen pixels, re-apply without cumulative resampling, multi-cycle save/load, document undo/redo, cancel, bake, paint refusal, and legacy projects without reshape.

## Explicitly deferred

- Unified ReShape GUI
- Standard keyboard Undo binding for tool-local history
- Geometry-backend branch integration
- 16-bit/HDR ReShape (still refused)
- DxO sidecars / proprietary mesh formats
