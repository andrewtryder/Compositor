# Milestone 8.7 — Non-Destructive Geometry Correction Stack

Worktree: `/Users/atr/code/Compositor-nondestructive-geometry`  
Branch: `camera-raw-nondestructive-geometry`  
Base: unified geometry `01513cdd26660a53a1227c2eaa4f5fb95cb1e2c3` (PR #11)

## Correction-stack architecture

`LayerCorrectionStack` on `ImageLayer` owns:

- Immutable 8-bit source (`ImportedImage`)
- Ordered `LayerCorrectionNode` list (`cameraRawGeometry`, `reshape`)
- Session-only stage caches invalidated from the edited node onward

`LayerReshape` remains as a projection of the reshape node for MeshWarp tooling and v22 dual-write. There is no second competing layer model.

Rendering (`LayerCorrectionRenderer`) always evaluates from the immutable source. Parameter edits do not resample the source into itself.

## Supported operation orders

| Order | Status |
| --- | --- |
| Identity / empty stack | Supported |
| Camera Raw geometry only | Supported (Keep Original Size) |
| ReShape only | Supported (still saves as v22 reshape) |
| Camera Raw → ReShape | Supported (dimension-preserving) |
| ReShape → Camera Raw | Supported (dimension-preserving) |
| Expand to Fit + ReShape | **Refused** (`LayerCorrectionError.expandWithReshape`) |
| Full Camera Raw color grade as a stack node | **Not persisted** (geometry-family only) |
| Deep / HDR stacks | **Refused** |

## Backend operations

`EditorSession` APIs: `addCorrection`, `editCorrection`, `setCorrectionEnabled`, `resetCorrection`, `removeCorrection`, `reorderCorrection`, `bakeCorrection`, `bakeAllCorrections`, plus MeshWarp Apply that updates the reshape node without discarding Camera Raw settings.

Destructive Filters / painting / Levels / Hue-Sat still refuse until Bake.

## Undo / Redo

Every successful document-level stack mutation is one `DocumentHistory` entry. Cancel MeshWarp leaves the stack unchanged.

## Project format

- `ProjectManifest.current = 23`
- Reshape-only packages still write **v22** (`reshape` only)
- Multi-node / Camera Raw stacks write **v23** (`correctionStack` + reshape dual-write when needed)
- v22 reshape-only loads synthesize an in-memory stack for ND ops
- Corrupt stack/source rejected without installing

## Precision and coordinates

- 8-bit raster only for stacks
- ReShape mesh dimensions must match the node's input stage
- No silent mesh remapping across size-changing stages
- Ordinary Expand on non-stack layers unchanged

## Apply / export performance (measured)

See `MILESTONE_8_7_PERF.txt`. Highlights (medians):

| Size | `commitImage` (Metal) | CPU raster fallback | Two-node stack (no cache) | Cache hit |
| --- | ---: | ---: | ---: | ---: |
| 1024² | ~12 ms | ~2131 ms | ~800 ms | ~0.04 ms |
| 4000×3000 | ~133 ms | ~24902 ms | ~9012 ms | ~0.08 ms |
| 6000×4000 | ~234 ms | ~47701 ms | ~16673 ms | ~0.12 ms |

`MeshWarpEdit.commitImage()` uses Metal when available (`usedMetal=true`). CPU times are fallback/raster only and must not be treated as normal Apply latency. Two-node stack times include Camera Raw geometry + mesh; cache hits skip recompute.

## Shipping build configuration

- Production **Release**: `ENABLE_TESTABILITY = NO`
- New **ReleaseTestable**: Release optimizations + `ENABLE_TESTABILITY = YES` for `@testable` suites

## Validation

- Debug: `NonDestructiveGeometryStackTests` (all passed)
- Debug: retained `UnifiedGeometryBackendTests` + `MeshWarpPersistenceTests` (passed)
- Perf: `NonDestructiveGeometryPerformanceTests` (passed; wrote PERF.txt)
- ReleaseTestable: focused stack suite (see PR notes)

## Remaining backend gaps

- No polished Photoshop-style GUI / Smart Filter panel
- No full Camera Raw color-grade node persistence
- No Expand↔ReShape remapping
- No deep/HDR ReShape or 16-bit Expand in stacks
- Merge / paint / destructive filters still require Bake
- Shared GPU preview scheduler across CR+mesh stages not unified beyond per-stage Metal mesh
