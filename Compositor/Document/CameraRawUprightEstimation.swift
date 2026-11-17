import CoreGraphics
import Foundation

/// One straight edge in analysis pixels. `y` grows downward, matching the bitmap row order.
struct CameraRawDetectedLine: Equatable, Sendable {
    var x0: Double
    var y0: Double
    var x1: Double
    var y1: Double

    var length: Double { hypot(x1 - x0, y1 - y0) }
    var midX: Double { (x0 + x1) / 2 }
    var midY: Double { (y0 + y1) / 2 }
    /// Direction in degrees, (−180°, 180°]. Reversing the endpoints adds 180°.
    var angleDegrees: Double { atan2(y1 - y0, x1 - x0) * 180 / .pi }

    /// Unit normal form `ax + by + c = 0`.
    var normal: (a: Double, b: Double, c: Double) {
        let dx = x1 - x0, dy = y1 - y0
        let length = max(hypot(dx, dy), 1e-9)
        let a = dy / length, b = -dx / length
        return (a, b, -(a * x0 + b * y0))
    }
}

enum CameraRawUprightFallback: String, Sendable {
    case none
    case vertical
    case level
    case identity
}

/// What Auto decided, including evidence that is not saved in the project.
struct CameraRawUprightObservation: Sendable {
    var guides: [CameraRawGeometryGuide] = []
    var mode: CameraRawUprightMode = .off
    var confidence: Double = 0
    var residualDegrees: Double = 0
    var supportingLines: Int = 0
    var fallback: CameraRawUprightFallback = .identity
    var lineExtractionMilliseconds: Double = 0
    var vanishingMilliseconds: Double = 0
    var solveMilliseconds: Double = 0
    /// Fraction of the output frame the warped quad still covers. Empty corners lower this.
    /// A uniform grid: it does not know that a person matters more than a ceiling.
    var coverage: Double = 1
    /// Fraction of source samples that land inside the output frame. Corners pushed outside lower this.
    var retainedFraction: Double = 1
    /// Largest axis-aligned rectangle that stays inside the warped quad, as a fraction of the frame.
    /// Constrain Crop keeps this region. A small roll lowers it more than `coverage`.
    var inscribedFraction: Double = 1
    /// Short reason for the validation notes. Not written into a project.
    var note: String = ""
}

/// A vanishing point fit. `point` nil means the lines are parallel (the point is at infinity).
struct CameraRawVanishingModel: Equatable, Sendable {
    var point: CGPoint?
    var orientationDegrees: Double
    var inliers: [CameraRawDetectedLine]
    var residualDegrees: Double
    /// 0…1. How far apart the inliers sit, across the image.
    var spread: Double
    var confidence: Double
}

/// Multi-line upright: edge segments, a robust vanishing-point fit, then guides for `CameraRawPerspective`.
enum CameraRawUprightEstimation {
    /// Long side of the grayscale the line finder reads. 160 merged neighboring walls; 480 keeps them apart
    /// and still finishes well under an interactive preview.
    static let analysisMaxSide = 480
    /// Lines farther than this from the vertical or the horizontal are not structural enough to vote.
    static let familyLimitDegrees = 38.0
    static let inlierLimitDegrees = 2.5
    /// Below this, Auto leaves the picture alone.
    static let minimumConfidence = 0.45

    /// Fit `lines` to one vanishing point. Every pair is tried when there are few lines, so tests are exact.
    static func fit(_ lines: [CameraRawDetectedLine], width: Double, height: Double, axis: Axis,
                    seed: UInt64 = 0xC0FFEE) -> CameraRawVanishingModel? {
        let pool = lines.filter { belongs($0, to: axis) && $0.length > 1 }
        guard pool.count >= 2, width > 0, height > 0 else { return nil }
        var best: CameraRawVanishingModel?
        func consider(_ first: CameraRawDetectedLine, _ second: CameraRawDetectedLine) {
            guard let model = model(first, second, pool: pool, width: width, height: height, axis: axis) else { return }
            if best == nil || model.confidence > best!.confidence { best = model }
        }
        if pool.count <= 40 {
            for index in 0..<pool.count {
                for other in (index + 1)..<pool.count { consider(pool[index], pool[other]) }
            }
        } else {
            var state = seed == 0 ? 1 : seed
            for _ in 0..<120 {
                state = state &* 6364136223846793005 &+ 1
                let index = Int(state % UInt64(pool.count))
                state = state &* 6364136223846793005 &+ 1
                var other = Int(state % UInt64(pool.count - 1))
                if other >= index { other += 1 }
                consider(pool[index], pool[other])
            }
        }
        guard let best, best.confidence >= minimumConfidence else { return nil }
        return best
    }

