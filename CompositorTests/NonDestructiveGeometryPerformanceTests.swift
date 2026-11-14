import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Production Apply / stack render timings for M8.8.
///
/// Metrics are emitted as one JSON object per measured scenario to stdout. The invoking
/// shell captures test output and writes `MILESTONE_8_8_PERF.txt` outside the sandboxed
/// test process. No file is written from within XCTest.
@Suite(.serialized)
@MainActor
struct NonDestructiveGeometryPerformanceTests {
    private func solid(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(red: 0.65, green: 0.4, blue: 0.25, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func checkerboard(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let tile: CGFloat = 64
        for y in stride(from: 0, through: CGFloat(height), by: tile) {
            for x in stride(from: 0, through: CGFloat(width), by: tile) {
                if (Int(x / tile) + Int(y / tile)) % 2 == 0 {
                    context.setFillColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1)
                } else {
                    context.setFillColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)
                }
                context.fill(CGRect(x: x, y: y, width: min(tile, CGFloat(width) - x),
                                      height: min(tile, CGFloat(height) - y)))
            }
        }
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

    /// Emit one machine-readable metric record to stdout.
    private func emitMetric(width: Int, height: Int, fixture: String, scenario: String,
                            ms: Double, usedMetal: Bool, fallbackReason: String?,
                            runs: Int, notes: String = "") {
        var record: [String: Any] = [
            "width": width, "height": height, "fixture": fixture, "scenario": scenario,
            "ms": ms, "usedMetal": usedMetal, "runs": runs,
        ]
        if let fallbackReason, !fallbackReason.isEmpty {
            record["fallbackReason"] = fallbackReason
        }
        if !notes.isEmpty {
            record["notes"] = notes
        }
        let data = try? JSONSerialization.data(withJSONObject: record, options: [])
        if let data, let line = String(data: data, encoding: .utf8) {
            print("M8.8_METRIC \(line)")
        } else {
            print("M8.8_METRIC {\"width\":\(width),\"height\":\(height),\"fixture\":\"\(fixture)\",\"scenario\":\"\(scenario)\",\"ms\":\(ms),\"usedMetal\":\(usedMetal),\"runs\":\(runs)}")
        }
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
        let budget = DocumentLimits.documentPixelBudget / 4
        guard width * height <= budget else {
            emitMetric(width: width, height: height, fixture: "solid", scenario: "skipped",
                       ms: 0, usedMetal: false, fallbackReason: "pixel budget exceeded",
                       runs: 0)
            return
        }

        let metalAvailable = MetalMeshWarp.shared != nil
        let gpu = LayerCorrectionGPUContext()

        // Fixtures: solid color + checkerboard for correctness checks.
        let solidSource = try solid(width: width, height: height)
        let checkerSource = try checkerboard(width: width, height: height)

        let mesh = warped(MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.25))
        let transform = LayerTransform(origin: .zero, size: CGSize(width: width, height: height))

        // ---- Warm-up MeshWarpEdit commitImage (production Apply path). ----
        let warmEdit = MeshWarpEdit(layerID: UUID(), layerName: "P", image: solidSource,
                                    transform: transform, mesh: mesh)
        var warmSample = MeshWarpRenderer.Sample()
        _ = warmEdit.commitImage(sample: &warmSample)

        // ---- MeshWarpEdit timings (session create, upload, GPU render, readback, commit). ----
        var sessionCreate: [Double] = []
        var initialUpload: [Double] = []
        var warmGPU: [Double] = []
        var readback: [Double] = []
        var fullCommit: [Double] = []
        var cpuFallback: [Double] = []
        var usedMetalCommit = false

        for i in 0..<runs {
            var start = CFAbsoluteTimeGetCurrent()
            _ = MeshWarpEdit(layerID: UUID(), layerName: "P", image: solidSource,
                             transform: transform, mesh: mesh)
            sessionCreate.append((CFAbsoluteTimeGetCurrent() - start) * 1000)

            let uploadStart = CFAbsoluteTimeGetCurrent()
            let edit = MeshWarpEdit(layerID: UUID(), layerName: "P", image: solidSource,
                                    transform: transform, mesh: mesh)
            if i == 0 { initialUpload.append((CFAbsoluteTimeGetCurrent() - uploadStart) * 1000) }

            if let session = MetalMeshWarpSession(image: solidSource) {
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
                _ = MeshWarpRaster.apply(source: solidSource, mesh: mesh, timing: &cpuTiming)
                cpuFallback.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
        }

        emitMetric(width: width, height: height, fixture: "solid", scenario: "session_create",
                   ms: median(sessionCreate), usedMetal: true, fallbackReason: nil, runs: runs)
        if !initialUpload.isEmpty {
            emitMetric(width: width, height: height, fixture: "solid", scenario: "initial_source_upload",
                       ms: initialUpload[0], usedMetal: true, fallbackReason: nil, runs: 1)
        }
        if !warmGPU.isEmpty {
            emitMetric(width: width, height: height, fixture: "solid", scenario: "warm_gpu_mesh_render",
                       ms: median(warmGPU), usedMetal: true, fallbackReason: nil, runs: runs)
        }
        if !readback.isEmpty {
            emitMetric(width: width, height: height, fixture: "solid", scenario: "gpu_readback",
                       ms: median(readback), usedMetal: true, fallbackReason: nil, runs: runs)
        }
        emitMetric(width: width, height: height, fixture: "solid", scenario: "full_commit_apply",
                   ms: median(fullCommit), usedMetal: usedMetalCommit,
                   fallbackReason: usedMetalCommit ? nil : "no Metal device", runs: runs)
        if !cpuFallback.isEmpty {
            emitMetric(width: width, height: height, fixture: "solid", scenario: "cpu_fallback",
                       ms: median(cpuFallback), usedMetal: false,
                       fallbackReason: "CPU MeshWarpRaster", runs: cpuRuns)
        }

        // ---- Stack scenarios ----
        func crSettings() -> CameraRawGeometryBackendSettings {
            var cr = CameraRawGeometryBackendSettings()
            cr.geometry.upright = .off
            cr.geometry.vertical = 18
            cr.geometry.framingMode = .keepOriginalSize
            return cr
        }

        var stackTwoNode: [Double] = []
        var stackCacheHit: [Double] = []
        var stackMeshMetal: [Double] = []
        var stackMeshReadback: [Double] = []
        var stackCROnly: [Double] = []
        var stackMeshOnly: [Double] = []
        var stackReshapeThenCR: [Double] = []
        var stackEditFirst: [Double] = []
        var stackEditSecond: [Double] = []
        var usedMetalStack = false
        var metalFallbackReason: String?
        var errors: [String] = []

        for i in 0..<runs {
            // Camera Raw geometry alone.
            var crOnly = LayerCorrectionStack(
                source: ImportedImage(image: solidSource, thumbnail: solidSource, name: "P"),
                nodes: [.cameraRawGeometry(crSettings())])
            var start = CFAbsoluteTimeGetCurrent()
            do {
                _ = try render(&crOnly, options: .init(useCache: false), gpu: gpu)
            } catch { errors.append("CR only \(i): \(error.localizedDescription)") }
            stackCROnly.append((CFAbsoluteTimeGetCurrent() - start) * 1000)

            // ReShape alone.
            var meshOnly = LayerCorrectionStack(
                source: ImportedImage(image: solidSource, thumbnail: solidSource, name: "P"),
                nodes: [.reshape(mesh: mesh, imageWidth: width, imageHeight: height)])
            start = CFAbsoluteTimeGetCurrent()
            do {
                _ = try render(&meshOnly, options: .init(useCache: false,
                                                         requireMetalMeshWhenAvailable: metalAvailable),
                               gpu: gpu)
            } catch { errors.append("mesh only \(i): \(error.localizedDescription)") }
            stackMeshOnly.append((CFAbsoluteTimeGetCurrent() - start) * 1000)

            // Two-node CR→ReShape cold.
            var stack = LayerCorrectionStack(
                source: ImportedImage(image: solidSource, thumbnail: solidSource, name: "P"),
                nodes: [
                    .cameraRawGeometry(crSettings()),
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

            // Cache hit (same stack, re-render).
            start = CFAbsoluteTimeGetCurrent()
            do {
                _ = try render(&stack, options: .init(useCache: true), gpu: gpu)
            } catch { errors.append("cache hit \(i): \(error.localizedDescription)") }
            stackCacheHit.append((CFAbsoluteTimeGetCurrent() - start) * 1000)

            // ReShape → Camera Raw.
            var reshapeThenCR = LayerCorrectionStack(
                source: ImportedImage(image: solidSource, thumbnail: solidSource, name: "P"),
                nodes: [
                    .reshape(mesh: mesh, imageWidth: width, imageHeight: height),
                    .cameraRawGeometry(crSettings())
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
                source: ImportedImage(image: solidSource, thumbnail: solidSource, name: "P"),
                nodes: [
                    .cameraRawGeometry(crSettings()),
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

        emitMetric(width: width, height: height, fixture: "solid", scenario: "camera_raw_only",
                   ms: median(stackCROnly), usedMetal: true, fallbackReason: nil, runs: runs)
        emitMetric(width: width, height: height, fixture: "solid", scenario: "reshape_only",
                   ms: median(stackMeshOnly), usedMetal: usedMetalStack,
                   fallbackReason: metalFallbackReason, runs: runs)
        emitMetric(width: width, height: height, fixture: "solid", scenario: "camera_raw_then_reshape_cold",
                   ms: median(stackTwoNode), usedMetal: usedMetalStack,
                   fallbackReason: metalFallbackReason, runs: runs)
        emitMetric(width: width, height: height, fixture: "solid", scenario: "reshape_then_camera_raw",
                   ms: median(stackReshapeThenCR), usedMetal: usedMetalStack,
                   fallbackReason: metalFallbackReason, runs: runs)
        emitMetric(width: width, height: height, fixture: "solid", scenario: "edit_first_node",
                   ms: median(stackEditFirst), usedMetal: usedMetalStack,
                   fallbackReason: metalFallbackReason, runs: runs)
        emitMetric(width: width, height: height, fixture: "solid", scenario: "edit_second_node_upstream_cached",
                   ms: median(stackEditSecond), usedMetal: usedMetalStack,
                   fallbackReason: metalFallbackReason, runs: runs)
        emitMetric(width: width, height: height, fixture: "solid", scenario: "cache_hit",
                   ms: median(stackCacheHit), usedMetal: usedMetalStack,
                   fallbackReason: nil, runs: runs)
        if !stackMeshMetal.isEmpty {
            emitMetric(width: width, height: height, fixture: "solid", scenario: "stack_reshape_gpu_kernel",
                       ms: median(stackMeshMetal), usedMetal: usedMetalStack,
                       fallbackReason: metalFallbackReason, runs: runs)
        }
        if !stackMeshReadback.isEmpty {
            emitMetric(width: width, height: height, fixture: "solid", scenario: "stack_reshape_readback",
                       ms: median(stackMeshReadback), usedMetal: usedMetalStack,
                       fallbackReason: nil, runs: runs)
        }

        if !errors.isEmpty {
            emitMetric(width: width, height: height, fixture: "solid", scenario: "errors",
                       ms: 0, usedMetal: false,
                       fallbackReason: errors.joined(separator: "; "), runs: 0)
        }

        if metalAvailable {
            #expect(usedMetalStack, "Metal available but two-node stack did not use Metal (\(metalFallbackReason ?? "nil"))")
            #expect(usedMetalCommit)
        }
    }
}
