import AppKit
import Foundation
import Testing
@testable import Compositor

/// Warm-median timings for ReShape mesh update, CPU/GPU raster, and Apply.
/// Run with: `xcodebuild ... -only-testing:CompositorTests/MeshWarpPerformanceTests`
@Suite(.serialized)
@MainActor
struct MeshWarpPerformanceTests {
    private func solid(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.7, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private func deformedMesh() -> MeshWarpGrid {
        var mesh = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.25)
        let index = mesh.index(column: 4, row: 4)
        _ = mesh.tryMove(index: index, to: mesh.positions[index] + SIMD2(0.05, -0.04))
        return mesh
    }

    private func fmt(_ values: [Double]) -> String {
        values.isEmpty ? "n/a" : String(format: "%.2f", median(values))
    }

    @Test func warmMediansAtThreeResolutions() throws {
        let sizes = [(1024, 1024), (4000, 3000), (6000, 4000)]
        var report: [String] = []
        report.append("build=Debug (xcodebuild test); host=\(ProcessInfo.processInfo.machineHardwareName)")
        for (width, height) in sizes {
            let megapixels = Double(width * height) / 1_000_000
            let source = try solid(width: width, height: height)
            let mesh = deformedMesh()
            let sourceBytes = try MeshWarpRaster.rgba8Bytes(from: source)
            let stride = width * 4
            let large = megapixels >= 10

            var updateSamples: [Double] = []
            for _ in 0..<12 {
                var trial = MeshWarpGrid.identity(preset: .points8, stickyBorders: true, propagation: 0.25)
                let index = trial.index(column: 4, row: 4)
                let started = CFAbsoluteTimeGetCurrent()
                _ = trial.tryMove(index: index, to: trial.positions[index] + SIMD2(0.05, -0.04))
                updateSamples.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
            }

            // CPU reference: full warm set at 1K; one warm sample at 4K/6K (piecewise affine is expensive).
            var cpuSamples: [Double] = []
            let cpuRuns = large ? 2 : 6
            for i in 0..<cpuRuns {
                var timing = MeshWarpRaster.Timing()
                _ = MeshWarpRaster.apply(source: source, mesh: mesh, timing: &timing)
                if i >= (large ? 1 : 1) { cpuSamples.append(timing.milliseconds) }
            }

            var uploadSamples: [Double] = []
            var kernelSamples: [Double] = []
            var readbackSamples: [Double] = []
            var gpuSamples: [Double] = []
            if let metal = MetalMeshWarp.shared {
                var destination = [UInt8](repeating: 0, count: stride * height)
                let gpuRuns = large ? 5 : 8
                for i in 0..<gpuRuns {
                    var sample = MetalMeshWarp.Sample()
                    let ok = sourceBytes.withUnsafeBufferPointer { src in
                        destination.withUnsafeMutableBufferPointer { dst in
                            metal.apply(source: src.baseAddress!, destination: dst.baseAddress!,
                                        width: width, height: height, stride: stride, mesh: mesh, sample: &sample)
                        }
                    }
                    #expect(ok)
                    if i >= 1 {
                        uploadSamples.append(sample.uploadMilliseconds)
                        kernelSamples.append(sample.kernelMilliseconds)
                        readbackSamples.append(sample.readbackMilliseconds)
                        gpuSamples.append(sample.gpuMilliseconds)
                    }
                }
            }

            var previewSamples: [Double] = []
            var residentSamples: [Double] = []
            var residentKernelSamples: [Double] = []
            let previewRuns = large ? 3 : 5
            for i in 0..<previewRuns {
                var sample = MeshWarpRenderer.Sample()
                _ = MeshWarpRenderer.apply(source: source, mesh: mesh, sample: &sample)
                if i >= 1 { previewSamples.append(sample.endToEndMilliseconds) }
            }
            if MetalMeshWarp.shared != nil {
                let session = try #require(MetalMeshWarpSession(image: source))
                let residentRuns = large ? 5 : 8
                for i in 0..<residentRuns {
                    var sample = MetalMeshWarpSession.Sample()
                    #expect(session.render(mesh: mesh, sample: &sample, wait: true))
                    if i >= 1 {
                        residentSamples.append(sample.endToEndMilliseconds)
                        residentKernelSamples.append(sample.kernelMilliseconds)
                    }
                }
                session.invalidate()
            }

            var applySamples: [Double] = []
            let applyRuns = large ? 2 : 3
            for i in 0..<applyRuns {
                let session = EditorSession()
                session.createDocument(width: width, height: height)
                session.insert(ImportedImage(image: source, thumbnail: source, name: "Perf"))
                session.beginMeshWarp(preset: .points8)
                let edit = try #require(session.meshWarpEdit)
                var editMesh = edit.mesh
                let index = editMesh.index(column: 4, row: 4)
                let moved = editMesh.tryMove(index: index, to: editMesh.positions[index] + SIMD2(0.05, -0.04))
                #expect(moved)
                edit.mesh = editMesh
                let started = CFAbsoluteTimeGetCurrent()
                session.applyMeshWarp()
                let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
                if i >= (large ? 1 : 0) { applySamples.append(elapsed) }
                #expect(session.meshWarpEdit == nil)
            }

            report.append(
                "\(width)x\(height) meshUpdate=\(fmt(updateSamples))ms cpu=\(fmt(cpuSamples))ms " +
                "upload=\(fmt(uploadSamples))ms kernel=\(fmt(kernelSamples))ms " +
                "readback=\(fmt(readbackSamples))ms gpu=\(fmt(gpuSamples))ms " +
                "previewBuffer=\(fmt(previewSamples))ms residentPreview=\(fmt(residentSamples))ms " +
                "residentKernel=\(fmt(residentKernelSamples))ms apply=\(fmt(applySamples))ms"
            )
        }
        let text = report.joined(separator: "\n")
        let candidates = [
            URL(fileURLWithPath: "/tmp/MILESTONE_8_MESH_PERF.txt"),
            FileManager.default.temporaryDirectory.appendingPathComponent("MILESTONE_8_MESH_PERF.txt"),
        ]
        var wrote: URL?
        for url in candidates {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                wrote = url
                break
            } catch {
                continue
            }
        }
        let payload = "MESH_PERF_BEGIN\n\(text)\nMESH_PERF_END path=\(wrote?.path ?? "none")\n"
        if let data = payload.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        #expect(report.count == 4, Comment(rawValue: payload))
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
