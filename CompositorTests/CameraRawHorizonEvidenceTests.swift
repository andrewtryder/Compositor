import AppKit
import Foundation
import Testing
@testable import Compositor

/// Milestone 10.4: renders the before/after pictures the report cites.
///
/// These are not UI screenshots. They are the real Camera Raw pipeline, run on the checked-in
/// `work/geometry-validation/originals` photographs through `CameraRawSettings.applyResult`, which is what the
/// panel previews and what Apply commits. Where a UI-automation acceptance run is blocked (see the report), these
/// are the honest substitute for "what the person sees": the same code path, the same photographs, the same
/// Horizon settings the controls write.
///
/// The test host is the sandboxed app, so it cannot write into the checkout. It leaves the pictures in the app's
/// container and `scripts/horizon-evidence.sh` copies them next to the report.
///
/// The photographs are untracked, so a checkout without them skips rather than failing or inventing a picture.
@MainActor
struct CameraRawHorizonEvidenceTests {
    /// Where the test writes its pictures.
    private func outputDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["M10_4_EVIDENCE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CompositorM10_4Evidence", isDirectory: true)
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

    /// One row of pictures, each labeled underneath, on a neutral background.
    ///
    /// A plain context, not `BrushRaster.context`: that one flips the CTM for drawing user-space images, which
    /// renders `CTLine` text mirrored. Here the default y-up space is what the label positions are written for.
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
            // y up: the tile sits above its label.
            context.draw(image, in: CGRect(x: x, y: labelHeight + padding, width: width, height: tileHeight))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(white: 0.85, alpha: 1)
            ]
            let text = NSAttributedString(string: label, attributes: attributes)
            let line = CTLineCreateWithAttributedString(text)
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

    /// Off, a 3° Angle, Amount 50, and the same tilt handed to Horizontal Reference.
    ///
    /// The reference line is drawn 3° down to the right in the panel's own lower-left normalized coordinates, so
    /// Horizontal Reference has to recover the same 3° the Angle control was given. The two pictures matching is
    /// the point: the reference path and the angle path are one rotation, not two.
    @Test func writesContactsSheetsForAngleReferenceAndAmount() throws {
        try #require(GeometryValidationFixtures.hasLocalPhotographs,
                     "the untracked geometry photographs are not in this checkout")
        let output = try outputDirectory()

        for name in ["window-wall.jpg", "stone-house.jpg"] {
            let source = try sampled(try photograph(name), longest: 520)
            let stem = name.replacingOccurrences(of: ".jpg", with: "")

            var off = CameraRawSettings()
            off.automaticHorizonAngle = nil
            let offImage = try off.applyResult(source).image

            var angle = CameraRawSettings()
            angle.horizon.mode = .angle
            angle.horizon.angleDegrees = 3
            let angleImage = try angle.applyResult(source).image

            var half = angle
            half.horizon.amount = 50
            half.automaticHorizonAngle = nil
            let halfImage = try half.applyResult(source).image

            // 3° down to the right, converted from normalized space to keep the drawn slope true on this frame.
            var reference = CameraRawSettings()
            reference.horizon.mode = .horizontalReference
            reference.horizon.referenceStartX = 0.10
            reference.horizon.referenceStartY = 0.70
            reference.horizon.referenceEndX = 0.90
            reference.horizon.referenceEndY = 0.70 - tan(3 * Double.pi / 180) * 0.80
                * Double(source.width) / Double(source.height)
            let referenceImage = try reference.applyResult(source).image

            let sheet = try contactSheet([
                ("Off (identity)", offImage),
                ("Angle 3°", angleImage),
                ("Angle 3°, Amount 50", halfImage),
                ("Horizontal Reference, same 3° line", referenceImage)
            ])
            try write(sheet, to: output.appendingPathComponent("\(stem)-horizon.png"))
        }
    }

    /// The equivalences the report states, measured on a photograph rather than a synthetic gradient.
    @Test func offIsIdentityAndReferenceRecoversTheAnglesOwnRotation() throws {
        try #require(GeometryValidationFixtures.hasLocalPhotographs)
        let source = try sampled(try photograph("window-wall.jpg"), longest: 400)
        let sourcePixels = try MeshWarpRaster.rgba8Bytes(from: source)

        // Off, with no Automatic measurement, is the identity: not one byte moves.
        var off = CameraRawSettings()
        off.automaticHorizonAngle = nil
        #expect(try MeshWarpRaster.rgba8Bytes(from: try off.applyResult(source).image) == sourcePixels)

        // A rotation the reference line can reproduce exactly, so the two paths must agree bit for bit.
        var angle = CameraRawSettings()
        angle.horizon.mode = .angle
        angle.horizon.angleDegrees = 3
        let anglePixels = try MeshWarpRaster.rgba8Bytes(from: try angle.applyResult(source).image)
        #expect(anglePixels != sourcePixels, "the correction did something")

        var reference = CameraRawSettings()
        reference.horizon.mode = .horizontalReference
        reference.horizon.referenceStartX = 0.10
        reference.horizon.referenceStartY = 0.70
        // Exactly 3° of slope in pixel space, which is what referenceAngle measures.
        let rise = tan(3 * Double.pi / 180) * 0.80 * Double(source.width)
        reference.horizon.referenceEndX = 0.90
        reference.horizon.referenceEndY = 0.70 - rise / Double(source.height)
        let referencePixels = try MeshWarpRaster.rgba8Bytes(from: try reference.applyResult(source).image)

        // Both paths resolve to the same angle and so land on the same grid.
        let delta = zip(anglePixels, referencePixels).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(delta <= 1, "the reference path and the angle path are the same rotation (max delta \(delta))")
    }
}
