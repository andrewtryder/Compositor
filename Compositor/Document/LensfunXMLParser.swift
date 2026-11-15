import Foundation

/// Reads a Lensfun XML database. It is deliberately strict about structure and permissive about content: a file that
/// is not a `<lensdatabase>` is refused, while an entry with a missing optional tag is accepted with that field left
/// empty. A malformed file throws, so the caller can refuse the whole import rather than half-loading it.
nonisolated final class LensfunXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var database = LensfunDatabase()
    private var error: Error?
    /// The open elements, outermost first: `<lensdatabase>`, then `<lens>`, then `<calibration>`. `<mount>` means a
    /// mount declaration at the top level and a lens's own mount inside `<lens>`, so the path decides which.
    private var path: [String] = []
    private var text = ""

    private var currentMount: String?
    private var currentMountCompat: [String] = []
    private var currentCamera: LensfunCamera?
    private var currentLens: LensfunLens?
    private var currentCalibration = LensfunCalibrations()
    private var currentCalibratedFocals: [Double] = []
    private var currentVignettePoints: [LensfunVignettePoint] = []
    private var currentDistortions: [LensfunDistortion] = []
    private var currentTCAs: [LensfunTCA] = []
    private var currentVignettings: [LensfunVignetting] = []
    /// The attributes of the element most recently started, so a translated variant (`<model lang="en">`)
    /// can be told from the primary name, which is what matching goes by.
    private var currentAttributes: [String: String] = [:]

    /// The format versions this reader understands. Lensfun 0.3 and later write 1; 2 adds the `acm` models but no
    /// structure this reader depends on. Version 0 predates the tags used here and is refused rather than guessed at.
    static let supportedFormats: ClosedRange<Int> = 1...2
    /// A database bigger than this is refused before parsing: the shipped one is about 4 MB.
    static let maximumBytes = 64 * 1_000_000

    init(data: Data) {
        self.data = data
        super.init()
    }

    func parse() throws -> LensfunDatabase {
        guard data.count <= Self.maximumBytes else { throw LensfunDatabaseError.tooLarge(Self.maximumBytes) }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw LensfunDatabaseError.malformed(parser.parserError?.localizedDescription ?? "unreadable XML")
        }
        if let error { throw error }
        guard Self.supportedFormats.contains(database.formatVersion) else {
            throw LensfunDatabaseError.unsupportedFormat(database.formatVersion)
        }
        guard !database.isEmpty else { throw LensfunDatabaseError.notADatabase }
        return database
    }

    private var insideLens: Bool { path.contains("lens") }
    private var insideCamera: Bool { path.contains("camera") }
    private var insideMount: Bool { path.last == "mount" && !insideLens }
    private var insideCalibration: Bool { path.contains("calibration") }

    // MARK: - Delegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        currentAttributes = attributes
        switch elementName {
        case "lensdatabase":
            path.append("lensdatabase")
            database.formatVersion = Int(attributes["version"] ?? "0") ?? 0
        case "mount":
            path.append("mount")
            if !insideLens {
                currentMount = nil
                currentMountCompat = []
            }
        case "camera":
            path.append("camera")
            currentCamera = LensfunCamera()
        case "lens":
            path.append("lens")
            currentLens = LensfunLens()
        case "calibration":
            path.append("calibration")
            currentCalibration = LensfunCalibrations()
            currentCalibratedFocals = []
            currentVignettePoints = []
            currentDistortions = []
            currentTCAs = []
            currentVignettings = []
        case "distortion":
            guard insideCalibration, let model = attributes["model"], model != "none" else { return }
            currentCalibration.distortion = true
            if let focal = Self.number(attributes["focal"]) { currentCalibratedFocals.append(focal) }
            // The measured coefficients are kept, not just the fact of them, so the calibrated engine can use
            // them. An unknown or absent model is recorded as unsupported rather than guessed at.
            if let distortion = LensfunDistortion(attributes: attributes, number: Self.number) {
                currentDistortions.append(distortion)
            } else {
                currentCalibration.hasUnsupportedDistortion = true
            }
        case "tca":
            guard insideCalibration, let model = attributes["model"], model != "none" else { return }
            currentCalibration.tca = true
            if let focal = Self.number(attributes["focal"]) { currentCalibratedFocals.append(focal) }
            if let tca = LensfunTCA(attributes: attributes, number: Self.number) {
                currentTCAs.append(tca)
            } else {
                currentCalibration.hasUnsupportedTCA = true
            }
        case "vignetting":
            guard insideCalibration, let model = attributes["model"], model != "none" else { return }
            currentCalibration.vignetting = true
            if let focal = Self.number(attributes["focal"]), let aperture = Self.number(attributes["aperture"]) {
                currentVignettePoints.append(LensfunVignettePoint(focal: focal, aperture: aperture))
            }
            if let vignetting = LensfunVignetting(attributes: attributes, number: Self.number) {
                currentVignettings.append(vignetting)
            } else {
                currentCalibration.hasUnsupportedVignetting = true
            }
        case "center":
            guard insideLens, var lens = currentLens else { return }
            lens.center.x = Self.number(attributes["x"]) ?? 0
            lens.center.y = Self.number(attributes["y"]) ?? 0
            currentLens = lens
        case "focal":
            guard insideLens, var lens = currentLens else { return }
            if let value = Self.number(attributes["value"]) {
                lens.focalMin = value
                lens.focalMax = value
            } else {
                if let min = Self.number(attributes["min"]) { lens.focalMin = min }
                if let max = Self.number(attributes["max"]) { lens.focalMax = max }
            }
            currentLens = lens
        case "aperture":
            guard insideLens, var lens = currentLens else { return }
            if let value = Self.number(attributes["value"]) {
                lens.apertureMin = value
                lens.apertureMax = value
            } else {
                if let min = Self.number(attributes["min"]) { lens.apertureMin = min }
                if let max = Self.number(attributes["max"]) { lens.apertureMax = max }
            }
            currentLens = lens
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        // Resolve which element this is before the path is popped, since `<mount>` depends on its parent.
        switch elementName {
        case "mount":
            if insideLens {
                if !value.isEmpty { currentLens?.mounts.append(value) }
            } else if insideCamera {
                // A camera names its mount as the element's text; a top-level `<mount>` names it in `<name>`.
                if !value.isEmpty { currentCamera?.mount = value }
            } else if let mount = currentMount, !mount.isEmpty {
                database.mounts[mount] = currentMountCompat
                currentMount = nil
                currentMountCompat = []
            }
        case "camera":
            if let camera = currentCamera, !camera.model.isEmpty { database.cameras.append(camera) }
            currentCamera = nil
        case "lens":
            if var lens = currentLens, !lens.model.isEmpty {
                lens.calibrations = currentCalibration
                lens.calibratedFocals = currentCalibratedFocals
                lens.vignettePoints = currentVignettePoints
                lens.distortions = currentDistortions
                lens.tcas = currentTCAs
                lens.vignettings = currentVignettings
                database.lenses.append(lens)
            }
            currentLens = nil
        case "name":
            if insideMount { currentMount = value }
        case "compat":
            if insideMount { currentMountCompat.append(value) }
        case "maker":
            if insideCamera { currentCamera?.maker = value }
            else if insideLens { currentLens?.maker = value }
        case "model":
            // A translated variant carries a lang attribute; only the untranslated name is the identity
            // the photograph's metadata is matched against, so a variant never overwrites it.
            if insideCamera {
                if currentAttributes["lang"] == nil { currentCamera?.model = value }
            } else if insideLens {
                if currentAttributes["lang"] == nil { currentLens?.model = value }
            }
        case "cropfactor":
            if let number = Self.number(value) {
                if insideCamera { currentCamera?.cropFactor = number }
                else if insideLens { currentLens?.cropFactor = number }
            }
        default:
            break
        }
        if path.last == elementName { path.removeLast() }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = LensfunDatabaseError.malformed(parseError.localizedDescription)
    }

    /// A number from an attribute or an element's text, or nil when it is not one.
    private static func number(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        return Double(value.trimmingCharacters(in: .whitespaces))
    }
}

/// What can go wrong reading a database. Each case becomes a sentence in the panel.
nonisolated enum LensfunDatabaseError: Error, Equatable, LocalizedError {
    case malformed(String)
    case notADatabase
    case unsupportedFormat(Int)
    case tooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .malformed(let reason):
            return "The Lensfun database could not be read (\(reason)). It may be damaged or not Lensfun XML."
        case .notADatabase:
            return "That file is not a Lensfun database: it has no lens entries."
        case .unsupportedFormat(let version):
            return "That database uses Lensfun format \(version), which this build does not read."
        case .tooLarge(let bytes):
            return "That database is larger than \(bytes / 1_000_000) MB and was not loaded."
        }
    }
}