    enum Axis { case vertical, horizontal }

    // MARK: - Image

    static func observe(in image: CGImage, mode: CameraRawUprightMode, analysisMaxSide: Int = analysisMaxSide) -> CameraRawUprightObservation {
        guard mode.isAuto, image.width > 1, image.height > 1 else {
            return CameraRawUprightObservation(mode: mode, fallback: .identity, note: "not an auto mode")
        }
        let started = CFAbsoluteTimeGetCurrent()
        let field = resample(image, maxSide: analysisMaxSide)
        let segments = segments(in: field)
        let extracted = (CFAbsoluteTimeGetCurrent() - started) * 1000
        let fitStarted = CFAbsoluteTimeGetCurrent()
        let vertical = fit(segments, width: field.width, height: field.height, axis: .vertical)
        let horizontal = fit(segments, width: field.width, height: field.height, axis: .horizontal)
        let fitted = (CFAbsoluteTimeGetCurrent() - fitStarted) * 1000
        var observation = choose(mode: mode, vertical: vertical, horizontal: horizontal, field: field)
        let solveStarted = CFAbsoluteTimeGetCurrent()
        observation = accept(observation, vertical: vertical, horizontal: horizontal, field: field,
                             width: image.width, height: image.height)
        observation.lineExtractionMilliseconds = extracted
        observation.vanishingMilliseconds = fitted
        observation.solveMilliseconds = (CFAbsoluteTimeGetCurrent() - solveStarted) * 1000
        return observation
    }

    // MARK: - Fit

    private static func belongs(_ line: CameraRawDetectedLine, to axis: Axis) -> Bool {
        let folded = abs(CameraRawPerspective.foldedOrientation(line.angleDegrees))
        switch axis {
        case .horizontal: return folded <= familyLimitDegrees
        case .vertical: return folded >= 90 - familyLimitDegrees
        }
    }

    private static func model(_ first: CameraRawDetectedLine, _ second: CameraRawDetectedLine,
                              pool: [CameraRawDetectedLine], width: Double, height: Double,
                              axis: Axis) -> CameraRawVanishingModel? {
        let separation = perpendicularSeparation(first, second)
        let minimum = (axis == .vertical ? width : height) * 0.12
        guard separation >= minimum else { return nil }
        let vanishing = intersect(first, second)
        let orientation = CameraRawPerspective.meanOrientation([first.angleDegrees, second.angleDegrees])
        // Inside the frame the intersection is a crossing, not a usable vanishing point.
        let point: CGPoint?
        if let vanishing {
            let outside = vanishing.x < -width * 0.25 || vanishing.x > width * 1.25
                || vanishing.y < -height * 0.25 || vanishing.y > height * 1.25
            guard outside else { return nil }
            point = vanishing
        } else {
            point = nil
        }
        var inliers = pool.filter { residual($0, point: point, orientation: orientation) <= inlierLimitDegrees }
        guard inliers.count >= 2 else { return nil }
        var refined: CGPoint? = point
        if let solved = leastSquares(inliers) {
            let distance = hypot(solved.x - width / 2, solved.y - height / 2)
            if distance > hypot(width, height) * 0.85 {
                let again = pool.filter { residual($0, point: solved, orientation: orientation) <= inlierLimitDegrees }
                if again.count >= inliers.count {
                    refined = solved
                    inliers = again
                }
            }
        }
        let agreed = CameraRawPerspective.meanOrientation(inliers.map(\.angleDegrees))
        let residualMean = inliers.reduce(0.0) { $0 + residual($1, point: refined, orientation: agreed) } / Double(inliers.count)
        let spread = spreadOf(inliers, axis: axis, width: width, height: height)
        guard spread >= 0.12, residualMean <= inlierLimitDegrees else { return nil }
        // Two clean, separated lines are enough. More inliers and a wider span raise confidence.
        let support = min(1, Double(inliers.count) / 5)
        let tightness = max(0, 1 - residualMean / inlierLimitDegrees)
        let coverage = min(1, spread / 0.35)
        let confidence = min(1, 0.5 * tightness + 0.25 * support + 0.25 * coverage)
        return CameraRawVanishingModel(point: refined, orientationDegrees: agreed, inliers: inliers,
                                       residualDegrees: residualMean, spread: spread, confidence: min(1, confidence))
    }

