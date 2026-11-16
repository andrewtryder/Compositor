import Foundation

/// A named, additive set of Camera Raw settings that can be applied to a layer without touching
/// anything the preset does not list. Each category is optional: a preset that omits a group leaves
/// that group's current values in place.
nonisolated struct CameraRawPreset: Equatable, Sendable, Identifiable {
    /// Stable identity so a renamed preset keeps its place in the list.
    let id: UUID
    /// The name shown in the panel.
    var name: String
    /// Which groups this preset carries values for. Everything else is left untouched on apply.
    var affects: Set<CameraRawGroup>
    /// A snapshot of the settings for the groups named in `affects`.
    var settings: CameraRawSettings
    /// When the preset was created, for the panel's sorting.
    var created: Date = Date()

    init(name: String, affects: Set<CameraRawGroup>, settings: CameraRawSettings, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.affects = affects
        self.settings = settings
    }

    /// Whether this preset changes anything at all.
    var isEmpty: Bool { affects.isEmpty || settings.isIdentity }

    /// The groups this preset carries, in the panel's fixed order.
    var groupsInOrder: [CameraRawGroup] { CameraRawGroup.panelOrder.filter { affects.contains($0) } }
}

/// Errors a preset can throw while reading or writing.
enum CameraRawPresetError: Error, Equatable, LocalizedError, Sendable {
    case missingName
    case duplicateName(String)
    case notFound(UUID)
    case corruptedFile(String)
    case missingFields
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .missingName: return "A preset needs a name."
        case .duplicateName(let n): return "A preset named “\(n)” already exists."
        case .notFound(let id): return "The preset no longer exists."
        case .corruptedFile(let reason): return "That preset file is not readable: \(reason)."
        case .missingFields: return "That preset is missing settings."
        case .unsupportedVersion: return "That preset was made by a newer version of Compositor."
        }
    }
}

/// The current preset-file format version. Bump this when the persisted shape changes.
let CameraRawPresetFormatVersion = 1

/// A preset as written to disk: self-describing so a missing or future version is handled explicitly.
struct CameraRawPresetFile: Codable, Equatable, Sendable {
    var version: Int = CameraRawPresetFormatVersion
    var name: String = ""
    var affects: [String] = []
    /// The versioned on-disk mirror of CameraRawSettings, since the live model is not Codable.
    var settings: CameraRawSettingsPersistentState
    var created: Date = Date()

    init(preset: CameraRawPreset) {
        version = CameraRawPresetFormatVersion
        name = preset.name
        affects = preset.affects.map { $0.rawValue }
        settings = CameraRawSettingsPersistentState(preset.settings)
        created = preset.created
    }

    init(version: Int = CameraRawPresetFormatVersion, name: String = "", affects: [String] = [],
         settings: CameraRawSettingsPersistentState, created: Date = Date()) {
        self.version = version
        self.name = name
        self.affects = affects
        self.settings = settings
        self.created = created
    }
}

