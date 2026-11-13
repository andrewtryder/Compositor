import CoreGraphics
import Foundation

/// Which independent perspective tool owns the active guides / corners. Serialized separately so a future GUI can
/// switch tools without collapsing unrelated state into Vertical/Horizontal sliders.
nonisolated enum CameraRawPerspectiveToolKind: String, CaseIterable, Sendable, Codable {
    case automatic = "Automatic"
    case verticalGuides = "Vertical Guides"
    case horizontalGuides = "Horizontal Guides"
    case combinedGuides = "Combined Guides"
    case rectangle = "Rectangle"
    case eightPoint = "Eight Point"
    case manualKeystone = "Manual Keystone"
}

/// Typed parameters for perspective tools. Perspective Amount and Aspect (H/V Ratio) live on geometry settings;
/// Aspect is the existing width/height polish — H/V Ratio is the same transform with a clearer product name.
nonisolated struct CameraRawPerspectiveToolState: Equatable, Sendable, Codable {
    var kind: CameraRawPerspectiveToolKind = .automatic
    /// Vertical-only guides (normalized lower-left).
    var verticalGuides: [CameraRawGeometryGuide] = []
    /// Horizontal-only guides.
    var horizontalGuides: [CameraRawGeometryGuide] = []
    /// Four corners in normalized lower-left order TL, TR, BR, BL (x0,y0 … x3,y3).
    var rectangleCornerScalars: [Double] = []
    /// Four segments (eight endpoints) as guides for eight-point correction.
    var eightPointGuides: [CameraRawGeometryGuide] = []
    var manualVertical: Double = 0
    var manualHorizontal: Double = 0
    var manualRotate: Double = 0

    var rectangleCorners: [CGPoint] {
        get {
            guard rectangleCornerScalars.count == 8 else { return [] }
            return (0..<4).map { CGPoint(x: rectangleCornerScalars[$0 * 2], y: rectangleCornerScalars[$0 * 2 + 1]) }
        }
        set {
            rectangleCornerScalars = newValue.prefix(4).flatMap { [$0.x, $0.y] }
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        kind = try values.decodeIfPresent(CameraRawPerspectiveToolKind.self, forKey: .kind) ?? base.kind
        verticalGuides = try values.decodeIfPresent([CameraRawGeometryGuide].self, forKey: .verticalGuides) ?? base.verticalGuides
        horizontalGuides = try values.decodeIfPresent([CameraRawGeometryGuide].self, forKey: .horizontalGuides) ?? base.horizontalGuides
        rectangleCornerScalars = try values.decodeIfPresent([Double].self, forKey: .rectangleCornerScalars) ?? base.rectangleCornerScalars
        eightPointGuides = try values.decodeIfPresent([CameraRawGeometryGuide].self, forKey: .eightPointGuides) ?? base.eightPointGuides
        manualVertical = try values.decodeIfPresent(Double.self, forKey: .manualVertical) ?? base.manualVertical
        manualHorizontal = try values.decodeIfPresent(Double.self, forKey: .manualHorizontal) ?? base.manualHorizontal
        manualRotate = try values.decodeIfPresent(Double.self, forKey: .manualRotate) ?? base.manualRotate
    }

    mutating func reset() {
        self = CameraRawPerspectiveToolState()
    }
}

/// Builds guides / corners for the solver without replacing the existing two- and four-guide paths.
nonisolated enum CameraRawPerspectiveTools {
    /// Guides the upright solver should use for the active tool. Nil means “leave geometry.guides alone”.
    static func activeGuides(for state: CameraRawPerspectiveToolState) -> [CameraRawGeometryGuide]? {
        switch state.kind {
        case .automatic, .manualKeystone:
            return nil
        case .verticalGuides:
            return state.verticalGuides
        case .horizontalGuides:
            return state.horizontalGuides
        case .combinedGuides:
            return state.verticalGuides + state.horizontalGuides
        case .rectangle:
            return rectangleGuides(corners: state.rectangleCorners)
        case .eightPoint:
            return state.eightPointGuides
        }
    }

    /// Four corner points (normalized lower-left) → four edge guides for the existing DLT path.
    static func rectangleGuides(corners: [CGPoint]) -> [CameraRawGeometryGuide]? {
        guard corners.count == 4,
              corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite
                && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return nil }
        // Edges: TL→TR, TR→BR, BR→BL, BL→TL. Two vertical + two horizontal for Auto Full / Guided.
        let edges = [(0, 1), (1, 2), (2, 3), (3, 0)]
        return edges.map { a, b in
            CameraRawGeometryGuide(startX: corners[a].x, startY: corners[a].y,
                                   endX: corners[b].x, endY: corners[b].y)
        }
    }

    /// Applies tool state onto a geometry settings copy. Does not mutate Auto ranking thresholds.
    static func applying(_ state: CameraRawPerspectiveToolState, to geometry: CameraRawGeometrySettings) -> CameraRawGeometrySettings {
        var result = geometry
        switch state.kind {
        case .automatic:
            break
        case .verticalGuides:
            result.upright = .guided
            result.guides = state.verticalGuides
            result.vertical = 0; result.horizontal = 0; result.rotate = 0
        case .horizontalGuides:
            result.upright = .guided
            result.guides = state.horizontalGuides
            result.vertical = 0; result.horizontal = 0; result.rotate = 0
        case .combinedGuides:
            result.upright = .guided
            result.guides = state.verticalGuides + state.horizontalGuides
            result.vertical = 0; result.horizontal = 0; result.rotate = 0
        case .rectangle:
            result.upright = .guided
            result.guides = rectangleGuides(corners: state.rectangleCorners) ?? result.guides
            result.vertical = 0; result.horizontal = 0; result.rotate = 0
        case .eightPoint:
            result.upright = .guided
            result.guides = state.eightPointGuides
            result.vertical = 0; result.horizontal = 0; result.rotate = 0
        case .manualKeystone:
            result.upright = .off
            result.guides = []
            result.vertical = state.manualVertical
            result.horizontal = state.manualHorizontal
            result.rotate = state.manualRotate
        }
        return result
    }

    /// H/V Ratio is Aspect polish under a product name: positive widens, negative tallens (see `polish`).
    static func aspectFromHorizontalVerticalRatio(_ ratio: Double) -> Double {
        ImageAdjustmentPixels.clamp(ratio, CameraRawGeometrySettings.toneRange, 0)
    }

    static func horizontalVerticalRatio(fromAspect aspect: Double) -> Double {
        ImageAdjustmentPixels.clamp(aspect, CameraRawGeometrySettings.toneRange, 0)
    }
}
