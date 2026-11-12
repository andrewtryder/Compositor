import Foundation

/// Finds `work/geometry-validation` from this source file, then from linked git worktrees.
/// Photographs stay untracked. A checkout without them does not embed another machine's path.
nonisolated enum GeometryValidationFixtures {
    static func sourceRoot() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("work/geometry-validation", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    static func rootContaining(_ relativePath: String) -> URL? {
        for root in roots() {
            let url = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: url.path) { return root }
        }
        return nil
    }

    static var hasLocalPhotographs: Bool {
        rootContaining("originals/window-wall.jpg") != nil
    }

    private static func roots() -> [URL] {
        var found: [URL] = []
        func add(_ url: URL?) {
            guard let url else { return }
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path),
                  !found.contains(where: { $0.standardizedFileURL.path == path }) else { return }
            found.append(url)
        }
        add(sourceRoot())
        guard let source = sourceRoot() else { return found }
        var directory = source
        var gitDirectory: URL?
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let git = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                gitDirectory = isDirectory.boolValue ? git : gitDirectoryURL(git)
                break
            }
        }
        guard let gitDirectory else { return found }
        let common = commonGitDirectory(gitDirectory)
        add(common.deletingLastPathComponent().appendingPathComponent("work/geometry-validation", isDirectory: true))
        let worktrees = common.appendingPathComponent("worktrees", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: worktrees.path) else { return found }
        for name in names {
            let pointer = worktrees.appendingPathComponent(name).appendingPathComponent("gitdir")
            guard let text = try? String(contentsOf: pointer, encoding: .utf8) else { continue }
            let worktreeGit = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
            add(worktreeGit.deletingLastPathComponent().appendingPathComponent("work/geometry-validation", isDirectory: true))
        }
        return found
    }

    private static func gitDirectoryURL(_ gitFile: URL) -> URL? {
        guard let text = try? String(contentsOf: gitFile, encoding: .utf8) else { return nil }
        let prefix = "gitdir:"
        guard let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix(prefix) else { return nil }
        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return URL(fileURLWithPath: path)
    }

    private static func commonGitDirectory(_ gitDirectory: URL) -> URL {
        let pointer = gitDirectory.appendingPathComponent("commondir")
        guard let text = try? String(contentsOf: pointer, encoding: .utf8) else { return gitDirectory }
        return URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDirectory).standardizedFileURL
    }
}