    private static func residual(_ line: CameraRawDetectedLine, point: CGPoint?, orientation: Double) -> Double {
        guard let point else {
            return undirectedDegrees(line.angleDegrees, orientation)
        }
        let toward = atan2(point.y - line.midY, point.x - line.midX) * 180 / .pi
        return undirectedDegrees(line.angleDegrees, toward)
    }

    static func undirectedDegrees(_ a: Double, _ b: Double) -> Double {
        var delta = abs(a - b).truncatingRemainder(dividingBy: 180)
        if delta > 90 { delta = 180 - delta }
        return delta
    }

    private static func intersect(_ first: CameraRawDetectedLine, _ second: CameraRawDetectedLine) -> CGPoint? {
        let u = first.normal, v = second.normal
        let det = u.a * v.b - v.a * u.b
        let scale = max(1, first.length * second.length)
        guard abs(det) > 1e-6 * scale / max(scale, 1) else { return nil }
        guard abs(det) > 1e-8 else { return nil }
        let x = (u.b * v.c - v.b * u.c) / det
        let y = (v.a * u.c - u.a * v.c) / det
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func leastSquares(_ lines: [CameraRawDetectedLine]) -> CGPoint? {
        var ata00 = 0.0, ata01 = 0.0, ata11 = 0.0, atb0 = 0.0, atb1 = 0.0
        for line in lines {
            let n = line.normal
            ata00 += n.a * n.a
            ata01 += n.a * n.b
            ata11 += n.b * n.b
            atb0 += n.a * -n.c
            atb1 += n.b * -n.c
        }
        let det = ata00 * ata11 - ata01 * ata01
        guard abs(det) > 1e-8 else { return nil }
        let x = (atb0 * ata11 - ata01 * atb1) / det
        let y = (ata00 * atb1 - ata01 * atb0) / det
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func perpendicularSeparation(_ first: CameraRawDetectedLine, _ second: CameraRawDetectedLine) -> Double {
        let n = first.normal
        return abs(n.a * second.midX + n.b * second.midY + n.c)
    }

    private static func spreadOf(_ lines: [CameraRawDetectedLine], axis: Axis, width: Double, height: Double) -> Double {
        let values = lines.map { axis == .vertical ? $0.midX : $0.midY }
        guard let low = values.min(), let high = values.max() else { return 0 }
        let span = axis == .vertical ? width : height
        return span > 0 ? (high - low) / span : 0
    }

    // MARK: - Choose guides

    private struct Field {
        var width: Double
        var height: Double
        var gray: [Double]
    }

    private static func choose(mode: CameraRawUprightMode, vertical: CameraRawVanishingModel?,
                               horizontal: CameraRawVanishingModel?, field: Field) -> CameraRawUprightObservation {
        func guides(_ model: CameraRawVanishingModel, count: Int) -> [CameraRawGeometryGuide] {
            representative(model, count: count).map { guide($0, field: field) }
        }
        func levelGuide() -> [CameraRawGeometryGuide] {
            guard let horizontal else { return [] }
            return levelGuides(horizontal, field: field)
        }
        switch mode {
        case .autoLevel:
            guard let horizontal else {
                return CameraRawUprightObservation(mode: mode, fallback: .identity, note: "no horizon")
            }
            return CameraRawUprightObservation(guides: levelGuide(), mode: mode, confidence: horizontal.confidence,
                                               residualDegrees: horizontal.residualDegrees,
                                               supportingLines: horizontal.inliers.count, fallback: .level,
                                               note: "roll only")
        case .autoVertical:
            guard let vertical else {
                return CameraRawUprightObservation(mode: mode, fallback: .identity, note: "no verticals")
            }
            return CameraRawUprightObservation(guides: guides(vertical, count: 2), mode: mode,
                                               confidence: vertical.confidence, residualDegrees: vertical.residualDegrees,
                                               supportingLines: vertical.inliers.count, fallback: .none,
                                               note: "vertical vanishing point")
        case .autoFull:
            if let vertical, let horizontal {
                let confidence = min(vertical.confidence, horizontal.confidence)
                return CameraRawUprightObservation(guides: guides(vertical, count: 2) + guides(horizontal, count: 2),
                                                   mode: mode, confidence: confidence,
                                                   residualDegrees: max(vertical.residualDegrees, horizontal.residualDegrees),
                                                   supportingLines: vertical.inliers.count + horizontal.inliers.count,
                                                   fallback: .none, note: "both families")
            }
            if let vertical {
                return CameraRawUprightObservation(guides: guides(vertical, count: 2), mode: mode,
                                                   confidence: vertical.confidence, residualDegrees: vertical.residualDegrees,
                                                   supportingLines: vertical.inliers.count, fallback: .vertical,
                                                   note: "full fell back to vertical")
            }
            if let horizontal {
                return CameraRawUprightObservation(guides: levelGuide(), mode: mode, confidence: horizontal.confidence,
                                                   residualDegrees: horizontal.residualDegrees,
                                                   supportingLines: horizontal.inliers.count, fallback: .level,
                                                   note: "full fell back to level")
            }
            return CameraRawUprightObservation(mode: mode, fallback: .identity, note: "no structure")
        case .off, .guided:
            return CameraRawUprightObservation(mode: mode, fallback: .identity)
        }
    }

    /// Keep a solution only when the existing solver puts those guides on their axes.
    /// Auto Level and Auto Vertical are unchanged: one candidate, accepted or refused.
    /// Auto Full ranks the two-family warp against vertical, level, and identity.
    private static func accept(_ observation: CameraRawUprightObservation,
                               vertical: CameraRawVanishingModel?, horizontal: CameraRawVanishingModel?,
                               field: Field, width: Int, height: Int) -> CameraRawUprightObservation {
        if observation.mode == .autoFull {
            return selectFull(vertical: vertical, horizontal: horizontal, field: field, width: width, height: height)
        }
        if let solved = solved(observation, width: width, height: height) {
            return annotate(solved, width: width, height: height)
        }
        return refused(observation, reason: "solver refused")
    }

    /// A two-family homography is kept only when the degrees it adds are worth the frame it spends.
    /// Loss is the worse of empty output corners and source pixels pushed outside the frame.
    /// Gain is how many degrees the simpler candidate still leaves on the other family.
    /// About 16 points of frame for only a few degrees is not worth it. A strong keystone may spend more.
    private static func fullIsWorth(gain: Double, coverageLoss: Double, fullCoverage: Double) -> Bool {
        if fullCoverage < 0.50 { return false }
        let loss = max(0, coverageLoss)
        if loss <= 0.06 { return gain >= 0.75 }
        if loss <= 0.12 { return gain >= 4 }
        if loss <= 0.22 { return gain >= 12 }
        return gain >= 18 && fullCoverage >= 0.55
    }

    private static func selectFull(vertical: CameraRawVanishingModel?, horizontal: CameraRawVanishingModel?,
                                   field: Field, width: Int, height: Int) -> CameraRawUprightObservation {
        func guides(_ model: CameraRawVanishingModel, count: Int) -> [CameraRawGeometryGuide] {
            representative(model, count: count).map { guide($0, field: field) }
        }
        let both = vertical != nil && horizontal != nil
        var full = CameraRawUprightObservation(mode: .autoFull, fallback: .identity, note: "no structure")
        if let vertical, let horizontal {
            full = CameraRawUprightObservation(
                guides: guides(vertical, count: 2) + guides(horizontal, count: 2),
                mode: .autoFull, confidence: min(vertical.confidence, horizontal.confidence),
                residualDegrees: max(vertical.residualDegrees, horizontal.residualDegrees),
                supportingLines: vertical.inliers.count + horizontal.inliers.count,
                fallback: .none, note: "both families")
        }
        var upright = CameraRawUprightObservation(mode: .autoFull, fallback: .identity, note: "no verticals")
        if let vertical {
            upright = CameraRawUprightObservation(
                guides: guides(vertical, count: 2), mode: .autoFull, confidence: vertical.confidence,
                residualDegrees: vertical.residualDegrees, supportingLines: vertical.inliers.count,
                fallback: .vertical, note: "full fell back to vertical")
        }
        var level = CameraRawUprightObservation(mode: .autoFull, fallback: .identity, note: "no horizon")
        if let horizontal {
            level = CameraRawUprightObservation(
                guides: levelGuides(horizontal, field: field), mode: .autoFull, confidence: horizontal.confidence,
                residualDegrees: horizontal.residualDegrees, supportingLines: horizontal.inliers.count,
                fallback: .level, note: "full fell back to level")
        }

        let fullSolved = both ? solved(full, width: width, height: height) : nil
        let verticalSolved = vertical != nil ? solved(upright, width: width, height: height) : nil
        let levelSolved = horizontal != nil ? solved(level, width: width, height: height) : nil

        if let chosen = fullSolved, let fullFit = fit(of: chosen, width: width, height: height) {
            let fullHorizontal = familyMedian(horizontal?.inliers ?? [], axis: .horizontal, homography: fullFit.homography, field: field, width: width, height: height)
            let fullVertical = familyMedian(vertical?.inliers ?? [], axis: .vertical, homography: fullFit.homography, field: field, width: width, height: height)
            var extra = gainAgainstIdentity(fullHorizontal, fullVertical, horizontal: horizontal, vertical: vertical, field: field, width: width, height: height)
            var loss = 1 - fullFit.coverage
            if let simpler = verticalSolved, let simplerFit = fit(of: simpler, width: width, height: height) {
                let crooked = familyMedian(horizontal?.inliers ?? [], axis: .horizontal, homography: simplerFit.homography, field: field, width: width, height: height)
                let simplerVertical = familyMedian(vertical?.inliers ?? [], axis: .vertical, homography: simplerFit.homography, field: field, width: width, height: height)
                extra = crooked - fullHorizontal
                loss = max(simplerFit.coverage - fullFit.coverage, simplerFit.retained - fullFit.retained)
                let damagesVerticals = fullVertical > simplerVertical + 1
                let thin = (horizontal?.inliers.count ?? 0) < 4 && loss > 0.10
                if damagesVerticals || thin || !fullIsWorth(gain: extra, coverageLoss: loss, fullCoverage: fullFit.coverage) {
                    var kept = annotate(simpler, fit: simplerFit)
                    kept.fallback = .vertical
                    kept.note = String(format: "both families; full coverage %.3f vs vertical %.3f, horizontal gain %.2f°, loss %.3f; kept verticals",
                                       fullFit.coverage, simplerFit.coverage, extra, loss)
                    return kept
                }
            }
            var kept = annotate(chosen, fit: fullFit)
            kept.note = String(format: "both families; coverage %.3f, extra %.2f°, loss %.3f", fullFit.coverage, extra, loss)
            return kept
        }
        if let simpler = verticalSolved, let simplerFit = fit(of: simpler, width: width, height: height) {
            return annotate(simpler, fit: simplerFit)
        }
        if let simpler = levelSolved, let simplerFit = fit(of: simpler, width: width, height: height) {
            return annotate(simpler, fit: simplerFit)
        }
        if both || vertical != nil || horizontal != nil {
            let failed = full.guides.isEmpty ? (vertical == nil ? level : upright) : full
            return refused(failed, reason: "solver refused")
        }
        var empty = full
        empty.note = ""
        return refused(empty, reason: "no structure")
    }

    /// Degrees the original still has on both families, minus what the full warp leaves.
    private static func gainAgainstIdentity(_ fullHorizontal: Double, _ fullVertical: Double,
                                            horizontal: CameraRawVanishingModel?, vertical: CameraRawVanishingModel?,
                                            field: Field, width: Int, height: Int) -> Double {
        let crookedH = familyMedian(horizontal?.inliers ?? [], axis: .horizontal, homography: nil, field: field, width: width, height: height)
        let crookedV = familyMedian(vertical?.inliers ?? [], axis: .vertical, homography: nil, field: field, width: width, height: height)
        return max(0, crookedH - fullHorizontal) + max(0, crookedV - fullVertical)
    }

    private struct FrameFit {
        var homography: CameraRawHomography
        var coverage: Double
        var retained: Double
        var inscribed: Double
    }

    private static func fit(of observation: CameraRawUprightObservation, width: Int, height: Int) -> FrameFit? {
        guard let homography = CameraRawPerspective.homography(guides: observation.guides, width: width, height: height) else { return nil }
        let measured = frameFit(homography: homography, width: width, height: height)
        return FrameFit(homography: homography, coverage: measured.coverage, retained: measured.retained, inscribed: measured.inscribed)
    }

    private static func annotate(_ observation: CameraRawUprightObservation, width: Int, height: Int) -> CameraRawUprightObservation {
        guard let measured = fit(of: observation, width: width, height: height) else { return observation }
        return annotate(observation, fit: measured)
    }

    private static func annotate(_ observation: CameraRawUprightObservation, fit: FrameFit) -> CameraRawUprightObservation {
        var result = observation
        result.coverage = fit.coverage
        result.retainedFraction = fit.retained
        result.inscribedFraction = fit.inscribed
        return result
    }

    /// Output fill, source retention, and the inscribed crop, from a 24×24 sample. Not a render.
    private static func frameFit(homography: CameraRawHomography, width: Int, height: Int) -> (coverage: Double, retained: Double, inscribed: Double) {
        let w = Double(width), h = Double(height)
        guard w > 0, h > 0 else { return (1, 1, 1) }
        let corners = CameraRawPerspective.perspectiveCorners(homography: homography, width: width, height: height)
        let steps = 24
        var mask = [Bool](repeating: false, count: steps * steps)
        var filled = 0
        var retained = 0
        for row in 0..<steps {
            for col in 0..<steps {
                let x = (Double(col) + 0.5) / Double(steps) * w
                let y = (Double(row) + 0.5) / Double(steps) * h
                let point = CGPoint(x: x, y: y)
                if pointInQuad(point, corners) {
                    mask[row * steps + col] = true
                    filled += 1
                }
                if let mapped = homography.applyingFinite(point),
                   mapped.x >= 0, mapped.x <= w, mapped.y >= 0, mapped.y <= h {
                    retained += 1
                }
            }
        }
        let cells = Double(steps * steps)
        return (Double(filled) / cells, Double(retained) / cells, inscribedFraction(mask, steps: steps))
    }

    private static func pointInQuad(_ point: CGPoint, _ quad: [CGPoint]) -> Bool {
        guard quad.count == 4 else { return false }
        var sign = 0.0
        for index in 0..<4 {
            let a = quad[index], b = quad[(index + 1) % 4]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if abs(cross) < 1e-6 { continue }
            if sign == 0 { sign = cross } else if cross * sign < 0 { return false }
        }
        return true
    }

    private static func inscribedFraction(_ mask: [Bool], steps: Int) -> Double {
        var best = 0
        for top in 0..<steps {
            var open = [Bool](repeating: true, count: steps)
            for bottom in top..<steps {
                for column in 0..<steps where !mask[bottom * steps + column] { open[column] = false }
                var run = 0
                for column in 0..<steps {
                    if open[column] {
                        run += 1
                        best = max(best, run * (bottom - top + 1))
                    } else {
                        run = 0
                    }
                }
            }
        }
        return Double(best) / Double(steps * steps)
    }

    /// Median absolute degrees between a family's inliers and its axis, after `homography` (nil leaves them).
    private static func familyMedian(_ lines: [CameraRawDetectedLine], axis: Axis, homography: CameraRawHomography?,
                                     field: Field, width: Int, height: Int) -> Double {
        guard !lines.isEmpty, field.width > 0, field.height > 0 else { return 0 }
        let imageW = Double(width), imageH = Double(height)
        let target = axis == .vertical ? 90.0 : 0.0
        var errors: [Double] = []
        errors.reserveCapacity(lines.count)
        for line in lines {
            let start = CGPoint(x: line.x0 / field.width * imageW, y: (1 - line.y0 / field.height) * imageH)
            let end = CGPoint(x: line.x1 / field.width * imageW, y: (1 - line.y1 / field.height) * imageH)
            let p = homography?.applyingFinite(start) ?? start
            let q = homography?.applyingFinite(end) ?? end
            let angle = atan2(q.y - p.y, q.x - p.x) * 180 / .pi
            errors.append(undirectedDegrees(angle, target))
        }
        errors.sort()
        return errors[errors.count / 2]
    }

    private static func solved(_ observation: CameraRawUprightObservation, width: Int, height: Int) -> CameraRawUprightObservation? {
        guard !observation.guides.isEmpty,
              let homo = CameraRawPerspective.homography(guides: observation.guides, width: width, height: height) else { return nil }
        let residual = axisResidual(observation.guides, homography: homo, width: width, height: height)
        guard residual <= 1.25 else { return nil }
        var result = observation
        result.residualDegrees = residual
        return result
    }

    private static func refused(_ observation: CameraRawUprightObservation, reason: String) -> CameraRawUprightObservation {
        var result = observation
        result.guides = []
        result.confidence = 0
        result.supportingLines = 0
        result.fallback = .identity
        result.note = observation.note.isEmpty ? reason : observation.note + "; " + reason
        return result
    }

    private static func axisResidual(_ guides: [CameraRawGeometryGuide], homography: CameraRawHomography,
                                     width: Int, height: Int) -> Double {
        let w = Double(width), h = Double(height)
        var worst = 0.0
        for guide in guides {
            guard let kind = CameraRawPerspective.classify(guide, width: w, height: h) else { continue }
            let ends = CameraRawPerspective.segment(guide, width: w, height: h)
            guard let p = homography.applyingFinite(ends.0), let q = homography.applyingFinite(ends.1) else { return 90 }
            let angle = atan2(q.y - p.y, q.x - p.x) * 180 / .pi
            let target = kind.kind == .vertical ? 90.0 : 0.0
            worst = max(worst, undirectedDegrees(angle, target))
        }
        return worst
    }

    private static func levelGuides(_ horizontal: CameraRawVanishingModel, field: Field) -> [CameraRawGeometryGuide] {
        let angle = horizontal.orientationDegrees
        let radians = angle * .pi / 180
        let cx = field.width / 2, cy = field.height / 2
        // Same pixel length on both axes. Scaling x by width and y by height would flatten the roll.
        let span = min(field.width, field.height) * 0.45
        let dx = cos(radians) * span
        let dy = sin(radians) * span
        let line = CameraRawDetectedLine(x0: cx - dx, y0: cy - dy, x1: cx + dx, y1: cy + dy)
        return [guide(line, field: field)]
    }

    private static func representative(_ model: CameraRawVanishingModel, count: Int) -> [CameraRawDetectedLine] {
        let sorted = model.inliers.sorted { $0.length > $1.length }
        guard let first = sorted.first else { return [] }
        if count == 1 { return [first] }
        guard let second = sorted.dropFirst().max(by: { perpendicularSeparation($0, first) < perpendicularSeparation($1, first) }) else {
            return [first]
        }
        return [first, second]
    }

    /// Bitmap y grows downward. Guides use the lower-left origin the solver already uses.
    private static func guide(_ line: CameraRawDetectedLine, field: Field) -> CameraRawGeometryGuide {
        func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
        return CameraRawGeometryGuide(
            startX: clamp(line.x0 / field.width),
            startY: clamp(1 - line.y0 / field.height),
            endX: clamp(line.x1 / field.width),
            endY: clamp(1 - line.y1 / field.height)
        )
    }

    // MARK: - Segments

    private static func resample(_ image: CGImage, maxSide: Int) -> Field {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(2, Int((Double(image.width) * scale).rounded()))
        let height = max(2, Int((Double(image.height) * scale).rounded()))
        guard let context = try? BrushRaster.context(width: width, height: height, mask: false) else {
            return Field(width: Double(width), height: Double(height), gray: [])
        }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data else { return Field(width: Double(width), height: Double(height), gray: []) }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var gray = [Double](repeating: 0, count: width * height)
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let pixel = y * stride + x * 4
                let alpha = Double(bytes[pixel + 3])
                if alpha <= 0 { continue }
                gray[y * width + x] = (0.2126 * Double(bytes[pixel]) + 0.7152 * Double(bytes[pixel + 1]) + 0.0722 * Double(bytes[pixel + 2])) / alpha * 255
            }
        }
        return Field(width: Double(width), height: Double(height), gray: gray)
    }

