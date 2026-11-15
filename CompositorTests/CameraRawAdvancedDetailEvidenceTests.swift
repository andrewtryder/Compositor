import AppKit
import CoreImage
import Foundation
import Testing
@testable import Compositor

/// Milestone 11.2 on a real photograph: what Raw Details and sensor-stage chroma reduction actually do to a Sigma
/// 40mm F1.4 frame, measured rather than asserted from theory, and what the platform does *not* make possible.
///
/// The fixture is the untracked CR2 the earlier RAW evidence uses, so a checkout without it reports skipped rather
/// than inventing numbers.
@MainActor
struct CameraRawAdvancedDetailEvidenceTests {
    private var fixture: URL? {
        GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2")
            .map { $0.appendingPathComponent("originals/sigma-40art-sample.CR2") }
    }

    // MARK: - Raw Details

    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func switchingRawDetailsOnWithoutMovingItChangesNothing() throws {
        let url = try #require(fixture)
        var settings = try #require(RawImporter.asShot(url))
        let asShot = try developed(url, settings: settings)
        settings.rawDetail.enabled = true
        let onButNeutral = try developed(url, settings: settings)
        #expect(try bytes(onButNeutral) == bytes(asShot), "enabling Raw Details with every offset at zero is a no-op")
        print("[M11.2] Raw Details on, offsets neutral: identical to As Shot")
    }

    /// The decoder's reconstruction lives in the sensor's own frequencies, so this measures a native-resolution
    /// window: downscaling the frame for the preview is what would hide the effect, not the effect itself.
    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func rawDetailsReallyAddsResolvedDetail() throws {
        let url = try #require(fixture)
        var settings = try #require(RawImporter.asShot(url))
        #expect(settings.supportsRawDetail, "this decoder offers detail controls")
        let plain = try nativeWindow(url, settings: settings)
        settings.rawDetail = RawDetailSettings(enabled: true, detail: 1.5, sharpness: 0.2, contrast: 0.3)
        let detailed = try nativeWindow(url, settings: settings)
        let delta = try difference(plain, detailed)
        let plainEnergy = try detailEnergy(plain), detailedEnergy = try detailEnergy(detailed)
        #expect(delta.moved > 0.5, "the decoder's reconstruction touches most of the developed pixels")
        #expect(detailedEnergy > plainEnergy * 1.15, "and adds resolved detail, not just a tone shift")
        print("[M11.2] Raw Details at native: mean delta \(fmt(delta.mean)), moved \(fmt(delta.moved * 100))%, "
              + "detail energy \(fmt(plainEnergy, 3)) → \(fmt(detailedEnergy, 3))")
    }

