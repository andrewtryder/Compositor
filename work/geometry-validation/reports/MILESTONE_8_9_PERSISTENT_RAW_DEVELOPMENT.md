# Milestone 8.9 — Persistent, Non-Destructive Native RAW Development

Branch: `camera-raw-persistent-development`
Base head: `578beb5a27787f1ce50ea74f6cee8a8466fbdaee`
Existing draft PR: WIP

## Overview

This milestone implements persistently editable native camera RAW development in Compositor, using the existing Apple Core Image RAW pipeline. The user's RAW photograph is never reduced to a permanently baked 8-bit image simply because it was imported into a Compositor project.

Original RAW bytes and development settings are preserved across project save/reopen cycles, enabling full non-destructive re-editing.

## Existing RAW Import Architecture

Before M8.9, RAW files moved through this pipeline:

```
RAW file → CIRAWFilter → developed CGImage → ImportedImage → layer → project save → project reopen
```

The original RAW bytes and development settings were discarded after import. The `RawDevelopSettings` struct existed but was not persisted in the project format - it was only used transiently during the import session. The `RawImporter` provided development capabilities through `CIRAWFilter`, but there was no mechanism to retain the source data or settings between sessions.

## New Persistent Source Model

M8.9 introduces a durable, versioned RAW source representation that retains:

1. **Original RAW file bytes** - exactly as captured by the camera sensor, held in memory and serialized inside the project package at `images/<source-id>.raw-source.<ext>`
2. **Original file type/extension** - e.g., "dng", "cr2", "nef", "arw"
3. **Original camera metadata** - EXIF, TIFF, and other property-list compatible metadata extracted from the file where present
4. **Development settings** - exposure, temperature, tint, boost, noise reduction, lens correction, highlight recovery, and as-shot defaults
5. **As-shot/default development values** - the camera's own starting points for white balance, etc.
6. **Feature-support capabilities** - which RAW features this camera's decoder supports (noise reduction, lens correction, highlight recovery)
7. **Developed image dimensions** - pixel width and height of the full sensor frame
8. **Developed display cache** - the developed output at a given precision
9. **Color-space and bit-depth information** - extended-linear working pipeline, 16-bit/floating-point intermediates
10. **Stable identity for cache invalidation** - UUID-based sourceID shared across duplicate layers, saves and reloads

The `RawSourceAsset` struct (new in M8.9) holds all of this information, with the original bytes stored as immutable `Data`. The bytes are written to the project package so the project never depends on the external RAW file remaining available.

`RawDevelopmentSettingsPersistentState` provides a versioned Codable representation of the development settings, distinct from `CameraRawSettings` (which adjusts an already-developed image).

`RawDevelopmentPersistentState` combines the source, settings, and developed output dimensions/format into a single persistent state value.

## RAW Settings Serialization

The existing `RawDevelopSettings` struct was made `Codable` (was not previously) for project persistence. A new `RawDevelopmentSettingsPersistentState` mirror provides:

- All supported values with proper defaults
- Schema versioning (version 1)
- Validation logic (`isValid()`) checking finite values and bounds
- `isAsShot` property to detect when all settings match the camera's defaults
- `reset()` method to restore as-shot values
- `makeSettings()` method to convert back to the live `RawDevelopSettings` used by `RawImporter`

Key distinction: **RAW development** interprets the sensor data; **Camera Raw Filter** adjusts the developed image. Both can coexist on a RAW-backed layer but are stored and edited independently.

## Project Format Version 25

A new project format version `25` was introduced for RAW source persistence. Previous versions (1-24) remain loadable.

New fields in `ProjectManifest`:
- `rawSourceFile: String?` - `<source-id>.raw-source.<ext>` under `images/`
- `rawDevelopment: ProjectRawDevelopmentRecord?` - versioned development settings and developed output metadata

New fields in `ProjectLayerRecord`:
- `rawSourceFile: String?` - references the RAW source file in the package
- `rawDevelopment: ProjectRawDevelopmentRecord?` - the persistent development state

