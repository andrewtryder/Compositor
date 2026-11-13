import CoreGraphics
import Foundation

/// Result of Camera Raw geometry when the output footprint may differ from the input.
nonisolated struct CameraRawGeometryResult: Sendable {
    let image: CGImage
    /// Non-nil when Expand to Fit (possibly after Constrain Crop) changed the layer pixel grid.
    let expansion: CameraRawGeometryExpansion?
}

/// Maps an expanded (or cropped-expanded) geometry result back onto the document without moving siblings.
///
/// `coverageInInput` is the axis-aligned rectangle in the *input* layer's CG pixel space (origin top-left, y down)
/// that the output image covers 1:1. It may extend outside the original 0…width × 0…height bounds.
nonisolated struct CameraRawGeometryExpansion: Equatable, Sendable {
    let inputWidth: Int
    let inputHeight: Int
    let coverageInInput: CGRect

    var outputWidth: Int { max(1, Int(coverageInInput.width.rounded())) }
    var outputHeight: Int { max(1, Int(coverageInInput.height.rounded())) }

    var isIdentityFootprint: Bool {
        abs(coverageInInput.minX) < 0.5 && abs(coverageInInput.minY) < 0.5
            && abs(coverageInInput.width - CGFloat(inputWidth)) < 0.5
            && abs(coverageInInput.height - CGFloat(inputHeight)) < 0.5
    }

    /// Document placement for the expanded pixels, preserving rotation/flip/sampling and the visual position of
    /// content that still corresponds to the original coverage region (same rule as FilterEdit blur growth).
    func layerTransform(from base: LayerTransform) -> LayerTransform {
        let bounds = CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight)
        let target = bounds.union(coverageInInput).integral
        var expanded = base
        expanded.size = CGSize(width: target.width * base.size.width / bounds.width,
                               height: target.height * base.size.height / bounds.height)
        let toDocument = BrushRaster.pixelToDocument(base, width: inputWidth, height: inputHeight)
        let middle = CGPoint(x: target.midX, y: target.midY).applying(toDocument)
        expanded.origin = CGPoint(x: middle.x - expanded.size.width / 2, y: middle.y - expanded.size.height / 2)
        return expanded
    }

    /// After Constrain Crop removes empty margins inside an expanded canvas, shrink coverage to the kept rectangle.
    func cropping(to rect: CGRect) -> CameraRawGeometryExpansion? {
        let kept = CGRect(x: coverageInInput.minX + rect.minX,
                          y: coverageInInput.minY + rect.minY,
                          width: rect.width,
                          height: rect.height)
        guard kept.width >= 1, kept.height >= 1,
              kept.width.isFinite, kept.height.isFinite else { return nil }
        return CameraRawGeometryExpansion(inputWidth: inputWidth, inputHeight: inputHeight, coverageInInput: kept)
    }
}

extension CameraRawPerspective {
    /// CIPerspectiveTransform corners (y up from the bottom of the *input*) → coverage in layer CG pixels (y down).
    static func coverageInLayerPixels(corners: [CGPoint], width: Int, height: Int) -> CGRect? {
        guard width > 0, height > 0, corners.count == 4,
              corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let h = Double(height)
        let cg = corners.map { CGPoint(x: $0.x, y: h - $0.y) }
        let minX = cg.map(\.x).min()!, maxX = cg.map(\.x).max()!
        let minY = cg.map(\.y).min()!, maxY = cg.map(\.y).max()!
        let w = maxX - minX, ht = maxY - minY
        guard w.isFinite, ht.isFinite, w > 0.5, ht > 0.5 else { return nil }
        let outW = CGFloat(Int(w.rounded(.up)))
        let outH = CGFloat(Int(ht.rounded(.up)))
        guard (1...DocumentLimits.maxSide).contains(Int(outW)),
              (1...DocumentLimits.maxSide).contains(Int(outH)),
              Int(outW) * Int(outH) <= DocumentLimits.maxSurfacePixels else { return nil }
        return CGRect(x: minX, y: minY, width: outW, height: outH)
    }
}

extension CameraRawGeometrySettings {
    /// Planned Expand to Fit coverage for the current corners, or nil when Keep Original Size / unchanged / unsafe.
    func plannedExpansion(width: Int, height: Int) -> CameraRawGeometryExpansion? {
        guard framingMode == .expandToFit, width > 0, height > 0 else { return nil }
        let corners = outputCorners(width: width, height: height)
        let identity = CameraRawPerspective.identityCorners(width: Double(width), height: Double(height))
        let unchanged = zip(corners, identity).allSatisfy {
            hypot($0.x - $1.x, $0.y - $1.y) < 0.05
        }
        if unchanged { return nil }
        guard let coverage = CameraRawPerspective.coverageInLayerPixels(corners: corners, width: width, height: height) else {
            return nil
        }
        let expansion = CameraRawGeometryExpansion(inputWidth: width, inputHeight: height, coverageInInput: coverage)
        return expansion.isIdentityFootprint ? nil : expansion
    }
}
