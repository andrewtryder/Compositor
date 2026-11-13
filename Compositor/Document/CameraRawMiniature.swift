import CoreImage
import CoreGraphics
import Foundation

nonisolated enum CameraRawMiniatureShape: String, CaseIterable, Sendable, Codable {
    case linear = "Linear"
    case circular = "Circular"
}

/// Tilt-shift / miniature settings. Identity when strength is zero. GUI deferred.
nonisolated struct CameraRawMiniatureSettings: Equatable, Sendable, Codable {
    var shape: CameraRawMiniatureShape = .linear
    /// 0…100 blur strength. Zero leaves pixels unchanged.
    var strength: Double = 0
    /// 0…100 soft transition width around the focus region.
    var falloff: Double = 40
    /// Focus band center in normalized image coordinates (0…1, y down for API convenience).
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    /// Linear: focus line angle in degrees. Circular: unused.
    var angleDegrees: Double = 0
    /// Half-width of the sharp band (linear) or radius (circular), 0…1 relative to the long side.
    var focusSize: Double = 0.2
    var symmetricPosition = true
    var symmetricBlur = true

    static let unitRange: ClosedRange<Double> = 0...100
    static let sizeRange: ClosedRange<Double> = 0.02...0.8

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        shape = try values.decodeIfPresent(CameraRawMiniatureShape.self, forKey: .shape) ?? base.shape
        strength = try values.decodeIfPresent(Double.self, forKey: .strength) ?? base.strength
        falloff = try values.decodeIfPresent(Double.self, forKey: .falloff) ?? base.falloff
        centerX = try values.decodeIfPresent(Double.self, forKey: .centerX) ?? base.centerX
        centerY = try values.decodeIfPresent(Double.self, forKey: .centerY) ?? base.centerY
        angleDegrees = try values.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? base.angleDegrees
        focusSize = try values.decodeIfPresent(Double.self, forKey: .focusSize) ?? base.focusSize
        symmetricPosition = try values.decodeIfPresent(Bool.self, forKey: .symmetricPosition) ?? base.symmetricPosition
        symmetricBlur = try values.decodeIfPresent(Bool.self, forKey: .symmetricBlur) ?? base.symmetricBlur
    }

    var isIdentity: Bool {
        ImageAdjustmentPixels.clamp(strength, Self.unitRange, 0) <= 1e-9
    }

    var normalized: CameraRawMiniatureSettings {
        var result = self
        result.strength = ImageAdjustmentPixels.clamp(strength, Self.unitRange, 0)
        result.falloff = ImageAdjustmentPixels.clamp(falloff, Self.unitRange, 40)
        result.centerX = min(1, max(0, centerX))
        result.centerY = min(1, max(0, centerY))
        result.focusSize = ImageAdjustmentPixels.clamp(focusSize, Self.sizeRange, 0.2)
        if !result.angleDegrees.isFinite { result.angleDegrees = 0 }
        return result
    }

    mutating func reset() {
        self = CameraRawMiniatureSettings()
    }
}

nonisolated enum CameraRawMiniature {
    /// Continuous blur-weight mask in CI coordinates (y up), values 0 (sharp) … 1 (full strength).
    static func blurMask(settings: CameraRawMiniatureSettings, width: Int, height: Int) -> CIImage? {
        let settings = settings.normalized
        guard !settings.isIdentity, width > 0, height > 0 else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let side = max(w, h)
        let cx = settings.centerX * w
        // API y down → CI y up.
        let cy = (1 - settings.centerY) * h
        let focus = CGFloat(settings.focusSize) * side
        let fall = max(1, CGFloat(settings.falloff / 100) * side * 0.35)
        let sharp = CIColor(red: 0, green: 0, blue: 0)
        let soft = CIColor(red: 1, green: 1, blue: 1)
        switch settings.shape {
        case .circular:
            let inner = max(0, focus)
            let outer = inner + fall
            return CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(x: cx, y: cy),
                "inputRadius0": inner,
                "inputRadius1": outer,
                "inputColor0": sharp,
                "inputColor1": soft
            ])?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        case .linear:
            let radians = settings.angleDegrees * .pi / 180
            // Normal to the focus line.
            let nx = CGFloat(sin(radians)), ny = CGFloat(cos(radians))
            let along = focus
            if settings.symmetricBlur {
                // Approximate a band with two opposing linear gradients composited by max via screen-ish add.
                let p0 = CGPoint(x: cx - nx * along, y: cy - ny * along)
                let p1 = CGPoint(x: cx - nx * (along + fall), y: cy - ny * (along + fall))
                let p2 = CGPoint(x: cx + nx * along, y: cy + ny * along)
                let p3 = CGPoint(x: cx + nx * (along + fall), y: cy + ny * (along + fall))
                guard let g0 = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(cgPoint: p0), "inputPoint1": CIVector(cgPoint: p1),
                    "inputColor0": sharp, "inputColor1": soft
                ])?.outputImage,
                      let g1 = CIFilter(name: "CILinearGradient", parameters: [
                        "inputPoint0": CIVector(cgPoint: p2), "inputPoint1": CIVector(cgPoint: p3),
                        "inputColor0": sharp, "inputColor1": soft
                      ])?.outputImage else { return nil }
                return g0.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: g1])
                    .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            }
            let p0 = CGPoint(x: cx - nx * along, y: cy - ny * along)
            let p1 = CGPoint(x: cx - nx * (along + fall), y: cy - ny * (along + fall))
            return CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(cgPoint: p0), "inputPoint1": CIVector(cgPoint: p1),
                "inputColor0": sharp, "inputColor1": soft
            ])?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    /// Renders the miniature effect. Uses CIMaskedVariableBlur (same family as Progressive Blur).
    static func apply(_ image: CGImage, settings: CameraRawMiniatureSettings, scale: CGFloat = 1) throws -> CGImage {
        let settings = settings.normalized
        guard !settings.isIdentity else { return image }
        let width = image.width, height = image.height
        guard let mask = blurMask(settings: settings, width: width, height: height) else { return image }
        let radius = max(0.5, settings.strength / 100 * 28 * Double(scale > 0 ? scale : 1))
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let source = CIImage(cgImage: image)
        let blurred = source.applyingFilter("CIMaskedVariableBlur", parameters: [
            "inputMask": mask,
            kCIInputRadiusKey: radius
        ]).cropped(to: extent)
        return try PixelAdjust.render(blurred, width: width, height: height, isMask: false)
    }
}
