import CoreImage
import Foundation

/// Which decoder version a RAW is developed with.
///
/// Two choices only, and the second is opt-in: a project that never asked for it develops exactly as it
/// always has. The choice is per file, stored in that file's development settings — there is no app-wide
/// preference, and opening an older project never upgrades it (M12.5).
nonisolated enum RawDecoderChoice: String, Codable, Sendable, CaseIterable {
    /// Whatever the system's RAW engine picks for this file, which is what every earlier version did.
    case systemDefault = "System Default"
    /// Apple RAW 9, where this particular file genuinely supports it.
    case appleRAW9 = "Apple RAW 9"

    var label: String { rawValue }

    /// The decoder versions to ask for, most preferred first. RAW 9 has two spellings: `9` for the system's
    /// RAW pipeline and `9.dng` for DNG. Both are RAW 9 — a file may list one, the other, or both — so both
    /// are candidates rather than one being a fallback to something else.
    ///
    /// Named by their reported strings rather than `CIRAWDecoderVersion.version9`, which the SDK gates to macOS 27
    /// while this app deploys to macOS 26. The string initializer is not gated, and the read-back below is what
    /// decides whether a host genuinely runs the version — so an older OS that cannot decode RAW 9 refuses it at the
    /// same place an unsupported file does, instead of the app failing to build or the choice being compiled out.
    var requestedVersions: [CIRAWDecoderVersion] {
        switch self {
        case .systemDefault: return []
        case .appleRAW9: return ["9", "9.dng"].map { CIRAWDecoderVersion(rawValue: $0) }
        }
    }

    /// The spellings RAW 9 can take, as the decoder reports them back.
    static let raw9EffectiveVersions: Set<String> = ["9", "9.dng"]
}

/// Whether a requested decoder version is genuinely in effect.
///
/// The API does not fail an unsupported request: it silently keeps another version. So the only trustworthy
/// test is asking the filter what version it now reports, which is what this models. A request that was
/// listed and applied, one that was never listed, and one that was listed but not honoured are three
/// different outcomes, and the third is the one that must never be shown to the user as the requested decoder.
nonisolated enum RawDecoderVerdict: Equatable, Sendable {
    /// The filter reports the version that was asked for.
    case applied(effective: String)
    /// The file does not list the version at all.
    case notListed(requested: String, supported: [String])
    /// The version was requested and the filter kept a different one.
    case ignored(requested: String, effective: String)

    var isApplied: Bool {
        if case .applied = self { return true }
        return false
    }

    var effectiveVersion: String? {
        switch self {
        case .applied(let effective), .ignored(_, let effective): return effective
        case .notListed: return nil
        }
    }

    /// Why this request did not take, for a message the reader can act on.
    var explanation: String? {
        switch self {
        case .applied: return nil
        case .notListed(let requested, let supported):
            let offered = supported.isEmpty ? "no version it names" : supported.joined(separator: ", ")
            return "This file's decoder does not offer version \(requested); it names \(offered)."
        case .ignored(let requested, let effective):
            return "Version \(requested) was requested but this file's decoder developed with version "
                + "\(effective) instead, so it is not available here."
        }
    }
}

/// The pure decision behind [`RawDecoderVerdict`], separated from `CIRAWFilter` so the unsupported paths can
/// be tested without a machine that has the decoder — or without a file that lacks it.
nonisolated enum RawDecoderSelection {
    /// Decides whether a request is genuinely in effect, given what the file lists and what the filter
    /// reported after the assignment.
    ///
    /// A version that is listed but reads back as something else was not honoured. A version that is not
    /// listed was not offered, whether or not the filter happens to accept it.
    static func verdict(requested: String, supported: [String], effective: String) -> RawDecoderVerdict {
        guard supported.contains(requested) else {
            return .notListed(requested: requested, supported: supported)
        }
        guard effective == requested else {
            return .ignored(requested: requested, effective: effective)
        }
        return .applied(effective: effective)
    }

    /// Whether a file can offer RAW 9 at all, judged from its own list. True for either spelling.
    static func offersRaw9(supported: [String]) -> Bool {
        supported.contains { RawDecoderChoice.raw9EffectiveVersions.contains($0) }
    }

    /// Whether `choice` can be offered for a file that lists `supported` versions. The system default is
    /// always available: it means "leave the filter alone", which cannot fail.
    static func isAvailable(_ choice: RawDecoderChoice, supported: [String]) -> Bool {
        switch choice {
        case .systemDefault: return true
        case .appleRAW9: return offersRaw9(supported: supported)
        }
    }
}

