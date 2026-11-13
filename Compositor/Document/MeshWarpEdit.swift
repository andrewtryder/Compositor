import AppKit
import CoreImage
import Foundation
import simd

/// In-progress ReShape mesh edit on one layer. Apply stores editable mesh + source and
/// updates the layer's display pixels (one document undo); Cancel drops the session only.
@Observable
final class MeshWarpEdit {
    let layerID: UUID
    let layerName: String
    /// Layer pixel size when editing began.
    let width: Int
    let height: Int
    /// Immutable unwarped source pixels (8-bit). Never replaced by a warped result.
    let originalImage: CGImage
    /// Thumbnail for the immutable source when committing persistent state.
    let originalThumbnail: CGImage
    /// Layer transform at begin (placement unchanged by warp).
    let transform: LayerTransform
    var mesh: MeshWarpGrid
    /// Multi-point selection (stable vertex IDs).
    var selection = MeshWarpSelection()
    /// Legacy single-index mirror of the primary / last-hit vertex (overlay highlight).
    var selectedIndex: Int?
    var transformMode: MeshWarpTransformMode = .move
    /// CPU/CG preview fallback; nil when showing the original or a GPU-resident preview.
    var previewImage: CGImage?
    /// GPU-resident live preview (preferred). Drawn through `place(live:)` without per-drag readback.
    var previewCIImage: CIImage?
    var lastWarning: String?
    /// Unsupported deep/HDR layers are refused at begin.
    var isUnsupportedPrecision = false
    /// Timing from the most recent preview encode.
    var lastPreviewSample = MeshWarpRenderer.Sample()
    /// Generation of the mesh state last submitted to the GPU.
    private(set) var previewGeneration: UInt64 = 0

    /// Tool-local undo/redo (not document history).
    @ObservationIgnored let history = MeshWarpHistory()
    /// Positions at the start of the current pointer gesture (absolute displacement base).
    @ObservationIgnored var gestureBasePositions: [SIMD2<Float>]?
    @ObservationIgnored var gestureBaseSelection = MeshWarpSelection()
    @ObservationIgnored private var gestureDidMutate = false

    @ObservationIgnored private var gpuSession: MetalMeshWarpSession?

    init(layerID: UUID, layerName: String, image: CGImage, transform: LayerTransform, mesh: MeshWarpGrid,
         thumbnail: CGImage? = nil) {
        self.layerID = layerID
        self.layerName = layerName
        self.width = image.width
        self.height = image.height
        self.originalImage = image
        self.originalThumbnail = thumbnail ?? ((try? PixelAdjust.thumbnail(of: image)) ?? image)
        self.transform = transform
        self.mesh = mesh
        self.gpuSession = MetalMeshWarpSession(image: image)
    }

    var displayedImage: CGImage { previewImage ?? originalImage }
    var usesGPUResidentPreview: Bool { previewCIImage != nil }

    func snapshot() -> MeshWarpHistorySnapshot {
        MeshWarpHistorySnapshot(mesh: mesh, selection: selection)
    }

    func apply(snapshot: MeshWarpHistorySnapshot) {
        mesh = snapshot.mesh
        selection = snapshot.selection
        selection.prune(to: mesh)
        selectedIndex = selection.indices(in: mesh).sorted().first
    }

    func resetMesh() {
        let before = snapshot()
        let sticky = mesh.stickyBorders
        let propagation = mesh.propagation
        if let identity = MeshWarpGrid.identity(pointColumns: mesh.pointColumns, pointRows: mesh.pointRows,
                                                stickyBorders: sticky, propagation: propagation) {
            mesh = identity
        } else {
            mesh.resetToRest()
        }
        selection.clear()
        selectedIndex = nil
        previewImage = nil
        previewCIImage = nil
        lastWarning = nil
        history.push(before)
        gpuSession?.invalidate()
    }

    @discardableResult
    func subdivideSelection() -> MeshWarpTopologyResult {
        let before = snapshot()
        let result = mesh.subdivideSelectedQuads(containingVertexIndices: selection.indices(in: mesh))
        if !result.succeeded.isEmpty {
            selection.prune(to: mesh)
            history.push(before)
            refreshPreview(waitForGPU: true)
        } else {
            lastWarning = result.message
        }
        return result
    }

    @discardableResult
    func mergeSelection() -> MeshWarpTopologyResult {
        let before = snapshot()
        let result = mesh.mergeSelectedChildGroup(containingVertexIndices: selection.indices(in: mesh))
        if !result.succeeded.isEmpty {
            selection.prune(to: mesh)
            history.push(before)
            refreshPreview(waitForGPU: true)
        } else {
            lastWarning = result.message
        }
        return result
    }

