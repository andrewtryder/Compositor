import AppKit
import CoreImage

/// Where a local mask's coverage comes from. Raster kinds are captured once from something already in the document
/// (a selection, Vision's foreground instance, a layer mask); gradient kinds are parametric and stay editable.
nonisolated enum CameraRawLocalMaskKind: String, Codable, CaseIterable, Sendable {
    case selection = "Selection"
    case objectSelection = "Object"
    case colorRange = "Color Range"
    case layerMask = "Layer Mask"
    case linearGradient = "Linear Gradient"
    case radialGradient = "Radial Gradient"
    case brushPainted = "Brush"

    /// Kinds whose coverage is a stored grayscale bitmap.
    var isRaster: Bool { self == .selection || self == .objectSelection || self == .layerMask || self == .brushPainted }
    /// Kinds placed by dragging on the preview.
    var isGradient: Bool { self == .linearGradient || self == .radialGradient }
    /// Kinds that support brush editing on the canvas.
    var isBrushPainted: Bool { self == .brushPainted }
}

/// A mask's coverage as an 8-bit gray PNG (row 0 is the top, white reveals). Stored with the settings so a reopened
/// project reproduces the same region without re-running whatever found it.
nonisolated struct CameraRawLocalMaskRaster: Codable, Equatable, Sendable {
    /// A mask larger than this is resampled down before it is stored; a full-resolution soft mask still fits easily.
    static let maximumSide = 4096
    static let maximumBytes = 4 * 1024 * 1024

    var width: Int
    var height: Int
    var png: Data

    var isValid: Bool {
        (1...Self.maximumSide).contains(width) && (1...Self.maximumSide).contains(height)
            && !png.isEmpty && png.count <= Self.maximumBytes
    }

    /// The stored coverage at `width` × `height`, resampled only when the grid differs.
    func image(width: Int, height: Int) -> CGImage? {
        guard let source = Self.decode(png) else { return nil }
        guard source.width != width || source.height != height else { return source }
        guard let context = try? BrushRaster.context(width: width, height: height, mask: true) else { return nil }
        context.interpolationQuality = .high
        BrushRaster.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height), mask: true, context: context)
        return context.makeImage()
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// `image` as a stored raster, resampled down (and re-encoded) only while its PNG exceeds the byte budget.
    static func make(from image: CGImage) throws -> CameraRawLocalMaskRaster {
        var current = image
        var factor = 1
        while true {
            let side = max(current.width, current.height)
            if side > maximumSide {
                factor = max(1, Int((Double(side) / Double(maximumSide)).rounded(.up)))
                guard let smaller = resized(current, by: factor) else { throw ExportError.render }
                current = smaller
                continue
            }
            let png = try encode(current)
            if png.count <= maximumBytes { return CameraRawLocalMaskRaster(width: current.width, height: current.height, png: png) }
            guard factor < 16, let smaller = resized(current, by: 2) else { throw ExportError.render }
            factor *= 2
            current = smaller
        }
    }

    private static func resized(_ image: CGImage, by factor: Int) -> CGImage? {
        let width = max(1, image.width / factor), height = max(1, image.height / factor)
        guard let context = try? BrushRaster.context(width: width, height: height, mask: true) else { return nil }
        context.interpolationQuality = .high
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: true, context: context)
        return context.makeImage()
    }

    private static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ExportError.render
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.render }
        return data as Data
    }
}

