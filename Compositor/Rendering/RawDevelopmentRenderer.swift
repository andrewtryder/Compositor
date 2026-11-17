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

    /// Results that finished before anyone awaited them, indexed by revision.
    ///
    /// A develop can complete between `beginDevelop` and `waitForDevelop` — a small frame, or a failure that returns
    /// at once — and dropping the finished task there made the caller read a completed develop as unknown and report
    /// the Apply as failed. Keeping the result until it is asked for removes that race; the few kept revisions are
    /// bounded below, because a caller that never collects one must not leak the frame.
    private var finished: [Int: DevelopResult] = [:]
    private static let finishedLimit = 8

    /// Revisions whose result a caller already took, so a task that finishes afterwards does not store a second copy.
    /// Bounded too: a fast develop's task can outlive its own result, and an unbounded set here would be a leak.
    private var consumed: [Int] = []
    private static let consumedLimit = 8

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

        // Collect the finished task's result here rather than dropping it: a develop that completes before the caller
        // awaits it is still a completed develop, and reading it as unknown made Apply report failure for no reason.
        Task { [weak self] in
            let result = await task.value
            await self?.finish(revision: revision, result: result)
        }

        return revision
    }

    /// Call before applying a develop result to ensure it's the latest revision.
    func checkRevision(_ revision: Int, against inFlightRevision: Int) -> Bool {
        return revision == inFlightRevision
    }

    /// Wait for a develop operation to complete and return its result. Returns `nil`
    /// only if the revision was never started here.
    ///
    /// A result is delivered once. The caller that collects it is recorded so the task's own cleanup, which may run
    /// afterwards, does not keep a second copy of a 16-bit frame for a revision nobody will ask for again.
    func waitForDevelop(revision: Int) async -> DevelopResult? {
        defer { markConsumed(revision) }
        if let result = finished.removeValue(forKey: revision) { return result }
        guard let task = inFlightTasks[revision] else { return nil }
        let result = await task.value
        // A task that finished while this await was beginning may have stored its result already.
        if let kept = finished.removeValue(forKey: revision) { return kept }
        return result
    }

    /// Remembers that nobody is going to ask for this revision again, within a bounded window.
    private func markConsumed(_ revision: Int) {
        consumed.append(revision)
        if consumed.count > Self.consumedLimit { consumed.removeFirst(consumed.count - Self.consumedLimit) }
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

    /// A task finished: take it out of the in-flight table and keep its result for whoever asks for it.
    ///
    /// Kept results are bounded so a revision no one ever collects — a preview superseded by a newer one — cannot
    /// hold frames indefinitely; the oldest goes first, which is the one least likely still to be wanted.
    private func finish(revision: Int, result: DevelopResult) {
        inFlightTasks.removeValue(forKey: revision)
        // A caller that already took this result must not leave a second retained copy of a 16-bit frame behind.
        if let index = consumed.firstIndex(of: revision) {
            consumed.remove(at: index)
            return
        }
        finished[revision] = result
        while finished.count > Self.finishedLimit, let oldest = finished.keys.min() {
            finished.removeValue(forKey: oldest)
        }
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