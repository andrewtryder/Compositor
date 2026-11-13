# Camera Raw — Geometry Backend (Track A continuation)

Baseline: `2f3d1cc8dcad9979e0351c1c627d6aadca165c07` (PR #5 Track A checkpoint)
Branch: `camera-raw-geometry-backend`
Worktree: `/Users/atr/code/Compositor-geometry-backend`

Backend-first milestone. Unified GUI and extensive photographic GUI validation are deferred.

## Phase 1 — Expand to Fit integration

- `CameraRawGeometryExpansion` maps CI warp corners → layer-CG coverage and a `LayerTransform` using the same center-preserving rule as FilterEdit blur growth.
- `geometry.applyResult` / `CameraRawSettings.applyResult` / `PixelFilter.runResult` return expansion metadata.
- Preview and `commitFilter` place expanded Camera Raw results via `preparedTransform` / committed layer transform.
- Masks on the old grid are carried onto the new footprint (same path as blur growth).
- Document canvas is not resized as a side effect.
- Selection + Expand falls back to Keep Original Size (blend requires matching footprints).
- 16-bit layers: Expand commits through the 8-bit filter path because `DeepLayer.run` requires same-size results.
- Framing picker enabled in Geometry controls.

## Phase 2 — Horizon engine

- `CameraRawHorizonSettings` + `CameraRawHorizon`: Automatic, Angle, Horizontal/Vertical reference, Amount, reset.
- Rotation matches manual Rotate corner math; endpoint order is invariant for references.
- Composition: Horizon after perspective; skipped when it would double-apply roll with Auto Level unless used as Level substitute. Auto Full ranking unchanged.

## Phase 3 — Perspective tools

- `CameraRawPerspectiveToolState` / `CameraRawPerspectiveTools`: vertical, horizontal, combined, rectangle, eight-point, manual keystone.
- Existing two-/four-guide solver paths retained; tools only supply guides.
- H/V Ratio ≡ existing Aspect polish (documented alias).

## Phase 4 — Crop / framing APIs

- `CameraRawGeometryCrop` + `CameraRawGeometryCropRequest`: coordinate conversion, aspect constraint, opaque inscribed rect (shared algorithm with Constrain Crop).
- Keep Original Size / Expand to Fit remain independent of Constrain Crop.

## Phase 5 — Miniature Effect

- `CameraRawMiniatureSettings` + renderer via `CIMaskedVariableBlur` (linear band / circular), continuous masks, identity at zero strength.
- Wired through `CameraRawGeometryBackend.apply` for API use; not yet a Camera Raw panel section.

## Phase 6 — Backend facade

- `CameraRawGeometryBackendSettings` / `CameraRawGeometryBackend` document composition order and provide `apply` / `reset`.
- ReShape / mesh stays separate (PR #4); not composed here.

## Tests (Debug)

- `CameraRawGeometryBackendTests` — passed
- `CameraRawPerspectiveIntensityFramingTests` — passed

## Known limitations

- Horizon / perspective-tools / miniature / crop-request are backend APIs; not fully surfaced in the Camera Raw sheet (except Framing + existing perspective).
- Expand + layer selection coerced to Keep Original Size.
- Expand on 16-bit layers uses the 8-bit commit path.
- Release CompositorTests module compatibility issue from Track A remains unaddressed here.
- No ViewPoint RE repeated; no proprietary code copied.
