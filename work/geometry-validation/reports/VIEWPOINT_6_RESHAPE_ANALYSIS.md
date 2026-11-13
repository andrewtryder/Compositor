# ViewPoint 6.1 — ReShape Fusion analysis

Companion to `VIEWPOINT_6_REFERENCE.md`. Observations from the live 6.1.0.699 editor on 12 Nov 2026, plus declared strings. No proprietary code or SAM weights were copied.

## How ReShape was reached

1. Open `window-wall.jpg` in the correction editor.  
2. In **Reshape Fusion**, press a Grid preset (`4x4`, `8x8`, `16x16`, `32x32`, or `Custom`).  
3. The panel expands; an overlay mesh appears on the image.

Accessibility descriptions for the five presets were confirmed. Selecting any preset also revealed labels **Sticky borders**, **Propagation**, **AI selection**, and an **AI** checkbox in the accessibility tree.

## Confirmed grid construction

| Control | Observed |
| --- | --- |
| Presets | 4×4, 8×8, 16×16, 32×32, Custom |
| Rows / Columns | Numeric fields (screenshot of 8×8 showed Rows=8, Columns=8) |
| Subdivide Grid | Button present when mesh active |
| Merge Grid | Button present when mesh active |
| Grid coverage | Dropdown; screenshot showed **Inner** |
| Point budget | Status text on 8×8: **81 points used of 10000** |
| Apply / Reset | Bottom bar buttons while mesh editing |

Declared (strings only, not clicked as separate menu items): `warpGrid4x4` … `warpGrid32x32`, `warpGridCustom`, `Could not restore Warp grid`, `GridWarpingActive`.

**Not proven:** freeform addition of arbitrary rows/columns beyond the Rows/Columns fields; per-cell topology edits beyond Subdivide/Merge.

## Control-point and region transforms

When the 8×8 mesh was active, a floating control group showed transform modes:

- **Move** (active in the captured screenshot)  
- **Rotate**  
- **Scale**  
(and a fourth icon in the same strip; treat as present but not named in accessibility)

Screenshot evidence: blue control points at intersections; mesh rectangular before user drag.

**Not completed in this session:** a measured before/after drag of a single point with recorded coordinates. AX does not expose individual mesh handles as separate elements, so Computer Use / raw pointer input is required for displacement trials. That remains a follow-up measurement.

Declared undo names: `ReshapeMoveUndoCommand`, `ReshapeSliderUndoCommand`, “Warp reshape changed”, “Reset points” dialog copy.

## Sticky borders and propagation

| Control | Observed |
| --- | --- |
| Sticky borders | Checkbox in the floating ReShape panel (unchecked in the 8×8 screenshot) |
| Propagation | Slider in the floating panel (at minimum in that screenshot) |

Declared symbols: `onStickyBordersChanged`, `Sticky border`, `propagationValueChanged`, `TransformationWithPropagation`, `WarpGrid::propagation+`.

**Behavior:** not measured with a controlled drag. Do not invent falloff math from the slider alone.

## Selection and subject-aware UI

Observed when mesh active:

- Rectangular and free-form selection icons  
- **AI** control / **AI selection** checkbox  
- Mask color / grid color swatches  
- Mode toggles for grid vs mask visibility  
- “Show settings” checkbox  

Bundle resources (declared presence, not runtime proof of quality):

- `Contents/Resources/SAM/{Decoder,Encoder,Matting}/20260702163542/`  
- Strings: `[SAM] AI mode`, `SAMInteractionController`, `SAMModelManager`, `ensureSAMAgentReady: no image loaded`, etc.

**Confirmed:** the UI exposes AI selection controls and ships SAM-named resources.  
**Not confirmed:** successful subject segmentation on a person, mask refinement quality, or that SAM runs without additional licensing/download. Milestone 9 should treat subject-aware features as a separate deliverable.

## Interaction with global perspective

- Perspective and ReShape appear as **sibling modules** in the same editor rail.  
- Declared strings include `DisabledWithKeystoningAuto` and `skipWarp` — not exercised.  
- Sidecar after Perspective Auto + Crop Auto stored `KeystoningMode=Auto` and `CropRatio`; it did **not** show ReShape keys in the inspected JSON (ReShape was not Applied in that save).  
- Pipeline order (perspective before/after warp at export) was **not** isolated experimentally.

## Undo, Apply, persistence

| Action | Observed |
| --- | --- |
| Mesh Apply / Reset | Buttons present while editing |
| Reset all | Clears tools; size returned to 3648×5472 when used earlier |
| Save sidecar | Writes `.dvp` ZIP beside the source |
| Export | Separate “Export image as” dialog (JPEG quality, then save panel) |

Granularity of undo for individual points vs whole mesh: **not measured**.

## Automation notes for ReShape

- Grid presets are AX checkboxes with descriptions `4x4`…`Custom` — presses work.  
- Mesh vertices are **not** in the accessibility tree.  
- Sticky borders / Propagation appear only after a grid is selected.  
- Prefer window screenshots + pointer automation for displacement studies.

## Implications for Compositor (clean-room)

Useful interaction concepts to reproduce with our own math:

1. Discrete grid presets plus custom row/column counts.  
2. Subdivide / merge as topology edits.  
3. Move / rotate / scale operating on a selection of points or a region.  
4. Sticky borders and a propagation/falloff strength.  
5. Explicit Apply vs live preview, with a high point budget ceiling.  
6. Keep AI masks for Milestone 9.

Do not port DxO shaders, SAM weights, or sidecar schemas.
