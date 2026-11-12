# Milestone 6 validation

Date: 12 November 2026. Branch `camera-raw-geometry-upright`. Baseline `2132f173d9ad8e4eb3eee0ca2456c938217ec4a5`.

This is not a claim of DxO ViewPoint parity. ViewPoint 5.15 is installed and opens. Two exports were checked on disk: the synthetic interior TIFF, and `viewpoint/window-wall__auto-full.jpg`. Those runs use different framing and different commands from Compositor. They are not a parity result.

## Architecture

Auto upright still ends in the existing `CameraRawPerspective` homography and the same four-corner `CIPerspectiveTransform`. Nothing new is written into a `.comp` file. Detection diagnostics stay in memory.

`CameraRawUprightDetection` is a thin facade. `CameraRawUprightEstimation` does the work and returns a `CameraRawUprightObservation`: guides, mode, confidence, residual, supporting-line count, fallback (`none`, `vertical`, `level`, `identity`), timings, and a short note. Guided corrections, volume, lens order, and Constrain Crop are unchanged.

Switching Guided to Auto stashes the drawn guides on the filter session and restores them when Guided is selected again. A failed Auto replaces the live guides with nothing. It does not clear that stash, and it does not run while a commit is in progress or after the preview version or mode has changed.

## Algorithms

Analysis long side is 480 pixels. The previous detector used 160 and kept the longest Hough pair.

1. Resample, grayscale, Sobel. An edge pixel needs magnitude at least 28.
2. Group pixels whose undirected tangent is within about 0.22 radians of the seed. Fit each group with PCA. Drop segments shorter than 7 percent of the long side, then suppress near-duplicates within 4 degrees and 2.5 percent of the short side. Keep at most 64.
3. Split segments into a vertical family and a horizontal family using undirected angle. A line within 38 degrees of horizontal is horizontal. A line within 38 degrees of vertical is vertical. Diagonals vote for neither.
4. Fit one vanishing point per family. With 40 lines or fewer, every pair is tried, so the tests are exact. Otherwise a seeded LCG (`0xC0FFEE`) draws pairs. A pair must be separated by at least 12 percent of the relevant side. An intersection inside the frame, expanded by 25 percent, is a crossing and is rejected. No intersection means the lines are parallel and the point is at infinity.
5. Inliers are lines within 2.5 degrees of the model. The point is refined by least squares on the inliers when that point stays far from the frame. Confidence is `0.5 * tightness + 0.25 * support + 0.25 * coverage`, and a fit below 0.45 is discarded.
6. The kept lines become ordinary guides. Auto Level emits one guide at the inlier mean angle, using the same pixel length on both axes so a wide frame does not flatten the roll. Auto Vertical emits two well-separated verticals. Auto Full emits two of each.
7. `accept` keeps a solution only when `CameraRawPerspective` puts those guides on their axes within 1.25 degrees. Auto Full that fails that test retries the vertical pair, then one horizon, then identity.

The solver treats a vanishing point as near when it lies inside a 20 percent margin around the frame. It used to be 35 percent, which refused a normal wide-angle wall whose meeting point sits just above the picture. `isPlausible` still refuses a non-convex or extreme homography.

## Confidence

Confidence is geometric, not a raw edge count. Tightness is how far the inlier residual is below 2.5 degrees. Support saturates at five inliers. Coverage saturates when the inliers span about 35 percent of the frame. Two clean, separated lines can pass. A crowd of short or stacked edges cannot, because spread below 0.12 is rejected before the score is used.

## Tests

`CameraRawUprightTests` passed in this session: outliers and reversed endpoints, nearly parallel lines left as a roll, Auto Vertical under 1 degree on a known wall pair, Auto Level as a single guide that keeps the two sides parallel, Auto Full with a vertical-only fallback and an empty-image identity, diagonals, a non-square frame, stale detection, and the 160 versus 480 timing check.