    func toolUndo() -> Bool {
        guard let previous = history.undo(current: snapshot()) else { return false }
        apply(snapshot: previous)
        refreshPreview(waitForGPU: true)
        return true
    }

    func toolRedo() -> Bool {
        guard let next = history.redo(current: snapshot()) else { return false }
        apply(snapshot: next)
        refreshPreview(waitForGPU: true)
        return true
    }

    /// Rebuilds the preview from the current mesh. Prefer a GPU-resident texture; fall back to CPU/`CGImage`.
    func refreshPreview(waitForGPU: Bool = true) {
        if mesh.isIdentity {
            previewImage = nil
            previewCIImage = nil
            return
        }
        var sample = MeshWarpRenderer.Sample()
        if let session = gpuSession {
            var gpuSample = MetalMeshWarpSession.Sample()
            if session.render(mesh: mesh, sample: &gpuSample, wait: waitForGPU) {
                previewCIImage = session.image
                previewImage = nil
                previewGeneration = gpuSample.generation
                sample.usedMetal = true
                sample.usedResidentPreview = true
                sample.triangleUploadMilliseconds = gpuSample.triangleUploadMilliseconds
                sample.kernelMilliseconds = gpuSample.kernelMilliseconds
                sample.gpuMilliseconds = gpuSample.gpuMilliseconds
                sample.endToEndMilliseconds = gpuSample.endToEndMilliseconds
                lastPreviewSample = sample
                return
            }
        }
        previewCIImage = nil
        previewImage = MeshWarpRenderer.apply(source: originalImage, mesh: mesh, sample: &sample)
        lastPreviewSample = sample
    }

    /// Full-resolution pixels for Apply, matching the latest preview mesh.
    func commitImage(sample: inout MeshWarpRenderer.Sample) -> CGImage? {
        if mesh.isIdentity { return originalImage }
        if let session = gpuSession {
            var gpuSample = MetalMeshWarpSession.Sample()
            if session.render(mesh: mesh, sample: &gpuSample, wait: true) {
                var metalSample = MetalMeshWarp.Sample()
                if let image = session.readbackCGImage(sample: &metalSample) {
                    sample.usedMetal = true
                    sample.usedResidentPreview = true
                    sample.triangleUploadMilliseconds = gpuSample.triangleUploadMilliseconds
                    sample.kernelMilliseconds = gpuSample.kernelMilliseconds
                    sample.gpuMilliseconds = gpuSample.gpuMilliseconds
                    sample.readbackMilliseconds = metalSample.readbackMilliseconds
                    sample.endToEndMilliseconds = gpuSample.endToEndMilliseconds + metalSample.readbackMilliseconds
                    return image
                }
            }
        }
        return MeshWarpRenderer.apply(source: originalImage, mesh: mesh, sample: &sample)
    }

    func beginGesture() {
        gestureBasePositions = mesh.positions
        gestureBaseSelection = selection
        gestureDidMutate = false
    }

    func endGesture() {
        defer {
            gestureBasePositions = nil
            gestureDidMutate = false
        }
        guard gestureDidMutate, let base = gestureBasePositions else { return }
        var beforeMesh = mesh
        beforeMesh.positions = base
        beforeMesh.topology.writeBack(positions: base)
        history.push(MeshWarpHistorySnapshot(mesh: beforeMesh, selection: gestureBaseSelection))
    }

    @discardableResult
    func moveSelected(toPrimaryDestination destination: SIMD2<Float>, primary: Int) -> Bool {
        guard let base = gestureBasePositions else { return false }
        let ok = mesh.tryMove(index: primary, to: destination,
                              imageWidth: width, imageHeight: height, base: base)
        if ok { gestureDidMutate = true }
        return ok
    }

    @discardableResult
    func transformSelection(mode: MeshWarpTransformMode,
                            translation: SIMD2<Float> = .zero,
                            rotationRadians: Float = 0,
                            scale: Float = 1) -> Bool {
        let selected = selection.indices(in: mesh)
        guard !selected.isEmpty, let base = gestureBasePositions,
              let pivot = MeshWarpGrid.barycenter(indices: selected, in: base) else { return false }
        let ok = mesh.applySelectionTransform(selected: selected, imageWidth: width, imageHeight: height, base: base) { point in
            switch mode {
            case .move:
                return point + translation
            case .rotate:
                let relative = point - pivot
                let c = cos(rotationRadians), s = sin(rotationRadians)
                return pivot + SIMD2(relative.x * c - relative.y * s, relative.x * s + relative.y * c)
            case .scale:
                return pivot + (point - pivot) * scale
            }
        }
        if ok { gestureDidMutate = true }
        return ok
    }

