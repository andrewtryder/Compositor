import CoreGraphics
import Foundation

/// Evaluates a `LayerCorrectionStack` from the immutable source. Stage caches are reused when a
/// node and all upstream nodes are unchanged (`revision` + cache entries).
///
/// Mesh stages prefer a resident `LayerCorrectionGPUContext` when supplied; otherwise they fall
/// back to one-shot `MeshWarpRenderer` / CPU. Metal usage is recorded from actual command completion,
/// never inferred from device presence alone.
nonisolated enum LayerCorrectionRenderer {
    nonisolated struct Options: Sendable {
        var preferMetalMesh: Bool = true
        /// When true, reuse `stack.stageCache` entries that match the current revision.
        var useCache: Bool = true
        /// Session-owned resident GPU working set. Not serializable.
        var gpuContext: LayerCorrectionGPUContext? = nil
        /// When true and Metal is available, fail instead of silently falling back to CPU for mesh.
        var requireMetalMeshWhenAvailable: Bool = false
    }

    static func render(_ stack: inout LayerCorrectionStack,
                       options: Options = Options()) throws -> LayerCorrectionRenderResult {
        try stack.validatePrecision()
        try stack.validateStageDimensions()

        var current = stack.source.image
        var expansion: CameraRawGeometryExpansion?
        var usedMetal = false
        var cacheHits = 0
        var stagesRendered = 0
        var timings: [LayerCorrectionRenderResult.StageTiming] = []

        for node in stack.nodes where node.enabled {
            if options.useCache,
               let cached = stack.stageCache[node.id],
               cached.revision == stack.revision,
               cached.inputWidth == current.width,
               cached.inputHeight == current.height,
               cached.image.width == cached.outputWidth,
               cached.image.height == cached.outputHeight {
                current = cached.image
                expansion = cached.expansion ?? expansion
                cacheHits += 1
                timings.append(.init(nodeID: node.id, kind: node.kind, milliseconds: 0,
                                     usedMetal: false, cacheHit: true))
                continue
            }

            let started = CFAbsoluteTimeGetCurrent()
            var timing = LayerCorrectionRenderResult.StageTiming(
                nodeID: node.id, kind: node.kind, milliseconds: 0, usedMetal: false, cacheHit: false)
            let output: CGImage
            var stageExpansion: CameraRawGeometryExpansion?

            switch node.kind {
            case .cameraRawGeometry:
                if node.usesExpandToFit, stack.hasReshape {
                    throw LayerCorrectionError.expandWithReshape
                }
                let applied = try CameraRawGeometryBackend.apply(current, settings: node.cameraRaw)
                output = applied.image
                stageExpansion = applied.expansion
                timing.fallbackReason = "Camera Raw geometry (CPU)"

            case .cameraRawFull:
                if node.usesExpandToFit, stack.hasReshape {
                    throw LayerCorrectionError.expandWithReshape
                }
                // Reuse the existing Camera Raw Filter algorithms — no duplicate color engine.
                let applied = try node.cameraRawFull.applyResult(current, usesGPU: false)
                output = applied.image
                stageExpansion = applied.expansion
                timing.fallbackReason = "Camera Raw full (CPU Filter path)"

            case .reshape:
                guard let mesh = node.mesh else {
                    throw LayerCorrectionError.malformed("reshape missing mesh")
                }
                guard node.meshImageWidth == current.width,
                      node.meshImageHeight == current.height else {
                    throw LayerCorrectionError.invalidDimensions(
                        "reshape \(node.meshImageWidth)×\(node.meshImageHeight) vs \(current.width)×\(current.height)")
                }
                if mesh.isIdentity {
                    output = current
                    timing.fallbackReason = "identity mesh"
                } else if options.preferMetalMesh {
                    let warped: CGImage
                    if let gpu = options.gpuContext {
                        var sample = LayerCorrectionGPUContext.MeshSample()
                        guard let image = gpu.apply(source: current, mesh: mesh, sample: &sample) else {
                            throw LayerCorrectionError.unsupported("ReShape could not render the mesh.")
                        }
                        warped = image
                        timing.usedMetal = sample.usedMetal
                        timing.metalAvailable = sample.metalAvailable
                        timing.fallbackReason = sample.fallbackReason
                        timing.sourceUploadMilliseconds = sample.sourceUploadMilliseconds
                        timing.triangleUploadMilliseconds = sample.triangleUploadMilliseconds
                        timing.kernelMilliseconds = sample.kernelMilliseconds
                        timing.gpuMilliseconds = sample.gpuMilliseconds
                        timing.syncMilliseconds = sample.syncMilliseconds
                        timing.readbackMilliseconds = sample.readbackMilliseconds
                        timing.allocationMilliseconds = sample.allocationMilliseconds
                    } else {
                        var sample = MeshWarpRenderer.Sample()
                        guard let image = MeshWarpRenderer.apply(source: current, mesh: mesh, sample: &sample) else {
                            throw LayerCorrectionError.unsupported("ReShape could not render the mesh.")
                        }
                        warped = image
                        timing.usedMetal = sample.usedMetal
                        timing.metalAvailable = MetalMeshWarp.shared != nil
                        timing.fallbackReason = sample.usedMetal ? nil : "one-shot MeshWarpRenderer CPU/Metal fail"
                        timing.sourceUploadMilliseconds = sample.uploadMilliseconds
                        timing.triangleUploadMilliseconds = sample.triangleUploadMilliseconds
                        timing.kernelMilliseconds = sample.kernelMilliseconds
                        timing.gpuMilliseconds = sample.gpuMilliseconds
                        timing.readbackMilliseconds = sample.readbackMilliseconds
                    }
                    if options.requireMetalMeshWhenAvailable,
                       MetalMeshWarp.shared != nil,
                       !timing.usedMetal {
                        throw LayerCorrectionError.unsupported(
                            "Metal mesh expected but fell back (\(timing.fallbackReason ?? "unknown")).")
                    }
                    output = warped
                } else {
                    var rasterTiming = MeshWarpRaster.Timing()
                    guard let warped = MeshWarpRaster.apply(source: current, mesh: mesh, timing: &rasterTiming) else {
                        throw LayerCorrectionError.unsupported("ReShape CPU raster failed.")
                    }
                    output = warped
                    timing.fallbackReason = "preferMetalMesh=false (CPU MeshWarpRaster)"
                    timing.kernelMilliseconds = rasterTiming.milliseconds
                }
            }

            timing.milliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000
            usedMetal = usedMetal || timing.usedMetal
            stagesRendered += 1
            timings.append(timing)

            stack.storeStage(LayerCorrectionStack.CachedStage(
                revision: stack.revision,
                image: output,
                expansion: stageExpansion,
                inputWidth: current.width,
                inputHeight: current.height,
                outputWidth: output.width,
                outputHeight: output.height
            ), for: node.id)
            current = output
            if let stageExpansion { expansion = stageExpansion }
        }

        return LayerCorrectionRenderResult(image: current, expansion: expansion, usedMetal: usedMetal,
                                           cacheHits: cacheHits, stagesRendered: stagesRendered,
                                           timings: timings)
    }

    /// Renders without mutating the caller's cache dictionary (uses a copy).
    static func renderCopy(_ stack: LayerCorrectionStack,
                           options: Options = Options()) throws -> LayerCorrectionRenderResult {
        var copy = stack
        return try render(&copy, options: options)
    }
}
