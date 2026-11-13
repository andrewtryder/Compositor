# Milestone 8 — Local mesh editor architecture

Clean-room design for Compositor. Inspired by observed ViewPoint 6.1 ReShape *interaction concepts* (`VIEWPOINT_6_RESHAPE_ANALYSIS.md`), implemented with Compositor’s own data structures, Metal path, and document model. Do not copy DxO code, SAM weights, or sidecar formats.

Milestone 8 = **manual** local mesh. Milestone 9 = subject-aware masks / protection.

## Architectural choice: document-level tool, not Camera Raw bake

**Recommendation:** implement mesh warp as a **native document/layer editing operation** (peer to Liquify / Smudge), not as a new Camera Raw Geometry slider set.

Reasons:

1. Camera Raw currently **bakes** pixels on OK (`FilterJob` → `PixelFilter.run` → `CameraRawSettings.apply`). A mesh that must stay editable after commit does not fit that bake-only model without a format bump and non-destructive filter stack work.
2. Compositor already has GPU stroke warps in `MetalWarp` (Liquify offsets, shared textures, readback at stroke end) and brush/mask infrastructure (`BrushRaster`, coverage Metal).
3. Undo for interactive point drags matches `EditorSession` / document undo more naturally than filter-preview coalescing.
4. Persistence can start as **layer-local edit state** or a sidecar next to the project, without immediately changing `ProjectManifest`—evaluate compatibility before any format version bump.

Camera Raw Geometry (perspective, volume, constrain crop) stays as today. Mesh can run **after** a baked Camera Raw result on a layer, or on any raster layer. Document the user-visible order in the UI (“Mesh Warp” tool), not as a silent Camera Raw stage.

Non-destructive long-term option (post–Milestone 8): store mesh + source reference as an adjustment layer. Out of scope until persistence design is approved.

## Mesh data structures

```
MeshWarpDocument {
  imageSize: (width, height)           // pixel space, top-left origin (Compositor convention)
  grid: MeshGrid
  selection: Set<VertexId>
  options: MeshOptions
}

MeshGrid {
  columns: Int, rows: Int              // cell counts; vertex counts = (columns+1)*(rows+1)
  vertices: [SIMD2<Float>]             // current positions, length (columns+1)*(rows+1)
  rest: [SIMD2<Float>]                 // bind pose (usually uniform UV lattice)
  // optional topology for subdiv:
  cells: [Quad]                        // or implicit regular indexing for M8
}

MeshOptions {
  stickyBorders: Bool
  propagation: Float                   // 0…1 falloff radius relative to image diagonal
  coverage: .full | .inner             // optional inset margin
}
```

Milestone 8 can ship **regular quad grids only** (presets 4×4 … 32×32 + custom rows/columns). Subdivide/merge can be phase 8.1: split a selected quad into four, re-index vertices (keep a free vertex list once regularity breaks).

Coordinate system: **layer pixel space**, y down, matching `MetalWarp` / document pixels. UI overlays convert via the existing canvas transform.

## Deformation algorithm (proposed)

**Preview and export:** destination-to-source sampling over triangles from each quad (two triangles), barycentric fetch from the **rest** lattice into the source image; premultiplied bilinear, transparent OOB (same edge policy as volume).

**Editing:** user moves **destination** vertices (or rest-fixed, dest-draged—pick one and keep it consistent). Recommended: rest pose fixed; dragged handles update `vertices[]`; rasterizer uses current `vertices` as the destination mesh and samples the source via the inverse map of each triangle.

**Propagation:** when stickyBorders is off and propagation > 0, a handle drag also displaces neighbors with a smooth kernel (e.g. Wendland or Gaussian of distance in rest space). When stickyBorders is on, vertices on the image boundary have delta forced to 0.

**Fold / degeneracy:** reject or project updates that invert triangle area below ε; optionally Laplacian rest-shape regularizer on Apply. Show a non-blocking warning if a cell folds.

**Region rotate/scale:** for a selected vertex set, apply a similarity or affine about the selection centroid in destination space, then run the same fold checks.

This is intentionally ordinary FEM-free lattice warp—not DxO’s proprietary solver.

## Rendering approach

