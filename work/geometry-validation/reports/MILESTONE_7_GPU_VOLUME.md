# Milestone 7 — Metal volume deformation

Branch `camera-raw-volume-metal` in `/Users/atr/code/Compositor-volume-metal`, based on `7568a31`. Not committed. The other worktree was not modified. `volumeStrengthScale` is still 0.55. The CPU function `volume_deform` is unchanged and remains the fallback.

ViewPoint 6 notes are in `VIEWPOINT_6_REFERENCE.md`. This milestone does not tune Compositor to those sliders, and it does not add ReShape.

## Architecture

`MetalCameraRawVolume` follows `MetalCameraRawLookup`: the system default device, a compute pipeline compiled with safe math, and two shared buffers reused across slider moves. `CameraRawGeometrySettings.applyVolume` tries that path when the active strength is above zero and the two bitmap rows have the same stride. Identity (strength 0) stays on the CPU byte copy. Any refusal or a failed command buffer falls through to `volume_deform`.

The shader repeats the CPU mapping. Destination pixel `(x, y)` is a pixel center, normalized by half the width and height, passed through `compute_anamorphosis` for mode 0 radial, 1 horizontal, 2 vertical, or 3 horizontal then vertical, then sampled bilinearly. Row `y` is the buffer row, the same index the CPU uses. Out-of-range neighbors add nothing, so the edge fades instead of clamping. Weights multiply the stored premultiplied bytes. `round` matches `lround` on those non-negative sums.

A texture sampler was not used. Hardware sampling clamps and does not match that missing-neighbor rule. The result is still a `CGImage`, because perspective is a Core Image filter on that image. One upload and one readback sit on either side of the kernel. The readback copies only the pixel bytes, so row padding is left as the CPU left it. Sharing the texture into Core Image would remove the readback, and it would also change the perspective handoff. That was left alone.

## Parity

Tolerance: a channel may differ by at most 1 code value. Float `sqrt` and the float strength can sit on the other side of a halfway value from the CPU's double sum. A difference of 2 or more would mean the sample moved. Every compared image stayed inside 1.

Passed on this Mac, Debug (`-Onone`), safe math:

- All four modes at strengths 0, 20, 100, and 200, on 1×1, 2×3, 17×13, 32×48, 48×32, and 64×64.
- A transparent left edge, a partial-alpha gradient with padded rows, and a 1920×1080 grid.
- The editor path `CameraRawGeometrySettings.apply` for all four modes, against a direct `volume_deform` of the same picture. Strength 0 matches the input bytes.
- Warm radial passes at slider 80, maximum channel error 1:

| Size | CPU | GPU end to end | Upload | Command wait | Device | Readback |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1024×1024 | 58.6 ms | 1.6 ms | 0.2 | 1.2 | 0.6 | 0.2 |
| 4000×3000 | 706.6 ms | 12.8 ms | 2.7 | 7.0 | 6.2 | 3.1 |
| 6000×4000 | 1383.2 ms | 24.0 ms | 5.5 | 12.0 | 10.6 | 6.0 |

Those GPU figures are the median of three runs after one discarded pass at that size. The CPU column is the same median for `volume_deform` on the same buffer. End-to-end speedup is about 37×, 55×, and 58×. The device interval is smaller than the end-to-end time because the upload and readback are still on the CPU. The earlier volume baseline on this Mac was 59 / 674 / 1374 ms. This CPU column is that same kernel, not a new algorithm.

A buffer whose stride is shorter than the pixels is refused and left untouched, so the CPU path still owns it. Process resident size around the large runs moved from 788 MB to 681 MB. That is not a clean peak. The retained pair of shared buffers for 6000×4000 RGBA is 183 MiB.

## Tests

`xcodebuild` test of `CameraRawVolumeGPUTests`, `CameraRawTests`, `CameraRawResetTests`, `CameraRawUprightTests`, and `CameraRawUprightComparisonTests/renderPhotographicModes()` succeeded on 12 Nov 2026 (about 271 seconds of testing, Debug).

The photographic canary ran. It was not skipped. Fixture lookup walks from the test source to `work/geometry-validation`, then to linked git worktrees, so the Metal checkout finds the photographs that live only in the other checkout. Those JPEGs are still gitignored and were not staged. Window-wall Auto Full still keeps the vertical correction. The synthetic upright tests passed with it.

`CameraRawTests` covers volume identity, premultiplied volume output, distortion before perspective, and constrain crop.

A later Release run of `CameraRawVolumeGPUTests` also succeeded. That run is the source of the Release timings, the pipeline comparison, and the full-resolution photograph check below.

## Pipeline

`CameraRawSettings.apply` is the function both the preview and OK use. Camera Raw's preview is the full image (`prepared` keeps factor 1 for this filter). OK builds a `FilterJob` and `PixelFilter.run` calls the same `apply`. A test of that job against `apply` matched every byte.

The GPU side of the comparison is that apply path. The CPU side runs `lens_distort` when distortion is on, then `volume_deform`, then the same perspective and constrain-crop code with the volume sliders at 0. On a 360×240 structural grid the maximum channel error stayed within 1 for:

- Volume alone (horizontal and vertical, sliders 120 and 80)
- Volume and perspective (radial 160, vertical 28, horizontal −18)
- Distortion and volume (distortion 40, vertical volume 150)
- Distortion, volume, perspective, and constrain crop

Window-wall (`originals/window-wall.jpg`, 3648×5472) was rendered the same way: distortion 20, radial slider 80, vertical perspective 16, constrain crop on. Output size stayed 3648×5472. Maximum channel error against the CPU pipeline stayed within 1. The GPU image was written as a TIFF, opened again, and matched the image that was written. The TIFF was then deleted. It was not put in the repo. Auto Full on that original still keeps the vertical correction (`kept verticals`). Auto Vertical is not identity.

## CPU fallback

A GPU call that returns false does so before it copies into the destination. The tests cover a zero width, a negative height, a stride shorter than the pixels, and a buffer larger than `maxBufferLength`. The destination bytes stay as they were. A valid apply after the oversized refusal still matches the CPU kernel, so the command queue is usable again.

`applyVolume` treats a false return, a nil `MetalCameraRawVolume.shared`, and a strength of 0 the same way: it calls `volume_deform`. Strength 0 never tries the GPU. This Mac has a device, so a missing device and a shader that fails to compile were not forced. Both throw out of `init` and leave `shared` nil. A command buffer that finishes in any state other than completed is also not copied; that status was not injected, because valid commands on this GPU complete.

## Release performance

Hardware: MacBook Pro, Apple M3 Pro (11 CPU cores, 14-core GPU, Metal 4), 18 GB, macOS 27.0.1 (26A434). The Release test host was compiled `-O` with whole-module optimization and without code coverage. Hardened runtime was off for that launch so the test process could load Sparkle. The benchmark settings match the Debug run: radial slider 80, one discarded pass, then the median of three.

| Size | CPU | GPU end to end | Upload | Command wait | Device | Readback |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1024×1024 | 42.1 ms | 1.7 ms | 0.2 | 1.2 | 0.6 | 0.2 |
| 4000×3000 | 438.7 ms | 12.8 ms | 2.3 | 5.1 | 4.4 | 3.4 |
| 6000×4000 | 782.9 ms | 19.4 ms | 4.8 | 7.4 | 6.7 | 5.1 |

Maximum channel error was 1 at each size. End-to-end, the GPU path is about 25×, 34×, and 40× the Release CPU kernel. The Debug CPU times were 58.6 / 706.6 / 1383.2 ms, so the Release CPU itself is faster and the GPU times barely moved. Resident size around the Release run went from 299 MB to 820 MB. Physical footprint was 744 MB, with a peak of 911 MB. The retained shared buffers for 6000×4000 RGBA are 183 MiB of that. Cold shader compile time is still inside the first use of `MetalCameraRawVolume.shared`, not a separate figure.

## Application smoke

The Release app from this worktree was launched with `window-wall.jpg`. The window stayed 1180×780. The layer opened at 3648×5472, right way up, named window-wall. Filter › Camera Raw Filter opened the docked panel. Geometry was expanded and showed Upright Off, Projection Perspective, Constrain Crop, Volume Mode Radial, and the Horizontal, Vertical, and Radial sliders at 0. While that panel was open, the document controls were disabled.

The sliders were not successfully driven. Accessibility writes changed the reported field value without changing the picture, and typed keystrokes did not commit a strength. No sample of the process showed `MetalCameraRawVolume.apply` on a stack. The four modes, a watched preview, and a GUI export were therefore not confirmed in the window. The processing those controls call is the path measured above.

To finish that check by hand: run the Release app, open window-wall, choose Filter › Camera Raw Filter, expand Geometry, and for Radial, Horizontal, Vertical, and Horizontal & Vertical move the matching slider. Then add a little lens distortion, a vertical perspective slider, and Constrain Crop, and compare OK with the preview. The picture should stay upright, with no new black frame and no opaque fringe.

## Not done

- The live Camera Raw sliders were not moved, so slider feel and a watched export are not a result.
- No camera-original RAW was available, so there is no ViewPoint 6 geometry export. See the ViewPoint 6 note. No further ViewPoint session was run for this checkpoint.
- Cold shader compile time was not split out from the first use of `MetalCameraRawVolume.shared`.
- Core Image still receives a `CGImage`, so the readback remains.
- A missing Metal device, a failed shader compile, and a failed command buffer were not forced on this machine. The code returns before writing the destination in those cases, and the tests cover the refusals that can be made without a second device.

## Proposed commit

`Camera Raw: run volume deformation on Metal and keep the CPU kernel as the fallback.`

- `Compositor/Rendering/MetalCameraRawVolume.swift`
- `Compositor/Document/CameraRawGeometryCalibration.swift`
- `CompositorTests/CameraRawVolumeGPUTests.swift`
- `CompositorTests/GeometryValidationFixtures.swift`
- `CompositorTests/CameraRawUprightTests.swift`
- `CompositorTests/CameraRawUprightComparisonTests.swift`
- `work/geometry-validation/reports/MILESTONE_7_GPU_VOLUME.md`
- `work/geometry-validation/reports/VIEWPOINT_6_REFERENCE.md`

Not included: photographs, ViewPoint exports, generated renders, and the window-placement edits in the other worktree.
