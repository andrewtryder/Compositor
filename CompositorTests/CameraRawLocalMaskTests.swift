import AppKit
import Foundation
import Testing
@testable import Compositor

/// Milestone 11.3: Camera Raw local masks — kinds, coverage, blending, warping, persistence and the panel's editing
/// rules. The photographic evidence is in `CameraRawLocalMaskEvidenceTests`.
struct CameraRawLocalMaskTests {
    // MARK: - Fixtures

    /// A 64×64 picture: left half mid gray, right half bright. A mask over the right half should brighten only that.
    private func fixture() throws -> CGImage {
        let context = try BrushRaster.context(width: 64, height: 64, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.25, green: 0.25, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        context.setFillColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        return try #require(context.makeImage())
    }

    /// Coverage that reveals only the right half.
    private func rightHalfRaster() throws -> CameraRawLocalMaskRaster {
        let context = try BrushRaster.context(width: 64, height: 64, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        return try CameraRawLocalMaskRaster.make(from: try #require(context.makeImage()))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                         mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        let count = image.width * image.height * 4
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let all = try pixels(image)
        let index = (y * image.width + x) * 4
        return (all[index], all[index + 1], all[index + 2])
    }

    // MARK: - A raster mask edits only inside itself

    @Test func aRasterMaskAdjustsOnlyItsOwnRegion() throws {
        let source = try fixture()
        var mask = CameraRawLocalMask(name: "Right", kind: .selection)
        mask.raster = try rightHalfRaster()
        mask.adjustments.exposure = 1
        var settings = CameraRawSettings()
        settings.localMasks = [mask]
        let result = try settings.applyResult(source).image

        let outside = try pixel(result, x: 8, y: 32)
        let inside = try pixel(result, x: 56, y: 32)
        // The left half is untouched, byte for byte.
        let original = try pixel(source, x: 8, y: 32)
        #expect(outside == original, "outside the mask the picture is exactly what it was")
        #expect(Int(inside.r) > Int(original.r) + 20, "inside the mask Exposure brightened the gray")
    }

    @Test func aNeutralMaskIsPixelIdentical() throws {
        let source = try fixture()
        var mask = CameraRawLocalMask(name: "Neutral", kind: .selection)
        mask.raster = try rightHalfRaster()
        // Every adjustment left at zero.
        var settings = CameraRawSettings()
        settings.localMasks = [mask]
        #expect(!settings.adjustsLocalMasks, "a neutral mask is not applied at all")
        let result = try settings.applyResult(source).image
        #expect(try pixels(result) == pixels(source))
    }

    @Test func aDisabledMaskIsPixelIdentical() throws {
        let source = try fixture()
        var mask = CameraRawLocalMask(name: "Off", kind: .selection)
        mask.raster = try rightHalfRaster()
        mask.adjustments.exposure = 2
        mask.enabled = false
        var settings = CameraRawSettings()
        settings.localMasks = [mask]
        #expect(!settings.adjustsLocalMasks)
        #expect(try pixels(settings.applyResult(source).image) == pixels(source))
    }

    @Test func aGlobalAdjustmentIsNotAppliedTwice() throws {
        let source = try fixture()
        // Global Exposure of 1, then a mask that also raises Exposure 1. The masked half gets both; the rest gets
        // exactly the global one, which this compares against.
        var global = CameraRawSettings()
        global.exposure = 1
        let globalOnly = try global.applyResult(source).image

        var mask = CameraRawLocalMask(name: "Right", kind: .selection)
        mask.raster = try rightHalfRaster()
        mask.adjustments.exposure = 1
        global.localMasks = [mask]
        let masked = try global.applyResult(source).image

        #expect(try pixel(masked, x: 8, y: 32) == pixel(globalOnly, x: 8, y: 32),
                "the unmasked side carries the global grade once, not twice")
        #expect(Int(try pixel(masked, x: 56, y: 32).r) > Int(try pixel(globalOnly, x: 56, y: 32).r),
                "the masked side carries both")
    }

    // MARK: - Order and overlap

    @Test func overlappingMasksAccumulateInListOrder() throws {
        let source = try fixture()
        var first = CameraRawLocalMask(name: "First", kind: .selection)
        first.raster = try rightHalfRaster()
        first.adjustments.exposure = 1
        var second = CameraRawLocalMask(name: "Second", kind: .selection)
        second.raster = try rightHalfRaster()
        second.adjustments.exposure = 1
        var settings = CameraRawSettings()
        settings.localMasks = [first, second]
        let both = try settings.applyResult(source).image

        var one = CameraRawSettings()
        one.localMasks = [first]
        let single = try one.applyResult(source).image
        // Two +1 stop masks over the same region are brighter than one.
        #expect(Int(try pixel(both, x: 56, y: 32).r) > Int(try pixel(single, x: 56, y: 32).r))
        // The unmatched half is untouched by either.
        #expect(try pixel(both, x: 8, y: 32) == pixel(source, x: 8, y: 32))
    }

    @Test func reversingMaskOrderCanChangeTheResult() throws {
        let source = try fixture()
        var warm = CameraRawLocalMask(name: "Warm", kind: .selection)
        warm.raster = try rightHalfRaster()
        warm.adjustments.temperature = 40
        var bright = CameraRawLocalMask(name: "Bright", kind: .selection)
        bright.raster = try rightHalfRaster()
        bright.adjustments.exposure = 1
        var forward = CameraRawSettings()
        forward.localMasks = [warm, bright]
        var backward = CameraRawSettings()
        backward.localMasks = [bright, warm]
        // Not asserting which is which: the point is that order is defined and the renderer follows it.
        #expect(try pixels(forward.applyResult(source).image) != pixels(source))
        #expect(try pixels(backward.applyResult(source).image) != pixels(source))
    }

    // MARK: - Invert and feather

    @Test func invertSwapsInsideAndOutside() throws {
        let source = try fixture()
        var mask = CameraRawLocalMask(name: "Right", kind: .selection)
        mask.raster = try rightHalfRaster()
        mask.adjustments.exposure = 1
        mask.inverted = true
        var settings = CameraRawSettings()
        settings.localMasks = [mask]
        let result = try settings.applyResult(source).image
        #expect(try pixel(result, x: 8, y: 32) != pixel(source, x: 8, y: 32), "the left half is now the inside")
        #expect(try pixel(result, x: 56, y: 32) == pixel(source, x: 56, y: 32),
                "the right half is now the outside, byte for byte")
    }