1. **Interactive preview:** Metal compute or render pipeline building a full-frame output texture from the triangle list (reuse patterns from `MetalCameraRawVolume` buffers and `MetalWarp` texture lifetime). Start from compute + shared buffers if that matches existing helpers; switch to a vertex/fragment mesh pass if triangle count grows.
2. **Stroke coalescing:** update vertex buffer on pointer move; encode one dispatch per frame; do not read back every move.
3. **Commit:** readback once on Apply / tool end into a layer bitmap (same end-of-stroke pattern as `MetalWarp.read(into:)`), then record undo.
4. **CPU fallback:** serial triangle raster for tests and no-Metal machines (parity tests with max channel error ≤ 1, as volume).

## Control-point interactions

| Gesture | Behavior |
| --- | --- |
| Drag handle | Move destination vertex (+ propagation) |
| Shift / marquee | Multi-select |
| Move / Rotate / Scale tool modes | Operate on selection |
| Double-click handle | Reset that vertex to rest |
| Reset mesh | All vertices ← rest |
| Subdivide (8.1) | Selected cells → 4 children |
| Merge (8.1) | Inverse when topology allows |

Overlay: draw rest ghost optionally; draw current edges and handles; point-count status (`used / max`).

## Boundary constraints

- `stickyBorders == true`: vertices with rest on the outer frame stay fixed.  
- Image-size change: rebuild rest lattice; discard or resample mesh (define on layer resize).  
- Maximum vertices (e.g. 10 000) to keep preview interactive—soft cap with UI feedback.

## Undo and persistence

- Each Apply (or each finished drag group) = one undo entry storing previous `vertices` (and topology if subdivided).  
- Tool cancel restores pre-tool snapshot.  
- **Milestone 8 persistence options (pick one before coding format):**  
  A. Destructive Apply only (no reopen of mesh)—fastest.  
  B. Store mesh JSON beside the project or in an unsaved editor session until save—still no manifest bump.  
  C. Manifest bump + layer edit record—only after explicit format review.

Do not invent a `.dvp` clone.

## Performance considerations

- 8×8 = 81 vertices, 128 triangles: trivial on M3-class GPUs.  
- 32×32 = 1089 vertices: still light; cost is full-frame sampling at photo resolution (same class as volume).  
- Keep one reusable output texture; avoid per-frame `CGImage` unless the AppKit canvas requires it.  
- Benchmark warm Apply at 6K like volume tests.

## Test strategy

1. **Unit:** rest lattice identity (zero displacement → byte-identical).  
2. **Parity:** CPU vs Metal on synthetic grids; max channel error ≤ 1.  
3. **Constraints:** sticky borders keep edge samples fixed under center drags.  
4. **Folds:** inverted quad rejected.  
5. **Propagation:** neighbor displacement monotonic in kernel radius.  
6. **UI smoke:** preset switch, drag, undo, Apply, export/save layer.  
7. **No regression:** Camera Raw geometry tests unchanged.

## Milestone 8 implementation sequence

1. Data model + rest lattice + overlay drawing (no warp yet).  
2. CPU triangle warp + identity/parity tests.  
3. Metal preview path + readback Apply.  
4. Handle drag + undo + stickyBorders.  
5. Propagation slider.  
6. Selection + rotate/scale modes.  
7. Custom rows/columns; optional subdiv/merge.  
8. Performance notes + acceptance checklist.  
9. Stop before AI / SAM-like features (Milestone 9).

## Acceptance criteria

- User can place a regular mesh (presets + custom size) on a raster layer.  
- Dragging handles updates a live preview without baking Camera Raw.  
- Sticky borders and propagation behave as documented above.  
- Apply writes pixels; Undo restores pre-Apply layer bits.  
- Full-resolution Apply completes with documented timing on the M3 Pro class machine.  
- CPU fallback exists; automated parity tests pass.  
- No DxO assets in the tree; no Camera Raw Auto algorithm changes.  
- Milestone 9 hooks: optional mask channel ignored in M8 but plumbed as “future protection mask.”

## Open questions (resolve before format work)

1. Destructive Apply vs session-only mesh vs project-format edit record.  
2. Whether mesh should be blocked while a Camera Raw panel is open (likely yes).  
3. Interaction with layer transforms: warp in layer pixel space before or after the layer affine.  
4. Maximum subdiv depth and how merge recovers regularity.

## Recommended next implementation prompt

> Implement Milestone 8 phase 1–3 in a new branch from `camera-raw-geometry-upright` (or merged M5–7 baseline): mesh data model, overlay, CPU warp with identity tests, then Metal preview/Apply wired as a document-level tool beside Liquify. Do not change Camera Raw Auto. Do not add AI masks. Follow `MILESTONE_8_ARCHITECTURE.md` acceptance criteria.
