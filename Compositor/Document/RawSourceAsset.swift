import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A durable, self-contained representation of an original camera RAW file.
///
/// The original bytes are held in memory (and serialized inside the project package at
/// `images/<source-id>.raw-source.<ext>`) so a project never depends on the external file
/// remaining available. The bytes are immutable: RAW development settings describe how to
/// interpret them, never modify them.
nonisolated struct RawSourceAsset: Equatable, Sendable {
    /// Stable identity shared across duplicate layers, saves and reloads.
    let sourceID: UUID
    /// Original RAW file bytes, exactly as captured.
    let rawData: Data
    /// Original file extension, e.g. "dng", "cr2", "nef", "arw".
    let fileExtension: String
    /// UTType identifier for the format, e.g. "com.adobe.raw-image".
    let utType: String
    /// Decoded pixel dimensions of the full sensor frame.
    let pixelWidth: Int
    let pixelHeight: Int
    /// Camera metadata extracted from EXIF where present. Values are property-list types only;
    /// missing keys are absent rather than invented.
    let cameraMetadata: [String: Any]
    /// Color space of the RAW data, if determinable.
    let colorSpace: String?
    /// Bits per component of the sensor data.
    let bitsPerComponent: Int
    /// As-shot development defaults read from the file (neutral temperature/tint, etc.).
    let asShotSettings: RawDevelopSettings
    /// Which RAW features this camera's decoder supports.
    let supportsNoiseReduction: Bool
    let supportsLensCorrection: Bool
    let supportsHighlightRecovery: Bool

    init(sourceID: UUID = UUID(),
         rawData: Data,
         fileExtension: String,
         utType: String,
         pixelWidth: Int,
         pixelHeight: Int,
         cameraMetadata: [String: Any] = [:],
         colorSpace: String? = nil,
         bitsPerComponent: Int = 0,
         asShotSettings: RawDevelopSettings,
         supportsNoiseReduction: Bool = false,
         supportsLensCorrection: Bool = false,
         supportsHighlightRecovery: Bool = false) {
        self.sourceID = sourceID
        self.rawData = rawData
        self.fileExtension = fileExtension
        self.utType = utType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.cameraMetadata = cameraMetadata
        self.colorSpace = colorSpace
        self.bitsPerComponent = bitsPerComponent
        self.asShotSettings = asShotSettings
        self.supportsNoiseReduction = supportsNoiseReduction
        self.supportsLensCorrection = supportsLensCorrection
        self.supportsHighlightRecovery = supportsHighlightRecovery
    }

    /// Total bytes of the original source.
    var byteCount: Int { rawData.count }

    /// Megapixels of the decoded sensor frame.
    var megapixels: Double { Double(pixelWidth * pixelHeight) / 1_000_000 }

    /// Suggested internal package filename.
    func fileName() -> String { "\(sourceID.uuidString).raw-source.\(fileExtension)" }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case sourceID, rawData, fileExtension, utType, pixelWidth, pixelHeight,
             cameraMetadata, colorSpace, bitsPerComponent, asShotSettings,
             supportsNoiseReduction, supportsLensCorrection, supportsHighlightRecovery
    }

    /// Property-list-compatible metadata wrapper so `Any` values round-trip through
    /// `NSKeyedArchiver`/`JSONSerialization`-safe types.
    struct MetadataEntry: Codable, Sendable {
        let key: String
        let value: PlistValue
    }

    /// A property-list-safe value: string, int, double, bool, date, data, or nested arrays/dicts.
    enum PlistValue: Codable, Sendable, Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case date(Date)
        case data(Data)
        case array([PlistValue])
        case dictionary([String: PlistValue])

        init(_ value: Any) {
            switch value {
            case let s as String: self = .string(s)
            case let i as Int: self = .int(i)
            case let d as Double: self = .double(d)
            case let b as Bool: self = .bool(b)
            case let date as Date: self = .date(date)
            case let data as Data: self = .data(data)
            case let arr as [Any]: self = .array(arr.map(PlistValue.init))
            case let dict as [String: Any]: self = .dictionary(dict.mapValues(PlistValue.init))
            default: self = .string(String(describing: value))
            }
        }

        var anyValue: Any {
            switch self {
            case .string(let s): return s
            case .int(let i): return i
            case .double(let d): return d
            case .bool(let b): return b
            case .date(let d): return d
            case .data(let d): return d
            case .array(let arr): return arr.map { $0.anyValue }
            case .dictionary(let dict): return dict.mapValues { $0.anyValue }
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decode(UUID.self, forKey: .sourceID)
        rawData = try container.decode(Data.self, forKey: .rawData)
        fileExtension = try container.decode(String.self, forKey: .fileExtension)
        utType = try container.decode(String.self, forKey: .utType)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        let entries = try container.decodeIfPresent([MetadataEntry].self, forKey: .cameraMetadata) ?? []
        cameraMetadata = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value.anyValue) })
        colorSpace = try container.decodeIfPresent(String.self, forKey: .colorSpace)
        bitsPerComponent = try container.decodeIfPresent(Int.self, forKey: .bitsPerComponent) ?? 0
        asShotSettings = try container.decode(RawDevelopSettings.self, forKey: .asShotSettings)
        supportsNoiseReduction = try container.decodeIfPresent(Bool.self, forKey: .supportsNoiseReduction) ?? false
        supportsLensCorrection = try container.decodeIfPresent(Bool.self, forKey: .supportsLensCorrection) ?? false
        supportsHighlightRecovery = try container.decodeIfPresent(Bool.self, forKey: .supportsHighlightRecovery) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(rawData, forKey: .rawData)
        try container.encode(fileExtension, forKey: .fileExtension)
        try container.encode(utType, forKey: .utType)
        try container.encode(pixelWidth, forKey: .pixelWidth)
        try container.encode(pixelHeight, forKey: .pixelHeight)
        let entries = cameraMetadata.map { MetadataEntry(key: $0.key, value: PlistValue($0.value)) }
        try container.encode(entries, forKey: .cameraMetadata)
        try container.encodeIfPresent(colorSpace, forKey: .colorSpace)
        try container.encode(bitsPerComponent, forKey: .bitsPerComponent)
        try container.encode(asShotSettings, forKey: .asShotSettings)
        try container.encode(supportsNoiseReduction, forKey: .supportsNoiseReduction)
        try container.encode(supportsLensCorrection, forKey: .supportsLensCorrection)
        try container.encode(supportsHighlightRecovery, forKey: .supportsHighlightRecovery)
    }
}

