import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// What a camera recorded, before anyone decided how it should look. The file holds one value per
/// photosite at 12–14 bits; every choice a JPEG has already baked in — exposure, white balance,
/// contrast — is still open. Compositor's layers are 8-bit, so that latitude has to be spent at
/// import: these are the controls for spending it deliberately rather than accepting a default.
nonisolated struct RawDevelopSettings: Equatable, Sendable, Codable {
    /// Stops of exposure, either side of what the camera recorded.
    var exposure: Float = 0
    /// White balance in Kelvin, starting from the camera's own reading.
    var temperature: Float = 5000
    /// Green–magenta balance, starting from the camera's own reading.
    var tint: Float = 0
    /// Apple's tone curve: 1 is its full interpretation, 0 leaves the image flat and neutral.
    var boost: Float = 1
    /// Luminance noise reduction, 0–1, starting where the system's RAW engine starts for this camera.
    var noiseReduction: Float = 0
    /// Chroma noise reduction at the decoder's own stage (M11.2). A different thing from the rendered picture's
    /// Color slider in Camera Raw Detail: this runs while the sensor data is still mosaic, where the color noise
    /// is separate from the luminance and can be removed without touching either.
    var colorNoiseReduction: Float = 0
    /// The lens's distortion and vignetting taken out, from the profile in the file, where it has one.
    var lensCorrection = false
    /// Detail brought back in highlights the camera only partly clipped (one or two channels blown).
    var highlightRecovery = false
    /// What the camera itself chose, so Reset has somewhere to go back to.
    var asShotTemperature: Float = 5000
    var asShotTint: Float = 0
    var asShotNoiseReduction: Float = 0
    var asShotColorNoiseReduction: Float = 0
    var asShotLensCorrection = false
    var asShotHighlightRecovery = false
    /// Which of those this file's camera allows; the others stay as they are.
    var supportsNoiseReduction = false
    var supportsColorNoiseReduction = false
    var supportsLensCorrection = false
    var supportsHighlightRecovery = false
    /// How the white balance was arrived at. As Shot uses the camera's own reading; Auto has been solved from the
    /// frame; Custom is what the Kelvin and Tint sliders were set to (M11.1).
    var whiteBalanceMode: RawWhiteBalanceMode = .asShot
    /// The camera's own absolute reading, kept so As Shot has somewhere to return to after a solve.
    var asShotTemperatureAbsolute: Float = 5000
    var asShotTintAbsolute: Float = 0
    /// The photographic profile: the decoder's camera rendering, its linear decode, or an ICC profile.
    var colorProfile = RawColorProfile()
    /// Raw Details (M11.2): the decoder's own detail reconstruction, off by default so nothing changes unless asked.
    var rawDetail = RawDetailSettings()
    /// What the decoder does to this file on its own; Raw Details' offsets are applied to these.
    var rawDetailDefaults = RawDetailBaseline()
    /// Whether this camera's decoder exposes its detail reconstruction and contrast controls.
    var supportsRawDetail = false

    var isAsShot: Bool {
        exposure == 0 && boost == 1 && temperature == asShotTemperature && tint == asShotTint
            && noiseReduction == asShotNoiseReduction && lensCorrection == asShotLensCorrection
            && colorNoiseReduction == asShotColorNoiseReduction
            && highlightRecovery == asShotHighlightRecovery && whiteBalanceMode == .asShot
            && !colorProfile.adjusts && rawDetail.isIdentity
    }
    mutating func reset() {
        exposure = 0
        boost = 1
        temperature = asShotTemperature
        tint = asShotTint
        noiseReduction = asShotNoiseReduction
        colorNoiseReduction = asShotColorNoiseReduction
        lensCorrection = asShotLensCorrection
        highlightRecovery = asShotHighlightRecovery
        whiteBalanceMode = .asShot
        colorProfile = RawColorProfile()
        rawDetail = RawDetailSettings()
    }

    /// The Kelvin and tint to develop at. The mode labels how they were arrived at (As Shot, Auto, Custom) and
    /// Reset restores the camera's own reading; the pixels come from these two values alone, so a project saved
    /// before the mode existed develops exactly as it did.
    var developmentBalance: (temperature: Float, tint: Float) { (temperature, tint) }

    /// Whether the decoder can still be asked for its detail reconstruction on this file.
    var canUseRawDetail: Bool { supportsRawDetail && !rawDetail.isIdentity }
}