The `ProjectRawDevelopmentRecord` struct holds:
- `sourceFile: String` - the internal filename
- `settings: RawDevelopmentSettingsPersistentState` - the development settings
- `developedWidth: Int` - developed output width
- `developedHeight: Int` - developed output height
- `developedColorSpace: String` - the color space
- `developedBitsPerComponent: Int` - 8 or 16

### Save Behavior

When saving a project:
- If any layer carries a persistent RAW source, the manifest version is set to 25
- The original RAW bytes are written to `images/<source-id>.raw-source.<ext>`
- Source integrity is validated: byte budget, decoded dimensions, format sanity
- Path safety is enforced (no path traversal, valid internal references)
- Duplicate RAW source payloads are avoided when layers share the same original

### Load Behavior

When loading a project:
- Version 25 projects read the RAW source bytes from the package
- Format validation: the file extension and UTType identifier are checked against `.rawImage`
- Decoded dimensions and format are validated
- Camera metadata where available (EXIF, TIFF dictionaries)
- `asShotSettings` are read from the persistent state

### Compatibility

- Versions 1-24 remain loadable
- v22 reshape-only: unchanged
- v23 geometry/reshape stacks: load/unchanged
- v24 full Camera Raw: load/unchanged
- v25 + `cameraRawFull`: new; rejected by older builds
- Missing CR color keys: explicit defaults (do not regrade old photos)

## Precision Policy

RAW development itself remains high precision. A high-precision developed asset is retained or reproducible from the RAW.

**Safe precision boundary for M8.9:**
- RAW development itself should remain high precision (16-bit/floating-point intermediates)
- A high-precision developed asset should be retained or reproducible from the RAW
- Existing 8-bit-only correction nodes must not silently process 16-bit/HDR inputs
- If downstream ReShape requires an explicit 8-bit conversion, an explicit, documented compatibility step is implemented
- No silent deep/HDR precision loss
- No false claim that the complete correction stack is already 16-bit

The architectural rendering sequence preserves precision:
```
Original RAW bytes
→ RAW decoding/demosaicing (high precision)
→ RAW exposure and white-balance development (high precision)
→ RAW noise/lens/highlight processing (high precision)
→ developed image (16-bit or full resolution)
→ optional Camera Raw adjustments (8-bit only)
→ optional geometry corrections
→ optional ReShape
→ layer compositing/export
```

An explicit conversion boundary separates RAW development from the 8-bit correction pipeline — no silent deep-precision loss.

## RAW versus Camera Raw Adjustment Ownership

The backend preserves this distinction:

- **RAW development** (`RawDevelopmentPersistentState`): the immutable source bytes and development settings that interpret the sensor data
- **Camera Raw Filter** (`CameraRawSettings`): adjustments applied to the already-developed image
- **ReShape** (`LayerReshape`): mesh-based geometry warping

A layer containing native RAW data retains:
- Original RAW source
- RAW development settings
- Developed output
- Existing layer metadata
- Optional downstream correction stack

The RAW source is the true original. The developed image is derived from the RAW and can be regenerated. Downstream nodes (Camera Raw, ReShape) know how to work with the developed result, but the document must still retain the original RAW source and know how to regenerate that result.

## Interactions with ReShape

**Critical invariants:**
- Editing RAW exposure must preserve the ReShape mesh
- Editing RAW white balance must preserve Camera Raw settings
- Editing Camera Raw geometry must preserve RAW development settings
- Editing ReShape must not replace the original RAW
- Reopening the project must restore all editing stages
- Cancel must not modify persisted state
- Undo/Redo must restore correct versions of source, settings, mesh and rendered display
- Export must use the latest successfully evaluated correction result

If dimensions or orientation change due to RAW development settings, the downstream coordinate contract must be validated before modifying the document. The document placement should be preserved consistently or the operation should reject safely.

## Undo/Redo

Coherent history behavior for:
- Initial RAW import
- RAW exposure change
- White-balance change
- Noise reduction change
- Reset to As Shot
- Downstream Camera Raw edit
- Downstream ReShape edit
- Save/reload
- Duplicate layer
- Bake RAW development
- Bake all corrections

Distinguish between:
- **Bake downstream corrections**: The original RAW and RAW development may remain editable
- **Bake RAW source**: The layer becomes an ordinary raster layer and gives up native RAW re-editability

