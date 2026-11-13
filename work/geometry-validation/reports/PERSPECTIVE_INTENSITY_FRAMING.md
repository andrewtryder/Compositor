# Camera Raw — Perspective Intensity and Framing

Baseline: `ffb781dda07d16efdf968c981a83da8fc8add00f`
Branch: `camera-raw-perspective-intensity-framing`
Worktree: `/Users/atr/code/Compositor-perspective-framing`

ViewPoint 6.1 research (behavioral reference only): reports under this folder + `/tmp/vp61-perspective-lab/notes/FINALSELECTION_RECOVERY.md`.

## Implementation decisions

1. **Perspective Amount (0–100%, default 100)** blends the keystone/roll homography toward identity after Auto/Guided selection (or after manual Vertical/Horizontal/Rotate), then applies Aspect / Scale / Offset. Auto candidate ranking is unchanged.
2. **Framing mode** enum: Keep Original Size (default, editor path) and Expand to Fit (geometry math + unit tests). The Camera Raw filter path forces Keep Original Size until `FilterEdit` can grow the layer and remapping together.
3. **Constrain Crop** stays independent: under Keep Original Size it still trims and scales into the original frame; under Expand to Fit (direct `geometry.apply`) it only crops empty margins.

Compositor intentionally retains composition-aware Auto Full ranking (`fullIsWorth` / coverage metrics). ViewPoint’s recovered estimator has no crop-loss term.

## Homography blending

For perspective matrix \(H\):

1. Normalize \(H\) by \(m_8\) (or largest entry).
2. \(H(t)=(1-t)I + tH\) with \(t=\mathrm{amount}/100\).
3. Renormalize; require `isPlausible`.
4. At \(t=1\), use the unblended solver/manual corners so existing 100% results stay bit-identical.
5. At \(t=0\), perspective corners are identity; polish and volume still apply.

Manual keystone builds a DLT from identity→full corners, then blends. Degenerate blends fall back to identity rather than inventing an intermediate.

## Coordinate conventions

- Corners are Core Image order (TL, TR, BR, BL), y upward from the bottom.
- Expand bounds use the continuous axis-aligned bbox of those corners, rounded up to integer pixels, translated so min ≥ 0.
- Guards: side ≤ `DocumentLimits.maxSide`, area ≤ `DocumentLimits.maxSurfacePixels`.

## Framing mathematics

`CameraRawPerspective.expandedFrame(corners:)` → `(size, translation)`.
`translatedCorners` shifts destinations into the nonnegative canvas before `CIPerspectiveTransform` + `PixelAdjust.render` at the new size.

## Defaults and serialization

| Setting | Default | Legacy decode |
| --- | --- | --- |
| `perspectiveAmount` | 100 | missing → 100 |
| `framingMode` | Keep Original Size | missing → Keep Original Size |

`CameraRawGeometrySettings` uses a custom `init(from:)` with `decodeIfPresent` fallbacks (same pattern as Lens Effects).

## Rendering architecture

`CameraRawSettings.apply` still assumes geometry output matches the layer footprint for the filter/editor path (Expand coerced to Keep Original Size). Direct `CameraRawGeometrySettings.apply` honors Expand for tests. Volume → perspective → Constrain Crop order unchanged. No extra resampling pass for intensity.

### Deferred Expand to Fit integration

Required before enabling Expand in the panel:

1. `FilterEdit` grow / remapping when geometry output size ≠ input.
2. Preview mapping updates each slider drag.
3. `commitFilter` layer transform sized to new pixels without shifting unrelated layers/masks.
4. Export verification of the expanded footprint.

## Tests

Debug (`CODE_SIGN_IDENTITY=-`):

| Suite | Result |
| --- | --- |
| `CameraRawPerspectiveIntensityFramingTests` | 15/15 passed |
| `CameraRawUprightTests` | passed (incl. window-wall Full→vertical, strong rectangle Full, Level) |
| `CameraRawUprightComparisonTests` | passed (`renderPhotographicModes`, `renderComparisonCorpus`) |
| `CameraRawResetTests` | passed |
| `CameraRawTests` | passed (geometry warp, constrain crop, guided upright, etc.) |

Release: build/test host failed with `Unable to resolve Swift module dependency to a compatible module: 'Compositor'` (same known Release module compatibility issue as ReShape; not a functional assertion failure).

## GUI validation

- Debug app launched; Camera Raw Filter opened on a synthetic converging-wall image.
- Geometry section is present in the panel list.
- SwiftUI accessibility did not expose Geometry disclosure controls for automated expand; slider interaction was not completed via Computer Use.
- Control presence confirmed in source (`Perspective Amount`, Framing picker disabled with deferral caption).
- No routine screenshots captured.

## Known limitations

- Expand to Fit unavailable in the editor (forced Keep Original Size on the Camera Raw filter path).
- Release automated tests blocked by module compatibility.
- GUI slider smoke incomplete due to AX gaps.

## Source files changed

- `Compositor/Document/CameraRawPerspective.swift`
- `Compositor/Document/CameraRawGeometryCalibration.swift`
- `Compositor/Document/CameraRaw.swift`
- `Compositor/UI/CameraRawGeometryCalibrationControls.swift`
- `CompositorTests/CameraRawPerspectiveIntensityFramingTests.swift`
- `work/geometry-validation/reports/PERSPECTIVE_INTENSITY_FRAMING.md`
- (copied research reports into worktree for reference; not required for the feature)
