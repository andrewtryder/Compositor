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
        let x = Double(point.x), y = Double(point.y)
        let w = m.6 * x + m.7 * y + m.8
        guard abs(w) > 1e-12 else { return point }
        return CGPoint(x: (m.0 * x + m.1 * y + m.2) / w, y: (m.3 * x + m.4 * y + m.5) / w)
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
        guard let h = solve(a, b: b, n: 8) else { return nil }
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

    static func classify(_ guide: CameraRawGeometryGuide) -> ClassifiedGuide? {
        let dx = guide.endX - guide.startX, dy = guide.endY - guide.startY
        let length = hypot(dx, dy)
        guard length > 0.01 else { return nil }
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
        guard abs(den) > 1e-9 else { return nil }
        let t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
        return CGPoint(x: x1 + t * (x2 - x1), y: y1 + t * (y2 - y1))
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

    /// Snap a line angle into a roll correction in degrees (horizon / upright).
    static func snapRotateDegrees(fromAngleDegrees angle: Double) -> Double {
        var rotate = -angle
        if rotate > 45 { rotate -= 90 } else if rotate < -45 { rotate += 90 }
        return rotate
    }

    /// Homography from the current guides, or nil when there is nothing useful to do.
    static func homography(guides: [CameraRawGeometryGuide], width: Int, height: Int) -> CameraRawHomography? {
        let w = Double(width), h = Double(height)
        guard w > 0, h > 0 else { return nil }
        let classified = guides.compactMap(classify)
        let verticals = classified.filter { $0.kind == .vertical }.sorted { $0.length > $1.length }
        let horizontals = classified.filter { $0.kind == .horizontal }.sorted { $0.length > $1.length }

        if verticals.count >= 2, horizontals.count >= 2 {
            return rectangleHomography(verticals: Array(verticals.prefix(2)), horizontals: Array(horizontals.prefix(2)),
                                       width: w, height: h)
        }
        if verticals.count >= 2 {
            let s0 = segment(verticals[0].guide, width: w, height: h)
            let s1 = segment(verticals[1].guide, width: w, height: h)
            if let vp = intersection(s0, s1),
               let homo = sendVanishingPointToInfinity(vp, verticalLines: true, width: w, height: h) {
                return homo
            }
            // Nearly parallel already: level to the mean angle from vertical.
            let mean = (verticals[0].angleDegrees + verticals[1].angleDegrees) / 2
            let fromVertical = mean > 0 ? mean - 90 : mean + 90
            return CameraRawHomography.rotation(degrees: -fromVertical, around: CGPoint(x: w / 2, y: h / 2))
        }
        if horizontals.count >= 2 {
            let s0 = segment(horizontals[0].guide, width: w, height: h)
            let s1 = segment(horizontals[1].guide, width: w, height: h)
            if let vp = intersection(s0, s1),
               let homo = sendVanishingPointToInfinity(vp, verticalLines: false, width: w, height: h) {
                return homo
            }
            let mean = (horizontals[0].angleDegrees + horizontals[1].angleDegrees) / 2
            return CameraRawHomography.rotation(degrees: snapRotateDegrees(fromAngleDegrees: mean),
                                               around: CGPoint(x: w / 2, y: h / 2))
        }
        if let first = horizontals.first ?? verticals.first {
            let rotate = first.kind == .horizontal
                ? snapRotateDegrees(fromAngleDegrees: first.angleDegrees)
                : snapRotateDegrees(fromAngleDegrees: first.angleDegrees > 0 ? first.angleDegrees - 90 : first.angleDegrees + 90)
            guard abs(rotate) > 0.05 else { return nil }
            return CameraRawHomography.rotation(degrees: rotate, around: CGPoint(x: w / 2, y: h / 2))
        }
        return nil
    }

    private static func rectangleHomography(verticals: [ClassifiedGuide], horizontals: [ClassifiedGuide],
                                            width: Double, height: Double) -> CameraRawHomography? {
        let v0 = segment(verticals[0].guide, width: width, height: height)
        let v1 = segment(verticals[1].guide, width: width, height: height)
        let h0 = segment(horizontals[0].guide, width: width, height: height)
        let h1 = segment(horizontals[1].guide, width: width, height: height)
        guard let c00 = intersection(v0, h0), let c01 = intersection(v0, h1),
              let c10 = intersection(v1, h0), let c11 = intersection(v1, h1) else { return nil }
        // Order corners: average to place left/right and bottom/top.
        var corners = [c00, c01, c10, c11]
        corners.sort { $0.x + $0.y < $1.x + $1.y }
        // Rebuild as TL, TR, BR, BL in CI y-up space by sorting.
        let byY = [c00, c01, c10, c11].sorted { $0.y > $1.y }
        let top = Array(byY.prefix(2)).sorted { $0.x < $1.x }
        let bottom = Array(byY.suffix(2)).sorted { $0.x < $1.x }
        guard top.count == 2, bottom.count == 2 else { return nil }
        let source = [top[0], top[1], bottom[1], bottom[0]]
        let minX = source.map(\.x).min()!, maxX = source.map(\.x).max()!
        let minY = source.map(\.y).min()!, maxY = source.map(\.y).max()!
        let destination = [
            CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY),
            CGPoint(x: maxX, y: minY), CGPoint(x: minX, y: minY)
        ]
        return CameraRawHomography.dlt(from: source, to: destination)
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
