import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Production Apply / stack render timings for M8.8. Writes medians to the reports folder.
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

    private func warped(_ mesh: MeshWarpGrid) -> MeshWarpGrid {
        var mesh = mesh
        let handle = mesh.index(column: mesh.pointColumns / 2, row: mesh.pointRows / 2)
        var positions = mesh.positions
        positions[handle].x += 0.03
        mesh.positions = positions
        mesh.topology.writeBack(positions: positions)
        return mesh
    }

    private func render(_ stack: inout LayerCorrectionStack,
                        options: LayerCorrectionRenderer.Options,
                        gpu: LayerCorrectionGPUContext?) throws -> LayerCorrectionRenderResult {
        var options = options
        if let gpu { options.gpuContext = gpu }
        return try LayerCorrectionRenderer.render(&stack, options: options)
    }

    private func reportPath(for size: String) -> String {
        "/Users/atr/code/Compositor-correction-stack-acceleration/work/geometry-validation/reports/MILESTONE_8_8_PERF.txt"
    }

    private func writeReport(_ lines: [String], _ path: String) throws {
        var full = lines
        if FileManager.default.fileExists(atPath: path) {
            let existing = try String(contentsOfFile: path, encoding: .utf8)
            if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                full = existing.split(separator: "\n").map(String.init) + [""] + lines
            }
        }
        try full.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func capture1024() throws {
        try capture(size: (1024, 1024), runs: 3, cpuRuns: 3)
    }

    @Test func capture4000x3000() throws {
        try capture(size: (4000, 3000), runs: 3, cpuRuns: 1)
    }

    @Test func capture6000x4000() throws {
        try capture(size: (6000, 4000), runs: 3, cpuRuns: 1)
    }

    private func capture(size: (Int, Int), runs: Int, cpuRuns: Int) throws {
        let (width, height) = size
        let path = reportPath(for: "\(width)x\(height)")
        var lines: [String] = ["## \(width)×\(height)"]
        var errors: [String] = []
        guard width * height <= DocumentLimits.documentPixelBudget / 4 else {
            lines.append("- skipped (budget)")
            try writeReport(lines, path)
            return
        }
        let source = try solid(width: width, height: height)
        let mesh = warped(MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.25))
        let transform = LayerTransform(origin: .zero, size: CGSize(width: width, height: height))
        let gpu = LayerCorrectionGPUContext()
        let metalAvailable = MetalMeshWarp.shared != nil

        let warmEdit = MeshWarpEdit(layerID: UUID(), layerName: "P", image: source,
                                    transform: transform, mesh: mesh)
        var warmSample = MeshWarpRenderer.Sample()
        _ = warmEdit.commitImage(sample: &warmSample)

        var sessionCreate: [Double] = []
        var initialUpload: [Double] = []
        var warmGPU: [Double] = []
        var readback: [Double] = []
        var fullCommit: [Double] = []
        var cpuFallback: [Double] = []
        var stackTwoNode: [Double] = []
        var stackCacheHit: [Double] = []
        var stackMeshMetal: [Double] = []
        var stackMeshReadback: [Double] = []
        var stackCROnly: [Double] = []
        var stackMeshOnly: [Double] = []
        var stackReshapeThenCR: [Double] = []
        var stackEditFirst: [Double] = []
        var stackEditSecond: [Double] = []
        var usedMetalCommit = false
        var usedMetalStack = false
        var metalFallbackReason: String?

        for i in 0..<runs {
            var start = CFAbsoluteTimeGetCurrent()
            _ = MeshWarpEdit(layerID: UUID(), layerName: "P", image: source,
                             transform: transform, mesh: mesh)
            sessionCreate.append((CFAbsoluteTimeGetCurrent() - start) * 1000)

            let uploadStart = CFAbsoluteTimeGetCurrent()
            let edit = MeshWarpEdit(layerID: UUID(), layerName: "P", image: source,
                                    transform: transform, mesh: mesh)
            if i == 0 { initialUpload.append((CFAbsoluteTimeGetCurrent() - uploadStart) * 1000) }

            if let session = MetalMeshWarpSession(image: source) {
                var gpuSample = MetalMeshWarpSession.Sample()
                start = CFAbsoluteTimeGetCurrent()
                _ = session.render(mesh: mesh, sample: &gpuSample, wait: true)
                warmGPU.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                var metalSample = MetalMeshWarp.Sample()
                start = CFAbsoluteTimeGetCurrent()
                _ = session.readbackCGImage(sample: &metalSample)
                readback.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }

            var sample = MeshWarpRenderer.Sample()
            start = CFAbsoluteTimeGetCurrent()
            _ = edit.commitImage(sample: &sample)
            fullCommit.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            usedMetalCommit = usedMetalCommit || sample.usedMetal

            if i < cpuRuns {
                var cpuTiming = MeshWarpRaster.Timing()
                start = CFAbsoluteTimeGetCurrent()
                _ = MeshWarpRaster.apply(source: source, mesh: mesh, timing: &cpuTiming)
                cpuFallback.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }

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
            var coldResult: LayerCorrectionRenderResult?
            start = CFAbsoluteTimeGetCurrent()
            do {
                coldResult = try render(&stack,
                                        options: .init(preferMetalMesh: true, useCache: false,
                                                       requireMetalMeshWhenAvailable: false),
                                        gpu: gpu)
            } catch { errors.append("two-node cold \(i): \(error.localizedDescription)") }
            stackTwoNode.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            if let coldResult { usedMetalStack = usedMetalStack || coldResult.usedMetal }
            if let coldResult,
               let reshapeTiming = coldResult.timings.first(where: { $0.kind == .reshape }) {
                stackMeshMetal.append(reshapeTiming.gpuMilliseconds)
                stackMeshReadback.append(reshapeTiming.readbackMilliseconds)
                if !reshapeTiming.usedMetal {
                    metalFallbackReason = reshapeTiming.fallbackReason ?? "unknown"
                }
            }
            start = CFAbsoluteTimeGetCurrent()
            do {
                _ = try render(&stack, options: .init(useCache: true), gpu: gpu)
            } catch { errors.append("cache hit \(i): \(error.localizedDescription)") }
            stackCacheHit.append((CFAbsoluteTimeGetCurrent() - start) * 1000)

            var crOnly = LayerCorrectionStack(
                source: ImportedImage(image: source, thumbnail: source, name: "P"),
                nodes: [.cameraRawGeometry(cr)])
            start = CFAbsoluteTimeGetCurrent()
            do {
                _ = try render(&crOnly, options: .init(useCache: false), gpu: gpu)
            } catch { errors.append("CR only \(i): \(error.localizedDescription)") }
            stackCROnly.append((CFAbsoluteTimeGetCurrent() - start) * 1000)

            var meshOnly = LayerCorrectionStack(
                source: ImportedImage(image: source, thumbnail: source, name: "P"),
                nodes: [.reshape(mesh: mesh, imageWidth: width, imageHeight: height)])
            start = CFAbsoluteTimeGetCurrent()
            do {
                _ = try render(&meshOnly, options: .init(useCache: false,
                                                         requireMetalMeshWhenAvailable: metalAvailable),
                               gpu: gpu)
            } catch { errors.append("mesh only \(i): \(error.localizedDescription)") }
            stackMeshOnly.append((CFAbsoluteTimeGetCurrent() - start) * 1000)

            var reshapeThenCR = LayerCorrectionStack(
                source: ImportedImage(image: source, thumbnail: source, name: "P"),
                nodes: [
                    .reshape(mesh: mesh, imageWidth: width, imageHeight: height),
                    .cameraRawGeometry(cr)
                ])
            start = CFAbsoluteTimeGetCurrent()
            do {
                _ = try render(&reshapeThenCR, options: .init(useCache: false), gpu: gpu)
            } catch { errors.append("reshape→CR \(i): \(error.localizedDescription)") }
            stackReshapeThenCR.append((CFAbsoluteTimeGetCurrent() - start) * 1000)

            // Edit first node: invalidate from index 0, re-render.
            var editFirst = stack
            editFirst.nodes[0].cameraRaw.geometry.vertical = 22
            editFirst.invalidateFromIndex(0)
            start = CFAbsoluteTimeGetCurrent()
            do {
                _ = try render(&editFirst, options: .init(useCache: true), gpu: gpu)
            } catch { errors.append("edit first \(i): \(error.localizedDescription)") }
            stackEditFirst.append((CFAbsoluteTimeGetCurrent() - start) * 1000)

            // Warm stack then edit second node only.
            var editSecond = LayerCorrectionStack(
                source: ImportedImage(image: source, thumbnail: source, name: "P"),
                nodes: [
                    .cameraRawGeometry(cr),
                    .reshape(mesh: mesh, imageWidth: width, imageHeight: height)
                ])
            _ = try render(&editSecond, options: .init(), gpu: gpu)
            var mesh2 = mesh
            let handle = mesh2.index(column: 1, row: 1)
            var positions = mesh2.positions
            positions[handle].x += 0.01
            mesh2.positions = positions
            mesh2.topology.writeBack(positions: positions)
            editSecond.nodes[1].mesh = mesh2
            editSecond.invalidateFromIndex(1)
            start = CFAbsoluteTimeGetCurrent()
            do {
                _ = try render(&editSecond, options: .init(useCache: true), gpu: gpu)
            } catch { errors.append("edit second \(i): \(error.localizedDescription)") }
            stackEditSecond.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        if metalAvailable {
            #expect(usedMetalStack, "Metal available but two-node stack did not use Metal (\(metalFallbackReason))")
            #expect(usedMetalCommit)
        }

        lines.append("")
        if !errors.isEmpty {
            lines.append("- Errors: \(errors.joined(separator: "; "))")
        }
        lines.append("- MeshWarpEdit session create median: \(String(format: "%.2f", median(sessionCreate))) ms")
        if !initialUpload.isEmpty {
            lines.append("- Initial source upload (first MeshWarpEdit): \(String(format: "%.2f", initialUpload[0])) ms")
        }
        if !warmGPU.isEmpty {
            lines.append("- Warm GPU mesh render median: \(String(format: "%.2f", median(warmGPU))) ms")
        }
        if !readback.isEmpty {
            lines.append("- GPU readback to CGImage median: \(String(format: "%.2f", median(readback))) ms")
        }
        lines.append("- Full MeshWarpEdit.commitImage median: \(String(format: "%.2f", median(fullCommit))) ms (usedMetal=\(usedMetalCommit))")
        if !cpuFallback.isEmpty {
            lines.append("- CPU MeshWarpRaster fallback median: \(String(format: "%.2f", median(cpuFallback))) ms")
        } else {
            lines.append("- CPU MeshWarpRaster fallback median: covered by M8.7 baseline at this size")
        }
        lines.append("- Camera Raw geometry alone median: \(String(format: "%.2f", median(stackCROnly))) ms")
        lines.append("- ReShape alone (resident GPU) median: \(String(format: "%.2f", median(stackMeshOnly))) ms")
        lines.append("- Two-node CR→ReShape cold (resident GPU) median: \(String(format: "%.2f", median(stackTwoNode))) ms (usedMetal=\(usedMetalStack))")
        if let reason = metalFallbackReason {
            lines.append("- Metal fallback reason observed: \(reason)")
        }
        if !stackMeshMetal.isEmpty {
            lines.append("- Stack reshape GPU kernel median: \(String(format: "%.2f", median(stackMeshMetal))) ms")
        }
        if !stackMeshReadback.isEmpty {
            lines.append("- Stack reshape readback median: \(String(format: "%.2f", median(stackMeshReadback))) ms")
        }
        lines.append("- Two-node ReShape→CR cold median: \(String(format: "%.2f", median(stackReshapeThenCR))) ms")
        lines.append("- Two-node after editing first node median: \(String(format: "%.2f", median(stackEditFirst))) ms")
        lines.append("- Two-node after editing second node (upstream cache) median: \(String(format: "%.2f", median(stackEditSecond))) ms")
        lines.append("- Two-node stack render (cache hit) median: \(String(format: "%.2f", median(stackCacheHit))) ms")
        lines.append("")

        var header: [String] = [
            "# Milestone 8.8 — Accelerated correction-stack performance",
            "",
            "Wall-clock milliseconds, medians of \(runs) runs after 1 warm-up.",
            "GPU kernel-only times are not treated as full Apply latency.",
            "Metal usage is asserted from command completion, not device presence.",
            "",
            "## M8.7 baseline (6000×4000, from MILESTONE_8_7_PERF.txt)",
            "- Full MeshWarpEdit.commitImage median: 233.78 ms (usedMetal=true)",
            "- CPU MeshWarpRaster fallback median: 47701.15 ms",
            "- Two-node stack render (CR→ReShape, no cache) median: 16672.60 ms",
            "- Two-node stack render (cache hit) median: 0.12 ms",
            "",
            "- MetalMeshWarp.shared available: \(metalAvailable)",
            "",
        ]
        header.append(contentsOf: lines)
        let paths = [
            "/Users/atr/Desktop/MILESTONE_8_8_PERF_\(width)x\(height).txt",
            "/tmp/MILESTONE_8_8_PERF_\(width)x\(height).txt",
        ]
        var written = false
        for p in paths {
            do { try header.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8); written = true; break } catch {}
        }
        print("PERF REPORT WRITTEN: \(written) \(paths.first!)")
    }
}
