import CryptoKit
import Foundation
import Synchronization

/// Pilot's catalogue (2026-10-10, ADR 0010; public-repo spec T20): `catalogue/index.json` in banozz0/pilot, made by its
/// `catalogue/scripts/build-index.py`, lists each extension with its version, words, commands, what it says it touches
/// and every file with its size and sha256, and each theme pack with its palette, its files and their digest. Pilot reads
/// it only while the person looks at it (the Extensions page's one list, Q601, the menu's Extension catalogue, or
/// Refresh), never at launch or in the background, and installs an entry's files only when each one hashes as listed
/// (ExtensionInstaller, ThemeInstaller).
public enum ExtensionCatalogue {
    /// The repo, and the folder in it the catalogue is: every path a Source fetches is inside `root`.
    public static let repo = "banozz0/pilot", branch = "main", root = "catalogue", indexPath = "index.json"
    /// Where a person finds the catalogue on the web, as a question names it.
    public static let home = "github.com/\(repo)/tree/\(branch)/\(root)"
    /// The index format this Pilot reads: 2 lists themes beside the extensions.
    public static let schema = 2
    /// The most the index, one file and one extension may weigh, and the most files an extension may hold.
    public static let indexLimit = 1_000_000, fileLimit = 2_000_000, extensionLimit = 10_000_000, mostFiles = 200
    /// A theme pack's, as catalogue/scripts/check.py's THEME_LIMITS: one file, the pack, and its files.
    public static let themeFileLimit = 8 * 1024 * 1024, themeLimit = 40 * 1024 * 1024, themeMostFiles = 300
    /// How long an index read is kept in memory before the next look reads it again.
    public static let keptFor: TimeInterval = 600

    /// One extension the catalogue offers.
    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: String, title: String, icon: String?, version: String, description: String
        /// One or two concrete uses, said under its words (story 158).
        public let examples: [String]
        /// The tools its programs need ("python3"), said on its card.
        public let requires: [String]
        /// Its commands a person sees; hidden ones are not listed.
        public let commands: [Command]
        public let permissions: Extension.Permissions
        public let files: [File]

        public init(id: String, title: String, icon: String? = nil, version: String, description: String, examples: [String] = [],
                    requires: [String] = [], commands: [Command] = [], permissions: Extension.Permissions = .init(), files: [File]) {
            self.id = id; self.title = title; self.icon = icon; self.version = version; self.description = description
            self.examples = examples
            self.requires = requires; self.commands = commands; self.permissions = permissions; self.files = files
        }