/// Manages the person's presets: saving, applying, renaming, deleting, duplicating, import/export.
final class CameraRawPresets: @unchecked Sendable {
    /// The folder presets live in, next to Application Support.
    static let folder: URL = {
        let base: URL
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = support
        } else {
            base = FileManager.default.temporaryDirectory
        }
        return base.appendingPathComponent("Compositor/Camera Raw Presets", isDirectory: true)
    }()

    private let lock = NSLock()
    private var presets: [CameraRawPreset] = []

    /// All presets, newest first.
    var all: [CameraRawPreset] {
        lock.lock(); defer { lock.unlock() }
        return presets.sorted { $0.created > $1.created }
    }

    init() { reload() }

    /// Re-read the preset folder. Safe to call after an import adds files from outside.
    func reload() {
        lock.lock(); defer { lock.unlock() }
        let files: [URL]
        if let listed = try? FileManager.default.contentsOfDirectory(at: Self.folder,
                                                                     includingPropertiesForKeys: nil) {
            files = listed
        } else {
            files = []
        }
        presets = files.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(CameraRawPresetFile.self, from: data) else { return nil }
            guard file.version == CameraRawPresetFormatVersion else { return nil }
            guard !file.name.isEmpty else { return nil }
            let affects = Set(file.affects.compactMap { CameraRawGroup(rawValue: $0) })
            let settings = (try? file.settings.makeSettings()) ?? CameraRawSettings()
            return CameraRawPreset(name: file.name,
                                   affects: affects,
                                   settings: settings,
                                   id: UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID())
        }
    }

    /// Saves the current Camera Raw settings as a new preset, choosing which groups it affects.
    /// Throws if a preset with the same name already exists.
    func save(name: String, affects: Set<CameraRawGroup>, settings: CameraRawSettings) throws -> CameraRawPreset {
        lock.lock(); defer { lock.unlock() }
        guard !name.isEmpty else { throw CameraRawPresetError.missingName }
        guard !presets.contains(where: { $0.name == name }) else { throw CameraRawPresetError.duplicateName(name) }
        let preset = CameraRawPreset(name: name, affects: affects, settings: settings)
        presets.append(preset)
        try? write(preset)
        return preset
    }

    /// Applies `preset` onto `settings`, replacing only the groups the preset carries.
    /// Returns the updated settings. Undoable at the caller.
    func apply(_ preset: CameraRawPreset, to settings: inout CameraRawSettings) {
        for group in preset.groupsInOrder {
            CameraRawSettings.copy(group, from: preset.settings, to: &settings)
        }
    }

    /// Renames a preset. Throws if another preset already has that name.
    func rename(_ id: UUID, to name: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !name.isEmpty else { throw CameraRawPresetError.missingName }
        guard !presets.contains(where: { $0.id != id && $0.name == name }) else {
            throw CameraRawPresetError.duplicateName(name)
        }
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            throw CameraRawPresetError.notFound(id)
        }
        presets[index].name = name
        try? write(presets[index])
    }

    /// Deletes a preset.
    func delete(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            throw CameraRawPresetError.notFound(id)
        }
        presets.remove(at: index)
        let fileURL = Self.folder.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Returns a copy of `preset` with a new name.
    func duplicate(_ id: UUID, named name: String) throws -> CameraRawPreset {
        lock.lock(); defer { lock.unlock() }
        guard let base = presets.first(where: { $0.id == id }) else {
            throw CameraRawPresetError.notFound(id)
        }
        let copy = CameraRawPreset(name: name, affects: base.affects, settings: base.settings)
        presets.append(copy)
        try? write(copy)
        return copy
    }

    /// Writes `preset` to its JSON file in the presets folder.
    private func write(_ preset: CameraRawPreset) throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let file = CameraRawPresetFile(preset: preset)
        let data = try JSONEncoder().encode(file)
        let url = Self.folder.appendingPathComponent("\(preset.id.uuidString).json")
        try data.write(to: url)
    }

    /// Exports `preset` to a `.compositorpreset` file at `url`.
    func export(_ preset: CameraRawPreset, to url: URL) throws {
        let file = CameraRawPresetFile(preset: preset)
        let data = try JSONEncoder().encode(file)
        try data.write(to: url)
    }

    /// Imports a preset file from `url`, returning the new preset. Throws on corrupted or future-version files.
    func importPreset(from url: URL) throws -> CameraRawPreset {
        let data = try Data(contentsOf: url)
        guard let file = try? JSONDecoder().decode(CameraRawPresetFile.self, from: data) else {
            throw CameraRawPresetError.corruptedFile("not a valid preset file")
        }
        guard file.version == CameraRawPresetFormatVersion else {
            throw CameraRawPresetError.unsupportedVersion
        }
        guard !file.name.isEmpty else { throw CameraRawPresetError.missingFields }
        let affects = Set(file.affects.compactMap { CameraRawGroup(rawValue: $0) })
        let settings = try file.settings.makeSettings()
        let preset = CameraRawPreset(name: file.name, affects: affects, settings: settings)
        try save(name: preset.name, affects: affects, settings: settings)
        return preset
    }
}
