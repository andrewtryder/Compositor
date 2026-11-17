import Foundation
import Metal
import Synchronization

/// GPU volume deformation. The CPU `volume_deform` stays the reference and the fallback.
/// Sampling is done in the shader, not with a texture sampler: a sampler would clamp at the
/// edge and blend straight alpha, and the CPU lets missing neighbors contribute nothing.
nonisolated final class MetalCameraRawVolume: Sendable {
    static let shared: MetalCameraRawVolume? = try? MetalCameraRawVolume()

    struct Sample: Sendable {
        var uploadMilliseconds: Double = 0
        var kernelMilliseconds: Double = 0
        var readbackMilliseconds: Double = 0
        /// Device execution of the command buffer. Zero when the device does not report it.
        var gpuMilliseconds: Double = 0
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private struct Buffers {
        let source: MTLBuffer
        let destination: MTLBuffer
    }
    private let buffers = Mutex<Buffers?>(nil)

    private struct Parameters {
        var width: UInt32
        var height: UInt32
        var stride: UInt32
        var mode: UInt32
        var strengthH: Float
        var strengthV: Float
        var strengthR: Float
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw ExportError.render }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library = try device.makeLibrary(source: Self.source, options: options)
        guard let function = library.makeFunction(name: "volume_deform") else { throw ExportError.render }
        self.device = device
        self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)
    }

    /// Writes `destination` only after the command buffer completes. On failure the caller keeps the CPU result.
    func apply(source: UnsafePointer<UInt8>, destination: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int,
               strengthH: Double, strengthV: Double, strengthR: Double, mode: Int32, sample: inout Sample) -> Bool {
        guard width > 0, height > 0, stride >= width * 4,
              width <= Int(UInt32.max), height <= Int(UInt32.max), stride <= Int(UInt32.max) else { return false }
        let bytes = stride * height
        guard bytes > 0, bytes <= device.maxBufferLength else { return false }
        let threads = pipeline.threadExecutionWidth
        guard threads > 0, pipeline.maxTotalThreadsPerThreadgroup >= threads else { return false }
        return buffers.withLock { storage in
            if storage == nil || storage!.source.length < bytes || storage!.destination.length < bytes {
                guard let sourceBuffer = device.makeBuffer(length: bytes, options: .storageModeShared),
                      let destinationBuffer = device.makeBuffer(length: bytes, options: .storageModeShared) else { return false }
                storage = Buffers(source: sourceBuffer, destination: destinationBuffer)
            }
            guard let ready = storage, let command = queue.makeCommandBuffer(),
                  let encoder = command.makeComputeCommandEncoder() else { return false }
            let uploadStarted = CFAbsoluteTimeGetCurrent()
            memcpy(ready.source.contents(), source, bytes)
            sample.uploadMilliseconds = (CFAbsoluteTimeGetCurrent() - uploadStarted) * 1000
            var parameters = Parameters(width: UInt32(width), height: UInt32(height), stride: UInt32(stride), mode: UInt32(bitPattern: mode),
                                        strengthH: Float(strengthH), strengthV: Float(strengthV), strengthR: Float(strengthR))
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(ready.source, offset: 0, index: 0)
            encoder.setBuffer(ready.destination, offset: 0, index: 1)
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 2)
            let groupHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threads)
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
            guard command.status == .completed else { return false }
            let readbackStarted = CFAbsoluteTimeGetCurrent()
            // Copy only the pixel bytes. Row padding is not part of the warp, and the CPU leaves it alone.
            let row = width * 4
            if stride == row {
                memcpy(destination, ready.destination.contents(), bytes)
            } else {
                let gpuBytes = ready.destination.contents().assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    memcpy(destination + y * stride, gpuBytes + y * stride, row)
                }
            }
            sample.readbackMilliseconds = (CFAbsoluteTimeGetCurrent() - readbackStarted) * 1000
            return true
        }
    }

    func apply(source: UnsafePointer<UInt8>, destination: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int,
               strengthH: Double, strengthV: Double, strengthR: Double, mode: Int32) -> Bool {
        var sample = Sample()
        return apply(source: source, destination: destination, width: width, height: height, stride: stride,
                     strengthH: strengthH, strengthV: strengthV, strengthR: strengthR, mode: mode, sample: &sample)
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Parameters {
        uint width; uint height; uint stride; uint mode;
        float strengthH; float strengthV; float strengthR;
    };
    // Same closed form as compute_anamorphosis. fastMath is off so sqrt stays IEEE.
    static float anamorphosis(float a, float b) {
        if (b <= 0.0f) return a;
        float t = b * sqrt(4.0f * a * a + b * b) - b * b;
        if (t < 0.0f) return a;
        float r = sqrt(t * 0.5f);
        return a < 0.0f ? -r : r;
    }
    // Premultiplied bytes. A neighbor outside the buffer adds nothing, matching sample_bilinear.
    static uchar4 sample_bilinear(device const uchar *source, uint width, uint height, uint stride, float sx, float sy) {
        float x0f = floor(sx), y0f = floor(sy);
        float fx = sx - x0f, fy = sy - y0f;
        int x0 = int(x0f), y0 = int(y0f);
        float4 sums = float4(0.0f);
        for (int j = 0; j < 2; ++j) {
            int row = y0 + j;
            if (row < 0 || row >= int(height)) continue;
            float wy = j ? fy : 1.0f - fy;
            if (wy == 0.0f) continue;
            for (int i = 0; i < 2; ++i) {
                int column = x0 + i;
                if (column < 0 || column >= int(width)) continue;
                float weight = wy * (i ? fx : 1.0f - fx);
                if (weight == 0.0f) continue;
                uint at = uint(row) * stride + uint(column) * 4u;
                sums += weight * float4(source[at], source[at + 1], source[at + 2], source[at + 3]);
            }
        }
        // lround on a non-negative sum is round-half-away-from-zero, which is Metal's round().
        return uchar4(clamp(round(sums), 0.0f, 255.0f));
    }
    kernel void volume_deform(device const uchar *source [[buffer(0)]], device uchar *destination [[buffer(1)]],
                              constant Parameters &p [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        uint at = gid.y * p.stride + gid.x * 4u;
        bool identity = (p.mode == 0u && p.strengthR <= 0.0f) || (p.mode == 1u && p.strengthH <= 0.0f)
            || (p.mode == 2u && p.strengthV <= 0.0f)
            || (p.mode == 3u && p.strengthH <= 0.0f && p.strengthV <= 0.0f);
        if (identity) {
            destination[at] = source[at]; destination[at + 1] = source[at + 1];
            destination[at + 2] = source[at + 2]; destination[at + 3] = source[at + 3];
            return;
        }
        float halfW = float(p.width) * 0.5f, halfH = float(p.height) * 0.5f;
        float nx = ((float(gid.x) + 0.5f) / halfW) - 1.0f;
        float ny = ((float(gid.y) + 0.5f) / halfH) - 1.0f;
        float sx = nx, sy = ny;
        if (p.mode == 0u) {
            float radius = sqrt(sx * sx + sy * sy);
            if (radius > 1e-9f && p.strengthR > 0.0f) {
                float scale = anamorphosis(radius, p.strengthR) / radius;
                sx *= scale; sy *= scale;
            }
        } else if (p.mode == 1u) {
            if (p.strengthH > 0.0f) sx = anamorphosis(sx, p.strengthH);
        } else if (p.mode == 2u) {
            if (p.strengthV > 0.0f) sy = anamorphosis(sy, p.strengthV);
        } else {
            if (p.strengthH > 0.0f) sx = anamorphosis(sx, p.strengthH);
            if (p.strengthV > 0.0f) sy = anamorphosis(sy, p.strengthV);
        }
        float srcX = (sx + 1.0f) * halfW - 0.5f;
        float srcY = (sy + 1.0f) * halfH - 0.5f;
        uchar4 pixel = sample_bilinear(source, p.width, p.height, p.stride, srcX, srcY);
        destination[at] = pixel.r; destination[at + 1] = pixel.g; destination[at + 2] = pixel.b; destination[at + 3] = pixel.a;
    }
    """
}