extension RawSourceAsset: Codable {}

// MARK: - Equatable (manual; cameraMetadata contains Any which can't be synthesized)

extension RawSourceAsset {
    static func == (lhs: RawSourceAsset, rhs: RawSourceAsset) -> Bool {
        lhs.sourceID == rhs.sourceID
            && lhs.rawData == rhs.rawData
            && lhs.fileExtension == rhs.fileExtension
            && lhs.utType == rhs.utType
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
            && lhs.colorSpace == rhs.colorSpace
            && lhs.bitsPerComponent == rhs.bitsPerComponent
            && lhs.asShotSettings == rhs.asShotSettings
            && lhs.supportsNoiseReduction == rhs.supportsNoiseReduction
            && lhs.supportsLensCorrection == rhs.supportsLensCorrection
            && lhs.supportsHighlightRecovery == rhs.supportsHighlightRecovery
    }
}

/// Versioned Codable mirror of `RawDevelopSettings` for project persistence.
///
/// RAW development settings interpret sensor data; they are distinct from `CameraRawSettings`
/// which adjust an already-developed image. Both can coexist on a RAW-backed layer but are
/// stored and edited independently.
nonisolated struct RawDevelopmentSettingsPersistentState: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int = schemaVersion

    /// Stops of exposure, either side of what the camera recorded.
    var exposure: Float = 0
    /// White balance in Kelvin, starting from the camera's own reading.
    var temperature: Float = 5000
    /// Green–magenta balance, starting from the camera's own reading.
    var tint: Float = 0
    /// Apple's tone curve: 1 is its full interpretation, 0 leaves the image flat and neutral.
    var boost: Float = 1
    /// Luminance noise reduction, 0–1.
    var noiseReduction: Float = 0
    /// Lens distortion/vignetting correction from the file's profile.
    var lensCorrection: Bool = false
    /// Detail brought back in partly-clipped highlights.
    var highlightRecovery: Bool = false
    /// What the camera itself chose, so Reset has somewhere to go back to.
    var asShotTemperature: Float = 5000
    var asShotTint: Float = 0
    var asShotNoiseReduction: Float = 0
    var asShotLensCorrection: Bool = false
    var asShotHighlightRecovery: Bool = false
    /// Which features this camera allows.
    var supportsNoiseReduction: Bool = false
    var supportsLensCorrection: Bool = false
    var supportsHighlightRecovery: Bool = false
    /// Chroma noise reduction at the decoder's own stage (M11.2). Absent in older projects, which decoded with the
    /// camera's own value.
    var colorNoiseReduction: Float = 0
    var asShotColorNoiseReduction: Float = 0
    var supportsColorNoiseReduction: Bool = false
    /// White balance mode (M11.1). Absent in older projects, which decode to As Shot — the mode they were saved in.
    var whiteBalanceMode: String = RawWhiteBalanceMode.asShot.rawValue
    var asShotTemperatureAbsolute: Float = 5000
    var asShotTintAbsolute: Float = 0
    /// Photographic profile (M11.1). Absent in older projects, which decode to Camera Default.
    var colorProfile: ColorProfile = ColorProfile()
    /// Raw Details (M11.2). Absent in older projects, which decode to the decoder's own defaults.
    var rawDetail: RawDetail = RawDetail()
    var rawDetailDefaults: RawDetailDefaults = RawDetailDefaults()
    var supportsRawDetail: Bool = false
    /// Per-control Raw Details availability (M12.5). Absent in older projects; when absent, every control this
    /// decoder exposes is assumed available, which is the behaviour those projects were rendered with.
    var supportsDetail: Bool? = nil
    var supportsSharpness: Bool? = nil
    var supportsContrast: Bool? = nil
    var supportsMoire: Bool? = nil
    /// Which decoder this file was developed with (M12.5). Absent in older projects, which used the system's
    /// decoder for the file — the behaviour they were saved with.
    var decoder: String? = nil
    /// The version the decoder actually reported. Absent in older projects, where the system's choice was not
    /// recorded; the effective version is re-read from a filter when the project opens.
    var effectiveDecoderVersion: String? = nil

    nonisolated struct ColorProfile: Codable, Equatable, Sendable {
        var kind: String = RawColorProfileKind.cameraDefault.rawValue
        var name: String = ""
        var strength: Double = 100
        /// The ICC bytes, base64 in JSON. Absent for the decoder's own profiles.
        var iccData: Data?
    }

    nonisolated struct RawDetail: Codable, Equatable, Sendable {
        var enabled: Bool = false
        var detail: Float = 0
        var sharpness: Float = 0
        var contrast: Float = 0
        var moire: Float = 0

        private enum Keys: String, CodingKey { case enabled, detail, sharpness, contrast, moire }

        init() {}

        init(enabled: Bool, detail: Float, sharpness: Float, contrast: Float, moire: Float) {
            self.enabled = enabled
            self.detail = detail
            self.sharpness = sharpness
            self.contrast = contrast
            self.moire = moire
        }

        /// Decoded field by field. Synthesized decoding of a nested type rejects a missing key even when the property
        /// has a default, so a project written before `moire` existed would fail to load rather than take its neutral
        /// zero. The outer type's tolerant decoding cannot help a nested one (M12.5).
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            detail = try values.decodeIfPresent(Float.self, forKey: .detail) ?? 0
            sharpness = try values.decodeIfPresent(Float.self, forKey: .sharpness) ?? 0
            contrast = try values.decodeIfPresent(Float.self, forKey: .contrast) ?? 0
            moire = try values.decodeIfPresent(Float.self, forKey: .moire) ?? 0
        }
    }

    nonisolated struct RawDetailDefaults: Codable, Equatable, Sendable {
        var detail: Float = 0
        var sharpness: Float = 0
        var contrast: Float = 0
        var moire: Float = 0

        private enum Keys: String, CodingKey { case detail, sharpness, contrast, moire }

        init() {}

        init(detail: Float, sharpness: Float, contrast: Float, moire: Float) {
            self.detail = detail
            self.sharpness = sharpness
            self.contrast = contrast
            self.moire = moire
        }

        /// See `RawDetail`. A baseline written before `moire` existed is the decoder's own amounts without it.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            detail = try values.decodeIfPresent(Float.self, forKey: .detail) ?? 0
            sharpness = try values.decodeIfPresent(Float.self, forKey: .sharpness) ?? 0
            contrast = try values.decodeIfPresent(Float.self, forKey: .contrast) ?? 0
            moire = try values.decodeIfPresent(Float.self, forKey: .moire) ?? 0
        }
    }

    private enum Keys: String, CodingKey {
        case schemaVersion, exposure, temperature, tint, boost, noiseReduction, lensCorrection, highlightRecovery,
             asShotTemperature, asShotTint, asShotNoiseReduction, asShotLensCorrection, asShotHighlightRecovery,
             supportsNoiseReduction, supportsLensCorrection, supportsHighlightRecovery,
             whiteBalanceMode, asShotTemperatureAbsolute, asShotTintAbsolute, colorProfile, rawDetail,
             rawDetailDefaults, supportsRawDetail,
             colorNoiseReduction, asShotColorNoiseReduction, supportsColorNoiseReduction,
             supportsDetail, supportsSharpness, supportsContrast, supportsMoire,
             decoder, effectiveDecoderVersion
    }

    init() {}

    /// The decoder this state was saved with. Absent means the system's own, which is what every project before M12.5
    /// was developed with.
    var selectedDecoder: RawDecoderChoice {
        decoder.flatMap(RawDecoderChoice.init(rawValue:)) ?? .systemDefault
    }

    /// Whether the saved decoder offers each Raw Details control. An absent flag means available: projects written
    /// before the per-control flags existed offered every control their decoder had, so reading absence as
    /// unavailable would disable sliders that used to work.
    var offersDetail: Bool { supportsDetail ?? supportsRawDetail }
    var offersSharpness: Bool { supportsSharpness ?? supportsRawDetail }
    var offersContrast: Bool { supportsContrast ?? supportsRawDetail }
    var offersMoire: Bool { supportsMoire ?? supportsRawDetail }

    /// The Raw Details amounts this decoder cannot apply, so the sheet can say which are being held rather than lost.
    var unavailableRawDetailControls: [RawDetailControl] {
        var unavailable: [RawDetailControl] = []
        if !offersDetail { unavailable.append(.detail) }
        if !offersSharpness { unavailable.append(.sharpness) }
        if !offersContrast { unavailable.append(.contrast) }
        if !offersMoire { unavailable.append(.moire) }
        return unavailable
    }

    /// Every field defaults to the rendering an older project was saved with, so a state written before a field
    /// existed decodes unchanged rather than failing.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let base = Self()
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? base.schemaVersion
        exposure = try values.decodeIfPresent(Float.self, forKey: .exposure) ?? base.exposure
        temperature = try values.decodeIfPresent(Float.self, forKey: .temperature) ?? base.temperature
        tint = try values.decodeIfPresent(Float.self, forKey: .tint) ?? base.tint
        boost = try values.decodeIfPresent(Float.self, forKey: .boost) ?? base.boost
        noiseReduction = try values.decodeIfPresent(Float.self, forKey: .noiseReduction) ?? base.noiseReduction
        lensCorrection = try values.decodeIfPresent(Bool.self, forKey: .lensCorrection) ?? base.lensCorrection
        highlightRecovery = try values.decodeIfPresent(Bool.self, forKey: .highlightRecovery) ?? base.highlightRecovery
        asShotTemperature = try values.decodeIfPresent(Float.self, forKey: .asShotTemperature) ?? base.asShotTemperature
        asShotTint = try values.decodeIfPresent(Float.self, forKey: .asShotTint) ?? base.asShotTint
        asShotNoiseReduction = try values.decodeIfPresent(Float.self, forKey: .asShotNoiseReduction) ?? base.asShotNoiseReduction
        asShotLensCorrection = try values.decodeIfPresent(Bool.self, forKey: .asShotLensCorrection) ?? base.asShotLensCorrection
        asShotHighlightRecovery = try values.decodeIfPresent(Bool.self, forKey: .asShotHighlightRecovery) ?? base.asShotHighlightRecovery
        supportsNoiseReduction = try values.decodeIfPresent(Bool.self, forKey: .supportsNoiseReduction) ?? base.supportsNoiseReduction
        supportsLensCorrection = try values.decodeIfPresent(Bool.self, forKey: .supportsLensCorrection) ?? base.supportsLensCorrection
        supportsHighlightRecovery = try values.decodeIfPresent(Bool.self, forKey: .supportsHighlightRecovery) ?? base.supportsHighlightRecovery
        // M11.1 and M11.2: absent means the rendering the project was saved with.
        whiteBalanceMode = try values.decodeIfPresent(String.self, forKey: .whiteBalanceMode) ?? base.whiteBalanceMode
        asShotTemperatureAbsolute = try values.decodeIfPresent(Float.self, forKey: .asShotTemperatureAbsolute)
            ?? asShotTemperature
        asShotTintAbsolute = try values.decodeIfPresent(Float.self, forKey: .asShotTintAbsolute) ?? asShotTint
        colorProfile = try values.decodeIfPresent(ColorProfile.self, forKey: .colorProfile) ?? base.colorProfile
        rawDetail = try values.decodeIfPresent(RawDetail.self, forKey: .rawDetail) ?? base.rawDetail
        // Absent in a project written before the baseline existed; its offsets were measured against zero then.
        rawDetailDefaults = try values.decodeIfPresent(RawDetailDefaults.self, forKey: .rawDetailDefaults)
            ?? base.rawDetailDefaults
        supportsRawDetail = try values.decodeIfPresent(Bool.self, forKey: .supportsRawDetail) ?? base.supportsRawDetail
        colorNoiseReduction = try values.decodeIfPresent(Float.self, forKey: .colorNoiseReduction)
            ?? asShotNoiseReduction
        asShotColorNoiseReduction = try values.decodeIfPresent(Float.self, forKey: .asShotColorNoiseReduction)
            ?? asShotNoiseReduction
        supportsColorNoiseReduction = try values.decodeIfPresent(Bool.self, forKey: .supportsColorNoiseReduction)
            ?? base.supportsColorNoiseReduction
        // M12.5: absent means this project never chose a decoder, so it keeps the system's own — the rendering it was
        // saved with — and every Raw Details control that decoder exposes stays available, as it was.
        self.decoder = try values.decodeIfPresent(String.self, forKey: .decoder)
        effectiveDecoderVersion = try values.decodeIfPresent(String.self, forKey: .effectiveDecoderVersion)
        supportsDetail = try values.decodeIfPresent(Bool.self, forKey: .supportsDetail)
        supportsSharpness = try values.decodeIfPresent(Bool.self, forKey: .supportsSharpness)
        supportsContrast = try values.decodeIfPresent(Bool.self, forKey: .supportsContrast)
        supportsMoire = try values.decodeIfPresent(Bool.self, forKey: .supportsMoire)
    }

    init(_ settings: RawDevelopSettings) {
        exposure = settings.exposure
        temperature = settings.temperature
        tint = settings.tint
        boost = settings.boost
        noiseReduction = settings.noiseReduction
        lensCorrection = settings.lensCorrection
        highlightRecovery = settings.highlightRecovery
        asShotTemperature = settings.asShotTemperature
        asShotTint = settings.asShotTint
        asShotNoiseReduction = settings.asShotNoiseReduction
        asShotLensCorrection = settings.asShotLensCorrection
        asShotHighlightRecovery = settings.asShotHighlightRecovery
        supportsNoiseReduction = settings.supportsNoiseReduction
        supportsLensCorrection = settings.supportsLensCorrection
        supportsHighlightRecovery = settings.supportsHighlightRecovery
        whiteBalanceMode = settings.whiteBalanceMode.rawValue
        asShotTemperatureAbsolute = settings.asShotTemperatureAbsolute
        asShotTintAbsolute = settings.asShotTintAbsolute
        colorProfile = ColorProfile(kind: settings.colorProfile.kind.rawValue, name: settings.colorProfile.name,
                                    strength: settings.colorProfile.strength, iccData: settings.colorProfile.iccData)
        rawDetail = RawDetail(enabled: settings.rawDetail.enabled, detail: settings.rawDetail.detail,
                              sharpness: settings.rawDetail.sharpness, contrast: settings.rawDetail.contrast,
                              moire: settings.rawDetail.moire)
        rawDetailDefaults = RawDetailDefaults(detail: settings.rawDetailDefaults.detail,
                                             sharpness: settings.rawDetailDefaults.sharpness,
                                             contrast: settings.rawDetailDefaults.contrast,
                                             moire: settings.rawDetailDefaults.moire)
        supportsRawDetail = settings.supportsRawDetail
        colorNoiseReduction = settings.colorNoiseReduction
        asShotColorNoiseReduction = settings.asShotColorNoiseReduction
        supportsColorNoiseReduction = settings.supportsColorNoiseReduction
        supportsDetail = settings.supportsDetail
        supportsSharpness = settings.supportsSharpness
        supportsContrast = settings.supportsContrast
        supportsMoire = settings.supportsMoire
        decoder = settings.decoder.rawValue
        effectiveDecoderVersion = settings.effectiveDecoderVersion
    }

    /// Converts back to the live `RawDevelopSettings` used by `RawImporter`.
    func makeSettings() -> RawDevelopSettings {
        var settings = RawDevelopSettings()
        settings.exposure = exposure
        settings.temperature = temperature
        settings.tint = tint
        settings.boost = boost
        settings.noiseReduction = noiseReduction
        settings.lensCorrection = lensCorrection
        settings.highlightRecovery = highlightRecovery
        settings.asShotTemperature = asShotTemperature
        settings.asShotTint = asShotTint
        settings.asShotNoiseReduction = asShotNoiseReduction
        settings.asShotLensCorrection = asShotLensCorrection
        settings.asShotHighlightRecovery = asShotHighlightRecovery
        settings.supportsNoiseReduction = supportsNoiseReduction
        settings.supportsLensCorrection = supportsLensCorrection
        settings.supportsHighlightRecovery = supportsHighlightRecovery
        settings.whiteBalanceMode = RawWhiteBalanceMode(rawValue: whiteBalanceMode) ?? .asShot
        settings.asShotTemperatureAbsolute = asShotTemperatureAbsolute
        settings.asShotTintAbsolute = asShotTintAbsolute
        settings.colorProfile = RawColorProfile(kind: RawColorProfileKind(rawValue: colorProfile.kind) ?? .cameraDefault,
                                               iccData: colorProfile.iccData, name: colorProfile.name,
                                               strength: colorProfile.strength).normalized
        settings.rawDetail = RawDetailSettings(enabled: rawDetail.enabled, detail: rawDetail.detail,
                                              sharpness: rawDetail.sharpness, contrast: rawDetail.contrast,
                                              moire: rawDetail.moire).normalized
        settings.rawDetailDefaults = RawDetailBaseline(detail: rawDetailDefaults.detail,
                                                       sharpness: rawDetailDefaults.sharpness,
                                                       contrast: rawDetailDefaults.contrast,
                                                       moire: rawDetailDefaults.moire)
        settings.supportsRawDetail = supportsRawDetail
        settings.colorNoiseReduction = colorNoiseReduction
        settings.asShotColorNoiseReduction = asShotColorNoiseReduction
        settings.supportsColorNoiseReduction = supportsColorNoiseReduction
        // M12.5: a project written before the per-control flags existed offered every control its decoder had, so an
        // absent flag means available rather than unavailable. Reading it the other way would disable sliders on
        // projects that used to work.
        settings.supportsDetail = supportsDetail ?? supportsRawDetail
        settings.supportsSharpness = supportsSharpness ?? supportsRawDetail
        settings.supportsContrast = supportsContrast ?? supportsRawDetail
        settings.supportsMoire = supportsMoire ?? supportsRawDetail
        // Absent means the system's own decoder: the one every project before M12.5 was developed with.
        settings.decoder = decoder.flatMap(RawDecoderChoice.init(rawValue:)) ?? .systemDefault
        settings.effectiveDecoderVersion = effectiveDecoderVersion ?? ""
        return settings
    }

    /// Whether all values are finite and within sane bounds.
    func isValid() -> Bool {
        [exposure, temperature, tint, boost, noiseReduction,
         asShotTemperature, asShotTint, asShotNoiseReduction,
         asShotTemperatureAbsolute, asShotTintAbsolute,
         colorNoiseReduction, asShotColorNoiseReduction].allSatisfy { $0.isFinite }
            && boost >= 0
            && (0...1).contains(Double(noiseReduction))
            && (0...1).contains(Double(colorNoiseReduction))
            && RawColorProfileKind(rawValue: colorProfile.kind) != nil
            && colorProfile.strength.isFinite
            && RawWhiteBalanceMode(rawValue: whiteBalanceMode) != nil
            // M12.5: an unknown decoder name is a corrupt or future project, not a reason to quietly develop with a
            // different decoder than the one it names.
            && (decoder == nil || RawDecoderChoice(rawValue: decoder!) != nil)
    }

    var isAsShot: Bool {
        exposure == 0 && boost == 1 && temperature == asShotTemperature && tint == asShotTint
            && noiseReduction == asShotNoiseReduction && lensCorrection == asShotLensCorrection
            && highlightRecovery == asShotHighlightRecovery && whiteBalanceMode == RawWhiteBalanceMode.asShot.rawValue
            && colorProfile.kind == RawColorProfileKind.cameraDefault.rawValue
            && colorNoiseReduction == asShotColorNoiseReduction
    }

    /// Back to the file's own development: no exposure or boost change, the camera's balance, its noise
    /// reductions, and the decoder's own profile and detail rendering.
    mutating func reset() {
        exposure = 0
        boost = 1
        temperature = asShotTemperature
        tint = asShotTint
        noiseReduction = asShotNoiseReduction
        colorNoiseReduction = asShotColorNoiseReduction
        lensCorrection = asShotLensCorrection
        highlightRecovery = asShotHighlightRecovery
        whiteBalanceMode = RawWhiteBalanceMode.asShot.rawValue
        colorProfile = ColorProfile()
        rawDetail = RawDetail()
        // The decoder choice is not an adjustment, so Reset to As Shot leaves it alone: a person who chose RAW 9 and
        // then reset their sliders keeps RAW 9. Only the interpretation's settings go back, never which decoder the
        // film was developed with.
    }
}

/// The persistent state of a RAW-backed layer's development: the immutable source, the current
/// settings, and the dimensions/format of the last developed output.
nonisolated struct RawDevelopmentPersistentState: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int = schemaVersion
    var source: RawSourceAsset
    var settings: RawDevelopmentSettingsPersistentState
    /// Dimensions of the developed output at last full-resolution develop.
    var developedWidth: Int
    var developedHeight: Int
    /// Color space the developed image was rendered into.
    var developedColorSpace: String
    /// 8 or 16 bits per component.
    var developedBitsPerComponent: Int

    init(source: RawSourceAsset,
         settings: RawDevelopmentSettingsPersistentState,
         developedWidth: Int,
         developedHeight: Int,
         developedColorSpace: String,
         developedBitsPerComponent: Int) {
        self.schemaVersion = Self.schemaVersion
        self.source = source
        self.settings = settings
        self.developedWidth = developedWidth
        self.developedHeight = developedHeight
        self.developedColorSpace = developedColorSpace
        self.developedBitsPerComponent = developedBitsPerComponent
    }
}

/// Budgets for RAW source retention, shared with the document limits.
/// Defined in RawDevelopmentRenderer.swift.
