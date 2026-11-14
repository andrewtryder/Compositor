import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Integration performance samples. Writes medians to the worktree reports folder (not /tmp).
@Suite(.serialized)
@MainActor
struct UnifiedGeometryPerformanceTests {
    private func solid(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(red: 0.7, green: 0.35, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private func measure(_ body: () throws -> Void) rethrows -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        try body()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    @Test func captureIntegratedBackendMedians() async throws {
        var lines: [String] = [
            "# Milestone 8.6 — Integrated backend performance",
            "",
            "Measured on-device via `UnifiedGeometryPerformanceTests` (wall-clock milliseconds, medians of 5 runs after 1 warm-up).",
            "Metal kernel-only times are not treated as full interaction latency.",
            "",
        ]

        let sizes = [(1024, 1024), (4000, 3000), (6000, 4000)]
        for (width, height) in sizes {
            // Cap very large sizes if the host cannot allocate; still report what ran.
            guard width * height <= DocumentLimits.documentPixelBudget / 4 else {
                lines.append("- \(width)×\(height): skipped (budget)")
                continue
            }
            let source: CGImage
            do { source = try solid(width: width, height: height) }
            catch {
                lines.append("- \(width)×\(height): skipped (allocation: \(error.localizedDescription))")
                continue
            }

            var rawSettings = CameraRawSettings()
            rawSettings.geometry.upright = .off
            rawSettings.geometry.vertical = 20
            rawSettings.geometry.volumeRadial = 15
            rawSettings.geometry.framingMode = .keepOriginalSize

            // Warm-up
            _ = try? rawSettings.apply(source)

            var rawSamples: [Double] = []
            for _ in 0..<5 {
                rawSamples.append(try measure { _ = try rawSettings.apply(source) })
            }

            var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.25)
            let handle = mesh.index(column: 4, row: 4)
            var positions = mesh.positions
            positions[handle].x += 0.03
            mesh.positions = positions
            mesh.topology.writeBack(positions: positions)

            var sessionCreate: [Double] = []
            var upload: [Double] = []
            var warmPreview: [Double] = []
            var fullApply: [Double] = []

            for i in 0..<5 {
                let created = measure {
                    _ = MeshWarpEdit(layerID: UUID(), layerName: "P", image: source,
                                     transform: LayerTransform(origin: .zero,
                                                               size: CGSize(width: width, height: height)),
                                     mesh: mesh)
                }
                sessionCreate.append(created)

                let uploadStart = CFAbsoluteTimeGetCurrent()
                if let gpu = MetalMeshWarpSession(image: source) {
                    if i == 0 { upload.append((CFAbsoluteTimeGetCurrent() - uploadStart) * 1000) }
                    var sample = MetalMeshWarpSession.Sample()
                    warmPreview.append(measure {
                        _ = gpu.render(mesh: mesh, sample: &sample, wait: true)
                    })
                }

                var rasterTiming = MeshWarpRaster.Timing()
                fullApply.append(measure {
                    _ = MeshWarpRaster.apply(source: source, mesh: mesh, timing: &rasterTiming)
                })
            }

            // Adaptive triangle update
            var adaptive = mesh
            if let face = adaptive.topology.rootFaceIDs.first {
                _ = adaptive.subdivide(faceIDs: [face])
            }
            var triangleUpdate: [Double] = []
            for _ in 0..<5 {
                triangleUpdate.append(measure {
                    _ = adaptive.triangles()
                })
            }

            lines.append("## \(width)×\(height)")
            lines.append("- Camera Raw full-res apply median: \(String(format: "%.2f", median(rawSamples))) ms")
            lines.append("- Mesh session create median: \(String(format: "%.2f", median(sessionCreate))) ms")
            if !upload.isEmpty {
                lines.append("- GPU source upload (first session): \(String(format: "%.2f", upload[0])) ms")
            }
            if !warmPreview.isEmpty {
                lines.append("- Warm GPU mesh preview median: \(String(format: "%.2f", median(warmPreview))) ms")
            }
            lines.append("- Adaptive triangle-buffer update median: \(String(format: "%.2f", median(triangleUpdate))) ms")
            lines.append("- Full-resolution mesh Apply (CPU raster) median: \(String(format: "%.2f", median(fullApply))) ms")
            lines.append("")
        }

        // Project save/reload at modest size
        let image = try solid(width: 512, height: 512)
        let session = EditorSession()
        session.createDocument(width: 512, height: 512)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Perf"))
        session.beginMeshWarp(preset: .points8)
        if let edit = session.meshWarpEdit {
            var mesh = edit.mesh
            let h = mesh.index(column: 4, row: 4)
            mesh.positions[h].x += 0.02
            mesh.topology.writeBack(positions: mesh.positions)
            edit.mesh = mesh
            session.applyMeshWarp()
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m86-perf-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try #require(session.projectSnapshot())
        var saveSamples: [Double] = []
        var loadSamples: [Double] = []
        for _ in 0..<3 {
            let saveStart = CFAbsoluteTimeGetCurrent()
            try await ProjectStore.shared.save(snapshot, to: url)
            saveSamples.append((CFAbsoluteTimeGetCurrent() - saveStart) * 1000)
            let loadStart = CFAbsoluteTimeGetCurrent()
            _ = try await ProjectStore.shared.load(from: url)
            loadSamples.append((CFAbsoluteTimeGetCurrent() - loadStart) * 1000)
        }
        lines.append("## Project save/reload (512×512 with reshape)")
        lines.append("- Save median: \(String(format: "%.2f", median(saveSamples))) ms")
        lines.append("- Load median: \(String(format: "%.2f", median(loadSamples))) ms")
        lines.append("")

        // Write benchmark output to a writable temporary test-artifacts directory so the test
        // runs independently of repository write permissions. The checked-in report, if any,
        // is updated as a separate explicit operation.
        let report = FileManager.default.temporaryDirectory
            .appendingPathComponent("MILESTONE_8_6_PERF-\(UUID().uuidString).txt")
        try lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: report.path))
        // Validation: the output location must be in the user's temp directory, never inside
        // the (possibly read-only) source tree.
        #expect(report.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                "benchmark output must not be written into the source tree")
    }
}
