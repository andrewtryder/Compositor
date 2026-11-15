# M11.0 – M11.3 UI evidence

Subfolders by feature:

| Folder | Expected captures |
| --- | --- |
| `depth-focus/` | Optics › Lens Blur with the Focus picker, showing Focus Region as it always was and Depth Focus with Focal Depth, Depth Range, Set Focus and Show Depth |
| `raw-profiles-raw-details/` | The RAW development editor's White Balance (As Shot / Auto / Custom in K) and Profile rows, and the Raw Details group with the camera's own baseline beside the offsets |
| `local-masks/` | The Masks group below Calibration: the add menu, the mask list, the overlay on the canvas, and the local adjustment sliders |

**These captures are not present.** `CompositorUITests` is blocked on this machine by Automation
Mode authentication, and screen captures come back blank — the same blocker recorded for M10.4,
M10.5, M10.7, M10.8 and M10.9. Nothing here is a programmatically rendered mock presented as a real
screenshot, and none is generated to fill the space.

The accessibility identifiers each capture needs already exist (`lensBlurFocusModePicker`,
`lensBlurShowDepth`, `lensBlurPrepareDepthModel`, `lensBlurSetDepthFocus`, and the mask controls'
labels), so `CompositorUITests/CameraRawSectionOrderTests` and the screenshot steps can take these
images as soon as the automation permission is granted. Until then the manual acceptance gates
stay NOT OBSERVED.

Numbers and photographic evidence that *are* available are measured and reproducible from the test
suites; see `../../reports/M11_0_TO_M11_3_INTEGRATED_DEVELOPMENT.md` §6 and §8.