/// What the decoder exposes for one file at one version. Read from a filter that already has the version
/// applied: under RAW 9 a DNG loses its color noise reduction, its detail reconstruction and its moiré
/// reduction, so support captured before the switch describes a different decoder (M12.5).
nonisolated struct RawDecoderCapabilities: Equatable, Sendable {
    /// The version the filter picked on its own, before any request.
    var defaultVersion: String
    /// Every version the file lists.
    var supportedVersions: [String]
    /// The version actually in effect now.
    var effectiveVersion: String

    var supportsLuminanceNoiseReduction: Bool
    var supportsColorNoiseReduction: Bool
    var supportsDetail: Bool
    var supportsSharpness: Bool
    var supportsContrast: Bool
    var supportsMoireReduction: Bool
    var supportsHighlightRecovery: Bool
    var supportsLensCorrection: Bool

    /// The decoder's own amounts, read here so a version switch recaptures them rather than carrying the
    /// previous decoder's baseline across.
    var detailAmount: Float
    var sharpnessAmount: Float
    var contrastAmount: Float
    var moireAmount: Float

    /// `filter` must already hold the decoder version this describes.
    init(_ filter: CIRAWFilter) {
        defaultVersion = filter.decoderVersion.rawValue
        supportedVersions = filter.supportedDecoderVersions.map(\.rawValue)
        effectiveVersion = filter.decoderVersion.rawValue
        supportsLuminanceNoiseReduction = filter.isLuminanceNoiseReductionSupported
        supportsColorNoiseReduction = filter.isColorNoiseReductionSupported
        supportsDetail = filter.isDetailSupported
        supportsSharpness = filter.isSharpnessSupported
        supportsContrast = filter.isContrastSupported
        supportsMoireReduction = filter.isMoireReductionSupported
        supportsHighlightRecovery = filter.isHighlightRecoverySupported
        supportsLensCorrection = filter.isLensCorrectionSupported
        detailAmount = filter.isDetailSupported ? filter.detailAmount : 0
        sharpnessAmount = filter.isSharpnessSupported ? filter.sharpnessAmount : 0
        contrastAmount = filter.isContrastSupported ? filter.contrastAmount : 0
        moireAmount = filter.isMoireReductionSupported ? filter.moireReductionAmount : 0
    }

    /// A state read back from a project, for when no filter can be built here (the source bytes are held, so they can).
    /// The saved flags describe the decoder it was developed with; the sheet re-reads them from a filter when one can
    /// be built, so this is only a starting point.
    init(_ settings: RawDevelopSettings) {
        defaultVersion = settings.effectiveDecoderVersion
        supportedVersions = settings.decoder.requestedVersions.map(\.rawValue)
        effectiveVersion = settings.effectiveDecoderVersion
        supportsLuminanceNoiseReduction = settings.supportsNoiseReduction
        supportsColorNoiseReduction = settings.supportsColorNoiseReduction
        supportsDetail = settings.supportsDetail
        supportsSharpness = settings.supportsSharpness
        supportsContrast = settings.supportsContrast
        supportsMoireReduction = settings.supportsMoire
        supportsHighlightRecovery = settings.supportsHighlightRecovery
        supportsLensCorrection = settings.supportsLensCorrection
        detailAmount = settings.rawDetailDefaults.detail
        sharpnessAmount = settings.rawDetailDefaults.sharpness
        contrastAmount = settings.rawDetailDefaults.contrast
        moireAmount = settings.rawDetailDefaults.moire
    }

    /// For tests and for states read back from a project rather than a decoder.
    init(defaultVersion: String, supportedVersions: [String], effectiveVersion: String,
         supportsLuminanceNoiseReduction: Bool, supportsColorNoiseReduction: Bool,
         supportsDetail: Bool, supportsSharpness: Bool, supportsContrast: Bool,
         supportsMoireReduction: Bool, supportsHighlightRecovery: Bool, supportsLensCorrection: Bool,
         detailAmount: Float = 0, sharpnessAmount: Float = 0, contrastAmount: Float = 0, moireAmount: Float = 0) {
        self.defaultVersion = defaultVersion
        self.supportedVersions = supportedVersions
        self.effectiveVersion = effectiveVersion
        self.supportsLuminanceNoiseReduction = supportsLuminanceNoiseReduction
        self.supportsColorNoiseReduction = supportsColorNoiseReduction
        self.supportsDetail = supportsDetail
        self.supportsSharpness = supportsSharpness
        self.supportsContrast = supportsContrast
        self.supportsMoireReduction = supportsMoireReduction
        self.supportsHighlightRecovery = supportsHighlightRecovery
        self.supportsLensCorrection = supportsLensCorrection
        self.detailAmount = detailAmount
        self.sharpnessAmount = sharpnessAmount
        self.contrastAmount = contrastAmount
        self.moireAmount = moireAmount
    }

    /// What the decoder does on its own at this version, which Raw Details' offsets are applied to.
    var baseline: RawDetailBaseline {
        RawDetailBaseline(detail: detailAmount, sharpness: sharpnessAmount,
                          contrast: contrastAmount, moire: moireAmount)
    }

    /// Whether any Raw Details control survives at this version. Under RAW 9 two of the four do, so the
    /// group stays usable rather than disappearing.
    var offersAnyRawDetail: Bool {
        supportsDetail || supportsSharpness || supportsContrast || supportsMoireReduction
    }

    /// Whether this version is RAW 9, however the file spells it.
    var isRaw9: Bool { RawDecoderChoice.raw9EffectiveVersions.contains(effectiveVersion) }
}

