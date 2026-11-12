import AppKit
import Testing
@testable import Compositor

@MainActor
struct CameraRawUprightTests {
    private func picture(_ width: Int, _ height: Int, strokes: [(CGPoint, CGPoint)], noise: Bool = false) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noise {
            var state: UInt64 = 0x1234
            for y in 0..<height {
                for x in 0..<width {
                    state = state &* 6364136223846793005 &+ 1
                    let gray = 0.82 + Double(state % 40) / 200
                    context.setFillColor(CGColor(gray: gray, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        context.setStrokeColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        context.setLineWidth(6)
        context.setLineCap(.square)
        for stroke in strokes {
            context.move(to: stroke.0)
            context.addLine(to: stroke.1)
            context.strokePath()
        }
        return try #require(context.makeImage())
    }

    /// User-space y grows downward. The solver's y grows upward.
    private func upright(_ point: CGPoint, height: Int) -> CGPoint {
        CGPoint(x: point.x, y: CGFloat(height) - point.y)
    }

    private func correctedAngle(_ start: CGPoint, _ end: CGPoint, guides: [CameraRawGeometryGuide], width: Int, height: Int) -> Double {
        let homo = CameraRawPerspective.homography(guides: guides, width: width, height: height)
        let a = homo?.applyingFinite(upright(start, height: height)) ?? upright(start, height: height)
        let b = homo?.applyingFinite(upright(end, height: height)) ?? upright(end, height: height)
        return atan2(b.y - a.y, b.x - a.x) * 180 / .pi
    }

    private func axisError(_ angle: Double, vertical: Bool) -> Double {
        CameraRawUprightEstimation.undirectedDegrees(angle, vertical ? 90 : 0)
    }

    /// A line through `anchor` and the vanishing point, clipped to a y span (user space, y downward).
    private func through(vp: CGPoint, anchor: CGPoint, y0: CGFloat, y1: CGFloat) -> (CGPoint, CGPoint) {
        let slope = (anchor.x - vp.x) / (anchor.y - vp.y)
        func at(_ y: CGFloat) -> CGPoint { CGPoint(x: vp.x + (y - vp.y) * slope, y: y) }
        return (at(y0), at(y1))
    }

    private func throughX(vp: CGPoint, anchor: CGPoint, x0: CGFloat, x1: CGFloat) -> (CGPoint, CGPoint) {
        let slope = (anchor.y - vp.y) / (anchor.x - vp.x)
        func at(_ x: CGFloat) -> CGPoint { CGPoint(x: x, y: vp.y + (x - vp.x) * slope) }
        return (at(x0), at(x1))
    }

    @Test func vanishingFitIgnoresOutliersAndReversedEnds() throws {
        let width = 360.0, height = 240.0
        let vp = CGPoint(x: 180, y: -420)
        func line(_ anchorX: Double) -> CameraRawDetectedLine {
            let ends = through(vp: vp, anchor: CGPoint(x: anchorX, y: 200), y0: 20, y1: 220)
            return CameraRawDetectedLine(x0: ends.0.x, y0: ends.0.y, x1: ends.1.x, y1: ends.1.y)
        }
        var lines = [line(80), line(180), line(280)]
        lines.append(CameraRawDetectedLine(x0: 10, y0: 10, x1: 200, y1: 40))
        lines.append(CameraRawDetectedLine(x0: 30, y0: 200, x1: 300, y1: 80))
        let fit = CameraRawUprightEstimation.fit(lines, width: width, height: height, axis: .vertical, seed: 7)
        let model = try #require(fit)
        #expect(model.inliers.count >= 3)
        #expect(model.residualDegrees < 1)
        #expect(model.confidence >= CameraRawUprightEstimation.minimumConfidence)
        guard let point = model.point else {
            Issue.record("expected a finite vertical vanishing point")
            return
        }
        #expect(abs(point.x - vp.x) < 8)
        #expect(abs(point.y - vp.y) < 30)

        let reversed = lines.map { CameraRawDetectedLine(x0: $0.x1, y0: $0.y1, x1: $0.x0, y1: $0.y0) }
        let again = try #require(CameraRawUprightEstimation.fit(reversed, width: width, height: height, axis: .vertical, seed: 7))
        #expect(abs((again.point?.x ?? 0) - point.x) < 8)
        #expect(abs((again.point?.y ?? 0) - point.y) < 30)
    }

    @Test func nearlyParallelLinesStayARoll() throws {
        let lines = [
            CameraRawDetectedLine(x0: 80, y0: 10, x1: 92, y1: 230),
            CameraRawDetectedLine(x0: 250, y0: 10, x1: 262, y1: 230)
        ]
        let model = try #require(CameraRawUprightEstimation.fit(lines, width: 360, height: 240, axis: .vertical))
        #expect(model.point == nil)
        #expect(model.residualDegrees < 1)
    }

    @Test func autoVerticalStraightensConvergingWalls() throws {
        let width = 360, height = 240
        let vp = CGPoint(x: 180, y: -360)
        let left = through(vp: vp, anchor: CGPoint(x: 90, y: 200), y0: 16, y1: 224)
        let right = through(vp: vp, anchor: CGPoint(x: 270, y: 200), y0: 16, y1: 224)
        let image = try picture(width, height, strokes: [left, right])
        let observation = CameraRawUprightDetection.observe(in: image, mode: .autoVertical)
        #expect(observation.fallback != .identity)
        #expect(observation.confidence >= CameraRawUprightEstimation.minimumConfidence)
        #expect(axisError(correctedAngle(left.0, left.1, guides: observation.guides, width: width, height: height), vertical: true) < 1)
        #expect(axisError(correctedAngle(right.0, right.1, guides: observation.guides, width: width, height: height), vertical: true) < 1)
    }

    @Test func autoLevelRollsWithoutKeystone() throws {
        let width = 360, height = 200
        let horizon = (CGPoint(x: 20, y: 118), CGPoint(x: 340, y: 78))
        let second = (CGPoint(x: 20, y: 168), CGPoint(x: 340, y: 128))
        let image = try picture(width, height, strokes: [horizon, second])
        let observation = CameraRawUprightDetection.observe(in: image, mode: .autoLevel)
        #expect(observation.guides.count == 1)
        #expect(observation.fallback == .level)
        #expect(axisError(correctedAngle(horizon.0, horizon.1, guides: observation.guides, width: width, height: height), vertical: false) < 1)
        let before = CameraRawPerspective.homography(guides: observation.guides, width: width, height: height)
        // A roll turns image-vertical lines, but the two sides stay parallel.
        let leftTop = before?.applyingFinite(CGPoint(x: 40, y: 180))
        let leftBottom = before?.applyingFinite(CGPoint(x: 40, y: 20))
        let rightTop = before?.applyingFinite(CGPoint(x: 320, y: 180))
        let rightBottom = before?.applyingFinite(CGPoint(x: 320, y: 20))
        if let leftTop, let leftBottom, let rightTop, let rightBottom {
            let left = atan2(leftTop.y - leftBottom.y, leftTop.x - leftBottom.x) * 180 / .pi
            let right = atan2(rightTop.y - rightBottom.y, rightTop.x - rightBottom.x) * 180 / .pi
            #expect(CameraRawUprightEstimation.undirectedDegrees(left, right) < 0.5)
        }
    }

    @Test func autoFullUsesBothFamiliesAndFallsBack() throws {
        let width = 400, height = 260
        let verticalVP = CGPoint(x: 200, y: -420)
        let horizontalVP = CGPoint(x: 1100, y: 140)
        let left = through(vp: verticalVP, anchor: CGPoint(x: 80, y: 200), y0: 24, y1: 236)
        let right = through(vp: verticalVP, anchor: CGPoint(x: 320, y: 200), y0: 24, y1: 236)
        let top = throughX(vp: horizontalVP, anchor: CGPoint(x: 200, y: 50), x0: 30, x1: 370)
        let bottom = throughX(vp: horizontalVP, anchor: CGPoint(x: 200, y: 210), x0: 20, x1: 380)
        let image = try picture(width, height, strokes: [left, right, top, bottom])
        let full = CameraRawUprightDetection.observe(in: image, mode: .autoFull)
        #expect(full.fallback == .none)
        #expect(full.residualDegrees < 1)
        #expect(axisError(correctedAngle(left.0, left.1, guides: full.guides, width: width, height: height), vertical: true) < 1)
        #expect(axisError(correctedAngle(top.0, top.1, guides: full.guides, width: width, height: height), vertical: false) < 1)

        let walls = try picture(width, height, strokes: [left, right])
        let verticalOnly = CameraRawUprightDetection.observe(in: walls, mode: .autoFull)
        #expect(verticalOnly.fallback == .vertical)
        #expect(axisError(correctedAngle(left.0, left.1, guides: verticalOnly.guides, width: width, height: height), vertical: true) < 1)

        let blank = try picture(80, 60, strokes: [])
        let none = CameraRawUprightDetection.observe(in: blank, mode: .autoFull)
        #expect(none.guides.isEmpty)
        #expect(none.fallback == .identity)
    }

    @Test func noiseAndDiagonalsDoNotInventAWarp() throws {
        let width = 320, height = 200
        let image = try picture(width, height, strokes: [
            (CGPoint(x: 20, y: 30), CGPoint(x: 140, y: 150)),
            (CGPoint(x: 200, y: 20), CGPoint(x: 300, y: 170)),
            (CGPoint(x: 40, y: 170), CGPoint(x: 180, y: 40))
        ], noise: true)
        let observation = CameraRawUprightDetection.observe(in: image, mode: .autoFull)
        #expect(observation.fallback == .identity || observation.residualDegrees < 1.25)
        if observation.fallback == .identity {
            #expect(observation.guides.isEmpty)
        }
    }

    @Test func nonSquareFrameStillClassifiesInPixels() throws {
        let width = 420, height = 160
        let vp = CGPoint(x: 210, y: -240)
        let left = through(vp: vp, anchor: CGPoint(x: 80, y: 120), y0: 12, y1: 148)
        let right = through(vp: vp, anchor: CGPoint(x: 340, y: 120), y0: 12, y1: 148)
        let image = try picture(width, height, strokes: [left, right])
        let observation = CameraRawUprightDetection.observe(in: image, mode: .autoVertical)
        #expect(axisError(correctedAngle(left.0, left.1, guides: observation.guides, width: width, height: height), vertical: true) < 1)
    }

    @Test func staleDetectionIsNotApplied() {
        #expect(CameraRawUprightDetection.shouldApply(mode: .autoVertical, current: .autoVertical, version: 3, currentVersion: 3, committing: false))
        #expect(!CameraRawUprightDetection.shouldApply(mode: .autoVertical, current: .autoLevel, version: 3, currentVersion: 3, committing: false))
        #expect(!CameraRawUprightDetection.shouldApply(mode: .autoVertical, current: .guided, version: 3, currentVersion: 3, committing: false))
        #expect(!CameraRawUprightDetection.shouldApply(mode: .autoFull, current: .autoFull, version: 3, currentVersion: 4, committing: false))
        #expect(!CameraRawUprightDetection.shouldApply(mode: .autoFull, current: .autoFull, version: 3, currentVersion: 3, committing: true))
        #expect(!CameraRawUprightDetection.shouldApply(mode: .guided, current: .guided, version: 1, currentVersion: 1, committing: false))
    }

    /// Times the detector after the picture has already been drawn. Rendering cost is not included.
    @Test func autoDetectionPerformanceBaseline() throws {
        let width = 1024, height = 768
        let vp = CGPoint(x: 512, y: -900)
        let left = through(vp: vp, anchor: CGPoint(x: 220, y: 600), y0: 40, y1: 720)
        let right = through(vp: vp, anchor: CGPoint(x: 800, y: 600), y0: 40, y1: 720)
        let image = try picture(width, height, strokes: [left, right])
        let coarse = CameraRawUprightDetection.observe(in: image, mode: .autoVertical, analysisMaxSide: 160)
        let fine = CameraRawUprightDetection.observe(in: image, mode: .autoVertical, analysisMaxSide: 480)
        #expect(fine.lineExtractionMilliseconds > 0)
        #expect(fine.vanishingMilliseconds >= 0)
        #expect(coarse.fallback == .identity || coarse.residualDegrees < 2)
        #expect(axisError(correctedAngle(left.0, left.1, guides: fine.guides, width: width, height: height), vertical: true) < 1)
        #expect(fine.lineExtractionMilliseconds + fine.vanishingMilliseconds + fine.solveMilliseconds > 0)
        #expect(coarse.lineExtractionMilliseconds + coarse.vanishingMilliseconds >= 0)
        // Ranking the candidates is a grid over the homography, not another line extraction.
        #expect(fine.solveMilliseconds < fine.lineExtractionMilliseconds)
    }

    @Test func autoFullKeepsAStrongRectangleAndFallsBackWhenItDoesNotPay() throws {
        let width = 400, height = 260
        let verticalVP = CGPoint(x: 200, y: -180)
        let horizontalVP = CGPoint(x: 720, y: 140)
        let left = through(vp: verticalVP, anchor: CGPoint(x: 60, y: 200), y0: 16, y1: 244)
        let midLeft = through(vp: verticalVP, anchor: CGPoint(x: 140, y: 200), y0: 16, y1: 244)
        let midRight = through(vp: verticalVP, anchor: CGPoint(x: 260, y: 200), y0: 16, y1: 244)
        let right = through(vp: verticalVP, anchor: CGPoint(x: 340, y: 200), y0: 16, y1: 244)
        let top = throughX(vp: horizontalVP, anchor: CGPoint(x: 200, y: 36), x0: 20, x1: 380)
        let upper = throughX(vp: horizontalVP, anchor: CGPoint(x: 200, y: 90), x0: 20, x1: 380)
        let lower = throughX(vp: horizontalVP, anchor: CGPoint(x: 200, y: 170), x0: 16, x1: 384)
        let bottom = throughX(vp: horizontalVP, anchor: CGPoint(x: 200, y: 220), x0: 16, x1: 384)
        let strong = try picture(width, height, strokes: [left, midLeft, midRight, right, top, upper, lower, bottom])
        let full = CameraRawUprightDetection.observe(in: strong, mode: .autoFull)
        #expect(full.fallback == .none, Comment(rawValue: full.note))
        #expect(full.coverage > 0.50)
        #expect(full.coverage < 0.98)
        #expect(axisError(correctedAngle(left.0, left.1, guides: full.guides, width: width, height: height), vertical: true) < 1.25)
        #expect(axisError(correctedAngle(top.0, top.1, guides: full.guides, width: width, height: height), vertical: false) < 1.25)

        let walls = try picture(width, height, strokes: [left, right])
        let verticalOnly = CameraRawUprightDetection.observe(in: walls, mode: .autoFull)
        #expect(verticalOnly.fallback == .vertical)

        let horizon = (CGPoint(x: 16, y: 150), CGPoint(x: 384, y: 108))
        let horizon2 = (CGPoint(x: 16, y: 210), CGPoint(x: 384, y: 168))
        let levelOnly = try picture(width, height, strokes: [horizon, horizon2])
        let leveled = CameraRawUprightDetection.observe(in: levelOnly, mode: .autoFull)
        #expect(leveled.fallback == .level)
        #expect(leveled.guides.count == 1)

        // A mild wall, plus two lines that cross inside the frame. That is not a horizon.
        let far = CGPoint(x: 200, y: -420)
        let farLeft = through(vp: far, anchor: CGPoint(x: 80, y: 200), y0: 24, y1: 236)
        let farRight = through(vp: far, anchor: CGPoint(x: 320, y: 200), y0: 24, y1: 236)
        let up = (CGPoint(x: 30, y: 40), CGPoint(x: 370, y: 200))
        let down = (CGPoint(x: 30, y: 210), CGPoint(x: 370, y: 50))
        let conflict = try picture(width, height, strokes: [farLeft, farRight, up, down])
        let refused = CameraRawUprightDetection.observe(in: conflict, mode: .autoFull)
        #expect(refused.fallback == .vertical || refused.fallback == .identity)
        #expect(refused.coverage > 0.85)

        // Four lines in two opposing slopes, like a vault. They are inside the horizontal
        // family gate and can define a rectangle. That rectangle must not spend much more of
        // the frame than the vertical correction. The existing loss schedule already decides this.
        let riseA = (CGPoint(x: 16, y: 28), CGPoint(x: 384, y: 96))
        let riseB = (CGPoint(x: 16, y: 78), CGPoint(x: 384, y: 146))
        let fallA = (CGPoint(x: 16, y: 132), CGPoint(x: 384, y: 64))
        let fallB = (CGPoint(x: 16, y: 196), CGPoint(x: 384, y: 128))
        let vault = try picture(width, height, strokes: [farLeft, farRight, riseA, riseB, fallA, fallB])
        let misled = CameraRawUprightDetection.observe(in: vault, mode: .autoFull)
        let vaultVertical = CameraRawUprightDetection.observe(in: vault, mode: .autoVertical)
        #expect(misled.coverage > 0.85, Comment(rawValue: misled.note))
        #expect(vaultVertical.coverage - misled.coverage < 0.06, Comment(rawValue: misled.note))
    }
}
