# M10.3 — Optional Lensfun lens profile provider

Status: complete. Discovery, selection and persistence only. No calibrated pixel correction is applied,
and none is presented as working.

## 1. What this milestone adds, and what it does not

Adds a `Lens Profile` group at the bottom of the existing Camera Raw `Optics` section, after M10.2's
`Lens Blur`. It lets a user:

* choose a lens-correction provider: **Apple Native** (default), **Lensfun** (opt-in), **Off**;
* import a Lensfun XML database explicitly, see whether one is installed, and remove it;
* see the camera and lens the file recorded, and the focal length and aperture it was shot at;
* match a lens profile automatically, or pick one by hand when the automatic match is ambiguous;
* see which of Distortion, Vignetting and Lateral chromatic aberration the matched profile actually
  carries **for this shot** — and be told plainly when it carries none.

It does **not** apply a Lensfun correction to any pixel. The panel says so in its own words. This is
deliberate: the acceptance rules forbid presenting an incomplete renderer as functional, and the
calibrated engine is M10.4.

Nothing else changed. The ten sections keep their order, every pre-existing Optics control keeps its
position, and the RAW development editor's own `Lens Correction` toggle is untouched.

## 2. Why a database-only provider, not the Lensfun library

The two halves of Lensfun are separately licensed and separately problematic:

| | Lensfun library | Lensfun XML database |
| --- | --- | --- |
| License | LGPL-3.0 | CC BY-SA 3.0 |
| What it is | C++ shared library (`liblensfun`) | Plain XML: `<lensdatabase>` of mounts, cameras, lenses and `<calibration>` blocks |
| Cost of shipping | Must be built per architecture, signed, and its LGPL obligations satisfied (relinking ability, source offer) | A data file |
| Runtime risk | Executes third-party native code in-process | None: it is parsed, never run |

Compositor is App Sandbox + Hardened Runtime, `arm64` only, deployment target macOS 26, signed with
`Config/Compositor.entitlements`. Under those constraints:

* **Hardened Runtime** refuses to load a dylib that is not signed by the same team or by Apple.
  Shipping `liblensfun` means signing it as part of the bundle; *downloading* one at runtime means
  loading unsigned third-party native code, which is exactly what Hardened Runtime exists to stop.
  Weakening it (`disable-library-validation`) to allow that would weaken every other library too.
* **App Sandbox** gives the app no writable location that is executable-safe for third-party code,
  and no `com.apple.security.cs.allow-unsigned-executable-memory` to map one.
* The library would need building for `arm64` from source, with its own LGPL relinking obligation,
  for a feature that is optional.

So M10.3 implements the **safe half**: the database, read by Compositor's own Swift `XMLParser`
reader. No third-party binary is downloaded, installed, or executed. The correction engine, when it
arrives, is a separately built and signed component (see §8), not something fetched at runtime.

**Attribution.** The database is CC BY-SA 3.0. When a user imports one, the panel names Lensfun as
the source of the data, and the report you are reading records the terms. Any future bundled copy
would carry the same notice in the app's about box. Nothing here relicenses or redistributes the
database: the user supplies it.

**Offline.** Nothing is fetched. `Import Lensfun Database…` opens the standard open panel; the user
picks an XML file or an unpacked update folder. There is no URL, no version check, no silent update.
That satisfies "installation must require an explicit user action" by construction rather than by a
confirmation dialog.

**Integrity.** An imported set is validated in full before a single byte is written over the working
copy (§4), and a SHA-256 digest of the installed files is available for the status line, so what the
panel read can be compared with what is on disk.

## 3. Architecture

| File | Role |
| --- | --- |
| `Compositor/Document/CameraRawLensProfile.swift` | Provider enum, `LensMetadata`, `CameraRawLensProfileSelection`, `CameraRawLensProfileSettings`, `CameraRawLensCorrectionPolicy`, and reading camera/lens from ImageIO properties |
| `Compositor/Document/LensfunDatabase.swift` | Value types for cameras, lenses, calibrations and matches, plus the name normalization and matching rules |
| `Compositor/Document/LensfunXMLParser.swift` | Streaming `XMLParser` delegate for database formats 1 and 2 |
| `Compositor/Document/LensfunDatabaseManager.swift` | On-disk store (Application Support), install/remove, and the panel's observable state |
| `Compositor/UI/CameraRawLensProfileControls.swift` | The `Lens Profile` group |
| `Compositor/Document/CameraRawDetailOptics.swift` | `lensProfile` added to `CameraRawOpticsSettings`; included in `normalized` and in `adjusts` |
| `Compositor/Document/CameraRawSettingsPersistence.swift` | `lensProfile` object inside `optics`, with per-key defaults |
| `Compositor/Document/Filters.swift` | `lensMetadata` and `rawDevelopment` on `FilterEdit`; `lensCorrectionPolicy` |
| `Compositor/IO/ImageImporter.swift` | Reads camera/lens from the dictionaries ImageIO already returned |
| `Compositor/Document/EditorSession.swift` | One `LensfunDatabaseManager` per session; RAW import records lens metadata |
| `Compositor/UI/CameraRawDetailOpticsControls.swift` | Appends the group after `lensBlurControls` |

