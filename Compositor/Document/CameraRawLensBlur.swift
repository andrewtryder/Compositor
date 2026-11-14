import CoreGraphics
import CoreImage
import Foundation

/// Optics › Lens Blur: the picture blurred outside a focus region as a lens draws it, in discs of the aperture's
/// shape rather than a Gaussian smear. Compositor already had the engine — `CameraRawMiniature`'s focus mask and
/// `MetalBokeh`'s aperture-shaped discs — with no control reaching it; this is that control.
///
/// Amount zero is exactly the input, so a picture that has never had Lens Blur on renders as it always did.
nonisolated struct CameraRawLensBlurSettings: Equatable, Sendable {
    /// 0…100. Zero blurs nothing.
    var amount: Double = 0
    /// How the out-of-focus light is drawn: the same apertures Lens Effects' Bokeh offers.
    var aperture: BokehShape = .round
    /// The sharp region's center, normalized (0…1, y down), as the preview shows it.
    var focusX: Double = 0.5
    var focusY: Double = 0.5
    /// 0…100: how wide the sharp region is, as a share of the frame's longer side. 100 covers the whole frame.
    var focusRange: Double = 35
    /// 0…100: how gradually the sharp region gives way to the blur.
    var falloff: Double = 40
    /// 0…100: how much of each disc's light gathers at its rim, as fast lenses draw it.
    var highlights: Double = 50

    static let unitRange: ClosedRange<Double> = 0...100

    var isIdentity: Bool {
        ImageAdjustmentPixels.clamp(amount, Self.unitRange, 0) <= 1e-9
    }

    var normalized: Self {
        var result = self
        result.amount = ImageAdjustmentPixels.clamp(amount, Self.unitRange, 0)
        result.focusX = min(1, max(0, focusX.isFinite ? focusX : 0.5))
        result.focusY = min(1, max(0, focusY.isFinite ? focusY : 0.5))
        result.focusRange = ImageAdjustmentPixels.clamp(focusRange, Self.unitRange, 35)
        result.falloff = ImageAdjustmentPixels.clamp(falloff, Self.unitRange, 40)
        result.highlights = ImageAdjustmentPixels.clamp(highlights, Self.unitRange, 50)
        return result
    }

    /// The discs' radius in `image`'s pixels, scaled for a preview made at `scale`.
    func radius(scale: Double) -> CGFloat {
        let pixels = max(0, amount) / 100 * 30
        return CGFloat(pixels * (scale > 0 ? scale : 1))
    }
}

nonisolated enum CameraRawLensBlur {
    /// How far outside the focus region is fully blurred, 0 sharp … 1 blurred, over `extent` (Core Image coordinates,
    /// y up). Built from the same gradient the miniature effect's mask uses.
    static func blurMask(settings: CameraRawLensBlurSettings, width: Int, height: Int) -> CIImage? {
        let settings = settings.normalized
        guard width > 0, height > 0 else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let side = max(w, h)
        let center = CIVector(x: settings.focusX * w, y: (1 - settings.focusY) * h)
        // 100 covers the frame's corners, which lie 0.71 of the longer side from its middle.
        let inner = CGFloat(settings.focusRange / 100) * side * 0.75
        let fall = max(1, CGFloat(settings.falloff / 100) * side * 0.35)
        return CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: center,
            "inputRadius0": inner,
            "inputRadius1": inner + fall,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// `image` with its out-of-focus light drawn as discs, sharp inside the focus region.
    static func apply(_ image: CGImage, settings: CameraRawLensBlurSettings, scale: CGFloat = 1) throws -> CGImage {
        let settings = settings.normalized
        guard !settings.isIdentity else { return image }
        let width = image.width, height = image.height
        guard let mask = blurMask(settings: settings, width: width, height: height) else { return image }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let source = CIImage(cgImage: image)
        let radius = max(0.5, settings.radius(scale: Double(scale)))
        // A GPU that can draw the aperture's own shape draws it; without one, a Gaussian of the same radius stands in.
        let blurred: CIImage
        if let gpu = MetalBokeh.shared, let discs = try? gpu.blur(source, extent: extent, radius: radius,
                                                                  shape: settings.aperture,
                                                                  ring: settings.highlights / 100) {
            blurred = discs
        } else {
            blurred = source.clampedToExtent().applyingGaussianBlur(sigma: radius * 0.5).cropped(to: extent)
        }
        let mixed = blurred.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: source, kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
        return try PixelAdjust.render(mixed, width: width, height: height, isMask: false)
    }

    /// Whether the discs are drawn by `MetalBokeh` rather than the Gaussian stand-in, for the panel's help text.
    static var drawsApertures: Bool { MetalBokeh.shared != nil }
}