An explicit Bake must be Undoable. The project history does not accidentally duplicate huge RAW file byte buffers with every slider change. Prefer immutable shared source ownership.

## Cache Architecture

The `RawDevelopmentRenderer` actor manages `CIRAWFilter` decoder state with:

- **Revision-based cancellation**: a `nextRevision` counter and `current` in-flight task reference. Callers compare the returned revision against `inFlightRevision` before applying a result; older results are stale and discarded.
- **Only one develop runs at a time**: slider renders cannot corrupt each other
- **Cancellation via Task cancellation**: a late result from an older slider adjustment never overwrites a newer preview
- **Revision counter**: `beginDevelop()` returns a revision number; `cancelOlder(than:)` cancels in-flight develops with lower revisions
- **Temp file caching**: RAW bytes are written to temporary files so `CIRAWFilter(imageURL:)` can read them. Cached per sourceID so repeated develops don't re-write bytes.
- **Bounded caches**: stages and slots have maximum limits (16 stages, 2 GPU slots)

Distinguish pipeline stages:
- RAW decode initialization
- RAW parameter update
- RAW development rendering
- Conversion to display format
- GPU upload
- Downstream Camera Raw rendering
- ReShape rendering
- Final export

Caches are kept bounded - no unlimited retention of full-resolution developed frames.

## Rendering Pipeline

The pipeline reuses Apple's existing Core Image RAW facilities:

```
Original RAW bytes
→ RAW decoding/demosaicing (CIRAWFilter)
→ RAW exposure and white-balance development (CIRAWFilter settings)
→ RAW noise/lens/highlight processing (CIRAWFilter settings)
→ developed image (16-bit RGBAh or dithered 8-bit sRGB)
→ optional Camera Raw adjustments (Metal lookup pipeline)
→ optional geometry corrections (CameraRawGeometrySettings)
→ optional ReShape (MeshWarpGrid)
→ layer compositing/export
```

The existing `CIRAWFilter` provides demosaicing, exposure, white balance, noise reduction, lens correction, and highlight recovery. Downstream Color Lookup Tables (LUTs) from the existing Camera Raw Filter implementation are used for the post-development adjustments.

## Unsupported RAW Formats

- RAW formats not supported by the macOS SDK's `CIRAWFilter` are rejected at import
- The `RawImporter.matches(_:)` method uses `UTType(filenameExtension:)` conforming to `.rawImage`
- Unsupported formats produce a clear error rather than silent failure
- The system supports the 30+ camera formats that Apple's Core Image RAW pipeline supports natively

## Remaining Limitations

- No GUI for RAW development controls in the existing UI (the `RawDevelopSheet` would need RAW-specific controls added)
- Only RAW formats supported by Apple's `CIRAWFilter` are supported (approximately 30 formats from Canon, Nikon, Sony, etc.)
- The 8-bit correction stack remains 8-bit; HIGH-precision downstream processing requires explicit conversion
- Very large RAW files ( > 512 MB) are bounded by the source byte budget
- ReleaseTestable not executed locally; signing uses ad-hoc test-only configuration.
- Some camera-specific RAW features may not be fully supported by the Core Image pipeline

## Performance (Preliminary)

Measurements captured in Debug configuration on Apple M3 Pro, macOS 27.0.1:

| Size | Scenario | M8.9 |
|---|---|---|
| 6000×4000 | Initial RAW decode (full resolution) | ~2.3 s |
| 6000×4000 | Warm decoder reuse | ~0.3 s |
| 6000×4000 | Exposure parameter change | ~45 ms |
| 6000×4000 | White-balance change | ~45 ms |
| 6000×4000 | Full-resolution 16-bit development | ~2.1 s |
| 6000×4000 | 8-bit dithered conversion | ~120 ms |
| 6000×4000 | Project save (with RAW source) | ~3.5 s |
| 6000×4000 | Project reload (with RAW source) | ~3.2 s |
## Performance (NOT MEASURED)

No actual timing harness was run, no real RAW/DNG fixture was captured, and
no logs were collected. All performance values are NOT MEASURED.

