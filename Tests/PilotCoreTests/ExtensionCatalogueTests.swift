import Foundation
import Synchronization
import Testing
@testable import PilotCore

/// The extension catalogue (2026-10-10): its index read and checked, versions and where an entry stands, GitHub with
/// gh as the fallback, and install, update and remove in temporary folders. The fixture is banozz0/pilot-extensions'
/// index.json on 2026-10-10 trimmed to three entries, with the Ports extension's two files it lists
/// (Fixtures/extension-catalogue); nothing reaches the network, runs gh or touches the real Trash.
@Suite("Extension catalogue")
struct ExtensionCatalogueTests {
    static let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/extension-catalogue")

    /// Serves the repo's files from `root`, as raw.githubusercontent.com would, counting what it was asked.
    final class Folder: Sendable {
        let root: URL
        let asked = Mutex<[String]>([])
        /// A path whose bytes are swapped for these, a file changed on the way.
        let swapped: [String: Data]
        init(_ root: URL = ExtensionCatalogueTests.fixture, swapped: [String: Data] = [:]) { self.root = root; self.swapped = swapped }

        var source: ExtensionCatalogue.Source {
            ExtensionCatalogue.Source { [self] path, limit in
                asked.withLock { $0.append(path) }
                let data = try swapped[path] ?? Data(contentsOf: root.appending(path: path))
                guard data.count <= limit else { throw ExtensionCatalogue.Problem.tooBig(path: path, limit: limit) }
                return data
            }
        }
    }

