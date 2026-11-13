# Camera Raw — Geometry Backend (Track A continuation)

Branch: `camera-raw-geometry-backend`
Worktree: `/Users/atr/code/Compositor-geometry-backend`
Base: `camera-raw-perspective-intensity-framing` (PR #5)
Draft PR: https://github.com/andrewtryder/Compositor/pull/6

Backend-first milestone. No polished GUI / screenshots.

### Release `ENABLE_TESTABILITY` (provisional)

Project Release sets `ENABLE_TESTABILITY = YES` so Release `CompositorTests` can `@testable import Compositor`. This is a **provisional** CI/test-host fix only: before production distribution it must be limited to test builds (e.g. a dedicated Test configuration or `OTHER_SWIFT_FLAGS` gated for testing), not left on the shipping Release app module. Release optimization settings (`SWIFT_OPTIMIZATION_LEVEL`, whole-module opts) are unchanged.

## Status legend

| Tag | Meaning |
|---|---|
| Algorithm | Core math / renderer exists |
| Pixel | Deterministic pixel / numerical tests pass |
| Document | Normal `PixelFilter` / `EditorSession` Apply path executes it |
| Precision | Bit-depth / color-space behavior verified or explicitly refused |
| Serialization | Codable API exists; Camera Raw Apply remains destructive (pixels committed) |
| GUI | Panel / toolbar controls |
| Not implemented | Out of scope or deferred |

## Phase 1 — Expand to Fit

| Item | Status |
|---|---|
| Expansion metadata + layer placement | Algorithm · Pixel · Document |
| Preview / commit place via `geometryExpansion.layerTransform` | Document |
| Coverage-only transform (not union with original bounds) | Algorithm · Pixel — fixes Constrain Crop of expanded output |
| Document canvas not resized for Expand | Document |
| Selection + Expand → Keep Original Size | Document |
| 16-bit / HDR Expand | **Precision: refused** — coerced to Keep Original Size; never silent 8-bit Expand |
| Framing picker in Geometry controls | GUI (existing Framing control only) |

`supportsExpandToFit(on:)` returns false when `asset.deep != nil`. Preview and commit both coerce Expand → Keep; deep commit always uses `DeepLayer.run` / 16-bit path.

## Phase 2 — Horizon

| Item | Status |
|---|---|
| Modes: Automatic, Angle, H/V reference, Amount | Algorithm · Pixel |
| Endpoint order invariant | Algorithm · Pixel |
| Composed into destination corners **before** framing / Expand | Algorithm · Pixel · Document (`CameraRawSettings.applyResult`) |
| Skip double roll with Auto Level (Automatic = Level substitute) | Algorithm · Pixel |
| Auto Full candidate ranking | Untouched |
| Dedicated Horizon GUI | GUI pending |

## Phase 3 — Perspective tools

| Item | Status |
|---|---|
| Vertical / horizontal / combined / rectangle / eight-point / keystone | Algorithm · Document (via `CameraRawPerspectiveTools.applying` → guides) |
| Vertical-guide pixel warp test | Pixel (synthetic tapering grid) |
| H/V Ratio ≡ Aspect polish | Algorithm · Pixel |
| Degenerate guide rejection (full matrix of tools) | Partial — solver rejects bad guides; not every kind has a dedicated pixel test |
| Tool UI | GUI pending |

## Phase 4 — Crop / framing

| Item | Status |
|---|---|
| Keep Original Size / Expand to Fit | Algorithm · Pixel · Document |
| Constrain Crop (opaque inscribed) | Algorithm · Pixel · Document |
| `CameraRawGeometryCrop` free / aspect / constrained plans | Algorithm · Pixel (opaque plan tested) |
| Expand then crop footprint = coverage + transform | Pixel |
| Crop request UI beyond Constrain Crop | GUI pending |

## Phase 5 — Miniature Effect

| Item | Status |
|---|---|
| Linear / circular masked variable blur | Algorithm · Pixel |
| Zero strength identity; focus vs periphery | Pixel (impulse pattern) |
| Wired into `CameraRawSettings.applyResult` after geometry | Document |
| Independent of projective pipeline | Algorithm |
| Panel UI | GUI pending |

## Phase 6 — Backend facade

| Item | Status |
|---|---|
| `CameraRawGeometryBackend` composition order | Algorithm · Document (shared with `CameraRawSettings.applyResult`) |
| ReShape / mesh | Not implemented here (PR #4) |

## Safety pass (this session)

1. **16-bit Expand**: refuse / coerce; preserve depth on Keep path.
2. **Footprint**: `layerTransform` uses coverage only.
3. **Integration**: Horizon, perspective tools, Miniature execute on the normal Camera Raw Apply path.
4. **Horizon + Expand**: horizon degrees fed into corner framing so expansion metadata includes roll.
5. **Release tests**: project Release `ENABLE_TESTABILITY = YES` so `@testable import Compositor` resolves.

## Tests

| Suite | Debug | Release |
|---|---|---|
| `CameraRawGeometrySafetyTests` | passed | passed |
| `CameraRawGeometryBackendTests` | passed | (compiled with Release host) |
| `CameraRawPerspectiveIntensityFramingTests` | passed (prior) | — |

## Remaining backend gaps

- Full 16-bit **variable-footprint** Expand (needs DeepLayer same-size constraint lift) — currently refused.
- Broader per-tool perspective pixel suites (H/V/combined/rect/8pt/keystone).
- Document-level Undo/Redo placement harness for Expand + crop (footprint unit-tested; session history not yet).
- Miniature: asymmetric / transition smoothness / alpha fringe cases beyond impulse center/corner.
- Free-crop / preserved-aspect crop pixel cases beyond opaque auto crop.
- GUI for Horizon, tools, Miniature, crop request.
- Advanced ReShape / AI segmentation / ViewPoint toolbar — not in scope.

## Proposed follow-up commit (do not create yet)

```
Camera Raw: refuse 16-bit Expand, fix crop placement, wire Horizon/Miniature

Keep Expand from silently dithering deep layers; map expanded footprints from
coverage alone; compose Horizon before framing; enable Release testability.
```