/// The adjustments a local mask applies where it shows. Deliberately the subset Camera Raw offers locally: the
/// photographic tone and color controls. Temperature and tint are relative, like the Camera Raw Filter's own, because
/// these pixels have already been developed.
nonisolated struct CameraRawLocalAdjustments: Codable, Equatable, Sendable {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var texture: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0

    init() {}

    /// Every key read if it is there, its default if not: a mask saved before a control existed still loads.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        func read(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            try values.decodeIfPresent(Double.self, forKey: key) ?? fallback
        }
        exposure = try read(.exposure, base.exposure)
        contrast = try read(.contrast, base.contrast)
        highlights = try read(.highlights, base.highlights)
        shadows = try read(.shadows, base.shadows)
        whites = try read(.whites, base.whites)
        blacks = try read(.blacks, base.blacks)
        temperature = try read(.temperature, base.temperature)
        tint = try read(.tint, base.tint)
        vibrance = try read(.vibrance, base.vibrance)
        saturation = try read(.saturation, base.saturation)
        texture = try read(.texture, base.texture)
        clarity = try read(.clarity, base.clarity)
        dehaze = try read(.dehaze, base.dehaze)
    }

    var isIdentity: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0 && whites == 0 && blacks == 0
            && temperature == 0 && tint == 0 && vibrance == 0 && saturation == 0
            && texture == 0 && clarity == 0 && dehaze == 0
    }

    var isValid: Bool {
        [exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation,
         texture, clarity, dehaze].allSatisfy { $0.isFinite && CameraRawSettings.toneRange.contains($0) }
            && CameraRawSettings.exposureRange.contains(exposure)
    }

    var normalized: Self {
        var result = self
        result.exposure = ImageAdjustmentPixels.clamp(exposure, CameraRawSettings.exposureRange, 0)
        for key in [\Self.contrast, \Self.highlights, \Self.shadows, \Self.whites, \Self.blacks, \Self.temperature,
                    \Self.tint, \Self.vibrance, \Self.saturation, \Self.texture, \Self.clarity, \Self.dehaze] {
            result[keyPath: key] = ImageAdjustmentPixels.clamp(result[keyPath: key], CameraRawSettings.toneRange, 0)
        }
        return result
    }

    /// The whole-picture grade carrying just these amounts: what the existing Camera Raw passes evaluate, so a local
    /// adjustment is the same math as the global one and not a second implementation of it.
    var settings: CameraRawSettings {
        var settings = CameraRawSettings()
        let values = normalized
        settings.whiteBalance = .custom
        settings.exposure = values.exposure
        settings.contrast = values.contrast
        settings.highlights = values.highlights
        settings.shadows = values.shadows
        settings.whites = values.whites
        settings.blacks = values.blacks
        settings.temperature = values.temperature
        settings.tint = values.tint
        settings.vibrance = values.vibrance
        settings.saturation = values.saturation
        settings.texture = values.texture
        settings.clarity = values.clarity
        settings.dehaze = values.dehaze
        return settings
    }
}

