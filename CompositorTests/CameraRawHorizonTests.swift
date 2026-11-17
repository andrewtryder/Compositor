import AppKit
import Foundation
import Testing
@testable import Compositor

/// Milestone 10.4: the Horizon interface built on the existing ViewPoint-derived geometry engine, and the regression
/// hardening around it. Nothing here adds a second solver: every test drives `CameraRawHorizonSettings`,
/// `CameraRawHorizon` and `CameraRawGeometryBackend`, which is what the panel calls.
@MainActor
struct CameraRawHorizonTests {
    // MARK: - Helpers

    /// A gradient with a hard diagonal so a rotation is visible in the pixels, not just in the corners.
    private func ruled(width: Int = 96, height: Int = 64) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                let value = UInt8((x * 255) / max(width - 1, 1))
                data[i] = value
                data[i + 1] = UInt8((y * 255) / max(height - 1, 1))
                data[i + 2] = ((x / 6) + (y / 6)) % 2 == 0 ? 240 : 20
                data[i + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    private func solid(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func rgba8(_ image: CGImage) throws -> [UInt8] {
        try MeshWarpRaster.rgba8Bytes(from: image)
    }

    private func maxDelta(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    /// A session with an open Camera Raw panel and a live preview source, as `beginFilter` sets up.
    private func cameraRawSession(width: Int = 96, height: Int = 64) throws -> (EditorSession, FilterEdit) {
        let image = try ruled(width: width, height: height)
        let session = EditorSession()
        session.createDocument(width: width, height: height)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        session.beginFilter(.cameraRaw)
        let edit = try #require(session.filterEdit)
        edit.previewSource = image
        return (session, edit)
    }

    /// A drawn horizon that falls to the right by 4° in a 360×200 frame, in user space (y down).
    private func tiltedHorizonPicture() throws -> CGImage {
        let width = 360, height = 200
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 0.05, alpha: 1))
        context.setLineWidth(6)
        context.setLineCap(.square)
        for offset in [0.0, 50.0] {
            context.move(to: CGPoint(x: 20, y: 118 + offset))
            context.addLine(to: CGPoint(x: 340, y: 78 + offset))
            context.strokePath()
        }
        return try #require(context.makeImage())
    }

    /// The slope, in degrees, that a horizontal reference line ends up with after `degrees` of Horizon.
    private func leveledSlope(of guide: CameraRawGeometryGuide, degrees: Double?, width: Int, height: Int) -> Double {
        let ends = CameraRawPerspective.segment(guide, width: Double(width), height: Double(height))
        let homo = degrees.flatMap {
            CameraRawHorizon.rotationHomography(degrees: $0, width: Double(width), height: Double(height))
        }
        let a = homo?.applying(ends.0) ?? ends.0
        let b = homo?.applying(ends.1) ?? ends.1
        return atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180 / .pi
    }

    // MARK: - Off is a bit-exact identity

    @Test func offIsBitExactIdentity() throws {
        let image = try ruled()
        #expect(try rgba8(try CameraRawSettings().apply(image)) == rgba8(image),
                "default Horizon is Off and leaves every byte alone")
        #expect(CameraRawHorizonSettings().mode == .off)
        #expect(CameraRawHorizonSettings().isIdentity)
        #expect(CameraRawHorizon.rotationDegrees(settings: CameraRawHorizonSettings(), width: 96, height: 64) == nil)
        #expect(CameraRawHorizon.homography(settings: CameraRawHorizonSettings(), width: 96, height: 64) == .identity)

        // Off with a stale angle is still Off, and still exact.
        var stale = CameraRawHorizonSettings()
        stale.angleDegrees = 20
        stale.amount = 100
        stale.referenceStartX = 0.1
        stale.referenceEndX = 0.9
        #expect(try rgba8(try CameraRawSettings().apply(image)) == rgba8(image))
        #expect(stale.isIdentity, "a leftover angle is inert while the mode is Off")
    }

    @Test func backendIdentityApplyReturnsTheSameImage() throws {
        let image = try ruled()
        var settings = CameraRawGeometryBackendSettings()
        settings.horizon.mode = .off
        let result = try CameraRawGeometryBackend.apply(image, settings: settings)
        #expect(try rgba8(result.image) == rgba8(image))
        #expect(result.expansion == nil)
    }

    // MARK: - Angle

    @Test func angleRotationTurnsThePictureClockwiseAboutItsCenter() throws {
        let image = try ruled(width: 120, height: 80)
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .angle
        horizon.angleDegrees = 10
        let degrees = try #require(CameraRawHorizon.rotationDegrees(settings: horizon, width: 120, height: 80))
        #expect(abs(degrees - 10) < 1e-9)

        // The rotation homography matches the manual Rotate control, corner for corner.
        let homo = try #require(CameraRawHorizon.rotationHomography(degrees: 10, width: 120, height: 80))
        var manual = CameraRawGeometrySettings()
        manual.upright = .off
        manual.rotate = 10
        let fromHorizon = CameraRawPerspective.perspectiveCorners(homography: homo, width: 120, height: 80)
        for (a, b) in zip(fromHorizon, manual.outputCorners(width: 120, height: 80)) {
            #expect(hypot(a.x - b.x, a.y - b.y) < 0.05, "Horizon angle agrees with manual Rotate")
        }

        // The center stays put; a horizontal reference through it becomes the angle it was given.
        let center = homo.applying(CGPoint(x: 60, y: 40))
        #expect(hypot(center.x - 60, center.y - 40) < 1e-6, "rotation is about the image center")
        let guide = CameraRawGeometryGuide(startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)
        #expect(abs(leveledSlope(of: guide, degrees: degrees, width: 120, height: 80) - 10) < 0.05)

        // And the pixels really move.
        var settings = CameraRawSettings()
        settings.horizon = horizon
        settings.geometry.framingMode = .keepOriginalSize
        #expect(maxDelta(try rgba8(settings.apply(image)), try rgba8(image)) > 8)
    }

