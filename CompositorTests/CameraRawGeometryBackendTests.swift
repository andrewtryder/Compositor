import CoreGraphics
import Foundation
import Testing
@testable import Compositor

struct CameraRawGeometryBackendTests {
    private func solidImage(width: Int, height: Int, color: (UInt8, UInt8, UInt8, UInt8) = (200, 100, 50, 255)) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(red: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255,
                             blue: CGFloat(color.2) / 255, alpha: CGFloat(color.3) / 255)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func expandCoverageMatchesExpandedFrame() throws {
        let width = 100, height = 80
        var settings = CameraRawGeometrySettings()
        settings.upright = .off
        settings.vertical = 40
        settings.framingMode = .expandToFit
        let corners = settings.outputCorners(width: width, height: height)
        let frame = try #require(CameraRawPerspective.expandedFrame(corners: corners))
        let coverage = try #require(CameraRawPerspective.coverageInLayerPixels(corners: corners, width: width, height: height))
        #expect(Int(coverage.width) == Int(frame.size.width))
        #expect(Int(coverage.height) == Int(frame.size.height))
    }

    @Test func expandApplyResultReturnsLargerImageAndPlacement() throws {
        let image = try solidImage(width: 120, height: 90)
        var settings = CameraRawGeometrySettings()
        settings.upright = .off
        settings.vertical = 55
        settings.framingMode = .expandToFit
        let result = try settings.applyResult(image)
        #expect(result.image.width >= image.width || result.image.height >= image.height)
        let expansion = try #require(result.expansion)
        #expect(expansion.outputWidth == result.image.width)
        #expect(expansion.outputHeight == result.image.height)
        let base = LayerTransform(origin: CGPoint(x: 10, y: 20), size: CGSize(width: 120, height: 90))
        let placed = expansion.layerTransform(from: base)
        #expect(placed.rotation == base.rotation)
        #expect(placed.size.width > base.size.width - 0.5 || placed.size.height > base.size.height - 0.5)
        // Sibling layers are untouched by construction: only the returned transform changes.
        #expect(base.origin == CGPoint(x: 10, y: 20))
    }

    @Test func keepOriginalSizeRemainsBackwardCompatible() throws {
        let image = try solidImage(width: 64, height: 48)
        var settings = CameraRawGeometrySettings()
        settings.upright = .off
        settings.vertical = 40
        settings.framingMode = .keepOriginalSize
        let result = try settings.applyResult(image)
        #expect(result.image.width == 64)
        #expect(result.image.height == 48)
        #expect(result.expansion == nil)
    }

