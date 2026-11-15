import AppKit
import Foundation
import Testing
@testable import Compositor

/// Milestone 10.6: renders the calibrated Lensfun correction over the checked-in photographs, through the
/// real Camera Raw pipeline the panel previews and Apply commit.
///
/// The photographs are JPEGs, so the double-correction policy would refuse the pass on them: a rendered
/// image may already carry the camera's own correction. These tests therefore call the correction through
/// `applyResult` with the policy source a redevelopable RAW would carry, which is the exact path a RAW
/// development layer takes. That is stated here and in the report rather than hidden: the evidence shows
/// what the correction computes and looks like, not that these particular files qualify for it.
///
/// These are not UI screenshots. The interactive captures live in `work/camera-raw-parity/screenshots`;
/// this file renders the before/after pairs the report cites, and writes a CSV of measured differences so
/// the report can quote numbers instead of impressions.
///
/// The test host is the sandboxed app and cannot write into the checkout: it leaves the pictures in the
/// app's container and `scripts/lensfun-evidence.sh` copies them next to the report.
///
/// The photographs are untracked, so a checkout without them skips rather than failing or inventing a picture.
@MainActor
struct CameraRawLensfunEvidenceTests {
    private func outputDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["M10_6_EVIDENCE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CompositorM10_6Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func photograph(_ name: String) throws -> (image: CGImage, metadata: LensMetadata) {
        let root = try #require(GeometryValidationFixtures.rootContaining("originals/\(name)"),
                                "work/geometry-validation/originals/\(name)")
        let url = root.appendingPathComponent("originals/\(name)")
        let data = try Data(contentsOf: url)
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
            ?? [:]
        let rep = try #require(NSBitmapImageRep(data: data))
        return (try #require(rep.cgImage), LensMetadata(imageProperties: properties))
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

    private func crop(_ image: CGImage, center: CGPoint, size: CGSize) throws -> CGImage {
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        guard let cropped = image.cropping(to: rect) else { throw ExportError.render }
        return cropped
    }

    /// The maximum per-channel absolute difference between two images of the same size, and the fraction of
    /// pixels that differ at all. Values are 8-bit units, as the evidence CSV quotes.
    private func difference(_ a: CGImage, _ b: CGImage) throws -> (maxChannelDelta: Int, changedFraction: Double) {
        let width = a.width, height = a.height
        let left = try MeshWarpRaster.rgba8Bytes(from: a)
        let right = try MeshWarpRaster.rgba8Bytes(from: b)
        var maximum = 0
        var changed = 0
        let total = width * height
        for pixel in 0..<total {
            let i = pixel * 4
            let delta = max(abs(Int(left[i]) - Int(right[i])), abs(Int(left[i + 1]) - Int(right[i + 1])),
                            abs(Int(left[i + 2]) - Int(right[i + 2])))
            if delta > maximum { maximum = delta }
            if delta > 0 { changed += 1 }
        }
        return (maximum, Double(changed) / Double(total))
    }

    /// Renders the photograph through the pipeline with one provider selection and records what the
    /// resolution said, so the CSV can quote the gates and the corrections the engine chose.
    @discardableResult
    private func rendered(_ source: CGImage, metadata: LensMetadata, database: LensfunDatabase?,
                          provider: CameraRawLensProfileProvider, source_: CameraRawLensCorrectionPolicy.Source = .redevelopableRaw)
        throws -> (image: CGImage, resolution: CameraRawLensfun.Resolution) {
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = provider
        let result = try settings.applyResult(source,
                                              lensMetadata: metadata, lensfunDatabase: database,
                                              policySource: source_, appleCorrectionActive: false)
        let resolution = CameraRawLensfun.resolve(settings: settings.optics.lensProfile, metadata: metadata,
                                                  database: database, policySource: source_,
                                                  appleCorrectionActive: false)
        return (result.image, resolution)
    }

    /// The Sigma 24-70mm Art was shot at 24 mm f/3.2 on the EOS 6D and is calibrated in Lensfun's own
    /// published database (ptlens distortion, poly3 TCA): a genuine match, not a stand-in. The Tokina
    /// 16-28 is calibrated for distortion and TCA at 16 mm, which is how `stone-house` was shot.
    private func calibratedDatabase() throws -> LensfunDatabase {
        let root = try #require(GeometryValidationFixtures.rootContaining("originals/window-wall.jpg"))
        let folder = root.appendingPathComponent("originals/lensfun-evidence-db")
        let files = try #require(try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter { $0.pathExtension == "xml" },
            "work/geometry-validation/originals/lensfun-evidence-db (import the Lensfun XML files there)")
        var database = LensfunDatabase()
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let parsed = try LensfunDatabase.parse(try Data(contentsOf: file))
            database.formatVersion = max(database.formatVersion, parsed.formatVersion)
            database.cameras.append(contentsOf: parsed.cameras)
            database.lenses.append(contentsOf: parsed.lenses)
            for (mount, compatible) in parsed.mounts { database.mounts[mount] = compatible }
        }
        database.fileCount = files.count
        return database
    }

    /// One calibrated photograph, four states: Apple Native (unchanged rendering), Lensfun (the calibrated
    /// pass), Off, and the same with the database absent. Each corrected picture is written beside its
    /// source, and a CSV records what the resolution said and how much the pixels moved.
    @Test func writesCalibratedCorrectionsBesideSource() throws {
        try #require(GeometryValidationFixtures.hasLocalPhotographs,
                     "the untracked geometry photographs are not in this checkout")
        let database = try calibratedDatabase()
        let output = try outputDirectory()
        var csv = "photo,lens,provider,issue,max channel delta,changed fraction\n"

        for (name, longest) in [("window-wall.jpg", 900), ("stone-house.jpg", 900)] {
            let (full, metadata) = try photograph(name)
            let source = try sampled(full, longest: longest)
            let base = try rendered(source, metadata: metadata, database: database, provider: .appleNative)
            let lens = try #require(base.resolution.correction == nil ? metadata.lensDescription : metadata.lensDescription)

            // Lensfun with the real calibrated profile.
            let lensfun = try rendered(source, metadata: metadata, database: database, provider: .lensfun)
            let correction = lensfun.resolution.correction
            let delta = try difference(base.image, lensfun.image)

            // Off: identical to Apple Native by definition, checked rather than assumed.
            let off = try rendered(source, metadata: metadata, database: database, provider: .off)
            let offDelta = try difference(base.image, off.image)

            csv += "\(name),\(lens),Apple Native,,0,0\n"
            csv += "\(name),\(lens),Lensfun,\"\(correction?.lensDescription ?? "none")\",\(delta.maxChannelDelta),\(String(format: "%.4f", delta.changedFraction))\n"
            csv += "\(name),\(lens),Off,,\(offDelta.maxChannelDelta),\(String(format: "%.4f", offDelta.changedFraction))\n"

            try write(base.image, to: output.appendingPathComponent("\(name)-apple-native.png"))
            try write(lensfun.image, to: output.appendingPathComponent("\(name)-lensfun.png"))
            try write(try sideBySide(base.image, lensfun.image, labels: ("Apple Native", "Lensfun")),
                      to: output.appendingPathComponent("\(name)-lensfun-side-by-side.png"))

            // Corner crops, where distortion and vignetting show most: a 320-pixel square at two corners.
            if let correction {
                let names = correction.correctionNames.joined(separator: ", ")
                for (corner, label) in [(CGPoint(x: 0, y: 0), "top-left"), (CGPoint(x: source.width, y: source.height), "bottom-right")] {
                    let beforeCrop = try crop(base.image, center: corner, size: CGSize(width: 320, height: 320))
                    let afterCrop = try crop(lensfun.image, center: corner, size: CGSize(width: 320, height: 320))
                    try write(try sideBySide(beforeCrop, afterCrop, labels: ("Apple Native", "Lensfun (\(names))"), tileHeight: 240),
                              to: output.appendingPathComponent("\(name)-corner-\(label).png"))
                }
            }

            // Lensfun selected with no database: pixels must not move.
            let absent = try rendered(source, metadata: metadata, database: nil, provider: .lensfun)
            #expect(absent.resolution.correction == nil)
            let absentDelta = try difference(base.image, absent.image)
            #expect(absentDelta.maxChannelDelta == 0, "a missing database never changes pixels")
            csv += "\(name),\(lens),Lensfun without database,,\(absentDelta.maxChannelDelta),\(String(format: "%.4f", absentDelta.changedFraction))\n"
        }
        try csv.write(to: output.appendingPathComponent("lensfun-evidence.csv"), atomically: true, encoding: .utf8)
    }

    /// A refused pass, on the record: the same photograph with Apple's decode correction reported active.
    /// The picture must come out identical and the resolution must say why.
    @Test func appleCorrectionActiveLeavesPixelsUnchanged() throws {
        try #require(GeometryValidationFixtures.hasLocalPhotographs,
                     "the untracked geometry photographs are not in this checkout")
        let database = try calibratedDatabase()
        let (full, metadata) = try photograph("window-wall.jpg")
        let source = try sampled(full, longest: 900)
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        let refused = try settings.applyResult(source, lensMetadata: metadata, lensfunDatabase: database,
                                               policySource: .redevelopableRaw, appleCorrectionActive: true)
        let base = try settings.applyResult(source, lensMetadata: nil, lensfunDatabase: nil)
        let delta = try difference(base.image, refused.image)
        #expect(delta.maxChannelDelta == 0, "Apple correction active: the Lensfun pass must not run")
    }
}
