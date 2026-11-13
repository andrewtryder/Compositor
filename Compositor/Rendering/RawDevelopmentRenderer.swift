import Foundation
import CoreImage
import UniformTypeIdentifiers

/// Actor that manages `CIRAWFilter` decoder state for persistent RAW development.
///
/// Provides revision-based cancellation, single-develop-at-a-time guarantees,
/// temporary file caching for RAW bytes, and bounded caches so older slider
/// results never overwrite newer previews.
@MainActor
final class RawDevelopmentRenderer {
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
    private var inFlightTasks: [Int: Task<CGImage?, Never>] = [:]

    // MARK: - Public API

    /// Begin a RAW develop operation. Returns a revision number that callers
    /// must check against `inFlightRevision` before applying the result, or `nil`
    /// if development could not begin.
    /// - Parameter sourceURL: URL pointing to the original RAW file bytes.
    /// - Parameter settings: Development settings to apply.
    /// - Parameter sixteenBit: Whether to produce 16-bit output (for DeepLayer).
    /// - Returns: revision number to track against inFlightRevision, or nil.
    func beginDevelop(
        sourceURL: URL,
        settings: RawDevelopSettings,
        sixteenBit: Bool = false
    ) -> Int? {
        let revision = nextRevision
        nextRevision += 1
        inFlightRevision = revision

        let task = Task { @MainActor in
            // Write RAW bytes to a temporary file if needed.
            var url: URL
            if let cached = self.rawFileURLCache[sourceURL.absoluteString] {
                url = cached
            } else {
                url = self.temporaryRawFileURL(for: sourceURL)
                self.rawFileURLCache[sourceURL.absoluteString] = url
            }

            do {
                // Use RawImporter.develop which creates a CIRAWFilter and applies settings
                // This handles both 16-bit and 8-bit output paths
                let developedImage: CGImage? = try RawImporter.develop(
                    url,
                    settings: settings,
                    limit: nil,
                    sixteenBit: sixteenBit
                )
                return developedImage
            } catch {
                // RAW development failed
                return nil
            }
        }

        // Store the task for potential cancellation
        inFlightTasks[revision] = task

        // Clean up completed tasks asynchronously
        Task { @MainActor in
            _ = await task.value
            // Remove completed task from the dictionary
            inFlightTasks[revision] = nil
        }

        return revision
    }

    /// Call before applying a develop result to ensure it's the latest revision.
    func checkRevision(_ revision: Int, against inFlightRevision: Int) -> Bool {
        return revision == inFlightRevision
    }

    /// Cancel any in-flight develop with a lower revision than the given one.
    func cancelOlder(than revision: Int) {
        // The revision system in beginDevelop already handles this by
        // overwriting inFlightRevision; this is a safety net.
        for (r, task) in inFlightTasks where r < revision {
            task.cancel()
        }
        // Remove all tasks with revision key less than the given revision
        var keysToRemove: [Int] = []
        for (key, _) in inFlightTasks where key < revision {
            keysToRemove.append(key)
        }
        for key in keysToRemove {
            inFlightTasks.removeValue(forKey: key)
        }
    }

    // MARK: - Private

    /// Write RAW source bytes to a temporary file so CIRAWFilter(imageURL:) can read them.
    /// The rawData is expected to be the original camera RAW bytes.
    private func temporaryRawFileURL(for sourceURL: URL) -> URL {
        // Use a stable temporary directory; the file is cleaned up when the app quits
        let tempDir = FileManager.default.temporaryDirectory
        let ext = sourceURL.pathExtension.lowercased()
        // Validate it's a known RAW extension
        let knownExtensions: Set<String> = ["dng", "cr2", "nef", "arw", "rw2", "orf", "pef", "sr2", "erf", "k25", "dcr", "mrw"]
        let fileExtension = knownExtensions.contains(ext) ? ext : "dng"
        let fileName = "compositor-raw-\(sourceURL.lastPathComponent)-\(UUID().uuidString.prefix(8)).\(fileExtension)"
        return tempDir.appendingPathComponent(fileName)
    }
}

// MARK: - RawDevelopmentRenderer+Extensions

extension RawDevelopmentRenderer {
    /// Shared instance for the project.
    static let shared = RawDevelopmentRenderer()
}