# ViewPoint 6 — Backend coverage matrix

Maps ViewPoint-style correction capabilities to Compositor’s Camera Raw geometry backend.
Does **not** claim GUI parity or proprietary DxO behavior.

Branch: `camera-raw-geometry-backend` · PR #6 draft  
Legend: **A** algorithm · **P** pixel verified · **D** document path · **Pr** precision · **S** serialization/Codable · **G** GUI · **—** not implemented

| Capability | A | P | D | Pr | S | G | Notes |
|---|---|---|---|---|---|---|---|
| Manual keystone (V/H/Rotate) | ✓ | ✓ | ✓ | ✓ (8-bit Expand; 16-bit Keep) | ✓ geometry Codable | partial | Existing Geometry sliders |
| Perspective Amount | ✓ | ✓ | ✓ | ✓ | ✓ | partial | Track A / PR #5 |
| Auto Level / Full / etc. | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Ranking unchanged |
| Expand to Fit | ✓ | ✓ | ✓ | refuse deep | ✓ framingMode | ✓ Framing | Deep: coerce Keep |
| Constrain Crop | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | Opaque inscribed |
| Horizon (auto / angle / refs) | ✓ | ✓ | ✓ | ✓ | ✓ Codable | — | Into corners before Expand |
| Vertical guides tool | ✓ | ✓ | ✓ | ✓ | ✓ | — | Pixel warp tested |
| Horizontal guides tool | ✓ | — | ✓ | ✓ | ✓ | — | Solver path; no dedicated pixel suite |
| Combined guides | ✓ | — | ✓ | ✓ | ✓ | — | |
| Rectangle / 4-corner | ✓ | — | ✓ | ✓ | ✓ | — | |
| Eight-point | ✓ | — | ✓ | ✓ | ✓ | — | |
| H/V Ratio | ✓ | ✓ | ✓ | ✓ | ≡ Aspect | — | Alias of Aspect polish |
| Free / aspect crop API | ✓ | partial | API | ✓ | ✓ | — | Opaque auto tested |
| Miniature Effect | ✓ | ✓ | ✓ | ✓ | ✓ Codable | — | After geometry; not projective |
| Volume (prior) | ✓ | ✓ | ✓ | ✓ | ✓ | partial | Milestone 7 |
| ReShape / mesh | — | — | — | — | — | — | PR #4 only |
| AI segmentation | — | — | — | — | — | — | Out of scope |
| ViewPoint toolbar chrome | — | — | — | — | — | — | GUI deferred |

## Document-path integration

Features that **do** run when the user Applies Camera Raw (`PixelFilter.run` → `CameraRawSettings.applyResult`):

1. Existing geometry / upright / volume / framing / Constrain Crop  
2. `perspectiveTools` → guides / keystone via `CameraRawPerspectiveTools.applying`  
3. `horizon` → degrees into `applyResult(..., horizonDegrees:)` before framing  
4. `miniature` → after geometry, before color grade  

Features that are **Codable helpers / API only** until wired above (crop request free-form remains primarily via `CameraRawGeometryBackend.apply` + `CameraRawGeometryCrop`; Constrain Crop on geometry settings is document-integrated):

- `CameraRawGeometryCropRequest` free / aspect / constrained plans beyond Constrain Crop  
- Standalone `CameraRawGeometryBackend.apply` facade (same composition, used by tests / API)

Camera Raw Apply is **destructive**: committed pixels land on the layer. Live smart-filter re-edit of Horizon/Miniature settings is not project-stored as separate filter state beyond what Geometry already persists in filter settings if/when encoded; `automaticHorizonAngle` is explicitly session-only.

## Precision policy

| Layer type | Expand to Fit | Other geometry |
|---|---|---|
| 8-bit | Allowed; placement via coverage | Full |
| 16-bit / HDR (`deep`) | **Rejected** → Keep Original Size | Full precision via `DeepLayer.run` |

Never silently reduce Expand output to 8-bit.

## Release test host

Root cause: Release `Compositor` module lacked `-enable-testing` (`ENABLE_TESTABILITY`).  
Fix: `ENABLE_TESTABILITY = YES` on project Release configuration.  
Result: `CameraRawGeometrySafetyTests` **TEST SUCCEEDED** under `-configuration Release`.

## Explicitly incomplete (do not mark done)

- Advanced ReShape / mesh editing  
- AI subject / sky segmentation  
- Dedicated ViewPoint-style toolbar / Horizon / Miniature / tool UIs  
- Full 16-bit Expand infrastructure  
- Exhaustive per-tool perspective + crop pixel matrices  
- Session Undo/Redo Expand placement e2e
