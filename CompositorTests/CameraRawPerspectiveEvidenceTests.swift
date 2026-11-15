import AppKit
import Foundation
import Testing
@testable import Compositor

/// Milestone 10.5: renders the corrected-beside-source pictures the report cites, through the real Camera Raw
/// pipeline and on the checked-in `work/geometry-validation/originals` photographs.
///
/// These are not UI screenshots. `CameraRawSettings.applyResult` is the same path the panel previews and Apply
/// commits, run with the same `CameraRawPerspectiveToolState` the Advanced Perspective controls write, which is
/// the honest evidence a unit test can produce. The interactive captures live in `work/camera-raw-parity/screenshots`.
///
/// The test host is the sandboxed app and cannot write into the checkout: it leaves the pictures in the app's
/// container and `scripts/perspective-evidence.sh` copies them next to the report.
///
/// The photographs are untracked, so a checkout without them skips rather than failing or inventing a picture.
@MainActor
struct CameraRawPerspectiveEvidenceTests {
    private func outputDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["M10_5_EVIDENCE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CompositorM10_5Evidence", isDirectory: true)
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

    /// A source and its correction side by side, each labeled: the comparison the report makes.
    /// A plain context, not `BrushRaster.context`: that one flips the CTM for drawing user-space images, which
    /// renders `CTLine` text mirrored.
    private func sideBySide(_ before: CGImage, _ after: CGImage, labels: (String, String),
                            tileHeight: Int = 320) throws -> CGImage {
        let padding = 12, labelHeight = 22
        let scale = Double(tileHeight) / Double(before.height)
        let width = Int((Double(before.width) * scale).rounded())
        let totalWidth = width * 2 + padding * 3
        let totalHeight = tileHeight + labelHeight + padding * 2
        let context = try #require(CGContext(data: nil, width: totalWidth, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        context.interpolationQuality = .high
        context.draw(before, in: CGRect(x: padding, y: labelHeight + padding,
                                        width: width, height: tileHeight))
        context.draw(after, in: CGRect(x: padding * 2 + width, y: labelHeight + padding,
                                       width: width, height: tileHeight))
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let white = CGColor(gray: 0.92, alpha: 1)
        for (index, label) in [labels.0, labels.1].enumerated() {
            let attributed = NSAttributedString(string: label, attributes: [
                .font: font, .foregroundColor: NSColor(cgColor: white) as Any
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: CGFloat(padding + index * (width + padding)), y: CGFloat(padding) / 2)
            CTLineDraw(line, context)
        }
        return try #require(context.makeImage())
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// The picture a tool produces, through the pipeline the panel previews with.
    private func corrected(_ source: CGImage, _ tools: CameraRawPerspectiveToolState) throws -> CGImage {
        var settings = CameraRawSettings()
        settings.perspectiveTools = tools
        settings.automaticHorizonAngle = nil
        return try settings.applyResult(source).image
    }

    /// One photograph, six corrections: source, two vertical guides, two horizontals, combined, a rectangle drawn on
    /// the building's face, and the eight-point segments. Each is written both on its own and as a source/corrected
    /// pair, so the report can show the change and the difference.
    @Test func writesCorrectedBesideSourceForEveryTool() throws {
        try #require(GeometryValidationFixtures.hasLocalPhotographs,
                     "the untracked geometry photographs are not in this checkout")
        let output = try outputDirectory()
        let source = try sampled(try photograph("stone-house.jpg"), longest: 520)
        let sourceImage = try CameraRawSettings().applyResult(source).image
        try write(sourceImage, to: output.appendingPathComponent("stone-house-source.png"))

        let converging: [CameraRawGeometryGuide] = [
            CameraRawGeometryGuide(startX: 0.30, startY: 0.02, endX: 0.37, endY: 0.98),
            CameraRawGeometryGuide(startX: 0.70, startY: 0.02, endX: 0.63, endY: 0.98)
        ]

        // Vertical Guides: two converging verticals, the correction this photograph actually needs.
        var vertical = CameraRawPerspectiveToolState()
        vertical.kind = .verticalGuides
        vertical.verticalGuides = converging
        let verticalImage = try corrected(source, vertical)
        try write(try sideBySide(sourceImage, verticalImage, labels: ("Source", "Vertical Guides")),
                  to: output.appendingPathComponent("stone-house-vertical-guides.png"))

        // Horizontal Guides: two level-ish lines with a small downward tilt, which rolls and keystones.
        var horizontal = CameraRawPerspectiveToolState()
        horizontal.kind = .horizontalGuides
        horizontal.horizontalGuides = [
            CameraRawGeometryGuide(startX: 0.06, startY: 0.30, endX: 0.94, endY: 0.345),
            CameraRawGeometryGuide(startX: 0.06, startY: 0.72, endX: 0.94, endY: 0.76)
        ]
        let horizontalImage = try corrected(source, horizontal)
        try write(try sideBySide(sourceImage, horizontalImage, labels: ("Source", "Horizontal Guides")),
                  to: output.appendingPathComponent("stone-house-horizontal-guides.png"))

        // Combined Guides: both lists at once, solved verticals first.
        var combined = CameraRawPerspectiveToolState()
        combined.kind = .combinedGuides
        combined.verticalGuides = converging
        combined.horizontalGuides = horizontal.horizontalGuides
        let combinedImage = try corrected(source, combined)
        try write(try sideBySide(sourceImage, combinedImage, labels: ("Source", "Combined Guides")),
                  to: output.appendingPathComponent("stone-house-combined-guides.png"))

        // Rectangle: four corners of a face known to be rectangular, in TL, TR, BR, BL order.
        var rectangle = CameraRawPerspectiveToolState()
        rectangle.kind = .rectangle
        rectangle.rectangleCorners = [CGPoint(x: 0.24, y: 0.90), CGPoint(x: 0.76, y: 0.86),
                                      CGPoint(x: 0.72, y: 0.12), CGPoint(x: 0.28, y: 0.16)]
        let rectangleImage = try corrected(source, rectangle)
        try write(try sideBySide(sourceImage, rectangleImage, labels: ("Source", "Rectangle")),
                  to: output.appendingPathComponent("stone-house-rectangle.png"))

        // Eight Point: four segments — eight endpoints — round the same face, as top edges and bottom edges.
        var eightPoint = CameraRawPerspectiveToolState()
        eightPoint.kind = .eightPoint
        eightPoint.eightPointGuides = [
            CameraRawGeometryGuide(startX: 0.24, startY: 0.90, endX: 0.48, endY: 0.89),
            CameraRawGeometryGuide(startX: 0.52, startY: 0.88, endX: 0.76, endY: 0.86),
            CameraRawGeometryGuide(startX: 0.28, startY: 0.16, endX: 0.50, endY: 0.14),
            CameraRawGeometryGuide(startX: 0.50, startY: 0.14, endX: 0.72, endY: 0.12)
        ]
        let eightPointImage = try corrected(source, eightPoint)
        try write(try sideBySide(sourceImage, eightPointImage, labels: ("Source", "Eight Point")),
                  to: output.appendingPathComponent("stone-house-eight-point.png"))

        // Every correction did something, and the numbers are in the report.
        let sourcePixels = try MeshWarpRaster.rgba8Bytes(from: sourceImage)
        var report = ["tool,moved pixels (of \(sourcePixels.count / 4)),max channel delta"]
        for (name, image) in [("vertical", verticalImage), ("horizontal", horizontalImage),
                              ("combined", combinedImage), ("rectangle", rectangleImage),
                              ("eightPoint", eightPointImage)] {
            let pixels = try MeshWarpRaster.rgba8Bytes(from: image)
            let deltas = zip(sourcePixels, pixels).map { abs(Int($0) - Int($1)) }
            let moved = stride(from: 0, to: deltas.count, by: 4).reduce(0) { $0 + (deltas[$1] > 2 ? 1 : 0) }
            report.append("\(name),\(moved),\(deltas.max() ?? 0)")
        }
        try report.joined(separator: "\n").write(to: output.appendingPathComponent("corrections.csv"),
                                                atomically: true, encoding: .utf8)
    }

    /// Perspective Amount is the existing blend, so the same guides at 0, 50 and 100 show as identity, half and full.
    @Test func writesPerspectiveAmountBlend() throws {
        try #require(GeometryValidationFixtures.hasLocalPhotographs)
        let output = try outputDirectory()
        let source = try sampled(try photograph("window-wall.jpg"), longest: 420)
        let labels = ["Identity (Amount 0)", "Amount 50", "Amount 100"]

        var tools = CameraRawPerspectiveToolState()
        tools.kind = .verticalGuides
        tools.verticalGuides = [
            CameraRawGeometryGuide(startX: 0.28, startY: 0.02, endX: 0.36, endY: 0.98),
            CameraRawGeometryGuide(startX: 0.72, startY: 0.02, endX: 0.64, endY: 0.98)
        ]
        var images: [CGImage] = []
        for (index, amount) in [0.0, 50.0, 100.0].enumerated() {
            var settings = CameraRawSettings()
            settings.perspectiveTools = tools
            settings.geometry.perspectiveAmount = amount
            settings.automaticHorizonAngle = nil
            let image = try settings.applyResult(source).image
            images.append(image)
            try write(image, to: output.appendingPathComponent("amount-\(Int(amount)).png"))
            _ = index
        }
        try write(try contactRow(images, labels: labels, tileHeight: 260),
                  to: output.appendingPathComponent("window-wall-perspective-amount.png"))
    }

    private func contactRow(_ images: [CGImage], labels: [String], tileHeight: Int) throws -> CGImage {
        let padding = 10, labelHeight = 20
        let scale = Double(tileHeight) / Double(images[0].height)
        let width = Int((Double(images[0].width) * scale).rounded())
        let totalWidth = width * images.count + padding * (images.count + 1)
        let totalHeight = tileHeight + labelHeight + padding * 2
        let context = try #require(CGContext(data: nil, width: totalWidth, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        context.interpolationQuality = .high
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        for (index, image) in images.enumerated() {
            context.draw(image, in: CGRect(x: padding + index * (width + padding), y: labelHeight + padding,
                                           width: width, height: tileHeight))
            let attributed = NSAttributedString(string: labels[index], attributes: [
                .font: font, .foregroundColor: NSColor(white: 0.92, alpha: 1)
            ])
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.textPosition = CGPoint(x: CGFloat(padding + index * (width + padding)), y: 5)
        }
        return try #require(context.makeImage())
    }
}
