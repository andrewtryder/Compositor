import CoreGraphics
import CoreImage
import Foundation

/// What decides which parts of the picture stay sharp: the existing radial focus region, or the photograph's own
/// depth estimate. Depth Focus is opt-in and additive; Focus Region renders exactly as it always has.
nonisolated enum CameraRawLensBlurFocusMode: String, CaseIterable, Codable, Sendable {
    case focusRegion = "Focus Region"
    case depthFocus = "Depth Focus"
}

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
    /// Which parts stay sharp. `.focusRegion` is the original behavior; `.depthFocus` needs a depth map.
    var focusMode: CameraRawLensBlurFocusMode = .focusRegion
    /// The sharp region's center, normalized (0…1, y down), as the preview shows it.
    var focusX: Double = 0.5
    var focusY: Double = 0.5
    /// 0…100: how wide the sharp region is, as a share of the frame's longer side. 100 covers the whole frame.
    var focusRange: Double = 35
    /// Depth Focus: the relative depth that stays sharp, 0…100 of the depth map's range (0 farthest, 100 nearest).
    /// It is a position in the estimate's own ordering, not a distance in meters.
    var depthFocalDistance: Double = 50
    /// Depth Focus: 0…100, how much depth either side of the focal distance stays sharp.
    var depthRange: Double = 25
    /// 0…100: how gradually the sharp region gives way to the blur.
    var falloff: Double = 40
    /// 0…100: how much of each disc's light gathers at its rim, as fast lenses draw it.
    var highlights: Double = 50

    static let unitRange: ClosedRange<Double> = 0...100

    var isIdentity: Bool {
        ImageAdjustmentPixels.clamp(amount, Self.unitRange, 0) <= 1e-9
    }

    /// Depth Focus is selected and an amount is set: the render needs a depth map to do anything.
    var needsDepth: Bool {
        focusMode == .depthFocus && !isIdentity
    }

    var normalized: Self {
        var result = self
        result.amount = ImageAdjustmentPixels.clamp(amount, Self.unitRange, 0)
        result.focusX = min(1, max(0, focusX.isFinite ? focusX : 0.5))
        result.focusY = min(1, max(0, focusY.isFinite ? focusY : 0.5))
        result.focusRange = ImageAdjustmentPixels.clamp(focusRange, Self.unitRange, 35)
        result.depthFocalDistance = ImageAdjustmentPixels.clamp(depthFocalDistance, Self.unitRange, 50)
        result.depthRange = ImageAdjustmentPixels.clamp(depthRange, Self.unitRange, 25)
        result.falloff = ImageAdjustmentPixels.clamp(falloff, Self.unitRange, 40)
        result.highlights = ImageAdjustmentPixels.clamp(highlights, Self.unitRange, 50)
        return result
    }

    /// The discs' radius in `image`'s pixels, scaled for a preview made at `scale`.
    func radius(scale: Double) -> CGFloat {
        let pixels = max(0, amount) / 100 * 30
        return CGFloat(pixels * (scale > 0 ? scale : 1))
    }

    /// The focal distance in the depth map's own 0…1 scale (1 nearest).
    var focalDepth: Double { normalized.depthFocalDistance / 100 }

    /// The half-width of the sharp depth band, in the same 0…1 scale. 100 keeps half the estimate's range sharp.
    var halfDepthRange: Double { normalized.depthRange / 200 }

    /// How soft the transition out of that band is, in the same 0…1 scale: the Falloff slider, as lens blur has
    /// always used it, reinterpreted as a share of the depth estimate's range for Depth Focus.
    var depthFeather: Double { max(0.01, normalized.falloff / 100 * 0.5) }
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

    /// How far each pixel's estimated depth is outside the sharp band, 0 (sharp) … 1 (fully blurred), over `extent`.
    ///
    /// Two linear ramps either side of the band, each clamped to 0…1 and combined with a maximum: no custom kernel,
    /// and exact at both ends. The depth image is the estimate's own grayscale, resampled to `extent`, so a
    /// corrected frame (de-squeeze, perspective, crop) still reads its depth in the right place.
    static func depthBlurMask(settings: CameraRawLensBlurSettings, depth: DepthMap, extent: CGRect) -> CIImage? {
        let settings = settings.normalized
        guard extent.width >= 1, extent.height >= 1, !depth.values.isEmpty else { return nil }
        let map = DepthModel.image(depth, over: extent)
        let focal = CGFloat(settings.focalDepth)
        let half = CGFloat(settings.halfDepthRange)
        let feather = CGFloat(settings.depthFeather)
        // Past the band's near edge (nearest side) and its far edge (farthest side).
        func ramp(scale: CGFloat, bias: CGFloat) -> CIImage {
            let scaled = map.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ])
            return scaled.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
        }
        let near = ramp(scale: 1 / feather, bias: -focal / feather - half / feather)
        let far = ramp(scale: -1 / feather, bias: focal / feather - half / feather)
        return near.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: far])
            .cropped(to: extent)
    }

    /// `image` with its out-of-focus light drawn as discs, sharp inside the focus stack's sharp band.
    ///
    /// `depth`: the frame's depth estimate, when the caller already has one (the preview computes it once per edit).
    /// Nil asks `DepthModel` for it here; if the model isn't loaded, Depth Focus renders the input unchanged rather
    /// than pretending a radial blur is depth-aware.
    /// `visualizeDepth`: preview only — the depth map itself, to see what Depth Focus reads. Never committed.
    static func apply(_ image: CGImage, settings: CameraRawLensBlurSettings, scale: CGFloat = 1,
                      depth: DepthMap? = nil, visualizeDepth: Bool = false) throws -> CGImage {
        let settings = settings.normalized
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return image }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        if settings.focusMode == .depthFocus {
            // An estimate for this frame, or the model's: nil when it isn't loaded, and then there is nothing
            // depth-aware to draw.
            guard let map = depth ?? DepthModel.depth(for: image) else { return image }
            if visualizeDepth {
                return try PixelAdjust.render(DepthModel.image(map, over: extent), width: width, height: height, isMask: false)
            }
            guard !settings.isIdentity, let mask = depthBlurMask(settings: settings, depth: map, extent: extent) else { return image }
            return try mixed(image, settings: settings, mask: mask, extent: extent, scale: scale)
        }
        guard !settings.isIdentity, let mask = blurMask(settings: settings, width: width, height: height) else { return image }
        return try mixed(image, settings: settings, mask: mask, extent: extent, scale: scale)
    }

    /// The discs (or the Gaussian stand-in) blended through `mask`: sharp where the mask is black.
    private static func mixed(_ image: CGImage, settings: CameraRawLensBlurSettings, mask: CIImage,
                              extent: CGRect, scale: CGFloat) throws -> CGImage {
        let width = image.width, height = image.height
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

    /// The depth the panel reports for a point the user clicked, and the focal distance that makes it sharp.
    /// Nil when the frame has no estimate (the model isn't loaded).
    static func focalDistance(forDepthAtX x: Double, y: Double, in image: CGImage, depth: DepthMap?) -> Double? {
        guard let map = depth ?? DepthModel.depth(for: image) else { return nil }
        let value = map.value(atNormalizedX: x, y: y)
        guard value.isFinite else { return nil }
        return Double(min(1, max(0, value))) * 100
    }
}