    @Test func angleIsWrappedAndOutOfRangeValuesAreClamped() {
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .angle
        horizon.angleDegrees = 400
        #expect(horizon.normalized.angleDegrees == 45, "the model clamps to ±45")
        horizon.angleDegrees = -400
        #expect(horizon.normalized.angleDegrees == -45)
        horizon.angleDegrees = .nan
        #expect(horizon.normalized.angleDegrees == 0, "a non-finite angle falls back instead of propagating")
        horizon.angleDegrees = .infinity
        #expect(horizon.normalized.angleDegrees == 0)
        #expect(CameraRawHorizon.wrap(350) == -10)
        #expect(CameraRawHorizon.wrap(-350) == 10)
        #expect(CameraRawHorizon.wrap(90) == 45)
        #expect(CameraRawHorizon.wrap(12.5) == 12.5)
    }

    @Test func angleZeroIsIdentity() {
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .angle
        horizon.angleDegrees = 0
        #expect(CameraRawHorizon.rotationDegrees(settings: horizon, width: 100, height: 100) == nil)
    }

    // MARK: - Automatic

    @Test func automaticLevelsThePicturesOwnHorizon() throws {
        let width = 360, height = 200
        let image = try tiltedHorizonPicture()
        let observation = CameraRawUprightDetection.observe(in: image, mode: .autoLevel)
        let guide = try #require(observation.guides.first)
        #expect(guide.endY > guide.startY, "the drawn horizon rises to the right in lower-left coordinates")

        let angle = try #require(CameraRawHorizon.automaticAngle(from: observation, width: width, height: height))
        #expect(abs(angle) > 1, "the tilt was measured")
        #expect(abs(leveledSlope(of: guide, degrees: angle, width: width, height: height)) < 0.5,
                "Automatic asks for the rotation that levels the guide")

        // Measured in pixels: the picture is 360×200, so normalized and pixel slopes differ. 4° of user-space tilt is
        // about 7.1° of pixel tilt here, and the answer describes the picture, not the normalized square.
        let pixels = CameraRawPerspective.segment(guide, width: Double(width), height: Double(height))
        let drawn = atan2(Double(pixels.1.y - pixels.0.y), Double(pixels.1.x - pixels.0.x)) * 180 / .pi
        #expect(abs(angle + drawn) < 0.5, "the sign levels the drawn line rather than doubling its tilt")

