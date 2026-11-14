import CoreGraphics
import Foundation

/// How a horizon / level correction is specified. Independent of Auto Upright candidate ranking.
nonisolated enum CameraRawHorizonMode: String, CaseIterable, Sendable, Codable {
    case off = "Off"
    case automatic = "Automatic"
    case angle = "Angle"
    case horizontalReference = "Horizontal Reference"
    case verticalReference = "Vertical Reference"
}

/// Horizon correction as a pure rotation about the image center. Does not re-run Auto Full selection.
/// Composition with perspective: apply Horizon *after* keystone when both are active so roll is not double-applied
/// through Auto Level guides; when Upright already owns roll, Horizon stays off unless explicitly forced.
nonisolated struct CameraRawHorizonSettings: Equatable, Sendable, Codable {
    var mode: CameraRawHorizonMode = .off
    /// Clockwise degrees when `mode == .angle`. Wrapped to ±45 for safety.
    var angleDegrees: Double = 0
    /// Normalized 0…1 lower-left coordinates for two-point references.
    var referenceStartX: Double = 0
    var referenceStartY: Double = 0
    var referenceEndX: Double = 1
    var referenceEndY: Double = 0
    /// 0…100. Blends the horizon rotation toward identity (same spirit as Perspective Amount).
    var amount: Double = 100

    static let angleRange: ClosedRange<Double> = -45...45
    static let amountRange: ClosedRange<Double> = 0...100

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        mode = try values.decodeIfPresent(CameraRawHorizonMode.self, forKey: .mode) ?? base.mode
        angleDegrees = try values.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? base.angleDegrees
        referenceStartX = try values.decodeIfPresent(Double.self, forKey: .referenceStartX) ?? base.referenceStartX
        referenceStartY = try values.decodeIfPresent(Double.self, forKey: .referenceStartY) ?? base.referenceStartY
        referenceEndX = try values.decodeIfPresent(Double.self, forKey: .referenceEndX) ?? base.referenceEndX
        referenceEndY = try values.decodeIfPresent(Double.self, forKey: .referenceEndY) ?? base.referenceEndY
        amount = try values.decodeIfPresent(Double.self, forKey: .amount) ?? base.amount
    }

    var isIdentity: Bool {
        mode == .off || ImageAdjustmentPixels.clamp(amount, Self.amountRange, 100) <= 1e-9
    }

    var normalized: CameraRawHorizonSettings {
        var result = self
        result.angleDegrees = ImageAdjustmentPixels.clamp(angleDegrees, Self.angleRange, 0)
        result.amount = ImageAdjustmentPixels.clamp(amount, Self.amountRange, 100)
        result.referenceStartX = min(1, max(0, referenceStartX))
        result.referenceStartY = min(1, max(0, referenceStartY))
        result.referenceEndX = min(1, max(0, referenceEndX))
        result.referenceEndY = min(1, max(0, referenceEndY))
        return result
    }

    mutating func reset() {
        self = CameraRawHorizonSettings()
    }
}

