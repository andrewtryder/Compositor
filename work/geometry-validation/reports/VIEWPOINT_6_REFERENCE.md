# ViewPoint 6.1 reference (hands-on)

Research date: 12 Nov 2026.  
Installed app: `/Applications/DxO ViewPoint 6.app` (also listed as `DxO Viewpoint 6.app` on this volume).  
This report separates **confirmed UI behavior** from **bundle/string declarations**. Nothing proprietary was copied into Compositor. ReShape is not implemented yet.

## Installed version

Confirmed from `Info.plist` via REA `inspect_plist` and Launch Services:

| Field | Value |
| --- | --- |
| Display name | DxO ViewPoint 6 |
| Short version | 6.1 |
| Long version | 6.1.0.699 |
| Bundle id | `com.dxo.dvpv6.standalone` |
| Executable | `DxOViewPoint6` (universal Mach-O; arm64 slice used) |
| Minimum system | macOS 13.3 |
| License material on disk | `~/Library/Application Support/DxO/Licenses/viewpoint6.key` (presence only; contents not read) |

## REA tools actually used

| Tool | Purpose in this session |
| --- | --- |
| `open_binary` | Bind `/Applications/DxO ViewPoint 6.app` |
| `inspect_plist` | Bundle id, versions, document types |
| `observe_native_ui` | Screenshot + accessibility tree for browser and editor |
| `close_binary` | End the Mach-O session when switching |
| `computer_*` (Computer Use) | App-targeted presses for menus, Reset all, Export |
| Shell `strings` on a thinned arm64 slice | Declared module / ReShape names (not live proof) |
| Accessibility (`AXUIElement`) / System Events | Open menus, Export, Save sidecar |
| `screencapture -l` | Window screenshots under `viewpoint6-research/screenshots/` |

Deep providers (`search_strings` via Ghidra/Hopper/Kuna) were unavailable for the universal Mach-O without a thinned reopen; string harvest used `lipo` + `strings` instead and is labeled **declared**.

## What opened successfully

1. Launch showed an Activation window and the image browser. With `viewpoint6.key` present, the **correction editor still opened** for a local JPEG.
2. `open -a "DxO ViewPoint 6" …/window-wall.jpg` loaded the editor titled `DxO ViewPoint 6.1 - window-wall.jpg` at **3648 × 5472 px**.
3. Opening a **folder** via Launch Services produced a dialog: “This file cannot be opened by DxO ViewPoint 6.” Use Open folder in-browser or open a JPEG/TIFF file.
4. PNG is not a declared document type (unchanged vs earlier notes). JPEG and TIFF opened.

## Confirmed editor modules (accessibility)

Right-rail sections observed live:

- Exposure Compensation, White Balance  
- Distortion (Auto Optics Module / Manual)  
- Volume deformation (Horizontal/Vertical, Diagonal)  
- Perspective (Auto, guided tools, Intensity, Auto correct, Up/Down, Left/Right, H/V Ratio)  
- Reshape Fusion (grid presets; expands when a grid is selected)  
- Horizon (Auto, Horizontal Level, Vertical Level, Angle)  
- Crop (Auto, Crop, Aspect Ratio Preserve, Constrain to image)  
- Miniature effect  

Toolbar: Browse, prev/next, compare, Fit, 1:1, flip/rotate, grid overlay, guides, **Export**, Reset all.

### Distortion

Auto help: “Automatic with DxO Optics Module”. On `window-wall.jpg` the panel shows that automated distortion needs information from the original image file, with **Open original image**. JPEG alone did not unlock Optics Module Auto in this session.

### Volume deformation

Live descriptions: **Horizontal/Vertical** and **Diagonal**. Declared binary names also include Radial / Horizontal / Vertical / HV (strings only).

### Perspective — Auto correct modes

The Auto correct menu (opened with `show-menu`) lists exactly:

1. Verticals & Horizontals  
2. Verticals only  
3. Horizontals only  

Declared symbols also include `AutoFullCorrection`, `AutoVerticalCorrection`, `AutoHorizontalCorrection`.

**Automation limitation:** Accessibility `press` on the menu row texts returned success but the MenuButton title often stayed `Verticals & Horizontals`, and three mode screenshots taken that way were **byte-identical**. Mode switching must be treated as **UI-visible but not reliably automation-selected** in this session. Keyboard / coordinate selection needs a follow-up pass.