        // The angle reaches the pipeline through .automatic, unchanged.
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .automatic
        #expect(CameraRawHorizon.rotationDegrees(settings: horizon, width: width, height: height,
                                                 automaticAngle: angle) == angle)
    }

    @Test func automaticWithoutAMeasurementIsIdentity() {
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .automatic
        #expect(CameraRawHorizon.rotationDegrees(settings: horizon, width: 100, height: 100) == nil,
                "no observation yet means no rotation, not a guess")
        #expect(CameraRawHorizon.rotationDegrees(settings: horizon, width: 100, height: 100,
                                                 automaticAngle: .nan) == nil)
        #expect(CameraRawHorizon.rotationDegrees(settings: horizon, width: 100, height: 100,
                                                 automaticAngle: Double.infinity) == nil)
    }

    @Test func automaticFromAnEmptyObservationDoesNotInventARotation() {
        let empty = CameraRawUprightObservation()
        #expect(CameraRawHorizon.automaticAngle(from: empty, width: 100, height: 100) == nil)
        // A magnitude with no direction to turn is not a rotation either.
        var residual = CameraRawUprightObservation()
        residual.residualDegrees = 3.5
        #expect(CameraRawHorizon.automaticAngle(from: residual, width: 100, height: 100) == nil)
    }

    // MARK: - Reference lines

    @Test func horizontalReferenceLevelsTheDrawnLine() throws {
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .horizontalReference
        horizon.referenceStartX = 0.1
        horizon.referenceStartY = 0.4
        horizon.referenceEndX = 0.9
        horizon.referenceEndY = 0.5
        let degrees = try #require(CameraRawHorizon.rotationDegrees(settings: horizon, width: 200, height: 100))
        let guide = CameraRawGeometryGuide(startX: 0.1, startY: 0.4, endX: 0.9, endY: 0.5)
        #expect(abs(leveledSlope(of: guide, degrees: degrees, width: 200, height: 100)) < 0.5,
                "the reference line comes out level")
    }

    @Test func verticalReferenceStandsTheDrawnLineUpright() throws {
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .verticalReference
        horizon.referenceStartX = 0.3
        horizon.referenceStartY = 0.1
        horizon.referenceEndX = 0.4
        horizon.referenceEndY = 0.9
        let degrees = try #require(CameraRawHorizon.rotationDegrees(settings: horizon, width: 200, height: 120))
        let guide = CameraRawGeometryGuide(startX: 0.3, startY: 0.1, endX: 0.4, endY: 0.9)
        // A vertical reference asked for a turned line: the result must be vertical, ±90° folded.
        let slope = leveledSlope(of: guide, degrees: degrees, width: 200, height: 120)
        var deviation = abs(slope)
        if deviation > 90 { deviation = 180 - deviation }
        deviation = abs(deviation - 90)
        #expect(deviation < 0.5, "the drawn line comes out vertical: \(slope)")
    }

    @Test func endpointOrderDoesNotChangeTheCorrection() throws {
        for mode in [CameraRawHorizonMode.horizontalReference, .verticalReference] {
            var forward = CameraRawHorizonSettings()
            forward.mode = mode
            forward.referenceStartX = 0.12
            forward.referenceStartY = 0.33
            forward.referenceEndX = 0.88
            forward.referenceEndY = 0.47

            var reversed = forward
            swap(&reversed.referenceStartX, &reversed.referenceEndX)
            swap(&reversed.referenceStartY, &reversed.referenceEndY)

            let a = try #require(CameraRawHorizon.rotationDegrees(settings: forward, width: 180, height: 120))
            let b = try #require(CameraRawHorizon.rotationDegrees(settings: reversed, width: 180, height: 120))
            #expect(abs(a - b) < 1e-6, "\(mode.rawValue) ignores which end was drawn first")

            // The homographies agree too, so a preview and an apply cannot drift on endpoint order.
            let ha = try #require(CameraRawHorizon.homography(settings: forward, width: 180, height: 120))
            let hb = try #require(CameraRawHorizon.homography(settings: reversed, width: 180, height: 120))
            let probe = CGPoint(x: 137, y: 61)
            #expect(hypot(ha.applying(probe).x - hb.applying(probe).x,
                          ha.applying(probe).y - hb.applying(probe).y) < 1e-6)
        }
    }

    @Test func aReferenceTooShortToReadIsRefused() {
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .horizontalReference
        horizon.referenceStartX = 0.5
        horizon.referenceStartY = 0.5
        horizon.referenceEndX = 0.5
        horizon.referenceEndY = 0.5
        #expect(CameraRawHorizon.rotationDegrees(settings: horizon, width: 100, height: 100) == nil,
                "a zero-length line asks for no rotation")
        #expect(CameraRawHorizon.referenceAngle(settings: horizon, width: 0, height: 0, vertical: false) == nil)
        #expect(CameraRawHorizon.referenceAngle(settings: horizon, width: 100, height: 100, vertical: false) == nil)
    }

    @Test func referencePointsAreClampedIntoTheImage() {
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .horizontalReference
        horizon.referenceStartX = -4
        horizon.referenceStartY = 9
        horizon.referenceEndX = 4
        horizon.referenceEndY = -9
        let normalized = horizon.normalized
        #expect(normalized.referenceStartX == 0 && normalized.referenceStartY == 1)
        #expect(normalized.referenceEndX == 1 && normalized.referenceEndY == 0)
    }

    // MARK: - Amount

    @Test(arguments: [0.0, 25.0, 50.0, 100.0])
    func amountBlendsTheCorrection(_ amount: Double) throws {
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .angle
        horizon.angleDegrees = 12
        horizon.amount = amount
        let degrees = CameraRawHorizon.rotationDegrees(settings: horizon, width: 100, height: 100)
        if amount == 0 {
            #expect(degrees == nil, "0% is exactly identity, not a very small rotation")
        } else {
            let expected = 12 * amount / 100
            #expect(abs(try #require(degrees) - expected) < 1e-9)
        }
    }

    @Test func amountZeroLeavesThePixelsExactlyAlone() throws {
        let image = try ruled()
        var settings = CameraRawSettings()
        settings.horizon.mode = .angle
        settings.horizon.angleDegrees = 30
        settings.horizon.amount = 0
        #expect(settings.horizon.isIdentity)
        #expect(try rgba8(settings.apply(image)) == rgba8(image))
    }

    @Test func amountOneHundredMatchesTheFullCorrection() throws {
        let image = try ruled()
        var full = CameraRawSettings()
        full.horizon.mode = .angle
        full.horizon.angleDegrees = 9
        full.horizon.amount = 100
        full.geometry.framingMode = .keepOriginalSize
        var explicit = full
        explicit.horizon.amount = 100
        #expect(try rgba8(full.apply(image)) == rgba8(explicit.apply(image)))
        #expect(maxDelta(try rgba8(full.apply(image)), try rgba8(image)) > 8,
                "100% is the whole rotation, and it moves pixels")
    }

    @Test func outOfRangeAmountIsClampedNotRejected() {
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .angle
        horizon.angleDegrees = 10
        horizon.amount = 900
        #expect(horizon.normalized.amount == 100)
        horizon.amount = -900
        #expect(horizon.normalized.amount == 0)
        horizon.amount = .nan
        #expect(horizon.normalized.amount == 100, "a broken amount falls back to the full correction")
    }

    // MARK: - No double rotation with Upright

    @Test func automaticHorizonDoesNotRunAlongsideAutoLevelsGuides() {
        var settings = CameraRawGeometryBackendSettings()
        settings.geometry.upright = .autoLevel
        settings.geometry.guides = [CameraRawGeometryGuide(startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.45)]
        settings.horizon.mode = .automatic
        #expect(!CameraRawGeometryBackend.shouldApplyHorizon(settings),
                "Auto Level already rolled the picture; a second roll would tilt it back")
        #expect(CameraRawGeometryBackend.horizonDegrees(settings: settings, width: 100, height: 100,
                                                        automaticAngle: 4) == nil)
    }

    @Test func automaticHorizonSubstitutesWhenAutoLevelFoundNoLine() {
        var settings = CameraRawGeometryBackendSettings()
        settings.geometry.upright = .autoLevel
        settings.geometry.guides = []
        settings.horizon.mode = .automatic
        #expect(CameraRawGeometryBackend.shouldApplyHorizon(settings),
                "with nothing to level with, Automatic is the Level the picture never got")
    }

    @Test(arguments: [CameraRawUprightMode.guided, .autoVertical, .autoFull])
    func explicitHorizonRunsOverASolvingUpright(_ mode: CameraRawUprightMode) {
        var settings = CameraRawGeometryBackendSettings()
        settings.geometry.upright = mode
        settings.geometry.guides = [CameraRawGeometryGuide(startX: 0.2, startY: 0.1, endX: 0.25, endY: 0.9)]
        settings.horizon.mode = .angle
        settings.horizon.angleDegrees = 5
        #expect(CameraRawGeometryBackend.shouldApplyHorizon(settings),
                "an explicit Angle is the person asking for a rotation on top")
        settings.horizon.mode = .automatic
        #expect(!CameraRawGeometryBackend.shouldApplyHorizon(settings),
                "Automatic would measure a roll these solvers do not deliberately add")
    }

    @Test func axisAlignedLeveledPictureIsNotRolledTwice() throws {
        // A picture whose horizon is already level: Auto Level has nothing to roll with, so it hands back no guide.
        let width = 360, height = 200
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 0.05, alpha: 1))
        context.setLineWidth(6)
        for y in [80.0, 140.0] {
            context.move(to: CGPoint(x: 20, y: y))
            context.addLine(to: CGPoint(x: 340, y: y))
            context.strokePath()
        }
        let image = try #require(context.makeImage())
        let observation = CameraRawUprightDetection.observe(in: image, mode: .autoLevel)
        var geometry = CameraRawGeometrySettings()
        geometry.upright = .autoLevel
        geometry.guides = observation.guides
        let corners = geometry.outputCorners(width: width, height: height)
        #expect(abs(corners[1].y - corners[0].y) < 0.5, "Auto Level leaves a level horizon level")

        // With no guide there was nothing for Auto Level to level, so Automatic is allowed to stand in — and must
        // still ask for nothing, because the observation has no direction to read.
        var backend = CameraRawGeometryBackendSettings(geometry: geometry)
        backend.horizon.mode = .automatic
        let automatic = CameraRawHorizon.automaticAngle(from: observation, width: width, height: height)
        #expect(automatic == nil || abs(automatic ?? 0) < 0.5,
                "an already-level picture has no rotation left to ask for")
        #expect(CameraRawGeometryBackend.horizonDegrees(settings: backend, width: width, height: height,
                                                        automaticAngle: automatic) == nil,
                "so nothing is rolled, twice or at all")
    }

    // MARK: - Rejecting degenerate and non-finite input

    @Test func nonFiniteInputIsRejectedNotRendered() {
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .angle
        horizon.angleDegrees = .nan
        #expect(CameraRawHorizon.rotationDegrees(settings: horizon, width: 100, height: 100) == nil)
        horizon.angleDegrees = .infinity
        #expect(CameraRawHorizon.rotationDegrees(settings: horizon, width: 100, height: 100) == nil)
        #expect(CameraRawHorizon.rotationHomography(degrees: .nan, width: 100, height: 100) == nil)
        #expect(CameraRawHorizon.rotationHomography(degrees: 10, width: 0, height: 100) == nil)
        #expect(CameraRawHorizon.rotationHomography(degrees: 10, width: 100, height: -2) == nil)
        #expect(CameraRawHorizon.rotationDegrees(settings: horizon, width: 0, height: 0) == nil)
    }

    @Test func nanReferenceFallsBackToTheDefaultLine() {
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .horizontalReference
        horizon.referenceStartX = .nan
        horizon.referenceStartY = .nan
        horizon.referenceEndX = .nan
        horizon.referenceEndY = .nan
        // Clamping a non-finite value yields the range's fallback, so the line ends up readable rather than poisoned.
        let normalized = horizon.normalized
        #expect(normalized.referenceStartX.isFinite && normalized.referenceEndX.isFinite)
        #expect(normalized.referenceStartY.isFinite && normalized.referenceEndY.isFinite)
        #expect(horizon.isIdentity == false)
    }

    @Test func degenerateRotationIsRefusedRatherThanInvented() {
        // A 180° rotation about the center maps the frame onto itself with a negative determinant; the safety gate
        // refuses it, and the wrap keeps the model inside ±45° anyway.
        #expect(CameraRawHorizon.rotationHomography(degrees: 180, width: 100, height: 80) != nil,
                "the raw rotation is well formed")
        var horizon = CameraRawHorizonSettings()
        horizon.mode = .angle
        horizon.angleDegrees = 180
        #expect(horizon.normalized.angleDegrees == 45, "the model never asks for a fold-over")
    }

    // MARK: - Existing geometry surviving a Horizon change

    @Test func horizonChangesLeaveEveryOtherGeometrySettingAlone() throws {
        var settings = CameraRawSettings()
        settings.geometry.upright = .guided
        settings.geometry.guides = [CameraRawGeometryGuide(startX: 0.2, startY: 0.1, endX: 0.24, endY: 0.9)]
        settings.geometry.vertical = 12
        settings.geometry.horizontal = -7
        settings.geometry.rotate = 3
        settings.geometry.aspect = 8
        settings.geometry.scale = 15
        settings.geometry.offsetX = -4
        settings.geometry.offsetY = 6
        settings.geometry.perspectiveAmount = 78
        settings.geometry.framingMode = .expandToFit
        settings.geometry.constrainCrop = true
        settings.geometry.volumeMode = .horizontalAndVertical
        settings.geometry.volumeHorizontal = 30
        settings.geometry.volumeVertical = 22
        settings.geometry.volumeRadial = 11
        settings.geometry.focalLengthMm = 28
        settings.geometry.sensorWidthMm = 36
        settings.geometry.projection = .rectilinear
        let before = settings.geometry

        settings.horizon.mode = .angle
        settings.horizon.angleDegrees = 6
        settings.horizon.amount = 80
        #expect(settings.geometry == before, "Horizon is a separate model and cannot rewrite Geometry")

        settings.horizon = CameraRawHorizonSettings()
        #expect(settings.geometry == before, "and clearing Horizon leaves it alone too")
    }

    @Test func geometryResetClearsHorizonWithTheRestOfTheSection() {
        var settings = CameraRawSettings()
        settings.geometry.vertical = 20
        settings.geometry.focalLengthMm = 24
        settings.geometry.sensorWidthMm = 36
        settings.horizon.mode = .angle
        settings.horizon.angleDegrees = 8
        settings.automaticHorizonAngle = 4
        let reset = settings.resetting(.geometry)
        #expect(reset.horizon == CameraRawHorizonSettings(), "Reset Geometry puts Horizon back to Off")
        #expect(reset.automaticHorizonAngle == nil)
        #expect(reset.geometry.focalLengthMm == 24 && reset.geometry.sensorWidthMm == 36,
                "the EXIF focal length stays, as before this milestone")
        #expect(reset.geometry.vertical == 0)
    }

    @Test func geometryEyeTurnedOffDropsHorizon() {
        var settings = CameraRawSettings()
        settings.horizon.mode = .angle
        settings.horizon.angleDegrees = 5
        settings.geometry.vertical = 10
        let hidden = settings.applying(showsLight: true, showsColor: true, showsGeometry: false)
        #expect(hidden.horizon == CameraRawHorizonSettings())
        #expect(hidden.geometry == CameraRawGeometrySettings())
    }

    // MARK: - Preview versus committed output

    @Test func previewAndCommittedOutputUseTheSameHorizon() async throws {
        let (session, edit) = try cameraRawSession(width: 240, height: 160)
        var settings = edit.settings
        settings.cameraRaw.horizon.mode = .angle
        settings.cameraRaw.horizon.angleDegrees = 7
        settings.cameraRaw.geometry.framingMode = .keepOriginalSize
        session.updateFilter(settings, preview: true)
        while let task = edit.previewTask { await task.value }
        let shown = try #require(edit.preparedPreview)

        let reference = try settings.cameraRaw.apply(edit.previewSource)
        #expect(shown.width == reference.width && shown.height == reference.height,
                "the preview shows the rotated frame, not the original")
        #expect(maxDelta(try rgba8(shown), try rgba8(reference)) <= 1,
                "the preview and the full apply agree on Horizon")
        #expect(maxDelta(try rgba8(shown), try rgba8(edit.previewSource)) > 8,
                "and the preview is not the untouched source")
    }

    // MARK: - Apply, Cancel, Undo and Redo

    @Test func applyBakesHorizonAndCancelLeavesTheLayer() async throws {
        let image = try ruled(width: 40, height: 32)
        let session = EditorSession()
        session.createDocument(width: 40, height: 32)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        let original = try rgba8(try #require(session.activeLayer?.asset?.image))

        // Cancel: the door out that changes nothing.
        session.beginFilter(.cameraRaw)
        var settings = try #require(session.filterEdit).settings
        settings.cameraRaw.horizon.mode = .angle
        settings.cameraRaw.horizon.angleDegrees = 11
        session.updateFilter(settings, preview: true)
        session.cancelFilter()
        #expect(session.filterEdit == nil)
        #expect(try rgba8(try #require(session.activeLayer?.asset?.image)) == original)

        // Apply: one undo entry, and the pixels move.
        session.beginFilter(.cameraRaw)
        settings = try #require(session.filterEdit).settings
        settings.cameraRaw.horizon.mode = .angle
        settings.cameraRaw.horizon.angleDegrees = 11
        settings.cameraRaw.geometry.framingMode = .keepOriginalSize
        session.updateFilter(settings, preview: true)
        let count = session.history.undoCount
        await session.commitFilter()
        #expect(session.history.undoCount == count + 1)
        let baked = try rgba8(try #require(session.activeLayer?.asset?.image))
        #expect(maxDelta(baked, original) > 8, "OK bakes the rotation")

        session.undo()
        #expect(try rgba8(try #require(session.activeLayer?.asset?.image)) == original, "Undo puts the layer back")
        session.redo()
        #expect(try rgba8(try #require(session.activeLayer?.asset?.image)) == baked, "Redo bakes it again")
    }

    @Test func aHorizonOnlyChangeIsStillAnEdit() async throws {
        // The one number that matters for OK: `adjustsGeometry` has to notice Horizon, or OK would close as a no-op.
        var settings = CameraRawSettings()
        #expect(!settings.adjustsGeometry)
        settings.horizon.mode = .angle
        settings.horizon.angleDegrees = 4
        #expect(settings.adjustsGeometry)
        #expect(!settings.isIdentity)
        settings.horizon.amount = 0
        #expect(!settings.adjustsGeometry, "0% is identity, so OK has nothing to bake")
    }

    // MARK: - Persistence and legacy decoding

    @Test func horizonRoundTripsThroughPersistence() throws {
        var settings = CameraRawSettings()
        settings.horizon.mode = .verticalReference
        settings.horizon.angleDegrees = -12.5
        settings.horizon.amount = 63
        settings.horizon.referenceStartX = 0.22
        settings.horizon.referenceStartY = 0.11
        settings.horizon.referenceEndX = 0.31
        settings.horizon.referenceEndY = 0.88

        let data = try JSONEncoder().encode(CameraRawSettingsPersistentState(settings))
        let decoded = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: data)
        let restored = try decoded.makeSettings()
        #expect(restored.horizon.mode == .verticalReference)
        #expect(abs(restored.horizon.angleDegrees + 12.5) < 1e-9)
        #expect(restored.horizon.amount == 63)
        #expect(abs(restored.horizon.referenceStartX - 0.22) < 1e-9)
        #expect(abs(restored.horizon.referenceEndY - 0.88) < 1e-9)
        // The measurement is deliberately not persisted: reopening re-measures nothing behind the person's back.
        #expect(restored.automaticHorizonAngle == nil)
    }

    @Test func aProjectWrittenBeforeHorizonStillLoads() throws {
        // Older projects have no `horizon` key at all.
        let json = Data("""
        {"schemaVersion":1,"exposure":0.4,
         "geometry":{"upright":"Off","vertical":12,"perspectiveAmount":80,"framingMode":"Keep Original Size"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: json)
        let settings = try decoded.makeSettings()
        #expect(settings.exposure == 0.4)
        #expect(settings.geometry.vertical == 12)
        #expect(settings.horizon == CameraRawHorizonSettings(), "missing Horizon decodes as Off, not as a correction")
        #expect(settings.horizon.isIdentity)
    }

    @Test func corruptHorizonValuesAreRejectedByTheReader() throws {
        var persistent = CameraRawSettingsPersistentState()
        persistent.horizon.angleDegrees = .nan
        #expect(throws: CameraRawSettingsPersistentState.DecodeError.self) {
            _ = try persistent.makeSettings()
        }
    }

    @Test func horizonSurvivesAFullCorrectionStackNode() throws {
        let image = try ruled(width: 48, height: 40)
        var settings = CameraRawSettings()
        settings.horizon.mode = .angle
        settings.horizon.angleDegrees = 8
        settings.geometry.framingMode = .keepOriginalSize
        var stack = LayerCorrectionStack(
            source: ImportedImage(image: image, thumbnail: image, name: "L"),
            nodes: [.cameraRawFull(settings)])
        let rendered = try LayerCorrectionRenderer.render(&stack)
        #expect(maxDelta(try rgba8(rendered.image), try rgba8(image)) > 8)

        let persistent = try LayerCorrectionStackPersistentState(stack: stack)
        let source = ImportedImage(image: image, thumbnail: image, name: "L")
        let restored = try persistent.makeStack(source: source)
        let node = try #require(restored.nodes.first)
        #expect(node.cameraRawFull.horizon.mode == .angle)
        #expect(abs(node.cameraRawFull.horizon.angleDegrees - 8) < 1e-9)
    }

    @Test func saveAndReopenKeepsHorizonAndRendersTheSamePixels() async throws {
        let image = try ruled(width: 60, height: 44)
        let session = EditorSession()
        session.createDocument(width: 60, height: 44)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        try session.addCorrection(kind: .cameraRawFull, cameraRawFull: {
            var settings = CameraRawSettings()
            settings.horizon.mode = .horizontalReference
            settings.horizon.referenceStartX = 0.1
            settings.horizon.referenceStartY = 0.45
            settings.horizon.referenceEndX = 0.9
            settings.horizon.referenceEndY = 0.55
            settings.horizon.amount = 75
            settings.geometry.framingMode = .keepOriginalSize
            return settings
        }())

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Horizon-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let restored = EditorSession()
        restored.installProject(loaded, from: url)

        let node = try #require(restored.activeLayer?.correctionStack?.nodes.first)
        #expect(node.cameraRawFull.horizon.mode == .horizontalReference)
        #expect(node.cameraRawFull.horizon.amount == 75)
        #expect(abs(node.cameraRawFull.horizon.referenceEndY - 0.55) < 1e-9)

        let before = try rgba8(try #require(session.activeLayer?.asset?.image))
        let after = try rgba8(try #require(restored.activeLayer?.asset?.image))
        #expect(before == after, "a reopened project renders the same Horizon")
    }

    // MARK: - The reference-line drawing interaction

    @Test func drawingAReferenceLineCommitsIntoTheSettings() throws {
        let (session, edit) = try cameraRawSession(width: 200, height: 100)
        var settings = edit.settings
        settings.cameraRaw.horizon.mode = .horizontalReference
        session.updateFilter(settings, preview: true)

        session.beginCameraRawHorizonReferenceDrawing()
        #expect(edit.drawingCameraRawHorizonReference)
        #expect(edit.cameraRawHorizonDrawingMode == .horizontalReference)
        #expect(!edit.drawingCameraRawGeometryGuide, "Guided Upright cannot own the same drag")

        // The drag arrives in document points, through the same preview mapping Guided Upright uses.
        let image = edit.previewSource
        let start = CGPoint(x: 0.2 * CGFloat(image.width), y: 0.4 * CGFloat(image.height)).applying(edit.previewMapping)
        let end = CGPoint(x: 0.8 * CGFloat(image.width), y: 0.6 * CGFloat(image.height)).applying(edit.previewMapping)
        session.beginCameraRawHorizonReference(at: start)
        session.continueCameraRawHorizonReference(to: end)
        session.commitCameraRawHorizonReference()

        let line = try #require(session.cameraRawHorizonReferenceLine)
        #expect(abs(line.startX - 0.2) < 0.01)
        #expect(abs(line.startY - 0.4) < 0.01)
        #expect(abs(line.endX - 0.8) < 0.01)
        #expect(abs(line.endY - 0.6) < 0.01)
        #expect(edit.cameraRawHorizonReferenceDraft == nil, "the draft is consumed by the commit")
        let degrees = try #require(CameraRawHorizon.rotationDegrees(
            settings: edit.settings.cameraRaw.horizon, width: image.width, height: image.height))
        #expect(abs(degrees) > 1, "the committed line asks for a real correction")
    }

    @Test func aStrayClickDoesNotCommitAReferenceLine() throws {
        let (session, edit) = try cameraRawSession(width: 120, height: 80)
        var settings = edit.settings
        settings.cameraRaw.horizon.mode = .horizontalReference
        settings.cameraRaw.horizon.referenceStartX = 0.25
        settings.cameraRaw.horizon.referenceEndX = 0.75
        session.updateFilter(settings, preview: true)
        let before = edit.settings.cameraRaw.horizon

        session.beginCameraRawHorizonReferenceDrawing()
        let point = CGPoint(x: 0.5 * CGFloat(edit.previewSource.width),
                            y: 0.5 * CGFloat(edit.previewSource.height)).applying(edit.previewMapping)
        session.beginCameraRawHorizonReference(at: point)
        session.commitCameraRawHorizonReference()
        #expect(edit.settings.cameraRaw.horizon == before, "a click with no drag is not a reference")
        #expect(edit.cameraRawHorizonReferenceDraft == nil)
    }

    @Test func referenceDrawingIsRefusedInModesThatDoNotUseALine() throws {
        let (session, edit) = try cameraRawSession()
        var settings = edit.settings
        settings.cameraRaw.horizon.mode = .angle
        session.updateFilter(settings, preview: true)
        session.beginCameraRawHorizonReferenceDrawing()
        #expect(!edit.drawingCameraRawHorizonReference, "Angle has no reference line to draw")
    }

    @Test func clearingTheReferenceRestoresTheDefaultLine() throws {
        let (session, edit) = try cameraRawSession()
        var settings = edit.settings
        settings.cameraRaw.horizon.mode = .horizontalReference
        settings.cameraRaw.horizon.referenceStartX = 0.3
        settings.cameraRaw.horizon.referenceStartY = 0.7
        settings.cameraRaw.horizon.referenceEndX = 0.4
        settings.cameraRaw.horizon.referenceEndY = 0.8
        session.updateFilter(settings, preview: true)

        session.clearCameraRawHorizonReference()
        let line = try #require(session.cameraRawHorizonReferenceLine)
        #expect(line.startX == 0 && line.startY == 0)
        #expect(line.endX == 1 && line.endY == 0)
        #expect(edit.settings.cameraRaw.horizon.mode == .horizontalReference, "the mode is the person's choice, not the line's")
    }

    @Test func endingDrawingDropsTheDraftWithoutCommitting() throws {
        let (session, edit) = try cameraRawSession(width: 120, height: 80)
        var settings = edit.settings
        settings.cameraRaw.horizon.mode = .verticalReference
        session.updateFilter(settings, preview: true)
        let before = edit.settings.cameraRaw.horizon

        session.beginCameraRawHorizonReferenceDrawing()
        let start = CGPoint(x: 0.3 * CGFloat(edit.previewSource.width),
                            y: 0.3 * CGFloat(edit.previewSource.height)).applying(edit.previewMapping)
        session.beginCameraRawHorizonReference(at: start)
        #expect(edit.cameraRawHorizonReferenceDraft != nil)
        session.endCameraRawHorizonReferenceDrawing()
        #expect(edit.cameraRawHorizonReferenceDraft == nil)
        #expect(!edit.drawingCameraRawHorizonReference)
        #expect(edit.settings.cameraRaw.horizon == before)
    }

    @Test func geometryResetStopsReferenceDrawing() throws {
        let (session, edit) = try cameraRawSession()
        var settings = edit.settings
        settings.cameraRaw.horizon.mode = .horizontalReference
        session.updateFilter(settings, preview: true)
        session.beginCameraRawHorizonReferenceDrawing()
        #expect(edit.drawingCameraRawHorizonReference)
        session.resetCameraRaw(.geometry)
        #expect(!edit.drawingCameraRawHorizonReference)
        #expect(edit.cameraRawHorizonReferenceDraft == nil)
        #expect(edit.cameraRawHorizonDrawingMode == nil)
    }

    // MARK: - The panel's structure this milestone had to keep

    @Test func cameraRawSectionOrderIsUnchanged() {
        #expect(CameraRawGroup.panelOrder.map(\.rawValue) ==
                ["Light", "Color", "Color Grading", "Effects", "Curve", "Color Mixer", "Detail", "Optics",
                 "Geometry", "Calibration"])
        #expect(Set(CameraRawGroup.panelOrder) == Set(CameraRawGroup.allCases),
                "the declared order names every section exactly once")
        // The reset groups keep their own order; this is what the panel iterates.
        #expect(CameraRawGroup.allCases.map(\.rawValue) ==
                ["Light", "Color", "Effects", "Curve", "Color Mixer", "Color Grading", "Detail", "Optics",
                 "Geometry", "Calibration"])
    }

    @Test func theAdditiveSectionsOfMilestoneTenAreStillPresent() {
        // Auto Tone (10.1) lives in Light and is measured from the picture's tones, not a fixed curve.
        var light = CameraRawSettings()
        #expect(!light.adjustsLight)
        light.exposure = 0.5
        #expect(light.adjustsLight)

        // Lens Blur (10.2) is part of Optics and stays an optical stage after geometry.
        #expect(CameraRawSettings().optics.lensBlur.isIdentity)
        var blur = CameraRawSettings()
        blur.optics.lensBlur.amount = 50
        #expect(blur.adjustsOptics)
        #expect(blur.optics.lensBlur.amount == 50)

        // Lens Profile (10.3) is still the optional provider switch, unchanged by this milestone.
        #expect(CameraRawSettings().optics.lensProfile.provider == .appleNative)
        #expect(CameraRawLensProfileProvider.allCases.contains(.lensfun))
        #expect(CameraRawLensProfileProvider.allCases.contains(.off))
    }

    @Test func horizonIsNotPartOfTheOpticsOrCalibrationGroups() {
        var settings = CameraRawSettings()
        settings.horizon.mode = .angle
        settings.horizon.angleDegrees = 5
        // Only Geometry carries Horizon, so resetting any other section leaves it standing.
        for group in CameraRawGroup.allCases where group != .geometry {
            let reset = settings.resetting(group)
            #expect(reset.horizon.mode == .angle, "Reset \(group) must not clear Horizon")
        }
        #expect(settings.resetting(.geometry).horizon.mode == .off)
    }

    @Test func geometryOperationsRunInTheDocumentedOrder() {
        #expect(CameraRawGeometryBackend.compositionOrder ==
                ["lensDistortion", "anamorphicDeSqueeze", "volume", "perspective", "horizon",
                 "framingCrop", "cropAfterTransform", "miniature", "colorGrade"])
    }

    // MARK: - The composed pipeline

    @Test func horizonIsComposedIntoFramingBeforeTheCrop() throws {
        let image = try solid(width: 100, height: 80)
        var geometry = CameraRawGeometrySettings()
        geometry.upright = .off
        geometry.vertical = 30
        geometry.framingMode = .expandToFit
        let without = try geometry.applyResult(image)
        let with = try geometry.applyResult(image, horizonDegrees: 12)
        let changed = without.image.width != with.image.width || without.image.height != with.image.height
            || without.expansion?.coverageInInput != with.expansion?.coverageInInput
        #expect(changed, "Expand to Fit measures the rotated frame, not the keystoned one")
    }

    @Test func horizonRunsBeforeTheColorGrade() throws {
        // A rotation moves pixels; a grade recolors them. Both together must be the rotation then the grade, which is
        // what the pixels say when the rotation is the only spatial stage.
        let image = try ruled(width: 64, height: 48)
        var settings = CameraRawSettings()
        settings.horizon.mode = .angle
        settings.horizon.angleDegrees = 6
        settings.geometry.framingMode = .keepOriginalSize
        settings.exposure = 0.3
        let combined = try settings.apply(image)

        var spatial = settings
        spatial.exposure = 0
        let rotated = try spatial.apply(image)
        var grade = CameraRawSettings()
        grade.exposure = 0.3
        let graded = try grade.apply(rotated)
        #expect(maxDelta(try rgba8(combined), try rgba8(graded)) <= 1,
                "the documented order is rotation, then grade")
    }
}