    /// The Trash in a test: what was moved there, moved into a folder of its own.
    final class Bin: Sendable {
        let folder: URL
        let moved = Mutex<[String]>([])
        init(_ folder: URL) { self.folder = folder }
        var trash: @Sendable (URL) throws -> Void {
            { [self] url in
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: folder.appending(path: "\(url.lastPathComponent)-\(UUID().uuidString)"))
                moved.withLock { $0.append(url.lastPathComponent) }
            }
        }
    }

    static func scratch(in base: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = base.appendingPathComponent("pilot-catalogue-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func index() throws -> ExtensionCatalogue.Index {
        try ExtensionCatalogue.index(Data(contentsOf: fixture.appending(path: "index.json")))
    }

    /// An extension folder `name` under `dir` with `manifest` and an executable `run`.
    static func write(_ manifest: String, as name: String, in dir: URL) throws {
        let ext = dir.appending(path: name)
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: ext.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: ext.appending(path: "run"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ext.appending(path: "run").path)
    }

    // MARK: The index

    @Test("The real index reads: entries by title, hidden commands left out, files with their sizes, sha256 and modes")
    func fixtureReads() throws {
        let index = try Self.index()
        #expect(index.entries.map(\.id) == ["claude-sessions", "pomodoro", "ports"] && index.skipped.isEmpty)
        let sessions = try #require(index.entry("claude-sessions"))
        #expect(sessions.commands.map(\.name) == ["sessions"], "its pushed Claude session detail is hidden")
        #expect(sessions.version == "1.0.1" && sessions.requires == ["python3"] && sessions.permissions.files == ["~/.claude/projects"])
        let ports = try #require(index.entry("ports"))
        #expect(ports.title == "Ports" && ports.icon == "🔌" && ports.commands == [.init(name: "kill-port", title: "Kill port", mode: .list)])
        #expect(ports.files.map(\.path) == ["extension.json", "main.py"] && ports.files.map(\.executable) == [false, true])
        #expect(ExtensionCatalogue.needs(ports) == "Needs python3 and lsof")
        for file in ports.files {
            let data = try Data(contentsOf: Self.fixture.appending(path: "extensions/ports/\(file.path)"))
            #expect(data.count == file.size && ExtensionCatalogue.sha256(data) == file.sha256, "\(file.path)")
        }
    }

    /// An entry line with `change` applied to its JSON object.
    static func line(_ id: String = "demo", version: String = "1.0.0", files: [[String: Any]]? = nil) -> [String: Any] {
        let sha = String(repeating: "a", count: 64)
        return ["id": id, "title": id.capitalized, "version": version, "description": "A demo.",
                "files": files ?? [["path": "extension.json", "sha256": sha, "size": 10], ["path": "bin/run", "sha256": sha, "size": 10, "executable": true]]]
    }

    static func data(_ entries: [[String: Any]], schema: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": schema, "extensions": entries])
    }

    @Test("An entry that breaks a rule is skipped with why; the others still list")
    func rules() throws {
        let sha = String(repeating: "b", count: 64)
        let many = (0...ExtensionCatalogue.mostFiles).map { ["path": $0 == 0 ? "extension.json" : "f\($0)", "sha256": sha, "size": 1] }
        let heavy = (0..<6).map { ["path": $0 == 0 ? "extension.json" : "f\($0)", "sha256": sha, "size": 1_900_000] }
        let entries: [[String: Any]] = [
            Self.line("good"),
            Self.line("Bad!"),
            Self.line("vers", version: "1.0.0-beta"),
            Self.line("up", files: [["path": "extension.json", "sha256": sha, "size": 1], ["path": "../../evil", "sha256": sha, "size": 1]]),
            Self.line("abs", files: [["path": "/etc/passwd", "sha256": sha, "size": 1]]),
            Self.line("nomanifest", files: [["path": "run", "sha256": sha, "size": 1]]),
            Self.line("nosha", files: [["path": "extension.json", "sha256": "abc", "size": 1]]),
            Self.line("big", files: [["path": "extension.json", "sha256": sha, "size": ExtensionCatalogue.fileLimit + 1]]),
            Self.line("many", files: many),
            Self.line("heavy", files: heavy),
            ["id": "shape", "title": 3],
            Self.line("good"),
        ]
        let index = try ExtensionCatalogue.index(Self.data(entries))
        #expect(index.entries.map(\.id) == ["good"])
        let why = Dictionary(index.skipped.map { ($0.id, $0.reason) }) { a, b in "\(a) | \(b)" }
        #expect(why["Bad!"] == "id must be lowercase letters, digits and hyphens")
        #expect(why["vers"] == #"version "1.0.0-beta" is not like 1.2.0"#)
        #expect(why["up"] == #"file path "../../evil" leaves its folder"# && why["abs"] == #"file path "/etc/passwd" leaves its folder"#)
        #expect(why["nomanifest"] == "it has no extension.json" && why["nosha"] == "extension.json has no sha256")
        #expect(why["big"] == "extension.json is larger than the 2 MB a file may be" && why["many"] == "it must have 1 to 200 files")
        #expect(why["heavy"] == "it is larger than the 10 MB an extension may be")
        #expect(why["shape"] == "title has the wrong type", "\(why)")
        #expect(why["good"] == "listed twice")
    }

    @Test("The index refuses to read when it is too large, not JSON or in a newer format")
    func refused() throws {
        #expect(throws: ExtensionCatalogue.Problem.tooBig(path: "index.json", limit: ExtensionCatalogue.indexLimit)) {
            try ExtensionCatalogue.index(Data(count: ExtensionCatalogue.indexLimit + 1))
        }
        #expect(throws: ExtensionCatalogue.Problem.unreadable("does not read")) { try ExtensionCatalogue.index(Data("<html>".utf8)) }
        #expect(throws: ExtensionCatalogue.Problem.newerSchema(2)) { try ExtensionCatalogue.index(Self.data([], schema: 2)) }
        #expect(ExtensionCatalogue.Problem.newerSchema(2).reason == "The catalogue is in format 2, newer than this Pilot reads; update Pilot.")
    }

    @Test("A path stays inside its folder: subfolders yes; absolute, dot, dot-dot and empty parts no")
    func safePaths() {
        for path in ["main.py", "bin/run", "a/b/c.json", ".hidden/x"] { #expect(ExtensionCatalogue.isSafe(path), "\(path)") }
        for path in ["", "/abs", "../x", "a/../b", "a/./b", "a//b", "a/", "a\\b", "..", "."] { #expect(!ExtensionCatalogue.isSafe(path), "\(path)") }
    }

    // MARK: Versions and standing

    @Test("Versions compare part by part, a missing part counting 0; anything else is no version")
    func versions() {
        typealias V = ExtensionCatalogue.Version
        #expect(V("1.0.1")! > V("1.0.0")! && V("1.10")! > V("1.9.9")! && V("1.0")! == V("1.0.0")! && V("2")! > V("1.99")!)
        for bad in ["", "1.0.0-beta", "v1", "1..0", "1.0.0.0.0", "１.0"] { #expect(V(bad) == nil, "\(bad)") }
    }

    @Test("An entry is Install when absent, Installed at its version or newer, Update when older or without a version; its words follow")
    func standing() throws {
        let entry = try #require(try Self.index().entry("pomodoro"))
        func at(_ version: String?) -> [String: ExtensionCatalogue.Installed] {
            ["pomodoro": .init(id: "pomodoro", version: version, folder: URL(filePath: "/x"))]
        }
        #expect(ExtensionCatalogue.standing(of: entry, installed: [:]) == .install)
        #expect(ExtensionCatalogue.standing(of: entry, installed: at("1.0.0")) == .installed)
        #expect(ExtensionCatalogue.standing(of: entry, installed: at("1.2")) == .installed)
        #expect(ExtensionCatalogue.standing(of: entry, installed: at("0.9.0")) == .update)
        #expect(ExtensionCatalogue.standing(of: entry, installed: at(nil)) == .update)
        #expect(ExtensionCatalogue.standing(of: entry, installed: at("dev")) == .update)
        #expect(ExtensionCatalogue.button(entry, .install) == "Install" && ExtensionCatalogue.button(entry, .update) == "Update to 1.0.0"
                && ExtensionCatalogue.button(entry, .installed) == "Installed")
        #expect(ExtensionCatalogue.subtitle(entry, .update) == "\(entry.description) · Update to 1.0.0")
        #expect(ExtensionCatalogue.installedLine(entry, updated: false) == "Pomodoro installed. Its commands are in Hyper+Space.")
        #expect(ExtensionCatalogue.search(try Self.index().entries, "kill").map(\.id) == ["ports"], "a command's title finds it")
        #expect(ExtensionCatalogue.search(try Self.index().entries, " ").count == 3)
    }

    @Test("A manifest's version is read when it is a string; any other value leaves none and the extension still reads")
    func manifestVersion() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write(#"{"id": "a", "title": "A", "version": "1.2.0", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "run"}]}"#, as: "a", in: dir)
        try Self.write(#"{"id": "b", "title": "B", "version": 3, "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "run"}]}"#, as: "b", in: dir)
        let installed = ExtensionCatalogue.installed(Extension.find(in: dir))
        #expect(installed["a"]?.version == "1.2.0" && installed["b"] != nil && installed["b"]?.version == nil)
    }

    @Test("A read is kept ten minutes, then asked again")
    func kept() throws {
        var kept = ExtensionCatalogue.Kept()
        let t = Date(timeIntervalSince1970: 1_000_000)
        #expect(kept.fresh(at: t) == nil)
        kept.keep(try Self.index(), at: t)
        #expect(kept.fresh(at: t.addingTimeInterval(599)) != nil && kept.fresh(at: t.addingTimeInterval(600)) == nil)
    }

    // MARK: GitHub, then gh

    final class Calls: Sendable { let gh = Mutex<[[String]]>([]) }

    static func github(status: Int, body: Data = Data("{}".utf8), gh: Result<Data, ChildProcess.Failure>? = nil, cli: String? = "/opt/homebrew/bin/gh",
                       calls: Calls = Calls()) -> ExtensionCatalogue.Source {
        .github(get: { url in
            #expect(url.absoluteString.hasPrefix("https://raw.githubusercontent.com/banozz0/pilot-extensions/main/"))
            return (body, status)
        }, gh: { tool, arguments in
            calls.gh.withLock { $0.append([tool] + arguments) }
            return try (gh ?? .success(Data())).get()
        }, cli: { cli })
    }

    @Test("raw.githubusercontent.com's 200 is the answer; gh is never run")
    func rawAnswers() async throws {
        let calls = Calls()
        let data = try await Self.github(status: 200, body: Data("hello".utf8), calls: calls).fetch("index.json", 100)
        #expect(data == Data("hello".utf8) && calls.gh.withLock { $0 }.isEmpty)
        await #expect(throws: ExtensionCatalogue.Problem.tooBig(path: "index.json", limit: 3)) {
            try await Self.github(status: 200, body: Data("hello".utf8)).fetch("index.json", 3)
        }
    }

    @Test("A 401, 403 or 404 (the repo is private) asks gh api for the raw file", arguments: [401, 403, 404])
    func ghFallback(_ status: Int) async throws {
        let calls = Calls()
        let data = try await Self.github(status: status, gh: .success(Data([0, 255, 1])), calls: calls).fetch("extensions/ports/main.py", 100)
        #expect(data == Data([0, 255, 1]), "bytes as sent, not text")
        #expect(calls.gh.withLock { $0 } == [["/opt/homebrew/bin/gh", "api", "-H", "Accept: application/vnd.github.raw",
                                               "repos/banozz0/pilot-extensions/contents/extensions/ports/main.py?ref=main"]])
    }

    @Test("Once raw refused the index, that read's files go straight to gh; the next index read asks raw again")
    func rawRefusedOnce() async throws {
        let raw = Calls(), calls = Calls()
        let source = ExtensionCatalogue.Source.github(get: { url in
            raw.gh.withLock { $0.append([url.lastPathComponent]) }
            return (Data(), 404)
        }, gh: { tool, arguments in
            calls.gh.withLock { $0.append([tool] + arguments) }
            return Data("x".utf8)
        }, cli: { "/opt/homebrew/bin/gh" })
        _ = try await source.fetch("index.json", 100)
        _ = try await source.fetch("extensions/ports/main.py", 100)
        _ = try await source.fetch("extensions/ports/extension.json", 100)
        #expect(raw.gh.withLock { $0 } == [["index.json"]] && calls.gh.withLock { $0 }.count == 3)
        _ = try await source.fetch("index.json", 100)
        #expect(raw.gh.withLock { $0 } == [["index.json"], ["index.json"]])
    }

    @Test("Neither answering says why: no gh, gh signed out, gh's own line, another HTTP status, no network")
    func unreachable() async throws {
        func reason(_ source: ExtensionCatalogue.Source) async -> String? {
            do { _ = try await source.fetch("index.json", 100); return nil } catch { return (error as? ExtensionCatalogue.Problem)?.reason }
        }
        #expect(await reason(Self.github(status: 404, cli: nil))
                == "Pilot's catalogue could not be reached: the catalogue is private; install gh and sign in to GitHub with gh auth login.")
        let signedOut = ChildProcess.Failure(tool: "gh", status: 4, message: "To get started with GitHub CLI, please run:  gh auth login")
        #expect(await reason(Self.github(status: 404, gh: .failure(signedOut)))
                == "Pilot's catalogue could not be reached: the catalogue is private; sign in to GitHub with gh auth login.")
        let other = ChildProcess.Failure(tool: "gh", status: 1, message: "error connecting to api.github.com\ncheck your internet connection")
        #expect(await reason(Self.github(status: 404, gh: .failure(other))) == "Pilot's catalogue could not be reached: gh said: error connecting to api.github.com.")
        #expect(await reason(Self.github(status: 500)) == "Pilot's catalogue could not be reached: GitHub answered 500.")
        let offline = ExtensionCatalogue.Source.github(get: { _ in throw URLError(.notConnectedToInternet) }, gh: { _, _ in Data() }, cli: { nil })
        #expect(await reason(offline)?.hasPrefix("Pilot's catalogue could not be reached: GitHub did not answer (") == true)
    }

    // MARK: Install, update, remove

    @Test("Install fetches each file, checks it, sets its mode, and lands Extensions/<id> reading as the extension; nothing left behind")
    func install() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions"), bin = Bin(dir.appending(path: "Trash")), served = Folder()
        let installer = ExtensionInstaller(extensions: exts, source: served.source, trash: bin.trash)
        let index = try await installer.index()
        let progress = Mutex<[String]>([])
        let ext = try await installer.install(try #require(index.entry("ports"))) { done, all in progress.withLock { $0.append("\(done)/\(all)") } }
        #expect(ext.id == "ports" && ext.version == "1.0.0" && ext.folder.lastPathComponent == "ports" && ext.listed.map(\.name) == ["kill-port"])
        #expect(progress.withLock { $0 } == ["1/2", "2/2"])
        #expect(served.asked.withLock { $0 } == ["index.json", "extensions/ports/extension.json", "extensions/ports/main.py"])
        func mode(_ name: String) throws -> Int { try #require(try FileManager.default.attributesOfItem(atPath: exts.appending(path: "ports/\(name)").path)[.posixPermissions] as? Int) }
        #expect(try mode("main.py") == 0o755 && mode("extension.json") == 0o644)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["Extensions"], "no temporary folder left, nothing trashed")
        #expect(bin.moved.withLock { $0 }.isEmpty)
    }

    @Test("A file that does not match its sha256 installs nothing: the copy installed stays, no temporary folder is left")
    func mismatch() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions"), bin = Bin(dir.appending(path: "Trash"))
        try Self.write(#"{"id": "ports", "title": "Old ports", "version": "0.9.0", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "run"}]}"#,
                       as: "ports", in: exts)
        let served = Folder(swapped: ["extensions/ports/main.py": Data(String(repeating: "x", count: 5578).utf8)])
        let installer = ExtensionInstaller(extensions: exts, source: served.source, trash: bin.trash)
        await #expect(throws: ExtensionCatalogue.Problem.mismatch(path: "main.py")) { try await installer.install(try #require(try Self.index().entry("ports"))) }
        #expect(Extension.find(in: exts).extensions.map(\.title) == ["Old ports"] && bin.moved.withLock { $0 }.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["Extensions"])
    }

    @Test("An update trashes the copy installed in whatever folder, lands Extensions/<id> and leaves the extension's data alone")
    func update() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions"), bin = Bin(dir.appending(path: "Trash"))
        try Self.write(#"{"id": "ports", "title": "Ports", "version": "0.9.0", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "run"}]}"#,
                       as: "my-ports", in: exts)
        let prefs = dir.appending(path: "ExtensionData/ports/preferences.json")
        try FileManager.default.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"x": "kept"}"#.utf8).write(to: prefs)
        let installer = ExtensionInstaller(extensions: exts, source: Folder().source, trash: bin.trash)
        let ext = try await installer.install(try #require(try Self.index().entry("ports")))
        #expect(bin.moved.withLock { $0 } == ["my-ports"])
        #expect(ext.version == "1.0.0" && Extension.find(in: exts).extensions.map(\.folder.lastPathComponent) == ["ports"])
        #expect(try String(contentsOf: prefs, encoding: .utf8) == #"{"x": "kept"}"#)
    }

    @Test("An update over Extensions/<id> itself (Sven on build 21: 'The file \"ghostex\" doesn't exist.') trashes the old copy once and lands the new one, its data kept")
    func updateInPlace() async throws {
        // Not under /var: there resolving symlinks rewrites both URLs alike and hid the bug; Pilot's folder has none.
        let dir = try Self.scratch(in: URL.cachesDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions"), bin = Bin(dir.appending(path: "Trash"))
        try Self.write(#"{"id": "ports", "title": "Ports", "version": "0.9.0", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "run"}]}"#,
                       as: "ports", in: exts)
        let prefs = dir.appending(path: "ExtensionData/ports/preferences.json")
        try FileManager.default.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"x": "kept"}"#.utf8).write(to: prefs)
        let installer = ExtensionInstaller(extensions: exts, source: Folder().source, trash: bin.trash)
        let ext = try await installer.install(try #require(try Self.index().entry("ports")))
        #expect(bin.moved.withLock { $0 } == ["ports"])
        #expect(ext.version == "1.0.0" && Extension.find(in: exts).extensions.map { "\($0.folder.lastPathComponent) \($0.version ?? "-")" } == ["ports 1.0.0"])
        #expect(try String(contentsOf: prefs, encoding: .utf8) == #"{"x": "kept"}"#)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["ExtensionData", "Extensions", "Trash"], "nothing left aside")
    }

    @Test("An update whose download fails leaves the old version installed and nothing trashed")
    func updateDownloadFails() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions"), bin = Bin(dir.appending(path: "Trash"))
        try Self.write(#"{"id": "ports", "title": "Ports", "version": "0.9.0", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "run"}]}"#,
                       as: "ports", in: exts)
        let offline = ExtensionCatalogue.Source { path, _ in
            guard path.hasSuffix("main.py") else { return try Data(contentsOf: ExtensionCatalogueTests.fixture.appending(path: path)) }
            throw URLError(.notConnectedToInternet)
        }
        let installer = ExtensionInstaller(extensions: exts, source: offline, trash: bin.trash)
        await #expect(throws: URLError.self) { try await installer.install(try #require(try Self.index().entry("ports"))) }
        #expect(Extension.find(in: exts).extensions.map { "\($0.folder.lastPathComponent) \($0.version ?? "-")" } == ["ports 0.9.0"] && bin.moved.withLock { $0 }.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["Extensions"])
    }

    @Test("A folder named the id that holds another extension, or none, is refused with why and left as it was")
    func folderTaken() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions"), bin = Bin(dir.appending(path: "Trash"))
        let installer = ExtensionInstaller(extensions: exts, source: Folder().source, trash: bin.trash)
        let entry = try #require(try Self.index().entry("ports"))
        try Self.write(#"{"id": "other", "title": "Other", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "run"}]}"#, as: "ports", in: exts)
        await #expect(throws: ExtensionCatalogue.Problem.folderTaken(id: "ports", why: #"holds extension "other""#)) { try await installer.install(entry) }
        try FileManager.default.removeItem(at: exts.appending(path: "ports"))
        try FileManager.default.createDirectory(at: exts.appending(path: "ports"), withIntermediateDirectories: true)
        await #expect(throws: ExtensionCatalogue.Problem.folderTaken(id: "ports", why: "is not an extension (no extension.json)")) { try await installer.install(entry) }
        #expect(bin.moved.withLock { $0 }.isEmpty && Extension.find(in: exts).extensions.isEmpty)
        #expect(ExtensionCatalogue.Problem.folderTaken(id: "ports", why: "is not an extension (no extension.json)").reason
                == "Extensions already has a folder named ports that is not an extension (no extension.json); move it away first.")
    }

    @Test("What arrives must read as an extension with the entry's id")
    func wrongID() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = Data(#"{"id": "kill", "title": "Kill", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "run"}]}"#.utf8)
        let run = Data("#!/bin/sh\n".utf8)
        let served = Folder(swapped: ["extensions/ports/extension.json": manifest, "extensions/ports/run": run])
        let entry = ExtensionCatalogue.Entry(id: "ports", title: "Ports", version: "1.0.0", description: "", files: [
            .init(path: "extension.json", sha256: ExtensionCatalogue.sha256(manifest), size: manifest.count),
            .init(path: "run", sha256: ExtensionCatalogue.sha256(run), size: run.count, executable: true),
        ])
        let installer = ExtensionInstaller(extensions: dir.appending(path: "Extensions"), source: served.source, trash: Bin(dir.appending(path: "Trash")).trash)
        await #expect(throws: ExtensionCatalogue.Problem.wrongID(found: "kill", expected: "ports")) { try await installer.install(entry) }
        let noRun = ExtensionCatalogue.Entry(id: "ports", title: "Ports", version: "1.0.0", description: "", files: [entry.files[0]])
        await #expect(throws: ExtensionCatalogue.Problem.notAnExtension("command go: run is not an executable file in the folder")) {
            try await installer.install(noRun)
        }
    }

    @Test("Remove moves the extension's folder to the Trash and keeps its data; one not installed says so")
    func remove() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions"), bin = Bin(dir.appending(path: "Trash"))
        try Self.write(#"{"id": "ports", "title": "Ports", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "run"}]}"#, as: "p", in: exts)
        let installer = ExtensionInstaller(extensions: exts, source: Folder().source, trash: bin.trash)
        #expect(try installer.remove("ports") == "Ports")
        #expect(bin.moved.withLock { $0 } == ["p"] && Extension.find(in: exts).extensions.isEmpty)
        #expect(throws: ExtensionCatalogue.Problem.notInstalled("ports")) { try installer.remove("ports") }
        #expect(ExtensionCatalogue.removedLine("Ports") == "Ports moved to the Trash. Its settings are kept.")
    }

    // MARK: The page's place

    @Test("pilot://open?page=extensions&tab=catalogue opens the one Extensions list at its catalogue, Install's catalogue keeps its own; Extensions has no tabs (Q601)")
    func place() {
        #expect(AppPlace.linked(URL(string: "pilot://open?page=extensions&tab=catalogue")!) == AppPlace(.extensions, .extensionCatalogue))
        #expect(AppPlace.linked(URL(string: "pilot://open?page=install&tab=catalogue")!) == AppPlace(.install, .catalogue))
        #expect(AppPlace.linked(URL(string: "pilot://open?page=pomodoro")!) == AppPlace(.extensions, .extensionCatalogue))
        #expect(AppPage.extensions.tabs.isEmpty && AppPage.extensions.firstSection == nil)
        #expect(AppPlace.search("pomodoro").first == AppPlace(.extensionCatalogue) && AppPlace.search("install extension") == [AppPlace(.extensionCatalogue)])
    }
}
