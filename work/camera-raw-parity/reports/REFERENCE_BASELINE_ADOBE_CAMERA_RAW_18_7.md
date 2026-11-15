# Reference baseline — Adobe Camera Raw 18.7 (Photoshop 2026)

Status: **authoritative reference for all active Camera Raw work.** Supersedes
`work/geometry-validation/UI_SPEC_ADOBE_CAMERA_RAW_2016.md`, which is archived historical research.

Branch / worktree: `integration/compositor-camera-raw`, the sole worktree. No new branch, worktree or PR is
created for reference work or for any milestone that cites this document.

---

## 1. Which Adobe release is the reference

| Item | Value |
|---|---|
| Product | Photoshop 2026 |
| Camera Raw | **18.7** |
| Reference form | Six screenshots supplied by the user |
| Where they live | Outside the repository. Adobe-owned imagery is not committed; see §2 |
| Previous reference | Camera Raw 9.6 / Lightroom 2016 — **archived**, not a spec |

Three older citations exist in the tree and no longer define the target:

- `UI_SPEC_ADOBE_CAMERA_RAW_2016.md` — ACR 9.6. Archived, banner added, acceptance gate and branch plan voided.
- `MILESTONE_9_1_MODERN_GEOMETRY_UI.md` — cites "ACR 19.0 Geometry panel" and "ACR 18.3 workspace" from web
  images. Those were the working reference at the time; they are now **historical citations, not the baseline**.
  The UI decisions they produced are still valid unless they conflict with §6.
- `MILESTONE_9_1_2_REPOSITORY_CONSOLIDATION.md` §"Comparison target" — same ACR 19.0 citation. Historical.

Nothing in this document claims mathematical parity with Adobe. ACR is a behavioural reference for an
independent implementation; Compositor's own engines and interface stay authoritative.

---

## 2. Where the reference images are, and why they are not in Git

The six ACR 18.7 screenshots are **not committed**. The precedent is already set in this tree: M9.1 downloaded
reference JPEGs to `/tmp/compositor-geometry-ref/` and deliberately did **not** commit them
(`MILESTONE_9_1_MODERN_GEOMETRY_UI.md`: "copyrighted Adobe imagery").

So:

- Treat the six screenshots as **external, user-supplied evidence**. Read them, cite them, do not copy them in.
- If a milestone needs a stable local copy for comparison, keep it outside the repository (e.g. under `/tmp`) and
  record the path in the milestone report, exactly as M9.1 did.
- **Never** infer what a screenshot contains. If an image cannot be opened, say so rather than describing it.
  This matters: during the pass that produced this document, six similarly sized local images were initially
  taken for the Adobe screenshots and turned out to be unrelated newsletter documents. They were not cited.

### What the reference shows, as far as it is verified

Only the locally available ACR reference images have been read for this document:

| File | Release | Read for | Confidence |
|---|---|---|---|
| `/tmp/compositor-geometry-ref/acr19_geometry.jpg` | ACR 19.0 Geometry panel | Panel order: `Geometry` header, lens-correction note, `Projection`, `Vertical`, `Horizontal`, `Rotate` | Directly read |
| `/tmp/compositor-geometry-ref/acr18_workspace.jpg` | ACR 18.x workspace | Canvas framing, panel column, empty-edge presentation | Directly read |

The six ACR **18.7** screenshots are not present on this machine at the time of writing. Every statement below
about 18.7 is therefore drawn from the shipped Adobe feature set and from the parts of the ACR 18.x/19.0
references that were read, and is marked accordingly. **Where this document is uncertain, it says so** rather
than describing an image it has not seen.

---

## 3. The standing constraints this reference is subordinate to

These come from the permanent Camera Raw requirements and are not renegotiable per milestone.

