import Foundation
import UniformTypeIdentifiers

/// One own repo under ~/code as Apps › Repos lists it (Pilot 1.0.2, Sven Q716): its name, branch and last commit's subject.
public struct RepoSummary: Sendable, Identifiable, Equatable {
    public let name: String
    public let url: URL
    public var branch: String?
    public var subject: String?
    public var id: String { name }
}

/// A file or folder in a repo's tree, as Apps › Repos draws it.
public struct RepoEntry: Sendable, Identifiable, Hashable {
    public let url: URL
    /// Its path inside the repo, "Sources/Pilot/PilotApp.swift".
    public let path: String
    public let isFolder: Bool
    public var name: String { url.lastPathComponent }

    public init(url: URL, path: String, isFolder: Bool) { self.url = url; self.path = path; self.isFolder = isFolder }
    public var id: String { path }
}

/// What the preview pane shows of one file, read off the main thread: a file over `textCap` or one that is not text says
/// so instead of loading.
public enum RepoPreview: Sendable, Equatable {
    case text([String])
    case markdown(String)
    /// An image or a PDF: Quick Look draws it.
    case quickLook
    case large(Int64)
    case binary
    case unreadable(String)
}

/// Apps › Repos (Pilot 1.0.2, Sven Q716): own repos under ~/code, their files as a tree and a preview. Read-only: Pilot
/// never writes into a repo, and git runs only with GIT_OPTIONAL_LOCKS=0: the page's `git log`, and the Repos widget's
/// `status` (RepoStatus), which without it would rewrite the index. Everything is read when the page asks for it: no
/// watcher, no polling, nothing kept once the page closes.
public enum Repos {
    /// A text file is read whole up to this; a larger one says so.
    public static let textCap: Int64 = 512 * 1024
    /// The most files the filter walks in one repo, so a giant repo never fills Pilot's memory.
    public static let filterCap = 20_000

    /// Folders the tree hides until All files is on: build output and dependencies, besides the root .gitignore's plain
    /// folder names. `.git` and Finder's `.DS_Store` never show.
    public static let heavy: Set<String> = ["node_modules", ".build", "build", "DerivedData", "dist", ".next", "target", "Pods", ".venv",
                                            "venv", "__pycache__", ".swiftpm", ".gradle", ".turbo", ".cache", "coverage"]
    static let never: Set<String> = [".git", ".DS_Store"]

    /// ~/code's own repos, by name: a top-level folder AgentInstructions.isOwnRepo takes (its `.git` a folder; a
    /// worktree's `.git` is a file).
    public static func list(home: URL) -> [RepoSummary] {
        let code = home.appendingPathComponent("code")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: code.path)) ?? []
        return names.filter { AgentInstructions.isOwnRepo($0, in: code) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { RepoSummary(name: $0, url: code.appendingPathComponent($0), branch: branch(code.appendingPathComponent($0))) }
    }

    /// The branch `.git/HEAD` names; a detached HEAD is its short hash.
    public static func branch(_ repo: URL) -> String? {
        guard let head = try? String(contentsOf: repo.appendingPathComponent(".git/HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
        return head.hasPrefix("ref: ") ? String(head.dropFirst(5)) : String(head.prefix(7))
    }

    /// A git that is really there: never `/usr/bin/git`, whose shim asks to install the command-line tools when they are
    /// missing.
    static let git: String? = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
                               "/Applications/Xcode.app/Contents/Developer/usr/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// The last commit's subject, from `git log` in a child, 3 s at most; nil without git, commits or an answer.
    public static func subject(_ repo: URL) async -> String? {
        guard let git else { return nil }
        var environment = ChildProcess.toolEnvironment(git)
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        let out = try? await ChildProcess.run(git, ["-C", repo.path, "log", "-1", "--format=%s"], environment: environment,
                                              timeout: .seconds(3), limit: 4096)
        let line = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? nil : line
    }

    /// Every repo's subject, four children at a time.
    public static func subjects(_ repos: [RepoSummary]) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            var found: [String: String] = [:], next = 0
            func add() {
                guard next < repos.count else { return }
                let repo = repos[next]
                next += 1
                group.addTask { (repo.name, await subject(repo.url)) }
            }
            for _ in 0..<4 { add() }
            for await (name, subject) in group {
                if let subject { found[name] = subject }
                add()
            }
            return found
        }
    }

    /// The root .gitignore's plain folder names ("node_modules/", "/build"): no wildcards, no path inside.
    public static func ignored(_ repo: URL) -> Set<String> {
        guard let text = try? String(contentsOf: repo.appendingPathComponent(".gitignore"), encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { return nil }
            let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty, name.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]/\\")) == nil else { return nil }
            return name
        })
    }

    /// One folder's own level, folders first, each by name as Finder sorts; `hidden` is what the tree leaves out.
    public static func children(of folder: URL, in repo: URL, hidden: Set<String>) -> [RepoEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let prefix = repo.standardizedFileURL.path + "/"
        return urls.compactMap { url -> RepoEntry? in
            let name = url.lastPathComponent
            guard !never.contains(name) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            if isFolder, hidden.contains(name) { return nil }
            let path = url.standardizedFileURL.path
            return RepoEntry(url: url, path: path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : name, isFolder: isFolder)
        }
        .sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    /// The repo's files for the filter, breadth first, past no hidden folder, up to `cap`; `capped` says it stopped there.
    public static func files(in repo: URL, hidden: Set<String>, cap: Int = filterCap) -> (files: [RepoEntry], capped: Bool) {
        var files: [RepoEntry] = [], queue = [repo], at = 0
        while at < queue.count {
            for entry in children(of: queue[at], in: repo, hidden: hidden) {
                if entry.isFolder { queue.append(entry.url) } else { files.append(entry) }
                if files.count >= cap { return (files, true) }
            }
            at += 1
        }
        return (files, false)
    }

    /// The files whose path holds every word typed, in any case, a name match first; at most `limit`.
    public static func filter(_ files: [RepoEntry], query: String, limit: Int = 400) -> [RepoEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let held = files.filter { file in let path = file.path.lowercased(); return words.allSatisfy(path.contains) }
        let byName = held.filter { file in let name = file.name.lowercased(); return words.allSatisfy(name.contains) }
        let named = Set(byName.map(\.path))
        return Array((byName + held.filter { !named.contains($0.path) }).prefix(limit))
    }

    /// What the pane shows of `url`: Markdown rendered, text as lines, images and PDFs through Quick Look, a large or
    /// binary file named as such without reading it.
    public static func preview(_ url: URL) -> RepoPreview {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let size = Int64(values?.fileSize ?? 0), type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image) || type.conforms(to: .pdf) { return .quickLook }
        if size > textCap { return .large(size) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return .unreadable(error.localizedDescription) }
        guard !data.prefix(8192).contains(0), let text = String(data: data, encoding: .utf8) else { return .binary }
        if MarkdownHTML.isMarkdown(url) { return .markdown(text) }
        return .text(lines(text))
    }

    /// A text file's lines as the pane numbers them: tabs as four spaces, no empty last line.
    public static func lines(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\t", with: "    ").split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
