import AppKit
import CoreGraphics
import Vision

/// Builds Guided-style guides from the picture for Auto Level / Vertical / Full.
nonisolated enum CameraRawUprightDetection {
    /// Normalized lower-left guides for the requested Auto mode. Empty when nothing useful was found.
    static func guides(in image: CGImage, mode: CameraRawUprightMode) -> [CameraRawGeometryGuide] {
        switch mode {
        case .autoLevel:
            if let horizon = visionHorizon(image) { return [horizon] }
            return strongestNearHorizontal(from: houghLines(in: image)).map { [$0] } ?? []
        case .autoVertical:
            if let pair = bestVerticalPair(from: visionRectangleGuides(image) + houghLines(in: image)) {
                return pair
            }
            return []
        case .autoFull:
            let fromRect = visionRectangleGuides(image)
            let verticals = fromRect.filter { isVertical($0) }
            let horizontals = fromRect.filter { isHorizontal($0) }
            if verticals.count >= 2, horizontals.count >= 2 {
                return Array(verticals.prefix(2)) + Array(horizontals.prefix(2))
            }
            let lines = fromRect + houghLines(in: image)
            if let vPair = bestVerticalPair(from: lines), let hPair = bestHorizontalPair(from: lines) {
                return vPair + hPair
            }
            if let vPair = bestVerticalPair(from: lines) { return vPair }
            if let horizon = visionHorizon(image) { return [horizon] }
            return strongestNearHorizontal(from: lines).map { [$0] } ?? []
        case .off, .guided:
            return []
        }
    }

    // MARK: - Vision

    private static func visionHorizon(_ image: CGImage) -> CameraRawGeometryGuide? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first else { return nil }
        // Vision's angle is radians; positive tilts the right side up. Build a near-horizontal guide through the center.
        let angle = Double(observation.angle)
        let cx = 0.5, cy = 0.5
        let half = 0.45
        let dx = cos(angle) * half, dy = sin(angle) * half
        return CameraRawGeometryGuide(startX: cx - dx, startY: cy - dy, endX: cx + dx, endY: cy + dy)
    }

    private static func visionRectangleGuides(_ image: CGImage) -> [CameraRawGeometryGuide] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 4
        request.minimumConfidence = 0.4
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 25
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let rects = request.results, !rects.isEmpty else { return [] }
        // Vision uses lower-left origin for bounding box corners — same as our guides.
        let best = rects.max(by: { $0.confidence < $1.confidence })!
        let tl = best.topLeft, tr = best.topRight, br = best.bottomRight, bl = best.bottomLeft
        return [
            CameraRawGeometryGuide(startX: Double(tl.x), startY: Double(tl.y), endX: Double(bl.x), endY: Double(bl.y)),
            CameraRawGeometryGuide(startX: Double(tr.x), startY: Double(tr.y), endX: Double(br.x), endY: Double(br.y)),
            CameraRawGeometryGuide(startX: Double(tl.x), startY: Double(tl.y), endX: Double(tr.x), endY: Double(tr.y)),
            CameraRawGeometryGuide(startX: Double(bl.x), startY: Double(bl.y), endX: Double(br.x), endY: Double(br.y))
        ]
    }

    // MARK: - Hough fallback

    /// Probabilistic Hough on a downscaled grayscale edge map. Guides are normalized lower-left.
    private static func houghLines(in image: CGImage) -> [CameraRawGeometryGuide] {
        let maxSide = 160
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = try? BrushRaster.context(width: width, height: height, mask: false) else { return [] }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data else { return [] }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = context.bytesPerRow
        var gray = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * rowBytes + x * 4
                let a = Double(bytes[p + 3])
                if a <= 0 { continue }
                gray[y * width + x] = (0.2126 * Double(bytes[p]) + 0.7152 * Double(bytes[p + 1]) + 0.0722 * Double(bytes[p + 2])) / a * 255
            }
        }
        // Sobel magnitude.
        var edges = [Bool](repeating: false, count: width * height)
        let threshold = 40.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let gx = -gray[i - width - 1] - 2 * gray[i - 1] - gray[i + width - 1]
                    + gray[i - width + 1] + 2 * gray[i + 1] + gray[i + width + 1]
                let gy = -gray[i - width - 1] - 2 * gray[i - width] - gray[i - width + 1]
                    + gray[i + width - 1] + 2 * gray[i + width] + gray[i + width + 1]
                edges[i] = hypot(gx, gy) >= threshold
            }
        }
        let angleSteps = 180
        let rhoMax = hypot(Double(width), Double(height))
        let rhoSteps = max(1, Int(rhoMax.rounded()) * 2)
        var votes = [Int](repeating: 0, count: angleSteps * rhoSteps)
        var edgePoints: [(Int, Int)] = []
        edgePoints.reserveCapacity(width * height / 8)
        for y in 0..<height {
            for x in 0..<width where edges[y * width + x] {
                edgePoints.append((x, y))
            }
        }
        guard edgePoints.count > 20 else { return [] }
        // Probabilistic: subsample edge points.
        let step = max(1, edgePoints.count / 2500)
        for i in stride(from: 0, to: edgePoints.count, by: step) {
            let (x, y) = edgePoints[i]
            for t in 0..<angleSteps {
                let theta = Double(t) * .pi / Double(angleSteps)
                let rho = Double(x) * cos(theta) + Double(y) * sin(theta)
                let r = Int((rho + rhoMax).rounded())
                guard r >= 0, r < rhoSteps else { continue }
                votes[t * rhoSteps + r] += 1
            }
        }
        struct Peak { var theta: Double; var rho: Double; var votes: Int }
        var peaks: [Peak] = []
        let minVotes = max(12, edgePoints.count / (step * 80))
        for t in 0..<angleSteps {
            for r in 0..<rhoSteps {
                let v = votes[t * rhoSteps + r]
                guard v >= minVotes else { continue }
                // Local maximum in a small neighborhood.
                var isMax = true
                for dt in -1...1 where isMax {
                    for dr in -1...1 {
                        if dt == 0 && dr == 0 { continue }
                        let tt = (t + dt + angleSteps) % angleSteps
                        let rr = r + dr
                        guard rr >= 0, rr < rhoSteps else { continue }
                        if votes[tt * rhoSteps + rr] > v { isMax = false; break }
                    }
                }
                if isMax {
                    peaks.append(Peak(theta: Double(t) * .pi / Double(angleSteps),
                                      rho: Double(r) - rhoMax, votes: v))
                }
            }
        }
        peaks.sort { $0.votes > $1.votes }
        var guides: [CameraRawGeometryGuide] = []
        for peak in peaks.prefix(12) {
            guard let segment = segment(theta: peak.theta, rho: peak.rho, width: width, height: height) else { continue }
            // BrushRaster contexts are lower-left; Vision / guides use the same origin.
            let guide = CameraRawGeometryGuide(
                startX: Double(segment.0.x) / Double(width),
                startY: Double(segment.0.y) / Double(height),
                endX: Double(segment.1.x) / Double(width),
                endY: Double(segment.1.y) / Double(height)
            )
            // Suppress near-duplicates.
            let duplicate = guides.contains { other in
                abs(atan2(guide.endY - guide.startY, guide.endX - guide.startX)
                    - atan2(other.endY - other.startY, other.endX - other.startX)) < 0.12
                    && abs(midX(guide) - midX(other)) < 0.08 && abs(midY(guide) - midY(other)) < 0.08
            }
            if !duplicate { guides.append(guide) }
        }
        return guides
    }

    private static func segment(theta: Double, rho: Double, width: Int, height: Int) -> (CGPoint, CGPoint)? {
        let c = cos(theta), s = sin(theta)
        // Intersect the line with the image bounds.
        var points: [CGPoint] = []
        if abs(s) > 1e-6 {
            let y0 = rho / s
            let y1 = (rho - Double(width - 1) * c) / s
            if y0 >= 0, y0 <= Double(height - 1) { points.append(CGPoint(x: 0.0, y: y0)) }
            if y1 >= 0, y1 <= Double(height - 1) { points.append(CGPoint(x: Double(width - 1), y: y1)) }
        }
        if abs(c) > 1e-6 {
            let x0 = rho / c
            let x1 = (rho - Double(height - 1) * s) / c
            if x0 >= 0, x0 <= Double(width - 1) { points.append(CGPoint(x: x0, y: 0.0)) }
            if x1 >= 0, x1 <= Double(width - 1) { points.append(CGPoint(x: x1, y: Double(height - 1))) }
        }
        guard points.count >= 2 else { return nil }
        return (points[0], points[1])
    }

    // MARK: - Pair selection

    private static func isVertical(_ guide: CameraRawGeometryGuide) -> Bool {
        CameraRawPerspective.classify(guide)?.kind == .vertical
    }

    private static func isHorizontal(_ guide: CameraRawGeometryGuide) -> Bool {
        CameraRawPerspective.classify(guide)?.kind == .horizontal
    }

    private static func midX(_ g: CameraRawGeometryGuide) -> Double { (g.startX + g.endX) / 2 }
    private static func midY(_ g: CameraRawGeometryGuide) -> Double { (g.startY + g.endY) / 2 }

    private static func length(_ g: CameraRawGeometryGuide) -> Double {
        hypot(g.endX - g.startX, g.endY - g.startY)
    }

    private static func bestVerticalPair(from guides: [CameraRawGeometryGuide]) -> [CameraRawGeometryGuide]? {
        let verticals = guides.filter(isVertical).sorted { length($0) > length($1) }
        guard verticals.count >= 2 else { return nil }
        var best: (CameraRawGeometryGuide, CameraRawGeometryGuide, Double)?
        for i in 0..<verticals.count {
            for j in (i + 1)..<verticals.count {
                let separation = abs(midX(verticals[i]) - midX(verticals[j]))
                guard separation > 0.12 else { continue }
                let score = length(verticals[i]) * length(verticals[j]) * separation
                if best == nil || score > best!.2 {
                    best = (verticals[i], verticals[j], score)
                }
            }
        }
        guard let best else { return nil }
        return [best.0, best.1]
    }

    private static func bestHorizontalPair(from guides: [CameraRawGeometryGuide]) -> [CameraRawGeometryGuide]? {
        let horizontals = guides.filter(isHorizontal).sorted { length($0) > length($1) }
        guard horizontals.count >= 2 else { return nil }
        var best: (CameraRawGeometryGuide, CameraRawGeometryGuide, Double)?
        for i in 0..<horizontals.count {
            for j in (i + 1)..<horizontals.count {
                let separation = abs(midY(horizontals[i]) - midY(horizontals[j]))
                guard separation > 0.12 else { continue }
                let score = length(horizontals[i]) * length(horizontals[j]) * separation
                if best == nil || score > best!.2 {
                    best = (horizontals[i], horizontals[j], score)
                }
            }
        }
        guard let best else { return nil }
        return [best.0, best.1]
    }

    private static func strongestNearHorizontal(from guides: [CameraRawGeometryGuide]) -> CameraRawGeometryGuide? {
        guides.filter(isHorizontal).max(by: { length($0) < length($1) })
    }
}