    @discardableResult
    func resetSelectedPoints() -> Bool {
        let selected = selection.indices(in: mesh)
        guard !selected.isEmpty else { return false }
        let before = snapshot()
        var trial = mesh.positions
        for index in selected { trial[index] = mesh.rest[index] }
        var trialTopology = mesh.topology
        trialTopology.writeBack(positions: trial)
        guard MeshWarpGrid.leafTrianglesValid(trialTopology) else {
            lastWarning = "Resetting the selection would fold the mesh."
            return false
        }
        mesh.positions = trial
        mesh.topology = trialTopology
        history.push(before)
        refreshPreview(waitForGPU: true)
        return true
    }

    /// Apply a local Perspective / Horizon / Volume correction to the current selection.
    @discardableResult
    func applyLocalCorrection(_ correction: MeshWarpLocalCorrection,
                              policy: MeshWarpDisjointRegionPolicy = .independent) -> MeshWarpLocalStatus {
        let region = MeshWarpCorrectionRegion.fromSelection(selection, mesh: mesh, policy: policy)
        guard !region.resolvedVertexIndices(in: mesh).isEmpty else {
            let status = MeshWarpLocalStatus.rejected("empty selection region")
            lastWarning = status.reason
            return status
        }
        let before = snapshot()
        let status = mesh.applyLocalCorrection(correction, region: region,
                                               imageWidth: width, imageHeight: height,
                                               base: mesh.positions)
        if status.ok {
            history.push(before)
            lastWarning = nil
            refreshPreview(waitForGPU: true)
        } else {
            lastWarning = status.reason
        }
        return status
    }
}

extension EditorSession {
    var canBeginMeshWarp: Bool {
        guard canEditLayers, brushStroke == nil, warpStroke == nil, levels == nil,
              filterEdit == nil, transformEdit == nil,
              let layer = activeLayer, layer.asset != nil || layer.reshape != nil, !layer.isGroup,
              activeLayerID.map({ document?.effectiveVisibleIDs.contains($0) == true }) == true
        else { return false }
        return true
    }

    /// Message when a destructive pixel edit would discard editable ReShape state.
    func reshapeDestructiveRefusal(for layer: ImageLayer) -> String? {
        guard layer.reshape != nil else { return nil }
        return "“\(layer.name)” has an editable ReShape mesh. Bake ReShape before painting or applying filters."
    }

    func beginMeshWarp(preset: MeshWarpGrid.Preset = .points8) {
        cancelMeshWarp()
        guard canBeginMeshWarp, let layer = activeLayer else {
            brushError = paintRefusal
            return
        }
        if let refusal = reshapeRefusal(for: layer) {
            brushError = refusal.reason
            return
        }
        let sourceAsset: ImportedImage
        let mesh: MeshWarpGrid
        if let reshape = layer.reshape {
            sourceAsset = reshape.source
            mesh = reshape.mesh
        } else if let asset = layer.asset {
            sourceAsset = asset
            guard let identity = MeshWarpGrid.identity(pointColumns: preset.rawValue, pointRows: preset.rawValue,
                                                       stickyBorders: true, propagation: 0.25)
            else { return }
            mesh = identity
        } else {
            return
        }
        pauseGIFForEditing(for: layer.id)
        finishOpacityEdit()
        commitTransform()
        cancelCrop()
        tool = .reshape
        meshWarpEdit = MeshWarpEdit(layerID: layer.id, layerName: layer.name, image: sourceAsset.image,
                                    transform: displayedTransform(for: layer), mesh: mesh,
                                    thumbnail: sourceAsset.thumbnail)
    }

    func cancelMeshWarp() {
        guard let edit = meshWarpEdit else { return }
        edit.gpuSessionInvalidate()
        meshWarpEdit = nil
        brushRevision += 1
    }

    /// Clears editable mesh state, keeping the current rendered layer pixels as the new source.
    /// One document-history entry. Required before painting or filters on a ReShape layer.
    func bakeReshape(layerID: UUID? = nil) {
        let id = layerID ?? activeLayerID
        guard canEditLayers, let id,
              let index = document?.layers.firstIndex(where: { $0.id == id }),
              var layer = document?.layers[index],
              layer.reshape != nil else { return }
        if meshWarpEdit?.layerID == id { cancelMeshWarp() }
        beginEdit("Bake ReShape")
        layer.reshape = nil
        document?.layers[index] = layer
        endEdit()
        brushRevision += 1
    }