nonisolated enum CameraRawHorizon {
    /// Clockwise degrees that level the image for `settings`, or nil when identity / degenerate.
    static func rotationDegrees(settings: CameraRawHorizonSettings, width: Int, height: Int,
                                automaticAngle: Double? = nil) -> Double? {
        let settings = settings.normalized
        guard !settings.isIdentity, width > 0, height > 0 else { return nil }
        let full: Double
        switch settings.mode {
        case .off:
            return nil
        case .automatic:
            // The observation already reports the rotation that levels the picture, in the same convention as Angle,
            // so it is used as-is rather than negated into a second convention.
            guard let automaticAngle, automaticAngle.isFinite else { return nil }
            full = wrap(automaticAngle)
        case .angle:
            full = settings.angleDegrees
        case .horizontalReference:
            guard let degrees = referenceAngle(settings: settings, width: width, height: height, vertical: false) else {
                return nil
            }
            full = degrees
        case .verticalReference:
            guard let degrees = referenceAngle(settings: settings, width: width, height: height, vertical: true) else {
                return nil
            }
            full = degrees
        }
        let t = settings.amount / 100
        let blended = full * t
        return abs(blended) < 1e-9 ? nil : blended
    }

    /// Homography for the horizon rotation about the image center (CI coordinates, y up).
    static func homography(settings: CameraRawHorizonSettings, width: Int, height: Int,
                           automaticAngle: Double? = nil) -> CameraRawHomography? {
        guard let degrees = rotationDegrees(settings: settings, width: width, height: height,
                                            automaticAngle: automaticAngle) else { return .identity }
        return rotationHomography(degrees: degrees, width: Double(width), height: Double(height))
    }

    static func rotationHomography(degrees: Double, width: Double, height: Double) -> CameraRawHomography? {
        guard degrees.isFinite, width > 0, height > 0 else { return nil }
        let radians = degrees * .pi / 180
        let cosT = cos(radians), sinT = sin(radians)
        let cx = width / 2, cy = height / 2
        // Match Camera Raw manual Rotate: x' = cx + dx cos − dy sin, y' = cy + dx sin + dy cos.
        let m0 = cosT, m1 = -sinT, m2 = cx - cosT * cx + sinT * cy
        let m3 = sinT, m4 = cosT, m5 = cy - sinT * cx - cosT * cy
        guard let homo = CameraRawHomography(m: (m0, m1, m2, m3, m4, m5, 0, 0, 1)).normalized(),
              homo.isPlausible(width: width, height: height) else { return nil }
        return homo
    }

    /// Angle that makes a nearly-horizontal reference horizontal, or a nearly-vertical one vertical.
    /// Endpoint order does not change the result.
    static func referenceAngle(settings: CameraRawHorizonSettings, width: Int, height: Int, vertical: Bool) -> Double? {
        let w = Double(width), h = Double(height)
        guard w > 0, h > 0 else { return nil }
        let start = CGPoint(x: settings.referenceStartX * w, y: settings.referenceStartY * h)
        let end = CGPoint(x: settings.referenceEndX * w, y: settings.referenceEndY * h)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1e-3 else { return nil }
        // Image space here is normalized lower-left (y up), matching guides.
        let radians = atan2(dy, dx)
        if vertical {
            // Bring the line to ±90° (vertical).
            let target = radians >= 0 ? Double.pi / 2 : -Double.pi / 2
            return wrap((target - radians) * 180 / Double.pi)
        }
        // Bring the line to 0° or 180° (horizontal).
        var delta = -radians * 180 / Double.pi
        if abs(wrap(delta + 180)) < abs(wrap(delta)) { delta = wrap(delta + 180) }
        return wrap(delta)
    }

    /// Clockwise degrees that level the picture for an Auto Level (or level-fallback) observation.
    /// The guide's slope is measured in pixels, as every other geometry stage measures it, so a non-square frame is not
    /// leveled by an angle that only looks right in normalized space. Same convention as `referenceAngle`, so 0 is level
    /// and the sign matches the parameter `rotationDegrees`/`outputCorners` take.
    /// Nil when the observation carries no readable guide: `residualDegrees` is a magnitude, so it cannot say which way
    /// to turn, and guessing a sign would tilt a picture that is already level.
    static func automaticAngle(from observation: CameraRawUprightObservation, width: Int, height: Int) -> Double? {
        let w = Double(width), h = Double(height)
        guard w > 0, h > 0 else { return nil }
        for guide in observation.guides {
            guard let kind = CameraRawPerspective.classify(guide, width: w, height: h) else { continue }
            var reference = CameraRawHorizonSettings()
            reference.referenceStartX = guide.startX
            reference.referenceStartY = guide.startY
            reference.referenceEndX = guide.endX
            reference.referenceEndY = guide.endY
            return referenceAngle(settings: reference, width: width, height: height,
                                  vertical: kind.kind == .vertical)
        }
        return nil
    }

    static func wrap(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        if value > 45 { value = 45 }
        if value < -45 { value = -45 }
        return value
    }
}
