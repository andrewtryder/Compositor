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

    /// Whether the tool draws anything on the preview. Automatic and Manual Keystone have no on-image handles.
    var drawsOnCanvas: Bool {
        switch self {
        case .automatic, .manualKeystone: return false
        case .verticalGuides, .horizontalGuides, .combinedGuides, .rectangle, .eightPoint: return true
        }
    }

    /// The storage this tool's single lists live in. Combined Guides uses both; Rectangle uses corners.
    var guideList: CameraRawPerspectiveGuideList? {
        switch self {
        case .verticalGuides: return .vertical
        case .horizontalGuides: return .horizontal
        case .eightPoint: return .eightPoint
        case .automatic, .combinedGuides, .rectangle, .manualKeystone: return nil
        }
    }

    /// Whether the tool itself solves the picture's keystone, replacing the Upright mode and the manual sliders.
    /// Automatic and Manual Keystone do not: they leave those two existing owners in charge.
    var ownsSolver: Bool {
        switch self {
        case .automatic, .manualKeystone: return false
        case .verticalGuides, .horizontalGuides, .combinedGuides, .rectangle, .eightPoint: return true
        }
    }

    /// Stable identifier suffix for accessibility and UI guards, independent of the visible label.
    var tagIdentifier: String {
        switch self {
        case .automatic: return "automatic"
        case .verticalGuides: return "verticalGuides"
        case .horizontalGuides: return "horizontalGuides"
        case .combinedGuides: return "combinedGuides"
        case .rectangle: return "rectangle"
        case .eightPoint: return "eightPoint"
        case .manualKeystone: return "manualKeystone"
        }
    }

    /// Short, honest instructions shown under the selector.
    var instructions: String {
        switch self {
        case .automatic:
            return "Automatic leaves the Upright mode above in charge. The other tools below add their own guides."
        case .verticalGuides:
            return "Draw one or two lines along edges that should stand upright. One levels the picture; two force them parallel."
        case .horizontalGuides:
            return "Draw one or two lines along edges that should run level. One levels the picture; two force them parallel."
        case .combinedGuides:
            return "Draw vertical and horizontal lines together. They are solved verticals first, then horizontals, every time."
        case .rectangle:
            return "Click the four corners of a rectangle you know is true, in order: top left, top right, bottom right, bottom left."
        case .eightPoint:
            return "Draw four segments — eight endpoints — along edges that should be straight. Nothing is applied until all four are placed."
        case .manualKeystone:
            return "Uses the Vertical, Horizontal and Rotate sliders in Manual Transformations. There is no second set here."
        }
    }
}

/// Which array of a tool's points a handle belongs to. Combined Guides keeps verticals and horizontals apart so
/// their order stays deterministic and a drag can never move the wrong one.
nonisolated enum CameraRawPerspectiveGuideList: String, CaseIterable, Sendable, Codable {
    case vertical
    case horizontal
    case eightPoint
}

/// One draggable point on the preview: an endpoint of a guide, an eight-point segment end, or a rectangle corner.
nonisolated enum CameraRawPerspectiveDragTarget: Equatable, Sendable {
    case guide(list: CameraRawPerspectiveGuideList, index: Int, isEnd: Bool)
    case corner(index: Int)

    var guideList: CameraRawPerspectiveGuideList? {
        if case .guide(let list, _, _) = self { return list }
        return nil
    }
}

