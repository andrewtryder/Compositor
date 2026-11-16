import AppKit
import Foundation
import Testing
@testable import Compositor

/// Milestone 10.8: renders the before/after pictures the Miniature report cites.
///
/// These are not UI screenshots. They are the real Camera Raw pipeline, run on the untracked
/// `work/geometry-validation/originals` photographs through `CameraRawSettings.applyResult` — the
/// same code path the panel previews and Apply commits, with the same `CameraRawMiniatureSettings`
/// the new Geometry controls write. The renderer itself is untouched; these sheets evidence what
/// the exposed controls produce.
///
/// The test host is the sandboxed app, so it cannot write into the checkout. It leaves the
/// pictures in the app's container and `scripts/miniature-evidence.sh` copies them next to the
/// report. The photographs are untracked, so a checkout without them skips rather than failing.
@MainActor
struct CameraRawMiniatureEvidenceTests {
    private func outputDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["M10_8_EVIDENCE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CompositorM10_8Evidence", isDirectory: true)
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

    /// Before, Linear at the panel defaults, Linear with a tilted band and moved center, and
    /// Circular — the four states the report's photographic section walks through.
    @Test(.enabled(if: GeometryValidationFixtures.missingPhotographsReason == nil,
                   "the untracked geometry photographs are not in this checkout"))
    func writesMiniatureContactSheetsForLinearAndCircular() throws {
        try #require(GeometryValidationFixtures.hasLocalPhotographs,
                     "the untracked geometry photographs are not in this checkout")
        let output = try outputDirectory()

        for name in ["stone-house.jpg", "window-wall.jpg"] {
            let source = try sampled(try photograph(name), longest: 520)
            let stem = name.replacingOccurrences(of: ".jpg", with: "")

            var before = CameraRawSettings()
            before.automaticHorizonAngle = nil
            let beforeImage = try before.applyResult(source).image

            // Linear at the exposed defaults: Amount 60 raised from 0, everything else as shipped.
            var linear = CameraRawSettings()
            linear.miniature.strength = 60
            linear.miniature.shape = .linear
            linear.miniature.focusSize = 0.2
            linear.miniature.falloff = 40
            linear.miniature.centerX = 0.5
            linear.miniature.centerY = 0.5
            linear.miniature.angleDegrees = 0
            let linearImage = try linear.applyResult(source).image

            // A working tilt-shift composition: a low, slightly tilted band over the subject.
            var composed = linear
            composed.miniature.centerY = 0.62
            composed.miniature.angleDegrees = 8
            composed.miniature.focusSize = 0.14
            composed.miniature.falloff = 25
            let composedImage = try composed.applyResult(source).image

            // Circular: a sharp region over the subject, corners dissolved.
            var circular = composed
            circular.miniature.shape = .circular
            circular.miniature.focusSize = 0.22
            circular.miniature.centerX = 0.45
            circular.miniature.centerY = 0.55
            let circularImage = try circular.applyResult(source).image

            let sheet = try contactSheet([
                ("Before", beforeImage),
                ("Linear, Amount 60, defaults", linearImage),
                ("Linear, band at 62% · 8°", composedImage),
                ("Circular, radius 0.22", circularImage)
            ])
            try write(sheet, to: output.appendingPathComponent("\(stem)-miniature.png"))
        }
    }

    /// The measured claims the report makes, on a photograph rather than a synthetic impulse:
    /// zero strength is the exact input, and blur lands outside the band while the band keeps
    /// its local contrast.
    @Test(.enabled(if: GeometryValidationFixtures.missingPhotographsReason == nil,
                   "the untracked geometry photographs are not in this checkout"))
    func zeroStrengthIsBitIdenticalAndBlurStaysOutsideTheBand() throws {
        try #require(GeometryValidationFixtures.hasLocalPhotographs)
        let source = try sampled(try photograph("stone-house.jpg"), longest: 400)
        let sourcePixels = try MeshWarpRaster.rgba8Bytes(from: source)

        var identity = CameraRawSettings()
        identity.miniature.strength = 0
        #expect(try MeshWarpRaster.rgba8Bytes(from: try identity.applyResult(source).image) == sourcePixels,
                "Amount 0 commits the exact input")

        var applied = CameraRawSettings()
        applied.miniature.strength = 80
        applied.miniature.shape = .linear
        applied.miniature.focusSize = 0.12
        let appliedPixels = try MeshWarpRaster.rgba8Bytes(from: try applied.applyResult(source).image)
        #expect(appliedPixels != sourcePixels, "the effect did something")

        // Local variance, per row band: the band across the middle keeps its structure, the
        // sky above it is flattened toward its mean.
        func rowSpread(_ pixels: [UInt8], rows: ClosedRange<Int>, width: Int, height: Int) -> Double {
            var sum = 0.0, sum2 = 0.0, count = 0
            for y in rows where y >= 0 && y < height {
                for x in 0..<width {
                    let i = y * width * 4 + x * 4
                    let luma = 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
                    sum += luma; sum2 += luma * luma; count += 1
                }
            }
            guard count > 1 else { return 0 }
            return (sum2 / Double(count) - pow(sum / Double(count), 2)).squareRoot()
        }
        let width = source.width, height = source.height
        let band = Int((0.44 * Double(height)).rounded())...Int((0.56 * Double(height)).rounded())
        let sky = Int(0.05 * Double(height))...Int(0.15 * Double(height))
        let bandSpreadBefore = rowSpread(sourcePixels, rows: band, width: width, height: height)
        let bandSpreadAfter = rowSpread(appliedPixels, rows: band, width: width, height: height)
        let skySpreadBefore = rowSpread(sourcePixels, rows: sky, width: width, height: height)
        let skySpreadAfter = rowSpread(appliedPixels, rows: sky, width: width, height: height)
        #expect(bandSpreadAfter > bandSpreadBefore * 0.9, "the focus band keeps its structure (Δ \(bandSpreadBefore - bandSpreadAfter))")
        #expect(skySpreadAfter < skySpreadBefore * 0.8, "outside the band the picture flattens (Δ \(skySpreadBefore - skySpreadAfter))")
    }
}
