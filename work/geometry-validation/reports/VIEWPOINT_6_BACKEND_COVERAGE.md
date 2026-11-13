# ViewPoint 6 — Backend coverage matrix

Maps ViewPoint-style correction capabilities to Compositor’s unified geometry backend.
Does **not** claim GUI parity or proprietary DxO behavior.

Branch: `camera-raw-unified-geometry-backend` (integrates PR #6 + PR #10)  
Legend: **A** algorithm · **P** pixel verified · **D** document path · **Pr** precision · **S** serialization · **G** GUI · **—** not implemented

| Capability | A | P | D | Pr | S | G | Notes |
|---|---|---|---|---|---|---|---|
| Manual keystone (V/H/Rotate) | ✓ | ✓ | ✓ | ✓ (8-bit Expand; 16-bit Keep) | ✓ | partial | Camera Raw Geometry |
| Perspective Amount | ✓ | ✓ | ✓ | ✓ | ✓ | partial | PR #5 / #6 |
| Auto Level / Full / etc. | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Ranking unchanged |
| Expand to Fit | ✓ | ✓ | ✓ | refuse deep | ✓ | ✓ | Deep: coerce Keep |
| Constrain Crop | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | |
| Horizon (auto / angle / refs) | ✓ | ✓ | ✓ | ✓ | ✓ | — | Before Expand |
| Perspective tools | ✓ | partial | ✓ | ✓ | ✓ | — | Vertical guides pixel-tested |
| Miniature Effect | ✓ | ✓ | ✓ | ✓ | ✓ | — | After geometry |
| Volume | ✓ | ✓ | ✓ | ✓ | ✓ | partial | Milestone 7 |
| ReShape mesh foundation | ✓ | ✓ | ✓ | 8-bit | ✓ v22 | partial | PR #4–#10 line |
| Adaptive Subdivide / Merge | ✓ | ✓ | ✓ | 8-bit | ✓ | — | |
| Local Perspective / Horizon / Volume | ✓ | ✓ | ✓ | 8-bit | ✓ | — | |
| Persistent ReShape source + mesh | ✓ | ✓ | ✓ | 8-bit | ✓ v22 | — | Re-edit from source |
| Bake-or-refuse vs Camera Raw | ✓ | ✓ | ✓ | — | — | — | Unified contract |
| AI segmentation | — | — | — | — | — | — | Out of scope |
| ViewPoint toolbar chrome | — | — | — | — | — | — | GUI deferred |
| Smart-Filter stack (one layer) | — | — | — | — | — | — | Documented only |

## Domain ownership

- **Global** Camera Raw geometry: `CameraRawGeometryBackend` / `CameraRawSettings.applyResult`
- **Local** mesh: `MeshWarp*` / `LayerReshape` / `UnifiedGeometryBackend`
- Not combined into one oversized renderer

## Precision policy

| Layer type | Expand to Fit | ReShape |
|---|---|---|
| 8-bit | Allowed | Allowed |
| 16-bit / HDR | Refused → Keep Original Size | Refused (convert first) |

## Release test host

Provisional `ENABLE_TESTABILITY = YES` on project Release (required for `@testable import`).  
Shipping builds must not keep testing enabled; prefer a dedicated `ReleaseTestable` configuration before distribution.
