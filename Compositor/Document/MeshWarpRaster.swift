import CoreGraphics
import Foundation
import simd

/// CPU reference for mesh warp: destination-to-source piecewise-affine sampling with
/// premultiplied bilinear fetches. Out-of-range neighbors contribute nothing (same edge
/// policy as Camera Raw volume).
nonisolated enum MeshWarpRaster {
    struct Timing: Sendable {
        var milliseconds: Double = 0
    }

    /// Warps `source` (premultiplied RGBA8, top-left rows) into a new same-sized image.
    /// Identity meshes copy bytes. Returns nil when the bitmap cannot be created.
    static func apply(source: CGImage, mesh: MeshWarpGrid, timing: inout Timing) -> CGImage? {
        let width = source.width, height = source.height
        guard width > 0, height > 0 else { return nil }
        guard let sourceBytes = try? rgba8Bytes(from: source) else { return nil }
        let stride = width * 4
        var destination = [UInt8](repeating: 0, count: stride * height)
        let started = CFAbsoluteTimeGetCurrent()
        apply(source: sourceBytes, destination: &destination, width: width, height: height, stride: stride, mesh: mesh)
        timing.milliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000
        return image(from: destination, width: width, height: height, stride: stride)
    }

    static func apply(source: [UInt8], destination: inout [UInt8],
                      width: Int, height: Int, stride: Int, mesh: MeshWarpGrid) {
        precondition(destination.count >= stride * height)
        precondition(source.count >= stride * height)
        if mesh.isIdentity {
            destination.withUnsafeMutableBytes { dest in
                source.withUnsafeBytes { src in
                    memcpy(dest.baseAddress!, src.baseAddress!, stride * height)
                }
            }
            return
        }
        destination.withUnsafeMutableBytes { dest in
            let out = dest.bindMemory(to: UInt8.self).baseAddress!
            source.withUnsafeBytes { src in
                let input = src.bindMemory(to: UInt8.self).baseAddress!
                raster(source: input, destination: out, width: width, height: height, stride: stride, mesh: mesh)
            }
        }
    }

    private static func raster(source: UnsafePointer<UInt8>, destination: UnsafeMutablePointer<UInt8>,
                               width: Int, height: Int, stride: Int, mesh: MeshWarpGrid) {
        let triangles = mesh.triangles()
        let sx = Float(max(width - 1, 1)), sy = Float(max(height - 1, 1))
        // Clear to transparent.
        memset(destination, 0, stride * height)

        for triangle in triangles {
            let d0 = triangle.destination.0, d1 = triangle.destination.1, d2 = triangle.destination.2
            let s0 = triangle.source.0, s1 = triangle.source.1, s2 = triangle.source.2
            let area = MeshWarpGrid.signedArea(d0, d1, d2)
            guard abs(area) >= MeshWarpGrid.minimumTriangleArea else { continue }

            let minU = max(0, min(d0.x, min(d1.x, d2.x)))
            let maxU = min(1, max(d0.x, max(d1.x, d2.x)))
            let minV = max(0, min(d0.y, min(d1.y, d2.y)))
            let maxV = min(1, max(d0.y, max(d1.y, d2.y)))
            let x0 = max(0, Int(floor(minU * Float(width))))
            let x1 = min(width - 1, Int(ceil(maxU * Float(width))))
            let y0 = max(0, Int(floor(minV * Float(height))))
            let y1 = min(height - 1, Int(ceil(maxV * Float(height))))
            guard x0 <= x1, y0 <= y1 else { continue }

            let invArea = 1 / area
            for y in y0...y1 {
                let v = (Float(y) + 0.5) / Float(height)
                for x in x0...x1 {
                    let u = (Float(x) + 0.5) / Float(width)
                    let p = SIMD2<Float>(u, v)
                    let w0 = MeshWarpGrid.signedArea(d1, d2, p) * invArea
                    let w1 = MeshWarpGrid.signedArea(d2, d0, p) * invArea
                    let w2 = MeshWarpGrid.signedArea(d0, d1, p) * invArea
                    // Inclusive edge bias so shared edges are covered once without gaps.
                    if w0 < -1e-5 || w1 < -1e-5 || w2 < -1e-5 { continue }
                    let sourceUV = s0 * w0 + s1 * w1 + s2 * w2
                    let sampleX = sourceUV.x * sx
                    let sampleY = sourceUV.y * sy
                    let pixel = samplePremultiplied(source: source, width: width, height: height, stride: stride,
                                                    x: sampleX, y: sampleY)
                    let offset = y * stride + x * 4
                    destination[offset] = pixel.0
                    destination[offset + 1] = pixel.1
                    destination[offset + 2] = pixel.2
                    destination[offset + 3] = pixel.3
                }
            }
        }
    }

    /// Premultiplied bilinear. Missing neighbors contribute 0.
    static func samplePremultiplied(source: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int,
                                    x: Float, y: Float) -> (UInt8, UInt8, UInt8, UInt8) {
        let x0 = floor(x), y0 = floor(y)
        let fx = x - x0, fy = y - y0
        let ix0 = Int(x0), iy0 = Int(y0)
        let ix1 = ix0 + 1, iy1 = iy0 + 1
        func fetch(_ ix: Int, _ iy: Int) -> SIMD4<Float> {
            guard ix >= 0, iy >= 0, ix < width, iy < height else { return .zero }
            let o = iy * stride + ix * 4
            return SIMD4(Float(source[o]), Float(source[o + 1]), Float(source[o + 2]), Float(source[o + 3]))
        }
        let c00 = fetch(ix0, iy0), c10 = fetch(ix1, iy0), c01 = fetch(ix0, iy1), c11 = fetch(ix1, iy1)
        let top = c00 + (c10 - c00) * fx
        let bottom = c01 + (c11 - c01) * fx
        let mixed = top + (bottom - top) * fy
        return (UInt8(max(0, min(255, mixed.x.rounded()))),
                UInt8(max(0, min(255, mixed.y.rounded()))),
                UInt8(max(0, min(255, mixed.z.rounded()))),
                UInt8(max(0, min(255, mixed.w.rounded()))))
    }

    static func rgba8Bytes(from image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height, stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        let color = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: stride, space: color, bitmapInfo: info) else {
            throw ExportError.render
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    static func image(from bytes: [UInt8], width: Int, height: Int, stride: Int) -> CGImage? {
        let color = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        return bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: UnsafeMutableRawPointer(mutating: base),
                                          width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: stride, space: color, bitmapInfo: info)
            else { return nil }
            return context.makeImage()
        }
    }
}
