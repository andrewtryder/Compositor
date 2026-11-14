import CoreGraphics
import Foundation

/// Stable backend contracts for a later Photoshop-style GUI. Global Camera Raw geometry and local
/// ReShape stay separate operations; this type only documents ownership, precision, and bake rules.
nonisolated enum UnifiedGeometryBackend {
    /// Correction families a GUI can address without conflating their math.
    enum Domain: String, Sendable, CaseIterable {
        /// Camera Raw → Geometry / Optics: lens, volume, perspective, horizon, framing, crop.
        case cameraRawGeometry
        /// Edit → Transform → Warp: editable mesh deformation with persistent source.
        case reshapeMesh
        /// Filter → Blur Gallery: Miniature / tilt-shift (post-geometry raster effect).
        case miniature
        /// Document placement: layer transforms, masks, canvas/image size.
        case layerDocument
    }

    /// Precision a layer currently supports for a domain.
    enum PrecisionSupport: String, Sendable {
        case eightBit
        case sixteenBit
        case hdr
        case unsupported
    }

    /// Why an operation was refused. Never implies a silent bake.
    nonisolated struct Refusal: Equatable, Sendable, LocalizedError {
        var reason: String
        var requiresBake: Bool
        var errorDescription: String? { reason }
    }

    /// Intended Adobe-style menu placement (documentation for a future UI; not wired).
    static let guiPlacement: [(menu: String, items: [String])] = [
        ("Camera Raw → Geometry", [
            "Upright Auto / Level / Vertical / Full / Guided",
            "Auto Horizontal (where supported)",
            "Manual Vertical / Horizontal / Rotate / Aspect / Scale / Offset",
            "Perspective Amount",
            "Horizon references",
            "Advanced perspective tools",
            "Framing and crop (Keep Original Size / Expand to Fit)",
        ]),
        ("Camera Raw → Optics", [
            "Lens correction",
            "Volume Deformation",
        ]),
        ("Edit → Transform → Warp", [
            "Editable ReShape",
            "Move / Rotate / Scale",
            "Multi-selection, Propagation, Sticky Borders",
            "Subdivide / Merge",
            "Local Perspective / Horizon / Volume",
            "Reopen editable correction",
            "Bake correction",
        ]),
        ("Filter → Blur Gallery", [
            "Miniature / Tilt-Shift",
        ]),
    ]

    /// Composition order for Camera Raw full-resolution apply (unchanged from geometry backend).
    static var cameraRawCompositionOrder: [String] { CameraRawGeometryBackend.compositionOrder }

    /// Non-destructive stack (M8.7): `LayerCorrectionStack` on the layer stores ordered geometry
    /// nodes (Camera Raw geometry family + ReShape), always renders from an immutable source,
    /// invalidates downstream stage caches on edits, and round-trips in project format v23.
    /// Full Camera Raw color-grade Smart Filters, deep/HDR ReShape, and Expand+ReShape remapping
    /// remain out of scope; Expand to Fit with ReShape is refused explicitly.
    static let futureNonDestructiveStackNotes = """
    LayerCorrectionStack supports Camera Raw geometry ↔ ReShape coexistence with dimension-preserving \
    framing. Destructive Filters/painting still require Bake. Deep/HDR stacks and Expand+ReShape \
    remapping are not implemented.
    """
}

extension EditorSession {
    /// Precision available for ReShape on `layer`.
    func reshapePrecision(for layer: ImageLayer) -> UnifiedGeometryBackend.PrecisionSupport {
        let asset = layer.reshape?.source ?? layer.asset
        guard let asset else { return .unsupported }
        if asset.deep != nil || DeepLayer.isHDR(asset.image) { return .unsupported }
        if asset.image.bitsPerComponent > 8 { return .unsupported }
        return .eightBit
    }

    /// Precision available for Camera Raw geometry on `layer`.
    func cameraRawPrecision(for layer: ImageLayer) -> UnifiedGeometryBackend.PrecisionSupport {
        guard let asset = layer.asset else { return .unsupported }
        if DeepLayer.isHDR(asset.image) || (asset.deep != nil && DeepLayer.isHDR(asset.deep!)) {
            return .hdr
        }
        if asset.deep != nil || asset.image.bitsPerComponent > 8 { return .sixteenBit }
        return .eightBit
    }

    /// Destructive Camera Raw filter path on an editable correction stack / ReShape layer.
    /// Non-destructive stack edits use `editCorrection` / `addCorrection` instead.
    func cameraRawRefusal(for layer: ImageLayer) -> UnifiedGeometryBackend.Refusal? {
        if layer.correctionStack != nil {
            return UnifiedGeometryBackend.Refusal(
                reason: "“\(layer.name)” has an editable geometry correction stack. Edit the Camera Raw geometry node, or Bake corrections before applying the Camera Raw filter.",
                requiresBake: true)
        }
        if let message = reshapeDestructiveRefusal(for: layer) {
            return UnifiedGeometryBackend.Refusal(reason: message, requiresBake: true)
        }
        return nil
    }

    /// ReShape begin restrictions for `layer`.
    func reshapeRefusal(for layer: ImageLayer) -> UnifiedGeometryBackend.Refusal? {
        if layer.gifAnimation != nil {
            return UnifiedGeometryBackend.Refusal(
                reason: "ReShape cannot edit an animated GIF layer. Rasterize the frame first.",
                requiresBake: false)
        }
        switch reshapePrecision(for: layer) {
        case .eightBit:
            return nil
        case .sixteenBit, .hdr, .unsupported:
            return UnifiedGeometryBackend.Refusal(
                reason: "ReShape currently supports 8-bit layers. Convert the layer to 8-bit first.",
                requiresBake: false)
        }
    }

    /// Explicit bake entry point for a future GUI (same as `bakeReshape`).
    func bakeReshapeForCameraRaw(layerID: UUID? = nil) {
        bakeReshape(layerID: layerID)
    }
}
