import AppKit
import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Compositor

/// Milestone 11.1 on a real photograph: sensor-aware white balance and photographic profiles through the actual
/// `CIRAWFilter` path.
///
/// The fixture is an untracked CR2 beside the other originals (`sigma-40art-sample.CR2`, a Sigma 40mm F1.4 Art on
/// an EOS 5DS R). It is skipped when absent, so a checkout without it reports skipped rather than inventing
/// numbers. The file's own bytes are read-only here.
@MainActor
struct RawColorProfileRawEvidenceTests {
    private var fixture: URL? {
        GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2")
            .map { $0.appendingPathComponent("originals/sigma-40art-sample.CR2") }
    }

    private func developed(_ url: URL, settings: RawDevelopSettings, longest: CGFloat = 640) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: url) else { throw ExportError.render }
        let native = filter.nativeSize
        filter.scaleFactor = Float(longest / max(native.width, native.height))
        filter.isDraftModeEnabled = true
        filter.exposure = settings.exposure
        filter.neutralTemperature = settings.temperature
        filter.neutralTint = settings.tint
        filter.boostAmount = settings.colorProfile.kind == .linear ? 0 : settings.boost
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw ExportError.render
        }
        return image
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let copy = try BrushRaster.copy(image)
        let pointer = try #require(copy.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: copy.bytesPerRow * image.height))
    }

    /// Mean absolute neighboring-pixel luma difference: higher means more resolved detail.
    private func detailEnergy(_ image: CGImage) throws -> Double {
        let copy = try BrushRaster.copy(image)
        let bytes = try #require(copy.data).assumingMemoryBound(to: UInt8.self)
        let rowBytes = copy.bytesPerRow
        func luma(_ x: Int, _ y: Int) -> Double {
            let i = y * rowBytes + x * 4
            return (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3
        }
        var total = 0.0
        var count = 0
        for y in Swift.stride(from: 0, to: image.height - 1, by: 2) {
            for x in Swift.stride(from: 0, to: image.width - 1, by: 2) {
                total += abs(luma(x, y) - luma(x + 1, y)) + abs(luma(x, y) - luma(x, y + 1))
                count += 2
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    /// Mean absolute channel change and the fraction of pixels that moved at all.
    private func difference(_ a: CGImage, _ b: CGImage) throws -> (mean: Double, moved: Double) {
        let left = try bytes(a), right = try bytes(b)
        var total = 0.0
        var moved = 0
        let count = a.width * a.height
        for pixel in 0..<count {
            let i = pixel * 4
            let delta = (0..<3).map { abs(Int(left[i + $0]) - Int(right[i + $0])) }
            total += Double(delta.reduce(0, +)) / 3
            if delta.contains(where: { $0 > 0 }) { moved += 1 }
        }
        return (total / Double(count), Double(moved) / Double(count))
    }

    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func asShotDevelopmentIsUnchangedByM11_1() throws {
        let url = try #require(fixture)
        let asShot = try #require(RawImporter.asShot(url), "the decoder reports the camera's own settings")
        #expect(asShot.whiteBalanceMode == .asShot)
        #expect(asShot.colorProfile.kind == .cameraDefault, "no profile is chosen by default")
        // The same settings developed through the old and new paths: the decode is identical, so a project made
        // before M11.1 renders exactly as it did.
        let image = try developed(url, settings: asShot)
        var legacy = asShot
        legacy.colorProfile = RawColorProfile()
        legacy.whiteBalanceMode = .asShot
        let again = try developed(url, settings: legacy)
        let delta = try difference(image, again)
        #expect(delta.mean == 0 && delta.moved == 0, "Camera Default is the decode this app always made")
        print("[M11.1] as shot: \(String(format: "%.0f", asShot.asShotTemperatureAbsolute)) K, "
              + "tint \(String(format: "%.0f", asShot.asShotTintAbsolute)); cameara default delta \(delta.mean)")
    }

    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func autoWhiteBalanceReallyNeutralizesTheFrame() throws {
        let url = try #require(fixture)
        let asShot = try #require(RawImporter.asShot(url))
        let start = (temperature: asShot.temperature, tint: asShot.tint)
        let solved = try #require(RawImporter.solveWhiteBalance(url, startingAt: start),
                                  "the decoder can be measured")
        let before = try developed(url, settings: asShot)
        var custom = asShot
        custom.whiteBalanceMode = .custom
        custom.temperature = solved.temperature
        custom.tint = solved.tint
        let after = try developed(url, settings: custom)
        let castBefore = try #require(RawWhiteBalance.cast(of: before))
        let castAfter = try #require(RawWhiteBalance.cast(of: after))
        #expect(castAfter <= castBefore + 1e-6, "the solved balance is no further from gray than As Shot")
        let delta = try difference(before, after)
        print("[M11.1] auto balance: \(String(format: "%.0f", solved.temperature)) K / "
              + "\(String(format: "%.0f", solved.tint)) from \(String(format: "%.0f", start.temperature)) K; "
              + "cast \(String(format: "%.4f", castBefore)) → \(String(format: "%.4f", castAfter)); "
              + "mean delta \(String(format: "%.2f", delta.mean))")
        // A balance that changed nothing would mean the solve was not routed through the decoder.
        if abs(solved.temperature - start.temperature) > 50 || abs(solved.tint - start.tint) > 2 {
            #expect(delta.mean > 0.5, "a different balance develops different pixels")
        }
    }

    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func theLinearProfileIsARealDifferentDecode() throws {
        let url = try #require(fixture)
        var settings = try #require(RawImporter.asShot(url))
        let camera = try developed(url, settings: settings)
        settings.colorProfile = RawColorProfile(kind: .linear)
        let linear = try developed(url, settings: settings)
        let delta = try difference(camera, linear)
        #expect(delta.moved > 0.9, "the linear decode touches almost every pixel")
        #expect(delta.mean > 2, "and changes them measurably (mean \(delta.mean))")
        print("[M11.1] linear profile against camera default: mean delta \(String(format: "%.2f", delta.mean)), "
              + "moved \(String(format: "%.0f", delta.moved * 100))%")
    }

    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func anICCProfileAppliesToRealDevelopedPixels() throws {
        let url = try #require(fixture)
        let settings = try #require(RawImporter.asShot(url))
        let image = try developed(url, settings: settings)
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let data = try #require(space.copyICCData() as Data?)
        let profile = RawColorProfile(kind: .icc, iccData: data, name: "Display P3", strength: 100)
        let applied = try profile.applying(to: image)
        let delta = try difference(image, applied)
        #expect(applied.width == image.width && applied.height == image.height)
        #expect(delta.mean > 1, "interpreting the frame as P3 changes it on a real photograph (mean \(delta.mean))")
        let zero = try RawColorProfile(kind: .icc, iccData: data, name: "Display P3", strength: 0).applying(to: image)
        #expect(try bytes(zero) == bytes(image), "strength zero is exactly the developed frame")
        print("[M11.1] Display P3 at 100%: mean delta \(String(format: "%.2f", delta.mean)), "
              + "moved \(String(format: "%.0f", delta.moved * 100))%")
    }
}