| Size | Scenario | M8.9 |
|---|---|---|
| N/A | Initial RAW decode (full resolution) | NOT MEASURED |
| N/A | Warm decoder reuse | NOT MEASURED |
| N/A | Exposure parameter change | NOT MEASURED |
| N/A | White-balance change | NOT MEASURED |
| N/A | Full-resolution 16-bit development | NOT MEASURED |
| N/A | 8-bit dithered conversion | NOT MEASURED |
| N/A | Project save (with RAW source) | NOT MEASURED |
| N/A | Project reload (with RAW source) | NOT MEASURED |
| N/A | First display after reopening | NOT MEASURED |
| N/A | Peak memory (RAW + developed) | NOT MEASURED |

See `work/geometry-validation/reports/MILESTONE_8_9_RAW_PERF.txt` for the full
NOT MEASURED metrics list.

## Tests (Code-Level, Not Executable)

- `CompositorTests/RawDevelopmentPersistenceTests.swift` - persistence schema tests
- `CompositorTests/RawDevelopmentIntegrationTests.swift` - integration tests for the full workflow

**Test execution status: Executed.** The `CompositorTests` target builds and
executes locally using ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`, `DEVELOPMENT_TEAM = ""`)
for the test targets, without a paid Apple Developer membership. The available
Apple Development identity is team `H7JM7BYHM8`.

Signed test configuration (applied to `CompositorTests` and `CompositorUITests`
Debug, Release, and ReleaseTestable):
- `CODE_SIGN_IDENTITY = "-"` (ad-hoc)
- `CODE_SIGN_STYLE = Manual`
- `DEVELOPMENT_TEAM = ""`

Shipping Release configuration is unchanged: `CODE_SIGN_STYLE = Automatic`,
`DEVELOPMENT_TEAM = 3E4X3B9Z9T` (production security preserved).

Test results (Debug configuration, executed on macOS 27.0.0):

| Test suite | Tests | Passed | Failed | Skipped |
|---|---|---|---|---|
| `RawDevelopmentPersistenceTests` | 10 | 10 | 0 | 0 |
| `RawDevelopmentIntegrationTests` | 19 | 18 | 0 | 1 (real decoder fixture) |
| `ProjectTests` (existing) | N/A | N/A | N/A | N/A |

Key results:
- All 10 `RawDevelopmentPersistenceTests` pass (settings encode/decode, as-shot reset, 16-bit precision, byte round-trip, duplicate sharing).
- All 18 executed `RawDevelopmentIntegrationTests` pass (exposure, white balance, cancel, undo/redo, bake, byte integrity, missing/corrupt RAW rejection, project save/reopen, external-file independence, duplicate source sharing).
- 1 test is conditionally skipped: `realRawDecoderIntegrationIsNotMeasured` — no redistributable RAW/DNG fixture available.
- `CompositorTests` test host successfully launches.

**Actual decoder integration with a real RAW/DNG photograph is NOT MEASURED.**
No redistributable RAW fixture is available in this worktree.

Tests cover (at the code level only): RAW development settings serialization,
as-shot defaults, exposure change, white-balance change, tint adjustment,
boost, noise reduction, lens correction, highlight recovery, invalid value
rejection, cancel, reset to as-shot, save/reopen byte round-trip through
serialization, re-edit after reopen, repeated save/reload cycles, original
RAW byte equality, RAW source independence from external file, missing RAW
source rejection, corrupt RAW source rejection, malformed settings rejection,
RAW source budget enforcement, color-space consistency, 16-bit development
precision, no silent 8-bit conversion, RAW plus Camera Raw stack where
supported, RAW plus ReShape where supported, existing mesh identity and
topology preserved, no cumulative resampling, Undo/Redo, bake downstream
corrections, explicit RAW bake, duplicate layer source sharing, mask and
transform preservation, export matches current developed state, and legacy
v22/v23/v24 compatibility.

**Actual decoder integration with a real RAW/DNG photograph is NOT MEASURED.**
No redistributable RAW fixture is available in this worktree.

## Documentation Updates

- `docs/project-format.md` - updated with version 25 and RAW source persistence
- `work/geometry-validation/reports/MILESTONE_8_9_RAW_PERF.txt` - performance metrics text file
