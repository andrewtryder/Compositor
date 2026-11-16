import AppKit
import Foundation
import Testing
@testable import Compositor

/// Milestone 10.7: renders the advanced ReShape evidence the report cites — selection transforms,
/// Subdivide/Merge and the three local corrections — through the real mesh pipeline on the checked-in
/// `work/geometry-validation/originals` photographs, using the same `MeshWarpEdit` session calls the
/// toolbar's new controls make.
///
/// These are not UI screenshots. `MeshWarpRenderer.apply` is the same path the canvas previews with
/// (the GPU canvas draws the identical triangle set), and the corrections are made through the same
/// `EditorSession` entry points a person drives, so this is the honest evidence a unit test can
/// produce. The interactive captures live in `work/camera-raw-parity/screenshots/m10_7-ui/`.
///
/// The test host is the sandboxed app and cannot write into the checkout: it leaves the pictures in
/// the app's container and `scripts/reshape-evidence.sh` copies them next to the report.
///
/// The photographs are untracked, so a checkout without them skips rather than failing or inventing
/// a picture.
@MainActor
struct MeshWarpEvidenceTests {
    private func outputDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["M10_7_EVIDENCE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CompositorM10_7Evidence", isDirectory: true)
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

    /// Opens a ReShape session on the photograph through the real session path.
    private func reshapeSession(_ source: CGImage) throws -> (EditorSession, MeshWarpEdit) {
        let session = EditorSession()
        session.createDocument(width: source.width, height: source.height)
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Evidence"))
        session.beginMeshWarp(preset: .points8)
        let edit = try #require(session.meshWarpEdit)
        return (session, edit)
    }

    /// One photograph, the whole exposed feature set: source, multi-select with Move, Rotate, Scale,
    /// a locally subdivided and merged mesh, Local Perspective, Local Horizon and Local Volume.
    @Test(.enabled(if: GeometryValidationFixtures.missingPhotographsReason == nil,
                   "the untracked geometry photographs are not in this checkout"))
    func writesAdvancedReshapeBesideSourceForEveryFeature() throws {
        try #require(GeometryValidationFixtures.hasLocalPhotographs,
                     "the untracked geometry photographs are not in this checkout")
        let output = try outputDirectory()
        let source = try sampled(try photograph("stone-house.jpg"), longest: 520)
        try write(source, to: output.appendingPathComponent("stone-house-source.png"))
        var report = ["feature,max channel delta vs source"]

        // Multi-select (the center 3×3 block, as a marquee would take it) moved as one group.
        do {
            let (session, edit) = try reshapeSession(source)
            for row in 3...5 {
                for column in 3...5 {
                    edit.selection.add(edit.mesh.vertexID(edit.mesh.index(column: column, row: row)))
                }
            }
            edit.beginGesture()
            #expect(edit.transformSelection(mode: .move, translation: SIMD2(0.02, -0.01)))
            edit.endGesture()
            var rasterTiming = MeshWarpRaster.Timing()
            let image = try #require(MeshWarpRaster.apply(source: source, mesh: edit.mesh, timing: &rasterTiming))
            try write(try sideBySide(source, image, labels: ("Source", "Move — 9 points")),
                      to: output.appendingPathComponent("stone-house-move-selection.png"))
            try record("move-selection", source, image, report: &report)
            session.cancelMeshWarp()
        }

        // Rotate about the selection's barycenter.
        do {
            let (session, edit) = try reshapeSession(source)
            for row in 2...4 {
                for column in 5...7 {
                    edit.selection.add(edit.mesh.vertexID(edit.mesh.index(column: column, row: row)))
                }
            }
            edit.beginGesture()
            #expect(session.meshWarpRotateSelection(by: 5 * .pi / 180))
            edit.endGesture()
            var rasterTiming = MeshWarpRaster.Timing()
            let image = try #require(MeshWarpRaster.apply(source: source, mesh: edit.mesh, timing: &rasterTiming))
            try write(try sideBySide(source, image, labels: ("Source", "Rotate 5° — 9 points")),
                      to: output.appendingPathComponent("stone-house-rotate-selection.png"))
            try record("rotate-selection", source, image, report: &report)
            session.cancelMeshWarp()
        }

        // Scale from the barycenter.
        do {
            let (session, edit) = try reshapeSession(source)
            for row in 2...5 {
                for column in 2...5 {
                    edit.selection.add(edit.mesh.vertexID(edit.mesh.index(column: column, row: row)))
                }
            }
            edit.beginGesture()
            #expect(session.meshWarpScaleSelection(by: 1.15))
            edit.endGesture()
            var rasterTiming = MeshWarpRaster.Timing()
            let image = try #require(MeshWarpRaster.apply(source: source, mesh: edit.mesh, timing: &rasterTiming))
            try write(try sideBySide(source, image, labels: ("Source", "Scale 115% — 16 points")),
                      to: output.appendingPathComponent("stone-house-scale-selection.png"))
            try record("scale-selection", source, image, report: &report)
            session.cancelMeshWarp()
        }

        // A locally subdivided mesh: two interior cells refined, everything else untouched.
        do {
            let (session, edit) = try reshapeSession(source)
            edit.selection.selectOnly(index: edit.mesh.index(column: 4, row: 4), in: edit.mesh)
            let first = edit.subdivideSelection()
            #expect(!first.succeeded.isEmpty)
            edit.selection.clear()
            edit.selection.selectOnly(index: edit.mesh.index(column: 2, row: 2), in: edit.mesh)
            let second = edit.subdivideSelection()
            #expect(!second.succeeded.isEmpty)
            var rasterTiming = MeshWarpRaster.Timing()
            let image = try #require(MeshWarpRaster.apply(source: source, mesh: edit.mesh, timing: &rasterTiming))
            try write(try sideBySide(source, image, labels: ("Source", "Subdivided ×2 (identity pixels)")),
                      to: output.appendingPathComponent("stone-house-subdivided.png"))
            try record("subdivided-identity", source, image, report: &report)
            session.cancelMeshWarp()
        }