        /// What every file weighs together.
        public var size: Int { files.reduce(0) { $0 + $1.size } }
    }

    public struct Command: Equatable, Sendable {
        public let name: String, title: String, mode: Extension.Mode
        public init(name: String, title: String, mode: Extension.Mode) { self.name = name; self.title = title; self.mode = mode }
    }

    /// A file of an entry: its path inside `extensions/<id>/` in the repo, its sha256 in lowercase hex, its size and
    /// whether it is a program (installed 0755, else 0644).
    public struct File: Equatable, Sendable {
        public let path: String, sha256: String, size: Int, executable: Bool
        public init(path: String, sha256: String, size: Int, executable: Bool = false) {
            self.path = path; self.sha256 = sha256; self.size = size; self.executable = executable
        }
    }

    /// One theme pack the catalogue offers (schema 2): what its card shows before anything is fetched, every file in
    /// `themes/<id>/`, and `digest`, the sha256 of its file list, which an installed copy is compared with, since a pack's
    /// manifest has no version.
    public struct Theme: Equatable, Sendable, Identifiable {
        public let id: String, title: String, dark: Bool, styles: [String], palette: [String: String], preview: String?
        public let digest: String, files: [File]

        /// What every file weighs together.
        public var size: Int { files.reduce(0) { $0 + $1.size } }
    }

    /// What the catalogue holds: its extensions and themes by title, and the entries Pilot left out, each with why (in
    /// the log only).
    public struct Index: Equatable, Sendable {
        public let entries: [Entry], themes: [Theme], skipped: [Skipped]
        public init(entries: [Entry], themes: [Theme] = [], skipped: [Skipped] = []) {
            self.entries = entries; self.themes = themes; self.skipped = skipped
        }

        public func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }
        public func theme(_ id: String) -> Theme? { themes.first { $0.id == id } }
    }

    public struct Skipped: Equatable, Sendable {
        public let id: String, reason: String
        public init(id: String, reason: String) { self.id = id; self.reason = reason }
    }

    /// Why the catalogue or an install could not go on, in words the page and the HUD show.
    public enum Problem: Error, Equatable, Sendable {
        case unreachable(String), tooBig(path: String, limit: Int), unreadable(String), newerSchema(Int)
        case mismatch(path: String), notAnExtension(String), wrongID(found: String, expected: String), folderTaken(id: String, why: String)
        case notInstalled(String), notListed(String), failed(String)
        case notATheme(String), themeTaken(id: String, why: String), themeNotListed(String)

        public var reason: String {
            switch self {
            case .unreachable(let why): "Pilot's catalogue could not be reached: \(why)."
            case .tooBig(let path, let limit): "\(path) is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)), so Pilot did not take it."
            case .unreadable(let why): "The catalogue does not read: \(why)."
            case .newerSchema(let n): "The catalogue is in format \(n), newer than this Pilot reads; update Pilot."
            case .mismatch(let path): "\(path) did not match the catalogue's checksum, so nothing was installed."
            case .notAnExtension(let why): "What arrived is not an extension (\(why)), so nothing was installed."
            case .wrongID(let found, let expected): "What arrived is extension \"\(found)\", not \"\(expected)\", so nothing was installed."
            case .folderTaken(let id, let why): "Extensions already has a folder named \(id) that \(why); move it away first."
            case .notInstalled(let id): "No extension \(id) is installed."
            case .notListed(let id): "The catalogue has no extension \(id)."
            case .failed(let why): why
            case .notATheme(let why): "What arrived is not a theme pack Pilot takes (\(why)), so nothing was installed."
            case .themeTaken(let id, let why): "Pilot already has a theme pack \(id) \(why), so nothing was installed."
            case .themeNotListed(let id): "The catalogue has no theme \(id)."
            }
        }

        /// What `error` says to the person: a Problem's reason, else its own description.
        public static func reason(_ error: any Error) -> String { (error as? Problem)?.reason ?? error.localizedDescription }
    }

    // MARK: Reading the index

    private struct Raw: Decodable {
        let schema: Int
        let extensions: [Lenient<Line>]
        /// Schema 2's; a schema 1 index has none.
        let themes: [Lenient<ThemeLine>]?
    }

    /// An entry that may not decode: a newer or broken one is skipped, never the whole catalogue.
    private struct Lenient<Read: Decodable>: Decodable {
        let line: Read?, id: String, why: String?

        private struct Named: Decodable { let id: String? }

        init(from decoder: any Decoder) throws {
            id = (try? Named(from: decoder))?.id ?? "?"
            do { line = try Read(from: decoder); why = nil } catch { line = nil; why = describe(error) }
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _)?: "\(key.stringValue) is missing"
        case .typeMismatch(_, let c)?, .valueNotFound(_, let c)?: "\(field(c.codingPath)) has the wrong type"
        default: "does not read"
        }
    }

    /// A field's name inside its entry ("files.size"), the index's own key and the array places left out.
    private static func field(_ path: [any CodingKey]) -> String {
        let names = path.filter { $0.intValue == nil }.map(\.stringValue)
        return (["extensions", "themes"].contains(names.first) && names.count > 1 ? names.dropFirst() : names[...]).joined(separator: ".")
    }

    /// What an entry says, checked by `entry(_:)`.
    private struct Line: Decodable {
        struct Command: Decodable { let name: String, title: String, mode: String }
        struct File: Decodable { let path: String, sha256: String, size: Int, executable: Bool? }
        let id: String, title: String, icon: String?, version: String, description: String?, requires: [String]?
        let commands: [Command]?, permissions: Extension.Permissions?, files: [File]
        /// Any JSON, so a wrong type shows no examples rather than skipping the entry.
        let examples: JSONValue?
    }

    /// What a theme entry says, checked by `theme(_:)`.
    private struct ThemeLine: Decodable {
        let id: String, title: String, dark: Bool, styles: [String]?, palette: [String: String]?, preview: String?, digest: String
        let files: [Line.File]
    }

    /// The index `data` holds: entries whose id, version or files break a rule are skipped with why, and of two with one
    /// id the first is kept. Throws when it is too large, not JSON or in a newer format.
    public static func index(_ data: Data) throws -> Index {
        guard data.count <= indexLimit else { throw Problem.tooBig(path: indexPath, limit: indexLimit) }
        let raw: Raw
        do { raw = try JSONDecoder().decode(Raw.self, from: data) } catch { throw Problem.unreadable(describe(error)) }
        guard raw.schema <= schema else { throw Problem.newerSchema(raw.schema) }
        var skipped: [Skipped] = []
        /// Each kind's entries that hold every rule, the first of two with one id kept.
        func kept<Read, Made: Identifiable>(_ items: [Lenient<Read>], _ make: (Read) throws -> Made) -> [Made] where Made.ID == String {
            var made: [Made] = [], ids = Set<String>()
            for item in items {
                do {
                    guard let line = item.line else { throw Problem.failed(item.why ?? "does not read") }
                    let entry = try make(line)
                    guard ids.insert(entry.id).inserted else { throw Problem.failed("listed twice") }
                    made.append(entry)
                } catch {
                    skipped.append(Skipped(id: item.id, reason: (error as? Problem)?.reason ?? "\(error)"))
                }
            }
            return made
        }
        let entries = kept(raw.extensions, entry), themes = kept(raw.themes ?? [], theme)
        return Index(entries: entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
                     themes: themes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, skipped: skipped)
    }

    /// `line` as an entry once every rule holds: an extension name for its id, a dotted version, at most 200 files
    /// with an extension.json among them, each a safe path with a sha256 and a size under the limits.
    private static func entry(_ line: Line) throws -> Entry {
        func no(_ why: String) -> Problem { .failed(why) }
        guard Extension.isName(line.id) else { throw no("id must be lowercase letters, digits and hyphens") }
        guard Version(line.version) != nil else { throw no("version \"\(line.version)\" is not like 1.2.0") }
        let files = try checked(line.files, most: mostFiles, manifest: Extension.manifestName,
                                file: (fileLimit, "\(fileLimit / 1_000_000) MB a file"), total: (extensionLimit, "\(extensionLimit / 1_000_000) MB an extension"))
        let commands = (line.commands ?? []).compactMap { c in Extension.Mode(rawValue: c.mode).map { Command(name: c.name, title: c.title, mode: $0) } }
        return Entry(id: line.id, title: line.title, icon: line.icon.flatMap { ScriptCommand.isEmoji($0) ? $0 : nil }, version: line.version,
                     description: line.description ?? "", examples: Extension.examples(line.examples), requires: line.requires ?? [], commands: commands,
                     permissions: line.permissions ?? .init(), files: files)
    }

    /// `line` as a theme once every rule holds: a pack id, a title, 1 to 300 files with a manifest.json among them, each a
    /// safe path with a sha256 and a size under the theme limits, and a digest that is its files' own.
    private static func theme(_ line: ThemeLine) throws -> Theme {
        func no(_ why: String) -> Problem { .failed(why) }
        guard ThemePack.validID(line.id) else { throw no("id must be lowercase letters, digits and hyphens") }
        guard !line.title.isEmpty else { throw no("it has no title") }
        // A theme's files are data: none is installed as a program.
        let files = try checked(line.files, most: themeMostFiles, manifest: "manifest.json", file: (themeFileLimit, "\(themeFileLimit >> 20) MB a theme's file"),
                                total: (themeLimit, "\(themeLimit >> 20) MB a theme")).map { File(path: $0.path, sha256: $0.sha256, size: $0.size) }
        guard line.digest == digest(files) else { throw no("its digest is not its files'") }
        return Theme(id: line.id, title: line.title, dark: line.dark, styles: line.styles ?? [], palette: line.palette ?? [:],
                     preview: line.preview, digest: line.digest, files: files)
    }

    /// An entry's file list once each file is a safe path, listed once, with a sha256 and a size under `file`'s limit,
    /// 1 to `most` of them with `manifest` among them and `total`'s limit in all; each limit with the words its refusal says.
    private static func checked(_ lines: [Line.File], most: Int, manifest: String, file: (Int, String), total: (Int, String)) throws -> [File] {
        func no(_ why: String) -> Problem { .failed(why) }
        guard !lines.isEmpty, lines.count <= most else { throw no("it must have 1 to \(most) files") }
        var paths = Set<String>(), sum = 0
        let files = try lines.map { f in
            guard isSafe(f.path) else { throw no("file path \"\(f.path)\" leaves its folder") }
            guard paths.insert(f.path).inserted else { throw no("\(f.path) is listed twice") }
            guard f.sha256.wholeMatch(of: /[0-9a-f]{64}/) != nil else { throw no("\(f.path) has no sha256") }
            guard (0...file.0).contains(f.size) else { throw no("\(f.path) is larger than the \(file.1) may be") }
            sum += f.size
            return File(path: f.path, sha256: f.sha256, size: f.size, executable: f.executable ?? false)
        }
        guard paths.contains(manifest) else { throw no("it has no \(manifest)") }
        guard sum <= total.0 else { throw no("it is larger than the \(total.1) may be") }
        return files
    }

    /// A pack's digest as build-index.py writes it: the sha256 of "<path> <sha256>\n" for each file, by path.
    public static func digest(_ files: [File]) -> String {
        sha256(Data(files.sorted { $0.path < $1.path }.map { "\($0.path) \($0.sha256)\n" }.joined().utf8))
    }

    /// A path inside an extension's folder: relative, subfolders allowed, never `.` or `..` or an empty part.
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The sha256 of `data` in lowercase hex, as the index lists it.
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: Versions and what an entry's button says

    /// A dotted version, "1.2.0", compared part by part, a missing part counting 0.
    public struct Version: Comparable, Sendable {
        public let parts: [Int]

        public init?(_ text: String) {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
            self.parts = parts.compactMap { Int($0) }
            guard self.parts.count == parts.count else { return nil }
        }

        public static func < (a: Version, b: Version) -> Bool {
            for i in 0..<max(a.parts.count, b.parts.count) {
                let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
                if x != y { return x < y }
            }
            return false
        }

        public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
    }

    /// An extension in the Extensions folder, as the catalogue sees it: its id, its manifest's version and its folder.
    public struct Installed: Equatable, Sendable {
        public let id: String, version: String?, folder: URL
        public init(id: String, version: String?, folder: URL) { self.id = id; self.version = version; self.folder = folder }
    }

    /// The extensions `found` holds, by id.
    public static func installed(_ found: Extension.Found) -> [String: Installed] {
        Dictionary(found.extensions.map { ($0.id, Installed(id: $0.id, version: $0.version, folder: $0.folder)) }) { first, _ in first }
    }

    /// Where an entry stands: not in the Extensions folder, there at this version or newer, or older there (a missing or
    /// unreadable version counts as older).
    public enum Standing: Equatable, Sendable {
        case install, installed, update

        /// Its button's word: "Install", "Installed", "Update".
        public var label: String {
            switch self {
            case .install: "Install"
            case .installed: "Installed"
            case .update: "Update"
            }
        }
    }

    public static func standing(of entry: Entry, installed: [String: Installed]) -> Standing {
        guard let have = installed[entry.id] else { return .install }
        guard let offered = Version(entry.version), let mine = have.version.flatMap(Version.init), mine >= offered else { return .update }
        return .installed
    }

    /// Where a theme stands, by the digest of the installed pack with its id: none there, the catalogue's files as they
    /// are, or other files (an older catalogue copy, or one the person edited).
    public static func standing(of theme: Theme, installed: [String: String]) -> Standing {
        guard let have = installed[theme.id] else { return .install }
        return have == theme.digest ? .installed : .update
    }

    /// Its button's words: "Install", "Update to 1.1", "Installed"; a theme's says "Update" (`standing.label`).
    public static func button(_ entry: Entry, _ standing: Standing) -> String {
        standing == .update ? "Update to \(entry.version)" : standing.label
    }

    /// A menu row's muted line: "Focus blocks and breaks… · Update to 1.1".
    public static func subtitle(_ entry: Entry, _ standing: Standing) -> String {
        [entry.description, button(entry, standing)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "Needs python3 and git"; nil when it needs nothing.
    public static func needs(_ entry: Entry) -> String? {
        entry.requires.isEmpty ? nil : "Needs \(spokenList(entry.requires))"
    }

    /// The HUD after an install or update.
    public static func installedLine(_ entry: Entry, updated: Bool) -> String {
        "\(entry.title) \(updated ? "updated to \(entry.version)" : "installed"). Its commands are in Hyper+Space."
    }

    /// The HUD after Update all: how many updated, and which did not (each one's detail says why).
    public static func updatedAllLine(updated: Int, failed: [String]) -> String {
        if failed.isEmpty { return "Updated \(updated) extension\(updated == 1 ? "" : "s")." }
        return "Updated \(updated) of \(updated + failed.count). \(spokenList(failed)) did not update; open \(failed.count == 1 ? "it" : "each") for why."
    }

    /// The HUD after a remove.
    public static func removedLine(_ title: String) -> String { "\(title) moved to the Trash. Its settings are kept." }

    /// Uninstall's confirm (story 158): its question and what it says happens.
    public static func uninstallQuestion(_ title: String) -> String { "Uninstall \(title)?" }
    public static let uninstallNote = "Its folder goes to the Trash. Its settings and data are kept, so installing it again picks up where you left off."

    /// The entries whose title, id, description, an example or a command's title holds `query`, else, when none, those a
    /// typo of it finds (FuzzyRanker.Filter); all for a blank one.
    public static func search(_ entries: [Entry], _ query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return FuzzyRanker.Filter(q).filter(entries) { e in [e.title, e.id, e.description] + e.examples + e.commands.map(\.title) }
    }

    /// What a menu row's search matches besides its title.
    public static func keywords(_ entry: Entry) -> String {
        ([entry.id, entry.description] + entry.commands.map(\.title)).joined(separator: " ")
    }

    // MARK: The index kept a while

    /// The last index read and when, so a look within ten minutes asks nothing of GitHub.
    public struct Kept: Sendable {
        public private(set) var index: Index?
        private var at: Date?

        public init() {}

        /// The index when it was read less than `keptFor` before `now`.
        public func fresh(at now: Date = .now) -> Index? {
            guard let index, let at, now.timeIntervalSince(at) < keptFor else { return nil }
            return index
        }

        public mutating func keep(_ index: Index, at now: Date = .now) { self.index = index; at = now }
    }
}

// MARK: - Where the files come from

extension ExtensionCatalogue {
    /// How a file of the catalogue (a path inside `root`) reaches Pilot: GitHub in Pilot, a folder in a debug build's
    /// `catalogue.source` and in tests, or a table in tests, which never touch the network.
    public struct Source: Sendable {
        /// The bytes at `path` in the repo, at most `limit` of them; throws a Problem.
        public let fetch: @Sendable (_ path: String, _ limit: Int) async throws -> Data

        public init(fetch: @escaping @Sendable (_ path: String, _ limit: Int) async throws -> Data) { self.fetch = fetch }

        /// raw.githubusercontent.com, and when it answers 401, 403 or 404 (the repo is private), `gh api` as a child process,
        /// which reads the person's own GitHub sign-in. Each index read asks raw first; once it refused, the files after it
        /// go straight to gh, so an install pays no refused request per file. `get` answers the bytes and the HTTP status;
        /// `gh` runs the gh at the path `cli` finds with its arguments.
        public static func github(get: @escaping @Sendable (URL) async throws -> (Data, Int) = Source.get,
                                  gh: @escaping @Sendable (String, [String]) async throws -> Data = Source.gh,
                                  cli: @escaping @Sendable () -> String? = Source.ghPath) -> Source {
            let rawRefused = Flag()
            return Source { path, limit in
                let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                    .joined(separator: "/")
                if path == indexPath || !rawRefused.on.withLock({ $0 }) {
                    guard let url = URL(string: "https://raw.githubusercontent.com/\(repo)/\(branch)/\(root)/\(encoded)") else { throw Problem.unreachable("bad path \(path)") }
                    let status: Int
                    do {
                        let (data, code) = try await get(url)
                        if code == 200 {
                            guard data.count <= limit else { throw Problem.tooBig(path: path, limit: limit) }
                            if path == indexPath { rawRefused.on.withLock { $0 = false } }
                            return data
                        }
                        status = code
                    } catch let problem as Problem { throw problem }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw Problem.unreachable("GitHub did not answer (\(error.localizedDescription))") }
                    guard [401, 403, 404].contains(status) else { throw Problem.unreachable("GitHub answered \(status)") }
                    if path == indexPath { rawRefused.on.withLock { $0 = true } }
                }
                guard let tool = cli() else { throw Problem.unreachable("the catalogue is private; install gh and sign in to GitHub with gh auth login") }
                let data: Data
                do {
                    data = try await gh(tool, ["api", "-H", "Accept: application/vnd.github.raw", "repos/\(repo)/contents/\(root)/\(encoded)?ref=\(branch)"])
                } catch let failure as ChildProcess.Failure { throw Problem.unreachable(ghReason(failure.message)) }
                catch is ChildProcess.TimedOut { throw Problem.unreachable("gh took too long") }
                catch is CancellationError { throw CancellationError() }
                catch { throw Problem.unreachable("gh did not run (\(error.localizedDescription))") }
                guard data.count <= limit else { throw Problem.tooBig(path: path, limit: limit) }
                return data
            }
        }

        /// Whether raw.githubusercontent.com refused the last index read.
        final class Flag: Sendable { let on = Mutex(false) }

        /// What gh's failure means for the person: sign in, or its own first line.
        static func ghReason(_ message: String) -> String {
            let lower = message.lowercased()
            if lower.contains("auth login") || lower.contains("not logged") || lower.contains("authentication") {
                return "the catalogue is private; sign in to GitHub with gh auth login"
            }
            if lower.contains("404") || lower.contains("not found") { return "gh can't see \(repo) with the account it is signed in to" }
            let first = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? "it failed"
            return "gh said: \(first.prefix(120))"
        }

        /// One session for every read, so an install's files share a connection: no cookies or cache kept, a request given
        /// up after 20 s.
        static let session: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            return URLSession(configuration: config)
        }()

        /// One GET.
        @Sendable public static func get(_ url: URL) async throws -> (Data, Int) {
            let (data, response) = try await session.data(from: url)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        /// gh's stdout, its environment Pilot's with Homebrew's folder on PATH, stopped after 30 s.
        @Sendable public static func gh(_ cli: String, _ arguments: [String]) async throws -> Data {
            try await ChildProcess.data(cli, arguments, environment: ChildProcess.toolEnvironment(cli), timeout: .seconds(30))
        }

        /// gh where Homebrew or its own installer puts it (Pilot runs with launchd's short PATH); nil when there is none.
        @Sendable public static func ghPath() -> String? { CatalogueEntry.Check.copies(of: "gh").first }

        /// Pilot's own: GitHub.
        public static let live = github()

        /// Fetches each of `files` from `folder` in the catalogue into `into`, each held to its listed size and sha256 (at
        /// most `limit` bytes asked), written with `mode`'s permissions; `progress` hears each one (done, of all). Throws
        /// mismatch at the first file that differs: the installers' one integrity gate.
        func download(_ files: [File], from folder: String, limit: Int, into: URL, mode: (File) -> Int,
                      progress: (Int, Int) -> Void) async throws {
            let fm = FileManager.default
            for (i, file) in files.enumerated() {
                try Task.checkCancellation()
                let data = try await fetch("\(folder)/\(file.path)", min(file.size, limit))
                guard data.count == file.size, sha256(data) == file.sha256 else { throw Problem.mismatch(path: file.path) }
                let url = into.appending(path: file.path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                try fm.setAttributes([.posixPermissions: mode(file)], ofItemAtPath: url.path)
                progress(i + 1, files.count)
            }
        }

        /// The catalogue folder `root` on this Mac (a clone's `catalogue/`): each path read inside it, at most `limit` bytes.
        public static func folder(_ root: URL) -> Source {
            Source { path, limit in
                guard isSafe(path) else { throw Problem.unreachable("bad path \(path)") }
                let handle: FileHandle
                do { handle = try FileHandle(forReadingFrom: root.appending(path: path)) }
                catch { throw Problem.unreachable("\(root.path) has no \(path)") }
                defer { try? handle.close() }
                let data = try handle.read(upToCount: limit + 1) ?? Data()
                guard data.count <= limit else { throw Problem.tooBig(path: path, limit: limit) }
                return data
            }
        }
    }
}
