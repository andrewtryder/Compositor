import Foundation
import CoreImage
import UniformTypeIdentifiers

/// Actor that manages `CIRAWFilter` decoder state for persistent RAW development.
///
/// Provides revision-based cancellation, single-develop-at-a-time guarantees,
/// temporary file caching for RAW bytes, and bounded caches so older slider
/// results never overwrite newer previews.
///
/// All access to Core Image decoder state and temporary files happens on this
/// actor, so callers never race on shared decoder resources.
actor RawDevelopmentRenderer {
    // MARK: - Revision-based cancellation

    /// Current in-flight revision. Callers compare returned revision against
    /// `inFlightRevision` before applying a result; older results are stale.
    private var inFlightRevision = 0

    /// Monotonically increasing counter; `beginDevelop` returns the next value.
    private var nextRevision = 0

    // MARK: - Temporary file caching

    /// Cached RAW file URL per sourceID, so repeated develops don't re-write bytes.
    /// Keyed by the layer's sourceID (or the import URL hash if no sourceID yet).
    private var rawFileURLCache: [String: URL] = [:]

    // MARK: - In-flight task tracking

    /// Tasks currently developing, indexed by revision number.
    private var inFlightTasks: [Int: Task<DevelopResult, Never>] = [:]

    // MARK: - Public API

    /// The result of a RAW develop operation.
    enum DevelopResult: Sendable {
        case success(CGImage)
        case failure(Error)
    }

    /// Begin a RAW develop operation. Returns a revision number that callers
    /// must check against `inFlightRevision` before applying the result, or `nil`
    /// if development could not begin.
    /// - Parameter source: The `RawSourceAsset` holding the original camera bytes.
    /// - Parameter settings: Development settings to apply.
    /// - Parameter sixteenBit: Whether to produce 16-bit output (for DeepLayer).
    /// - Returns: revision number to track against `inFlightRevision`, or nil.
    func beginDevelop(
        source: RawSourceAsset,
        settings: RawDevelopSettings,
        sixteenBit: Bool = false
    ) -> Int {
        let revision = nextRevision
        nextRevision += 1
        inFlightRevision = revision

        let task = Task {
            // Write RAW bytes to a temporary file for CIRAWFilter(imageURL:) consumption.
            let tmpURL: URL
            do {
                tmpURL = try materializeRawBytes(source)
            } catch {
                return DevelopResult.failure(error)
            }
            // Clean up the temporary file when done.
            defer { try? FileManager.default.removeItem(at: tmpURL) }

            do {
                let developedImage: CGImage? = try RawImporter.develop(
                    tmpURL,
                    settings: settings,
                    limit: nil,
                    sixteenBit: sixteenBit
                )
                guard let developedImage else {
                    return DevelopResult.failure(ImageImportError.unreadable)
                }
                return DevelopResult.success(developedImage)
            } catch {
                return DevelopResult.failure(error)
            }
        }

        inFlightTasks[revision] = task

        // Clean up completed tasks asynchronously.
        Task { [weak self] in
            _ = await task.value
            await self?.removeTask(revision: revision)
        }

        return revision
    }

    /// Call before applying a develop result to ensure it's the latest revision.
    func checkRevision(_ revision: Int, against inFlightRevision: Int) -> Bool {
        return revision == inFlightRevision
    }

    /// Wait for a develop operation to complete and return its result. Returns `nil`
    /// if the revision is unknown or the task was already removed.
    func waitForDevelop(revision: Int) async -> DevelopResult? {
        guard let task = inFlightTasks[revision] else { return nil }
        return await task.value
    }

    /// Cancel any in-flight develop with a lower revision than the given one.
    func cancelOlder(than revision: Int) {
        for (r, task) in inFlightTasks where r < revision {
            task.cancel()
        }
        var keysToRemove: [Int] = []
        for (key, _) in inFlightTasks where key < revision {
            keysToRemove.append(key)
        }
        for key in keysToRemove {
            inFlightTasks.removeValue(forKey: key)
        }
    }

    /// Cancel all in-flight develops.
    func cancelAll() {
        for (_, task) in inFlightTasks {
            task.cancel()
        }
        inFlightTasks.removeAll()
    }

    // MARK: - Private

    private func removeTask(revision: Int) {
        inFlightTasks.removeValue(forKey: revision)
    }

    /// Write RAW source bytes to a temporary file so CIRAWFilter(imageURL:) can read them.
    /// The rawData is expected to be the original camera RAW bytes.
    private func materializeRawBytes(_ source: RawSourceAsset) throws -> URL {
        // Use a stable temporary directory; the file is cleaned up when the app quits.
        let tempDir = FileManager.default.temporaryDirectory
        let ext = source.fileExtension.lowercased()
        let knownExtensions: Set<String> = ["dng", "cr2", "nef", "arw", "rw2", "orf", "pef", "sr2", "erf", "k25", "dcr", "mrw"]
        let fileExtension = knownExtensions.contains(ext) ? ext : "dng"
        let fileName = "compositor-raw-\(UUID().uuidString).\(fileExtension)"
        let url = tempDir.appendingPathComponent(fileName)
        try source.rawData.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - RawDevelopmentRenderer+Extensions

extension RawDevelopmentRenderer {
    /// Shared instance for the project.
    static let shared = RawDevelopmentRenderer()
}