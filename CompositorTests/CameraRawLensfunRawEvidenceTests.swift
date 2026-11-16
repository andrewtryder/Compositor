import AppKit
import CoreImage
import Testing
@testable import Compositor

/// Milestone 10.6 §12: a real RAW photograph through the real pipeline, with a Lensfun profile that
/// genuinely matches the lens the file records.
///
/// The fixture is an untracked CR2 beside the other originals (`sigma-40art-sample.CR2`, a Sigma 40mm
/// F1.4 Art on an EOS 5DS R at f/1.4). Its lens is calibrated in Lensfun's published database for
/// vignetting (pa), so the Apple → Lensfun → Off comparison below is a calibrated one on RAW pixels.
/// The file's own bytes are read-only here; nothing overwrites it.
///
/// The test is skipped when the fixture or the XML is absent, so a checkout without them reports skipped
/// rather than inventing output. The decode uses `CIRAWFilter` directly with the lens-correction switch
/// off, which is the decode state the double-correction policy requires for a Lensfun pass.
@MainActor
struct CameraRawLensfunRawEvidenceTests {
    private func outputDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["M10_6_EVIDENCE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CompositorM10_6Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var root: URL? { GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") }

    /// The corrected image a decode setting produces, at a manageable preview size.
    private func developed(_ url: URL, lensCorrection: Bool, longest: CGFloat) throws -> (CGImage, LensMetadata) {
        guard let filter = CIRAWFilter(imageURL: url) else { throw ExportError.render }
        filter.isLensCorrectionEnabled = lensCorrection
        filter.scaleFactor = Float(longest / max(filter.nativeSize.width, filter.nativeSize.height))
        guard let output = filter.outputImage else { throw ExportError.render }
        let context = CIContext()
        guard let cg = context.createCGImage(output, from: output.extent) else { throw ExportError.render }
        let source = CGImageSourceCreateWithData(try Data(contentsOf: url) as CFData, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any] ?? [:]
        return (cg, LensMetadata(imageProperties: properties))
    }

    private func difference(_ a: CGImage, _ b: CGImage) throws -> (maxChannelDelta: Int, changedFraction: Double) {
        let left = try MeshWarpRaster.rgba8Bytes(from: a)
        let right = try MeshWarpRaster.rgba8Bytes(from: b)
        var maximum = 0
        var changed = 0
        for pixel in 0..<(a.width * a.height) {
            let i = pixel * 4
            let delta = max(abs(Int(left[i]) - Int(right[i])), abs(Int(left[i + 1]) - Int(right[i + 1])),
                            abs(Int(left[i + 2]) - Int(right[i + 2])))
            if delta > maximum { maximum = delta }
            if delta > 0 { changed += 1 }
        }
        return (maximum, Double(changed) / Double(a.width * a.height))
    }

    private func sideBySide(_ before: CGImage, _ after: CGImage, labels: (String, String)) throws -> CGImage {
        let padding = 12, labelHeight = 22
        let scale = Double(420) / Double(before.height)
        let width = Int((Double(before.width) * scale).rounded())
        let totalWidth = width * 2 + padding * 3
        let totalHeight = 420 + labelHeight + padding * 2
        let context = try #require(CGContext(data: nil, width: totalWidth, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        context.interpolationQuality = .high
        context.draw(before, in: CGRect(x: padding, y: labelHeight + padding, width: width, height: 420))
        context.draw(after, in: CGRect(x: padding * 2 + width, y: labelHeight + padding, width: width, height: 420))
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for (index, label) in [labels.0, labels.1].enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
                .font: font, .foregroundColor: NSColor(cgColor: CGColor(gray: 0.92, alpha: 1)) as Any
            ]))
            context.textPosition = CGPoint(x: CGFloat(padding + index * (width + padding)), y: CGFloat(padding) / 2)
            CTLineDraw(line, context)
        }
        return try #require(context.makeImage())
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// Apple Native (decoder lens correction on), Lensfun (decoder correction off, calibrated pass on),
    /// and Off (decoder correction off, no pass). Each pair rendered from the same CR2 bytes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COMPOSITOR_RAW_FIXTURE_PATH"] != nil
                    || GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked RAW fixture is not in this checkout"))
    func writesRawAppleLensfunAndOffBesideSource() throws {
        let root = try #require(root)
        let rawURL = root.appendingPathComponent("originals/sigma-40art-sample.CR2")
        let databaseFolder = root.appendingPathComponent("originals/lensfun-evidence-db")
        let files = try #require(try? FileManager.default.contentsOfDirectory(at: databaseFolder,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter { $0.pathExtension == "xml" },
            "the Lensfun XML files must be imported beside the originals")
        var database = LensfunDatabase()
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let parsed = try LensfunDatabase.parse(try Data(contentsOf: file))
            database.formatVersion = max(database.formatVersion, parsed.formatVersion)
            database.cameras.append(contentsOf: parsed.cameras)
            database.lenses.append(contentsOf: parsed.lenses)
            for (mount, compatible) in parsed.mounts { database.mounts[mount] = compatible }
        }
        database.fileCount = files.count

        let output = try outputDirectory()

        // Apple Native: the decoder's own correction, on by default where the camera is supported.
        let (apple, metadata) = try developed(rawURL, lensCorrection: true, longest: 1000)
        // Lensfun: the same RAW decoded with the decoder's correction off, so the calibrated pass owns
        // the distortion. This is the decode the policy requires — not a UI toggle over corrected pixels.
        let (developedOff, _) = try developed(rawURL, lensCorrection: false, longest: 1000)
        var settings = CameraRawSettings()
        settings.optics.lensProfile.provider = .lensfun
        let lensfun = try settings.applyResult(developedOff, lensMetadata: metadata, lensfunDatabase: database,
                                               policySource: .redevelopableRaw, appleCorrectionActive: false).image
        // Off: the same decode, nothing correcting.
        var offSettings = CameraRawSettings()
        offSettings.optics.lensProfile.provider = .off
        let off = try offSettings.applyResult(developedOff, lensMetadata: metadata, lensfunDatabase: database,
                                              policySource: .redevelopableRaw, appleCorrectionActive: false).image

        let resolution = CameraRawLensfun.resolve(settings: settings.optics.lensProfile, metadata: metadata,
                                                  database: database, policySource: .redevelopableRaw,
                                                  appleCorrectionActive: false)
        if resolution.correction == nil {
            let match = database.match(metadata)
            print("PROBE camera:", database.cameras(matching: metadata).map(\.description))
            print("PROBE named:", database.lenses(matching: metadata).map(\.description))
            print("PROBE issue:", match.issue as Any, "lens:", match.lens?.description as Any)
            print("PROBE metadata:", metadata)
            print("PROBE database lenses:", database.lenses.count, "cameras:", database.cameras.count)
        }
        let correction = try #require(resolution.correction, "the 40mm Art must resolve at 40 mm f/1.4")

        let appleDelta = try difference(off, apple)
        let lensfunDelta = try difference(developedOff, lensfun)
        let decoderSupportsCorrection = CIRAWFilter(imageURL: rawURL)?.isLensCorrectionSupported ?? false
        #expect(lensfunDelta.maxChannelDelta > 0, "the calibrated pass must change RAW pixels")

        var csv = "state,lens profile,decoder lens correction,max channel delta,changed fraction\n"
        csv += "Apple Native,\(decoderSupportsCorrection ? "supported by the decoder" : "not supported for this camera"),on,\(appleDelta.maxChannelDelta),\(String(format: "%.4f", appleDelta.changedFraction))\n"
        csv += "Lensfun,\(correction.lensDescription),off,\(lensfunDelta.maxChannelDelta),\(String(format: "%.4f", lensfunDelta.changedFraction))\n"
        csv += "Off,,off,0,0.0000\n"
        try csv.write(to: output.appendingPathComponent("raw-evidence.csv"), atomically: true, encoding: .utf8)

        try write(try sideBySide(developedOff, lensfun, labels: ("Off", "Lensfun (calibrated)")),
                  to: output.appendingPathComponent("raw-40art-off-vs-lensfun.png"))
        try write(try sideBySide(developedOff, apple, labels: ("Off", "Apple Native (decoder)")),
                  to: output.appendingPathComponent("raw-40art-off-vs-apple.png"))
        try write(try sideBySide(apple, lensfun, labels: ("Apple Native", "Lensfun")),
                  to: output.appendingPathComponent("raw-40art-apple-vs-lensfun.png"))
    }
}
