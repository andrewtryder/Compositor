import AppKit
import CoreImage
import Foundation

/// In-progress ReShape mesh edit on one layer. Apply rasterizes into the layer (undoable);
/// Cancel restores the snapshot taken at begin.
@Observable
final class MeshWarpEdit {
    let layerID: UUID
    let layerName: String
    /// Layer pixel size when editing began.
    let width: Int
    let height: Int
    /// Original layer pixels (8-bit RGBA preview path).
    let originalImage: CGImage
    /// Layer transform at begin (placement unchanged by warp).
    let transform: LayerTransform
    var mesh: MeshWarpGrid
    var selectedIndex: Int?
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

    @ObservationIgnored private var gpuSession: MetalMeshWarpSession?

    init(layerID: UUID, layerName: String, image: CGImage, transform: LayerTransform, mesh: MeshWarpGrid) {
        self.layerID = layerID
        self.layerName = layerName
        self.width = image.width
        self.height = image.height
        self.originalImage = image
        self.transform = transform
        self.mesh = mesh
        self.gpuSession = MetalMeshWarpSession(image: image)
    }

    var displayedImage: CGImage { previewImage ?? originalImage }
    var usesGPUResidentPreview: Bool { previewCIImage != nil }

    func resetMesh() {
        mesh.resetToRest()
        selectedIndex = nil
        previewImage = nil
        previewCIImage = nil
        lastWarning = nil
        gpuSession?.invalidate()
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
            // Ensure the destination matches the current mesh (in case the last drag skipped wait).
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
}

extension EditorSession {
    var canBeginMeshWarp: Bool {
        guard canEditLayers, brushStroke == nil, warpStroke == nil, levels == nil,
              filterEdit == nil, transformEdit == nil,
              let layer = activeLayer, layer.asset != nil, !layer.isGroup,
              activeLayerID.map({ document?.effectiveVisibleIDs.contains($0) == true }) == true
        else { return false }
        return true
    }

    func beginMeshWarp(preset: MeshWarpGrid.Preset = .points8) {
        cancelMeshWarp()
        guard canBeginMeshWarp, let layer = activeLayer, let asset = layer.asset else {
            brushError = paintRefusal
            return
        }
        if asset.deep != nil || DeepLayer.isHDR(asset.image) {
            brushError = "ReShape currently supports 8-bit layers. Convert the layer to 8-bit first."
            return
        }
        guard let mesh = MeshWarpGrid.identity(pointColumns: preset.rawValue, pointRows: preset.rawValue,
                                               stickyBorders: true, propagation: 0.25)
        else { return }
        pauseGIFForEditing(for: layer.id)
        finishOpacityEdit()
        commitTransform()
        cancelCrop()
        tool = .reshape
        meshWarpEdit = MeshWarpEdit(layerID: layer.id, layerName: layer.name, image: asset.image,
                                    transform: displayedTransform(for: layer), mesh: mesh)
    }

    func cancelMeshWarp() {
        guard let edit = meshWarpEdit else { return }
        edit.gpuSessionInvalidate()
        meshWarpEdit = nil
        brushRevision += 1
    }

    func setMeshWarpPreset(_ preset: MeshWarpGrid.Preset) {
        guard let edit = meshWarpEdit else { return }
        let sticky = edit.mesh.stickyBorders
        let propagation = edit.mesh.propagation
        guard let mesh = MeshWarpGrid.identity(pointColumns: preset.rawValue, pointRows: preset.rawValue,
                                               stickyBorders: sticky, propagation: propagation) else { return }
        edit.mesh = mesh
        edit.selectedIndex = nil
        edit.previewImage = nil
        edit.previewCIImage = nil
        edit.lastWarning = nil
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

    /// Commits the warped pixels into the layer as one undo step.
    func applyMeshWarp() {
        guard let edit = meshWarpEdit,
              let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
              let layer = document?.layers[index],
              layer.asset != nil
        else {
            cancelMeshWarp()
            return
        }
        if edit.mesh.isIdentity {
            cancelMeshWarp()
            return
        }
        var sample = MeshWarpRenderer.Sample()
        guard let warped = edit.commitImage(sample: &sample),
              let thumbnail = try? PixelAdjust.thumbnail(of: warped)
        else {
            brushError = "ReShape could not render the mesh."
            return
        }
        let asset = ImportedImage(image: warped, thumbnail: thumbnail, name: layer.name)
        do {
            let edited = try layerByEditingPixels(layer, asset: asset, transform: layer.transform, mask: layer.mask)
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

    func meshWarpBeginDrag(at documentPoint: CGPoint, viewRadius: CGFloat, viewportScale: CGFloat) -> Bool {
        guard let edit = meshWarpEdit else { return false }
        guard let index = meshWarpHitTest(documentPoint: documentPoint, viewRadius: viewRadius, viewportScale: viewportScale)
        else { return false }
        if edit.mesh.stickyBorders, edit.mesh.isBorder(index) {
            edit.lastWarning = "Sticky Borders keeps edge points fixed."
            brushRevision += 1
            return false
        }
        edit.selectedIndex = index
        edit.lastWarning = nil
        brushRevision += 1
        return true
    }

    func meshWarpDrag(to documentPoint: CGPoint) {
        guard let edit = meshWarpEdit, let index = edit.selectedIndex,
              let uv = meshWarpUV(documentPoint: documentPoint) else { return }
        if !edit.mesh.tryMove(index: index, to: uv) {
            edit.lastWarning = "That move would fold the mesh."
            brushRevision += 1
            return
        }
        edit.lastWarning = nil
        edit.refreshPreview(waitForGPU: true)
        brushRevision += 1
    }

    func meshWarpEndDrag() {
        meshWarpEdit?.refreshPreview(waitForGPU: true)
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