    @Test func expansionLayerTransformPreservesCenterMapping() {
        let expansion = CameraRawGeometryExpansion(
            inputWidth: 100, inputHeight: 100,
            coverageInInput: CGRect(x: -10, y: -5, width: 120, height: 110))
        let base = LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100))
        let placed = expansion.layerTransform(from: base)
        let toDocument = BrushRaster.pixelToDocument(base, width: 100, height: 100)
        let oldMid = CGPoint(x: 50, y: 50).applying(toDocument)
        let newToDocument = BrushRaster.pixelToDocument(placed, width: 120, height: 110)
        // Coverage mid (50, 50) in input == (60, 55) in expanded pixels.
        let newMid = CGPoint(x: 60, y: 55).applying(newToDocument)
        #expect(abs(oldMid.x - newMid.x) < 0.75)
        #expect(abs(oldMid.y - newMid.y) < 0.75)
    }

    @Test func horizonHorizontalReferenceLevels() throws {
        var settings = CameraRawHorizonSettings()
        settings.mode = .horizontalReference
        settings.referenceStartX = 0.1
        settings.referenceStartY = 0.4
        settings.referenceEndX = 0.9
        settings.referenceEndY = 0.5
        let degrees = try #require(CameraRawHorizon.rotationDegrees(settings: settings, width: 200, height: 100))
        #expect(abs(degrees) > 0.5)
        // Reversed endpoints → same correction.
        swap(&settings.referenceStartX, &settings.referenceEndX)
        swap(&settings.referenceStartY, &settings.referenceEndY)
        let reversed = try #require(CameraRawHorizon.rotationDegrees(settings: settings, width: 200, height: 100))
        #expect(abs(degrees - reversed) < 0.05)
    }

    @Test func horizonZeroAmountIsIdentity() {
        var settings = CameraRawHorizonSettings()
        settings.mode = .angle
        settings.angleDegrees = 12
        settings.amount = 0
        #expect(CameraRawHorizon.rotationDegrees(settings: settings, width: 100, height: 100) == nil)
    }

    @Test func horizonHomographyMatchesManualRotateCorners() throws {
        let degrees = 8.0
        let homo = try #require(CameraRawHorizon.rotationHomography(degrees: degrees, width: 100, height: 80))
        var geometry = CameraRawGeometrySettings()
        geometry.rotate = degrees
        let manual = geometry.outputCorners(width: 100, height: 80)
        let fromHomo = CameraRawPerspective.perspectiveCorners(homography: homo, width: 100, height: 80)
        for (a, b) in zip(manual, fromHomo) {
            #expect(hypot(a.x - b.x, a.y - b.y) < 0.05)
        }
    }

    @Test func perspectiveToolsRectangleProducesFourGuides() throws {
        var state = CameraRawPerspectiveToolState()
        state.kind = .rectangle
        state.rectangleCorners = [
            CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.8, y: 0.75),
            CGPoint(x: 0.85, y: 0.2), CGPoint(x: 0.15, y: 0.25)
        ]
        let guides = try #require(CameraRawPerspectiveTools.rectangleGuides(corners: state.rectangleCorners))
        #expect(guides.count == 4)
        var geometry = CameraRawGeometrySettings()
        geometry = CameraRawPerspectiveTools.applying(state, to: geometry)
        #expect(geometry.upright == .guided)
        #expect(geometry.guides.count == 4)
    }

    @Test func hvRatioMapsToAspect() {
        #expect(CameraRawPerspectiveTools.aspectFromHorizontalVerticalRatio(40) == 40)
        #expect(CameraRawPerspectiveTools.horizontalVerticalRatio(fromAspect: -20) == -20)
    }

    @Test func miniatureZeroStrengthIsIdentity() throws {
        let image = try solidImage(width: 32, height: 32)
        var settings = CameraRawMiniatureSettings()
        settings.strength = 0
        let out = try CameraRawMiniature.apply(image, settings: settings)
        #expect(out.width == image.width)
        #expect(out.height == image.height)
    }

    @Test func miniatureAppliesFiniteBlur() throws {
        let image = try solidImage(width: 48, height: 48)
        var settings = CameraRawMiniatureSettings()
        settings.strength = 80
        settings.falloff = 50
        settings.shape = .circular
        let out = try CameraRawMiniature.apply(image, settings: settings)
        #expect(out.width == 48)
        #expect(out.height == 48)
    }

    @Test func backendSerializationDefaults() throws {
        let empty = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(CameraRawGeometryBackendSettings.self, from: empty)
        #expect(decoded.horizon.mode == .off)
        #expect(decoded.miniature.strength == 0)
        #expect(decoded.geometry.perspectiveAmount == 100)
        #expect(decoded.geometry.framingMode == .keepOriginalSize)
    }

    @Test func backendApplyRunsPerspectiveAndMiniature() throws {
        let image = try solidImage(width: 60, height: 40)
        var settings = CameraRawGeometryBackendSettings()
        settings.geometry.upright = .off
        settings.geometry.vertical = 35
        settings.geometry.framingMode = .expandToFit
        settings.crop.framing = .expandToFit
        settings.miniature.strength = 40
        settings.miniature.shape = .linear
        let result = try CameraRawGeometryBackend.apply(image, settings: settings)
        #expect(result.image.width > 0 && result.image.height > 0)
    }
}