These existing geometry tests also passed: guided upright, homography paths and keystone isolation, bounded guides and vanishing points, distortion applied once, Constrain Crop, blank Auto, and geometry reset keeping focal length and sensor width.

Synthetic corpus, judged by looking at the rendered pixels. The automatic edge score is not quoted: after a rotation it locks onto the new black frame edge and reports that edge's angle instead of the drawn line.

| Image | Auto Full decision | What the render shows |
| --- | --- | --- |
| Strong verticals, vanishing point above the frame | Vertical, confidence 0.95, 4 lines | The four walls are plumb. About 84 percent of the frame is still picture. |
| Mild verticals | Vertical, confidence 0.95 | Walls plumb. About 94 percent retained. |
| Interior grid, both families | Both families, confidence 0.78 | Verticals plumb and horizontals level. About 88 percent retained. |
| Wide grid, vanishing point close above the frame | Verticals kept, confidence 0.85, 5 lines | Walls plumb. Horizontals still converge. The two-family rectangle was refused. About 75 percent retained. |
| Tilted horizon, no verticals | Level, confidence 0.73 | Both lines are level. |
| Long diagonals plus two short near-verticals | Vertical, confidence 0.85 | The short lines are plumb. The diagonals stay diagonal. |
| Smooth gradient | Identity | Unchanged. |
| Portrait frame, verticals only | Vertical, confidence 0.92 | Walls plumb. |
| Off-center vanishing point | Vertical, confidence 0.69 | Vertical correction, lower confidence. |

## Photographs

Three DxO ViewPoint 5 sample JPEGs were resized to a 1600-pixel long side and re-encoded as PNG without camera metadata, so neither app is asked to apply a lens module. They live under `work/geometry-validation/input/` and are gitignored. Compositor Auto Full, with volume and Constrain Crop off:

- `photo-vertical-landscape.png`, the stone house. Identity. The facade is already close to upright and most of the strong edges are foliage. The detector left it alone.
- `photo-vertical-portrait.png`, the window wall. Both families, confidence 0.89, 11 supporting lines. The mullions come out vertical. The warp is large: about 68 percent of the frame is still picture, and the lower left is empty.
- `photo-eight-point.png`, the library atrium. Level only, confidence 0.88, and the picture barely moves (99.8 percent opaque). Stairs and railings did not produce a rectangle the solver would accept.

## ViewPoint

ViewPoint 5.15.0 is open on the resized window. Its image browser does not list PNG, so the corpus was converted to TIFF in `work/geometry-validation/for-viewpoint/` (gitignored, including the sample photos). One file has been exported. The other eleven have not.

`synthetic-interior`, Perspective Auto, intensity 100, Auto correct set to Verticals & Horizontals. Distortion stayed off because the TIFF has no lens module. Volume deformation stayed off. ViewPoint reported Crop as Auto and warned that the EXIF did not allow a fully automatic correction. The export is `work/geometry-validation/viewpoint/synthetic-interior.tiff` (1074×716, a uniform scale of the 1200×800 frame) and a PNG copy of that file.

Line tilt, measured on the dark strokes:

| | Horizontal lines | Vertical lines |
| --- | --- | --- |
| Input | +6.1° to −4.2° | −18° to +15° |
| ViewPoint Auto | within 0.08° | −17° to +22° |
| Compositor Auto Full | within 0.13° | within 0.33° |

ViewPoint leveled the horizontals and left the vertical convergence. Compositor straightened both, and its render keeps the empty corners because Constrain Crop was off. This is one synthetic without camera metadata. It is not a ViewPoint parity result, and it says nothing yet about the three photographs.

## Performance

Detection only, on this Mac, one Auto Full pass. Rendering is not included. Fit and solve are negligible next to the line extraction.

| Picture | Extraction | Vanishing fit | Solve |
| --- | --- | --- | --- |
| 1200×800 synthetic | 200–290 ms | under 1 ms | under 1 ms |
| 1600-pixel photograph | 720–900 ms | 0–3.5 ms | 0–1.5 ms |

