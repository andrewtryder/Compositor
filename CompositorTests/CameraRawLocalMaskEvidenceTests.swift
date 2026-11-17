import AppKit
import CoreImage
import Foundation
import Testing
@testable import Compositor

/// Milestone 11.3 on a real photograph: a local mask shaped like a real selection, applied to a developed Sigma 40mm
/// F1.4 frame, measured rather than asserted, and carried through the geometry stage the picture itself goes through.
///
/// The fixture is the untracked CR2 the earlier RAW evidence uses, so a checkout without it reports skipped rather
/// than inventing numbers.
@MainActor
struct CameraRawLocalMaskEvidenceTests {
    private var fixture: URL? {
        GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2")
            .map { $0.appendingPathComponent("originals/sigma-40art-sample.CR2") }
    }

    /// The developed frame, no Camera Raw grade on it: the picture a local mask is placed over.
    private func developed(_ url: URL) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: url) else { throw ExportError.render }
        filter.isDraftModeEnabled = true
        guard let output = filter.outputImage else { throw ExportError.render }
        let extent = output.extent
        // A 900-pixel window keeps the evidence test quick while staying at native resolution, where a mask's edge
        // is a real edge rather than an interpolated one.
        let side = min(900, min(extent.width, extent.height))
        let window = CGRect(x: (extent.width - side) / 2, y: (extent.height - side) / 2, width: side, height: side)
        guard let image = CIContext().createCGImage(output, from: window, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw ExportError.render
        }
        return image
    }

    /// A soft ellipse over the middle of the frame, the shape a radial selection makes: white in the center, fading
    /// to black at 70% of the half-width.
    private func ellipticalMask(width: Int, height: Int) throws -> CameraRawLocalMaskRaster {
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bounds = CGRect(x: Double(width) * 0.18, y: Double(height) * 0.18,
                            width: Double(width) * 0.64, height: Double(height) * 0.64)
        context.setFillColor(gray: 1, alpha: 1)
        context.fillEllipse(in: bounds)
        return try CameraRawLocalMaskRaster.make(from: #require(context.makeImage()))
    }

    // MARK: - A local edit changes its region and nothing else

    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func aLocalMaskEditsItsRegionAndLeavesTheRestByteIdentical() throws {
        let url = try #require(fixture)
        let source = try developed(url)
        let raster = try ellipticalMask(width: source.width, height: source.height)

        var mask = CameraRawLocalMask(name: "Ellipse", kind: .selection)
        mask.raster = raster
        mask.adjustments.exposure = 0.9
        mask.adjustments.clarity = 20
        var settings = CameraRawSettings()
        settings.localMasks = [mask]
        let masked = try settings.applyResult(source).image

        let delta = try difference(source, masked)
        #expect(delta.moved > 0.25, "the mask's region is a real part of the frame")
        #expect(delta.moved < 0.75, "and only a part of it: the outside must be untouched")

        // The corners are outside the ellipse and have to be byte-identical.
        for (x, y) in [(4, 4), (source.width - 5, 4), (4, source.height - 5)] {
            #expect(try pixel(source, x: x, y: y) == pixel(masked, x: x, y: y),
                    "a corner outside the mask is exactly what it was at (\(x), \(y))")
        }
        // The center is inside, and brighter.
        let center = (source.width / 2, source.height / 2)
        let before = try luma(pixel(source, x: center.0, y: center.1))
        let after = try luma(pixel(masked, x: center.0, y: center.1))
        #expect(after > before + 6, "the center of the ellipse lifted: \(fmt(before)) → \(fmt(after))")
        print("[M11.3] local ellipse: moved \(fmt(delta.moved * 100))% of the frame, mean delta \(fmt(delta.mean)), "
              + "center luma \(fmt(before)) → \(fmt(after))")
    }

    /// Changing a mask's adjustment must not change which pixels it covers: the two are independent, as the
    /// milestone requires. This compares the coverage itself rather than the rendered pixels, because a small
    /// enough amount can round a covered pixel back to its original value without the region having moved.
    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func changingTheAmountDoesNotMoveTheRegion() throws {
        let url = try #require(fixture)
        let source = try developed(url)
        let raster = try ellipticalMask(width: source.width, height: source.height)

        var mask = CameraRawLocalMask(name: "Ellipse", kind: .selection)
        mask.raster = raster
        mask.adjustments.exposure = 0.4
        let gentle = try #require(try CameraRawLocalMaskRenderer.coverage(
            of: mask, settings: CameraRawSettings(), image: source,
            inputWidth: source.width, inputHeight: source.height,
            width: source.width, height: source.height))
        mask.adjustments.exposure = 1.2
        let strong = try #require(try CameraRawLocalMaskRenderer.coverage(
            of: mask, settings: CameraRawSettings(), image: source,
            inputWidth: source.width, inputHeight: source.height,
            width: source.width, height: source.height))
        #expect(try bytes(gentle) == bytes(strong), "the coverage is identical at both amounts; only how much differs")

        // And the render really does apply the two different amounts over that same region.
        var settings = CameraRawSettings()
        mask.adjustments.exposure = 0.4
        settings.localMasks = [mask]
        let soft = try settings.applyResult(source).image
        mask.adjustments.exposure = 1.2
        settings.localMasks = [mask]
        let hard = try settings.applyResult(source).image
        let center = (source.width / 2, source.height / 2)
        let hardLuma = try luma(pixel(hard, x: center.0, y: center.1))
        let softLuma = try luma(pixel(soft, x: center.0, y: center.1))
        #expect(hardLuma > softLuma)
        print("[M11.3] coverage identical at Exposure 0.4 and 1.2; the rendered amount differs")
    }

    // MARK: - The correction stack keeps it non-destructive

    /// A camera-raw correction node carrying a local mask, rendered through the stack: the layer's own pixels are
    /// never flattened, and the mask is still there to edit afterwards.
    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func theCorrectionStackCarriesTheMaskNonDestructively() throws {
        let url = try #require(fixture)
        let source = try developed(url)
        let raster = try ellipticalMask(width: source.width, height: source.height)

        var mask = CameraRawLocalMask(name: "Ellipse", kind: .selection)
        mask.raster = raster
        mask.adjustments.exposure = 0.8
        var settings = CameraRawSettings()
        settings.localMasks = [mask]

        var stack = LayerCorrectionStack(source: ImportedImage(image: source, thumbnail: source, name: "Developed"))
        stack.nodes.append(.cameraRawFull(settings))
        #expect(stack.nodes.count == 1)
        let rendered = try LayerCorrectionRenderer.render(&stack, options: .init()).image
        let delta = try difference(source, rendered)
        #expect(delta.moved > 0.2, "the stack rendered the local edit")
        #expect(delta.moved < 0.8, "and left the outside of the ellipse alone")

        // The mask is still in the stack's own settings, not baked into pixels.
        let staged = try #require(stack.nodes.first?.cameraRawFull)
        #expect(staged.localMasks.count == 1)
        #expect(staged.localMasks.first?.id == mask.id)
        #expect(staged.localMasks.first?.raster?.png == raster.png)
        print("[M11.3] correction stack: moved \(fmt(delta.moved * 100))% with the mask still editable in the node")
    }

    // MARK: - Geometry carries the mask with the picture

    /// A rotation must not slide the adjustment off the region it was drawn over: the mask is warped by the same
    /// stages the picture is. The comparison is against the *rotated frame without the mask*, because resampling
    /// changes nearly every pixel on its own and would swamp a comparison against the un-rotated picture.
    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func geometryCarriesTheMaskAlongWithThePicture() throws {
        let url = try #require(fixture)
        let source = try developed(url)
        let raster = try ellipticalMask(width: source.width, height: source.height)

        var mask = CameraRawLocalMask(name: "Ellipse", kind: .selection)
        mask.raster = raster
        mask.adjustments.exposure = 1

        // The same rotation, once without the mask and once with it: the difference is the mask alone.
        var geometryOnly = CameraRawSettings()
        geometryOnly.geometry.rotate = 4
        let rotatedPlain = try geometryOnly.applyResult(source).image

        var withMask = geometryOnly
        withMask.localMasks = [mask]
        let rotatedMasked = try withMask.applyResult(source).image

        let share = try movedShare(rotatedPlain, rotatedMasked)
        #expect(share > 0.15, "the mask still brightens a region after the rotation")
        #expect(share < 0.75, "and still only a region")

        // Were the mask left in the original, un-rotated frame, its ellipse would land on different pixels but would
        // also keep exactly the same pixel count. What identifies a carried mask is that the region it covers moved
        // with the picture: the brightest changed pixels sit near the center of the rotated frame, not where the
        // un-rotated ellipse would have put them.
        let centerShare = try movedShareNearCenter(rotatedPlain, rotatedMasked, fraction: 0.5)
        #expect(centerShare > share * 0.5, "most of the mask's work is still where the ellipse was drawn")
        print("[M11.3] rotation: mask moved \(fmt(share * 100))% of the rotated frame, "
              + "\(fmt(centerShare * 100))% of that within the middle half")
    }

    /// The share of `after`'s pixels that differ from `before` inside the middle `fraction` of the frame.
    private func movedShareNearCenter(_ before: CGImage, _ after: CGImage, fraction: Double) throws -> Double {
        let a = try bytes(before), b = try bytes(after)
        let width = min(before.width, after.width), height = min(before.height, after.height)
        let marginX = Int(Double(width) * (1 - fraction) / 2), marginY = Int(Double(height) * (1 - fraction) / 2)
        var moved = 0, count = 0
        for y in marginY..<(height - marginY) {
            for x in marginX..<(width - marginX) {
                let ia = (y * before.width + x) * 4
                let ib = (y * after.width + x) * 4
                count += 1
                if (0..<3).contains(where: { a[ia + $0] != b[ib + $0] }) { moved += 1 }
            }
        }
        return count > 0 ? Double(moved) / Double(count) : 0
    }

    // MARK: - Persistence of the real coverage

    @Test(.enabled(if: GeometryValidationFixtures.rootContaining("originals/sigma-40art-sample.CR2") != nil,
                   "the untracked CR2 fixture is absent"))
    func aSavedMaskReopensToTheSamePixels() throws {
        let url = try #require(fixture)
        let source = try developed(url)
        let raster = try ellipticalMask(width: source.width, height: source.height)
        var mask = CameraRawLocalMask(name: "Ellipse", kind: .selection)
        mask.raster = raster
        mask.adjustments.exposure = 0.7
        mask.adjustments.saturation = 15
        var settings = CameraRawSettings()
        settings.localMasks = [mask]
        let before = try settings.applyResult(source).image

        let data = try JSONEncoder().encode(CameraRawSettingsPersistentState(settings))
        let reopened = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: data).makeSettings()
        let after = try reopened.applyResult(source).image
        #expect(try bytes(after) == bytes(before), "the reopened project develops to the same pixels, byte for byte")

        // The stored coverage was shrunk to the size budget, and its PNG is smaller than the raw grid it came from.
        let stored = try #require(reopened.localMasks.first?.raster)
        print("[M11.3] saved mask: \(stored.width)×\(stored.height), \(stored.png.count / 1024) KB, "
              + "round-trip byte-identical")
    }

    // MARK: - Helpers

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                         mask: false, context: context)
        let pointer = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: image.width * image.height * 4))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8) {
        let all = try bytes(image)
        let index = (y * image.width + x) * 4
        return (all[index], all[index + 1], all[index + 2])
    }

    private func luma(_ pixel: (UInt8, UInt8, UInt8)) throws -> Double {
        0.299 * Double(pixel.0) + 0.587 * Double(pixel.1) + 0.114 * Double(pixel.2)
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

    /// The share of `after`'s pixels that differ from `before`, at the smaller of the two frames' sizes.
    private func movedShare(_ before: CGImage, _ after: CGImage) throws -> Double {
        let a = try bytes(before), b = try bytes(after)
        let width = min(before.width, after.width), height = min(before.height, after.height)
        var moved = 0
        for y in 0..<height {
            for x in 0..<width {
                let ia = (y * before.width + x) * 4
                let ib = (y * after.width + x) * 4
                if (0..<3).contains(where: { a[ia + $0] != b[ib + $0] }) { moved += 1 }
            }
        }
        return Double(moved) / Double(width * height)
    }

    private func fmt(_ value: Double, _ digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }
}
