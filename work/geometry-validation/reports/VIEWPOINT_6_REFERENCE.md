# ViewPoint 6 reference

Installed build inspected on this Mac on 12 Nov 2026. Observations from the running application are separate from strings and document types found in the application bundle. Nothing here was copied into Compositor, and ReShape is not part of Milestone 7.

## Installed version

Confirmed from `Contents/Info.plist` of `/Applications/DxO Viewpoint 6.app` (the same bundle as `DxO ViewPoint 6.app`):

- Display name: DxO ViewPoint 6
- Short version: 6.1
- Long version: 6.1.0.699
- Bundle id: `com.dxo.dvpv6.standalone`
- Executable: `DxOViewPoint6` (universal Mach-O; the opened slice is arm64)
- Minimum system: macOS 13.3
- Copyright string: (c) 2026, DxO Labs
- UI toolkit declared by `qt.conf`: Qt
- `NSAppleScriptEnabled` is absent. No scripting dictionary was found in the plist.

ViewPoint 5.15, used for the earlier window-wall export, is a different application (`com.dxo.dvpv5.standalone`). Its JPEG/TIFF save behavior does not describe this build.

## What the running application showed

The process was already running (pid 46748). The on-screen window titled "DxO ViewPoint 6.1" is a dark thumbnail browser. It showed the ViewPoint sample set, including the window-wall photograph, with a folder sidebar, a sort control, and a thumbnail-size control. A second window was titled "DxO ViewPoint 6 Activation".

Accessibility did not return a usable tree for that window (Qt). REA's native UI observer rejected the window id as not belonging to the process it had bound. Clicks were refused because the window was off the current Space. Opening a synthetic TIFF with Launch Services did not replace the browser. The activation window was left as it was.

So this session did not reach the correction editor. Volume sliders, perspective tools, ReShape, crop, and export were not operated. The items below that come from the binary are labeled as declared, not as watched behavior.

## Declared file types

`CFBundleDocumentTypes` names these extensions. This is what the bundle claims it can open. It was not confirmed by opening a camera-original RAW, because the validation workspace has none.

- JPEG: jpe, jpg, jpeg
- TIFF: tiff, tif
- DNG: dng
- RAW: CR2, CR3, ORF, ORI, RW2, RWL, NRW, NEF, CRW, MRW, ARW, RAF, PEF, MCR, SRW
- DXO

PNG is not a declared type. ViewPoint 5's earlier session also did not take PNG. That part matches. RAW and DNG as document types are new relative to what we exercised on ViewPoint 5. They are not yet confirmed by a successful open in 6.1.0.699.

## Declared correction modules

These names are user-facing strings and icon paths in the 6.1.0.699 executable. They describe the build's interface. They are not a record of using the controls.

**Lens distortion.** Strings include auto, manual, barrel, pincushion, and fisheye, plus "Activate auto distortion correction" and a module-status set of icons (ok, download, update, folder). Distortion can be discussed separately from volume: the bundle has both `CDistortionCorrection` and `CAnamorphosisCorrection`. Whether the installed editor lets you turn distortion off while volume stays on was not clicked.

**Volume deformation.** The label "Volume Deformation" is present. Mode names in the binary: `AnamorphosisRadial`, `AnamorphosisHorizontal`, `AnamorphosisVertical`, and an HV tool ("Horizontal / Vertical", icon `volume_deformation_HV`). A diagonal icon is `volume_deformation_diagonal`. There is also "Horizontal intensity". A string `DistortionAnamorphosisKeepEntireImage` exists. No slider range was read from the live panel.

**Perspective.** Strings include Horizon (horizontal and vertical tools), Keystoning, "Verticals & Horizontals", "Horizontals only", an 8-point tool, and a rectangle tool. `KeystoningBlendingIntensity`, `KeystoningKeepCenter`, and `KeystoningKeepOriginalSize` are present. "Automatic mode is only available for Perspective and Horizon tool" is present. ViewPoint 5's earlier log used a Keystoning action named AutoFull with the UI label "Verticals & Horizontals". The same label exists here. The 6.1 intensity and crop behavior were not remeasured.