Running Level, Vertical, and Full separately repeats the extraction. A single mode is the right interactive cost. Peak memory was not sampled. The analysis image is at most 480 pixels on the long side.

## Limitations

- A very close vertical vanishing point is corrected as verticals only. The combined rectangle was still refused on the wide synthetic grid, so horizontal convergence remains.
- A foliage-heavy facade with mild convergence is declined.
- A busy atrium with stairs falls back to a level that does almost nothing.
- The portrait window wall's two-family warp is no longer selected. Auto Full keeps the vertical correction. The vaulted ceiling is a likely reason the three horizontal lines wanted a much stronger warp; the line coordinates were not logged, so that part is an interpretation.
- Shallow horizons depend on the segment fitter. The tilted synthetic did level, but a line that fragments into horizontal pieces would be treated as already level.
- ViewPoint exports on disk are the synthetic interior TIFF and `viewpoint/window-wall__auto-full.jpg`. Stone house and the library were not opened in ViewPoint.

## Live Photographic Differential Testing — ViewPoint 5.15 vs Compositor

This section is measured results only. A file is a comparison only when its pixels were opened and checked. An on-screen ViewPoint correction that never produced an export is not a paired result.

Volume and Constrain Crop were off in Compositor. In ViewPoint, Distortion and Volume deformation were left off. ViewPoint's log marks the Crop module active as soon as an image opens. The displayed pixel size changed after Perspective Auto, so a crop or rescale may be part of that command. It was not separately switched off.

### Sources

The three photographs are DxO ViewPoint 5 sample JPEGs. Copies with the same bytes are in `work/geometry-validation/originals/` (gitignored). Photoshop 25.7 is in the Software tag of the two Canon files, so those are edited JPEGs that still carry camera EXIF, not untouched camera files. None of the three has a 35 mm-equivalent tag.

| Id | Original file | Size | Camera | Lens / focal length | Profile | SHA-256 |
| --- | --- | --- | --- | --- | --- | --- |
| stone-house | `05-Perspective-Vertical-Tutorial-Kevin_Barre.jpg` | 5472×3648 | Canon EOS 6D | Tokina AT-X 16-28 F2.8 PRO FX, 16 mm | sRGB | `9587668d50d849c107e99940deb6d3885355acf7cfed81aee059a8360ec76d58` |
| window-wall | `06-Perspective-Vertical-Tutorial-Kevin_Barre.jpg` | 3648×5472 | Canon EOS 6D | 24-70mm F2.8 DG OS HSM \| Art 017, 24 mm | sRGB | `89816b56c806af3a9b9991b0224b6b2764c4ffa73d632aa01acb86333616b0de` |
| library-atrium | `12-Perspective-8Points-Tutorial-Martijn_Kort.jpg` | 7952×5304 | none in the file | none | Adobe RGB | `f833d5bb7ec8ae03cfaf437b24d238ddf9b2cd0b72315e01f567e357ef1a631c` |

The metadata-stripped derivatives are separate cases: `input/photo-vertical-landscape.png` (1600×1067), `input/photo-vertical-portrait.png` (1067×1600), and `input/photo-eight-point.png` (1600×1067). They have no camera EXIF. ViewPoint's browser does not list PNG, so those derivatives were not opened in ViewPoint during this pass.

### What was completed

Compositor rendered Auto Level, Auto Vertical, and Auto Full for all six cases (three JPEGs and three stripped PNGs), again after the quality gate. Volume stayed at zero and Constrain Crop stayed off. The observations are in `reports/photo-modes.json`. The new renders are in `compositor/`. The pre-gate renders are in `compositor/before/`.

ViewPoint 5.15 opened `window-wall.jpg`. The title and the size readout were `3648 × 5472`. Distortion showed the message that automatic correction needs the original image before it can be applied, and the log left Distortion false with an empty CAF id (`No CalibrationContext provided`). Volume deformation was off. Perspective Auto was on, with Auto correct set to Verticals & Horizontals and intensity at 100. The log names that command `AutoFullCorrection`. After it ran, the size readout was `3350 × 5022`, the same aspect ratio scaled to about 0.92. The on-screen picture still contained the bride and both banks of windows. There was no EXIF warning of the kind the synthetic TIFF produced.