/// Why a decoder choice could not be honoured on this host, or that it could.
nonisolated enum RawDecoderAvailability: Equatable, Sendable {
    case available
    /// The file does not offer the version.
    case notOffered(String)
    /// The version was requested and the filter kept another one.
    case ignored(String)
    /// The file could not be read at all here.
    case unreadable

    var isAvailable: Bool { self == .available }
}

nonisolated enum RawDecoderError: Error, Equatable, LocalizedError {
    case notOffered(String)
    case ignored(String)

    var errorDescription: String? {
        switch self {
        case .notOffered(let reason): return reason
        case .ignored(let reason): return reason
        }
    }
}

/// The one place these explanations are worded, so the two RAW sheets cannot drift apart.
nonisolated enum RawDecoderCopy {
    /// Why a control is unavailable under the selected decoder, naming the decoder so the reason is actionable.
    static func unavailable(_ control: String, decoder: String = RawDecoderChoice.appleRAW9.label) -> String {
        "\(decoder) does not offer \(control) on this file. Switching back to "
            + "\(RawDecoderChoice.systemDefault.label) restores it, with any amount you had set."
    }

    /// That a value is being kept while the selected decoder cannot use it.
    static func retained(_ control: String, value: Float) -> String {
        String(format: "%@ is set to %.2f and kept. ", control, value)
            + "\(RawDecoderChoice.appleRAW9.label) cannot use it; switch to \(RawDecoderChoice.systemDefault.label) to apply it again."
    }
}