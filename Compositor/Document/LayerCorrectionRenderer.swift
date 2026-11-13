import CoreGraphics
import Foundation

/// Evaluates a `LayerCorrectionStack` from the immutable source. Stage caches are reused when a
/// node and all upstream nodes are unchanged (`revision` + cache entries).
nonisolated enum LayerCorrectionRenderer {
    nonisolated struct Options: Sendable {
        var preferMetalMesh: Bool = true
        /// When true, reuse `stack.stageCache` entries that match the current revision.
        var useCache: Bool = true
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
            let stageMetal: Bool
            let output: CGImage
            var stageExpansion: CameraRawGeometryExpansion?

            switch node.kind {
            case .cameraRawGeometry:
                if LayerCorrectionStack.usesExpand(node.cameraRaw), stack.hasReshape {
                    throw LayerCorrectionError.expandWithReshape
                }
                let applied = try CameraRawGeometryBackend.apply(current, settings: node.cameraRaw)
                output = applied.image
                stageExpansion = applied.expansion
                stageMetal = false

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
                    stageMetal = false
                } else if options.preferMetalMesh {
                    var sample = MeshWarpRenderer.Sample()
                    // Prefer resident session path when available via MeshWarpRenderer (Metal first).
                    guard let warped = MeshWarpRenderer.apply(source: current, mesh: mesh, sample: &sample) else {
                        throw LayerCorrectionError.unsupported("ReShape could not render the mesh.")
                    }
                    output = warped
                    stageMetal = sample.usedMetal
                } else {
                    var timing = MeshWarpRaster.Timing()
                    guard let warped = MeshWarpRaster.apply(source: current, mesh: mesh, timing: &timing) else {
                        throw LayerCorrectionError.unsupported("ReShape CPU raster failed.")
                    }
                    output = warped
                    stageMetal = false
                }
            }

            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            usedMetal = usedMetal || stageMetal
            stagesRendered += 1
            timings.append(.init(nodeID: node.id, kind: node.kind, milliseconds: ms,
                                 usedMetal: stageMetal, cacheHit: false))

            stack.stageCache[node.id] = LayerCorrectionStack.CachedStage(
                revision: stack.revision,
                image: output,
                expansion: stageExpansion,
                inputWidth: current.width,
                inputHeight: current.height,
                outputWidth: output.width,
                outputHeight: output.height
            )
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