The export is on disk: `viewpoint/window-wall__auto-full.jpg`, 3.8 MB, 3350×5022, JPEG, sRGB. The log line that counts is `onImageSaveComplete` from the external saver, naming that path. An earlier `Image saved` analytics event was not treated as proof. The format popup was left on JPEG, so this is not a TIFF. Stone house and the library were not opened in ViewPoint.

### Why Auto Full used to wreck the window wall

The old gate kept a two-family homography as soon as the four representative guides sat within 1.25° of the axes. On this JPEG they do: the residual is 0. That does not mean the rectangle is a good photograph.

The vertical family has 8 lines and confidence 0.918. The horizontal family has 3 lines. The rectangle built from those guides fills 0.766 of the output frame, against 0.936 for the vertical-only homography. The gate's preservation loss is 0.330, the worse of that empty-frame gap and the fraction of source samples pushed outside the canvas. The horizontal lines are still 21.25° off (median) after the vertical correction, so the extra alignment is large, not negligible. Three lines are not enough support to spend that much of the picture. The vaulted ceiling is the likely source of those lines. That last sentence is an interpretation; the coordinates of the three lines were not logged.

The stripped 1600-pixel PNG is the same decision with different numbers: full coverage 0.681 versus vertical 0.880, horizontal gain 11.03°, preservation loss 0.200. It is not the same measurement as the JPEG.

### What Auto Full does now

Auto Full solves four candidates from one line extraction: both families, vertical only, level only, and identity. It keeps the two-family warp only when the degrees it adds over the simpler candidate are worth the frame it spends.

Loss is the worse of empty output corners and source samples that land outside the frame. A 24×24 grid estimates both. It does not know that a person matters more than a ceiling. The inscribed rectangle is recorded and is what Constrain Crop would keep. It is not the ranking score, because a small roll shrinks that rectangle without being a bad keystone.

The schedule, in `fullIsWorth`:

| Frame spent | Extra alignment required |
| --- | --- |
| 6% or less | 0.75° |
| 12% or less | 4° |
| 22% or less | 12° |
| more than that | 18°, and at least half the frame still filled |

A family of fewer than four lines may not spend more than 10% of the frame. Two lines define the rectangle; a third is not confirmation enough for a large hole. Auto Level, Auto Vertical, and Guided are not ranked this way.

On the window-wall JPEG the thin-family rule is what rejects the warp. The degree schedule alone would still accept it, because 21° clears the 18° bar and the frame is still 77% filled. The stripped PNG would be rejected by the schedule as well (11° for a 20% loss).

### Window wall, before and after

Compositor, volume and Constrain Crop off. Opaque fraction is the rendered alpha. Coverage is the grid.

| | Before Auto Full | After Auto Full | Auto Vertical |
| --- | --- | --- | --- |
| Decision | both families, 4 guides | kept verticals, 2 guides | vertical vanishing point, 2 guides |
| Confidence | 0.892 | 0.918 | 0.918 |
| Grid coverage | 0.766 | 0.936 | 0.936 |
| Rendered opaque | 0.764 | 0.927 | 0.927 |
| What you see | black wedge on the left | mullions upright, small corner gaps | the same correction |

The bad warp is fixed on this file, and on the stripped PNG (Auto Full opaque 0.875, matching Auto Vertical). Auto Level is unchanged: a small roll, opaque 0.979.

ViewPoint's verified JPEG keeps the bride and both window banks, with no black wedge. The mullions look upright. The canvas is 3350×5022 rather than 3648×5472, a uniform scale of about 0.918, and the pixels are opaque. Compositor keeps the original canvas and leaves the corners empty because Constrain Crop is off. Those are not the same framing. ViewPoint's command was Perspective Auto with Verticals & Horizontals. Compositor's Auto Full on this file is now the vertical candidate. The commands are not equivalent, and this is not a claim of parity.