/// One region of a photograph with its own adjustments. Positions are normalized within the *corrected* frame — the
/// picture the preview shows after de-squeeze, geometry and crop — so what is drawn on the canvas is where the
/// adjustment lands, in the preview, on OK, and in an export of the same settings.
nonisolated struct CameraRawLocalMask: Codable, Equatable, Sendable, Identifiable {
    static let maximumCount = 8
    static let featherRange: ClosedRange<Double> = 0...250
    static let fuzzinessRange: ClosedRange<Double> = 0...200

    var id: UUID = UUID()
    var name: String = "Mask"
    var enabled = true
    var inverted = false
    /// How far the edge fades, in pixels of the corrected frame.
    var feather: Double = 0
    var kind: CameraRawLocalMaskKind = .selection
    var adjustments = CameraRawLocalAdjustments()
    /// Coverage for the raster kinds.
    var raster: CameraRawLocalMaskRaster?
    /// Linear gradient: white at the start, black at the end. Normalized.
    var startX: Double = 0.5
    var startY: Double = 0.2
    var endX: Double = 0.5
    var endY: Double = 0.8
    /// Radial gradient: solid in the middle, fading out to the radii, as fractions of the frame's shorter side.
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var radiusX: Double = 0.35
    var radiusY: Double = 0.35
    /// Color Range: the sampled straight color and how far from it counts.
    var red: Double = 0.5
    var green: Double = 0.5
    var blue: Double = 0.5
    var fuzziness: Double = 40

    init(id: UUID = UUID(), name: String = "Mask", kind: CameraRawLocalMaskKind = .selection) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// Read with every key optional, so a mask saved by an earlier build still loads.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? base.id
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? base.name
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? base.enabled
        inverted = try values.decodeIfPresent(Bool.self, forKey: .inverted) ?? base.inverted
        feather = try values.decodeIfPresent(Double.self, forKey: .feather) ?? base.feather
        kind = try values.decodeIfPresent(CameraRawLocalMaskKind.self, forKey: .kind) ?? base.kind
        adjustments = try values.decodeIfPresent(CameraRawLocalAdjustments.self, forKey: .adjustments) ?? base.adjustments
        raster = try values.decodeIfPresent(CameraRawLocalMaskRaster.self, forKey: .raster)
        startX = try values.decodeIfPresent(Double.self, forKey: .startX) ?? base.startX
        startY = try values.decodeIfPresent(Double.self, forKey: .startY) ?? base.startY
        endX = try values.decodeIfPresent(Double.self, forKey: .endX) ?? base.endX
        endY = try values.decodeIfPresent(Double.self, forKey: .endY) ?? base.endY
        centerX = try values.decodeIfPresent(Double.self, forKey: .centerX) ?? base.centerX
        centerY = try values.decodeIfPresent(Double.self, forKey: .centerY) ?? base.centerY
        radiusX = try values.decodeIfPresent(Double.self, forKey: .radiusX) ?? base.radiusX
        radiusY = try values.decodeIfPresent(Double.self, forKey: .radiusY) ?? base.radiusY
        red = try values.decodeIfPresent(Double.self, forKey: .red) ?? base.red
        green = try values.decodeIfPresent(Double.self, forKey: .green) ?? base.green
        blue = try values.decodeIfPresent(Double.self, forKey: .blue) ?? base.blue
        fuzziness = try values.decodeIfPresent(Double.self, forKey: .fuzziness) ?? base.fuzziness
    }

    /// Whether this mask changes anything: an eye-off mask or a neutral one is not applied at all, so it cannot cost
    /// a pixel of the picture.
    var applies: Bool { enabled && !adjustments.isIdentity }

    var isValid: Bool {
        guard !name.isEmpty, name.count <= 120,
              feather.isFinite, CameraRawLocalMask.featherRange.contains(feather),
              fuzziness.isFinite, CameraRawLocalMask.fuzzinessRange.contains(fuzziness),
              adjustments.isValid,
              [startX, startY, endX, endY, centerX, centerY, radiusX, radiusY, red, green, blue].allSatisfy(\.isFinite),
              (0...1).contains(startX), (0...1).contains(startY), (0...1).contains(endX), (0...1).contains(endY),
              (0...1).contains(centerX), (0...1).contains(centerY),
              (0...1).contains(radiusX), (0...1).contains(radiusY),
              (0...1).contains(red), (0...1).contains(green), (0...1).contains(blue) else { return false }
        if kind.isRaster {
            if kind == .brushPainted { return raster == nil || raster?.isValid == true }
            return raster?.isValid == true
        }
        return true
    }

    var normalized: Self {
        var result = self
        result.name = name.isEmpty ? "Mask" : String(name.prefix(120))
        result.feather = ImageAdjustmentPixels.clamp(feather, CameraRawLocalMask.featherRange, 0)
        result.fuzziness = ImageAdjustmentPixels.clamp(fuzziness, CameraRawLocalMask.fuzzinessRange, 40)
        result.adjustments = adjustments.normalized
        result.startX = ImageAdjustmentPixels.clamp(startX, 0...1, 0.5)
        result.startY = ImageAdjustmentPixels.clamp(startY, 0...1, 0.2)
        result.endX = ImageAdjustmentPixels.clamp(endX, 0...1, 0.5)
        result.endY = ImageAdjustmentPixels.clamp(endY, 0...1, 0.8)
        result.centerX = ImageAdjustmentPixels.clamp(centerX, 0...1, 0.5)
        result.centerY = ImageAdjustmentPixels.clamp(centerY, 0...1, 0.5)
        result.radiusX = ImageAdjustmentPixels.clamp(radiusX, 0...1, 0.35)
        result.radiusY = ImageAdjustmentPixels.clamp(radiusY, 0...1, 0.35)
        result.red = ImageAdjustmentPixels.clamp(red, 0...1, 0.5)
        result.green = ImageAdjustmentPixels.clamp(green, 0...1, 0.5)
        result.blue = ImageAdjustmentPixels.clamp(blue, 0...1, 0.5)
        return result
    }
}