    func setMeshWarpPreset(_ preset: MeshWarpGrid.Preset) {
        guard let edit = meshWarpEdit else { return }
        let before = edit.snapshot()
        let sticky = edit.mesh.stickyBorders
        let propagation = edit.mesh.propagation
        guard let mesh = MeshWarpGrid.identity(pointColumns: preset.rawValue, pointRows: preset.rawValue,
                                               stickyBorders: sticky, propagation: propagation) else { return }
        edit.mesh = mesh
        edit.selection.clear()
        edit.selectedIndex = nil
        edit.previewImage = nil
        edit.previewCIImage = nil
        edit.lastWarning = nil
        edit.history.push(before)
        brushRevision += 1
    }

    func setMeshWarpStickyBorders(_ value: Bool) {
        meshWarpEdit?.mesh.stickyBorders = value
        brushRevision += 1
    }

    func setMeshWarpPropagation(_ value: Float) {
        meshWarpEdit?.mesh.propagation = max(0, min(1, value))
        brushRevision += 1
    }

    func resetMeshWarp() {
        meshWarpEdit?.resetMesh()
        brushRevision += 1
    }

    func meshWarpToolUndo() {
        guard let edit = meshWarpEdit else { return }
        if edit.toolUndo() { brushRevision += 1 }
    }

    func meshWarpToolRedo() {
        guard let edit = meshWarpEdit else { return }
        if edit.toolRedo() { brushRevision += 1 }
    }

    /// Commits editable mesh + immutable source and refreshes display pixels as one undo step.
    func applyMeshWarp() {
        guard let edit = meshWarpEdit,
              let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
              let layer = document?.layers[index]
        else {
            cancelMeshWarp()
            return
        }
        if edit.mesh.isIdentity {
            // Identity with prior persistent mesh: restore source as display and clear reshape.
            if layer.reshape != nil {
                let source = ImportedImage(image: edit.originalImage, thumbnail: edit.originalThumbnail,
                                           name: layer.name)
                do {
                    var edited = try layerByEditingPixels(layer, asset: source, transform: layer.transform, mask: layer.mask)
                    edited.reshape = nil
                    beginEdit("ReShape")
                    document?.layers[index] = edited
                    endEdit()
                } catch {
                    brushError = error.localizedDescription
                    return
                }
            }
            edit.gpuSessionInvalidate()
            meshWarpEdit = nil
            brushRevision += 1
            return
        }
        var sample = MeshWarpRenderer.Sample()
        guard let warped = edit.commitImage(sample: &sample),
              let thumbnail = try? PixelAdjust.thumbnail(of: warped)
        else {
            brushError = "ReShape could not render the mesh."
            return
        }
        let display = ImportedImage(image: warped, thumbnail: thumbnail, name: layer.name)
        let source = ImportedImage(image: edit.originalImage, thumbnail: edit.originalThumbnail, name: layer.name)
        // Retain both display and source against the document budget.
        let used = (document?.layers ?? []).reduce(0) { total, candidate in
            let assetPixels = candidate.id == layer.id ? 0
                : (candidate.asset.map { $0.image.width * $0.image.height } ?? 0)
            let reshapePixels = candidate.id == layer.id ? 0
                : (candidate.reshape.map { $0.source.image.width * $0.source.image.height } ?? 0)
            let frames = candidate.gifAnimation?.framePixels.values
                .reduce(0) { $0 + $1.image.width * $1.image.height } ?? 0
            return total + assetPixels + reshapePixels + frames
        }
        let needed = display.image.width * display.image.height
            + source.image.width * source.image.height
        guard needed <= DocumentLimits.documentPixelBudget - used else {
            brushError = "ReShape source and result exceed this project’s \(DocumentLimits.documentBudgetMegapixels)-megapixel limit."
            return
        }
        do {
            var edited = try layerByEditingPixels(layer, asset: display, transform: layer.transform, mask: layer.mask)
            edited.reshape = LayerReshape(mesh: edit.mesh, source: source)
            beginEdit("ReShape")
            document?.layers[index] = edited
            endEdit()
            edit.gpuSessionInvalidate()
            meshWarpEdit = nil
            brushRevision += 1
        } catch {
            brushError = error.localizedDescription
        }
    }