The provider and selection are values on `CameraRawSettings`, so they travel with the document,
undo and redo, and the Optics reset exactly like every other Optics control. The database itself is
application state, not document state: it is shared by every document, like a preference.

## 4. Database manager

`LensfunDatabaseStore` is a folder: `Application Support/Compositor/Lensfun Database`. A folder, not
a file, because a Lensfun update is a set of XML files plus `timestamp.txt`, and "is it installed" is
then a question about one directory.

* **Detection.** `isInstalled` is "there is at least one `.xml` file". `load()` parses every file and
  merges them. A single unreadable file fails the whole load, so a half-broken install is reported
  rather than half-used.
* **Version.** The `version` attribute of `<lensdatabase>` is kept per file and the highest is
  reported. Formats 1 and 2 are read; 0 is refused rather than guessed at.
* **Install.** Every chosen file is parsed and merged *before* anything is written. Only then is the
  installed set replaced. A corrupt file therefore leaves the previous database untouched — there is
  a test for exactly that.
* **Remove.** Deletes the folder. Projects that named a Lensfun profile keep the name and report it as
  missing; nothing is silently substituted.
* **Size.** A file over 64 MB is refused before parsing (the shipped database is about 4 MB).

`LensfunDatabaseManager` is `@MainActor @Observable`, holds the parsed database and the status
(`notInstalled`, `loading`, `installed`, `failed`), and is refreshed when the panel appears.

## 5. Matching

Names are normalized conservatively. Lensfun's own rule is followed: a name is split into runs of one
character type — letters, digits, punctuation — then punctuation-only runs and a lone `f` are dropped.
That makes `f/2.8L` and `f2.8l` the same sequence and `24-70mm` and `24 70 mm` the same too, without
rewriting a name into a different one. Two names match when their word multisets are equal; a looser
"every word of the shorter is in the longer" is used only for camera bodies recorded more briefly
(`ILCE-7M3` against `Sony ILCE-7M3`).

Automatic matching applies hard constraints in this order, and never picks the first of several:

1. **Mount.** The lens must be for the camera's mount, or for a mount the database declares
   compatible (`<compat>`), checked in both directions. A Nikon lens on a Canon body is not a match
   even when the name is identical; it is still offered for manual choice.
2. **Focal range.** The lens's own range must cover the shot's focal length, with a little slack for
   the rounded value cameras record.
3. **Uniqueness.** Two entries that both survive are reported as ambiguous, and the user chooses.

Each failure is a distinct `LensfunMatchIssue` with its own sentence in the panel: no metadata, lens
not in the database, mount mismatch, focal mismatch, ambiguous.

**Calibration reporting is shot-specific.** A profile is only said to correct something when it has a
sample covering *this* focal length — and, for vignetting, this aperture too. A lens with vignetting
samples at f/2.8 does not claim to correct f/8. A `<distortion model="none">` is not a calibration.
This is what stops the panel from promising a correction the profile cannot do.

## 6. Double correction, by design

`CameraRawLensCorrectionPolicy` classifies the layer and states what is true of its pixels:

| Layer | Classification | What the panel says |
| --- | --- | --- |
| RAW whose bytes are still retained | `redevelopableRaw` | The decoder's correction is a choice; if it is on, it says to turn it off before using a Lensfun profile |
| RAW that was developed and baked | `previouslyDevelopedRaw` | Any decoder correction is already in the pixels and cannot be removed without redeveloping the original |
| JPEG / TIFF / PNG | `renderedImage` | The camera or another developer may already have corrected it; that cannot be separated from the pixels |

Only `redevelopableRaw` may ever take a Lensfun correction, and only once a calibrated engine exists
(`CameraRawLensCorrectionPolicy.calibratedCorrectionAvailable` is `false` today, so
`canApplyLensfunCorrection` is `false` for every layer). Apple's own state is read from the layer's
retained `RawDevelopSettings.lensCorrection`, so a baked develop is reported as baked rather than as
still being a choice. Manual Distortion, Defringe, Lens Vignetting and Lens Blur are independent of
all this and keep working under every provider, including `Off`.

## 7. UI

`Optics` keeps `Remove Chromatic Aberration` → `Generic Lens Correction` → `Manual` → `Lens Blur`,
and `Lens Profile` is appended after them. The group shows:

* a **Provider** picker (a visible control, not a hidden default) with a one-line explanation of each
  choice;
* when Lensfun is chosen, the database status (installed or not, lens/camera counts, date), the
  **Import Lensfun Database…** and **Remove** buttons, and a plain statement that only XML profile
  data is read and no code is installed;
* the detected camera, lens, focal length and aperture, or a statement that the layer carries no tags;
* **Automatic** / **Manual** matching, the matched profile name, the body it was measured on and its
  crop factor;
* the calibrations available **for this shot**, or a warning that none covers it;
* an orange warning for each unmatched case;
* the correction-policy sentence for the layer, and a notice that calibrated Lensfun correction is not
  available in this version.