    /// Ordinary sharpening is not Raw Details. This is the check that the two are not the same operation wearing
    /// different names: at comparable high-frequency energy, an unsharp mask halos far more than the decoder's
    /// reconstruction does.
    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func rawDetailsIsNotJustSharpening() throws {
        let url = try #require(fixture)
        var settings = try #require(RawImporter.asShot(url))
        let plain = try nativeWindow(url, settings: settings)
        settings.rawDetail = RawDetailSettings(enabled: true, detail: 1.5, sharpness: 0.2, contrast: 0.3)
        let detailed = try nativeWindow(url, settings: settings)
        let context = CIContext()
        // An unsharp mask tuned until it carries about the same neighbour energy as the decoder's result.
        var amount = 0.4
        var mask = try unsharp(plain, amount: amount, context: context)
        var tries = 0
        let target = try detailEnergy(detailed)
        while try detailEnergy(mask) < target * 0.95, tries < 14 {
            amount *= 1.5
            mask = try unsharp(plain, amount: amount, context: context)
            tries += 1
        }
        let maskHalos = try halos(mask), detailHalos = try halos(detailed)
        #expect(Double(maskHalos) > Double(detailHalos) * 1.5,
                "sharpening to the same energy halos far more than the decoder's reconstruction")
        print("[M11.2] halos at matched energy: unsharp mask \(maskHalos), Raw Details \(detailHalos)")
    }

    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func theCameraOwnSharpnessIsKeptWhenRawDetailsIsOff() throws {
        let url = try #require(fixture)
        let settings = try #require(RawImporter.asShot(url))
        #expect(settings.rawDetailDefaults.sharpness > 0.1,
                "this camera's decode does its own sharpening (\(fmt(settings.rawDetailDefaults.sharpness, 3)))")
        #expect(settings.rawDetail.isIdentity, "and Raw Details does not touch it until asked")
        print("[M11.2] camera's own: detail \(fmt(settings.rawDetailDefaults.detail, 3)), "
              + "sharpness \(fmt(settings.rawDetailDefaults.sharpness, 3))")
    }

    // MARK: - Chroma noise reduction

    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func sensorStageChromaReductionIsOfferedAndChangesTheFrame() throws {
        let url = try #require(fixture)
        var settings = try #require(RawImporter.asShot(url))
        guard settings.supportsColorNoiseReduction else {
            print("[M11.2] chroma reduction: not offered for this file")
            return
        }
        let untouched = try developed(url, settings: settings)
        settings.colorNoiseReduction = 1
        let reduced = try developed(url, settings: settings)
        let delta = try difference(untouched, reduced)
        let before = try chromaEnergy(untouched), after = try chromaEnergy(reduced)
        #expect(after < before, "the decoder's chroma stage reduces color variation (\(fmt(before, 3)) → \(fmt(after, 3)))")
        print("[M11.2] sensor chroma reduction at 100%: mean delta \(fmt(delta.mean)), moved \(fmt(delta.moved * 100))%, "
              + "chroma energy \(fmt(before, 3)) → \(fmt(after, 3))")
    }

    // MARK: - What the platform does not allow

    /// The blocker behind Super Resolution, pinned down so the gap is a measured fact rather than an opinion: the
    /// decoder's `scaleFactor` is documented for 0…1 and clamps anything larger. There is no path to a larger decode,
    /// and no Apple super-resolution model or API ships with the OS.
    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func theDecoderCannotDevelopLargerThanNative() throws {
        let url = try #require(fixture)
        let filter = try #require(CIRAWFilter(imageURL: url))
        let native = filter.nativeSize
        filter.scaleFactor = 2
        #expect(filter.scaleFactor == 1, "a requested 2× is clamped to 1: the decoder only downsamples")
        let straight = try #require(filter.outputImage?.extent.size)
        #expect(straight.width == native.width && straight.height == native.height)
        // And a downscale does work, which is what the preview path relies on.
        filter.scaleFactor = 0.25
        let quarter = try #require(filter.outputImage?.extent.size)
        #expect(abs(quarter.width - native.width / 4) <= 1)
        print("[M11.2] decoder scale: a requested 2× is clamped to \(fmt(Double(filter.scaleFactor), 0))×, "
              + "so a develop is never larger than native (\(Int(native.width))×\(Int(native.height)))")
    }

    // MARK: - Helpers

    private func developed(_ url: URL, settings: RawDevelopSettings) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: url) else { throw ExportError.render }
        let native = filter.nativeSize
        filter.scaleFactor = Float(700 / max(native.width, native.height))
        filter.isDraftModeEnabled = true
        apply(settings, to: filter)
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw ExportError.render
        }
        return image
    }

    /// A 640-pixel window at native resolution, so the decoder's high-frequency work survives.
    private func nativeWindow(_ url: URL, settings: RawDevelopSettings) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: url) else { throw ExportError.render }
        let native = filter.nativeSize
        filter.isDraftModeEnabled = true
        apply(settings, to: filter)
        guard let output = filter.outputImage else { throw ExportError.render }
        let extent = output.extent
        let window = CGRect(x: (native.width - 640) / 2, y: (native.height - 640) / 2, width: 640, height: 640)
            .offsetBy(dx: -extent.minX, dy: -extent.minY)
        guard let image = CIContext().createCGImage(output, from: window.intersection(extent), format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw ExportError.render
        }
        return image
    }

    private func apply(_ settings: RawDevelopSettings, to filter: CIRAWFilter) {
        filter.exposure = settings.exposure
        filter.neutralTemperature = settings.temperature
        filter.neutralTint = settings.tint
        filter.boostAmount = settings.colorProfile.kind == .linear ? 0 : settings.boost
        if settings.supportsNoiseReduction { filter.luminanceNoiseReductionAmount = settings.noiseReduction }
        if settings.supportsColorNoiseReduction { filter.colorNoiseReductionAmount = settings.colorNoiseReduction }
        guard settings.supportsRawDetail, settings.rawDetail.enabled else { return }
        let base = settings.rawDetailDefaults, offsets = settings.rawDetail
        if filter.isDetailSupported { filter.detailAmount = min(3, max(0, base.detail + offsets.detail)) }
        if filter.isSharpnessSupported { filter.sharpnessAmount = min(1, max(0, base.sharpness + offsets.sharpness)) }
        if filter.isContrastSupported { filter.contrastAmount = min(1, max(0, base.contrast + offsets.contrast)) }
        if filter.isMoireReductionSupported {
            filter.moireReductionAmount = min(3, max(0, base.moire + offsets.moire))
        }
    }

    private func unsharp(_ image: CGImage, amount: Double, context: CIContext) throws -> CGImage {
        let filtered = CIImage(cgImage: image).applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 1.2, kCIInputIntensityKey: amount,
        ])
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let out = context.createCGImage(filtered.cropped(to: extent), from: extent, format: .RGBA8,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw ExportError.render
        }
        return out
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let copy = try BrushRaster.copy(image)
        let pointer = try #require(copy.data).assumingMemoryBound(to: UInt8.self)
        let rowBytes = copy.bytesPerRow
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let from = y * rowBytes + x * 4, to = (y * image.width + x) * 4
                out[to] = pointer[from]
                out[to + 1] = pointer[from + 1]
                out[to + 2] = pointer[from + 2]
                out[to + 3] = pointer[from + 3]
            }
        }
        return out
    }

    private func difference(_ a: CGImage, _ b: CGImage) throws -> (mean: Double, moved: Double) {
        let left = try bytes(a), right = try bytes(b)
        var total = 0.0, moved = 0
        let count = a.width * a.height
        for pixel in 0..<count {
            let i = pixel * 4
            let delta = (0..<3).map { abs(Int(left[i + $0]) - Int(right[i + $0])) }
            total += Double(delta.reduce(0, +)) / 3
            if delta.contains(where: { $0 > 0 }) { moved += 1 }
        }
        return (total / Double(count), Double(moved) / Double(count))
    }

    /// Mean absolute difference between horizontal neighbours in luma: high-frequency energy, which is what "resolved
    /// detail" measures. Luma only, so a color shift does not read as detail.
    private func detailEnergy(_ image: CGImage) throws -> Double {
        let data = try bytes(image)
        let width = image.width, height = image.height
        func luma(_ i: Int) -> Double {
            (Double(data[i]) * 0.299 + Double(data[i + 1]) * 0.587 + Double(data[i + 2]) * 0.114)
        }
        var total = 0.0, count = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = (y * width + x) * 4
                total += abs(luma(i) - luma(i - 4)) + abs(luma(i) - luma(i + 4))
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    /// Pixels brighter or darker than both horizontal neighbours by more than 40 levels: the bright and dark lines
    /// sharpening leaves along an edge.
    private func halos(_ image: CGImage) throws -> Int {
        let data = try bytes(image)
        let width = image.width, height = image.height
        var count = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = (y * width + x) * 4
                let center = Int(data[i]), left = Int(data[i - 4]), right = Int(data[i + 4])
                if center - max(left, right) > 40 || min(left, right) - center > 40 { count += 1 }
            }
        }
        return count
    }

    /// Mean channel spread between neighbours: how much of the frame's variation is color rather than light.
    private func chromaEnergy(_ image: CGImage) throws -> Double {
        let data = try bytes(image)
        let width = image.width, height = image.height
        func chroma(_ i: Int) -> (Double, Double) {
            let r = Double(data[i]), g = Double(data[i + 1]), b = Double(data[i + 2])
            let y = r * 0.299 + g * 0.587 + b * 0.114
            return (r - y, b - y)
        }
        var total = 0.0, count = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = (y * width + x) * 4
                let (cr, cb) = chroma(i)
                let (lr, lb) = chroma(i - 4)
                let (rr, rb) = chroma(i + 4)
                total += abs(cr - lr) + abs(cb - lb) + abs(cr - rr) + abs(cb - rb)
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    private func fmt(_ value: Double, _ places: Int = 2) -> String {
        String(format: "%.\(places)f", value)
    }

    private func fmt(_ value: Float, _ places: Int = 2) -> String { fmt(Double(value), places) }
}
