import AppKit
import Foundation
import Testing
@testable import Compositor

/// Milestone 10.8: the Miniature / Tilt-Shift engine as now exposed in Geometry.
///
/// The renderer is the long-standing `CameraRawMiniature` (`CIMaskedVariableBlur` behind a linear
/// or circular focus mask), unchanged. What is new is only the panel reaching it, so these tests
/// pin the behavior a user now drives: identity at zero, the focus geometry, the interactions the
/// Move Focus mode performs, and the persistence the panel writes.
@MainActor
struct CameraRawMiniatureTests {
    // MARK: - Helpers

    /// A flat field with sharp impulses, so a blur has something measurable to soften.
    private func impulseImage(width: Int = 96, height: Int = 64) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // One impulse in the middle, one in a corner: the pair tells sharp from blurred.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: width / 2 - 2, y: height / 2 - 2, width: 4, height: 4))
        context.fill(CGRect(x: 4, y: 4, width: 3, height: 3))
        return try #require(context.makeImage())
    }

    private func luma(_ image: CGImage, _ x: Int, _ y: Int) throws -> Double {
        let copy = try BrushRaster.copy(image)
        let pixels = try #require(copy.data).assumingMemoryBound(to: UInt8.self)
        let i = y * copy.bytesPerRow + x * 4
        return (Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / 3
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.copy(image)
        let pointer = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: context.bytesPerRow * image.height))
    }

    private func session(layerSize: CGSize = CGSize(width: 200, height: 150)) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: Int(layerSize.width), height: Int(layerSize.height), mask: false)
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.45, blue: 0.6, alpha: 1))
        context.fill(CGRect(origin: .zero, size: layerSize))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        session.beginFilter(.cameraRaw)
        return session
    }

    // MARK: - Identity and ranges

    @Test func defaultSettingsAreIdentityAndLeavePixelsAlone() throws {
        let image = try impulseImage()
        let sourcePixels = try pixels(image)
        #expect(CameraRawMiniatureSettings().isIdentity)
        let out = try CameraRawMiniature.apply(image, settings: CameraRawMiniatureSettings())
        #expect(try pixels(out) == sourcePixels, "Amount 0 is the exact input")
    }

    @Test func strengthChangesBlurAndAmountsRoundTripThroughNormalization() throws {
        let image = try impulseImage()
        var settings = CameraRawMiniatureSettings()
        settings.strength = 20
        let light = try CameraRawMiniature.apply(image, settings: settings)
        settings.strength = 100
        let strong = try CameraRawMiniature.apply(image, settings: settings)
        let cornerDrop: (CGImage) throws -> Double = { [self] in
            try abs(luma(image, 5, 5) - luma($0, 5, 5))
        }
        #expect(try cornerDrop(strong) > cornerDrop(light), "a higher Amount blurs more")

        settings.strength = 500
        settings.falloff = -20
        settings.centerX = 3
        settings.centerY = -1
        settings.focusSize = 9
        let normalized = settings.normalized
        #expect(normalized.strength == 100)
        #expect(normalized.falloff == 0)
        #expect(normalized.centerX == 1 && normalized.centerY == 0)
        #expect(normalized.focusSize == CameraRawMiniatureSettings.sizeRange.upperBound)
    }

    @Test func nonFiniteInputsFallBackToUsableValues() throws {
        var settings = CameraRawMiniatureSettings()
        settings.strength = .infinity
        settings.angleDegrees = .nan
        settings.centerX = .nan
        let safe = settings.normalized
        #expect(safe.strength == 0, "a non-finite Amount falls back to the identity default")
        #expect(safe.angleDegrees == 0)
        #expect(safe.centerX == 0, "a non-finite center clamps inside the frame")
        let out = try CameraRawMiniature.apply(try impulseImage(), settings: settings)
        #expect(out.width == 96 && out.height == 64)
    }

    // MARK: - Focus geometry

    @Test func linearFocusBandKeepsItsInsideSharpAndBlursOutside() throws {
        let image = try impulseImage()
        var settings = CameraRawMiniatureSettings()
        settings.strength = 90
        settings.shape = .linear
        settings.focusSize = 0.12
        settings.centerY = 0.5
        let out = try CameraRawMiniature.apply(image, settings: settings)
        let centerDrop = try abs(luma(image, 48, 32) - luma(out, 48, 32))
        let edgeDrop = try abs(luma(image, 5, 5) - luma(out, 5, 5))
        #expect(edgeDrop > centerDrop, "the corner impulse blurs; the band's center impulse stays")
        #expect(centerDrop < 30, "an impulse on the focus line survives nearly intact (drop \(centerDrop))")
    }

    @Test func circularFocusRegionProtectsItsInsideAndBlursTheCorners() throws {
        let image = try impulseImage()
        var settings = CameraRawMiniatureSettings()
        settings.strength = 90
        settings.shape = .circular
        settings.focusSize = 0.18
        settings.centerX = 0.5
        settings.centerY = 0.5
        let out = try CameraRawMiniature.apply(image, settings: settings)
        let centerDrop = try abs(luma(image, 48, 32) - luma(out, 48, 32))
        let cornerDrop = try abs(luma(image, 5, 5) - luma(out, 5, 5))
        #expect(cornerDrop > centerDrop, "the corner impulse blurs; the region's center stays")
    }

    @Test func movingTheFocusCenterMovesTheProtectedRegion() throws {
        let image = try impulseImage(width: 96, height: 96)
        var settings = CameraRawMiniatureSettings()
        settings.strength = 90
        settings.shape = .circular
        settings.focusSize = 0.12
        settings.centerX = 0.2
        settings.centerY = 0.8
        let lowLeft = try CameraRawMiniature.apply(image, settings: settings)
        settings.centerX = 0.8
        settings.centerY = 0.2
        let topRight = try CameraRawMiniature.apply(image, settings: settings)
        // The impulse at the middle is outside both small regions, so both blur it — but the two
        // pictures must differ from each other, which is what a moved center means.
        #expect(try pixels(lowLeft) != pixels(topRight), "a moved focus moves the blur with it")
    }

    @Test func angleTiltsTheLinearBandAndCircularIgnoresIt() throws {
        let image = try impulseImage(width: 96, height: 96)
        var settings = CameraRawMiniatureSettings()
        settings.strength = 80
        settings.focusSize = 0.06
        settings.shape = .linear
        settings.angleDegrees = 0
        let horizontal = try CameraRawMiniature.apply(image, settings: settings)
        settings.angleDegrees = 90
        let vertical = try CameraRawMiniature.apply(image, settings: settings)
        #expect(try pixels(horizontal) != pixels(vertical), "a tilted band blurs different pixels")

        settings.shape = .circular
        let circularA = try CameraRawMiniature.apply(image, settings: settings)
        settings.angleDegrees = 0
        let circularB = try CameraRawMiniature.apply(image, settings: settings)
        #expect(try pixels(circularA) == pixels(circularB), "Angle is documented as unused for Circular")
    }

    @Test func focusSizeGrowsTheSharpRegion() throws {
        let image = try impulseImage(width: 96, height: 96)
        var settings = CameraRawMiniatureSettings()
        settings.strength = 90
        settings.shape = .circular
        settings.centerX = 0.5
        settings.centerY = 0.5
        settings.focusSize = 0.05
        let small = try CameraRawMiniature.apply(image, settings: settings)
        settings.focusSize = 0.45
        let large = try CameraRawMiniature.apply(image, settings: settings)
        // The corner impulse is far outside both radii; the difference to measure is how much of
        // the frame the large region protects, sampled halfway to the corner.
        let midDropSmall = try abs(luma(image, 22, 22) - luma(small, 22, 22))
        let midDropLarge = try abs(luma(image, 22, 22) - luma(large, 22, 22))
        #expect(midDropLarge < midDropSmall, "a larger Focus Size shields more of the frame")
    }

    @Test func falloffSoftensTheTransition() throws {
        let image = try impulseImage()
        var settings = CameraRawMiniatureSettings()
        settings.strength = 90
        settings.shape = .linear
        settings.focusSize = 0.1
        settings.falloff = 5
        let hard = try CameraRawMiniature.apply(image, settings: settings)
        settings.falloff = 95
        let soft = try CameraRawMiniature.apply(image, settings: settings)
        #expect(try pixels(hard) != pixels(soft), "Falloff changes the transition")
    }

    @Test func symmetricBlurNarrowsTheLinearBlurToOneSide() throws {
        // Three impulses: the middle of the band, and one in each half-frame. With Symmetric Blur
        // on, both outer impulses soften; with it off, the mask's single gradient leaves the far
        // half-frame bit-identical to the source, so exactly one outer impulse survives sharp.
        let width = 96, height = 96
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 46, y: 46, width: 4, height: 4))
        context.fill(CGRect(x: 4, y: 4, width: 3, height: 3))
        context.fill(CGRect(x: 4, y: 89, width: 3, height: 3))
        let image = try #require(context.makeImage())

        var settings = CameraRawMiniatureSettings()
        settings.strength = 90
        settings.shape = .linear
        settings.focusSize = 0.08
        settings.centerY = 0.5
        settings.symmetricBlur = true
        let both = try CameraRawMiniature.apply(image, settings: settings)
        settings.symmetricBlur = false
        let one = try CameraRawMiniature.apply(image, settings: settings)
        #expect(try pixels(both) != pixels(one), "Symmetric Blur changes the mask")

        // The top-corner impulse (device rows 3–6) sits in the half-frame the asymmetric mask
        // keeps sharp; the bottom-corner impulse sits in the side it still blurs.
        let topDropBoth = try abs(luma(image, 5, 4) - luma(both, 5, 4))
        let topDropOne = try abs(luma(image, 5, 4) - luma(one, 5, 4))
        let bottomDropOne = try abs(luma(image, 5, 91) - luma(one, 5, 91))
        #expect(topDropBoth > 0, "symmetric blur softens both halves")
        #expect(topDropOne == 0, "with Symmetric Blur off, the far half keeps its pixels exactly (drop \(topDropOne))")
        #expect(bottomDropOne > 0, "the near half still blurs with Symmetric Blur off")
    }

    @Test func symmetricPositionChangesNothingTodayAndIsDocumentedAsDeferred() throws {
        // The audit: the only place the flag could act is the mask, and the mask never reads it.
        // A change here means someone wired it up — the report and the panel must then follow.
        let image = try impulseImage()
        var on = CameraRawMiniatureSettings()
        on.strength = 80
        on.symmetricPosition = true
        var off = on
        off.symmetricPosition = false
        let onPixels = try pixels(try CameraRawMiniature.apply(image, settings: on))
        let offPixels = try pixels(try CameraRawMiniature.apply(image, settings: off))
        #expect(onPixels == offPixels, "symmetricPosition is still a deferred, non-rendering field")
    }

    @Test func resetReturnsThePanelDefaults() {
        var settings = CameraRawMiniatureSettings()
        settings.strength = 70
        settings.shape = .circular
        settings.centerX = 0.1
        settings.symmetricBlur = false
        settings.reset()
        #expect(settings == CameraRawMiniatureSettings())
        #expect(settings.isIdentity)
    }

    // MARK: - Pipeline compatibility

    @Test func miniatureRunsAfterPerspectiveAndHorizonInTheStack() throws {
        // Geometry moves pixels, then Miniature blurs the moved picture: the band must follow the
        // correction, and the output must be well-formed either way.
        let image = try impulseImage(width: 80, height: 60)
        var settings = CameraRawSettings()
        settings.geometry.upright = .off
        settings.geometry.vertical = 30
        settings.geometry.framingMode = .keepOriginalSize
        settings.horizon.mode = .angle
        settings.horizon.angleDegrees = 4
        settings.miniature.strength = 70
        settings.miniature.shape = .linear
        let out = try settings.applyResult(image)
        #expect(out.image.width == 80 && out.image.height == 60)
    }

    @Test func miniatureAndLensBlurAreIndependentStages() throws {
        let image = try impulseImage()
        var miniatureOnly = CameraRawSettings()
        miniatureOnly.miniature.strength = 80
        miniatureOnly.miniature.shape = .circular
        var lensOnly = CameraRawSettings()
        lensOnly.optics.lensBlur.amount = 80
        var both = miniatureOnly
        both.optics.lensBlur = lensOnly.optics.lensBlur

        let a = try pixels(miniatureOnly.apply(image))
        let b = try pixels(lensOnly.apply(image))
        let c = try pixels(both.apply(image))
        #expect(a != b, "the two engines are different effects")
        #expect(c != a && c != b, "both run when both are set")
    }

    @Test func transparencyAndBoundariesStayWellFormed() throws {
        let context = try BrushRaster.context(width: 48, height: 48, mask: false)
        context.clear(CGRect(x: 0, y: 0, width: 48, height: 48))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 18, y: 18, width: 12, height: 12))
        let image = try #require(context.makeImage())
        var settings = CameraRawMiniatureSettings()
        settings.strength = 85
        let out = try CameraRawMiniature.apply(image, settings: settings)
        #expect(out.width == 48 && out.height == 48)
        let outCount = try pixels(out).count
        let sourceCount = try pixels(image).count
        #expect(outCount == sourceCount, "the pixel grid never changes")
    }

    @Test func pixelDimensionsAreKeptAtEveryStrength() throws {
        for strength in [1.0, 25.0, 60.0, 100.0] {
            var settings = CameraRawMiniatureSettings()
            settings.strength = strength
            settings.shape = strength > 50 ? .circular : .linear
            let out = try CameraRawMiniature.apply(try impulseImage(width: 40, height: 33), settings: settings)
            #expect(out.width == 40 && out.height == 33, "strength \(strength) keeps the frame")
        }
    }

    // MARK: - Move Focus interaction (the mode the panel arms)

    @Test func moveFocusDragsTheCenterAndEscapePutsItBack() throws {
        let session = try session()
        let edit = try #require(session.filterEdit)
        var settings = edit.settings
        settings.cameraRaw.miniature.strength = 80
        session.updateFilter(settings, preview: true)
        #expect(edit.settings.cameraRaw.miniature.centerX == 0.5)
        #expect(edit.settings.cameraRaw.miniature.centerY == 0.5)

        let image = edit.previewSource
        func documentPoint(normalizedX x: Double, y: Double) -> CGPoint {
            CGPoint(x: x * CGFloat(image.width), y: y * CGFloat(image.height)).applying(edit.previewMapping)
        }

        // Arming captures the center where the drag found it.
        session.beginCameraRawMiniatureFocusInteraction()
        #expect(edit.movesCameraRawMiniatureFocus)
        #expect(edit.cameraRawMiniatureDragOriginalCenter != nil)

        // The press moves the focus to the pointer, then the drag follows it.
        session.moveCameraRawMiniatureFocus(to: documentPoint(normalizedX: 0.25, y: 0.25))
        #expect(abs(edit.settings.cameraRaw.miniature.centerX - 0.25) < 0.02)
        session.moveCameraRawMiniatureFocus(to: documentPoint(normalizedX: 0.7, y: 0.3))
        #expect(abs(edit.settings.cameraRaw.miniature.centerX - 0.7) < 0.02)
        #expect(abs(edit.settings.cameraRaw.miniature.centerY - 0.3) < 0.02)

        // Escape restores exactly, and disarms without writing any document entry.
        session.cancelCameraRawMiniatureFocusInteraction()
        #expect(!edit.movesCameraRawMiniatureFocus)
        #expect(edit.cameraRawMiniatureDragOriginalCenter == nil)
        #expect(edit.settings.cameraRaw.miniature.centerX == 0.5)
        #expect(edit.settings.cameraRaw.miniature.centerY == 0.5)
    }

    @Test func completingADragKeepsTheMovedFocusInOneEdit() throws {
        let session = try session()
        let edit = try #require(session.filterEdit)
        var settings = edit.settings
        settings.cameraRaw.miniature.strength = 80
        settings.cameraRaw.miniature.centerY = 0.3
        session.updateFilter(settings, preview: true)

        let image = edit.previewSource
        let target = CGPoint(x: 0.6 * CGFloat(image.width), y: 0.6 * CGFloat(image.height))
            .applying(edit.previewMapping)
        session.beginCameraRawMiniatureFocusInteraction()
        session.moveCameraRawMiniatureFocus(to: target)
        session.endCameraRawMiniatureFocusInteraction()
        #expect(!edit.movesCameraRawMiniatureFocus)
        #expect(edit.cameraRawMiniatureDragOriginalCenter == nil)
        #expect(abs(edit.settings.cameraRaw.miniature.centerX - 0.6) < 0.02)
        #expect(abs(edit.settings.cameraRaw.miniature.centerY - 0.6) < 0.02)
        // The settings were normalized on the way in, so the stored edit is the settled value.
        #expect(edit.settings.cameraRaw.miniature == edit.settings.cameraRaw.miniature.normalized)
    }

    @Test func anArmedDragThatNeverMovesLeavesTheSettingsAlone() throws {
        let session = try session()
        let edit = try #require(session.filterEdit)
        var settings = edit.settings
        settings.cameraRaw.miniature.strength = 80
        session.updateFilter(settings, preview: true)
        let before = edit.settings

        session.beginCameraRawMiniatureFocusInteraction()
        session.endCameraRawMiniatureFocusInteraction()
        #expect(edit.settings == before, "a no-op drag writes nothing")
    }

    @Test func armingOneCanvasModeEndsTheOthers() throws {
        let session = try session()
        let edit = try #require(session.filterEdit)
        edit.drawingCameraRawGeometryGuide = true
        session.beginCameraRawMiniatureFocusInteraction()
        #expect(edit.movesCameraRawMiniatureFocus)
        #expect(!edit.drawingCameraRawGeometryGuide)
        #expect(edit.cameraRawGuideDraft == nil)

        edit.drawingCameraRawPerspectiveTool = true
        session.beginCameraRawGeometryGuideDrawing()
        #expect(!edit.movesCameraRawMiniatureFocus, "Guided Upright drawing disarms the Miniature move")
        #expect(edit.cameraRawMiniatureDragOriginalCenter == nil)

        edit.drawingCameraRawHorizonReference = true
        session.beginCameraRawMiniatureFocusInteraction()
        #expect(!edit.drawingCameraRawHorizonReference)
        #expect(edit.cameraRawHorizonReferenceDraft == nil)

        // The advanced tools only arm when their own tool kind draws on the canvas; the default
        // Automatic does not, so arm Guided-style by selecting a drawing tool first.
        session.selectCameraRawPerspectiveTool(.verticalGuides)
        session.beginCameraRawPerspectiveToolDrawing()
        #expect(edit.drawingCameraRawPerspectiveTool)
        #expect(!edit.movesCameraRawMiniatureFocus, "the advanced tools disarm the Miniature move")
    }

    @Test func resetGeometryAlsoDisarmsTheFocusDrag() throws {
        let session = try session()
        let edit = try #require(session.filterEdit)
        var settings = edit.settings
        settings.cameraRaw.miniature.strength = 80
        settings.cameraRaw.miniature.centerX = 0.2
        session.updateFilter(settings, preview: true)

        session.beginCameraRawMiniatureFocusInteraction()
        session.resetCameraRaw(.geometry)
        #expect(!edit.movesCameraRawMiniatureFocus)
        #expect(edit.cameraRawMiniatureDragOriginalCenter == nil)
        #expect(edit.settings.cameraRaw.miniature.isIdentity, "Reset Geometry owns Miniature, as its group always has")
    }

    @Test func geometryEyeCoversMiniatureInThePreview() throws {
        let session = try session()
        let edit = try #require(session.filterEdit)
        var settings = edit.settings
        settings.cameraRaw.miniature.strength = 80
        session.updateFilter(settings, preview: true)
        #expect(edit.settings.cameraRaw.adjustsGeometry)

        // The eye off drops the group's amounts from what renders and what OK commits.
        let shown = edit.settings.cameraRaw.applying(showsLight: true, showsColor: true, showsGeometry: false)
        #expect(shown.miniature.isIdentity)
        #expect(shown.miniature.strength == 0)
    }

    // MARK: - Persistence

    @Test func miniatureSettingsSurviveThePanelPersistenceRoundTrip() throws {
        var settings = CameraRawSettings()
        settings.miniature.strength = 65
        settings.miniature.shape = .circular
        settings.miniature.focusSize = 0.31
        settings.miniature.falloff = 55
        settings.miniature.centerX = 0.4
        settings.miniature.centerY = 0.6
        settings.miniature.angleDegrees = 25
        settings.miniature.symmetricBlur = false

        let state = CameraRawSettingsPersistentState(settings)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: data)
        let restored = try decoded.makeSettings()
        #expect(restored.miniature == settings.miniature.normalized)
    }

    @Test func olderSettingsWithoutMiniatureDecodeToIdentity() throws {
        let state = CameraRawSettingsPersistentState(CameraRawSettings())
        let data = try JSONEncoder().encode(state)
        // Simulate an older file: strip the miniature key.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["miniature"] = nil
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: stripped)
        let restored = try decoded.makeSettings()
        #expect(restored.miniature == CameraRawMiniatureSettings())
        #expect(restored.miniature.isIdentity)
    }

    @Test func switchingShapesKeepsTheOtherSettings() {
        var settings = CameraRawMiniatureSettings()
        settings.strength = 60
        settings.focusSize = 0.25
        settings.angleDegrees = 30
        settings.centerX = 0.3
        let before = settings
        settings.shape = .circular
        #expect(settings.strength == 60 && settings.focusSize == 0.25 && settings.centerX == 0.3)
        settings.angleDegrees = 90
        settings.shape = .linear
        #expect(settings.angleDegrees == 90, "a value set under one shape survives switching back")
        #expect(before.shape == .linear)
    }

    @Test func normalizedSettingsAreStableAcrossRepeatedNormalization() {
        var settings = CameraRawMiniatureSettings()
        settings.strength = 140
        settings.falloff = -5
        settings.focusSize = 2
        settings.centerX = -0.5
        settings.centerY = 1.5
        settings.angleDegrees = 400
        let once = settings.normalized
        #expect(once.normalized == once, "normalization is idempotent")
    }
}