    /// Group strong, similarly aimed gradients into straight segments. A blank or noisy field yields none.
    private static func segments(in field: Field) -> [CameraRawDetectedLine] {
        let width = Int(field.width), height = Int(field.height)
        guard width > 2, height > 2, field.gray.count == width * height else { return [] }
        var magnitude = [Double](repeating: 0, count: width * height)
        var angle = [Double](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let gx = -field.gray[index - width - 1] - 2 * field.gray[index - 1] - field.gray[index + width - 1]
                    + field.gray[index - width + 1] + 2 * field.gray[index + 1] + field.gray[index + width + 1]
                let gy = -field.gray[index - width - 1] - 2 * field.gray[index - width] - field.gray[index - width + 1]
                    + field.gray[index + width - 1] + 2 * field.gray[index + width] + field.gray[index + width + 1]
                magnitude[index] = hypot(gx, gy)
                // Tangent of the edge, so a vertical wall has a vertical angle.
                angle[index] = atan2(gx, -gy)
            }
        }
        var strong = [Bool](repeating: false, count: width * height)
        for index in magnitude.indices where magnitude[index] >= 28 { strong[index] = true }
        var visited = [Bool](repeating: false, count: width * height)
        var lines: [CameraRawDetectedLine] = []
        let minimumLength = 0.07 * max(field.width, field.height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let start = y * width + x
                guard strong[start], !visited[start] else { continue }
                var queue = [start]
                var head = 0
                var points: [(Double, Double)] = []
                visited[start] = true
                let seed = angle[start]
                while head < queue.count {
                    let index = queue[head]
                    head += 1
                    let px = index % width, py = index / width
                    points.append((Double(px), Double(py)))
                    if points.count > 4000 { break }
                    for oy in -1...1 {
                        for ox in -1...1 where ox != 0 || oy != 0 {
                            let nx = px + ox, ny = py + oy
                            guard nx > 0, ny > 0, nx < width - 1, ny < height - 1 else { continue }
                            let next = ny * width + nx
                            guard strong[next], !visited[next] else { continue }
                            var delta = abs(angle[next] - seed)
                            if delta > .pi { delta = 2 * .pi - delta }
                            delta = min(delta, .pi - delta)
                            guard delta < 0.22 else { continue }
                            visited[next] = true
                            queue.append(next)
                        }
                    }
                }
                guard points.count >= 18, let line = fitSegment(points), line.length >= minimumLength else { continue }
                lines.append(line)
            }
        }
        return suppressDuplicates(lines, width: field.width, height: field.height).sorted { $0.length > $1.length }.prefix(64).map { $0 }
    }

    private static func fitSegment(_ points: [(Double, Double)]) -> CameraRawDetectedLine? {
        let count = Double(points.count)
        guard count >= 2 else { return nil }
        var meanX = 0.0, meanY = 0.0
        for point in points { meanX += point.0; meanY += point.1 }
        meanX /= count
        meanY /= count
        var xx = 0.0, xy = 0.0, yy = 0.0
        for point in points {
            let dx = point.0 - meanX, dy = point.1 - meanY
            xx += dx * dx
            xy += dx * dy
            yy += dy * dy
        }
        let theta = 0.5 * atan2(2 * xy, xx - yy)
        let dirX = cos(theta), dirY = sin(theta)
        var low = Double.greatestFiniteMagnitude, high = -Double.greatestFiniteMagnitude
        for point in points {
            let projection = (point.0 - meanX) * dirX + (point.1 - meanY) * dirY
            low = min(low, projection)
            high = max(high, projection)
        }
        return CameraRawDetectedLine(x0: meanX + dirX * low, y0: meanY + dirY * low,
                                     x1: meanX + dirX * high, y1: meanY + dirY * high)
    }

    private static func suppressDuplicates(_ lines: [CameraRawDetectedLine], width: Double, height: Double) -> [CameraRawDetectedLine] {
        let ordered = lines.sorted { $0.length > $1.length }
        var kept: [CameraRawDetectedLine] = []
        let near = 0.025 * min(width, height)
        for line in ordered {
            let duplicate = kept.contains { other in
                undirectedDegrees(line.angleDegrees, other.angleDegrees) < 4
                    && perpendicularSeparation(line, other) < near
            }
            if !duplicate { kept.append(line) }
        }
        return kept
    }
}
