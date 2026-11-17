import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Perspective Amount (homography blend) and framing bounds. Auto candidate ranking is intentionally untouched.
struct CameraRawPerspectiveIntensityFramingTests {
    private func checker(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        for y in 0..<height {
            for x in 0..<width {
                let on = ((x / 4) + (y / 4)) % 2 == 0
                context.setFillColor(red: on ? 0.9 : 0.1, green: on ? 0.9 : 0.1, blue: on ? 0.85 : 0.15, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return try #require(context.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> [[UInt8]] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var rows: [[UInt8]] = []
        for y in 0..<image.height {
            var row: [UInt8] = []
            row.reserveCapacity(image.width * 4)
            let base = y * context.bytesPerRow
            for x in 0..<image.width {
                let i = base + x * 4
                row.append(contentsOf: [bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]])
            }
            rows.append(row)
        }
        return rows
    }

    private var convergingGuides: [CameraRawGeometryGuide] {
        [
            CameraRawGeometryGuide(startX: 0.30, startY: 0.05, endX: 0.20, endY: 0.95),
            CameraRawGeometryGuide(startX: 0.70, startY: 0.05, endX: 0.85, endY: 0.95)
        ]
    }

    private func guidedSettings(amount: Double = 100) -> CameraRawGeometrySettings {
        var settings = CameraRawGeometrySettings()
        settings.upright = .guided
        settings.guides = convergingGuides
        settings.perspectiveAmount = amount
        return settings
    }

    // MARK: - Intensity

    @Test func perspectiveAmountZeroIsIdentity() {
        let full = guidedSettings(amount: 100).outputCorners(width: 120, height: 160)
        let zero = guidedSettings(amount: 0).outputCorners(width: 120, height: 160)
        let identity = CameraRawPerspective.identityCorners(width: 120, height: 160)
        #expect(zip(zero, identity).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.05 })
        #expect(zip(full, identity).contains { hypot($0.x - $1.x, $0.y - $1.y) > 0.5 })
    }

    @Test func perspectiveAmountHundredMatchesExistingPath() {
        var legacy = CameraRawGeometrySettings()
        legacy.upright = .guided
        legacy.guides = convergingGuides
        // Explicit 100 vs the previous default path (also 100).
        let atHundred = guidedSettings(amount: 100).outputCorners(width: 100, height: 100)
        let baseline = legacy.outputCorners(width: 100, height: 100)
        #expect(zip(atHundred, baseline).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1e-6 })
    }

    @Test func intermediateAmountsStayBetweenIdentityAndFull() {
        let identity = CameraRawPerspective.identityCorners(width: 100, height: 100)
        let full = guidedSettings(amount: 100).outputCorners(width: 100, height: 100)
        for amount in [25.0, 50.0, 75.0] {
            let mid = guidedSettings(amount: amount).outputCorners(width: 100, height: 100)
            for i in 0..<4 {
                let fullDelta = hypot(full[i].x - identity[i].x, full[i].y - identity[i].y)
                let midDelta = hypot(mid[i].x - identity[i].x, mid[i].y - identity[i].y)
                #expect(mid[i].x.isFinite && mid[i].y.isFinite)
                #expect(midDelta <= fullDelta + 1e-6)
                if fullDelta > 1 {
                    #expect(midDelta > 0.05, "amount \(amount) should move corner \(i)")
                }
            }
        }
    }

    @Test func blendIsInvariantToHomographyScale() throws {
        let homo = try #require(CameraRawPerspective.homography(guides: convergingGuides, width: 80, height: 120))
        let scaled = CameraRawHomography(m: (
            homo.m.0 * 3.7, homo.m.1 * 3.7, homo.m.2 * 3.7,
            homo.m.3 * 3.7, homo.m.4 * 3.7, homo.m.5 * 3.7,
            homo.m.6 * 3.7, homo.m.7 * 3.7, homo.m.8 * 3.7
        ))
        let a = try #require(homo.blendedTowardIdentity(amount: 0.4, width: 80, height: 120))
        let b = try #require(scaled.blendedTowardIdentity(amount: 0.4, width: 80, height: 120))
        let cornersA = CameraRawPerspective.perspectiveCorners(homography: a, width: 80, height: 120)
        let cornersB = CameraRawPerspective.perspectiveCorners(homography: b, width: 80, height: 120)
        #expect(zip(cornersA, cornersB).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1e-6 })
    }

    @Test func degenerateHomographyBlendIsRejected() {
        let bad = CameraRawHomography(m: (0, 0, 0, 0, 0, 0, 0, 0, 0))
        #expect(bad.blendedTowardIdentity(amount: 0.5, width: 100, height: 100) == nil)
        let extreme = CameraRawHomography(m: (1, 0, 10_000, 0, 1, 10_000, 0.5, 0.5, 0.01))
        #expect(extreme.blendedTowardIdentity(amount: 1, width: 50, height: 50) == nil)
    }

    @Test func manualKeystoneRespectsAmount() {
        var settings = CameraRawGeometrySettings()
        settings.vertical = 40
        settings.perspectiveAmount = 0
        let identity = CameraRawPerspective.identityCorners(width: 100, height: 100)
        #expect(zip(settings.outputCorners(width: 100, height: 100), identity).allSatisfy {
            hypot($0.x - $1.x, $0.y - $1.y) < 0.05
        })
        settings.perspectiveAmount = 100
        #expect(zip(settings.outputCorners(width: 100, height: 100), identity).contains {
            hypot($0.x - $1.x, $0.y - $1.y) > 0.5
        })
    }

    @Test func amountLeavesVolumeAspectScaleOffsetIndependent() throws {
        let grid = try checker(32, 32)
        var volumeOnly = CameraRawGeometrySettings()
        volumeOnly.volumeMode = .radial
        volumeOnly.volumeRadial = 80
        volumeOnly.perspectiveAmount = 0
        let withAmount = volumeOnly
        volumeOnly.perspectiveAmount = 100
        // No perspective active: amount must not change volume-only output.
        #expect(try pixels(volumeOnly.apply(grid)) == pixels(withAmount.apply(grid)))

        var polish = CameraRawGeometrySettings()
        polish.scale = 20
        polish.perspectiveAmount = 0
        let polishZero = polish.outputCorners(width: 100, height: 100)
        polish.perspectiveAmount = 100
        let polishFull = polish.outputCorners(width: 100, height: 100)
        #expect(zip(polishZero, polishFull).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1e-6 })
    }

    @Test func renderedZeroAmountLeavesPixelsUnchanged() throws {
        let grid = try checker(24, 24)
        var settings = guidedSettings(amount: 0)
        #expect(try pixels(settings.apply(grid)) == pixels(grid))
        settings.perspectiveAmount = 100
        #expect(try pixels(settings.apply(grid)) != pixels(grid))
    }

    // MARK: - Framing

    @Test func expandedFrameIdentityPreservesSize() throws {
        let corners = CameraRawPerspective.identityCorners(width: 200, height: 100)
        let frame = try #require(CameraRawPerspective.expandedFrame(corners: corners))
        #expect(frame.size.width == 200)
        #expect(frame.size.height == 100)
        #expect(abs(frame.translation.dx) < 1e-9)
        #expect(abs(frame.translation.dy) < 1e-9)
    }

    @Test func expandedFrameForRotatedRectangle() throws {
        // 90° rotation around center of 100×60 → same size after translation.
        let w = 100.0, h = 60.0
        let c = CGPoint(x: w / 2, y: h / 2)
        let source = CameraRawPerspective.identityCorners(width: w, height: h)
        let rotated = source.map { point -> CGPoint in
            let dx = point.x - c.x, dy = point.y - c.y
            return CGPoint(x: c.x - dy, y: c.y + dx)
        }
        let frame = try #require(CameraRawPerspective.expandedFrame(corners: rotated))
        #expect(frame.size.width == 60)
        #expect(frame.size.height == 100)
        let translated = CameraRawPerspective.translatedCorners(rotated, by: frame.translation)
        #expect(translated.map(\.x).min()! >= -1e-6)
        #expect(translated.map(\.y).min()! >= -1e-6)
    }

    @Test func expandToFitProducesLargerFiniteImage() throws {
        let grid = try checker(40, 60)
        var settings = guidedSettings(amount: 100)
        settings.framingMode = .expandToFit
        let expanded = try settings.apply(grid)
        #expect(expanded.width >= grid.width || expanded.height >= grid.height)
        #expect(expanded.width <= DocumentLimits.maxSide)
        #expect(expanded.height <= DocumentLimits.maxSide)
        // Keep Original Size stays on the input footprint.
        settings.framingMode = .keepOriginalSize
        let kept = try settings.apply(grid)
        #expect(kept.width == grid.width && kept.height == grid.height)
    }

    @Test func expandRejectsNonFiniteAndHugeBounds() {
        #expect(CameraRawPerspective.expandedFrame(corners: [CGPoint(x: Double.nan, y: 0)]) == nil)
        let huge = [
            CGPoint(x: -1e7, y: -1e7), CGPoint(x: 1e7, y: -1e7),
            CGPoint(x: 1e7, y: 1e7), CGPoint(x: -1e7, y: 1e7)
        ]
        #expect(CameraRawPerspective.expandedFrame(corners: huge) == nil)
    }

    @Test func constrainCropStaysIndependentOfFraming() throws {
        let grid = try checker(48, 48)
        var settings = CameraRawGeometrySettings()
        settings.rotate = 20
        settings.constrainCrop = true
        settings.framingMode = .keepOriginalSize
        let cropped = try settings.apply(grid)
        #expect(cropped.width == grid.width && cropped.height == grid.height)
        // Zero perspective amount with only rotate still crops into the original frame.
        settings.perspectiveAmount = 0
        // Rotate is perspective; amount 0 yields identity, so constrain crop should be a no-op.
        let identityCrop = try settings.apply(grid)
        #expect(try pixels(identityCrop) == pixels(grid))
    }

    // MARK: - Serialization

    @Test func decodingOmitsAmountAndFramingDefaultsToFullStrength() throws {
        let legacy = """
        {"upright":"Off","projection":"Perspective","vertical":12,"horizontal":0,"rotate":0,\
        "aspect":0,"scale":0,"offsetX":0,"offsetY":0,"constrainCrop":false,"guides":[],\
        "volumeHorizontal":0,"volumeVertical":0,"volumeRadial":0,"volumeMode":"Radial",\
        "focalLengthMm":0,"sensorWidthMm":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CameraRawGeometrySettings.self, from: legacy)
        #expect(decoded.perspectiveAmount == 100)
        #expect(decoded.framingMode == .keepOriginalSize)
        #expect(decoded.vertical == 12)

        var modern = CameraRawGeometrySettings()
        modern.perspectiveAmount = 35
        modern.framingMode = .expandToFit
        modern.vertical = 8
        let data = try JSONEncoder().encode(modern)
        let roundTrip = try JSONDecoder().decode(CameraRawGeometrySettings.self, from: data)
        #expect(roundTrip.perspectiveAmount == 35)
        #expect(roundTrip.framingMode == .expandToFit)
        #expect(roundTrip.vertical == 8)
    }

    // MARK: - Modes still compose with amount

    @Test func autoAndGuidedModesAcceptAmount() {
        for mode in [CameraRawUprightMode.autoLevel, .autoVertical, .autoFull, .guided] {
            var settings = CameraRawGeometrySettings()
            settings.upright = mode
            settings.guides = convergingGuides
            settings.perspectiveAmount = 50
            let corners = settings.outputCorners(width: 90, height: 120)
            #expect(corners.count == 4)
            #expect(corners.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        }
    }
}