    /// Document-space point → UV on the edited layer.
    func meshWarpUV(documentPoint: CGPoint) -> SIMD2<Float>? {
        guard let edit = meshWarpEdit else { return nil }
        let inverse = edit.transform.unitToDocument.inverted()
        let unit = documentPoint.applying(inverse)
        return SIMD2(Float(unit.x), Float(unit.y))
    }

    func meshWarpHitTest(documentPoint: CGPoint, viewRadius: CGFloat, viewportScale: CGFloat) -> Int? {
        guard let edit = meshWarpEdit, let uv = meshWarpUV(documentPoint: documentPoint) else { return nil }
        let layerWidth = max(edit.transform.size.width, 1) * viewportScale
        let radius = Float(viewRadius / max(layerWidth, 1))
        return edit.mesh.hitTest(uv: uv, radius: max(radius, 0.01))
    }

    func meshWarpBeginDrag(at documentPoint: CGPoint, viewRadius: CGFloat, viewportScale: CGFloat,
                           shift: Bool = false) -> Bool {
        guard let edit = meshWarpEdit else { return false }
        guard let index = meshWarpHitTest(documentPoint: documentPoint, viewRadius: viewRadius, viewportScale: viewportScale)
        else { return false }
        if edit.mesh.stickyBorders, edit.mesh.isCorner(index) {
            edit.lastWarning = "Sticky Borders keeps corner points fixed."
            brushRevision += 1
            return false
        }
        if shift {
            edit.selection.toggle(index: index, in: edit.mesh)
        } else if !edit.selection.contains(index: index, in: edit.mesh) {
            edit.selection.selectOnly(index: index, in: edit.mesh)
        }
        edit.selectedIndex = index
        edit.lastWarning = nil
        edit.beginGesture()
        brushRevision += 1
        return true
    }

    func meshWarpDrag(to documentPoint: CGPoint) {
        guard let edit = meshWarpEdit, let index = edit.selectedIndex,
              let uv = meshWarpUV(documentPoint: documentPoint) else { return }
        let ok: Bool
        if edit.selection.count > 1, edit.selection.contains(index: index, in: edit.mesh),
           let base = edit.gestureBasePositions {
            let translation = uv - base[index]
            ok = edit.transformSelection(mode: .move, translation: translation)
        } else {
            ok = edit.moveSelected(toPrimaryDestination: uv, primary: index)
        }
        if !ok {
            edit.lastWarning = "That move would fold the mesh."
            brushRevision += 1
            return
        }
        edit.lastWarning = nil
        edit.refreshPreview(waitForGPU: true)
        brushRevision += 1
    }

    func meshWarpEndDrag() {
        guard let edit = meshWarpEdit else { return }
        edit.endGesture()
        edit.refreshPreview(waitForGPU: true)
        brushRevision += 1
    }

    func meshWarpSelectAll() {
        guard let edit = meshWarpEdit else { return }
        edit.selection.selectAll(in: edit.mesh)
        edit.selectedIndex = edit.selection.indices(in: edit.mesh).sorted().first
        brushRevision += 1
    }

    func meshWarpClearSelection() {
        guard let edit = meshWarpEdit else { return }
        edit.selection.clear()
        edit.selectedIndex = nil
        brushRevision += 1
    }

    func meshWarpSelectMarquee(documentRect: CGRect, additive: Bool) {
        guard let edit = meshWarpEdit else { return }
        let inverse = edit.transform.unitToDocument.inverted()
        let a = documentRect.origin.applying(inverse)
        let b = CGPoint(x: documentRect.maxX, y: documentRect.maxY).applying(inverse)
        let uvRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                            width: abs(a.x - b.x), height: abs(a.y - b.y))
        edit.selection.selectMarquee(uvRect: uvRect, mesh: edit.mesh, additive: additive)
        edit.selectedIndex = edit.selection.indices(in: edit.mesh).sorted().first
        brushRevision += 1
    }

    func meshWarpSubdivideSelection() {
        guard let edit = meshWarpEdit else { return }
        _ = edit.subdivideSelection()
        brushRevision += 1
    }

    func meshWarpMergeSelection() {
        guard let edit = meshWarpEdit else { return }
        _ = edit.mergeSelection()
        brushRevision += 1
    }
}

extension MeshWarpEdit {
    fileprivate func gpuSessionInvalidate() {
        gpuSession?.invalidate()
        gpuSession = nil
    }

    /// CG canvas fallback: read the resident destination once. Prefer the GPU `previewCIImage` path.
    func commitImageForCanvas() -> CGImage? {
        var sample = MetalMeshWarp.Sample()
        return gpuSession?.readbackCGImage(sample: &sample)
    }
}
