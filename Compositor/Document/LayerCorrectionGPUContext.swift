import CoreGraphics
import Foundation
import Metal

/// Session-only Metal mesh working set for correction-stack evaluation. Not serializable.
/// Reuses source/destination textures across parameter edits when dimensions match; uploads the
/// upstream source only when the input image identity or size changes.
nonisolated final class LayerCorrectionGPUContext: @unchecked Sendable {
    nonisolated struct Key: Hashable, Sendable {
        var width: Int
        var height: Int
    }

    nonisolated struct MeshSample: Sendable {
        var usedMetal: Bool = false
        var metalAvailable: Bool = false
        var fallbackReason: String?
        var sourceUploadMilliseconds: Double = 0
        var triangleUploadMilliseconds: Double = 0
        var kernelMilliseconds: Double = 0
        var gpuMilliseconds: Double = 0
        var syncMilliseconds: Double = 0
        var readbackMilliseconds: Double = 0
        var allocationMilliseconds: Double = 0
        var endToEndMilliseconds: Double = 0
        var reusedSourceTexture: Bool = false
        var reusedDestinationTexture: Bool = false
    }

    private struct Slot {
        var sourceTexture: MTLTexture
        var destinationTexture: MTLTexture
        var triangleBuffer: MTLBuffer
        var sourceIdentity: ObjectIdentifier?
        var lastCommand: MTLCommandBuffer?
        var width: Int
        var height: Int
    }

    private var slots: [Key: Slot] = [:]
    private let lock = NSLock()
    /// Soft cap on retained GPU slots (each holds two full-res textures).
    var maximumSlots = 2

    func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        for key in slots.keys {
            slots[key]?.lastCommand?.waitUntilCompleted()
        }
        slots.removeAll(keepingCapacity: true)
    }

    func invalidate(width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(width: width, height: height)
        slots[key]?.lastCommand?.waitUntilCompleted()
        slots[key] = nil
    }

    /// Warps `source` with `mesh` using resident textures when possible.
    func apply(source: CGImage, mesh: MeshWarpGrid, sample: inout MeshSample) -> CGImage? {
        let started = CFAbsoluteTimeGetCurrent()
        defer { sample.endToEndMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000 }

        guard let metal = MetalMeshWarp.shared else {
            sample.metalAvailable = false
            sample.fallbackReason = "MetalMeshWarp.shared unavailable"
            return cpuFallback(source: source, mesh: mesh, sample: &sample)
        }
        sample.metalAvailable = true

        if mesh.isIdentity {
            sample.fallbackReason = "identity mesh"
            return source
        }

        let width = source.width, height = source.height
        guard width > 0, height > 0 else {
            sample.fallbackReason = "empty source"
            return nil
        }

        let triangles = mesh.triangles()
        guard !triangles.isEmpty else {
            sample.fallbackReason = "empty triangulation"
            return nil
        }

        let key = Key(width: width, height: height)
        let sourceID = ObjectIdentifier(source)

        lock.lock()
        var slot = slots[key]
        let allocStarted = CFAbsoluteTimeGetCurrent()
        if slot == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                      width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            guard let sourceTex = metal.device.makeTexture(descriptor: descriptor),
                  let destTex = metal.device.makeTexture(descriptor: descriptor),
                  let trianglesBuf = metal.device.makeBuffer(length: max(4096, triangles.count * 128),
                                                             options: .storageModeShared)
            else {
                lock.unlock()
                sample.fallbackReason = "Metal texture/buffer allocation failed"
                return cpuFallback(source: source, mesh: mesh, sample: &sample)
            }
            slot = Slot(sourceTexture: sourceTex, destinationTexture: destTex, triangleBuffer: trianglesBuf,
                        sourceIdentity: nil, lastCommand: nil, width: width, height: height)
            sample.allocationMilliseconds = (CFAbsoluteTimeGetCurrent() - allocStarted) * 1000
            // Evict older slots when over budget.
            while slots.count >= maximumSlots, let victim = slots.keys.first(where: { $0 != key }) {
                slots[victim]?.lastCommand?.waitUntilCompleted()
                slots[victim] = nil
            }
        } else {
            sample.reusedDestinationTexture = true
            sample.allocationMilliseconds = 0
        }
        guard var live = slot else {
            lock.unlock()
            sample.fallbackReason = "slot missing"
            return cpuFallback(source: source, mesh: mesh, sample: &sample)
        }
        lock.unlock()

        // Finish any prior encode that owns the destination before rewriting it.
        let syncStarted = CFAbsoluteTimeGetCurrent()
        live.lastCommand?.waitUntilCompleted()
        sample.syncMilliseconds = (CFAbsoluteTimeGetCurrent() - syncStarted) * 1000

        // Upload source only when the CGImage identity changes.
        if live.sourceIdentity != sourceID {
            guard let bytes = try? MeshWarpRaster.rgba8Bytes(from: source) else {
                sample.fallbackReason = "RGBA8 conversion failed"
                return cpuFallback(source: source, mesh: mesh, sample: &sample)
            }
            let uploadStarted = CFAbsoluteTimeGetCurrent()
            let stride = width * 4
            bytes.withUnsafeBytes { raw in
                live.sourceTexture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                           withBytes: raw.baseAddress!, bytesPerRow: stride)
            }
            sample.sourceUploadMilliseconds = (CFAbsoluteTimeGetCurrent() - uploadStarted) * 1000
            live.sourceIdentity = sourceID
            sample.reusedSourceTexture = false
        } else {
            sample.reusedSourceTexture = true
            sample.sourceUploadMilliseconds = 0
        }

        let packed = MetalMeshWarp.pack(triangles)
        let triangleBytes = packed.count * MemoryLayout<MetalMeshWarp.TriangleGPU>.stride
        if live.triangleBuffer.length < triangleBytes {
            guard let grown = metal.device.makeBuffer(length: max(triangleBytes, live.triangleBuffer.length * 2),
                                                      options: .storageModeShared) else {
                sample.fallbackReason = "triangle buffer grow failed"
                return cpuFallback(source: source, mesh: mesh, sample: &sample)
            }
            live.triangleBuffer = grown
        }

        let triUploadStarted = CFAbsoluteTimeGetCurrent()
        packed.withUnsafeBytes { raw in
            memcpy(live.triangleBuffer.contents(), raw.baseAddress!, triangleBytes)
        }
        sample.triangleUploadMilliseconds = (CFAbsoluteTimeGetCurrent() - triUploadStarted) * 1000

        let threads = metal.texturePipeline.threadExecutionWidth
        guard threads > 0, metal.texturePipeline.maxTotalThreadsPerThreadgroup >= threads,
              let command = metal.queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            sample.fallbackReason = "Metal command encoder failed"
            return cpuFallback(source: source, mesh: mesh, sample: &sample)
        }

        var parameters = MetalMeshWarp.Parameters(width: UInt32(width), height: UInt32(height),
                                                  stride: UInt32(width * 4), triangleCount: UInt32(packed.count))
        encoder.setComputePipelineState(metal.texturePipeline)
        encoder.setTexture(live.sourceTexture, index: 0)
        encoder.setTexture(live.destinationTexture, index: 1)
        encoder.setBuffer(live.triangleBuffer, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<MetalMeshWarp.Parameters>.stride, index: 1)
        let groupHeight = max(1, metal.texturePipeline.maxTotalThreadsPerThreadgroup / threads)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: threads, height: groupHeight, depth: 1))
        encoder.endEncoding()

        let kernelStarted = CFAbsoluteTimeGetCurrent()
        command.commit()
        command.waitUntilCompleted()
        sample.kernelMilliseconds = (CFAbsoluteTimeGetCurrent() - kernelStarted) * 1000
        if command.gpuStartTime != 0, command.gpuEndTime >= command.gpuStartTime {
            sample.gpuMilliseconds = (command.gpuEndTime - command.gpuStartTime) * 1000
        }
        live.lastCommand = command
        guard command.status == .completed else {
            sample.fallbackReason = "Metal command status \(command.status.rawValue)"
            store(key: key, slot: live)
            return cpuFallback(source: source, mesh: mesh, sample: &sample)
        }

        let readbackStarted = CFAbsoluteTimeGetCurrent()
        let stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        live.destinationTexture.getBytes(&bytes, bytesPerRow: stride,
                                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        sample.readbackMilliseconds = (CFAbsoluteTimeGetCurrent() - readbackStarted) * 1000
        store(key: key, slot: live)

        sample.usedMetal = true
        sample.fallbackReason = nil
        return MeshWarpRaster.image(from: bytes, width: width, height: height, stride: stride)
    }

    private func store(key: Key, slot: Slot) {
        lock.lock()
        slots[key] = slot
        lock.unlock()
    }

    private func cpuFallback(source: CGImage, mesh: MeshWarpGrid, sample: inout MeshSample) -> CGImage? {
        var timing = MeshWarpRaster.Timing()
        let image = MeshWarpRaster.apply(source: source, mesh: mesh, timing: &timing)
        sample.usedMetal = false
        if sample.fallbackReason == nil {
            sample.fallbackReason = "CPU MeshWarpRaster"
        }
        sample.kernelMilliseconds = timing.milliseconds
        return image
    }
}
