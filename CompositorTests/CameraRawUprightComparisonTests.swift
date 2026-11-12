import AppKit
import ImageIO
import Testing
@testable import Compositor

/// Renders the local validation corpus through the real geometry path.
/// The folder is created on this machine; CI has nothing to render and returns.
@MainActor
struct CameraRawUprightComparisonTests {
    private let root = URL(fileURLWithPath: "/Users/atr/code/Compositor/work/geometry-validation", isDirectory: true)

    @Test func renderComparisonCorpus() throws {
        let input = root.appendingPathComponent("input")
        guard FileManager.default.fileExists(atPath: input.path) else { return }
        let output = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("geometry-validation-out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: input.path)
            .filter { $0.hasSuffix(".png") && !$0.hasPrefix(".") }
            .sorted()
        var rows: [[String: Any]] = []
        for name in names {
            let url = input.appendingPathComponent(name)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let started = CFAbsoluteTimeGetCurrent()
            let full = CameraRawUprightDetection.observe(in: image, mode: .autoFull)
            let vertical = CameraRawUprightDetection.observe(in: image, mode: .autoVertical)
            let level = CameraRawUprightDetection.observe(in: image, mode: .autoLevel)
            let detect = (CFAbsoluteTimeGetCurrent() - started) * 1000
            var settings = CameraRawGeometrySettings()
            settings.upright = .autoFull
            settings.guides = full.guides
            settings.constrainCrop = false
            let rendered = try settings.apply(image)
            try writePNG(rendered, to: output.appendingPathComponent(name))
            let measured = try axisMeasure(rendered)
            rows.append([
                "file": name,
                "width": image.width,
                "height": image.height,
                "detectMilliseconds": (detect * 10).rounded() / 10,
                "extractMilliseconds": (full.lineExtractionMilliseconds * 10).rounded() / 10,
                "fitMilliseconds": (full.vanishingMilliseconds * 10).rounded() / 10,
                "solveMilliseconds": (full.solveMilliseconds * 10).rounded() / 10,
                "full": summary(full),
                "vertical": summary(vertical),
                "level": summary(level),
                "opaqueFraction": (measured.opaque * 1000).rounded() / 1000,
                "renderedVerticalError": measured.vertical,
                "renderedHorizontalError": measured.horizontal,
            ])
            if name == "synthetic-strong-vertical.png" {
                #expect(full.fallback != .identity)
                #expect(full.residualDegrees < 1.25)
            }
            if name == "synthetic-no-lines.png" {
                #expect(full.fallback == .identity)
                #expect(full.guides.isEmpty)
            }
        }
        let viewpoint = root.appendingPathComponent("viewpoint")
        var comparisons: [[String: Any]] = []
        if FileManager.default.fileExists(atPath: viewpoint.path) {
            for name in names {
                let url = viewpoint.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                let measured = try axisMeasure(image)
                comparisons.append([
                    "file": name,
                    "width": image.width,
                    "height": image.height,
                    "opaqueFraction": (measured.opaque * 1000).rounded() / 1000,
                    "renderedVerticalError": measured.vertical,
                    "renderedHorizontalError": measured.horizontal,
                ])
            }
        }
        let payload: [String: Any] = ["compositor": rows, "viewpoint": comparisons]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("results.json"))
        #expect(!rows.isEmpty)
    }

