import CoreGraphics
import Foundation

/// Builds Guided-style guides from the picture for Auto Level / Vertical / Full.
nonisolated enum CameraRawUprightDetection {
    /// Normalized lower-left guides for the requested Auto mode. Empty when nothing useful was found.
    static func guides(in image: CGImage, mode: CameraRawUprightMode) -> [CameraRawGeometryGuide] {
        observe(in: image, mode: mode).guides
    }

    /// Guides plus the evidence behind them. Diagnostics are not saved in a project.
    static func observe(in image: CGImage, mode: CameraRawUprightMode, analysisMaxSide: Int = CameraRawUprightEstimation.analysisMaxSide) -> CameraRawUprightObservation {
        CameraRawUprightEstimation.observe(in: image, mode: mode, analysisMaxSide: analysisMaxSide)
    }

    /// A detection started for `mode` at `version` may be applied only if the edit has not moved on.
    static func shouldApply(mode: CameraRawUprightMode, current: CameraRawUprightMode,
                            version: UInt64, currentVersion: UInt64, committing: Bool) -> Bool {
        mode.isAuto && !committing && current == mode && currentVersion == version
    }
}