**Crop and framing.** `CCropSettings` is in the binary. `KeystoningKeepOriginalSize` suggests an option to keep the original canvas, which ViewPoint 5 did not do on the window-wall JPEG (that export was 3350×5022 from 3648×5472). Whether 6.1 defaults to shrinking the canvas was not checked.

## Save and export, as declared

- "Export image as" and `CExportDialog` are present.
- A DNG save task and strings `DNGExport`, `dngHighFidelityCompression`, and "Cannot stamp the Software tag for the DNG" are present. High-fidelity DNG is declared. It was not produced.
- JPEG and TIFF are document types. The export dialog's actual format list was not opened, so the installed choices for those formats are not listed here.
- ViewPoint 5 wrote a file only when its log said `onImageSaveComplete` and the file was on disk. That rule still applies. No 6.1 export was produced in this session.
- Sidecar behavior was not observed. No new file appeared beside the synthetic TIFF because the editor did not open it.

## ReShape Fusion, as declared

Not implemented in Compositor. Confirmed only as content of this build:

- The word "ReShape", undo commands `ReshapeMoveUndoCommand` and `ReshapeSliderUndoCommand`, and "Warp reshape changed".
- Grid presets named `warpGrid4x4`, `warpGrid8x8`, `warpGrid16x16`, `warpGrid32x32`, and `warpGridCustom`, with matching idle icons.
- Move, resize, and rotate warp cursors.
- "Sticky border" / "Sticky borders changed".
- Propagation (`propagationValueChanged`, `TransformationWithPropagation`).
- `warp_sam`, and a `SAM` resource folder containing `Decoder`, `Encoder`, and `Matting` (dated folder `20260702163542`). That is the bundle's subject-selection material. The weights were not read, and no selection was made on screen.
- "Could not restore Warp grid" and `GridWarpingActive` exist. Local subdivision, falloff shape, and how a selection boundary is drawn were not seen.

Interaction between ReShape and global perspective was not exercised. `skipWarp` and `DisabledWithKeystoningAuto` are strings only.

## Comparison with ViewPoint 5

| Topic | ViewPoint 5.15, previously observed | ViewPoint 6.1.0.699 |
| --- | --- | --- |
| Version | 5.15, opened and exported | 6.1.0.699, browser observed, editor blocked by the activation window |
| Window-wall export | JPEG 3350×5022, on disk | Not exported |
| Perspective label | "Verticals & Horizontals" used | Same label is in the binary; not clicked |
| RAW open | Not attempted | Declared for many RAW extensions; no camera-original file is in the validation workspace |
| ReShape / SAM | Not part of that study | Declared, including grid sizes and a SAM folder; not operated |

## Relevant to Compositor, and still open

Compositor's volume modes stay radial, horizontal, vertical, and horizontal-plus-vertical. ViewPoint's declared set uses those names plus an HV control and a diagonal icon. Matching slider values is out of scope for Milestone 7. `volumeStrengthScale` stays 0.55.

Open questions, all unverified in the running 6.1 editor:

- Does a camera-original RAW open, and which lens fields are shown?
- Can distortion be off while volume is on?
- What are the live volume mode buttons and the slider limits?
- Does perspective run before or after volume, and does intensity blend like `KeystoningBlendingIntensity`?
- Does crop keep the original canvas or shrink it the way 5.15 did?
- Which TIFF, JPEG, and DNG options does Export actually offer, and does a save write a sidecar?
- For ReShape: is 4×4 through 32×32 the grid the user sees, can one cell subdivide, and does SAM matting drive the selection?

## Automation

Not reliable in this session. The browser window was off-Space, the accessibility tree was empty, and an activation window was in front. ViewPoint 5's AppleScript and menu clicking were already a poor batch API. This build has no scripting flag in its plist. Do not treat coordinates from the 5.15 session as valid here.