    /// Three real photographs, each as the camera JPEG and as the metadata-stripped derivative.
    /// Volume and Constrain Crop stay off. Missing files skip that case so CI stays empty.
    @Test func renderPhotographicModes() throws {
        let cases = [
            ("stone-house", "originals/stone-house.jpg"),
            ("window-wall", "originals/window-wall.jpg"),
            ("library-atrium", "originals/library-atrium.jpg"),
            ("stone-house-stripped", "input/photo-vertical-landscape.png"),
            ("window-wall-stripped", "input/photo-vertical-portrait.png"),
            ("library-atrium-stripped", "input/photo-eight-point.png"),
        ]
        let output = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("geometry-validation-photos")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for (id, relative) in cases {
            let url = root.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            for mode in [CameraRawUprightMode.autoLevel, .autoVertical, .autoFull] {
                let observation = CameraRawUprightDetection.observe(in: image, mode: mode)
                var settings = CameraRawGeometrySettings()
                settings.upright = mode
                settings.guides = observation.guides
                settings.constrainCrop = false
                let rendered = try settings.apply(image)
                let slug: String
                switch mode {
                case .autoLevel: slug = "auto-level"
                case .autoVertical: slug = "auto-vertical"
                case .autoFull: slug = "auto-full"
                default: slug = "other"
                }
                let name = "\(id)__\(slug).png"
                try writePNG(rendered, to: output.appendingPathComponent(name))
                let measured = try axisMeasure(rendered)
                rows.append([
                    "id": id,
                    "source": relative,
                    "mode": mode.rawValue,
                    "file": name,
                    "sourceWidth": image.width,
                    "sourceHeight": image.height,
                    "width": rendered.width,
                    "height": rendered.height,
                    "fallback": observation.fallback.rawValue,
                    "confidence": (observation.confidence * 1000).rounded() / 1000,
                    "residualDegrees": (observation.residualDegrees * 1000).rounded() / 1000,
                    "supportingLines": observation.supportingLines,
                    "guides": observation.guides.count,
                    "note": observation.note,
                    "extractMilliseconds": (observation.lineExtractionMilliseconds * 10).rounded() / 10,
                    "fitMilliseconds": (observation.vanishingMilliseconds * 10).rounded() / 10,
                    "solveMilliseconds": (observation.solveMilliseconds * 10).rounded() / 10,
                    "coverage": (observation.coverage * 1000).rounded() / 1000,
                    "retainedFraction": (observation.retainedFraction * 1000).rounded() / 1000,
                    "inscribedFraction": (observation.inscribedFraction * 1000).rounded() / 1000,
                    "opaqueFraction": (measured.opaque * 1000).rounded() / 1000,
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("modes.json"))
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("originals/window-wall.jpg").path) {
            #expect(rows.contains { ($0["id"] as? String) == "window-wall" })
            let full = rows.first { $0["id"] as? String == "window-wall" && $0["mode"] as? String == "Auto Full" }
            let vertical = rows.first { $0["id"] as? String == "window-wall" && $0["mode"] as? String == "Auto Vertical" }
            #expect(full?["fallback"] as? String == "vertical")
            #expect((full?["note"] as? String)?.contains("kept verticals") == true)
            let fullOpaque = full?["opaqueFraction"] as? Double ?? 0
            let verticalOpaque = vertical?["opaqueFraction"] as? Double ?? 0
            // The two-family warp was the defect. Auto Full should keep the vertical correction.
            #expect(fullOpaque > 0.90)
            #expect(verticalOpaque > 0.90)
            #expect(abs(fullOpaque - verticalOpaque) < 0.04)
            let strippedFull = rows.first { $0["id"] as? String == "window-wall-stripped" && $0["mode"] as? String == "Auto Full" }
            let strippedVertical = rows.first { $0["id"] as? String == "window-wall-stripped" && $0["mode"] as? String == "Auto Vertical" }
            #expect(strippedFull?["fallback"] as? String == "vertical")
            let strippedOpaque = strippedFull?["opaqueFraction"] as? Double ?? 0
            let strippedVerticalOpaque = strippedVertical?["opaqueFraction"] as? Double ?? 0
            #expect(strippedOpaque > 0.84)
            #expect(abs(strippedOpaque - strippedVerticalOpaque) < 0.04)
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("originals/stone-house.jpg").path) {
            let stone = rows.first { $0["id"] as? String == "stone-house" && $0["mode"] as? String == "Auto Full" }
            #expect(stone?["fallback"] as? String == "identity")
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("originals/library-atrium.jpg").path) {
            let library = rows.first { $0["id"] as? String == "library-atrium" && $0["mode"] as? String == "Auto Full" }
            #expect(library?["fallback"] as? String == "level")
        }
    }

    private func summary(_ observation: CameraRawUprightObservation) -> [String: Any] {
        [
            "fallback": observation.fallback.rawValue,
            "confidence": (observation.confidence * 1000).rounded() / 1000,
            "residualDegrees": (observation.residualDegrees * 1000).rounded() / 1000,
            "coverage": (observation.coverage * 1000).rounded() / 1000,
            "retainedFraction": (observation.retainedFraction * 1000).rounded() / 1000,
            "inscribedFraction": (observation.inscribedFraction * 1000).rounded() / 1000,
            "supportingLines": observation.supportingLines,
            "guides": observation.guides.count,
            "note": observation.note,
        ]
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ExportError.render
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) { throw ExportError.render }
    }

    /// Strongest near-axis edge, in degrees away from plumb or level. Nil when nothing strong is there.
    private func axisMeasure(_ image: CGImage) throws -> (vertical: Double, horizontal: Double, opaque: Double) {
        let width = image.width, height = image.height
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data else { return (0, 0, 0) }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = context.bytesPerRow
        var opaque = 0
        var gray = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = bytes + y * rowBytes
            for x in 0..<width {
                let pixel = row + x * 4
                let alpha = Int(pixel[3])
                if alpha >= 240 { opaque += 1 }
                if alpha == 0 { continue }
                gray[y * width + x] = (0.2126 * Float(pixel[0]) + 0.7152 * Float(pixel[1]) + 0.0722 * Float(pixel[2]))
            }
        }
        let diagonal = Int(hypot(Double(width), Double(height)).rounded(.up))
        let thetaCount = 180
        var bins = [Int](repeating: 0, count: thetaCount * (diagonal * 2 + 1))
        let step = max(2, min(width, height) / 400)
        for y in stride(from: 1, to: height - 1, by: step) {
            for x in stride(from: 1, to: width - 1, by: step) {
                let index = y * width + x
                let gx = gray[index + 1] - gray[index - 1]
                let gy = gray[index + width] - gray[index - width]
                guard hypot(gx, gy) > 50 else { continue }
                for theta in 0..<thetaCount {
                    let radians = Double(theta) * .pi / 180
                    let rho = Double(x) * cos(radians) + Double(y) * sin(radians)
                    let slot = Int(rho.rounded()) + diagonal
                    guard slot >= 0, slot <= diagonal * 2 else { continue }
                    bins[theta * (diagonal * 2 + 1) + slot] += 1
                }
            }
        }
        func peak(thetas: [Int]) -> Double {
            var best = 0
            var bestTheta = thetas[0]
            for theta in thetas {
                let row = bins[(theta * (diagonal * 2 + 1))..<((theta + 1) * (diagonal * 2 + 1))]
                let votes = row.max() ?? 0
                if votes > best {
                    best = votes
                    bestTheta = theta
                }
            }
            guard best > 25 else { return -1 }
            return Double(bestTheta)
        }
        let verticalTheta = peak(thetas: Array(70..<111))
        let horizontalTheta = peak(thetas: Array(0..<21) + Array(160..<180))
        let verticalError = verticalTheta < 0 ? -1 : abs(verticalTheta - 90)
        let horizontalError = horizontalTheta < 0 ? -1 : min(horizontalTheta, 180 - horizontalTheta)
        let fraction = Double(opaque) / Double(max(1, width * height))
        return (verticalError, horizontalError, fraction)
    }
}
