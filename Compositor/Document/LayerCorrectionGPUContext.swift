import CoreGraphics
import Foundation
import Metal

/// Session-only Metal mesh working set for correction-stack evaluation. Not serializable.
///
/// Synchronization policy:
/// - All slot metadata and dictionary mutation happen while holding `lock`.
/// - `withLeasedSlot(key:body:)` obtains exclusive access to a slot (creating it if needed),
///   runs `body` while the lock is released, and merges the returned `SlotResult` back into
///   the dictionary under the lock. Only one caller can lease a given slot at a time because
///   callers must not nest or interleave leases on the same key.
/// - The source CGImage is strongly retained for as long as its uploaded texture is treated
///   as current, preventing `ObjectIdentifier` reuse from causing false source-reuse hits.
/// - Before a destination texture is rewritten, the slot's last command buffer is waited on.
/// - Eviction waits on the victim's last command before removal.
/// - Failed Metal operations fall back to the CPU reference renderer without leaving stale
///   pixels in resident slots.
///
/// This class is safe for concurrent use from multiple threads provided each slot key is
/// leased by at most one caller at a time.
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

    /// A resident GPU slot plus a strong reference to the source image whose pixels it holds.
    private final class Slot {
        let sourceTexture: MTLTexture
        let destinationTexture: MTLTexture
        var triangleBuffer: MTLBuffer
        /// Strongly retained so `sourceIdentity` cannot be reused by a different CGImage.
        var sourceImage: CGImage?
        var sourceIdentity: ObjectIdentifier?
        var lastCommand: MTLCommandBuffer?
        let width: Int
        let height: Int

        init(sourceTexture: MTLTexture, destinationTexture: MTLTexture, triangleBuffer: MTLBuffer,
             width: Int, height: Int) {
            self.sourceTexture = sourceTexture
            self.destinationTexture = destinationTexture
            self.triangleBuffer = triangleBuffer
            self.width = width
            self.height = height
        }
    }

    private var slots: [Key: Slot] = [:]
    private let lock = NSLock()
    /// Soft cap on retained GPU slots (each holds two full-res textures).
    var maximumSlots = 2

    /// Execute `body` with exclusive access to the slot for `key`, creating it if needed.
    ///
    /// The slot is not removed from the dictionary while `body` runs; the caller must not
    /// call `invalidate` or `invalidateAll` concurrently with this lease. Returns a
    /// `SlotResult` describing whether GPU work succeeded and any timing updates.
    private func withLeasedSlot(key: Key, source: CGImage, metal: MetalMeshWarp,
                                body: (Slot) -> SlotResult) -> SlotResult {
        lock.lock()
        let allocStarted = CFAbsoluteTimeGetCurrent()
        var slot = slots[key]
        if slot == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: key.width, height: key.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            guard let sourceTex = metal.device.makeTexture(descriptor: descriptor),
                  let destTex = metal.device.makeTexture(descriptor: descriptor),
                  let trianglesBuf = metal.device.makeBuffer(
                    length: max(4096, 1024 * 128), options: .storageModeShared)
            else {
                lock.unlock()
                return SlotResult(ok: false, fallbackReason: "Metal texture/buffer allocation failed")
            }
            slot = Slot(sourceTexture: sourceTex, destinationTexture: destTex,
                        triangleBuffer: trianglesBuf, width: key.width, height: key.height)
            // Evict older slots when over budget, waiting on their GPU work first.
            while slots.count >= maximumSlots, let victimKey = slots.keys.first(where: { $0 != key }) {
                let victim = slots[victimKey]!
                victim.lastCommand?.waitUntilCompleted()
                slots[victimKey] = nil
            }
            slots[key] = slot!
        }
        guard let live = slot else {
            lock.unlock()
            return SlotResult(ok: false, fallbackReason: "slot missing")
        }
        // Retain the source for the lifetime of the slot's source texture.
        live.sourceImage = source
        let allocationMilliseconds = (CFAbsoluteTimeGetCurrent() - allocStarted) * 1000
        lock.unlock()

        var result = body(live)
        result.allocationMilliseconds = allocationMilliseconds
        return result
    }

    /// Outcome of a leased-slot GPU operation.
    private struct SlotResult {
        var ok: Bool
        var fallbackReason: String?
        var allocationMilliseconds: Double = 0
        var reusedDestinationTexture: Bool = false
        var reusedSourceTexture: Bool = false
        var sourceUploadMilliseconds: Double = 0
        var triangleUploadMilliseconds: Double = 0
        var syncMilliseconds: Double = 0
        var kernelMilliseconds: Double = 0
        var gpuMilliseconds: Double = 0
        var readbackMilliseconds: Double = 0
        /// The CGImage produced from readback, valid only when `ok` is true.
        var producedImage: CGImage? = nil
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

        let result = withLeasedSlot(key: key, source: source, metal: metal) { live -> SlotResult in
            var r = SlotResult(ok: false)

            // Finish any prior encode that owns the destination before rewriting it.
            let syncStarted = CFAbsoluteTimeGetCurrent()
            live.lastCommand?.waitUntilCompleted()
            r.syncMilliseconds = (CFAbsoluteTimeGetCurrent() - syncStarted) * 1000
            r.reusedDestinationTexture = true

            // Upload source only when the CGImage identity changes.
            if live.sourceIdentity != sourceID {
                guard let bytes = try? MeshWarpRaster.rgba8Bytes(from: source) else {
                    r.fallbackReason = "RGBA8 conversion failed"
                    return r
                }
                let uploadStarted = CFAbsoluteTimeGetCurrent()
                let stride = width * 4
                bytes.withUnsafeBytes { raw in
                    live.sourceTexture.replace(region: MTLRegionMake2D(0, 0, width, height),
                                               mipmapLevel: 0, withBytes: raw.baseAddress!,
                                               bytesPerRow: stride)
                }
                r.sourceUploadMilliseconds = (CFAbsoluteTimeGetCurrent() - uploadStarted) * 1000
                live.sourceIdentity = sourceID
                r.reusedSourceTexture = false
            } else {
                r.reusedSourceTexture = true
                r.sourceUploadMilliseconds = 0
            }

            let packed = MetalMeshWarp.pack(triangles)
            let triangleBytes = packed.count * MemoryLayout<MetalMeshWarp.TriangleGPU>.stride
            if live.triangleBuffer.length < triangleBytes {
                guard let grown = metal.device.makeBuffer(
                    length: max(triangleBytes, live.triangleBuffer.length * 2),
                    options: .storageModeShared)
                else {
                    r.fallbackReason = "triangle buffer grow failed"
                    return r
                }
                live.triangleBuffer = grown
            }

            let triUploadStarted = CFAbsoluteTimeGetCurrent()
            packed.withUnsafeBytes { raw in
                memcpy(live.triangleBuffer.contents(), raw.baseAddress!, triangleBytes)
            }
            r.triangleUploadMilliseconds = (CFAbsoluteTimeGetCurrent() - triUploadStarted) * 1000

            let threads = metal.texturePipeline.threadExecutionWidth
            guard threads > 0,
                  metal.texturePipeline.maxTotalThreadsPerThreadgroup >= threads,
                  let command = metal.queue.makeCommandBuffer(),
                  let encoder = command.makeComputeCommandEncoder()
            else {
                r.fallbackReason = "Metal command encoder failed"
                return r
            }

            var parameters = MetalMeshWarp.Parameters(
                width: UInt32(width), height: UInt32(height),
                stride: UInt32(width * 4), triangleCount: UInt32(packed.count))
            encoder.setComputePipelineState(metal.texturePipeline)
            encoder.setTexture(live.sourceTexture, index: 0)
            encoder.setTexture(live.destinationTexture, index: 1)
            encoder.setBuffer(live.triangleBuffer, offset: 0, index: 0)
            encoder.setBytes(&parameters, length: MemoryLayout<MetalMeshWarp.Parameters>.stride, index: 1)
            let groupHeight = max(1, metal.texturePipeline.maxTotalThreadsPerThreadgroup / threads)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: threads,
                                                                   height: groupHeight, depth: 1))
            encoder.endEncoding()

            let kernelStarted = CFAbsoluteTimeGetCurrent()
            command.commit()
            command.waitUntilCompleted()
            r.kernelMilliseconds = (CFAbsoluteTimeGetCurrent() - kernelStarted) * 1000
            if command.gpuStartTime != 0, command.gpuEndTime >= command.gpuStartTime {
                r.gpuMilliseconds = (command.gpuEndTime - command.gpuStartTime) * 1000
            }
            live.lastCommand = command

            guard command.status == .completed else {
                r.fallbackReason = "Metal command status \(command.status.rawValue)"
                return r
            }

            // Read back the destination texture while still holding the slot lease.
            let readbackStarted = CFAbsoluteTimeGetCurrent()
            let stride = width * 4
            var bytes = [UInt8](repeating: 0, count: stride * height)
            live.destinationTexture.getBytes(&bytes, bytesPerRow: stride,
                                             from: MTLRegionMake2D(0, 0, width, height),
                                             mipmapLevel: 0)
            r.readbackMilliseconds = (CFAbsoluteTimeGetCurrent() - readbackStarted) * 1000

            // Build the CGImage now, before releasing the slot.
            if let image = MeshWarpRaster.image(from: bytes, width: width, height: height,
                                                stride: stride) {
                r.ok = true
                r.fallbackReason = nil
                r.producedImage = image
            } else {
                r.fallbackReason = "CGImage creation from readback failed"
            }
            return r
        }

        // Merge SlotResult timing into the public sample.
        sample.allocationMilliseconds = result.allocationMilliseconds
        sample.syncMilliseconds = result.syncMilliseconds
        sample.sourceUploadMilliseconds = result.sourceUploadMilliseconds
        sample.triangleUploadMilliseconds = result.triangleUploadMilliseconds
        sample.kernelMilliseconds = result.kernelMilliseconds
        sample.gpuMilliseconds = result.gpuMilliseconds
        sample.readbackMilliseconds = result.readbackMilliseconds
        sample.reusedSourceTexture = result.reusedSourceTexture
        sample.reusedDestinationTexture = result.reusedDestinationTexture

        if result.ok, let image = result.producedImage {
            sample.usedMetal = true
            return image
        }

        // Metal failed or readback failed → fall back to CPU.
        sample.usedMetal = false
        if sample.fallbackReason == nil {
            sample.fallbackReason = result.fallbackReason ?? "CPU MeshWarpRaster"
        }
        return cpuFallback(source: source, mesh: mesh, sample: &sample)
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

    func invalidateAll() {
        lock.lock()
        for (_, slot) in slots {
            slot.lastCommand?.waitUntilCompleted()
        }
        slots.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func invalidate(width: Int, height: Int) {
        lock.lock()
        let key = Key(width: width, height: height)
        if let slot = slots[key] {
            slot.lastCommand?.waitUntilCompleted()
            slots[key] = nil
        }
        lock.unlock()
    }
}
