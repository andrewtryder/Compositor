import AppKit
import Foundation
import Testing
@testable import Compositor

/// Milestone 10.9: renders the before/after pictures the anamorphic and crop report cites.
///
/// The real Camera Raw pipeline, run on the untracked `work/geometry-validation/originals`
/// photographs through `CameraRawSettings.applyResult` — the same code path the panel commits,
/// with the de-squeeze ratio and crop request the new Geometry controls write. The renderer is
/// untouched; these sheets evidence what the exposed controls produce.
///
/// The test host is the sandboxed app, so it cannot write into the checkout. It leaves the
/// pictures in the app's container and `scripts/anamorphic-evidence.sh` copies them next to the
/// report. The photographs are untracked, so a checkout without them skips rather than failing.
@MainActor
struct CameraRawAnamorphicEvidenceTests {
    private func outputDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["M10_9_EVIDENCE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CompositorM10_9Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func photograph(_ name: String) throws -> CGImage {
        let root = try #require(GeometryValidationFixtures.rootContaining("originals/\(name)"),
                                "work/geometry-validation/originals/\(name)")
        let url = root.appendingPathComponent("originals/\(name)")
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
        return try #require(rep.cgImage)
    }

    private func sampled(_ image: CGImage, longest: Int) throws -> CGImage {
        let scale = min(1, Double(longest) / Double(max(image.width, image.height)))
        guard scale < 1 else { return image }
        let width = Int((Double(image.width) * scale).rounded())
        let height = Int((Double(image.height) * scale).rounded())
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// One row of pictures, each labeled underneath, on a neutral background. A plain context, not
    /// `BrushRaster.context`: that one flips the CTM, which renders `CTLine` text mirrored.
    private func contactSheet(_ tiles: [(String, CGImage)], tileHeight: Int = 300) throws -> CGImage {
        let padding = 12
        let labelHeight = 22
        let scales = tiles.map { Double(tileHeight) / Double($0.1.height) }
        let widths = zip(tiles, scales).map { Int((Double($0.0.1.width) * $0.1).rounded()) }
        let totalWidth = widths.reduce(0, +) + padding * (tiles.count + 1)
        let totalHeight = tileHeight + labelHeight + padding * 2
        let context = try #require(CGContext(data: nil, width: totalWidth, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "the contact sheet's context")
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        context.interpolationQuality = .high

        var x = padding
        for ((label, image), width) in zip(tiles, widths) {
            context.draw(image, in: CGRect(x: x, y: labelHeight + padding, width: width, height: tileHeight))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(white: 0.85, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
            context.textPosition = CGPoint(x: x, y: padding + 4)
            CTLineDraw(line, context)
            x += width + padding
        }
        return try #require(context.makeImage())
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// De-squeeze: squeezed 2× horizontally in the sampler, then Off, 1.5× and 2.0× beside each
    /// other — the restored proportions the panel's preset menu promises.
    @Test(.enabled(if: GeometryValidationFixtures.missingPhotographsReason == nil,
                   "the untracked geometry photographs are not in this checkout"))
    func writesDeSqueezeContactSheet() throws {
        try #require(GeometryValidationFixtures.hasLocalPhotographs,
                     "the untracked geometry photographs are not in this checkout")
        let output = try outputDirectory()

        let name = "stone-house.jpg"
        let source = try sampled(try photograph(name), longest: 400)

        // Simulate a squeezed capture: sample horizontally to half width, so the de-squeeze
        // restores what a 2× anamorphic lens would have compressed onto the sensor.
        let squeezedWidth = source.width / 2
        let squeezeContext = try BrushRaster.context(width: squeezedWidth, height: source.height, mask: false)
        squeezeContext.interpolationQuality = .low
        squeezeContext.draw(source, in: CGRect(x: 0, y: 0, width: squeezedWidth, height: source.height))
        let squeezed = try #require(squeezeContext.makeImage())

        var off = CameraRawSettings()
        let offImage = try off.applyResult(squeezed).image

        var oneFifty = CameraRawSettings()
        oneFifty.geometry.anamorphic = CameraRawAnamorphicSettings(ratio: 1.5)
        let oneFiftyImage = try oneFifty.applyResult(squeezed).image

        var two = CameraRawSettings()
        two.geometry.anamorphic = CameraRawAnamorphicSettings(ratio: 2)
        let twoImage = try two.applyResult(squeezed).image

        let sheet = try contactSheet([
            ("Squeezed 2×", squeezed),
            ("Off", offImage),
            ("De-squeeze 1.5×", oneFiftyImage),
            ("De-squeeze 2.0×", twoImage)
        ])
        try write(sheet, to: output.appendingPathComponent("stone-house-anamorphic.png"))
    }

    /// Crop After Transform: de-squeeze 2×, then a manual crop over the subject — the sheet shows
    /// the un-cropped corrected frame beside the cropped commit.
    @Test(.enabled(if: GeometryValidationFixtures.missingPhotographsReason == nil,
                   "the untracked geometry photographs are not in this checkout"))
    func writesCropContactSheet() throws {
        try #require(GeometryValidationFixtures.hasLocalPhotographs,
                     "the untracked geometry photographs are not in this checkout")
        let output = try outputDirectory()

        let name = "window-wall.jpg"
        let source = try sampled(try photograph(name), longest: 400)
        var before = CameraRawSettings()
        let beforeImage = try before.applyResult(source).image

        // De-squeeze 2× widens the corrected frame; the manual crop keeps its middle 60% × 60%.
        var settings = CameraRawSettings()
        settings.geometry.anamorphic = CameraRawAnamorphicSettings(ratio: 2)
        let corrected = try settings.applyResult(source).image
        let cropWidth = corrected.width * 6 / 10, cropHeight = corrected.height * 6 / 10
        let manual = CameraRawGeometryCropRequest(manualCrop: CGRect(
            x: (corrected.width - cropWidth) / 2, y: (corrected.height - cropHeight) / 2,
            width: cropWidth, height: cropHeight))
        var cropped = settings
        cropped.crop = manual
        let croppedImage = try cropped.applyResult(source).image

        let sheet = try contactSheet([
            ("Before", beforeImage),
            ("De-squeezed 2× (uncropped)", corrected),
            ("Crop After Transform 60%", croppedImage)
        ])
        try write(sheet, to: output.appendingPathComponent("window-wall-geometry-crop.png"))
    }

    /// The measured claims the report makes: 1.0 is the exact input (bit-identical), 2.0 widens
    /// to exactly double, and the crop commit is the kept rectangle placed where its pixels came from.
    @Test(.enabled(if: GeometryValidationFixtures.missingPhotographsReason == nil,
                   "the untracked geometry photographs are not in this checkout"))
    func identityIsBitExactAndCropKeepsItsRect() throws {
        try #require(GeometryValidationFixtures.hasLocalPhotographs)
        let source = try sampled(try photograph("stone-house.jpg"), longest: 300)
        let sourcePixels = try MeshWarpRaster.rgba8Bytes(from: source)

        var off = CameraRawSettings()
        off.geometry.anamorphic = CameraRawAnamorphicSettings(ratio: 1)
        #expect(try MeshWarpRaster.rgba8Bytes(from: try off.applyResult(source).image) == sourcePixels,
                "Off commits the exact input")

        var two = CameraRawSettings()
        two.geometry.anamorphic = CameraRawAnamorphicSettings(ratio: 2)
        let widened = try two.applyResult(source).image
        #expect(widened.width == source.width * 2)
        #expect(widened.height == source.height)
        let widenedPixels = try MeshWarpRaster.rgba8Bytes(from: widened)
        #expect(widenedPixels != sourcePixels, "the de-squeeze did something")

        // A manual crop of the un-de-squeezed picture commits the kept rectangle, nothing else.
        var cropped = CameraRawSettings()
        cropped.crop.manualCrop = CGRect(x: 10, y: 10, width: 100, height: 60)
        let croppedImage = try cropped.applyResult(source).image
        #expect(croppedImage.width == 100)
        #expect(croppedImage.height == 60)
        let expected = try #require(source.cropping(to: CGRect(x: 10, y: 10, width: 100, height: 60)))
        let croppedPixels = try MeshWarpRaster.rgba8Bytes(from: croppedImage)
        let expectedPixels = try MeshWarpRaster.rgba8Bytes(from: expected)
        #expect(croppedPixels == expectedPixels, "the crop commits exactly the kept rectangle")
    }
}

extension CameraRawGeometryCropRequest {
    /// Convenience for evidence sheets: a request with only a manual crop set.
    init(manualCrop: CGRect) {
        self.init()
        self.manualCrop = manualCrop
    }
}