        // A merged region: subdivide a block, then merge every complete child group back.
        do {
            let (session, edit) = try reshapeSession(source)
            edit.selection.selectOnly(index: edit.mesh.index(column: 4, row: 4), in: edit.mesh)
            let subdivided = edit.subdivideSelection()
            #expect(!subdivided.succeeded.isEmpty)
            for parent in subdivided.succeeded {
                edit.selection.clear()
                for child in edit.mesh.topology.faces[parent]!.children! {
                    for corner in edit.mesh.topology.faces[child]!.corners {
                        edit.selection.add(corner)
                    }
                }
                let merged = edit.mergeSelection()
                #expect(merged.succeeded.contains(parent))
                #expect(edit.mesh.topology.faces[parent]?.isLeaf == true)
            }
            #expect(!edit.mesh.isAdaptive, "the mesh is whole again after the merges")
            var rasterTiming = MeshWarpRaster.Timing()
            let image = try #require(MeshWarpRaster.apply(source: source, mesh: edit.mesh, timing: &rasterTiming))
            try write(try sideBySide(source, image, labels: ("Source", "Subdivided then merged (identity)")),
                      to: output.appendingPathComponent("stone-house-merged.png"))
            try record("merged-identity", source, image, report: &report)
            session.cancelMeshWarp()
        }

        // Local Perspective (combined keystone undo) over a 4×4 block.
        do {
            let (session, edit) = try reshapeSession(source)
            for row in 3...6 {
                for column in 3...6 {
                    edit.selection.add(edit.mesh.vertexID(edit.mesh.index(column: column, row: row)))
                }
            }
            let status = session.applyMeshWarpLocalCorrection(
                .perspective(MeshWarpLocalPerspective(mode: .combined, amount: 0.45)))
            #expect(status.ok, Comment(rawValue: status.reason))
            var rasterTiming = MeshWarpRaster.Timing()
            let image = try #require(MeshWarpRaster.apply(source: source, mesh: edit.mesh, timing: &rasterTiming))
            try write(try sideBySide(source, image, labels: ("Source", "Local Perspective — combined 45%")),
                      to: output.appendingPathComponent("stone-house-local-perspective.png"))
            try record("local-perspective", source, image, report: &report)
            session.cancelMeshWarp()
        }

        // Local Horizon: a reference line drawn the way the canvas drag draws it.
        do {
            let (session, edit) = try reshapeSession(source)
            for row in 2...5 {
                for column in 2...6 {
                    edit.selection.add(edit.mesh.vertexID(edit.mesh.index(column: column, row: row)))
                }
            }
            edit.mesh.stickyBorders = false
            session.meshWarpBeginHorizonReference()
            // The roofline of the stone house tilts down to the left in document space.
            let span = Double(source.width)
            session.meshWarpBeginHorizonDrag(at: CGPoint(x: span * 0.2, y: span * 0.42))
            session.meshWarpContinueHorizonDrag(to: CGPoint(x: span * 0.8, y: span * 0.38))
            session.meshWarpEndHorizonDrag()
            let horizon = try #require(session.meshWarpLocalHorizonCorrection(
                mode: .horizontalReference, angleDegrees: 0, amount: 0.6))
            let status = session.applyMeshWarpLocalCorrection(.horizon(horizon))
            #expect(status.ok, Comment(rawValue: status.reason))
            var rasterTiming = MeshWarpRaster.Timing()
            let image = try #require(MeshWarpRaster.apply(source: source, mesh: edit.mesh, timing: &rasterTiming))
            try write(try sideBySide(source, image, labels: ("Source", "Local Horizon — reference 60%")),
                      to: output.appendingPathComponent("stone-house-local-horizon.png"))
            try record("local-horizon", source, image, report: &report)
            session.cancelMeshWarp()
        }

        // Local Volume (radial) over the same kind of block. Propagation stays off so the
        // correction is local and gentle on the lattice; a strong one would fold and refuse.
        do {
            let (session, edit) = try reshapeSession(source)
            edit.mesh.propagation = 0
            for row in 3...6 {
                for column in 3...6 {
                    edit.selection.add(edit.mesh.vertexID(edit.mesh.index(column: column, row: row)))
                }
            }
            let status = session.applyMeshWarpLocalCorrection(
                .volume(MeshWarpLocalVolume(mode: .radial, strength: 0.12)))
            #expect(status.ok, Comment(rawValue: status.reason))
            var rasterTiming = MeshWarpRaster.Timing()
            let image = try #require(MeshWarpRaster.apply(source: source, mesh: edit.mesh, timing: &rasterTiming))
            try write(try sideBySide(source, image, labels: ("Source", "Local Volume — radial 12%")),
                      to: output.appendingPathComponent("stone-house-local-volume.png"))
            try record("local-volume", source, image, report: &report)
            session.cancelMeshWarp()
        }

        try report.joined(separator: "\n").write(to: output.appendingPathComponent("reshape-evidence.csv"),
                                                 atomically: true, encoding: .utf8)
    }

    private func record(_ name: String, _ source: CGImage, _ image: CGImage,
                        report: inout [String]) throws {
        let sourcePixels = try MeshWarpRaster.rgba8Bytes(from: source)
        let pixels = try MeshWarpRaster.rgba8Bytes(from: image)
        let deltas = zip(sourcePixels, pixels).map { abs(Int($0) - Int($1)) }
        report.append("\(name),-,\(deltas.max() ?? 0)")
    }
}
