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

    init() {}

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
        return settings
    }

    /// Whether all values are finite and within sane bounds.
    func isValid() -> Bool {
        [exposure, temperature, tint, boost, noiseReduction,
         asShotTemperature, asShotTint, asShotNoiseReduction].allSatisfy { $0.isFinite }
            && boost >= 0
            && (0...1).contains(Double(noiseReduction))
    }

    var isAsShot: Bool {
        exposure == 0 && boost == 1 && temperature == asShotTemperature && tint == asShotTint
            && noiseReduction == asShotNoiseReduction && lensCorrection == asShotLensCorrection
            && highlightRecovery == asShotHighlightRecovery
    }

    mutating func reset() {
        exposure = 0
        boost = 1
        temperature = asShotTemperature
        tint = asShotTint
        noiseReduction = asShotNoiseReduction
        lensCorrection = asShotLensCorrection
        highlightRecovery = asShotHighlightRecovery
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
