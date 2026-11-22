import Foundation

/// One own repo in the repos folder as the Repos widget lists it (Pilot 1.0.2, Sven Q725): its name and branch.
public struct RepoSummary: Sendable, Identifiable, Equatable {
    public let name: String
    public let url: URL
    public var branch: String?
    public var id: String { name }
}

/// The repos folder's own repos, for the Repos widget (RepoStatus). Read-only: Pilot never writes into a repo, and git
/// runs only with GIT_OPTIONAL_LOCKS=0, as `status` would otherwise rewrite the index.
public enum Repos {
    /// The own repos in `code` (the repos folder, `folders.repos`: ~/code unless picked, the tester's ~/dev), by name: a
    /// top-level folder `isOwnRepo` takes (its `.git` a folder; a worktree's `.git` is a file).
    public static func list(in code: URL) -> [RepoSummary] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: code.path)) ?? []
        return names.filter { isOwnRepo($0, in: code) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { RepoSummary(name: $0, url: code.appendingPathComponent($0), branch: branch(code.appendingPathComponent($0))) }
    }

    /// A folder in the repos folder that is one of your own repos (Q261): not other people's clones in oss nor the _ folders
    /// (_archive, _references, _tools), and its .git a folder, as a worktree's .git is a file.
    static func isOwnRepo(_ name: String, in code: URL) -> Bool {
        guard !name.hasPrefix("."), !name.hasPrefix("_"), name != "oss" else { return false }
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: code.appendingPathComponent(name).appendingPathComponent(".git").path, isDirectory: &folder)
            && folder.boolValue
    }

    /// The branch `.git/HEAD` names; a detached HEAD is its short hash.
    static func branch(_ repo: URL) -> String? {
        guard let head = try? String(contentsOf: repo.appendingPathComponent(".git/HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
        return head.hasPrefix("ref: ") ? String(head.dropFirst(5)) : String(head.prefix(7))
    }

    /// A git that is really there: never `/usr/bin/git`, whose shim asks to install the command-line tools when they are
    /// missing.
    static let git: String? = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
                               "/Applications/Xcode.app/Contents/Developer/usr/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }
}