1. Do not remove existing Compositor features.
2. Do not move existing controls, sections, tools or workflows.
3. Do not reorder existing Camera Raw sections.
4. Do not hide existing functionality behind new tabs, menus or disclosures without explicit authorization.
5. Do not replace Compositor-specific functionality with Adobe-style alternatives.
6. Add new features inside the most relevant existing section, or as a clearly identified adjacent control.
7. Preserve functionality, defaults, project compatibility, Undo/Redo, non-destructive edits and shortcuts.
8. Reuse existing Compositor engines. Do not duplicate a renderer or solver to resemble Adobe.
9. Do not ship a visually functional control whose behaviour is not implemented.
10. Keep Compositor's advanced capabilities even where Adobe has no equivalent.

Goal 5 is the one that decides the Upright question: **Compositor's five Upright modes are the product.** Adobe's
strip is a reference for compactness and labelling, never a target to copy button-for-button.

---

## 4. What the reference actually adds, over Compositor's current panel

Read against the shipped source in this tree, not against the historical reports. "Exposed" means a control a
person can click in the panel as it ships.

| Area | ACR 18.7 | Compositor today | Gap class |
|---|---|---|---|
| Geometry › Upright | Icon strip including Auto and Guided | **Exposed** — five honest modes: Off, Auto Level, Auto Vertical, Auto Full, Guided | None in function. Keep Compositor's five |
| Geometry › Projection | Popup | **Exposed** — Perspective / Rectilinear, inside Manual Transformations | None |
| Geometry › Vertical / Horizontal / Rotate | Sliders | **Exposed** — Manual Transformations | None |
| Geometry › Aspect | Slider | **Exposed** — labelled `Aspect` | None |
| Geometry › Scale / Offset X / Offset Y | Sliders | **Exposed** | None |
| Geometry › Constrain Crop | Toggle | **Exposed** | None |
| Geometry › guides on the image | Guided drawing, endpoint drag | **Exposed** — draw, drag endpoints, 4-guide cap, Escape cancel | None |
| Geometry › **Horizon** | Independent control | **Exposed** — M10.4: five modes, Angle, Amount, drawn reference | None since M10.4 |
| Geometry › perspective **tool kinds** | Rectangle, Eight Point and guide variants are part of the tool | **Not reachable** — backend complete, no UI | **M10.5** |
| Geometry › framing after transform | Keep-size vs expanded | **Exposed**, with a documented 16-bit refusal | None; precision policy is Compositor's own |
| Optics › Lens Blur | Focus-region blur with aperture shape | **Exposed** — M10.2 | None |
| Optics › lens profile | Camera-specific profiles | **Exposed as discovery only** — M10.3. No calibrated correction applied | **M10.6** |
| Light › Auto | Auto tone | **Exposed** — M10.1 | None |
| Everything else | ACR's ten sections | All ten present, in Compositor's order | None |

**Verified not-a-gap:** the historical `COMPOSITOR_GEOMETRY_GAP_ANALYSIS.md` still recommends "Track A —
Intensity + framing controls" as the next milestone. That is **stale**. `perspectiveAmount` (0–100, default 100)
and `framingMode` (Keep Original Size / Expand to Fit) are implemented, tested and exposed in the panel today.
Do not start that work again.

---

## 5. Backend-implemented versus user-reachable

The distinction the requirements demand be kept explicit. Two capabilities are real code with passing tests and
**no way for a user to reach them**. They must not be described as delivered.

| Capability | Backend | Reachable in the UI | Honest status |
|---|---|---|---|
| Vertical / Horizontal / Combined perspective guides | implemented | **no** | Backend only |
| Rectangle perspective construction | implemented | **no** | Backend only |
| Eight Point perspective construction | implemented | **no** | Backend only |
| Miniature / tilt-shift | implemented | **no** | Backend only; separate from Lens Blur |
| Lensfun calibrated correction | **not implemented** | no | Discovery only; the panel says so |
| Expand to Fit on 16-bit/HDR | refused by design | refused, with a message | Deliberate policy, not a gap |

Everything else listed as *exposed* in §4 is reachable and covered by the Camera Raw suites.

The panel must never imply that the three perspective tool kinds or Miniature are available. Today no control
claims them, which is correct; M10.5 and M10.7 are what make them real.

