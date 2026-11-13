import CoreGraphics
import CoreImage
import Foundation
import Metal
import Synchronization

/// GPU mesh warp matching `MeshWarpRaster`. Destination pixels find their source UV through
/// the first covering destination triangle; premultiplied bilinear with missing neighbors at 0.
nonisolated final class MetalMeshWarp: Sendable {
    static let shared: MetalMeshWarp? = try? MetalMeshWarp()

    struct Sample: Sendable {
        var uploadMilliseconds: Double = 0
        var kernelMilliseconds: Double = 0
        var readbackMilliseconds: Double = 0
        var gpuMilliseconds: Double = 0
        var triangleUploadMilliseconds: Double = 0
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let bufferPipeline: MTLComputePipelineState
    let texturePipeline: MTLComputePipelineState
    private struct Buffers {
        let source: MTLBuffer
        let destination: MTLBuffer
        let triangles: MTLBuffer
    }
    private let buffers = Mutex<Buffers?>(nil)

    struct Parameters {
        var width: UInt32
        var height: UInt32
        var stride: UInt32
        var triangleCount: UInt32
    }

    struct TriangleGPU {
        var d0x: Float, d0y: Float, d1x: Float, d1y: Float, d2x: Float, d2y: Float
        var s0x: Float, s0y: Float, s1x: Float, s1y: Float, s2x: Float, s2y: Float
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ExportError.render
        }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library = try device.makeLibrary(source: Self.source, options: options)
        guard let bufferFunction = library.makeFunction(name: "mesh_warp"),
              let textureFunction = library.makeFunction(name: "mesh_warp_texture")
        else { throw ExportError.render }
        self.device = device
        self.queue = queue
        bufferPipeline = try device.makeComputePipelineState(function: bufferFunction)
        texturePipeline = try device.makeComputePipelineState(function: textureFunction)
    }

    /// Writes `destination` only after success. Identity meshes should stay on the CPU memcpy path.
    func apply(source: UnsafePointer<UInt8>, destination: UnsafeMutablePointer<UInt8>,
               width: Int, height: Int, stride: Int, mesh: MeshWarpGrid, sample: inout Sample) -> Bool {
        guard width > 0, height > 0, stride >= width * 4,
              width <= Int(UInt32.max), height <= Int(UInt32.max), stride <= Int(UInt32.max) else { return false }
        let triangles = mesh.triangles()
        guard !triangles.isEmpty, triangles.count <= Int(UInt32.max) else { return false }
        let bytes = stride * height
        let triangleBytes = triangles.count * MemoryLayout<TriangleGPU>.stride
        guard bytes > 0, bytes <= device.maxBufferLength, triangleBytes <= device.maxBufferLength else { return false }
        let threads = bufferPipeline.threadExecutionWidth
        guard threads > 0, bufferPipeline.maxTotalThreadsPerThreadgroup >= threads else { return false }

        let packed = Self.pack(triangles)
        return buffers.withLock { storage in
            if storage == nil || storage!.source.length < bytes || storage!.destination.length < bytes
                || storage!.triangles.length < triangleBytes {
                guard let sourceBuffer = device.makeBuffer(length: bytes, options: .storageModeShared),
                      let destinationBuffer = device.makeBuffer(length: bytes, options: .storageModeShared),
                      let triangleBuffer = device.makeBuffer(length: max(triangleBytes, 256), options: .storageModeShared)
                else { return false }
                storage = Buffers(source: sourceBuffer, destination: destinationBuffer, triangles: triangleBuffer)
            }
            guard let ready = storage, let command = queue.makeCommandBuffer(),
                  let encoder = command.makeComputeCommandEncoder() else { return false }

            let uploadStarted = CFAbsoluteTimeGetCurrent()
            memcpy(ready.source.contents(), source, bytes)
            _ = packed.withUnsafeBytes { raw in
                memcpy(ready.triangles.contents(), raw.baseAddress!, triangleBytes)
            }
            sample.uploadMilliseconds = (CFAbsoluteTimeGetCurrent() - uploadStarted) * 1000

            var parameters = Parameters(width: UInt32(width), height: UInt32(height), stride: UInt32(stride),
                                        triangleCount: UInt32(triangles.count))
            encoder.setComputePipelineState(bufferPipeline)
            encoder.setBuffer(ready.source, offset: 0, index: 0)
            encoder.setBuffer(ready.destination, offset: 0, index: 1)
            encoder.setBuffer(ready.triangles, offset: 0, index: 2)
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 3)
            let groupHeight = max(1, bufferPipeline.maxTotalThreadsPerThreadgroup / threads)
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
            let row = width * 4
            if stride == row {
                memcpy(destination, ready.destination.contents(), bytes)
            } else {
                let gpu = ready.destination.contents().assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    memcpy(destination + y * stride, gpu + y * stride, row)
                }
            }
            sample.readbackMilliseconds = (CFAbsoluteTimeGetCurrent() - readbackStarted) * 1000
            return true
        }
    }

    func apply(source: UnsafePointer<UInt8>, destination: UnsafeMutablePointer<UInt8>,
               width: Int, height: Int, stride: Int, mesh: MeshWarpGrid) -> Bool {
        var sample = Sample()
        return apply(source: source, destination: destination, width: width, height: height, stride: stride,
                     mesh: mesh, sample: &sample)
    }

    static func pack(_ triangles: [MeshWarpTriangle]) -> [TriangleGPU] {
        var packed = [TriangleGPU]()
        packed.reserveCapacity(triangles.count)
        for triangle in triangles {
            packed.append(TriangleGPU(
                d0x: triangle.destination.0.x, d0y: triangle.destination.0.y,
                d1x: triangle.destination.1.x, d1y: triangle.destination.1.y,
                d2x: triangle.destination.2.x, d2y: triangle.destination.2.y,
                s0x: triangle.source.0.x, s0y: triangle.source.0.y,
                s1x: triangle.source.1.x, s1y: triangle.source.1.y,
                s2x: triangle.source.2.x, s2y: triangle.source.2.y))
        }
        return packed
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Parameters {
        uint width;
        uint height;
        uint stride;
        uint triangleCount;
    };

    struct Triangle {
        float d0x, d0y, d1x, d1y, d2x, d2y;
        float s0x, s0y, s1x, s1y, s2x, s2y;
    };

    inline float signed_area(float2 a, float2 b, float2 c) {
        return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    }

    inline float4 fetch(const device uchar *source, uint width, uint height, uint stride, int ix, int iy) {
        if (ix < 0 || iy < 0 || ix >= (int)width || iy >= (int)height) return float4(0);
        uint o = uint(iy) * stride + uint(ix) * 4u;
        return float4(source[o], source[o + 1], source[o + 2], source[o + 3]);
    }

    inline uchar4 sample_premultiplied(const device uchar *source, uint width, uint height, uint stride,
                                       float x, float y) {
        float x0 = floor(x), y0 = floor(y);
        float fx = x - x0, fy = y - y0;
        int ix0 = int(x0), iy0 = int(y0);
        float4 c00 = fetch(source, width, height, stride, ix0, iy0);
        float4 c10 = fetch(source, width, height, stride, ix0 + 1, iy0);
        float4 c01 = fetch(source, width, height, stride, ix0, iy0 + 1);
        float4 c11 = fetch(source, width, height, stride, ix0 + 1, iy0 + 1);
        float4 top = c00 + (c10 - c00) * fx;
        float4 bottom = c01 + (c11 - c01) * fx;
        float4 mixed = top + (bottom - top) * fy;
        return uchar4(uchar(clamp(round(mixed.x), 0.0f, 255.0f)),
                      uchar(clamp(round(mixed.y), 0.0f, 255.0f)),
                      uchar(clamp(round(mixed.z), 0.0f, 255.0f)),
                      uchar(clamp(round(mixed.w), 0.0f, 255.0f)));
    }

    kernel void mesh_warp(device const uchar *source [[buffer(0)]],
                          device uchar *destination [[buffer(1)]],
                          device const Triangle *triangles [[buffer(2)]],
                          constant Parameters &params [[buffer(3)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= params.width || gid.y >= params.height) return;
        uint offset = gid.y * params.stride + gid.x * 4u;
        destination[offset] = 0;
        destination[offset + 1] = 0;
        destination[offset + 2] = 0;
        destination[offset + 3] = 0;

        float u = (float(gid.x) + 0.5f) / float(params.width);
        float v = (float(gid.y) + 0.5f) / float(params.height);
        float2 p = float2(u, v);
        float sx = float(max(params.width, 1u) - 1u);
        float sy = float(max(params.height, 1u) - 1u);

        for (uint i = 0; i < params.triangleCount; ++i) {
            Triangle t = triangles[i];
            float2 d0 = float2(t.d0x, t.d0y);
            float2 d1 = float2(t.d1x, t.d1y);
            float2 d2 = float2(t.d2x, t.d2y);
            float area = signed_area(d0, d1, d2);
            if (fabs(area) < 1e-8f) continue;
            float inv = 1.0f / area;
            float w0 = signed_area(d1, d2, p) * inv;
            float w1 = signed_area(d2, d0, p) * inv;
            float w2 = signed_area(d0, d1, p) * inv;
            if (w0 < -1e-5f || w1 < -1e-5f || w2 < -1e-5f) continue;
            float2 s0 = float2(t.s0x, t.s0y);
            float2 s1 = float2(t.s1x, t.s1y);
            float2 s2 = float2(t.s2x, t.s2y);
            float2 sourceUV = s0 * w0 + s1 * w1 + s2 * w2;
            uchar4 pixel = sample_premultiplied(source, params.width, params.height, params.stride,
                                                sourceUV.x * sx, sourceUV.y * sy);
            destination[offset] = pixel.x;
            destination[offset + 1] = pixel.y;
            destination[offset + 2] = pixel.z;
            destination[offset + 3] = pixel.w;
            return;
        }
    }

    inline float4 fetch_tex(texture2d<float, access::read> source, uint width, uint height, int ix, int iy) {
        if (ix < 0 || iy < 0 || ix >= (int)width || iy >= (int)height) return float4(0);
        return source.read(uint2(uint(ix), uint(iy)));
    }

    inline float4 sample_premultiplied_tex(texture2d<float, access::read> source, uint width, uint height,
                                           float x, float y) {
        float x0 = floor(x), y0 = floor(y);
        float fx = x - x0, fy = y - y0;
        int ix0 = int(x0), iy0 = int(y0);
        float4 c00 = fetch_tex(source, width, height, ix0, iy0);
        float4 c10 = fetch_tex(source, width, height, ix0 + 1, iy0);
        float4 c01 = fetch_tex(source, width, height, ix0, iy0 + 1);
        float4 c11 = fetch_tex(source, width, height, ix0 + 1, iy0 + 1);
        float4 top = c00 + (c10 - c00) * fx;
        float4 bottom = c01 + (c11 - c01) * fx;
        float4 mixed = top + (bottom - top) * fy;
        // Match the buffer path's 8-bit rounding.
        return float4(round(clamp(mixed.x, 0.0f, 1.0f) * 255.0f),
                      round(clamp(mixed.y, 0.0f, 1.0f) * 255.0f),
                      round(clamp(mixed.z, 0.0f, 1.0f) * 255.0f),
                      round(clamp(mixed.w, 0.0f, 1.0f) * 255.0f)) / 255.0f;
    }

    kernel void mesh_warp_texture(texture2d<float, access::read> source [[texture(0)]],
                                  texture2d<float, access::write> destination [[texture(1)]],
                                  device const Triangle *triangles [[buffer(0)]],
                                  constant Parameters &params [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= params.width || gid.y >= params.height) return;
        destination.write(float4(0), gid);

        float u = (float(gid.x) + 0.5f) / float(params.width);
        float v = (float(gid.y) + 0.5f) / float(params.height);
        float2 p = float2(u, v);
        float sx = float(max(params.width, 1u) - 1u);
        float sy = float(max(params.height, 1u) - 1u);

        for (uint i = 0; i < params.triangleCount; ++i) {
            Triangle t = triangles[i];
            float2 d0 = float2(t.d0x, t.d0y);
            float2 d1 = float2(t.d1x, t.d1y);
            float2 d2 = float2(t.d2x, t.d2y);
            float area = signed_area(d0, d1, d2);
            if (fabs(area) < 1e-8f) continue;
            float inv = 1.0f / area;
            float w0 = signed_area(d1, d2, p) * inv;
            float w1 = signed_area(d2, d0, p) * inv;
            float w2 = signed_area(d0, d1, p) * inv;
            if (w0 < -1e-5f || w1 < -1e-5f || w2 < -1e-5f) continue;
            float2 s0 = float2(t.s0x, t.s0y);
            float2 s1 = float2(t.s1x, t.s1y);
            float2 s2 = float2(t.s2x, t.s2y);
            float2 sourceUV = s0 * w0 + s1 * w1 + s2 * w2;
            float4 pixel = sample_premultiplied_tex(source, params.width, params.height,
                                                    sourceUV.x * sx, sourceUV.y * sy);
            destination.write(pixel, gid);
            return;
        }
    }
    """
}

/// One ReShape edit's GPU working set: source uploaded once, destination reused, triangles updated per drag.
/// Exposes a `CIImage` for the canvas without copying pixels back each frame.
@MainActor
final class MetalMeshWarpSession {
    let width: Int
    let height: Int
    private let metal: MetalMeshWarp
    private let sourceTexture: MTLTexture
    private let destinationTexture: MTLTexture
    private var triangleBuffer: MTLBuffer
    private var triangleCapacity: Int
    private var lastCommand: MTLCommandBuffer?
    private var generation: UInt64 = 0
    private let colorSpace: CGColorSpace

    struct Sample {
        var triangleUploadMilliseconds: Double = 0
        var kernelMilliseconds: Double = 0
        var gpuMilliseconds: Double = 0
        var endToEndMilliseconds: Double = 0
        var generation: UInt64 = 0
    }

    init?(image: CGImage) {
        guard let metal = MetalMeshWarp.shared,
              let bytes = try? MeshWarpRaster.rgba8Bytes(from: image) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let source = metal.device.makeTexture(descriptor: descriptor),
              let destination = metal.device.makeTexture(descriptor: descriptor),
              let triangles = metal.device.makeBuffer(length: 4096, options: .storageModeShared)
        else { return nil }
        let stride = width * 4
        source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                       withBytes: bytes, bytesPerRow: stride)
        self.metal = metal
        self.width = width
        self.height = height
        self.sourceTexture = source
        self.destinationTexture = destination
        self.triangleBuffer = triangles
        self.triangleCapacity = triangles.length / MemoryLayout<MetalMeshWarp.TriangleGPU>.stride
        self.colorSpace = GPUCanvasRenderer.shared?.space ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// Live preview for the GPU canvas. Core Image synchronizes with the last submitted command.
    var image: CIImage? {
        CIImage(mtlTexture: destinationTexture, options: [.colorSpace: colorSpace])
    }

    /// Encodes a warp into the destination texture. Source stays untouched across calls.
    @discardableResult
    func render(mesh: MeshWarpGrid, sample: inout Sample, wait: Bool = true) -> Bool {
        let started = CFAbsoluteTimeGetCurrent()
        defer { sample.endToEndMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000 }
        guard !mesh.isIdentity else { return false }
        let triangles = mesh.triangles()
        guard !triangles.isEmpty else { return false }
        let packed = MetalMeshWarp.pack(triangles)
        let triangleBytes = packed.count * MemoryLayout<MetalMeshWarp.TriangleGPU>.stride
        if triangleBuffer.length < triangleBytes {
            guard let grown = metal.device.makeBuffer(length: max(triangleBytes, triangleBuffer.length * 2),
                                                      options: .storageModeShared) else { return false }
            triangleBuffer = grown
            triangleCapacity = grown.length / MemoryLayout<MetalMeshWarp.TriangleGPU>.stride
        }
        let threads = metal.texturePipeline.threadExecutionWidth
        guard threads > 0, metal.texturePipeline.maxTotalThreadsPerThreadgroup >= threads,
              let command = metal.queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return false }

        // Finish any prior encode that owns the destination before rewriting it.
        lastCommand?.waitUntilCompleted()

        let uploadStarted = CFAbsoluteTimeGetCurrent()
        _ = packed.withUnsafeBytes { raw in
            memcpy(triangleBuffer.contents(), raw.baseAddress!, triangleBytes)
        }
        sample.triangleUploadMilliseconds = (CFAbsoluteTimeGetCurrent() - uploadStarted) * 1000

        generation &+= 1
        sample.generation = generation
        var parameters = MetalMeshWarp.Parameters(width: UInt32(width), height: UInt32(height),
                                                  stride: UInt32(width * 4), triangleCount: UInt32(packed.count))
        encoder.setComputePipelineState(metal.texturePipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(destinationTexture, index: 1)
        encoder.setBuffer(triangleBuffer, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<MetalMeshWarp.Parameters>.stride, index: 1)
        let groupHeight = max(1, metal.texturePipeline.maxTotalThreadsPerThreadgroup / threads)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: threads, height: groupHeight, depth: 1))
        encoder.endEncoding()

        let kernelStarted = CFAbsoluteTimeGetCurrent()
        command.commit()
        lastCommand = command
        if wait {
            command.waitUntilCompleted()
            sample.kernelMilliseconds = (CFAbsoluteTimeGetCurrent() - kernelStarted) * 1000
            if command.gpuStartTime != 0, command.gpuEndTime >= command.gpuStartTime {
                sample.gpuMilliseconds = (command.gpuEndTime - command.gpuStartTime) * 1000
            }
            return command.status == .completed
        }
        sample.kernelMilliseconds = (CFAbsoluteTimeGetCurrent() - kernelStarted) * 1000
        return true
    }

    /// Full-resolution pixels for Apply. Waits for the latest command.
    func readbackCGImage(sample: inout MetalMeshWarp.Sample) -> CGImage? {
        let readbackStarted = CFAbsoluteTimeGetCurrent()
        lastCommand?.waitUntilCompleted()
        let stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        destinationTexture.getBytes(&bytes, bytesPerRow: stride,
                                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        sample.readbackMilliseconds = (CFAbsoluteTimeGetCurrent() - readbackStarted) * 1000
        return MeshWarpRaster.image(from: bytes, width: width, height: height, stride: stride)
    }

    func invalidate() {
        generation &+= 1
        lastCommand?.waitUntilCompleted()
        lastCommand = nil
    }

    deinit {
        lastCommand?.waitUntilCompleted()
    }
}

/// Chooses Metal when available and the mesh is non-identity; otherwise the CPU raster.
nonisolated enum MeshWarpRenderer {
    struct Sample: Sendable {
        var usedMetal: Bool = false
        var uploadMilliseconds: Double = 0
        var kernelMilliseconds: Double = 0
        var readbackMilliseconds: Double = 0
        var gpuMilliseconds: Double = 0
        var cpuMilliseconds: Double = 0
        var endToEndMilliseconds: Double = 0
        var triangleUploadMilliseconds: Double = 0
        var usedResidentPreview: Bool = false
    }

    static func apply(source: CGImage, mesh: MeshWarpGrid, sample: inout Sample) -> CGImage? {
        let started = CFAbsoluteTimeGetCurrent()
        defer { sample.endToEndMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000 }
        guard let bytes = try? MeshWarpRaster.rgba8Bytes(from: source) else { return nil }
        let width = source.width, height = source.height, stride = width * 4
        var destination = [UInt8](repeating: 0, count: stride * height)

        if mesh.isIdentity {
            var timing = MeshWarpRaster.Timing()
            let image = MeshWarpRaster.apply(source: source, mesh: mesh, timing: &timing)
            sample.cpuMilliseconds = timing.milliseconds
            sample.usedMetal = false
            return image
        }

        let metalOK: Bool = destination.withUnsafeMutableBufferPointer { dest in
            bytes.withUnsafeBufferPointer { src in
                guard let metal = MetalMeshWarp.shared else { return false }
                var metalSample = MetalMeshWarp.Sample()
                let ok = metal.apply(source: src.baseAddress!, destination: dest.baseAddress!,
                                     width: width, height: height, stride: stride, mesh: mesh, sample: &metalSample)
                if ok {
                    sample.usedMetal = true
                    sample.uploadMilliseconds = metalSample.uploadMilliseconds
                    sample.kernelMilliseconds = metalSample.kernelMilliseconds
                    sample.readbackMilliseconds = metalSample.readbackMilliseconds
                    sample.gpuMilliseconds = metalSample.gpuMilliseconds
                }
                return ok
            }
        }

        if !metalOK {
            let cpuStarted = CFAbsoluteTimeGetCurrent()
            MeshWarpRaster.apply(source: bytes, destination: &destination, width: width, height: height,
                                 stride: stride, mesh: mesh)
            sample.cpuMilliseconds = (CFAbsoluteTimeGetCurrent() - cpuStarted) * 1000
            sample.usedMetal = false
        }
        return MeshWarpRaster.image(from: destination, width: width, height: height, stride: stride)
    }
}
