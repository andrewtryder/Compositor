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

    init(geometry: CameraRawGeometrySettings = CameraRawGeometrySettings(),
         horizon: CameraRawHorizonSettings = CameraRawHorizonSettings(),
         perspectiveTools: CameraRawPerspectiveToolState = CameraRawPerspectiveToolState(),
         crop: CameraRawGeometryCropRequest = CameraRawGeometryCropRequest(),
         miniature: CameraRawMiniatureSettings = CameraRawMiniatureSettings()) {
        self.geometry = geometry
        self.horizon = horizon
        self.perspectiveTools = perspectiveTools
        self.crop = crop
        self.miniature = miniature
    }

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
    /// 4. Horizon rotation (composed into destination corners before framing)
    /// 5. Framing (Keep Original Size / Expand to Fit) + independent Constrain Crop / crop request
    /// 6. Miniature effect
    /// 7. Color grade (Camera Raw light/color/…)
    ///
    /// Auto Full candidate ranking is never modified here.
    /// Horizon, perspective tools, and Miniature are executed by `CameraRawSettings.applyResult` on the
    /// PixelFilter / EditorSession path (not API-only).
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
        // Auto Level already owns roll when its guides are active; Automatic horizon is the Level substitute.
        if upright == .autoLevel { return horizon.mode == .automatic }
        if upright == .guided || upright == .autoVertical || upright == .autoFull {
            return horizon.mode == .angle || horizon.mode == .horizontalReference || horizon.mode == .verticalReference
        }
        return true
    }

    static func horizonDegrees(settings: CameraRawGeometryBackendSettings, width: Int, height: Int,
                               automaticAngle: Double? = nil) -> Double? {
        guard shouldApplyHorizon(settings) else { return nil }
        return CameraRawHorizon.rotationDegrees(settings: settings.horizon, width: width, height: height,
                                                automaticAngle: automaticAngle)
    }

    /// Applies geometry + Horizon (into corners) + optional crop request + miniature. Does not run the color grade.
    static func apply(_ image: CGImage, settings: CameraRawGeometryBackendSettings,
                      automaticHorizonAngle: Double? = nil) throws -> CameraRawGeometryResult {
        let settings = settings.normalized
        let geometry = geometry(applying: settings)
        let degrees = horizonDegrees(settings: settings, width: image.width, height: image.height,
                                     automaticAngle: automaticHorizonAngle)
        var working = try geometry.applyResult(image, horizonDegrees: degrees)
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