---

## 6. Design language to take from 18.7 — and what not to take

### Take

- **Compactness.** Icon-sized mode buttons, tight vertical rhythm, a 96 pt label column, and a numeric field
  beside each slider. Compositor already matches this (`CameraRawControls.labelWidth = 96`).
- **Numeric entry next to the slider**, with the slider's own reset on double-click. Already the pattern in
  `CameraRawSlider` rows.
- **Per-section eye and reset**, shown only when the section is actually adjusted. Already implemented.
- **Lens corrections before geometry.** ACR's own note in the Geometry panel. Compositor's composition order
  already places lens distortion ahead of volume and perspective, so the advice is satisfied; it does not need
  a second note.
- **Disclosure for secondary work.** Advanced Geometry and Manual Transformations are collapsed by default so
  the primary rows stay visible. This is the one place a disclosure is correct — it reveals new rows and hides
  nothing that existed before it.

### Do not take

- **The Upright button set.** Compositor's five modes stay. No sixth button, no renamed modes, no picker.
- **ACR's section set or order.** The ten sections keep their order: Light, Color, Color Grading, Effects, Curve,
  Color Mixer, Detail, Optics, Geometry, Calibration.
- **ACR's sidebar metrics, fonts and colors as hard values.** Match the *rhythm*, keep Compositor's own styling
  and system colors.
- **Any Adobe imagery, icons or branding.** System symbols only.

### The 2016 spec's specific prohibitions

These appear in the archived document and are explicitly **not** requirements:

| 2016 proposal | Why it is refused |
|---|---|
| Six-icon Upright strip | Compositor has five modes with distinct algorithms; a sixth button would be cosmetic only |
| 320 pt sidebar, 70–75% canvas split | Compositor's panel geometry is its own and is load-bearing for `FloatingPanelTests` |
| Rename Geometry → Transform | Existing section name and title stay |
| Adobe's eight-slider order with Constrain Crop last | Compositor's rows stay where they are |
| Apply/Cancel footer, Previous/Next | Compositor already owns its Apply/Cancel |
| Precision Loupe during guide drawing | Not required; would be a new subsystem, not an additive control |
| New branch + draft PR | Forbidden — sole worktree on `integration/compositor-camera-raw` |

---

## 7. Acceptance gate for a milestone that cites this document

A milestone passes only if **all** of these hold.

1. **Additive.** Every preexisting control is still present, in its original section, in its original order.
   A structural test proves it, not a screenshot alone.
2. **Honest.** Every control either does what it says or is not shipped. Backend-only capabilities are listed in
   the report as backend-only, with the table from §5 updated.
3. **Reused.** The feature drives an existing engine. Name the engine in the report, or explain why a new one
   was unavoidable.
4. **Reference-correct.** The report cites **this** document, not the 2016 spec, and states which parts of the
   reference were actually consulted versus taken from the shipped feature set.
5. **Durable.** Defaults preserve old projects. Undo/Redo, Apply/Cancel and save/reopen are exercised.
6. **Tested.** Focused tests pass, including identity-at-default and a structural section-order assertion.
7. **Single worktree.** No new branch, worktree or PR.

---

## 8. Pointers

| Document | Role |
|---|---|
| `work/camera-raw-parity/reports/FEATURE_PARITY_PLAN.md` | Living milestone plan. §9 holds the sequence |
| `work/camera-raw-parity/reports/M10_4_VIEWPOINT_GEOMETRY_INTEGRATION.md` | Horizon; §8 scopes M10.5 |
| `work/geometry-validation/reports/COMPOSITOR_GEOMETRY_GAP_ANALYSIS.md` | ViewPoint 6.1 comparison. Track A is stale; see §4 |
| `work/geometry-validation/reports/VIEWPOINT_6_*.md` | ViewPoint research. Behavioural reference for Compositor's own engines |
| `work/geometry-validation/UI_SPEC_ADOBE_CAMERA_RAW_2016.md` | **Archived.** Provenance only |
