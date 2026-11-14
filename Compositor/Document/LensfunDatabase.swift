import Foundation

/// One entry from a Lensfun XML database. Only what the panel needs to describe a match is kept: the maker, model,
/// mounts, crop factor, the focal and aperture ranges, and which calibrations the entry actually carries.
nonisolated struct LensfunCamera: Equatable, Sendable {
    var maker = ""
    var model = ""
    var mount = ""
    var cropFactor = 0.0

    /// Lensfun's own identity for this camera: maker and model, as written in the file.
    var id: String { "\(maker)|\(model)" }
    var description: String { [maker, model].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// Which of the three corrections a profile's calibration block actually contains. A lens can carry one, two or all
/// three; the panel must not promise one it lacks.
nonisolated struct LensfunCalibrations: Equatable, Sendable {
    var distortion = false
    /// Vignetting needs focal length, aperture and focus distance together, so it is reported separately.
    var vignetting = false
    var tca = false

    var any: Bool { distortion || vignetting || tca }

    /// The names to show, in the order the panel lists them.
    var names: [String] {
        var result: [String] = []
        if distortion { result.append("Distortion") }
        if vignetting { result.append("Vignetting") }
        if tca { result.append("Lateral chromatic aberration") }
        return result
    }
}

/// A vignetting sample's position in the profile's own calibration grid.
nonisolated struct LensfunVignettePoint: Equatable, Sendable {
    var focal: Double
    var aperture: Double
}

/// A lens entry, with the calibration coverage the panel reports.
nonisolated struct LensfunLens: Equatable, Sendable {
    var maker = ""
    var model = ""
    var mounts: [String] = []
    var cropFactor = 0.0
    /// The lens's own focal range in mm. `focalMin == focalMax` for a prime; both zero when the file omits it.
    var focalMin = 0.0
    var focalMax = 0.0
    /// The lens's aperture range as f-numbers. Both zero when the file omits it.
    var apertureMin = 0.0
    var apertureMax = 0.0
    /// The focal lengths the distortion and TCA samples were measured at.
    var calibratedFocals: [Double] = []
    /// The focal lengths and apertures the vignetting samples were measured at.
    var vignettePoints: [LensfunVignettePoint] = []
    var calibrations = LensfunCalibrations()

    var id: String { "\(maker)|\(model)|\(mounts.joined(separator: "+"))" }
    var description: String { [maker, model].filter { !$0.isEmpty }.joined(separator: " ") }

    /// Whether this lens covers `focal` in mm. A lens with no focal range in the file accepts any value, since
    /// nothing there contradicts the photograph.
    func covers(focal: Double) -> Bool {
        guard focalMin > 0 || focalMax > 0 else { return true }
        let low = focalMin > 0 ? focalMin : focalMax
        let high = focalMax > 0 ? focalMax : focalMin
        // A little slack for the rounded focal length cameras record.
        return focal >= low - 0.6 && focal <= high + 0.6
    }

    /// Whether a distortion or TCA sample exists at or beside `focal`.
    func calibratesDistortion(at focal: Double) -> Bool {
        guard calibrations.distortion || calibrations.tca else { return false }
        guard !calibratedFocals.isEmpty else { return true }
        return calibratedFocals.contains { abs($0 - focal) <= max(1, focal * 0.12) }
    }

    /// Whether a vignetting sample exists at or beside this focal length and aperture. Vignetting depends on both,
    /// so a profile with samples at other apertures does not claim to correct this one.
    func calibratesVignetting(at focal: Double, aperture: Double) -> Bool {
        guard calibrations.vignetting, !vignettePoints.isEmpty else { return false }
        return vignettePoints.contains { point in
            let focalClose = abs(point.focal - focal) <= max(1, focal * 0.12)
            let apertureClose = aperture <= 0 || abs(point.aperture - aperture) <= max(0.4, aperture * 0.25)
            return focalClose && apertureClose
        }
    }

    /// The calibrations that genuinely cover this shot, which is what the panel may promise.
    func calibrations(coveringFocal focal: Double, aperture: Double) -> LensfunCalibrations {
        LensfunCalibrations(
            distortion: calibrations.distortion && calibratesDistortion(at: focal),
            vignetting: calibratesVignetting(at: focal, aperture: aperture),
            tca: calibrations.tca && calibratesDistortion(at: focal)
        )
    }
}

/// Why an automatic match could not settle on one lens. The panel turns each of these into its own sentence.
nonisolated enum LensfunMatchIssue: Equatable, Sendable {
    /// The file had no camera or lens tags to look up.
    case noMetadata
    /// A lens name was read, but no database entry corresponds to it.
    case lensNotInDatabase(String)
    /// The lens exists, but only for mounts this camera does not take.
    case mountMismatch(String)
    /// The lens exists, but its focal range does not include the shot's.
    case focalMismatch(String)
    /// More than one entry fits equally well, so the user must choose.
    case ambiguous([String])
}

/// The outcome of matching the photograph against the database. `lens` is set only when the answer is unambiguous.
nonisolated struct LensfunMatch: Equatable, Sendable {
    var camera: LensfunCamera?
    var lens: LensfunLens?
    var issue: LensfunMatchIssue?
    /// Every entry that fits, best first, so manual selection can offer exactly the plausible ones.
    var candidates: [LensfunLens] = []

    var isConfident: Bool { lens != nil && issue == nil }
}

/// A parsed Lensfun database: mounts, cameras and lenses, and the matching rules over them.
nonisolated struct LensfunDatabase: Equatable, Sendable {
    var mounts: [String: [String]] = [:]  // mount → compatible mounts
    var cameras: [LensfunCamera] = []
    var lenses: [LensfunLens] = []
    /// The `version` attribute the files declared. Lensfun's own format version, not the database's date.
    var formatVersion = 0
    /// How many XML files contributed, for the panel's status line.
    var fileCount = 0

    var isEmpty: Bool { cameras.isEmpty && lenses.isEmpty }

    /// Parses one XML document. Returns nil when it is not a Lensfun database at all, so a stray file is refused
    /// rather than silently contributing nothing.
    static func parse(_ data: Data, fileCount: Int = 1) throws -> LensfunDatabase {
        let parser = LensfunXMLParser(data: data)
        var database = try parser.parse()
        database.fileCount = fileCount
        return database
    }

    // MARK: - Name normalization

    /// The words of a camera or lens name, for comparing two spellings of the same thing. Lensfun splits a name into
    /// runs of one character type — letters, digits, or punctuation — then drops punctuation-only words and the single
    /// word "f". That makes "f/2.8L" and "f2.8l" the same sequence, and "24-70mm" and "24 70 mm" the same too.
    static func words(_ name: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentKind: CharacterKind?
        for character in name.lowercased() {
            guard let kind = CharacterKind(character) else {
                // Whitespace ends the current word; the next character starts a new one.
                if !current.isEmpty { result.append(current) }
                current = ""
                currentKind = nil
                continue
            }
            if kind == currentKind {
                current.append(character)
            } else {
                if !current.isEmpty { result.append(current) }
                current = String(character)
                currentKind = kind
            }
        }
        if !current.isEmpty { result.append(current) }
        // A punctuation-only word carries no meaning, and a lone "f" is the aperture prefix Lensfun ignores.
        return result.filter { word in
            word != "f" && word.contains { $0.isLetter || $0.isNumber }
        }
    }

    /// The three kinds of character Lensfun distinguishes when it splits a name into words.
    private enum CharacterKind: Equatable {
        case letter, digit, punctuation

        init?(_ character: Character) {
            if character.isWhitespace { return nil }
            if character.isLetter { self = .letter }
            else if character.isNumber { self = .digit }
            else { self = .punctuation }
        }
    }

    /// Whether two names are the same once case, word order and punctuation are set aside. Conservative: a missing
    /// word on either side means they differ.
    static func sameName(_ a: String, _ b: String) -> Bool {
        let left = words(a).sorted(), right = words(b).sorted()
        return !left.isEmpty && left == right
    }

    /// Whether one name contains the other's every word, for a camera recorded as "ILCE-7M3" against a database
    /// entry "Sony ILCE-7M3". Still requires all of the shorter name's words, so it does not merge unrelated models.
    static func containsName(_ longer: String, _ shorter: String) -> Bool {
        let long = Set(words(longer)), short = words(shorter)
        return !short.isEmpty && short.allSatisfy { long.contains($0) }
    }

    // MARK: - Lookup

    /// The cameras that could be the one in the photograph, best first. An exact model match wins; otherwise a name
    /// whose words are all present is considered, which is how "ILCE-7M3" finds "Sony ILCE-7M3".
    func cameras(matching metadata: LensMetadata) -> [LensfunCamera] {
        guard !metadata.cameraModel.isEmpty || !metadata.cameraMake.isEmpty else { return [] }
        let exact = cameras.filter { Self.sameName($0.model, metadata.cameraModel) }
        if !exact.isEmpty { return exact }
        let loose = cameras.filter {
            Self.containsName($0.model, metadata.cameraModel) || Self.containsName(metadata.cameraModel, $0.model)
        }
        return loose
    }

    /// The lenses whose name matches the photograph's, ignoring mount and focal range. Used both for the automatic
    /// match and to explain why one failed.
    func lenses(matching metadata: LensMetadata) -> [LensfunLens] {
        let name = metadata.lensModel.isEmpty ? metadata.lensMake : metadata.lensModel
        guard !name.isEmpty else { return [] }
        let exact = lenses.filter { Self.sameName($0.model, name) }
        if !exact.isEmpty { return exact }
        return lenses.filter { Self.containsName($0.model, name) || Self.containsName(name, $0.model) }
    }

    /// Whether `camera` takes `lens`, directly or through a declared compatible mount.
    func mountMatches(_ camera: LensfunCamera, _ lens: LensfunLens) -> Bool {
        let cameraMount = camera.mount.lowercased()
        guard !cameraMount.isEmpty, !lens.mounts.isEmpty else { return true }
        for mount in lens.mounts {
            let lensMount = mount.lowercased()
            if lensMount == cameraMount { return true }
            // A declared compatibility runs both ways: an M42 lens fits a Pentax K body and the reverse. Mount names
            // are compared without case, since the file's spelling need not match the camera entry's.
            if compatibles(cameraMount).contains(lensMount) { return true }
            if compatibles(lensMount).contains(cameraMount) { return true }
        }
        return false
    }

    /// The mounts declared compatible with `mount`, compared without case.
    private func compatibles(_ mount: String) -> Set<String> {
        var result: Set<String> = []
        for (name, compatible) in mounts where name.lowercased() == mount {
            result.formUnion(compatible.map { $0.lowercased() })
        }
        return result
    }

    /// The single best entry, or the reason there is none. Ambiguity is never resolved by picking the first entry.
    func match(_ metadata: LensMetadata) -> LensfunMatch {
        guard !metadata.isEmpty else { return LensfunMatch(issue: .noMetadata) }
        let camera = cameras(matching: metadata).first
        let named = lenses(matching: metadata)
        let lensName = metadata.lensModel.isEmpty ? metadata.lensMake : metadata.lensModel

        guard !named.isEmpty else {
            return LensfunMatch(camera: camera, issue: .lensNotInDatabase(lensName))
        }
        // Mount, then focal range: both are hard constraints, so a lens that fails either is not a candidate.
        let mounted = camera.map { camera in named.filter { mountMatches(camera, $0) } } ?? named
        guard !mounted.isEmpty else {
            return LensfunMatch(camera: camera, issue: .mountMismatch(lensName), candidates: named)
        }
        let fitted = metadata.focalLengthMm > 0 ? mounted.filter { $0.covers(focal: metadata.focalLengthMm) } : mounted
        guard !fitted.isEmpty else {
            return LensfunMatch(camera: camera, issue: .focalMismatch(lensName), candidates: mounted)
        }
        guard fitted.count == 1 else {
            // Two entries for one name are usually two mounts or two revisions: the photograph alone cannot say
            // which, so the user picks.
            return LensfunMatch(camera: camera, issue: .ambiguous(fitted.map(\.description)), candidates: fitted)
        }
        return LensfunMatch(camera: camera, lens: fitted[0], candidates: fitted)
    }

    /// The entry a manual choice names, if it is still in the database. A database update can remove a lens; the
    /// caller then reports it as missing rather than silently substituting another.
    func lens(id: String) -> LensfunLens? {
        lenses.first { $0.id == id }
    }

    func camera(id: String) -> LensfunCamera? {
        cameras.first { $0.id == id }
    }

    /// The camera a manual lens choice should be measured against: the one the user's metadata names, or the first
    /// entry the lens fits.
    func camera(forLens lens: LensfunLens, metadata: LensMetadata) -> LensfunCamera? {
        let named = cameras(matching: metadata)
        if let fit = named.first(where: { mountMatches($0, lens) }) { return fit }
        return cameras.first { mountMatches($0, lens) }
    }
}
