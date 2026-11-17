import Foundation
import ImageIO

/// Where a lens correction comes from. Apple's is built into every RAW the system can decode; Lensfun is an
/// optional, user-installed database of camera-specific measurements; Off leaves both alone while manual and
/// creative adjustments keep working.
///
/// Apple Native is the default and preserves every project made before this existed. Lensfun never has to be
/// installed: without it the app behaves exactly as it always has.
nonisolated enum CameraRawLensProfileProvider: String, CaseIterable, Identifiable, Sendable {
    case appleNative = "Apple Native"
    case lensfun = "Lensfun"
    case off = "Off"

    var id: String { rawValue }

    /// What the provider is, in the panel's own words, so the choice is never a bare menu label.
    var summary: String {
        switch self {
        case .appleNative:
            return "Apple's own lens correction, from the profile inside the RAW file. Available without anything extra."
        case .lensfun:
            return "Camera-specific measurements from the optional Lensfun database. Needs an explicit install or import."
        case .off:
            return "No automatic profile correction. Manual Distortion, Defringe, Vignetting and Lens Blur still apply."
        }
    }
}

/// Camera and lens as the file recorded them, normalized only as far as reading them safely. Empty strings mean
/// the file carried no such tag; nothing is guessed.
nonisolated struct LensMetadata: Equatable, Sendable {
    var cameraMake = ""
    var cameraModel = ""
    var lensMake = ""
    var lensModel = ""
    /// As-shot focal length in mm. Zero when the file has no tag.
    var focalLengthMm = 0.0
    /// As-shot f-number. Zero when the file has no tag.
    var aperture = 0.0
    /// Whether any of the above came from the file at all.
    var hasMetadata = false

    var isEmpty: Bool { !hasMetadata }

    /// The camera as one line for the panel, or nil when the file said nothing.
    var cameraDescription: String? {
        let parts = [cameraMake, cameraModel].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The lens as one line for the panel, or nil when the file said nothing.
    var lensDescription: String? {
        let name = lensModel.isEmpty ? lensMake : lensModel
        return name.isEmpty ? nil : name
    }
}

/// Which matched profile is in use. Automatic takes the single unambiguous match; Manual pins one the user picked,
/// so a later database update cannot quietly swap the lens under a photograph.
nonisolated struct CameraRawLensProfileSelection: Equatable, Sendable {
    var automatic = true
    /// Lensfun's stable identity for the chosen lens: maker, model and mounts, joined.
    var lensID = ""
    /// The camera entry the match was made against, so the panel can say which body the crop factor came from.
    var cameraID = ""

    var isManual: Bool { !automatic }
    var hasChoice: Bool { !lensID.isEmpty }

    var normalized: Self {
        var result = self
        if automatic {
            // An automatic selection keeps no pinned identity: the next match decides.
            result.lensID = ""
            result.cameraID = ""
        }
        return result
    }
}

/// Optics › Lens Profile: which provider is in charge and which profile, if any, was matched. Everything here is
/// additive; with the default provider nothing about the render changes.
nonisolated struct CameraRawLensProfileSettings: Equatable, Sendable {
    var provider: CameraRawLensProfileProvider = .appleNative
    var selection = CameraRawLensProfileSelection()
    /// The installed database's digest when this provider and selection were committed. Recorded, never
    /// gating: rendering is a pure function of the current database, and a difference is reported, not silent.
    var calibrationDigest = ""

    /// Whether this changes the picture at all. The provider alone does not decide: Lensfun only
    /// corrects pixels once a database is installed and a profile has been chosen, which the render
    /// path resolves against the photograph's metadata before it trusts the answer.
    var adjustsPixels: Bool {
        switch provider {
        case .off: return false
        case .appleNative: return false // Apple's correction lives in the decoder, not in this pass.
        case .lensfun: return selection.hasChoice
        }
    }

    /// Whether the settings differ from a brand-new image's, for the section's reset and eye.
    var isDefault: Bool { self == CameraRawLensProfileSettings() }

    var normalized: Self {
        var result = self
        result.selection = selection.normalized
        return result
    }
}

// MARK: - Correction policy

/// Why a correction is or is not applied, so Apple and Lensfun can never bend the same distortion twice.
///
/// The three sources are not interchangeable. A RAW that Compositor can redevelop gets its lens correction from the
/// decoder, and that switch can be turned off. A RAW that was already developed into pixels cannot have the
/// correction taken back out. A JPEG or TIFF may already carry the camera's own correction, which nothing here can
/// distinguish from an uncorrected frame.
nonisolated struct CameraRawLensCorrectionPolicy: Equatable, Sendable {
    /// What the layer's pixels actually are, as far as lens correction is concerned.
    enum Source: String, Sendable {
        /// RAW bytes are still held, so the decoder can be run again with its lens correction off.
        case redevelopableRaw
        /// A RAW that was developed and baked; the decoder's correction, if any, is already in the pixels.
        case previouslyDevelopedRaw
        /// JPEG, TIFF, PNG or anything else a camera may have corrected before it was written.
        case renderedImage
    }

    var source: Source
    var provider: CameraRawLensProfileProvider
    /// Whether the decoder's own correction is in the pixels right now.
    var appleCorrectionActive: Bool
    /// Whether the generic and manual Optics controls are doing anything.
    var manualAdjustmentsActive: Bool

    /// Calibrated Lensfun pixel correction does not exist yet. It is reported rather than assumed, so the panel can
    /// say plainly that a match only describes what a profile could do.
    /// Calibrated Lensfun pixel correction exists: the engine in CameraRawLensfun applies the poly3,
    /// poly5 and ptlens distortion models, linear and poly3 lateral chromatic aberration, and the pa
    /// vignetting model, from a user-imported database.
    static let calibratedCorrectionAvailable = true

    /// Whether Lensfun may correct these pixels without risking a double correction. Only a RAW whose
    /// bytes are still held qualifies, and only while the decoder's own correction is out of the pixels.
    var canApplyLensfunCorrection: Bool {
        source == .redevelopableRaw && !appleCorrectionActive && Self.calibratedCorrectionAvailable
    }

    /// The plain sentence the panel shows under the provider, describing what is actually happening.
    var explanation: String {
        switch provider {
        case .off:
            return manualAdjustmentsActive
                ? "Profile correction is off. Your manual Optics adjustments still apply."
                : "Profile correction is off. Nothing in Optics is changing the picture."
        case .appleNative:
            switch source {
            case .redevelopableRaw:
                return appleCorrectionActive
                    ? "Apple's lens correction is on in the RAW decoder. Turn it off there before using a Lensfun profile, so the distortion is not corrected twice."
                    : "Apple's lens correction is available in the RAW decoder but currently off."
            case .previouslyDevelopedRaw:
                return appleCorrectionActive
                    ? "This RAW was developed with Apple's lens correction baked into its pixels. It cannot be removed without redeveloping the original."
                    : "This RAW was developed without Apple's lens correction. Its pixels hold whatever distortion the lens had."
            case .renderedImage:
                return "This is not a RAW file. Any in-camera or developer lens correction is already in the pixels and cannot be separated from them."
            }
        case .lensfun:
            switch source {
            case .redevelopableRaw:
                return appleCorrectionActive
                    ? "Apple's lens correction is on in the RAW decoder. Turn it off there first, or the distortion would be corrected twice."
                    : "The matched profile's calibrated corrections are applied to the pixels."
            case .previouslyDevelopedRaw:
                return "Lensfun cannot correct this layer safely: the RAW was already developed, so any correction in its pixels is fixed. Redevelop the original first."
            case .renderedImage:
                return "Lensfun cannot correct this layer safely: a JPEG or TIFF may already carry the camera's own correction, and applying another would double it."
            }
        }
    }

    /// Whether the panel should show its "no calibrated correction yet" notice. The calibrated engine
    /// exists now; the panel reports per-correction status instead.
    var showsUnavailableNotice: Bool { false }
}

// MARK: - Reading camera and lens from a file

nonisolated extension LensMetadata {
    /// Reads camera, lens, focal length and aperture from ImageIO properties, which both RAW and ordinary images
    /// expose. Absent tags stay empty; nothing is derived or invented.
    init(imageProperties properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        func text(_ value: Any?) -> String {
            guard let value else { return "" }
            if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
            return ""
        }
        func number(_ value: Any?) -> Double {
            if let number = value as? NSNumber { return number.doubleValue }
            if let number = value as? Double { return number }
            if let number = value as? Float { return Double(number) }
            if let number = value as? Int { return Double(number) }
            return 0
        }

        cameraMake = text(tiff?[kCGImagePropertyTIFFMake])
        cameraModel = text(tiff?[kCGImagePropertyTIFFModel])
        lensMake = text(exif?[kCGImagePropertyExifLensMake])
        lensModel = text(exif?[kCGImagePropertyExifLensModel])
        focalLengthMm = number(exif?[kCGImagePropertyExifFocalLength])
        aperture = number(exif?[kCGImagePropertyExifFNumber])
        hasMetadata = !(cameraMake.isEmpty && cameraModel.isEmpty && lensMake.isEmpty && lensModel.isEmpty)
    }

    /// Reads the same fields from a RAW source's retained metadata, which stores the EXIF and TIFF dictionaries
    /// exactly as ImageIO handed them over at import.
    init(cameraMetadata: [String: Any]) {
        var properties: [CFString: Any] = [:]
        if let exif = cameraMetadata["Exif"] as? [CFString: Any] { properties[kCGImagePropertyExifDictionary] = exif }
        if let tiff = cameraMetadata["TIFF"] as? [CFString: Any] { properties[kCGImagePropertyTIFFDictionary] = tiff }
        self.init(imageProperties: properties)
    }
}