/// What the decoder already does to this file before any of Raw Details' offsets apply: its own detail, sharpness,
/// contrast and moire amounts. Read once from a freshly built filter, because a filter that has been developed has
/// its own values changed. Kept in the project so a reopen reproduces the same rendering even if the system's
/// defaults for the file were to change (M11.2).
nonisolated struct RawDetailBaseline: Equatable, Sendable, Codable {
    var detail: Float = 0
    var sharpness: Float = 0
    var contrast: Float = 0
    var moire: Float = 0

    init(detail: Float = 0, sharpness: Float = 0, contrast: Float = 0, moire: Float = 0) {
        self.detail = detail
        self.sharpness = sharpness
        self.contrast = contrast
        self.moire = moire
    }

    /// A filter's values as it was just built, before anything was developed through it.
    init(_ filter: CIRAWFilter) {
        detail = filter.isDetailSupported ? filter.detailAmount : 0
        sharpness = filter.isSharpnessSupported ? filter.sharpnessAmount : 0
        contrast = filter.isContrastSupported ? filter.contrastAmount : 0
        moire = filter.isMoireReductionSupported ? filter.moireReductionAmount : 0
    }
}

/// Raw Details: the decoder's own detail reconstruction, run on the sensor data before it becomes pixels
/// (M11.2). The amounts are the decoder's own, and each is *offset from what the decoder already does* rather than
/// absolute: a camera's decode arrives with its own sharpness already applied (0.72 on the EOS 5DS R measured here),
/// so a control at zero that means "no sharpness" would silently remove the camera's rendering. Zero here means the
/// decoder's own value, which the develop reads off the filter once, per file.
nonisolated struct RawDetailSettings: Equatable, Sendable, Codable {
    /// Whether Raw Details takes part at all. Off leaves the decoder exactly as it was.
    var enabled = false
    /// Extra edge detail recovery, −1…2 on top of the decoder's own.
    var detail: Float = 0
    /// Sharpness, −0.75…0.28 on top of the decoder's own; zero is the camera's existing sharpening.
    var sharpness: Float = 0
    /// Local edge contrast, −1…1.
    var contrast: Float = 0
    /// Moire reduction, −1…3.
    var moire: Float = 0

    /// Ranges offered, as offsets. Sharpness is narrower upward because the decoder's own value plus these must
    /// stay inside 0…1, and its default is already high on the files measured.
    static let detailRange: ClosedRange<Float> = -1...2
    static let sharpnessRange: ClosedRange<Float> = -0.75...0.28
    static let contrastRange: ClosedRange<Float> = -1...1
    static let moireRange: ClosedRange<Float> = -1...3

    /// Whether this leaves the decoder untouched: switched off, or every offset at its neutral zero.
    var isIdentity: Bool { !enabled || (detail == 0 && sharpness == 0 && contrast == 0 && moire == 0) }

    var normalized: Self {
        var result = self
        result.detail = Self.clamp(detail, Self.detailRange)
        result.sharpness = Self.clamp(sharpness, Self.sharpnessRange)
        result.contrast = Self.clamp(contrast, Self.contrastRange)
        result.moire = Self.clamp(moire, Self.moireRange)
        return result
    }

    private static func clamp(_ value: Float, _ range: ClosedRange<Float>) -> Float {
        guard value.isFinite else { return 0 }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

nonisolated enum RawImporter {
    /// One context for every develop: building a CIContext allocates GPU resources, and the sheet
    /// develops again on each slider move. Half-float in linear light throughout, named rather than left to
    /// Core Image's defaults, so nothing is rounded before the final 8-bit pixels.
    private static let context = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    ])

    /// Developing a RAW is seconds of work, so only one runs at a time and the caller waits its
    /// turn. Without this a dragged slider starts a render per pixel moved and they all pile up.
    ///
    /// The preview keeps its filter between renders, which is what makes the sliders feel live:
    /// building a new CIRAWFilter decodes the file again (about 1.5s here), while changing exposure
    /// or white balance on one that already exists costs nothing measurable.
    actor Queue {
        static let shared = Queue()
        private var cached: (url: URL, limit: CGFloat, filter: CIRAWFilter)?

        /// `sixteenBit`: the full frame at 16 bits a channel, for a 16-bit layer (`DeepLayer`); otherwise dithered to 8.
        func develop(_ url: URL, settings: RawDevelopSettings, limit: CGFloat?, sixteenBit: Bool = false) -> CGImage? {
            guard let limit else { return try? RawImporter.develop(url, settings: settings, limit: nil, sixteenBit: sixteenBit) }
            let filter: CIRAWFilter
            if let cached, cached.url == url, cached.limit == limit {
                filter = cached.filter
            } else {
                guard let made = CIRAWFilter(imageURL: url) else { return nil }
                let longest = max(made.nativeSize.width, made.nativeSize.height)
                if longest > limit {
                    made.scaleFactor = Float(limit / longest)
                    made.isDraftModeEnabled = true
                }
                cached = (url, limit, made)
                filter = made
            }
            return RawImporter.render(filter, settings: settings)
        }

        /// Lets go of the decoded frame when the sheet closes.
        func release() { cached = nil }
    }

    /// Every camera RAW the system can develop — 30 formats, from Canon and Nikon to DNG — rather
    /// than a list of vendors that would need extending with each new camera.
    static func matches(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .rawImage)
    }

    /// The camera's own white balance and the engine's own starting points for this camera, which is where the
    /// controls start.
    static func asShot(_ url: URL) -> RawDevelopSettings? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        var settings = RawDevelopSettings(temperature: filter.neutralTemperature, tint: filter.neutralTint)
        settings.noiseReduction = filter.isLuminanceNoiseReductionSupported ? filter.luminanceNoiseReductionAmount : 0
        settings.colorNoiseReduction = filter.isColorNoiseReductionSupported ? filter.colorNoiseReductionAmount : 0
        settings.lensCorrection = filter.isLensCorrectionSupported && filter.isLensCorrectionEnabled
        settings.highlightRecovery = filter.isHighlightRecoverySupported && filter.isHighlightRecoveryEnabled
        settings.asShotTemperature = settings.temperature
        settings.asShotTint = settings.tint
        settings.asShotNoiseReduction = settings.noiseReduction
        settings.asShotColorNoiseReduction = settings.colorNoiseReduction
        settings.asShotLensCorrection = settings.lensCorrection
        settings.asShotHighlightRecovery = settings.highlightRecovery
        settings.supportsNoiseReduction = filter.isLuminanceNoiseReductionSupported
        settings.supportsColorNoiseReduction = filter.isColorNoiseReductionSupported
        settings.supportsLensCorrection = filter.isLensCorrectionSupported
        settings.supportsHighlightRecovery = filter.isHighlightRecoverySupported
        // M11.1: the camera's own absolute reading, reported by the decoder's sensor model rather than guessed.
        settings.asShotTemperatureAbsolute = filter.neutralTemperature
        settings.asShotTintAbsolute = filter.neutralTint
        settings.whiteBalanceMode = .asShot
        // M11.2: whether this file's decoder exposes Raw Details at all, and what it does on its own, read here
        // from a filter nothing has been developed through yet.
        settings.supportsRawDetail = filter.isDetailSupported || filter.isSharpnessSupported
            || filter.isContrastSupported || filter.isMoireReductionSupported
        settings.rawDetailDefaults = RawDetailBaseline(filter)
        return settings
    }

    /// The retained RAW bytes written to a temporary file, for `CIRAWFilter(imageURL:)`. The caller removes it.
    static func temporaryFile(for source: RawSourceAsset) throws -> URL {
        let ext = source.fileExtension.lowercased()
        let known: Set<String> = ["dng", "cr2", "nef", "arw", "rw2", "orf", "pef", "sr2", "erf", "k25", "dcr", "mrw"]
        let name = "compositor-raw-\(UUID().uuidString).\(known.contains(ext) ? ext : "dng")"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try source.rawData.write(to: url, options: .atomic)
        return url
    }

    /// The camera's own balance, without decoding beyond what the filter reports cheaply.
    static func asShotBalance(_ url: URL) -> (temperature: Float, tint: Float)? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        return (filter.neutralTemperature, filter.neutralTint)
    }

    /// The balance whose developed frame is closest to gray, searched through the decoder's own sensor model.
    /// `limit` keeps the search to a small preview: each measurement decodes one frame, so this is a handful of
    /// small decodes rather than any number of full ones. Nil when the file cannot be developed.
    static func solveWhiteBalance(_ url: URL, startingAt start: (temperature: Float, tint: Float),
                                  limit: CGFloat = 512) -> RawWhiteBalanceSolution? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let longest = max(filter.nativeSize.width, filter.nativeSize.height)
        if longest > limit {
            filter.scaleFactor = Float(limit / longest)
            filter.isDraftModeEnabled = true
        }
        var settings = RawDevelopSettings()
        settings.boost = 1
        settings.whiteBalanceMode = .custom
        return RawWhiteBalance.solve(startingAt: start) { temperature, tint in
            settings.temperature = temperature
            settings.tint = tint
            let balance = settings
            guard let image = render(filter, settings: balance) else { return nil }
            return RawWhiteBalance.cast(of: image)
        }
    }

    /// The developed image. `limit` caps the long edge for the preview the sheet shows while the
    /// sliders move; the import itself passes nil and gets the full frame.
    static func develop(_ url: URL, settings: RawDevelopSettings, limit: CGFloat? = nil, sixteenBit: Bool = false) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: url) else { throw ImageImportError.unreadable }
        if let limit {
            let size = filter.nativeSize
            let longest = max(size.width, size.height)
            if longest > limit {
                filter.scaleFactor = Float(limit / longest)
                filter.isDraftModeEnabled = true
            }
        }
        guard let image = render(filter, settings: settings, sixteenBit: sixteenBit) else { throw ImageImportError.unreadable }
        return image
    }

    /// Applies the settings to a filter that already holds the decoded frame, and reads the pixels out.
    fileprivate static func render(_ filter: CIRAWFilter, settings: RawDevelopSettings, sixteenBit: Bool = false) -> CGImage? {
        filter.exposure = settings.exposure
        let balance = settings.developmentBalance
        filter.neutralTemperature = balance.temperature
        filter.neutralTint = balance.tint
        // A linear profile is the decoder's decode with its tone curve taken out; anything else keeps the curve the
        // camera's own rendering uses, so a project without a profile develops exactly as it always did.
        filter.boostAmount = settings.colorProfile.kind == .linear ? 0 : settings.boost
        if settings.supportsNoiseReduction { filter.luminanceNoiseReductionAmount = settings.noiseReduction }
        if settings.supportsColorNoiseReduction { filter.colorNoiseReductionAmount = settings.colorNoiseReduction }
        if settings.supportsLensCorrection { filter.isLensCorrectionEnabled = settings.lensCorrection }
        if settings.supportsHighlightRecovery { filter.isHighlightRecoveryEnabled = settings.highlightRecovery }
        // Raw Details: the decoder's own reconstruction, on the sensor data itself. Offsets from the values this
        // filter already holds, so switching it on without moving a control changes nothing, and zero never removes
        // the sharpening the camera's own rendering does.
        let detail = settings.rawDetail.normalized
        if settings.supportsRawDetail, detail.enabled {
            // Always from the file's own baseline, never from the filter's current values: a filter that has been
            // developed holds the last offsets, so reading them back would compound on every slider move.
            let base = settings.rawDetailDefaults
            if filter.isDetailSupported { filter.detailAmount = min(3, max(0, base.detail + detail.detail)) }
            if filter.isSharpnessSupported { filter.sharpnessAmount = min(1, max(0, base.sharpness + detail.sharpness)) }
            if filter.isContrastSupported { filter.contrastAmount = min(1, max(0, base.contrast + detail.contrast)) }
            if filter.isMoireReductionSupported { filter.moireReductionAmount = min(3, max(0, base.moire + detail.moire)) }
        }
        guard let output = filter.outputImage else { return nil }
        if sixteenBit {
            return context.createCGImage(output, from: output.extent.integral, format: .RGBA16,
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return dithered(output, context: context)
    }

    /// The image as 8-bit sRGB pixels, rounded with a little noise rather than straight down. A RAW holds 12–14 bits;
    /// rounded plainly to 8, a smooth sky came out in visible steps, which curves and levels then pulled further apart.
    /// Noise of about one 8-bit step, too fine to see, breaks the steps up, as Lightroom does on export. The frame is
    /// rendered once at 16 bits, then rounded on every core in C: a few tens of milliseconds on a 20-megapixel photo.
    static func dithered(_ image: CIImage, context: CIContext) -> CGImage? {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, let target = try? BrushRaster.context(width: width, height: height, mask: false),
              let data = target.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var wide = [UInt16](repeating: 0, count: width * height * 4)
        wide.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 8, bounds: extent, format: .RGBA16,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        // In C, where the per-pixel work is quick in any build.
        wide.withUnsafeBufferPointer { dither_quantize16($0.baseAddress!, data, width, height, target.bytesPerRow) }
        return target.makeImage()
    }


    /// The frame's size without developing it, so an oversized file is refused before the work.
    static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Focal length and an estimated sensor width for Camera Raw volume auto. Zeros when EXIF is missing.
    static func lensGeometry(_ url: URL) -> RawLensGeometry {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return RawLensGeometry()
        }
        return RawLensGeometry(properties: props)
    }
}

/// EXIF focal / sensor hints threaded from RAW import into Camera Raw Geometry.
nonisolated struct RawLensGeometry: Equatable, Sendable {
    var focalLengthMm: Double = 0
    var sensorWidthMm: Double = 0

    init(focalLengthMm: Double = 0, sensorWidthMm: Double = 0) {
        self.focalLengthMm = focalLengthMm
        self.sensorWidthMm = sensorWidthMm
    }

    init(properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let focal = Self.number(exif?[kCGImagePropertyExifFocalLength])
            ?? Self.number(properties[kCGImagePropertyExifFocalLength])
        let focal35 = Self.number(exif?[kCGImagePropertyExifFocalLenIn35mmFilm])
        focalLengthMm = focal ?? 0
        // Prefer an explicit sensor width; otherwise infer from 35 mm equivalent: sensorWidth ≈ 36 * f / f35.
        if let focal, let focal35, focal35 > 0 {
            sensorWidthMm = 36 * focal / focal35
        } else {
            sensorWidthMm = 0
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        if let number = value as? Float { return Double(number) }
        if let number = value as? Int { return Double(number) }
        return nil
    }
}