An edge-orientation median on the ViewPoint JPEG stays about 8° from vertical. The same sample on the source JPEG was 8.1°. Wood, foliage, and the dress dominate that population. It is not used as the geometric score.

### Stone house and library

Stone house, JPEG and stripped PNG, all three modes: identity. Notes are `no horizon`, `no verticals`, and `no structure`. The facade is declined rather than warped. An edge-orientation sample of the JPEG still has a median of about 12° from vertical, because foliage and roof edges are in that sample. The detector did not turn those into a vanishing point. ViewPoint was not run on this file.

Library atrium, JPEG and stripped PNG: Auto Vertical is identity (`no verticals`). Auto Level and Auto Full are the same roll, confidence 0.922 on the JPEG and 0.880 on the PNG, opaque fraction 0.989 and 0.998. Auto Full's note is `full fell back to level`. The atrium is not rectified. The JPEG has no camera EXIF, so this is not an EXIF effect. ViewPoint was not run on this file.

### Edge measurement

`measure-geometry.swift` summarizes strong edges within 25° of an axis by median and 90th-percentile deviation. On the photographs that population includes wood grain, foliage, stairs, and the dress, so the median does not fall to zero when the mullions are straight. It is recorded in `reports/edge-stats.json` and is not a pass/fail score. The synthetic grid still uses the line fit from the earlier section, which follows the drawn strokes.

Ranking the candidates took 10.6 ms on the window-wall JPEG. Line extraction on the same call took 722 ms. The gate does not extract lines again.

### Status

- Completed synthetic paired test: `synthetic-interior` only. ViewPoint leveled it and left the verticals converging. Compositor rectified both.
- Completed real-photograph paired file: `window-wall.jpg` against `viewpoint/window-wall__auto-full.jpg`. ViewPoint's Perspective Auto kept the composition and shrank the canvas. Compositor Auto Full now keeps the vertical correction and the original canvas. Not parity.
- Real photographs tested only in Compositor: stone house and library atrium, each as the sample JPEG and as the stripped PNG, in all three Auto modes. Window wall was also rendered in all three modes, including the stripped PNG, which ViewPoint did not open.
- Not opened in ViewPoint: stone house and the library. No camera-original RAW was added. The two Canon files were resaved by Photoshop 25.7, and the library file has no camera EXIF.

`renderPhotographicModes()` checks the outcome, not the old defect. Stone house Auto Full stays identity. Library Auto Full stays a level. Window-wall Auto Full, JPEG and stripped PNG, keeps the vertical correction and the same opaque fraction. `windowWallAutoFullPrefersTheVerticalCorrection()` is skipped, not passed, when `window-wall.jpg` is absent. `autoFullKeepsAStrongRectangleAndFallsBackWhenItDoesNotPay()` keeps a supported strong rectangle, falls back to vertical when only walls are present, falls back to a level when only a horizon is present, and refuses two lines that cross inside the frame.

The same test draws four horizontal lines in two opposing slopes. On that fixture Auto Full spends about 1% more of the frame than Auto Vertical (coverage 0.887 against about 0.897, loss 0.010). That is not a destructive warp, so it does not prove the gate would refuse four supported lines that open a large hole. A later adversarial fixture still needs four inliers of one horizontal model, a large preservation loss, and lines that are not one real horizon. No new threshold was added for the current fixture.

## Suggested commit message

Camera Raw: robust automatic upright detection and quality-aware perspective selection.

## Pull request #1

Leave it open and do not merge on this work alone. Auto Full on the window wall now keeps the vertical correction instead of the black wedge. A supported synthetic rectangle is still allowed to crop. The only photographic ViewPoint file is the window-wall JPEG, and that command is not the same operation as Compositor's result. Do not treat the milestone as matched to ViewPoint.
