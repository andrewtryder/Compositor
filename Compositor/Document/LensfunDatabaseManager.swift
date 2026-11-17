import CryptoKit
import Foundation
import Observation

/// The installed Lensfun database: which files are on disk, what they say, and how to put them there.
///
/// Nothing is downloaded automatically and no third-party binary is ever loaded. A database is XML, imported only
/// when the user picks a file, and parsed with the app's own reader. The store is a folder in Application Support;
/// removing it returns the app to exactly the state it had before Lensfun was mentioned.
nonisolated struct LensfunDatabaseStore: Sendable {
    /// Where imported databases live. One folder, so "is it installed" is a question about one directory.
    let directory: URL

    static var `default`: LensfunDatabaseStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return LensfunDatabaseStore(directory: base.appendingPathComponent("Compositor/Lensfun Database", isDirectory: true))
    }

    /// The XML files currently installed, sorted for a stable digest.
    var xmlFiles: [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "xml" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    var isInstalled: Bool { !xmlFiles.isEmpty }

    /// The database's own date, from the `timestamp.txt` Lensfun's updater writes beside the XML. Nil when the
    /// user imported loose files, which carry no such date.
    var timestamp: Date? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("timestamp.txt"), encoding: .utf8),
              let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Loads and validates everything installed. Throws if any file is unreadable, so a half-broken install is
    /// reported rather than half-used.
    func load() throws -> LensfunDatabase {
        let files = xmlFiles
        guard !files.isEmpty else { throw LensfunDatabaseError.notADatabase }
        var merged = LensfunDatabase()
        for file in files {
            let data = try Data(contentsOf: file)
            let parsed = try LensfunDatabase.parse(data)
            merged.formatVersion = max(merged.formatVersion, parsed.formatVersion)
            merged.cameras.append(contentsOf: parsed.cameras)
            merged.lenses.append(contentsOf: parsed.lenses)
            for (mount, compatible) in parsed.mounts { merged.mounts[mount] = compatible }
        }
        merged.fileCount = files.count
        guard !merged.isEmpty else { throw LensfunDatabaseError.notADatabase }
        return merged
    }

    /// A fingerprint of the installed files, so the panel can show that what it read is what is on disk.
    func digest() -> String {
        var hasher = SHA256()
        for file in xmlFiles {
            hasher.update(data: (try? Data(contentsOf: file)) ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Installs the XML in `sources`, which may be files or folders. Everything is validated before anything is
    /// written, so a bad file leaves the previous database in place.
    @discardableResult
    func install(from sources: [URL]) throws -> LensfunDatabase {
        var xml: [URL] = []
        var timestampFile: URL?
        for source in sources {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil,
                                                                             options: [.skipsHiddenFiles])) ?? []
                // A Lensfun update tarball unpacks to version_1/, which is a folder of XML.
                xml.append(contentsOf: contents.filter { $0.pathExtension.lowercased() == "xml" })
                if let stamp = contents.first(where: { $0.lastPathComponent == "timestamp.txt" }) { timestampFile = stamp }
            } else if source.pathExtension.lowercased() == "xml" {
                xml.append(source)
            } else if source.lastPathComponent == "timestamp.txt" {
                timestampFile = source
            }
        }
        guard !xml.isEmpty else { throw LensfunDatabaseError.notADatabase }

        // Parse every file before touching the installed copy.
        var merged = LensfunDatabase()
        for file in xml {
            let parsed = try LensfunDatabase.parse(try Data(contentsOf: file))
            merged.formatVersion = max(merged.formatVersion, parsed.formatVersion)
            merged.cameras.append(contentsOf: parsed.cameras)
            merged.lenses.append(contentsOf: parsed.lenses)
            for (mount, compatible) in parsed.mounts { merged.mounts[mount] = compatible }
        }
        guard !merged.isEmpty else { throw LensfunDatabaseError.notADatabase }
        merged.fileCount = xml.count

        // Only now replace the installed set.
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for old in xmlFiles { try? manager.removeItem(at: old) }
        try? manager.removeItem(at: directory.appendingPathComponent("timestamp.txt"))
        for file in xml {
            let destination = directory.appendingPathComponent(file.lastPathComponent)
            try? manager.removeItem(at: destination)
            try manager.copyItem(at: file, to: destination)
        }
        if let timestampFile {
            try? manager.copyItem(at: timestampFile, to: directory.appendingPathComponent("timestamp.txt"))
        }
        return merged
    }

    /// Removes the installed database, returning the app to its state before Lensfun was used.
    func uninstall() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The panel's view of the database: whether it is there, what it holds, and the operations that change it.
@MainActor
@Observable
final class LensfunDatabaseManager {
    enum Status: Equatable {
        case notInstalled
        case loading
        case installed
        case failed(String)
    }

    private(set) var status: Status = .notInstalled
    /// The parsed database, once loaded. Nil while it is absent or unreadable.
    private(set) var database: LensfunDatabase?
    /// The database's own date, when the import carried one.
    private(set) var databaseDate: Date?
    private(set) var digest = ""
    /// A message from the last import attempt, shown in the panel until the next one.
    private(set) var lastError: String?

    let store: LensfunDatabaseStore

    init(store: LensfunDatabaseStore = .default) {
        self.store = store
    }

    var isInstalled: Bool { status == .installed }

    var statusText: String {
        switch status {
        case .notInstalled: return "Not installed"
        case .loading: return "Reading database…"
        case .installed:
            let lenses = database?.lenses.count ?? 0
            let cameras = database?.cameras.count ?? 0
            return "\(lenses) lenses, \(cameras) cameras"
        case .failed(let reason): return reason
        }
    }

    /// Reads what is installed, if anything. Called when the panel opens; cheap when the folder is empty.
    func refresh() {
        guard store.isInstalled else {
            status = .notInstalled
            database = nil
            databaseDate = nil
            digest = ""
            return
        }
        status = .loading
        do {
            let loaded = try store.load()
            database = loaded
            databaseDate = store.timestamp
            digest = store.digest()
            status = .installed
        } catch {
            database = nil
            status = .failed(error.localizedDescription)
        }
    }

    /// What an edit's snapshot needs before it is taken: a database installed on disk but not yet read
    /// in this session has to be read now, or the first Camera Raw edit would render as if Lensfun were
    /// absent until some panel happened to open. Cheap when the folder is empty (one directory listing),
    /// and a no-op once loaded, so the parse cost lands once per session, not per edit.
    func ensureLoadedForEdit() {
        guard !isInstalled, store.isInstalled else { return }
        refresh()
    }

    /// Installs what the user chose. Returns true when the database is now usable.
    @discardableResult
    func install(from sources: [URL]) -> Bool {
        do {
            let loaded = try store.install(from: sources)
            database = loaded
            databaseDate = store.timestamp
            digest = store.digest()
            status = .installed
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            // The previous install is untouched; report the failure without pretending there is no database.
            if store.isInstalled { refresh() } else { status = .failed(error.localizedDescription) }
            return false
        }
    }

    func uninstall() {
        store.uninstall()
        database = nil
        databaseDate = nil
        digest = ""
        lastError = nil
        status = .notInstalled
    }

    /// Records a failure the file panel itself reported, such as a revoked grant, without touching the install.
    func report(_ error: Error) {
        lastError = error.localizedDescription
    }
}