/// Turns local masks into edits: each mask's own adjustments, evaluated by the existing Camera Raw passes and blended
/// back through the mask's coverage, in list order so overlapping regions accumulate as they do everywhere else.
///
/// A mask's coverage is expressed in the corrected frame — the picture the preview shows — with one exception:
/// coverage captured from the document (a selection, Vision's instance, a layer mask) belongs to the photograph's own
/// pixels, so it is carried through the same geometry, distortion and crop the picture went through before it is
/// blended. That keeps a selection-shaped mask on the pixels it was drawn around when the frame is warped.
nonisolated enum CameraRawLocalMaskRenderer {
    /// Painted where a mask shows while its overlay is on. Preview only, never committed.
    static let overlayColor = (red: Double(1), green: Double(0.18), blue: Double(0.18), alpha: Double(0.5))

    /// `image` with every enabled, non-neutral mask applied. Masks are applied one after another, each over the
    /// result of the one before it, so two overlapping masks both count.
    ///
    /// `inputWidth` / `inputHeight` are the frame the settings started from, which is the grid a captured raster is
    /// expressed in; `image` is the corrected, graded frame.
    static func applying(_ masks: [CameraRawLocalMask], to image: CGImage, settings: CameraRawSettings,
                         inputWidth: Int, inputHeight: Int) throws -> CGImage {
        var current = image
        for mask in masks where mask.applies {
            guard let coverage = try coverage(of: mask, settings: settings, image: current,
                                              inputWidth: inputWidth, inputHeight: inputHeight,
                                              width: current.width, height: current.height) else { continue }
            let adjusted = try mask.adjustments.settings.apply(current)
            current = try blend(adjusted, over: current, through: coverage)
        }
        return current
    }

    /// `image` with `maskID`'s region painted, replacing the picture's own grade: a preview of what the mask covers,
    /// not a color change.
    static func overlay(_ masks: [CameraRawLocalMask], maskID: UUID, settings: CameraRawSettings,
                        on image: CGImage, inputWidth: Int, inputHeight: Int) throws -> CGImage {
        guard let mask = masks.first(where: { $0.id == maskID }),
              let coverage = try coverage(of: mask, settings: settings, image: image,
                                          inputWidth: inputWidth, inputHeight: inputHeight,
                                          width: image.width, height: image.height) else {
            return image
        }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let color = CIColor(red: overlayColor.red, green: overlayColor.green, blue: overlayColor.blue,
                            alpha: overlayColor.alpha)
        let painted = CIImage(color: color).cropped(to: extent).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(cgImage: image),
            kCIInputMaskImageKey: CIImage(cgImage: coverage),
        ])
        return try PixelAdjust.render(painted, width: image.width, height: image.height, isMask: false)
    }

    /// The mask's coverage on a `width` × `height` grid: white where it shows, softened by its feather and inverted
    /// when it is. Nil when the coverage is entirely black — nothing to blend, and nothing to spend on blending it.
    static func coverage(of mask: CameraRawLocalMask, settings: CameraRawSettings, image: CGImage?,
                         inputWidth: Int, inputHeight: Int, width: Int, height: Int) throws -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var base: CGImage?
        switch mask.kind {
        case .selection, .objectSelection, .layerMask, .brushPainted:
            base = try capturedCoverage(mask, settings: settings, inputWidth: inputWidth, inputHeight: inputHeight,
                                        width: width, height: height)
        case .linearGradient:
            base = try linearGradient(mask, width: width, height: height)
        case .radialGradient:
            base = try radialGradient(mask, width: width, height: height)
        case .colorRange:
            base = try colorRange(mask, in: image, width: width, height: height)
        }
        guard var coverage = base else { return nil }
        if mask.inverted { coverage = try inverted(coverage) }
        if mask.feather > 0 { coverage = try softened(coverage, radius: mask.feather) }
        return hasCoverage(coverage) ? coverage : nil
    }

    /// A raster captured from the document, carried to the corrected frame by the same lens distortion, geometry,
    /// de-squeeze and crop the picture itself went through: the mask is run through `applyResult` with those stages
    /// and nothing else, so the two are displaced identically rather than by a second implementation of the warps.
    private static func capturedCoverage(_ mask: CameraRawLocalMask, settings: CameraRawSettings,
                                         inputWidth: Int, inputHeight: Int, width: Int, height: Int) throws -> CGImage? {
        guard let raster = mask.raster, let stored = raster.image(width: inputWidth, height: inputHeight) else { return nil }
        guard let warps = warpingStages(of: settings) else { return try resized(stored, width: width, height: height) }
        // Warping is the expensive part and the same for every slider move that does not change geometry, so the
        // warped coverage is kept for the mask it came from.
        let key = WarpedCoverageKey(png: raster.png, settings: warps, inputWidth: inputWidth, inputHeight: inputHeight,
                                    width: width, height: height)
        if let hit = WarpedCoverageCache.shared.image(for: key) { return hit }
        // The mask is coverage, not color: a white-on-black picture warped by the same stages keeps its coverage where
        // the photograph's own pixels went. Anything the warp left transparent reads as no coverage.
        guard let warped = try? warps.applyResult(stored).image,
              let coverage = try? extractedCoverage(warped, width: width, height: height) else {
            return try resized(stored, width: width, height: height)
        }
        WarpedCoverageCache.shared.store(coverage, for: key)
        return coverage
    }

    /// Just the spatial stages of `settings` — lens distortion, de-squeeze, Volume, perspective, Horizon, framing and
    /// Crop After Transform — or nil when none of them moves a pixel. Miniature and Lens Blur are left out: they
    /// soften pixels without displacing them, and softening a mask would move its edge.
    private static func warpingStages(of settings: CameraRawSettings) -> CameraRawSettings? {
        var stages = CameraRawSettings()
        stages.geometry = settings.geometry
        stages.horizon = settings.horizon
        stages.perspectiveTools = settings.perspectiveTools
        stages.crop = settings.crop
        stages.automaticHorizonAngle = settings.automaticHorizonAngle
        // The corner-radius and profile strengths are the picture's own weathering; the mask needs the same k.
        stages.optics.distortion = settings.optics.distortion
        stages.optics.enableLensProfile = settings.optics.enableLensProfile
        stages.optics.profileDistortion = settings.optics.profileDistortion
        let moves = stages.geometry.adjusts || !stages.horizon.isIdentity
            || stages.perspectiveTools.kind != .automatic || !stages.crop.isNoCrop
            || stages.optics.distortionK(profileStrength: PixelFilter.lensStrength) != 0
        return moves ? stages : nil
    }

    /// The red channel of a premultiplied RGBA gray picture as one-channel coverage at `width` × `height`.
    private static func extractedCoverage(_ image: CGImage, width: Int, height: Int) throws -> CGImage? {
        let scaled = try resized(image, width: width, height: height)
        guard let scaled else { return nil }
        let gray = CIImage(cgImage: scaled).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        return try PixelAdjust.render(gray, width: width, height: height, isMask: true)
    }

    private static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage? {
        guard image.width != width || image.height != height else { return image }
        // A gray mask stays gray; a warped picture is read back through its red channel.
        if image.colorSpace?.model == .monochrome, image.bitsPerComponent == 8 {
            guard let context = try? BrushRaster.context(width: width, height: height, mask: true) else { return image }
            context.interpolationQuality = .high
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: true, context: context)
            return context.makeImage()
        }
        guard let context = try? BrushRaster.context(width: width, height: height, mask: false) else { return image }
        context.interpolationQuality = .high
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        return context.makeImage()
    }

    /// Whether any pixel of `coverage` shows at all.
    static func hasCoverage(_ coverage: CGImage) -> Bool {
        guard let context = try? BrushRaster.context(width: coverage.width, height: coverage.height, mask: true) else { return false }
        BrushRaster.draw(coverage, in: CGRect(x: 0, y: 0, width: coverage.width, height: coverage.height),
                         mask: true, context: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        for y in 0..<coverage.height {
            let row = y * context.bytesPerRow
            for x in 0..<coverage.width where data[row + x] != 0 { return true }
        }
        return false
    }

    private static func blend(_ adjusted: CGImage, over base: CGImage, through coverage: CGImage) throws -> CGImage {
        let blended = CIImage(cgImage: adjusted).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(cgImage: base),
            kCIInputMaskImageKey: CIImage(cgImage: coverage),
        ])
        return try PixelAdjust.render(blended, width: base.width, height: base.height, isMask: false)
    }

    private static func inverted(_ coverage: CGImage) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: coverage.width, height: coverage.height)
        let flipped = CIImage(cgImage: coverage).applyingFilter("CIColorInvert").cropped(to: extent)
        return try PixelAdjust.render(flipped, width: coverage.width, height: coverage.height, isMask: true)
    }

    private static func softened(_ coverage: CGImage, radius: Double) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: coverage.width, height: coverage.height)
        let soft = CIImage(cgImage: coverage).clampedToExtent()
            .applyingGaussianBlur(sigma: radius / 2).cropped(to: extent)
        return try PixelAdjust.render(soft, width: coverage.width, height: coverage.height, isMask: true)
    }

    private static func linearGradient(_ mask: CameraRawLocalMask, width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let start = CGPoint(x: mask.startX * Double(width), y: mask.startY * Double(height))
        var end = CGPoint(x: mask.endX * Double(width), y: mask.endY * Double(height))
        // A gradient needs two distinct points; a double-click that never moved still means white everywhere.
        if hypot(end.x - start.x, end.y - start.y) < 1 { end = CGPoint(x: start.x, y: start.y + 1) }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                        colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
                                        locations: [0, 1]) else { throw ExportError.render }
        context.drawLinearGradient(gradient, start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    private static func radialGradient(_ mask: CameraRawLocalMask, width: Int, height: Int) throws -> CGImage {
        let shorter = Double(min(width, height))
        let radius = max(1, max(mask.radiusX, mask.radiusY) * shorter)
        let center = CGPoint(x: mask.centerX * Double(width), y: mask.centerY * Double(height))
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                        colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1),
                                                 CGColor(gray: 0, alpha: 1)] as CFArray,
                                        locations: [0, 0.55, 1]) else { throw ExportError.render }
        // Roundness moves the gradient the other way from the radii: a wider radius is a flatter ellipse.
        let xRatio = max(0.05, mask.radiusX / max(mask.radiusX, mask.radiusY))
        let yRatio = max(0.05, mask.radiusY / max(mask.radiusX, mask.radiusY))
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: xRatio, y: yRatio)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius,
                                   options: [.drawsAfterEndLocation])
        context.restoreGState()
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    private static func colorRange(_ mask: CameraRawLocalMask, in image: CGImage?, width: Int, height: Int) throws -> CGImage? {
        guard let image else { return nil }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        var coverage = [UInt8](repeating: 0, count: width * height)
        let color = [UInt8((min(1, max(0, mask.red)) * 255).rounded()),
                     UInt8((min(1, max(0, mask.green)) * 255).rounded()),
                     UInt8((min(1, max(0, mask.blue)) * 255).rounded())]
        _ = coverage.withUnsafeMutableBufferPointer { out in
            color.withUnsafeBufferPointer { include in
                color_range_mask(data.assumingMemoryBound(to: UInt8.self), width, height, context.bytesPerRow,
                                 include.baseAddress, 1, nil, 0,
                                 Int32(mask.fuzziness.rounded()), 0, out.baseAddress)
            }
        }
        guard let provider = CGDataProvider(data: Data(coverage) as CFData) else { throw ExportError.render }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// One warped local-mask coverage, keyed by the mask's stored pixels and the exact stages that moved them. The warp
/// is identical for every slider that does not change geometry, so dragging Exposure reuses it instead of re-warping.
nonisolated struct WarpedCoverageKey: Equatable {
    let png: Data
    let settings: CameraRawSettings
    let inputWidth: Int
    let inputHeight: Int
    let width: Int
    let height: Int
}

nonisolated final class WarpedCoverageCache: @unchecked Sendable {
    static let shared = WarpedCoverageCache()
    private var entries: [(key: WarpedCoverageKey, image: CGImage)] = []
    private let limit = 4
    private let lock = NSLock()

    func image(for key: WarpedCoverageKey) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.key == key }?.image
    }

    func store(_ image: CGImage, for key: WarpedCoverageKey) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.key == key }
        entries.append((key, image))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }
}
