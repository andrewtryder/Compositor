import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Production Apply / stack render timings for M8.7. Writes medians to the reports folder.
@Suite(.serialized)
@MainActor
struct NonDestructiveGeometryPerformanceTests {
    private func solid(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(red: 0.65, green: 0.4, blue: 0.25, alpha: 1)
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

    private func warped(_ mesh: MeshWarpGrid) -> MeshWarpGrid {
        var mesh = mesh
        let handle = mesh.index(column: mesh.pointColumns / 2, row: mesh.pointRows / 2)
        var positions = mesh.positions
        positions[handle].x += 0.03
        mesh.positions = positions
        mesh.topology.writeBack(positions: positions)
        return mesh
    }

    @Test func captureApplyAndStackMedians() throws {
        var lines: [String] = [
            "# Milestone 8.7 — Non-destructive geometry performance",
            "",
            "Wall-clock milliseconds, medians of 5 runs after 1 warm-up.",
            "GPU kernel-only times are not treated as full Apply latency.",
            "",
        ]

        let sizes = [(1024, 1024), (4000, 3000), (6000, 4000)]
        for (width, height) in sizes {
            guard width * height <= DocumentLimits.documentPixelBudget / 4 else {
                lines.append("- \(width)×\(height): skipped (budget)")
                continue
            }
            let source: CGImage
            do { source = try solid(width: width, height: height) }
            catch {
                lines.append("- \(width)×\(height): skipped (\(error.localizedDescription))")
                continue
            }

            let mesh = warped(MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.25))
            let transform = LayerTransform(origin: .zero, size: CGSize(width: width, height: height))

            // Warm-up MeshWarpEdit commitImage (production Apply path).
            let warmEdit = MeshWarpEdit(layerID: UUID(), layerName: "P", image: source,
                                        transform: transform, mesh: mesh)
            var warmSample = MeshWarpRenderer.Sample()
            _ = warmEdit.commitImage(sample: &warmSample)

            var sessionCreate: [Double] = []
            var initialUpload: [Double] = []
            var triangleUpload: [Double] = []
            var warmGPU: [Double] = []
            var readback: [Double] = []
            var fullCommit: [Double] = []
            var cpuFallback: [Double] = []
            var stackTwoNode: [Double] = []
            var stackCacheHit: [Double] = []
            var usedMetalCommit = false

            for i in 0..<5 {
                sessionCreate.append(measure {
                    _ = MeshWarpEdit(layerID: UUID(), layerName: "P", image: source,
                                     transform: transform, mesh: mesh)
                })

                let uploadStart = CFAbsoluteTimeGetCurrent()
                let edit = MeshWarpEdit(layerID: UUID(), layerName: "P", image: source,
                                        transform: transform, mesh: mesh)
                if i == 0 {
                    initialUpload.append((CFAbsoluteTimeGetCurrent() - uploadStart) * 1000)
                }

                if let gpu = MetalMeshWarpSession(image: source) {
                    var gpuSample = MetalMeshWarpSession.Sample()
                    warmGPU.append(measure {
                        _ = gpu.render(mesh: mesh, sample: &gpuSample, wait: true)
                    })
                    triangleUpload.append(gpuSample.triangleUploadMilliseconds)
                    var metalSample = MetalMeshWarp.Sample()
                    readback.append(measure {
                        _ = gpu.readbackCGImage(sample: &metalSample)
                    })
                }

                var sample = MeshWarpRenderer.Sample()
                fullCommit.append(measure {
                    _ = edit.commitImage(sample: &sample)
                })
                usedMetalCommit = usedMetalCommit || sample.usedMetal

                var cpuTiming = MeshWarpRaster.Timing()
                cpuFallback.append(measure {
                    _ = MeshWarpRaster.apply(source: source, mesh: mesh, timing: &cpuTiming)
                })

                var cr = CameraRawGeometryBackendSettings()
                cr.geometry.upright = .off
                cr.geometry.vertical = 18
                cr.geometry.framingMode = .keepOriginalSize
                var stack = LayerCorrectionStack(
                    source: ImportedImage(image: source, thumbnail: source, name: "P"),
                    nodes: [
                        .cameraRawGeometry(cr),
                        .reshape(mesh: mesh, imageWidth: width, imageHeight: height)
                    ])
                stackTwoNode.append(try measure {
                    _ = try LayerCorrectionRenderer.render(&stack, options: .init(useCache: false))
                })
                // Second render should hit both stage caches when revision unchanged.
                stackCacheHit.append(try measure {
                    _ = try LayerCorrectionRenderer.render(&stack, options: .init(useCache: true))
                })
            }

            lines.append("## \(width)×\(height)")
            lines.append("- MeshWarpEdit session create median: \(String(format: "%.2f", median(sessionCreate))) ms")
            if !initialUpload.isEmpty {
                lines.append("- Initial source upload (first MeshWarpEdit): \(String(format: "%.2f", initialUpload[0])) ms")
            }
            if !triangleUpload.isEmpty {
                lines.append("- Mesh triangle upload median: \(String(format: "%.2f", median(triangleUpload))) ms")
            }
            if !warmGPU.isEmpty {
                lines.append("- Warm GPU mesh render median: \(String(format: "%.2f", median(warmGPU))) ms")
            }
            if !readback.isEmpty {
                lines.append("- GPU readback to CGImage median: \(String(format: "%.2f", median(readback))) ms")
            }
            lines.append("- Full MeshWarpEdit.commitImage median: \(String(format: "%.2f", median(fullCommit))) ms (usedMetal=\(usedMetalCommit))")
            lines.append("- CPU MeshWarpRaster fallback median: \(String(format: "%.2f", median(cpuFallback))) ms")
            lines.append("- Two-node stack render (CR→ReShape, no cache) median: \(String(format: "%.2f", median(stackTwoNode))) ms")
            lines.append("- Two-node stack render (cache hit) median: \(String(format: "%.2f", median(stackCacheHit))) ms")
            lines.append("")
        }

        let report = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("work/geometry-validation/reports/MILESTONE_8_7_PERF.txt")
        try lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: report.path))
    }
}