/// Why a tool's stored geometry cannot produce a transform. Shown by the panel and asserted by tests; never
/// substituted with a different transform to keep a preview alive.
nonisolated enum CameraRawPerspectiveToolIssue: String, Sendable, Equatable, Error {
    case nonFiniteCoordinates = "A point is not a finite number."
    case coordinatesOutsideImage = "A point lies outside the picture."
    case insufficientPoints = "Not enough points yet."
    case duplicatePoints = "Two points sit on top of each other."
    case zeroLengthSegment = "A line has no length."
    case collinearConstraints = "The lines are too nearly parallel to solve."
    case invalidCornerOrder = "The corners are not in top-left, top-right, bottom-right, bottom-left order."
    case selfIntersecting = "The four corners cross over each other."
    case singularTransform = "These points do not define a usable transform."
    case excessiveDisplacement = "The correction would move the picture unreasonably far."
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
    /// Mirrors `CameraRawGeometrySettings.vertical`. See `CameraRawPerspectiveTools` for who owns what.
    var manualVertical: Double = 0
    var manualHorizontal: Double = 0
    var manualRotate: Double = 0

    /// The corners placed so far, one to four. An incomplete construction must be readable: returning an empty
    /// list until the fourth corner arrived would make each new click overwrite the first and a rectangle could
    /// never be finished. Only a complete, valid quad produces guides (`rectangleGuides`).
    var rectangleCorners: [CGPoint] {
        get {
            let count = min(rectangleCornerScalars.count / 2, 4)
            return (0..<count).map { CGPoint(x: rectangleCornerScalars[$0 * 2], y: rectangleCornerScalars[$0 * 2 + 1]) }
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

    /// Copies the sliders into the tool's own slots. The sliders on `CameraRawGeometrySettings` are the one owner;
    /// this mirror exists so each tool has its own copy without ever being able to override what the panel shows.
    mutating func synchronizingManual(with geometry: CameraRawGeometrySettings) {
        manualVertical = geometry.vertical
        manualHorizontal = geometry.horizontal
        manualRotate = geometry.rotate
    }

    /// True when the mirror and the sliders agree. A document written before the mirror existed opens with the
    /// sliders' values once settings are normalized, so nothing hidden can override them.
    func manualKeystoneIsMirrored(with geometry: CameraRawGeometrySettings) -> Bool {
        manualVertical == geometry.vertical
            && manualHorizontal == geometry.horizontal
            && manualRotate == geometry.rotate
    }

    // MARK: Stored points

    func guides(in list: CameraRawPerspectiveGuideList) -> [CameraRawGeometryGuide] {
        switch list {
        case .vertical: return verticalGuides
        case .horizontal: return horizontalGuides
        case .eightPoint: return eightPointGuides
        }
    }

    mutating func setGuides(_ guides: [CameraRawGeometryGuide], in list: CameraRawPerspectiveGuideList) {
        switch list {
        case .vertical: verticalGuides = guides
        case .horizontal: horizontalGuides = guides
        case .eightPoint: eightPointGuides = guides
        }
    }

    /// How many points each list keeps. The Guided Upright four-guide limit is its own and is untouched.
    /// Combined Guides may hold two verticals and two horizontals: that is exactly what the rectangle branch of the
    /// solver reads, and more would be silently ignored by it.
    static func capacity(for list: CameraRawPerspectiveGuideList) -> Int {
        switch list {
        case .vertical, .horizontal: return 2
        case .eightPoint: return 4
        }
    }

    /// Every point the active tool holds, in a stable order.
    func guideCount(for kind: CameraRawPerspectiveToolKind = .automatic) -> Int {
        let active = kind == .automatic ? self.kind : kind
        switch active {
        case .automatic, .manualKeystone: return 0
        case .verticalGuides: return verticalGuides.count
        case .horizontalGuides: return horizontalGuides.count
        case .combinedGuides: return verticalGuides.count + horizontalGuides.count
        case .eightPoint: return eightPointGuides.count
        case .rectangle: return rectangleCorners.count
        }
    }

    /// Convenience for callers that hold only the state. The panel and canvas pass the picture's size explicitly;
    /// this forwards to the one implementation so there is never a second validation path.
    func problem(width: Int, height: Int) -> CameraRawPerspectiveToolIssue? {
        CameraRawPerspectiveTools.problem(in: self, width: width, height: height)
    }

    /// Drops non-finite and zero-length points. Deliberately does not trim to `capacity(for:)`: a document written
    /// before this milestone may hold more guides than the panel now offers, and it must keep rendering as it did.
    /// New points go through `appendGuide`, which does enforce the per-list limit.
    var sanitized: CameraRawPerspectiveToolState {
        var result = self
        func clean(_ guides: [CameraRawGeometryGuide]) -> [CameraRawGeometryGuide] {
            guides.filter { guide in
                [guide.startX, guide.startY, guide.endX, guide.endY].allSatisfy(\.isFinite)
                    && hypot(guide.endX - guide.startX, guide.endY - guide.startY) > 0.01
            }
        }
        result.verticalGuides = clean(verticalGuides)
        result.horizontalGuides = clean(horizontalGuides)
        result.eightPointGuides = clean(eightPointGuides)
        // Corners are kept as an ordered quad or not at all: dropping one would renumber the rest, so an
        // incomplete set stays incomplete and `rectangleProblem` reports it.
        result.rectangleCornerScalars = rectangleCornerScalars
        return result
    }
}

/// Builds guides / corners for the solver without replacing the existing two- and four-guide paths.
nonisolated enum CameraRawPerspectiveTools {
    /// Guides the upright solver should use for the active tool. Nil means “leave geometry.guides alone”.
    /// An empty array means “this tool is active but has nothing usable”, which must render as identity rather than
    /// falling back to whatever a different tool left in `geometry.guides`.
    static func activeGuides(for state: CameraRawPerspectiveToolState) -> [CameraRawGeometryGuide]? {
        switch state.kind {
        case .automatic, .manualKeystone:
            return nil
        case .verticalGuides:
            return state.sanitized.verticalGuides
        case .horizontalGuides:
            return state.sanitized.horizontalGuides
        case .combinedGuides:
            // Deterministic: every vertical in stored order, then every horizontal. Same input, same solver input.
            return state.sanitized.verticalGuides + state.sanitized.horizontalGuides
        case .rectangle:
            // An incomplete or invalid rectangle is nothing at all, never a previous correction.
            return rectangleGuides(corners: state.rectangleCorners) ?? []
        case .eightPoint:
            // Four segments or none: two segments are not a weaker correction, they are half a construction.
            let guides = state.sanitized.eightPointGuides
            return guides.count == 4 ? guides : []
        }
    }

    /// Four corner points (normalized lower-left) → four edge guides for the existing DLT path.
    /// The order is fixed: TL → TR → BR → BL, so the edges are TL→TR, TR→BR, BR→BL, BL→TL.
    /// Nil for a degenerate, self-intersecting or wrongly ordered quad.
    static func rectangleGuides(corners: [CGPoint]) -> [CameraRawGeometryGuide]? {
        guard rectangleProblem(corners: corners) == nil else { return nil }
        // Edges: TL→TR, TR→BR, BR→BL, BL→TL. Two vertical + two horizontal for Auto Full / Guided.
        let edges = [(0, 1), (1, 2), (2, 3), (3, 0)]
        return edges.map { a, b in
            CameraRawGeometryGuide(startX: corners[a].x, startY: corners[a].y,
                                   endX: corners[b].x, endY: corners[b].y)
        }
    }

    /// The first reason these four corners cannot describe a rectangle, or nil when they can.
    static func rectangleProblem(corners: [CGPoint]) -> CameraRawPerspectiveToolIssue? {
        guard corners.count == 4 else { return .insufficientPoints }
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return .nonFiniteCoordinates }
        guard corners.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return .coordinatesOutsideImage }
        // 1% of the frame in normalized units is already a very small rectangle to constrain a picture with.
        let epsilon = 0.01
        for i in 0..<4 {
            for j in (i + 1)..<4 where hypot(corners[i].x - corners[j].x, corners[i].y - corners[j].y) <= epsilon {
                return .duplicatePoints
            }
        }
        // Order: TL, TR, BR, BL, with y up. A photographed rectangle is narrower at the top when its sides converge,
        // so the test is about which side of the quad a corner belongs to, not about comparing x across the diagonal.
        let (tl, tr, br, bl) = (corners[0], corners[1], corners[2], corners[3])
        guard tl.y >= br.y + epsilon, tl.y >= bl.y + epsilon,
              tr.y >= br.y + epsilon, tr.y >= bl.y + epsilon,
              tl.x <= tr.x + epsilon, bl.x <= br.x + epsilon,
              (tl.x + bl.x) / 2 <= (tr.x + br.x) / 2 + epsilon else { return .invalidCornerOrder }
        // Self-intersection: non-adjacent edges must not cross.
        if segmentsCross(tl, tr, br, bl) || segmentsCross(tr, br, bl, tl) { return .selfIntersecting }
        // Convexity and a usable area, the same test `CameraRawPerspective.convex` applies to a solved quad.
        var sign = 0.0
        var area = 0.0
        for index in 0..<4 {
            let a = corners[index], b = corners[(index + 1) % 4], c = corners[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-6 { return .collinearConstraints }
            if sign == 0 { sign = cross } else if cross * sign < 0 { return .selfIntersecting }
            area += a.x * b.y - a.y * b.x
        }
        guard abs(area) * 0.5 > 0.002 else { return .insufficientPoints }
        return nil
    }

    private static func segmentsCross(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        func orientation(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let d1 = orientation(p3, p4, p1), d2 = orientation(p3, p4, p2)
        let d3 = orientation(p1, p2, p3), d4 = orientation(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// The first reason the active tool cannot produce a transform, or nil when it can.
    /// `width` and `height` are the picture's pixel size, used for the solver's own plausibility test.
    /// Reads the stored state as-is: sanitizing first would drop a zero-length or corrupt point and report
    /// "not enough points", hiding the real reason from the person who drew it.
    static func problem(in state: CameraRawPerspectiveToolState, width: Int, height: Int) -> CameraRawPerspectiveToolIssue? {
        switch state.kind {
        case .automatic, .manualKeystone:
            return nil
        case .verticalGuides:
            return guideProblem(state.verticalGuides, width: width, height: height)
                ?? transformProblem(state, width: width, height: height)
        case .horizontalGuides:
            return guideProblem(state.horizontalGuides, width: width, height: height)
                ?? transformProblem(state, width: width, height: height)
        case .combinedGuides:
            let verticals = state.verticalGuides, horizontals = state.horizontalGuides
            if verticals.isEmpty, horizontals.isEmpty { return .insufficientPoints }
            if let issue = guideProblem(verticals, width: width, height: height) { return issue }
            if let issue = guideProblem(horizontals, width: width, height: height) { return issue }
            return transformProblem(state, width: width, height: height)
        case .rectangle:
            return rectangleProblem(corners: state.rectangleCorners) ?? transformProblem(state, width: width, height: height)
        case .eightPoint:
            guard state.eightPointGuides.count == 4 else { return .insufficientPoints }
            if let issue = guideProblem(state.eightPointGuides, width: width, height: height) { return issue }
            return transformProblem(state, width: width, height: height)
        }
    }

    private static func guideProblem(_ guides: [CameraRawGeometryGuide],
                                     width: Int, height: Int) -> CameraRawPerspectiveToolIssue? {
        guard !guides.isEmpty else { return .insufficientPoints }
        for guide in guides {
            guard [guide.startX, guide.startY, guide.endX, guide.endY].allSatisfy(\.isFinite) else {
                return .nonFiniteCoordinates
            }
            guard hypot(guide.endX - guide.startX, guide.endY - guide.startY) > 0.01 else { return .zeroLengthSegment }
        }
        // Repeated endpoints cannot add a constraint, and would be solved as if the first pair were the only one.
        for i in guides.indices {
            for j in guides.indices where j > i {
                let a = guides[i], b = guides[j]
                let sameDirection = hypot(a.startX - b.startX, a.startY - b.startY) <= 0.005
                    && hypot(a.endX - b.endX, a.endY - b.endY) <= 0.005
                let reversed = hypot(a.startX - b.endX, a.startY - b.endY) <= 0.005
                    && hypot(a.endX - b.startX, a.endY - b.startY) <= 0.005
                if sameDirection || reversed { return .duplicatePoints }
                if collinear(a, b) { return .collinearConstraints }
            }
        }
        return nil
    }

    /// Two guides lying along the same line say the same thing twice: there is no keystone to solve, only a roll.
    /// A share of the frame rather than an absolute distance, so the test means the same at any picture size.
    private static func collinear(_ a: CameraRawGeometryGuide, _ b: CameraRawGeometryGuide) -> Bool {
        let dx = a.endX - a.startX, dy = a.endY - a.startY
        let length = hypot(dx, dy)
        guard length > 0 else { return true }
        func offset(_ point: CGPoint) -> Double {
            abs(dy * (point.x - a.startX) - dx * (point.y - a.startY)) / length
        }
        return offset(b.start) <= 0.004 && offset(b.end) <= 0.004
    }

    /// The solved geometry must be a real, plausible transform — not merely finite numbers.
    private static func transformProblem(_ state: CameraRawPerspectiveToolState, width: Int, height: Int) -> CameraRawPerspectiveToolIssue? {
        guard width > 0, height > 0 else { return .insufficientPoints }
        guard let guides = activeGuides(for: state), !guides.isEmpty else { return .insufficientPoints }
        guard let homo = CameraRawPerspective.homography(guides: guides, width: width, height: height) else {
            return .singularTransform
        }
        guard homo.normalized() != nil else { return .singularTransform }
        guard homo.isPlausible(width: Double(width), height: Double(height)) else { return .excessiveDisplacement }
        return nil
    }

    /// Applies tool state onto a geometry settings copy. Does not mutate Auto ranking thresholds.
    /// The result is what the renderer sees; it is never written back into the document's stored geometry.
    static func applying(_ state: CameraRawPerspectiveToolState, to geometry: CameraRawGeometrySettings) -> CameraRawGeometrySettings {
        switch state.kind {
        case .automatic:
            // Nothing to do: the five-mode Upright path owns the picture, exactly as before this milestone.
            return geometry
        case .manualKeystone:
            // The Manual Transformations sliders on `geometry` are the one owner of these three numbers;
            // `state.manualVertical` and its siblings mirror them for per-tool storage. Rendering reads the sliders,
            // so a stale mirror can never override what the panel shows.
            var result = geometry
            result.upright = .off
            result.guides = []
            return result
        case .verticalGuides, .horizontalGuides, .combinedGuides, .eightPoint, .rectangle:
            var result = geometry
            // Solvers own keystone while a guide tool is active, so the manual numbers are cleared on this copy.
            // With no usable guides that leaves an identity, never a leftover manual keystone.
            result.vertical = 0
            result.horizontal = 0
            result.rotate = 0
            if let guides = activeGuides(for: state), !guides.isEmpty {
                result.upright = .guided
                result.guides = guides
            } else {
                // Active but incomplete or invalid: identity, never another tool's leftovers.
                result.upright = .off
                result.guides = []
            }
            return result
        }
    }

    /// H/V Ratio is Aspect polish under a product name: positive widens, negative tallens (see `polish`).
    static func aspectFromHorizontalVerticalRatio(_ ratio: Double) -> Double {
        ImageAdjustmentPixels.clamp(ratio, CameraRawGeometrySettings.toneRange, 0)
    }

    static func horizontalVerticalRatio(fromAspect aspect: Double) -> Double {
        ImageAdjustmentPixels.clamp(aspect, CameraRawGeometrySettings.toneRange, 0)
    }

    // MARK: - Handle addressing

    /// Every draggable handle the tool currently shows, in a stable order. Used by the canvas hit test and by tests;
    /// drawing uses the same lists so a handle can never be drawn in one place and grabbed in another.
    /// Reads the stored state as-is: sanitizing here would renumber guides mid-drag and move a handle under the pointer.
    static func dragTargets(for state: CameraRawPerspectiveToolState) -> [CameraRawPerspectiveDragTarget] {
        switch state.kind {
        case .automatic, .manualKeystone:
            return []
        case .verticalGuides:
            return guideTargets(.vertical, count: state.verticalGuides.count)
        case .horizontalGuides:
            return guideTargets(.horizontal, count: state.horizontalGuides.count)
        case .combinedGuides:
            return guideTargets(.vertical, count: state.verticalGuides.count)
                + guideTargets(.horizontal, count: state.horizontalGuides.count)
        case .eightPoint:
            return guideTargets(.eightPoint, count: state.eightPointGuides.count)
        case .rectangle:
            return (0..<state.rectangleCorners.count).map { .corner(index: $0) }
        }
    }

    private static func guideTargets(_ list: CameraRawPerspectiveGuideList, count: Int) -> [CameraRawPerspectiveDragTarget] {
        (0..<count).flatMap { index in
            [CameraRawPerspectiveDragTarget.guide(list: list, index: index, isEnd: false),
             .guide(list: list, index: index, isEnd: true)]
        }
    }

    /// The stored point a target names, or nil when the target no longer exists (a guide was cleared mid-drag).
    static func point(for target: CameraRawPerspectiveDragTarget, in state: CameraRawPerspectiveToolState) -> CGPoint? {
        switch target {
        case .guide(let list, let index, let isEnd):
            let guides = state.guides(in: list)
            guard guides.indices.contains(index) else { return nil }
            return isEnd ? guides[index].end : guides[index].start
        case .corner(let index):
            let corners = state.rectangleCorners
            guard corners.indices.contains(index) else { return nil }
            return corners[index]
        }
    }

    /// Moves one stored point in place. Returns false when the target no longer exists.
    @discardableResult
    static func setPoint(_ point: CGPoint, for target: CameraRawPerspectiveDragTarget,
                         in state: inout CameraRawPerspectiveToolState) -> Bool {
        switch target {
        case .guide(let list, let index, let isEnd):
            var guides = state.guides(in: list)
            guard guides.indices.contains(index) else { return false }
            if isEnd {
                guides[index].endX = point.x
                guides[index].endY = point.y
            } else {
                guides[index].startX = point.x
                guides[index].startY = point.y
            }
            state.setGuides(guides, in: list)
            return true
        case .corner(let index):
            var corners = state.rectangleCorners
            guard corners.indices.contains(index) else { return false }
            corners[index] = point
            state.rectangleCorners = corners
            return true
        }
    }

    /// Appends a finished guide to the active guide list. Returns false when the tool has no room for another one.
    @discardableResult
    static func appendGuide(_ guide: CameraRawGeometryGuide, to list: CameraRawPerspectiveGuideList,
                            in state: inout CameraRawPerspectiveToolState) -> Bool {
        var guides = state.guides(in: list)
        guard guides.count < CameraRawPerspectiveToolState.capacity(for: list) else { return false }
        guard [guide.startX, guide.startY, guide.endX, guide.endY].allSatisfy(\.isFinite),
              hypot(guide.endX - guide.startX, guide.endY - guide.startY) > 0.01 else { return false }
        guides.append(guide)
        state.setGuides(guides, in: list)
        return true
    }

    /// Clears only the active tool's own points, leaving every other tool's work in place.
    static func clear(_ kind: CameraRawPerspectiveToolKind, in state: inout CameraRawPerspectiveToolState) {
        switch kind {
        case .automatic, .manualKeystone: return
        case .verticalGuides: state.verticalGuides = []
        case .horizontalGuides: state.horizontalGuides = []
        case .combinedGuides:
            state.verticalGuides = []
            state.horizontalGuides = []
        case .rectangle: state.rectangleCornerScalars = []
        case .eightPoint: state.eightPointGuides = []
        }
    }

    // MARK: - Manual Keystone ownership

    /// The three keystone numbers as the panel shows them. The Manual Transformations sliders are stored on
    /// `CameraRawGeometrySettings`; the tool state mirrors them so a per-tool copy exists without being able to win.
    static func manualKeystoneValues(_ geometry: CameraRawGeometrySettings) -> (vertical: Double, horizontal: Double, rotate: Double) {
        (geometry.vertical, geometry.horizontal, geometry.rotate)
    }

    /// Writes the keystone sliders and their mirror in `perspectiveTools` in one step, so the two can never disagree.
    static func setManualKeystone(vertical: Double? = nil, horizontal: Double? = nil, rotate: Double? = nil,
                                  in settings: inout CameraRawSettings) {
        if let vertical {
            settings.geometry.vertical = vertical
            settings.perspectiveTools.manualVertical = vertical
        }
        if let horizontal {
            settings.geometry.horizontal = horizontal
            settings.perspectiveTools.manualHorizontal = horizontal
        }
        if let rotate {
            settings.geometry.rotate = rotate
            settings.perspectiveTools.manualRotate = rotate
        }
    }

}