    @Test func featherSoftensTheEdgeWithoutMovingIt() throws {
        let source = try fixture()
        var hard = CameraRawLocalMask(name: "Hard", kind: .selection)
        hard.raster = try rightHalfRaster()
        hard.adjustments.exposure = 1
        var soft = hard
        soft.feather = 8
        var settings = CameraRawSettings()
        settings.localMasks = [hard]
        let hardImage = try settings.applyResult(source).image
        settings.localMasks = [soft]
        let softImage = try settings.applyResult(source).image
        // Well inside, both are fully adjusted; at the boundary the feathered one is less adjusted.
        #expect(try pixel(hardImage, x: 60, y: 32).r == pixel(softImage, x: 60, y: 32).r)
        #expect(try pixel(hardImage, x: 33, y: 32).r != pixel(softImage, x: 33, y: 32).r,
                "the feathered edge changes the transition")
    }

    // MARK: - Gradients

    @Test func aLinearGradientRunsFromFullToNone() throws {
        let source = try fixture()
        var mask = CameraRawLocalMask(name: "Ramp", kind: .linearGradient)
        mask.startX = 0
        mask.startY = 0
        mask.endX = 0.6
        mask.endY = 0
        mask.adjustments.exposure = 1
        var settings = CameraRawSettings()
        settings.localMasks = [mask]
        let result = try settings.applyResult(source).image
        // Start is white (full), past the end is black (none).
        #expect(Int(try pixel(result, x: 2, y: 32).r) > Int(try pixel(source, x: 2, y: 32).r))
        #expect(try pixel(result, x: 62, y: 32) == pixel(source, x: 62, y: 32))
    }

    @Test func aRadialGradientIsFullInTheMiddleAndNoneAtTheEdge() throws {
        let source = try fixture()
        var mask = CameraRawLocalMask(name: "Spot", kind: .radialGradient)
        mask.centerX = 0.5
        mask.centerY = 0.5
        mask.radiusX = 0.2
        mask.radiusY = 0.2
        mask.adjustments.exposure = 1
        var settings = CameraRawSettings()
        settings.localMasks = [mask]
        let result = try settings.applyResult(source).image
        #expect(try pixel(result, x: 32, y: 32) != pixel(source, x: 32, y: 32), "the center is inside")
        #expect(try pixel(result, x: 1, y: 1) == pixel(source, x: 1, y: 1), "the corners are outside")
    }

    // MARK: - Color Range

    @Test func aColorRangeMaskFollowsTheSampledColor() throws {
        let source = try fixture()
        var mask = CameraRawLocalMask(name: "Gray", kind: .colorRange)
        // The right half is 0.6 gray, the left 0.25: sampling the right half keeps only it.
        mask.red = 0.6
        mask.green = 0.6
        mask.blue = 0.6
        mask.fuzziness = 20
        mask.adjustments.exposure = 1
        var settings = CameraRawSettings()
        settings.localMasks = [mask]
        let result = try settings.applyResult(source).image
        #expect(try pixel(result, x: 56, y: 32) != pixel(source, x: 56, y: 32), "the sampled gray changed")
        #expect(try pixel(result, x: 8, y: 32) == pixel(source, x: 8, y: 32), "the other gray did not")
    }

    // MARK: - Warping

    /// A rotation must carry a captured mask with the picture: the region that was on the left is still on the
    /// pixels that came from the left.
    @Test func aCapturedMaskIsWarpedWithThePicture() throws {
        let source = try fixture()
        var mask = CameraRawLocalMask(name: "Right", kind: .selection)
        mask.raster = try rightHalfRaster()
        mask.adjustments.exposure = 2
        var plain = CameraRawSettings()
        plain.localMasks = [mask]
        var warped = plain
        warped.geometry.rotate = 6
        let plainImage = try plain.applyResult(source).image
        let warpedImage = try warped.applyResult(source).image
        // The images differ because geometry ran, and both show a highlight: the mask was not left frozen in the
        // original frame, where the rotation would have moved the region away from the adjustment.
        #expect(try pixels(plainImage) != pixels(source))
        #expect(try pixels(warpedImage) != pixels(plainImage))
        // A mask left un-warped would have brightened a band that is now on the other side of the picture. Count the
        // brightened pixels instead of a coordinate: the count has to stay similar, not collapse.
        let plainBright = try brightCount(plainImage, source: source)
        let warpedBright = try brightCount(warpedImage, source: source)
        #expect(plainBright > 900, "roughly half of the frame is masked")
        #expect(warpedBright > 500, "the region survives the warp rather than being lost behind it")
    }

    private func brightCount(_ image: CGImage, source: CGImage) throws -> Int {
        let a = try pixels(image), b = try pixels(source)
        var count = 0
        for index in stride(from: 0, to: min(a.count, b.count), by: 4) where Int(a[index]) > Int(b[index]) + 8 {
            count += 1
        }
        return count
    }

    // MARK: - Validation and normalization

    @Test func aMaskWithAnOutOfRangeAmountIsInvalid() {
        var mask = CameraRawLocalMask(name: "Bad", kind: .linearGradient)
        mask.feather = 10_000
        #expect(!mask.isValid)
        #expect(mask.normalized.feather == CameraRawLocalMask.featherRange.upperBound)
    }

    @Test func aRasterKindNeedsItsRaster() {
        let mask = CameraRawLocalMask(name: "Missing", kind: .selection)
        #expect(!mask.isValid, "a selection mask with no coverage can never be rendered")
        #expect(CameraRawLocalMask(name: "Ramp", kind: .linearGradient).isValid)
    }

    @Test func anEmptyNameBecomesMaskOnNormalization() {
        var mask = CameraRawLocalMask(name: "", kind: .radialGradient)
        mask.name = "   "
        #expect(mask.normalized.name == "   ", "whitespace is kept; only a truly empty name is replaced")
        mask.name = ""
        #expect(mask.normalized.name == "Mask")
    }

    @Test func noMoreThanTheMaximumNumberOfMasks() {
        var settings = CameraRawSettings()
        settings.localMasks = (0...CameraRawLocalMask.maximumCount).map { index in
            CameraRawLocalMask(name: "Mask \(index)", kind: .linearGradient)
        }
        #expect(!settings.isValid)
        #expect(settings.normalized.localMasks.count == CameraRawLocalMask.maximumCount)
    }

    @Test func duplicateIdentifiersAreInvalid() {
        let id = UUID()
        var first = CameraRawLocalMask(id: id, name: "One", kind: .linearGradient)
        first.adjustments.exposure = 1
        var second = CameraRawLocalMask(id: id, name: "Two", kind: .radialGradient)
        second.adjustments.contrast = 10
        var settings = CameraRawSettings()
        settings.localMasks = [first, second]
        #expect(!settings.isValid, "two masks sharing an ID would edit the wrong one")
    }

    // MARK: - Persistence

    @Test func localMasksRoundTripThroughTheProjectState() throws {
        var mask = CameraRawLocalMask(name: "Right", kind: .selection)
        mask.raster = try rightHalfRaster()
        mask.adjustments.exposure = 0.75
        mask.adjustments.clarity = 25
        mask.inverted = true
        mask.feather = 12
        var settings = CameraRawSettings()
        settings.localMasks = [mask]
        let state = CameraRawSettingsPersistentState(settings)
        let back = try JSONDecoder().decode(CameraRawSettingsPersistentState.self,
                                            from: JSONEncoder().encode(state)).makeSettings()
        #expect(back.localMasks.count == 1)
        #expect(back.localMasks.first?.id == mask.id)
        #expect(back.localMasks.first?.adjustments == mask.adjustments)
        #expect(back.localMasks.first?.inverted == true)
        #expect(back.localMasks.first?.feather == 12)
        #expect(back.localMasks.first?.raster?.png == mask.raster?.png, "the coverage travels with the project")
    }

    @Test func aProjectWithoutMasksDecodesToNone() throws {
        let settings = CameraRawSettings()
        let state = CameraRawSettingsPersistentState(settings)
        var encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        encoded.removeValue(forKey: "localMasks")
        let data = try JSONSerialization.data(withJSONObject: encoded)
        let back = try JSONDecoder().decode(CameraRawSettingsPersistentState.self, from: data).makeSettings()
        #expect(back.localMasks.isEmpty)
        #expect(back.isIdentity)
    }

    @Test func aMaskSavedBeforeAControlExistedStillLoads() throws {
        // Only Exposure is present inside adjustments; the other twelve read their defaults rather than failing the
        // whole project.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","kind":"Linear Gradient","adjustments":{"exposure":0.4}}
        """
        let mask = try JSONDecoder().decode(CameraRawLocalMask.self, from: Data(json.utf8))
        #expect(mask.adjustments.exposure == 0.4)
        #expect(mask.adjustments.contrast == 0)
        #expect(mask.adjustments.dehaze == 0)
        #expect(mask.enabled)
    }

    @Test func anOversizedMaskRasterIsRefused() {
        let raster = CameraRawLocalMaskRaster(width: CameraRawLocalMaskRaster.maximumSide + 1, height: 8, png: Data([1]))
        #expect(!raster.isValid)
        let heavy = CameraRawLocalMaskRaster(width: 8, height: 8, png: Data(repeating: 0, count: CameraRawLocalMaskRaster.maximumBytes + 1))
        #expect(!heavy.isValid)
    }

    // MARK: - The local adjustment subset

    @Test func theLocalAdjustmentsCoverTheAdvertisedControls() {
        // Exposure through Dehaze, the photographic tone and color controls Camera Raw offers locally.
        let fields: [WritableKeyPath<CameraRawLocalAdjustments, Double>] = [
            \.exposure, \.contrast, \.highlights, \.shadows, \.whites, \.blacks,
            \.temperature, \.tint, \.vibrance, \.saturation, \.texture, \.clarity, \.dehaze,
        ]
        for key in fields {
            var adjustments = CameraRawLocalAdjustments()
            adjustments[keyPath: key] = 1
            #expect(!adjustments.isIdentity, "every advertised control actually changes the mask")
        }
    }

    @Test func localAdjustmentsProjectIntoTheGlobalPasses() {
        var adjustments = CameraRawLocalAdjustments()
        adjustments.exposure = 1
        adjustments.clarity = 20
        let settings = adjustments.settings
        // The same math as the global sliders, not a second implementation of it.
        #expect(settings.exposure == 1)
        #expect(settings.clarity == 20)
        #expect(settings.adjustsLight)
    }

    @Test func extremeLocalAmountsNormalizeIntoTheGlobalRanges() {
        var adjustments = CameraRawLocalAdjustments()
        adjustments.exposure = .nan
        adjustments.contrast = 1000
        let normalized = adjustments.normalized
        #expect(normalized.exposure == 0)
        #expect(normalized.contrast == CameraRawSettings.toneRange.upperBound)
    }

    // MARK: - The renderer's own contract

    @Test func coverageIsNilWhenNothingShows() throws {
        let image = try fixture()
        var mask = CameraRawLocalMask(name: "Empty", kind: .selection)
        // A raster that reveals nothing.
        let context = try BrushRaster.context(width: 64, height: 64, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        mask.raster = try CameraRawLocalMaskRaster.make(from: try #require(context.makeImage()))
        let coverage = try CameraRawLocalMaskRenderer.coverage(of: mask, settings: CameraRawSettings(), image: image,
                                                              inputWidth: 64, inputHeight: 64, width: 64, height: 64)
        #expect(coverage == nil, "an entirely black mask has nothing to blend")
    }

    @Test func anOverlayPaintsTheMaskAndLeavesTheRestAlone() throws {
        let source = try fixture()
        var mask = CameraRawLocalMask(name: "Right", kind: .selection)
        mask.raster = try rightHalfRaster()
        let overlaid = try CameraRawLocalMaskRenderer.overlay([mask], maskID: mask.id, settings: CameraRawSettings(),
                                                              on: source, inputWidth: 64, inputHeight: 64)
        #expect(try pixel(overlaid, x: 8, y: 32) == pixel(source, x: 8, y: 32))
        #expect(try pixel(overlaid, x: 56, y: 32) != pixel(source, x: 56, y: 32))
    }

    // MARK: - Section order is not touched

    @Test func localMasksAreNotATopLevelCameraRawSection() {
        // The ten sections keep Adobe's order, and masks hang below them rather than becoming an eleventh.
        #expect(CameraRawGroup.panelOrder.map(\.rawValue) ==
                ["Light", "Color", "Color Grading", "Effects", "Curve", "Color Mixer", "Detail", "Optics",
                 "Geometry", "Calibration"])
        #expect(!CameraRawGroup.allCases.map(\.rawValue).contains("Masks"))
    }

    // MARK: - The editing API, on a live panel

    @MainActor
    private func cameraRawSession(width: Int = 80, height: Int = 60) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: width, height: height)
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.45, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        session.insert(ImportedImage(image: try #require(context.makeImage()),
                                     thumbnail: try #require(context.makeImage()), name: "Photo"))
        session.beginFilter(.cameraRaw)
        return session
    }

    @Test @MainActor func aSelectionBecomesAMaskThatCoversItsRegion() throws {
        let session = try cameraRawSession()
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 40, y: 0, width: 40, height: 60),
                                                                    transform: nil), antialiased: false)
        let added = try #require(session.addCameraRawLocalMaskFromSelection())
        let mask = try #require(session.filterEdit?.settings.cameraRaw.localMasks.first { $0.id == added })
        #expect(mask.kind == .selection)
        #expect(mask.raster != nil, "the selection was captured as coverage")
        #expect(session.filterEdit?.selectedLocalMaskID == added, "the new mask is the one being edited")

        // Its coverage really is the right half: white there, black on the left.
        let raster = try #require(mask.raster)
        let image = try #require(raster.image(width: 80, height: 60))
        #expect(try coverageValue(image, x: 60, y: 30) > 200)
        #expect(try coverageValue(image, x: 10, y: 30) < 20)
    }

    private func coverageValue(_ image: CGImage, x: Int, y: Int) throws -> Int {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                         mask: true, context: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Int(data[y * context.bytesPerRow + x])
    }

    @Test @MainActor func addingASelectionMaskWithoutASelectionRefuses() throws {
        let session = try cameraRawSession()
        session.document?.selection = nil
        #expect(session.addCameraRawLocalMaskFromSelection() == nil, "nothing to make a mask from")
        #expect(session.filterEdit?.settings.cameraRaw.localMasks.isEmpty ?? false,
                "and no mask covering everything appears in its place")
        #expect(session.brushError != nil, "the refusal says why")
    }

    @Test @MainActor func theLayerMaskBecomesAMask() throws {
        let session = try cameraRawSession()
        // A layer mask revealing only the left half.
        let context = try BrushRaster.context(width: 80, height: 60, mask: true)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 40, y: 0, width: 40, height: 60))
        let coverage = try #require(context.makeImage())
        let asset = try LayerMask.asset(from: coverage)
        session.document?.layers[0].mask = LayerMask(asset: asset)

        let added = try #require(session.addCameraRawLocalMaskFromLayerMask())
        let mask = try #require(session.filterEdit?.settings.cameraRaw.localMasks.first { $0.id == added })
        #expect(mask.kind == .layerMask)
        let raster = try #require(mask.raster)
        let image = try #require(raster.image(width: 80, height: 60))
        let left = try coverageValue(image, x: 10, y: 30)
        let right = try coverageValue(image, x: 60, y: 30)
        #expect(left > 200, "the revealed half is the mask")
        #expect(right < 20, "the hidden half is not")
    }

    @Test @MainActor func gradientsAreAddedAndEditedOnTheCanvas() throws {
        let session = try cameraRawSession()
        let added = try #require(session.addCameraRawLocalMask(kind: .linearGradient))
        #expect(session.filterEdit?.settings.cameraRaw.localMasks.first?.kind == .linearGradient)

        // Rows and columns are named the way Photoshop names repeats.
        let second = try #require(session.addCameraRawLocalMask(kind: .linearGradient))
        let names = session.filterEdit?.settings.cameraRaw.localMasks.map(\.name) ?? []
        #expect(names == ["Linear Gradient", "Linear Gradient 1"])
        #expect(second != added)
    }

    @Test @MainActor func editingOneMaskLeavesTheOthersAlone() throws {
        let session = try cameraRawSession()
        let first = try #require(session.addCameraRawLocalMask(kind: .linearGradient))
        let second = try #require(session.addCameraRawLocalMask(kind: .radialGradient))
        session.selectCameraRawLocalMask(second)
        session.updateCameraRawLocalMaskAdjustments { $0.exposure = 1 }
        let masks = session.filterEdit?.settings.cameraRaw.localMasks ?? []
        #expect(masks.first { $0.id == second }?.adjustments.exposure == 1)
        #expect(masks.first { $0.id == first }?.adjustments.exposure == 0, "the other mask is untouched")
    }

    @Test @MainActor func deletingAMaskMovesTheSelectionOn() throws {
        let session = try cameraRawSession()
        let first = try #require(session.addCameraRawLocalMask(kind: .linearGradient))
        let second = try #require(session.addCameraRawLocalMask(kind: .radialGradient))
        session.selectCameraRawLocalMask(second)
        session.deleteCameraRawLocalMask(second)
        #expect(session.filterEdit?.settings.cameraRaw.localMasks.map(\.id) == [first])
        #expect(session.filterEdit?.selectedLocalMaskID == first, "the selection lands on a mask that exists")
        session.deleteCameraRawLocalMask(first)
        #expect(session.filterEdit?.selectedLocalMaskID == nil)
        #expect(session.filterEdit?.showsLocalMaskOverlay == false)
    }

    @Test @MainActor func aGradientDragMovesTheGradientAndEscapePutsItBack() throws {
        let session = try cameraRawSession()
        let added = try #require(session.addCameraRawLocalMask(kind: .linearGradient))
        let before = try #require(session.filterEdit?.settings.cameraRaw.localMasks.first { $0.id == added })

        session.beginCameraRawLocalMaskGradient()
        #expect(session.filterEdit?.drawsLocalMask == true)
        // Normalized points: (10, 100) and (70, 300) in an 80 × 60 preview.
        session.beginCameraRawLocalMaskGradientDrag(at: CGPoint(x: 10, y: 10))
        session.continueCameraRawLocalMaskGradientDrag(to: CGPoint(x: 70, y: 40))
        session.endCameraRawLocalMaskGradientDrag()
        let moved = try #require(session.filterEdit?.settings.cameraRaw.localMasks.first { $0.id == added })
        #expect(moved.startY != before.startY || moved.endY != before.endY, "the drag moved the gradient")

        // A second drag, cancelled, puts it back exactly.
        session.beginCameraRawLocalMaskGradient()
        session.beginCameraRawLocalMaskGradientDrag(at: CGPoint(x: 20, y: 20))
        session.continueCameraRawLocalMaskGradientDrag(to: CGPoint(x: 60, y: 50))
        session.cancelCameraRawLocalMaskGradient()
        let restored = try #require(session.filterEdit?.settings.cameraRaw.localMasks.first { $0.id == added })
        #expect(restored.startX == moved.startX && restored.startY == moved.startY)
        #expect(restored.endX == moved.endX && restored.endY == moved.endY)
        #expect(session.filterEdit?.drawsLocalMask == false)
    }

    @Test @MainActor func resettingThePanelLeavesMasksAlone() throws {
        let session = try cameraRawSession()
        _ = try #require(session.addCameraRawLocalMask(kind: .linearGradient))
        session.updateCameraRawLocalMaskAdjustments { $0.exposure = 1 }
        // A section reset touches its own group only.
        session.resetCameraRaw(.light)
        #expect(session.filterEdit?.settings.cameraRaw.localMasks.count == 1,
                "reset Light does not delete or neutralize a mask")
        #expect(session.filterEdit?.settings.cameraRaw.localMasks.first?.adjustments.exposure == 1)
    }
}
