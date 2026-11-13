import CoreGraphics
import Foundation

/// Aspect policy for geometry-aware crop. Reuses `CropGeometry` math where possible.
nonisolated enum CameraRawCropAspectMode: String, CaseIterable, Sendable, Codable {
    case free = "Free"
    case original = "Original"
    case fixed = "Fixed"
}

/// Backend crop / framing request after geometry. Does not resize the document canvas by itself.
nonisolated struct CameraRawGeometryCropRequest: Equatable, Sendable, Codable {
    var framing: CameraRawFramingMode = .keepOriginalSize
    var automaticOpaqueCrop = false
    /// Manual crop in the corrected image's CG pixel space (origin top-left), stored as x,y,w,h. Empty → unused.
    var manualCropScalars: [Double] = []
    var aspectMode: CameraRawCropAspectMode = .free
    /// width/height when `aspectMode == .fixed`.
    var aspectRatio: Double = 1
    /// When true, the crop rectangle is intersected with opaque pixels / transformed bounds.
    var constrainToImage = true

    var manualCrop: CGRect? {
        get {
            guard manualCropScalars.count == 4 else { return nil }
            return CGRect(x: manualCropScalars[0], y: manualCropScalars[1],
                          width: manualCropScalars[2], height: manualCropScalars[3])
        }
        set {
            if let newValue {
                manualCropScalars = [newValue.origin.x, newValue.origin.y, newValue.size.width, newValue.size.height]
            } else {
                manualCropScalars = []
            }
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        framing = try values.decodeIfPresent(CameraRawFramingMode.self, forKey: .framing) ?? base.framing
        automaticOpaqueCrop = try values.decodeIfPresent(Bool.self, forKey: .automaticOpaqueCrop) ?? base.automaticOpaqueCrop
        manualCropScalars = try values.decodeIfPresent([Double].self, forKey: .manualCropScalars) ?? base.manualCropScalars
        aspectMode = try values.decodeIfPresent(CameraRawCropAspectMode.self, forKey: .aspectMode) ?? base.aspectMode
        aspectRatio = try values.decodeIfPresent(Double.self, forKey: .aspectRatio) ?? base.aspectRatio
        constrainToImage = try values.decodeIfPresent(Bool.self, forKey: .constrainToImage) ?? base.constrainToImage
    }
}

/// Coordinate conversions and crop planning for Camera Raw geometry. Automatic opaque crop keeps the existing
/// largest-inscribed-opaque-rectangle algorithm in `CameraRawGeometrySettings`.
nonisolated enum CameraRawGeometryCrop {
    /// Document rect ↔ layer-pixel rect using the same mapping as brushes.
    static func layerPixels(fromDocument rect: CGRect, transform: LayerTransform, width: Int, height: Int) -> CGRect {
        let toPixels = BrushRaster.pixelToDocument(transform, width: width, height: height).inverted()
        return CropGeometry.snapped(rect.applying(toPixels))
    }

    static func document(fromLayerPixels rect: CGRect, transform: LayerTransform, width: Int, height: Int) -> CGRect {
        let toDocument = BrushRaster.pixelToDocument(transform, width: width, height: height)
        return CropGeometry.snapped(rect.applying(toDocument))
    }

    /// Corrected-image crop from an input-space rectangle after Expand coverage is known.
    static func corrected(fromInput rect: CGRect, expansion: CameraRawGeometryExpansion?) -> CGRect {
        guard let expansion else { return CropGeometry.snapped(rect) }
        let shifted = rect.offsetBy(dx: -expansion.coverageInInput.minX, dy: -expansion.coverageInInput.minY)
        return CropGeometry.snapped(shifted)
    }

    static func input(fromCorrected rect: CGRect, expansion: CameraRawGeometryExpansion?) -> CGRect {
        guard let expansion else { return CropGeometry.snapped(rect) }
        let shifted = rect.offsetBy(dx: expansion.coverageInInput.minX, dy: expansion.coverageInInput.minY)
        return CropGeometry.snapped(shifted)
    }

    /// Fits `rect` to `aspect` (width/height), preserving center. Uses the same snap rules as document crop.
    static func constraining(_ rect: CGRect, toAspect aspect: CGFloat?) -> CGRect {
        guard let aspect, aspect > 0, aspect.isFinite else { return CropGeometry.snapped(rect) }
        var size = rect.size
        if size.width / max(size.height, 1) > aspect {
            size.width = size.height * aspect
        } else {
            size.height = size.width / aspect
        }
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        return CropGeometry.snapped(CGRect(origin: origin, size: size))
    }

    /// Plans a crop rectangle in corrected image pixels for `image` after geometry.
    static func plan(request: CameraRawGeometryCropRequest, image: CGImage,
                     originalSize: CGSize) throws -> CGRect? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var rect: CGRect?
        if request.automaticOpaqueCrop || request.constrainToImage && request.manualCrop == nil {
            // Reuse Constrain Crop's opaque inscribed rectangle by running geometry settings.
            var geometry = CameraRawGeometrySettings()
            geometry.constrainCrop = true
            geometry.framingMode = .expandToFit
            // Only crop: applyConstrainCropResult needs opaque analysis — call through a no-warp path.
            rect = try opaqueInscribedRect(in: image)
        }
        if let manual = request.manualCrop {
            rect = CropGeometry.snapped(manual.intersection(bounds))
        }
        guard var crop = rect, crop.width >= 1, crop.height >= 1 else { return nil }
        switch request.aspectMode {
        case .free:
            break
        case .original:
            let aspect = originalSize.width / max(originalSize.height, 1)
            crop = constraining(crop, toAspect: aspect)
        case .fixed:
            crop = constraining(crop, toAspect: CGFloat(request.aspectRatio))
        }
        if request.constrainToImage {
            crop = crop.intersection(bounds)
            if let opaque = try opaqueInscribedRect(in: image) {
                crop = crop.intersection(opaque)
            }
        }
        return CropGeometry.valid(crop) ? CropGeometry.snapped(crop) : nil
    }

    /// Largest opaque inscribed rectangle — shared with Constrain Crop's algorithm via a temporary settings apply.
    static func opaqueInscribedRect(in image: CGImage) throws -> CGRect? {
        let width = image.width, height = image.height
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data else { return nil }
        return CameraRawGeometrySettings.inscribedOpaqueRect(bytes: data.assumingMemoryBound(to: UInt8.self),
                                                             width: width, height: height,
                                                             stride: context.bytesPerRow)
    }
}