Nothing in the group changes a pixel in M10.3, so choosing a provider or a profile is safe to do and
safe to undo.

### Screenshots (`work/camera-raw-parity/screenshots/`)

The Camera Raw panel is its own dialog beside the document window, so the evidence is the dialog
itself, captured as an element by `ScreenshotTests`.

| File | Shows |
| --- | --- |
| `AFTER_10_1_light_auto.png` | Light: `Auto` above Exposure; Exposure → Blacks unchanged and in order. |
| `AFTER_10_2_optics_lens_blur.png` | Optics scrolled to its end: `Lens Blur` (Amount, Aperture, Focus Range, Falloff, Highlights, Move Focus), then `Lens Profile`. |
| `AFTER_10_3_optics_lens_profile.png` | `Lens Profile` on its default: **Provider: Apple Native**, its explanation, the layer's lack of camera/lens tags, the correction-policy sentence, with Geometry and Calibration still below. |
| `AFTER_10_3_lens_profile_lensfun.png` | The same group after choosing **Lensfun**: "Lensfun database: Not installed", **Import Lensfun Database…**, and the statement that no Lensfun code is installed and nothing is fetched without a chosen file. |

The two M10.3 captures are the same panel in its two provider states, which is the point: Apple Native
is what a user sees before doing anything, and Lensfun is reachable but inert without an import.

## 8. Plan for M10.4 — calibrated corrections

1. Ship the Lensfun **correction engine** as a separately built, separately signed component — either
   a signed embedded framework built from the pinned LGPL source at build time, or a
   `SMAppService`-free helper in its own signed bundle. It must be signed with the same team as the
   app so Hardened Runtime allows loading it; nothing is fetched at runtime.
2. Implement distortion (poly3 / ptlens), TCA (poly3) and vignetting (pa) sampling from the calibration
   blocks already parsed here, interpolating between measured focal lengths.
3. Gate the pixel pass on `canApplyLensfunCorrection`, and require the user to turn Apple's correction
   off in the RAW development editor first; the panel already says to.
4. For `previouslyDevelopedRaw` and `renderedImage`, keep the current refusal and offer redevelopment
   of the original instead of a correction that would double up.
5. Only then flip `calibratedCorrectionAvailable` to `true`, and replace the "not available" notice.

## 9. Tests

`CompositorTests/CameraRawLensProfileTests.swift` — 38 tests, all passing.

| Area | Tests |
| --- | --- |
| Default provider | Apple Native is the default, is identity, makes no adjustment (1) |
| No pixel change | An explicit Lensfun choice renders byte-identical pixels (1) |
| Provider switching | Every provider round-trips and explains itself; Off is its own choice (1) |
| Not installed | A fresh store is not installed and does not load; an empty folder is not a database; Apple stays usable (3) |
| Install opt-in | Valid XML installs and loads; an unpacked update folder installs every file and keeps its timestamp; a bad import leaves the previous database in place; remove returns to the fresh state (4) |
| Parsing | Cameras, lenses, ranges, mounts and calibrations; a prime's single focal length; `model="none"` is not a calibration (3) |
| Invalid input | Malformed XML, a non-database, format 0, a database with no entries, an oversized file (5) |
| Matching | Exact match; case/word-order/punctuation-insensitive names; a briefer camera model; a missing lens reported not guessed; another mount rejected; focal length outside the range rejected; two identical entries ambiguous; no lens tag; a declared `<compat>` mount accepted (9) |
| Calibrations | Reported only where samples cover the shot; a prime without vignetting data never claims it (2) |
| Persistence | Round-trip; older `optics` without the key; an unknown provider string falls back to Apple Native; an automatic selection carries no pinned lens; the choice belongs to the Optics reset (5) |
| Policy | A redevelopable RAW may eventually take a correction; a developed RAW and a rendered image are both refused; Apple correction being on is called out; Off keeps manual adjustments (4) |

`CompositorUITests/CameraRawSectionOrderTests.swift` now also asserts the `Lens Profile` group exists
below `Lens Blur` and that the provider is a visible, labeled choice. `ScreenshotTests.swift` gained
steps `09` and `10`: the group on its default, and the same group after choosing Lensfun. Both pass.

### Build

An incremental Debug build of the app and both test targets, and the focused runs above, are what this
milestone was verified with. No full-resolution RAW benchmark was run, as the milestone requires.

## 10. Known limitations

* No calibrated correction is applied, by design. A match describes what a profile could correct.
* The database is not bundled. The user imports it; without one, Apple Native behaves exactly as it
  always has.
* Matching is name-based, as Lensfun's own is. A file whose lens tag is a camera's internal code
  (`"Unknown"`, a numeric ID) will not match, and is reported as not in the database rather than
  guessed.
* Only formats 1 and 2 are read, and only distortion / TCA / vignetting calibrations are described;
  the `acm` models of format 2 are parsed but not yet interpreted.
* The panel's manual list is limited to plausible entries (name matches, then everything the camera's
  mount takes) rather than the whole database.
