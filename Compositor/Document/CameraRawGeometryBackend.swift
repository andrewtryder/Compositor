import CoreGraphics
import Foundation

/// Coherent backend entry points for Camera Raw geometry features that a later unified GUI can call.
/// Global perspective, Horizon, framing/crop, Volume, and Miniature stay separate algorithms; this type only
/// sequences and documents their composition. ReShape / mesh deformation remains on its own branch and API.
nonisolated struct CameraRawGeometryBackendSettings: Equatable, Sendable, Codable {
    var geometry = CameraRawGeometrySettings()
    var horizon = CameraRawHorizonSettings()
    var perspectiveTools = CameraRawPerspectiveToolState()
    var crop = CameraRawGeometryCropRequest()
    var miniature = CameraRawMiniatureSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        geometry = try values.decodeIfPresent(CameraRawGeometrySettings.self, forKey: .geometry) ?? CameraRawGeometrySettings()
        horizon = try values.decodeIfPresent(CameraRawHorizonSettings.self, forKey: .horizon) ?? CameraRawHorizonSettings()
        perspectiveTools = try values.decodeIfPresent(CameraRawPerspectiveToolState.self, forKey: .perspectiveTools)
            ?? CameraRawPerspectiveToolState()
        crop = try values.decodeIfPresent(CameraRawGeometryCropRequest.self, forKey: .crop) ?? CameraRawGeometryCropRequest()
        miniature = try values.decodeIfPresent(CameraRawMiniatureSettings.self, forKey: .miniature) ?? CameraRawMiniatureSettings()
    }

    var normalized: CameraRawGeometryBackendSettings {
        var result = self
        result.geometry = geometry.normalized
        result.horizon = horizon.normalized
        result.miniature = miniature.normalized
        result.crop.framing = result.geometry.framingMode
        return result
    }
}

nonisolated enum CameraRawGeometryBackend {
    /// Documented correction order for full-resolution apply (GUI may preview subsets):
    /// 1. Lens distortion (optics)
    /// 2. Volume
    /// 3. Perspective / upright / tool guides (with Perspective Amount)
    /// 4. Horizon rotation (skipped when Upright already owns roll, unless horizon is explicitly forced)
    /// 5. Framing (Keep Original Size / Expand to Fit) + independent Constrain Crop / crop request
    /// 6. Miniature effect
    /// 7. Color grade (Camera Raw light/color/…)
    ///
    /// Auto Full candidate ranking is never modified here.
    static let compositionOrder = [
        "lensDistortion", "volume", "perspective", "horizon", "framingCrop", "miniature", "colorGrade"
    ]

    /// Geometry settings after applying the active perspective tool state.
    static func geometry(applying settings: CameraRawGeometryBackendSettings) -> CameraRawGeometrySettings {
        var geometry = CameraRawPerspectiveTools.applying(settings.perspectiveTools, to: settings.geometry.normalized)
        geometry.framingMode = settings.crop.framing
        if settings.crop.automaticOpaqueCrop {
            geometry.constrainCrop = true
        }
        return geometry
    }

    /// Whether Horizon should run given the current upright mode (avoid double roll).
    static func shouldApplyHorizon(_ settings: CameraRawGeometryBackendSettings) -> Bool {
        let horizon = settings.horizon.normalized
        guard !horizon.isIdentity else { return false }
        let upright = settings.geometry.upright
        // Auto Level / Guided already encode roll; Horizon stays available for Angle / references when upright is off,
        // or when the caller set Automatic horizon as a dedicated Level substitute.
        if upright == .autoLevel { return horizon.mode == .automatic }
        if upright == .guided || upright == .autoVertical || upright == .autoFull {
            return horizon.mode == .angle || horizon.mode == .horizontalReference || horizon.mode == .verticalReference
        }
        return true
    }

    /// Applies geometry + optional horizon + miniature. Does not run the color grade.
    static func apply(_ image: CGImage, settings: CameraRawGeometryBackendSettings,
                      automaticHorizonAngle: Double? = nil) throws -> CameraRawGeometryResult {
        let settings = settings.normalized
        var working = try geometry(applying: settings).applyResult(image)
        if shouldApplyHorizon(settings),
           let homo = CameraRawHorizon.homography(settings: settings.horizon, width: working.image.width,
                                                  height: working.image.height, automaticAngle: automaticHorizonAngle),
           homo != .identity {
            let width = working.image.width, height = working.image.height
            let corners = CameraRawPerspective.perspectiveCorners(homography: homo, width: width, height: height)
            let identity = CameraRawPerspective.identityCorners(width: Double(width), height: Double(height))
            let unchanged = zip(corners, identity).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.05 }
            if !unchanged {
                var horizonGeometry = CameraRawGeometrySettings()
                horizonGeometry.upright = .off
                horizonGeometry.rotate = CameraRawHorizon.rotationDegrees(settings: settings.horizon, width: width,
                                                                           height: height, automaticAngle: automaticHorizonAngle) ?? 0
                // Horizon runs on the current footprint; framing was already applied in the perspective stage.
                horizonGeometry.framingMode = .keepOriginalSize
                horizonGeometry.perspectiveAmount = 100
                let rotated = try horizonGeometry.applyResult(working.image)
                working = CameraRawGeometryResult(image: rotated.image, expansion: working.expansion)
            }
        }
        if let crop = try CameraRawGeometryCrop.plan(request: settings.crop, image: working.image,
                                                     originalSize: CGSize(width: image.width, height: image.height)),
           crop.width < CGFloat(working.image.width) - 0.5 || crop.height < CGFloat(working.image.height) - 0.5,
           let cropped = working.image.cropping(to: crop) {
            let expansion = working.expansion?.cropping(to: crop)
            working = CameraRawGeometryResult(image: cropped, expansion: expansion)
        }
        if !settings.miniature.isIdentity {
            let mini = try CameraRawMiniature.apply(working.image, settings: settings.miniature)
            working = CameraRawGeometryResult(image: mini, expansion: working.expansion)
        }
        return working
    }

    static func reset(_ settings: inout CameraRawGeometryBackendSettings) {
        let focal = settings.geometry.focalLengthMm
        let sensor = settings.geometry.sensorWidthMm
        settings = CameraRawGeometryBackendSettings()
        settings.geometry.focalLengthMm = focal
        settings.geometry.sensorWidthMm = sensor
    }
}
