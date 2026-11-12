import CoreGraphics
import Foundation

/// 3×3 homography in row-major order. Maps source pixel (x, y, 1) → destination.
nonisolated struct CameraRawHomography: Equatable, Sendable {
    var m: (Double, Double, Double, Double, Double, Double, Double, Double, Double)

    static func == (lhs: CameraRawHomography, rhs: CameraRawHomography) -> Bool {
        lhs.m.0 == rhs.m.0 && lhs.m.1 == rhs.m.1 && lhs.m.2 == rhs.m.2
            && lhs.m.3 == rhs.m.3 && lhs.m.4 == rhs.m.4 && lhs.m.5 == rhs.m.5
            && lhs.m.6 == rhs.m.6 && lhs.m.7 == rhs.m.7 && lhs.m.8 == rhs.m.8
    }

    static let identity = CameraRawHomography(m: (1, 0, 0, 0, 1, 0, 0, 0, 1))

    func applying(_ point: CGPoint) -> CGPoint {
        applyingFinite(point) ?? point
    }

    /// Nil when the point lands on the line at infinity or the result is non-finite.
    func applyingFinite(_ point: CGPoint) -> CGPoint? {
        let x = Double(point.x), y = Double(point.y)
        let w = m.6 * x + m.7 * y + m.8
        guard w.isFinite, abs(w) > 1e-8 else { return nil }
        let px = (m.0 * x + m.1 * y + m.2) / w
        let py = (m.3 * x + m.4 * y + m.5) / w
        guard px.isFinite, py.isFinite else { return nil }
        return CGPoint(x: px, y: py)
    }

    /// The image quad stays finite, convex, and inside a generous margin. Extreme warps are rejected.
    func isPlausible(width: Double, height: Double) -> Bool {
        guard width > 0, height > 0, m.0.isFinite, m.8.isFinite else { return false }
        let source = [
            CGPoint(x: 0, y: height), CGPoint(x: width, y: height),
            CGPoint(x: width, y: 0), CGPoint(x: 0, y: 0)
        ]
        var mapped: [CGPoint] = []
        mapped.reserveCapacity(4)
        for point in source {
            guard let next = applyingFinite(point) else { return false }
            mapped.append(next)
        }
        let padX = width * 3, padY = height * 3
        for point in mapped {
            if point.x < -padX || point.x > width + padX || point.y < -padY || point.y > height + padY { return false }
        }
        var sign = 0.0
        var area = 0.0
        for index in 0..<4 {
            let a = mapped[index], b = mapped[(index + 1) % 4], c = mapped[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-4 { return false }
            if sign == 0 { sign = cross } else if cross * sign < 0 { return false }
            area += a.x * b.y - a.y * b.x
        }
        area = abs(area) * 0.5
        let image = width * height
        return area > image * 0.02 && area < image * 25
    }

    static func translation(tx: Double, ty: Double) -> CameraRawHomography {
        CameraRawHomography(m: (1, 0, tx, 0, 1, ty, 0, 0, 1))
    }

    static func rotation(degrees: Double, around center: CGPoint) -> CameraRawHomography {
        let r = degrees * .pi / 180
        let c = cos(r), s = sin(r)
        let toOrigin = translation(tx: -Double(center.x), ty: -Double(center.y))
        let rot = CameraRawHomography(m: (c, -s, 0, s, c, 0, 0, 0, 1))
        let back = translation(tx: Double(center.x), ty: Double(center.y))
        return back * rot * toOrigin
    }

    static func * (lhs: CameraRawHomography, rhs: CameraRawHomography) -> CameraRawHomography {
        func at(_ h: CameraRawHomography, _ r: Int, _ c: Int) -> Double {
            let i = r * 3 + c
            switch i {
            case 0: return h.m.0; case 1: return h.m.1; case 2: return h.m.2
            case 3: return h.m.3; case 4: return h.m.4; case 5: return h.m.5
            case 6: return h.m.6; case 7: return h.m.7; default: return h.m.8
            }
        }
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                out[r * 3 + c] = at(lhs, r, 0) * at(rhs, 0, c) + at(lhs, r, 1) * at(rhs, 1, c) + at(lhs, r, 2) * at(rhs, 2, c)
            }
        }
        return CameraRawHomography(m: (out[0], out[1], out[2], out[3], out[4], out[5], out[6], out[7], out[8]))
    }

    /// Direct linear transform from four source→destination correspondences. Nil when degenerate.
    static func dlt(from sources: [CGPoint], to destinations: [CGPoint]) -> CameraRawHomography? {
        guard sources.count == 4, destinations.count == 4 else { return nil }
        // Inhomogeneous DLT with h₈ = 1: eight equations in eight unknowns.
        var a = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        var b = [Double](repeating: 0, count: 8)
        for i in 0..<4 {
            let x = Double(sources[i].x), y = Double(sources[i].y)
            let u = Double(destinations[i].x), v = Double(destinations[i].y)
            a[i * 2] = [-x, -y, -1, 0, 0, 0, u * x, u * y]
            b[i * 2] = -u
            a[i * 2 + 1] = [0, 0, 0, -x, -y, -1, v * x, v * y]
            b[i * 2 + 1] = -v
        }
        guard let h = solve(a, b: b, n: 8), h.allSatisfy(\.isFinite) else { return nil }
        return CameraRawHomography(m: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1))
    }

    /// Gaussian elimination for an n×n system. Nil on a singular matrix.
    private static func solve(_ matrix: [[Double]], b: [Double], n: Int) -> [Double]? {
        var m = matrix
        var x = b
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            if abs(m[pivot][col]) < 1e-14 { return nil }
            m.swapAt(col, pivot)
            x.swapAt(col, pivot)
            let div = m[col][col]
            for c in col..<n { m[col][c] /= div }
            x[col] /= div
            for r in 0..<n where r != col {
                let f = m[r][col]
                for c in col..<n { m[r][c] -= f * m[col][c] }
                x[r] -= f * x[col]
            }
        }
        return x
    }
}