Manual tools confirmed by description: Force Vertical Parallel, Force Horizontal Parallel, Rectangle, 8 points. Intensity default **100**. Manual Up/Down, Left/Right, H/V Ratio stayed at **0** after Auto (Auto does not mirror into those sliders).

### Horizon and Crop

Horizon Auto / Horizontal Level / Vertical Level / Angle observed.  
Crop Auto / Crop / Aspect Ratio **Preserve** / **Constrain to image** observed.

## Automatic perspective — measured window-wall run

Photograph: `work/geometry-validation/originals/window-wall.jpg` (copy under `viewpoint6-research/input/`).

| Step | Status size readout |
| --- | ---: |
| Reset all | 3648 × 5472 |
| Perspective Auto (Auto correct title showed Verticals & Horizontals) | 4493 × 7035 |
| Crop Auto afterward | 3350 × 5022 |

Interpretation of the intermediate 4493×7035 size: the corrected canvas expands (empty margins) before Crop Auto shrinks to an opaque crop. Aspect scale ≈ **0.918** on each edge; area ratio ≈ **0.843** of the original pixel count.

### Export (on disk)

- Path: `work/geometry-validation/viewpoint6-research/exports/vp6-window-wall-auto-vh.jpg.jpg`  
- Decoded size: **3350 × 5022**, JPEG  
- Export dialog: format JPEG, quality **80**, then a macOS save panel  
- MD5 differs from ViewPoint 5’s `viewpoint/window-wall__auto-full.jpg` (also 3350×5022), so pixels are not identical, but **framing matches** the earlier VP5 Auto Full export dimensions.

**Rule used:** an on-screen correction alone was not counted as a paired comparison; this export file exists and decodes.

### Sidecar

File menu **Save sidecar** wrote:

`viewpoint6-research/input/window-wall.jpg.dvp`

It is a ZIP. Observed JSON keys (no weights copied):

- `manifest.json`: `writer_software=viewpoint`, `writer_version=6.1.0.699`, source name/uuid  
- `private_data/viewpoint.json` parameters seen: `KeystoningMode=Auto`, `CropRatio≈0.666…`  

Other correction state may live inside that private blob; only these keys were inspected.

## Comparison with Compositor (window-wall)

Compositor baseline (Milestone 6, Constrain Crop off in the recorded renders): Auto Full quality gate keeps the **vertical-only** solution; canvas stays **3648×5472** with transparency in empty corners; opaque coverage about **92.7%** for the vertical solution in the M6 report narrative.

ViewPoint 6.1 on the same JPEG (Perspective Auto + Crop Auto, export):

- Shrinks the delivered image to **3350×5022** (~91.8% linear).  
- Bride and both window banks remain in frame (confirmed on screen and in the export dimensions).  
- Does **not** keep the original pixel canvas; Crop Auto is the framing step.  
- Distortion Optics Module Auto was unavailable without the original RAW.

**Do not claim parity.** The shared photographic outcome is that both systems avoid the extreme two-family warp that used to destroy this frame. Representation differs (Compositor: same-size canvas + alpha; ViewPoint: smaller opaque JPEG).

Stone-house and library-atrium were copied into `viewpoint6-research/input/` but **not** run through separate Auto/export cycles in this session.

## Unverified / blocked

- Reliable automation of Auto correct mode switching (Verticals only / Horizontals only / V&H) for separate exports.  
- Forced missing-Metal / Optics Module with a camera-original RAW (none in the validation corpus).  
- Whether Activation UI is required on a machine without `viewpoint6.key`.  
- Pixel-level residual angle measurements on the VP6 export (export exists; quantitative angle compare not run here).  
- Deep decompilation of correction math (providers unavailable for universal binary in-session).

## Screenshots and artifacts (local, gitignored)

Under `work/geometry-validation/viewpoint6-research/` (gitignored):

- `screenshots/` — browser, editor, reshape grids, export dialogs  
- `exports/vp6-window-wall-auto-vh.jpg.jpg`  
- `input/*.jpg` copies + `window-wall.jpg.dvp`  

See also `VIEWPOINT_6_RESHAPE_ANALYSIS.md` and `MILESTONE_8_ARCHITECTURE.md`.
