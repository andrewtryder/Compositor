import AppKit
import CoreImage

/// A brush stroke that paints coverage onto a Camera Raw local mask's raster.
///
/// Paint adds white coverage (reveals the adjustment), erase removes it (hides the adjustment).
/// The stroke works on the mask's own grayscale pixel grid and produces a `CameraRawLocalMaskRaster`
/// that is stored with the mask. Painting modifies mask coverage only, never the photograph.
///
/// The brush tip is rendered once as grayscale coverage: white at full strength, fading to black
/// at the rim according to hardness. Each dab stamps the tip through the coverage at the given
/// opacity, building up overlapping dabs without exceeding the opacity cap.
final class CameraRawLocalMaskBrush {
    /// The brush's diameter in pixels of the mask grid.
    let diameter: CGFloat
    /// The brush's hardness, 0 (soft) to 1 (hard).
    let hardness: CGFloat
    /// The brush's opacity cap, 0.01…1.
    let opacity: CGFloat
    /// Whether this stroke is erasing (removing coverage) rather than painting (adding it).
    let erasing: Bool

    /// The mask grid's size.
    let width: Int
    let height: Int

    /// The working context holding the coverage being painted. Y is flipped: document-space
    /// (y down from top) maps to context space (y up from bottom), as with every `BrushRaster`
    /// context.
    private let context: CGContext

    /// The brush tip as grayscale coverage, rendered once.
    private let tip: CGImage?

    /// `true` if the painted mask has any non-black coverage; `false` when an empty painted mask
    /// applies no adjustment (its coverage is entirely black).
    var isEmpty: Bool {
        guard let image = coverage() else { return true }
        return !CameraRawLocalMaskRenderer.hasCoverage(image)
    }

    /// Creates a brush over `base` coverage (nil means an empty black mask).
    init(base: CGImage?, width: Int, height: Int, settings: BrushSettings, erasing: Bool) throws {
        self.width = width
        self.height = height
        self.diameter = settings.diameter
        self.hardness = settings.hardness
        self.opacity = settings.opacity
        self.erasing = erasing

        guard let context = try? BrushRaster.context(width: width, height: height, mask: true) else {
            throw ExportError.render
        }
        self.context = context

        // Start from the existing coverage, or an empty black mask.
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let base {
            context.setFillColor(gray: 1, alpha: 1)
            context.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: base)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        // Render the tip once as grayscale coverage: white at full strength, fading to black at the rim.
        let tipSize = max(1, Int(diameter.rounded(.up)))
        let tipContext = try? BrushRaster.context(width: tipSize, height: tipSize, mask: true)
        tipContext?.setFillColor(gray: 0, alpha: 1)
        tipContext?.fill(CGRect(x: 0, y: 0, width: tipSize, height: tipSize))
        tipContext?.setFillColor(gray: 1, alpha: 1)
        let tipBounds = CGRect(x: 0, y: 0, width: tipSize, height: tipSize)
        if hardness >= 1 {
            tipContext?.fillEllipse(in: tipBounds)
        } else if let falloff = Self.falloffGradient(hardness: hardness) {
            let radius = CGFloat(tipSize) / 2
            let center = CGPoint(x: radius, y: radius)
            tipContext?.drawRadialGradient(falloff, startCenter: center, startRadius: radius * hardness,
                                           endCenter: center, endRadius: radius,
                                           options: [.drawsBeforeStartLocation])
        }
        self.tip = tipContext?.makeImage()
    }

    /// Paints a dab at `point` (in the mask grid's pixel space, y down from top).
    ///
    /// The context was created by `BrushRaster.context`, which already flips its CTM so that
    /// document-space (y down from top) draws correctly. The tip is radially symmetric, so its
    /// own orientation does not matter.
    func dab(at point: CGPoint, pressure: CGFloat = 1) {
        guard let tip else { return }
        let radius = diameter / 2
        let circle = CGRect(x: point.x - radius, y: point.y - radius, width: diameter, height: diameter)
        let clipped = circle.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clipped.isNull, !clipped.isEmpty else { return }

        context.saveGState()
        context.setAlpha(opacity * min(1, max(0, pressure)))

        if erasing {
            context.setBlendMode(.clear)
            context.clip(to: clipped, mask: tip)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(clipped)
        } else {
            context.setBlendMode(.normal)
            context.clip(to: clipped, mask: tip)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(clipped)
        }

        context.restoreGState()
    }

    /// The painted coverage as a CGImage, or nil if the context failed.
    func coverage() -> CGImage? {
        return context.makeImage()
    }

    /// Encodes the painted coverage as a `CameraRawLocalMaskRaster`.
    func makeRaster() throws -> CameraRawLocalMaskRaster {
        guard let image = coverage() else { throw ExportError.render }
        return try CameraRawLocalMaskRaster.make(from: image)
    }

    // MARK: - Brush tip gradient

    /// A radial falloff gradient for a soft brush tip: full strength at the center, fading to
    /// zero at the rim. `hardness` sets the inner radius that stays at full strength.
    private static func falloffGradient(hardness: CGFloat) -> CGGradient? {
        let steps = 24
        let locations = (0...steps).map { CGFloat($0) / CGFloat(steps) }
        let levels: [CGFloat] = locations.flatMap { [BrushRaster.falloff($0), CGFloat(1)] }
        return CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(),
                          colorComponents: levels, locations: locations, count: locations.count)
    }
}