/// Classifies and solves Guided / Auto upright guides into a homography, then four CIPerspectiveTransform corners.
nonisolated enum CameraRawPerspective {
    enum GuideKind { case vertical, horizontal }

    struct ClassifiedGuide {
        var guide: CameraRawGeometryGuide
        var kind: GuideKind
        var length: Double
        var angleDegrees: Double
    }

    static func classify(_ guide: CameraRawGeometryGuide, width: Double, height: Double) -> ClassifiedGuide? {
        let dx = (guide.endX - guide.startX) * width, dy = (guide.endY - guide.startY) * height
        let length = hypot(dx, dy)
        guard length > 0.01 * max(width, height) else { return nil }
        let angle = atan2(dy, dx) * 180 / .pi
        let kind: GuideKind = abs(angle) > 45 && abs(angle) < 135 ? .vertical : .horizontal
        return ClassifiedGuide(guide: guide, kind: kind, length: length, angleDegrees: angle)
    }

    /// Pixel-space segment from a normalized lower-left guide.
    static func segment(_ guide: CameraRawGeometryGuide, width: Double, height: Double) -> (CGPoint, CGPoint) {
        (CGPoint(x: guide.startX * width, y: guide.startY * height),
         CGPoint(x: guide.endX * width, y: guide.endY * height))
    }

    static func intersection(_ a: (CGPoint, CGPoint), _ b: (CGPoint, CGPoint)) -> CGPoint? {
        let x1 = Double(a.0.x), y1 = Double(a.0.y), x2 = Double(a.1.x), y2 = Double(a.1.y)
        let x3 = Double(b.0.x), y3 = Double(b.0.y), x4 = Double(b.1.x), y4 = Double(b.1.y)
        let den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        let scale = max(1, hypot(x2 - x1, y2 - y1) * hypot(x4 - x3, y4 - y3))
        guard abs(den) > 1e-8 * scale else { return nil }
        let t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
        let x = x1 + t * (x2 - x1), y = y1 + t * (y2 - y1)
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// A vanishing point close to the picture makes a destructive warp. Parallel lines have none.
    static func vanishingPointIsFar(_ point: CGPoint, width: Double, height: Double) -> Bool {
        let marginX = width * 0.35, marginY = height * 0.35
        return point.x < -marginX || point.x > width + marginX || point.y < -marginY || point.y > height + marginY
    }

    /// Undirected line angle folded into (−90°, 90°]. Reversing a guide does not change it.
    static func foldedOrientation(_ angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        var value = angle.truncatingRemainder(dividingBy: 180)
        if value > 90 { value -= 180 }
        if value <= -90 { value += 180 }
        return value
    }

    /// Smallest rotation that lays an undirected line on the horizontal.
    static func rotationOntoHorizontal(angleDegrees angle: Double) -> Double {
        -foldedOrientation(angle)
    }

    /// Smallest rotation that stands an undirected line on the vertical.
    static func rotationOntoVertical(angleDegrees angle: Double) -> Double {
        let folded = foldedOrientation(angle)
        let deviation = folded >= 0 ? folded - 90 : folded + 90
        return -deviation
    }

    /// Mean undirected orientation, in (−90°, 90°]. Endpoint order does not matter.
    static func meanOrientation(_ angles: [Double]) -> Double {
        var x = 0.0, y = 0.0
        for angle in angles where angle.isFinite {
            let doubled = angle * .pi / 90
            x += cos(doubled)
            y += sin(doubled)
        }
        guard x != 0 || y != 0 else { return 0 }
        return atan2(y, x) * 90 / .pi
    }

    /// Homography that sends a finite vanishing point to infinity (projective keystone undo).
    static func sendVanishingPointToInfinity(_ vp: CGPoint, verticalLines: Bool, width: Double, height: Double) -> CameraRawHomography? {
        let cx = width / 2, cy = height / 2
        let px = Double(vp.x) - cx, py = Double(vp.y) - cy
        // In centered coords, H = [[1,0,0],[0,1,0],[a,b,1]] with a*px + b*py = -1.
        let a: Double, b: Double
        if verticalLines {
            // Prefer pitch-only (horizontal vanishing line) when the VP is off the horizontal midline.
            if abs(py) > 1e-3 {
                a = 0
                b = -1 / py
            } else if abs(px) > 1e-3 {
                a = -1 / px
                b = 0
            } else {
                return nil
            }
        } else {
            if abs(px) > 1e-3 {
                a = -1 / px
                b = 0
            } else if abs(py) > 1e-3 {
                a = 0
                b = -1 / py
            } else {
                return nil
            }
        }
        let centered = CameraRawHomography(m: (1, 0, 0, 0, 1, 0, a, b, 1))
        let toOrigin = CameraRawHomography.translation(tx: -cx, ty: -cy)
        let back = CameraRawHomography.translation(tx: cx, ty: cy)
        return back * centered * toOrigin
    }

    /// Homography from the current guides, or nil when there is nothing useful to do.
    /// A bad rectangle falls back to a parallel pair, then to a roll. An extreme warp is refused.
    static func homography(guides: [CameraRawGeometryGuide], width: Int, height: Int) -> CameraRawHomography? {
        let w = Double(width), h = Double(height)
        guard w > 0, h > 0 else { return nil }
        let classified = guides.compactMap { classify($0, width: w, height: h) }
        let verticals = classified.filter { $0.kind == .vertical }.sorted { $0.length > $1.length }
        let horizontals = classified.filter { $0.kind == .horizontal }.sorted { $0.length > $1.length }

        if verticals.count >= 2, horizontals.count >= 2,
           let homo = rectangleHomography(verticals: Array(verticals.prefix(2)), horizontals: Array(horizontals.prefix(2)),
                                          width: w, height: h),
           homo.isPlausible(width: w, height: h) {
            return homo
        }
        if verticals.count >= 2, let homo = forceParallel(verticals[0], verticals[1], verticalLines: true, width: w, height: h) {
            return homo
        }
        if horizontals.count >= 2, let homo = forceParallel(horizontals[0], horizontals[1], verticalLines: false, width: w, height: h) {
            return homo
        }
        if let first = horizontals.first ?? verticals.first {
            return roll(first, width: w, height: h)
        }
        return nil
    }

    /// Force two guides parallel and then onto the axis. A vanishing point inside the frame is ignored.
    private static func forceParallel(_ first: ClassifiedGuide, _ second: ClassifiedGuide, verticalLines: Bool,
                                      width: Double, height: Double) -> CameraRawHomography? {
        let center = CGPoint(x: width / 2, y: height / 2)
        let s0 = segment(first.guide, width: width, height: height)
        let s1 = segment(second.guide, width: width, height: height)
        if let vanishing = intersection(s0, s1), vanishingPointIsFar(vanishing, width: width, height: height),
           let keystone = sendVanishingPointToInfinity(vanishing, verticalLines: verticalLines, width: width, height: height) {
            let direction = atan2(Double(vanishing.y) - height / 2, Double(vanishing.x) - width / 2) * 180 / .pi
            let rotate = verticalLines ? rotationOntoVertical(angleDegrees: direction) : rotationOntoHorizontal(angleDegrees: direction)
            let solved = abs(rotate) > 0.05
                ? CameraRawHomography.rotation(degrees: rotate, around: center) * keystone
                : keystone
            if solved.isPlausible(width: width, height: height) { return solved }
        }
        let mean = meanOrientation([first.angleDegrees, second.angleDegrees])
        let rotate = verticalLines ? rotationOntoVertical(angleDegrees: mean) : rotationOntoHorizontal(angleDegrees: mean)
        guard abs(rotate) > 0.05 else { return nil }
        let solved = CameraRawHomography.rotation(degrees: rotate, around: center)
        return solved.isPlausible(width: width, height: height) ? solved : nil
    }

    private static func roll(_ guide: ClassifiedGuide, width: Double, height: Double) -> CameraRawHomography? {
        let rotate = guide.kind == .horizontal
            ? rotationOntoHorizontal(angleDegrees: guide.angleDegrees)
            : rotationOntoVertical(angleDegrees: guide.angleDegrees)
        guard abs(rotate) > 0.05 else { return nil }
        let solved = CameraRawHomography.rotation(degrees: rotate, around: CGPoint(x: width / 2, y: height / 2))
        return solved.isPlausible(width: width, height: height) ? solved : nil
    }

    private static func rectangleHomography(verticals: [ClassifiedGuide], horizontals: [ClassifiedGuide],
                                            width: Double, height: Double) -> CameraRawHomography? {
        let v0 = segment(verticals[0].guide, width: width, height: height)
        let v1 = segment(verticals[1].guide, width: width, height: height)
        let h0 = segment(horizontals[0].guide, width: width, height: height)
        let h1 = segment(horizontals[1].guide, width: width, height: height)
        guard let c00 = intersection(v0, h0), let c01 = intersection(v0, h1),
              let c10 = intersection(v1, h0), let c11 = intersection(v1, h1) else { return nil }
        let raw = [c00, c01, c10, c11]
        guard raw.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let cx = raw.map(\.x).reduce(0, +) / 4, cy = raw.map(\.y).reduce(0, +) / 4
        // Clockwise in y-up, starting at the corner nearest the top-left.
        var ordered = raw.sorted { atan2($0.y - cy, $0.x - cx) > atan2($1.y - cy, $1.x - cx) }
        guard let start = ordered.indices.min(by: { ordered[$0].x - ordered[$0].y < ordered[$1].x - ordered[$1].y }) else { return nil }
        ordered = Array(ordered[start...]) + Array(ordered[..<start])
        guard ordered.count == 4, convex(ordered) else { return nil }
        let top = hypot(ordered[1].x - ordered[0].x, ordered[1].y - ordered[0].y)
        let bottom = hypot(ordered[2].x - ordered[3].x, ordered[2].y - ordered[3].y)
        let right = hypot(ordered[2].x - ordered[1].x, ordered[2].y - ordered[1].y)
        let left = hypot(ordered[3].x - ordered[0].x, ordered[3].y - ordered[0].y)
        let rectWidth = max(1, (top + bottom) / 2)
        let rectHeight = max(1, (left + right) / 2)
        let halfW = rectWidth / 2, halfH = rectHeight / 2
        let midX = width / 2, midY = height / 2
        let destination = [
            CGPoint(x: midX - halfW, y: midY + halfH), CGPoint(x: midX + halfW, y: midY + halfH),
            CGPoint(x: midX + halfW, y: midY - halfH), CGPoint(x: midX - halfW, y: midY - halfH)
        ]
        return CameraRawHomography.dlt(from: ordered, to: destination)
    }

    private static func convex(_ corners: [CGPoint]) -> Bool {
        var sign = 0.0
        for index in 0..<corners.count {
            let a = corners[index], b = corners[(index + 1) % corners.count], c = corners[(index + 2) % corners.count]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-4 { return false }
            if sign == 0 { sign = cross } else if cross * sign < 0 { return false }
        }
        return true
    }

    /// Where the image's four corners land after `homography`, in CIPerspectiveTransform order (TL, TR, BR, BL).
    static func perspectiveCorners(homography: CameraRawHomography, width: Int, height: Int) -> [CGPoint] {
        let w = Double(width), h = Double(height)
        let source = [
            CGPoint(x: 0, y: h), CGPoint(x: w, y: h),
            CGPoint(x: w, y: 0), CGPoint(x: 0, y: 0)
        ]
        return source.map { homography.applying($0) }
    }
}
