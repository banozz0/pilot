import Foundation
import Synchronization
import Testing
@testable import Pilot
@testable import PilotCore

/// `pilot ext new|test|install|remove` (AI helper T10), asked through the registry the socket answers from. Each test has
/// a home of its own in a temporary folder: Extensions, ExtensionData and the Trash, so nothing reaches Sven's, and no
/// other suite's (PilotFolder.support is shared by the whole run under CFFIXED_USER_HOME). No Engine is built: one loads
/// and writes back the run's shared binds file. The gate is the test's: it records each question and answers as told.
@MainActor
@Suite("Extension tooling", .serialized)
struct ExtensionToolingTests {
    static let templates = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/ext-template").standardizedFileURL

    @MainActor final class Rig {
        let tools = ExtensionTools()
        let verbs = ControlVerbs()
        let work = FileManager.default.temporaryDirectory.appending(path: "pilot-ext-tooling-\(UUID().uuidString)").resolvingSymlinksInPath()
        let trash: URL
        var asked: [ControlGate.Ask] = []
        var allow = false
        let keychain = CollectionsExtensionPrefsTests.Keychain()
        /// What ext open opened: the id and whether its page.
        var opened: [(String, Bool)] = []
        /// The catalogue's files by path, as GitHub would serve them; none there is unreachable.
        let shelf = Shelf()
        /// Runs while the question is up, as Sven reads it.
        var whileAsking: () throws -> Void = {}

        init() throws {
            trash = work.appending(path: "Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            tools.templates = ExtensionToolingTests.templates
            tools.extensions = work.appending(path: "home/Extensions")
            tools.data = work.appending(path: "home/ExtensionData")
            let trash = trash
            tools.trash = { try FileManager.default.moveItem(at: $0, to: trash.appending(path: "\(UUID().uuidString)-\($0.lastPathComponent)")) }
            tools.gate = ControlGate { [unowned self] ask, _ in
                asked.append(ask)
                try? whileAsking()
                return allow
            }
            tools.cache = work.appending(path: "home/Caches")
            tools.keychain = keychain
            tools.label = { _ in nil }
            tools.open = { [unowned self] in opened.append(($0, $1)) }
            let shelf = shelf
            tools.catalogue = ExtensionCatalogueModel(installer: ExtensionInstaller(
                extensions: tools.extensions, staging: work.appending(path: "home"),
                source: ExtensionCatalogue.Source { path, _ in
                    guard let data = shelf.files.withLock({ $0[path] }) else { throw ExtensionCatalogue.Problem.unreachable("offline") }
                    return data
                }, trash: tools.trash))
            verbs.registerExtensions(tools)
        }

        func ask(_ verb: String, _ args: String...) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args, cwd: work.path), peer: nil)
        }

        func installedIDs() -> [String] { Extension.find(in: tools.extensions).extensions.map(\.id) }

        /// The extension ids `pilot actions` lists, read as it reads them (ControlActions.menuOffers), on this test's folder:
        /// Extension.find() at the time of asking, so an install shows with no reload.
        func actionIDs() -> Set<String> { Set(Extension.actions([], with: Extension.find(in: tools.extensions).extensions).map(\.id)) }

        func trashed() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: trash.path) }

        func clean() { try? FileManager.default.removeItem(at: work) }

        /// An installed extension `probe` with a no-view command, one printing actions, a list and a page, each marking
        /// that it ran; and a password preference.
        func probe() throws {
            let dir = tools.extensions.appending(path: "probe")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"""
                {"id": "probe", "title": "Probe", "icon": "🔭", "version": "1.2.0", "description": "Looks at things.", "examples": ["Type probe"],
                 "permissions": {"network": ["api.example.com"], "clipboard": true},
                 "preferences": [{"name": "token", "type": "password", "title": "Token"}, {"name": "who", "type": "text", "title": "Who", "required": true}],
                 "surfaces": {"page": {"command": "board"}},
                 "commands": [{"name": "say", "title": "Say", "mode": "no-view", "run": "say", "keyword": "say"},
                              {"name": "acts", "title": "Acts", "mode": "no-view", "run": "acts"},
                              {"name": "pick", "title": "Pick", "mode": "list", "run": "pick"},
                              {"name": "boom", "title": "Boom", "mode": "no-view", "run": "boom"},
                              {"name": "board", "title": "Board", "mode": "no-view", "hidden": true, "run": "board"}]}
                """#.utf8).write(to: dir.appending(path: Extension.manifestName))
            let programs = [
                "say": #"echo '{"type":"hud","text":"said it"}'"#,
                "acts": #"echo '{"type":"action","action":{"type":"copy","text":"copied"}}'; echo '{"type":"action","action":{"type":"open","url":"https://example.com"}}'"#,
                "pick": #"echo '{"type":"list","items":[{"title":"One","subtitle":"first","actions":[{"type":"copy","text":"one"}]},{"title":"Two"}]}'"#,
                "boom": "echo stderr-secret-words >&2; exit 3",
                "board": ##"echo '{"type":"blocks","blocks":[{"type":"markdown","text":"# Hi"}],"refresh":30}'"##,
            ]
            for (name, body) in programs {
                let program = dir.appending(path: name)
                try Data("#!/bin/sh\ncat > /dev/null\ntouch ran-\(name)\n\(body)\n".utf8).write(to: program)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
            }
        }

        func ran(_ name: String) -> Bool { FileManager.default.fileExists(atPath: tools.extensions.appending(path: "probe/ran-\(name)").path) }

        /// The catalogue offering extension `cat` at `version`, its two files on the shelf.
        func offer(version: String, manifestCommand: String = "meow") throws {
            let manifest = Data(#"{"id": "cat", "title": "Cat", "version": "\#(version)", "commands": [{"name": "\#(manifestCommand)", "title": "Meow", "mode": "no-view", "run": "meow"}]}"#.utf8)
            let program = Data("#!/bin/sh\necho '{\"type\":\"hud\",\"text\":\"meow\"}'\n".utf8)
            let index = try JSONSerialization.data(withJSONObject: ["schema": 1, "extensions": [[
                "id": "cat", "title": "Cat", "version": version, "description": "Says meow.", "requires": ["python3"],
                "commands": [["name": "meow", "title": "Meow", "mode": "no-view"]],
                "files": [["path": "extension.json", "sha256": ExtensionCatalogue.sha256(manifest), "size": manifest.count],
                          ["path": "meow", "sha256": ExtensionCatalogue.sha256(program), "size": program.count, "executable": true]],
            ]]])
            shelf.files.withLock { $0 = ["index.json": index, "extensions/cat/extension.json": manifest, "extensions/cat/meow": program] }
        }
    }

    final class Shelf: Sendable { let files = Mutex<[String: Data]>([:]) }

    static func field(_ answer: ControlAnswer, _ name: String) -> JSONValue? {
        if case .object(let o)? = answer.result { o[name] } else { nil }
    }

    @Test("ext new writes a folder per mode that ext test passes, each command run once after Allow")
    func newThenTest() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        rig.allow = true
        let made = await rig.ask("ext", "new", "demo", "--mode", "list")
        #expect(made.ok, "\(made.error?.message ?? "")")
        let folder = rig.work.appending(path: "demo")
        #expect(Self.field(made, "made") == .string(folder.path))
        let tested = await rig.ask("ext", "test", "demo")
        #expect(tested.ok, "\(tested.error?.message ?? "")")
        #expect(Self.field(tested, "check") == .string("passed"))
        guard case .array(let runs)? = Self.field(tested, "runs"), case .object(let run)? = runs.first else { Issue.record("no runs"); return }
        #expect(runs.count == 1 && run["command"] == .string("items") && run["as"] == .string("list"))
        #expect(rig.asked.map(\.title) == ["Test extension"])
        #expect(rig.asked[0].detail.contains(folder.path) && rig.asked[0].detail.contains("ext.demo.items (list)"))

        for (i, mode) in ["no-view", "detail", "bar"].enumerated() {
            let id = "demo-\(i)"
            #expect(await rig.ask("ext", "new", id, "--mode", mode).ok, "\(mode)")
            let answer = await rig.ask("ext", "test", rig.work.appending(path: id).path)
            #expect(answer.ok, "\(mode): \(answer.error?.message ?? "")")
        }
        #expect(await rig.ask("ext", "new", "demo").error?.code == .badValue, "a taken folder")
        #expect(await rig.ask("ext", "new", "other", "--mode", "grid").error?.code == .badValue)
        #expect(await rig.ask("ext", "new", "Bad_ID").error?.message.contains("must be lowercase") == true)
    }

    nonisolated static let catalogue = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../catalogue/extensions").standardizedFileURL

    @Test("ext test --check passes each catalogue extension (18 today), read in place, and asks nothing",
          .enabled(if: FileManager.default.fileExists(atPath: catalogue.path)))
    func catalogueChecks() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        // Read without asking, as a temporary folder is: the test reads Sven's checkout, not an agent's folder.
        rig.tools.readable.append(Self.catalogue)
        let folders = try FileManager.default.contentsOfDirectory(at: Self.catalogue, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
        #expect(!folders.isEmpty)
        for folder in folders {
            let answer = await rig.ask("ext", "test", folder.path, "--check")
            #expect(answer.ok && Self.field(answer, "check") == .string("passed"), "\(folder.lastPathComponent): \(answer.error?.message ?? "")")
        }
        #expect(rig.asked.isEmpty)
    }

    @Test("Each catalogue extension's install question (18 today) is short enough to be asked, every file named",
          .enabled(if: FileManager.default.fileExists(atPath: catalogue.path)))
    func catalogueQuestions() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        rig.tools.readable.append(Self.catalogue)
        let folders = try FileManager.default.contentsOfDirectory(at: Self.catalogue, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
        for folder in folders {
            // Denied once asked: the catalogue is only read, into a temporary copy.
            let answer = await rig.ask("ext", "install", folder.path)
            let message = answer.error?.message ?? ""
            #expect(answer.error?.code == .denied && !message.hasPrefix("not asked:"), "\(folder.lastPathComponent): \(message)")
            guard let asked = rig.asked.last, asked.detail.contains("from \(folder.path)") else { continue }
            let length = asked.text.unicodeScalars.count, lines = asked.text.count { $0 == "\n" }
            #expect(length <= ControlGate.Ask.longest && lines <= ControlGate.Ask.mostLines)
            print("install question \(folder.lastPathComponent): \(length) of \(ControlGate.Ask.longest) characters, \(lines) line breaks")
        }
        #expect(rig.asked.count == folders.count)
        #expect(rig.installedIDs().isEmpty)
    }

    @Test("ext test --check runs nothing and asks nothing; a denied test runs nothing; a broken manifest fails with the page's reason")
    func checkOnly() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        #expect(await rig.ask("ext", "new", "demo").ok)
        let checked = await rig.ask("ext", "test", "demo", "--check")
        #expect(checked.ok && Self.field(checked, "runs") == nil)
        let denied = await rig.ask("ext", "test", "demo")
        #expect(denied.error?.code == .denied)
        #expect(rig.asked.count == 1, "--check asked nothing; the plain test asked once")

        let manifest = rig.work.appending(path: "demo/extension.json")
        let text = try String(contentsOf: manifest, encoding: .utf8).replacing(#""mode": "list""#, with: #""mode": "grid""#)
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        let page = try #require(Extension.find(in: rig.work).broken.first?.problem.reason)
        let broken = await rig.ask("ext", "test", "demo")
        #expect(broken.error?.code == .badValue)
        #expect(broken.error?.message.contains("- \(page)") == true, "\(broken.error?.message ?? "") lacks \(page)")
        #expect(rig.asked.count == 1, "a failed check asks nothing")
    }

    @Test("ext install asks naming the folder, the files, the commands and what it replaces; Deny copies nothing; Allow installs with no reload")
    func install() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        #expect(await rig.ask("ext", "new", "demo").ok)
        let source = rig.work.appending(path: "demo")
        let target = rig.tools.extensions.appending(path: "demo")

        let denied = await rig.ask("ext", "install", "demo")
        #expect(denied.error?.code == .denied)
        #expect(!FileManager.default.fileExists(atPath: target.path), "Deny copies nothing")
        let question = try #require(rig.asked.last)
        #expect(question.title == "Install extension")
        for part in ["demo (Demo 0.1.0) from \(source.path)", "into \(target.path)", "programs: main.py (runs items)",
                     "other files: extension.json; 2 files in all", "commands, run as you: ext.demo.items (list) runs main.py",
                     "replaces nothing: no extension demo is installed"] {
            #expect(question.detail.contains(part), "\(part) missing from \(question.text)")
        }
        #expect(!rig.actionIDs().contains("ext.demo.items"))

        rig.allow = true
        let installed = await rig.ask("ext", "install", "demo")
        #expect(installed.ok, "\(installed.error?.message ?? "")")
        #expect(Self.field(installed, "folder") == .string(target.path))
        #expect(Self.field(installed, "replaced") == .array([]))
        #expect(rig.installedIDs() == ["demo"])
        #expect(try Data(contentsOf: target.appending(path: "main.py")) == Data(contentsOf: source.appending(path: "main.py")))
        #expect(rig.actionIDs().contains("ext.demo.items"), "listed with no reload")

        // A second install replaces the first: the old copy goes to the Trash, the data folder stays.
        let data = rig.tools.data.appending(path: "demo")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: data.appending(path: "todos.json"))
        let manifest = source.appending(path: "extension.json")
        try String(contentsOf: manifest, encoding: .utf8).replacing(#""version": "0.1.0""#, with: #""version": "0.2.0""#)
            .write(to: manifest, atomically: true, encoding: .utf8)
        let again = await rig.ask("ext", "install", source.path)
        #expect(again.ok, "\(again.error?.message ?? "")")
        #expect(Self.field(again, "replaced") == .array([.string(target.resolvingSymlinksInPath().path)]))
        #expect(rig.asked.last?.detail.contains("replaces demo (Demo 0.1.0) at \(target.resolvingSymlinksInPath().path), which goes to the Trash; its data and settings stay") == true,
                "\(rig.asked.last?.text ?? "")")
        #expect(try Extension(folder: target).version == "0.2.0")
        let trashed = try rig.trashed()
        #expect(trashed.count == 1 && trashed[0].hasSuffix("-demo"))
        #expect(try Extension(folder: rig.trash.appending(path: trashed[0])).version == "0.1.0", "the old copy is in the Trash")
        #expect(try Data(contentsOf: data.appending(path: "todos.json")) == Data("kept".utf8))
    }

    @Test("A file changed while the question is up installs nothing: each is checked against the bytes the question listed")
    func changedWhileAsking() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        #expect(await rig.ask("ext", "new", "demo").ok)
        rig.allow = true
        let source = rig.work.appending(path: "demo")
        let shownMain = try Data(contentsOf: source.appending(path: "main.py")), shownManifest = try Data(contentsOf: source.appending(path: "extension.json"))
        // While the question is up, the manifest is swapped for one with another command and main.py changes.
        rig.whileAsking = {
            try Data("#!/usr/bin/env python3\nprint('swapped')\n".utf8).write(to: source.appending(path: "main.py"))
            try ExtensionToolingTests.edit(source.appending(path: "extension.json"), #""commands": ["#,
                                           #""commands": [{ "name": "swapped", "title": "Swapped", "mode": "no-view", "run": "main.py" }, "#)
        }
        let answer = await rig.ask("ext", "install", "demo")
        #expect(answer.ok, "\(answer.error?.message ?? "")")
        #expect(rig.asked.last?.detail.contains("swapped") == false)
        let target = rig.tools.extensions.appending(path: "demo")
        #expect(try Data(contentsOf: target.appending(path: "main.py")) == shownMain, "what installs is what was asked about")
        #expect(try Data(contentsOf: target.appending(path: "extension.json")) == shownManifest)
        #expect(try Extension(folder: target).commands.map(\.name) == ["items"])
    }

    static func edit(_ file: URL, _ old: String, _ new: String) throws {
        try String(contentsOf: file, encoding: .utf8).replacing(old, with: new).write(to: file, atomically: true, encoding: .utf8)
    }

    @Test("The install question names every file: what commands run and every executable first, then the rest; too many to show is denied unasked")
    func everyFileNamed() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        #expect(await rig.ask("ext", "new", "demo").ok)
        let source = rig.work.appending(path: "demo")
        try FileManager.default.createDirectory(at: source.appending(path: "lib"), withIntermediateDirectories: true)
        try Data("def help():\n    return 1\n".utf8).write(to: source.appending(path: "lib/helper.py"))
        try Data("#!/bin/sh\n".utf8).write(to: source.appending(path: "lib/tool.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appending(path: "lib/tool.sh").path)
        #expect(await rig.ask("ext", "install", "demo").error?.code == .denied)
        let detail = try #require(rig.asked.last).detail
        #expect(detail.contains("programs: lib/tool.sh (executable), main.py (runs items)"), "\(detail)")
        #expect(detail.contains("other files: extension.json, lib/helper.py; 4 files in all"), "\(detail)")

        // Fifty more long names: the question cannot be shown whole, so the gate denies it without showing it.
        for i in 0..<50 { try Data().write(to: source.appending(path: "lib/a-module-with-a-long-name-\(i).py")) }
        let asked = rig.asked.count
        let tooMany = await rig.ask("ext", "install", "demo")
        #expect(tooMany.error?.code == .denied && tooMany.error?.message.hasPrefix("not asked:") == true, "\(tooMany.error?.message ?? "")")
        #expect(rig.asked.count == asked)
        #expect(rig.installedIDs().isEmpty)
    }

    @Test("ext new never makes a folder in Pilot's Extensions folder, which would be live with no Allow: it points to ext install")
    func newOutsideExtensions() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        let extensions = rig.tools.extensions
        try FileManager.default.createDirectory(at: extensions.appending(path: "sub"), withIntermediateDirectories: true)
        // The rig's folder is under /private/var (realpath's spelling); /System/Volumes/Data/private/var is the same folder
        // through a firmlink, which no symlink resolution maps back.
        let real = try #require(realpath(extensions.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        #expect(real.hasPrefix("/private/var/") && FileManager.default.fileExists(atPath: "/System/Volumes/Data" + real))
        // Symlinks to it, into it, and to its parent: each folder on the path is judged by what it points to.
        let fm = FileManager.default
        try fm.createSymbolicLink(at: rig.work.appending(path: "link"), withDestinationURL: extensions)
        try fm.createSymbolicLink(at: rig.work.appending(path: "sublink"), withDestinationURL: extensions.appending(path: "sub"))
        try fm.createSymbolicLink(at: rig.work.appending(path: "homelink"), withDestinationURL: extensions.deletingLastPathComponent())
        for dir in [extensions.path, extensions.appending(path: "sub").path, extensions.path.uppercased(), "home/Extensions/../Extensions",
                    "/System/Volumes/Data" + real, "/System/Volumes/Data" + real + "/sub",
                    "link", "link/sub", "link/new", rig.work.appending(path: "link").path, "sublink", "homelink/Extensions", "homelink/Extensions/sub"] {
            let answer = await rig.ask("ext", "new", "demo", "--dir", dir)
            #expect(answer.error?.code == .badValue && answer.error?.message.contains("pilot ext install") == true, "\(dir): \(answer)")
        }
        let fromInside = await rig.verbs.answer(ControlRequest(verb: "ext", args: ["new", "demo"], cwd: extensions.path), peer: nil)
        #expect(fromInside.error?.code == .badValue, "a cwd in the Extensions folder is refused too")
        let made = FileManager.default.enumerator(atPath: extensions.path)?.compactMap { $0 as? String } ?? []
        #expect(made == ["sub"], "nothing made there: \(made)")
        #expect(!fm.fileExists(atPath: extensions.appending(path: "new").path))
        #expect(await rig.ask("ext", "new", "demo", "--dir", rig.work.path).ok, "a folder elsewhere is fine")
    }

    @Test("ext install leaves a planted symlink behind and refuses a path the installer would write outside its folder")
    func installEntryRules() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        #expect(await rig.ask("ext", "new", "demo").ok)
        let source = rig.work.appending(path: "demo")
        let secret = rig.work.appending(path: "secret.txt")
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: source.appending(path: "escape"), withDestinationURL: secret)
        rig.allow = true
        #expect(await rig.ask("ext", "install", "demo").ok)
        let target = rig.tools.extensions.appending(path: "demo")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() == ["extension.json", "main.py"])
        #expect(rig.asked.last?.detail.contains("escape") == false)

        try Data().write(to: source.appending(path: #"lib\up.txt"#))
        let asked = rig.asked.count
        let refused = await rig.ask("ext", "install", "demo")
        #expect(refused.error?.message.contains("leaves its folder") == true, "\(refused.error?.message ?? "")")
        #expect(rig.asked.count == asked, "nothing asked")
    }

    @Test("ext install refuses a folder that fails the check, or holds a file the installer would refuse, and asks nothing")
    func installChecks() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        #expect(await rig.ask("ext", "new", "demo").ok)
        let manifest = rig.work.appending(path: "demo/extension.json")
        try String(contentsOf: manifest, encoding: .utf8).replacing(#""version": "0.1.0""#, with: #""version": "one""#)
            .write(to: manifest, atomically: true, encoding: .utf8)
        let answer = await rig.ask("ext", "install", "demo")
        #expect(answer.error?.message.contains("- version must be x.y.z") == true)

        // check.py takes a file up to 2 MiB, the installer up to 2 MB: one between is refused before asking.
        try String(contentsOf: manifest, encoding: .utf8).replacing(#""version": "one""#, with: #""version": "0.1.0""#)
            .write(to: manifest, atomically: true, encoding: .utf8)
        try Data(count: ExtensionCatalogue.fileLimit + 1).write(to: rig.work.appending(path: "demo/data.bin"))
        let big = await rig.ask("ext", "install", "demo")
        #expect(big.error?.message.contains("data.bin is larger than") == true, "\(big.error?.message ?? "")")
        #expect(rig.asked.isEmpty && rig.installedIDs().isEmpty)
    }

    @Test("ext remove asks naming the folder and the data that stays; Deny keeps it; Allow sends it to the Trash and leaves ExtensionData")
    func remove() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        #expect(await rig.ask("ext", "new", "demo").ok)
        rig.allow = true
        #expect(await rig.ask("ext", "install", "demo").ok)
        let data = rig.tools.data.appending(path: "demo")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: data.appending(path: "preferences.json"))
        let target = rig.tools.extensions.appending(path: "demo")

        rig.allow = false
        #expect(await rig.ask("ext", "remove", "demo").error?.code == .denied)
        #expect(rig.installedIDs() == ["demo"])
        let question = try #require(rig.asked.last)
        #expect(question.title == "Remove extension")
        for part in ["demo (Demo 0.1.0) at \(target.path) goes to the Trash", "ext.demo.items (list) runs main.py", "stay in \(data.path)"] {
            #expect(question.detail.contains(part), "\(part) missing from \(question.text)")
        }

        rig.allow = true
        let removed = await rig.ask("ext", "remove", "demo")
        #expect(removed.ok, "\(removed.error?.message ?? "")")
        #expect(rig.installedIDs().isEmpty)
        #expect(try rig.trashed().count == 1)
        #expect(try Data(contentsOf: data.appending(path: "preferences.json")) == Data("kept".utf8))
        #expect(!rig.actionIDs().contains("ext.demo.items"))
        #expect(await rig.ask("ext", "remove", "demo").error?.code == .badValue, "nothing left to remove, nothing asked")
        #expect(rig.asked.count == 3)
    }

    // MARK: CLI W15

    @Test("ext test and ext install read a folder outside the temporary folders and ~/Downloads only after Allow; Deny reads nothing")
    func readGate() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        #expect(await rig.ask("ext", "new", "demo").ok)
        #expect(await rig.ask("ext", "test", "demo", "--check").ok && rig.asked.isEmpty, "the temporary folder is read without asking")
        rig.tools.readable = []
        let folder = rig.work.appending(path: "demo").path
        for words in [["test", "demo", "--check"], ["test", "demo"], ["install", "demo"]] {
            let answer = await rig.verbs.answer(ControlRequest(verb: "ext", args: words, cwd: rig.work.path), peer: nil)
            #expect(answer.error?.code == .denied && answer.error?.message.contains("Read folder") == true, "\(words)")
            #expect(Self.field(answer, "check") == nil)
        }
        #expect(rig.asked.map(\.title) == ["Read folder", "Read folder", "Read folder"])
        #expect(rig.asked[0].detail.contains(folder) && rig.asked[0].detail.contains("only the check's summary"))
        rig.allow = true
        let checked = await rig.ask("ext", "test", "demo", "--check")
        #expect(checked.ok && rig.asked.count == 4)
    }

    @Test("The read gate holds against a link out of an allowed folder, a linked extension.json, a .. path and a look-alike of an allowed folder")
    func readGateEscapes() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        let fm = FileManager.default
        // Allowed: work/Downloads only. Elsewhere: work/secret, with an extension that must never be read unasked.
        let allowed = rig.work.appending(path: "Downloads"), secret = rig.work.appending(path: "secret")
        for dir in [allowed, secret, rig.work.appending(path: "Downloads-evil")] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        rig.tools.readable = [allowed]
        #expect(await rig.ask("ext", "new", "leaked-id", "--dir", secret.path).ok)
        let hidden = secret.appending(path: "leaked-id")
        #expect(await rig.ask("ext", "new", "evil", "--dir", rig.work.appending(path: "Downloads-evil").path).ok)
        try fm.createSymbolicLink(at: allowed.appending(path: "link"), withDestinationURL: hidden)
        let asked = rig.asked.count
        for path in [allowed.appending(path: "link").path, allowed.path + "/../secret/leaked-id", rig.work.appending(path: "Downloads-evil/evil").path] {
            for words in [["test", path, "--check"], ["install", path]] {
                let answer = await rig.verbs.answer(ControlRequest(verb: "ext", args: words, cwd: rig.work.path), peer: nil)
                #expect(answer.error?.code == .denied && answer.error?.message.contains("Read folder") == true && answer.result == nil, "\(words): \(answer)")
            }
        }
        #expect(rig.asked.count == asked + 6 && rig.asked.suffix(6).allSatisfy { $0.title == "Read folder" })
        #expect(rig.asked.last?.detail.contains("Downloads-evil") == true && rig.asked[asked].detail.contains(hidden.path), "the link is asked about where it leads")

        // A linked extension.json in an allowed folder is never followed: the copy has none, so nothing of it comes back.
        let planted = allowed.appending(path: "planted")
        try fm.createDirectory(at: planted, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: planted.appending(path: Extension.manifestName), withDestinationURL: hidden.appending(path: Extension.manifestName))
        for words in [["test", planted.path, "--check"], ["install", planted.path]] {
            let answer = await rig.verbs.answer(ControlRequest(verb: "ext", args: words, cwd: rig.work.path), peer: nil)
            #expect(answer.error?.code == .badValue && answer.error?.message.contains("no extension.json") == true, "\(words): \(answer)")
            #expect(try !Self.text(answer).contains("leaked-id"))
        }
        #expect(rig.asked.count == asked + 6, "an allowed folder asks nothing")
    }

    static func text(_ answer: ControlAnswer) throws -> String { try String(decoding: JSONEncoder().encode(answer), as: UTF8.self) }

    @Test("ext show answers the card: version, description, examples, what it touches, commands, preferences still needed; ext broken the folders not read")
    func showsCard() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        try rig.probe()
        let shown = await rig.ask("ext", "show", "probe")
        #expect(shown.ok, "\(shown.error?.message ?? "")")
        #expect(Self.field(shown, "version") == .string("1.2.0") && Self.field(shown, "icon") == .string("🔭"))
        #expect(Self.field(shown, "description") == .string("Looks at things.") && Self.field(shown, "examples") == .array([.string("Type probe")]))
        #expect(Self.field(shown, "touches") == .array([.string("Connects to api.example.com"), .string("Reads and writes the clipboard")]))
        #expect(Self.field(shown, "needs") == .array([.string("who")]) && Self.field(shown, "page") == .bool(true))
        guard case .array(let commands)? = Self.field(shown, "commands") else { Issue.record("no commands"); return }
        #expect(commands.count == 4, "the hidden page command is left out, as on the card")
        #expect(commands.first == .object(["action": .string("ext.probe.say"), "name": .string("say"), "title": .string("Say"), "mode": .string("no-view"),
                                           "does": .string("Runs and shows one line"), "keyword": .string("say")]))
        #expect(await rig.ask("ext", "show", "nope").error?.message.contains("installed: probe") == true)

        let broken = rig.tools.extensions.appending(path: "junk")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        guard case .array(let rows)? = await rig.ask("ext", "broken").result, case .object(let row)? = rows.first else { Issue.record("no broken row"); return }
        #expect(rows.count == 1 && row["why"] == .string("no extension.json"))
        #expect(rig.asked.isEmpty)
    }

    @Test("ext open opens its page, or its card with --card or when it has no page")
    func opens() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        try rig.probe()
        #expect(Self.field(await rig.ask("ext", "open", "probe"), "on") == .string("page"))
        #expect(Self.field(await rig.ask("ext", "open", "probe", "--card"), "on") == .string("card"))
        #expect(rig.opened.map(\.0) == ["probe", "probe"] && rig.opened.map(\.1) == [true, false])
        #expect(await rig.ask("ext", "open", "nope").error?.code == .badValue && rig.opened.count == 2)
    }

    @Test("ext run asks first, runs once and answers what it printed; Deny runs nothing; a missing preference says so")
    func runs() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        try rig.probe()
        let denied = await rig.ask("ext", "run", "ext.probe.say")
        #expect(denied.error?.code == .denied && !rig.ran("say"))
        #expect(rig.asked.last?.title == "Run extension command Probe › Say")
        rig.allow = true
        #expect(await rig.ask("ext", "run", "ext.probe.say").error?.message.contains("Probe needs Who set first") == true, "the required preference")
        #expect(await rig.ask("add", "ext-prefs", "--pref", "probe.who", "--value", "me").ok)

        let said = await rig.ask("ext", "run", "ext.probe.say")
        #expect(Self.field(said, "shows") == .string("said it") && rig.ran("say"), "\(said.error?.message ?? "")")
        let acts = await rig.ask("ext", "run", "ext.probe.acts")
        #expect(Self.field(acts, "actions") == .array([.object(["does": .string("Copy"), "text": .string("copied")]),
                                                         .object(["does": .string("Open"), "target": .string("https://example.com")])]))
        #expect(Self.field(acts, "note") == .string("not performed: pilot run ext.probe.acts performs them"))
        let picked = await rig.ask("ext", "run", "ext.probe.pick", "--query", "on")
        #expect(Self.field(picked, "items") == .array([.object(["title": .string("One"), "subtitle": .string("first"), "actions": .array([.object(["does": .string("Copy"), "text": .string("one")])])]),
                                                       .object(["title": .string("Two"), "actions": .array([])])]))
        #expect(rig.asked.last?.detail.hasSuffix(", search on") == true, "\(rig.asked.last?.text ?? "")")
        #expect(await rig.ask("ext", "run", "ext.probe.nope").error?.code == .unknownAction)
        // A failed exit answers a fixed line: its stderr can hold anything, so it stays in the log.
        let boom = await rig.ask("ext", "run", "ext.probe.boom")
        #expect(boom.error?.message == "ext.probe.boom stopped with an error; Pilot's log says why" && rig.ran("boom"), "\(boom)")
    }

    @Test("ext page asks first and answers its blocks; nothing is read back while a password preference is set, and nothing runs")
    func pages() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        try rig.probe()
        rig.allow = true
        #expect(await rig.ask("add", "ext-prefs", "--pref", "probe.who", "--value", "me").ok)
        let page = await rig.ask("ext", "page", "probe")
        #expect(page.ok, "\(page.error?.message ?? "")")
        #expect(Self.field(page, "blocks") == .array([.object(["type": .string("markdown"), "text": .string("# Hi")])]) && Self.field(page, "refresh") == .number(30))
        #expect(rig.asked.last?.detail.hasSuffix(", for its page") == true)

        try rig.keychain.setPassword("s3cret", extension: "probe", preference: "token")
        let asked = rig.asked.count
        for words in [["page", "probe"], ["run", "ext.probe.say"]] {
            let answer = await rig.verbs.answer(ControlRequest(verb: "ext", args: words, cwd: rig.work.path), peer: nil)
            #expect(answer.error?.code == .denied && answer.error?.message.contains("password preference set (token)") == true, "\(words)")
        }
        #expect(rig.asked.count == asked && !rig.ran("say"), "refused before asking or running")
        #expect(rig.keychain.reads.withLock { $0 } == 1, "only the one page run read it, to hand it to the program")
    }

    @Test("ext catalogue lists and searches the catalogue with each entry's standing; ext get asks, installs, then updates; offline is not-ready")
    func catalogueInstall() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        let offline = await rig.ask("ext", "catalogue")
        #expect(offline.error?.code == .notReady && offline.error?.message.contains("offline") == true, "\(offline.error?.message ?? "")")

        try rig.offer(version: "1.0.0")
        let listed = await rig.ask("ext", "catalogue", "--refresh")
        guard case .array(let entries)? = Self.field(listed, "entries"), case .object(let cat)? = entries.first else { Issue.record("no entries: \(listed)"); return }
        #expect(cat["id"] == .string("cat") && cat["standing"] == .string("install") && cat["button"] == .string("Install"))
        #expect(cat["needs"] == .string("Needs python3") && cat["files"] == .number(2))
        #expect(Self.field(await rig.ask("ext", "catalogue", "nothing-like-it"), "count") == .number(0))

        let denied = await rig.ask("ext", "get", "cat")
        #expect(denied.error?.code == .denied && rig.installedIDs().isEmpty)
        let question = try #require(rig.asked.last)
        #expect(question.title == "Install extension" && question.detail.contains("programs: meow") && question.detail.contains("ext.cat.meow (no-view)"))
        #expect(question.detail.contains("replaces nothing"))

        rig.allow = true
        let got = await rig.ask("ext", "get", "cat")
        #expect(got.ok && Self.field(got, "commands") == .array([.string("ext.cat.meow")]) && Self.field(got, "updatedFrom") == nil, "\(got.error?.message ?? "")")
        #expect(Self.field(got, "version") == .string("1.0.0"), "the version read back from the installed manifest")
        #expect(rig.installedIDs() == ["cat"])
        let again = await rig.ask("ext", "get", "cat")
        #expect(Self.field(again, "changed") == .bool(false))

        try rig.offer(version: "1.1.0")
        guard case .array(let now)? = Self.field(await rig.ask("ext", "catalogue", "--refresh"), "entries"), case .object(let row)? = now.first else { Issue.record("no entries"); return }
        #expect(row["standing"] == .string("update") && row["installedVersion"] == .string("1.0.0"))
        let updated = await rig.ask("ext", "get", "cat")
        #expect(Self.field(updated, "updatedFrom") == .string("1.0.0") && Self.field(updated, "version") == .string("1.1.0"))
        #expect(rig.asked.last?.detail.contains("updates 1.0.0 at") == true)
        #expect(await rig.ask("ext", "get", "dog").error?.message.contains("no extension dog") == true)
    }

    @Test("Each real catalogue entry's pinned manifest matches its index, and its ext get question is short enough to be asked",
          .enabled(if: FileManager.default.fileExists(atPath: catalogue.deletingLastPathComponent().appending(path: "index.json").path)))
    func catalogueGetQuestions() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        let root = Self.catalogue.deletingLastPathComponent()
        let index = try ExtensionCatalogue.index(Data(contentsOf: root.appending(path: "index.json")))
        #expect(!index.entries.isEmpty)
        // The checkout as GitHub serves it.
        rig.shelf.files.withLock { files in
            for entry in index.entries { for file in entry.files { files["extensions/\(entry.id)/\(file.path)"] = try? Data(contentsOf: root.appending(path: "extensions/\(entry.id)/\(file.path)")) } }
        }
        for entry in index.entries {
            let commands = try await rig.tools.pinnedCommands(entry)
            #expect(commands.filter { !$0.hasSuffix(", hidden)") }.count == entry.commands.count, "\(entry.id): the index lists the shown ones")
            let text = rig.tools.catalogueAsk(entry, nil, commands).text
            let length = text.unicodeScalars.count, lines = text.count { $0 == "\n" }
            #expect(length <= ControlGate.Ask.longest && lines <= ControlGate.Ask.mostLines, "\(entry.id): \(length) characters, \(lines) line breaks")
        }
    }

    @Test("ext get refuses before asking when the index's commands differ from the extension.json it pins, or that file does not match")
    func catalogueMismatch() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        try rig.offer(version: "1.0.0", manifestCommand: "purr")
        let lied = await rig.ask("ext", "get", "cat")
        #expect(lied.error?.code == .badValue && lied.error?.message.contains("other commands than its extension.json declares") == true, "\(lied)")
        try rig.offer(version: "1.0.0")
        rig.shelf.files.withLock { $0["extensions/cat/extension.json"] = Data("{}".utf8) }
        let swapped = await rig.ask("ext", "get", "cat")
        #expect(swapped.error?.code == .badValue && swapped.error?.message.contains("checksum") == true, "\(swapped)")
        #expect(rig.asked.isEmpty && rig.installedIDs().isEmpty)
    }

    @Test("Staging reads only the files it listed: one swapped for a link, or under a folder swapped for one, is refused unread")
    func stageRefusesSwaps() throws {
        let rig = try Rig()
        defer { rig.clean() }
        let fm = FileManager.default
        let folder = rig.work.appending(path: "demo"), elsewhere = rig.work.appending(path: "elsewhere")
        try fm.createDirectory(at: folder.appending(path: "lib"), withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere.appending(path: "lib"), withIntermediateDirectories: true)
        try Data(#"{"id": "demo"}"#.utf8).write(to: folder.appending(path: Extension.manifestName))
        try Data("x = 1\n".utf8).write(to: folder.appending(path: "lib/x.py"))
        try Data(#"{"id": "leaked-id"}"#.utf8).write(to: elsewhere.appending(path: "secret.json"))
        try Data("leaked = 1\n".utf8).write(to: elsewhere.appending(path: "lib/x.py"))
        let listed = Dictionary(uniqueKeysWithValues: ExtensionCheck.listing(folder).map { ($0.path, $0) })
        let manifest = try #require(listed[Extension.manifestName]), module = try #require(listed["lib/x.py"])
        #expect(try ExtensionCheck.read(manifest, limit: 100) == Data(#"{"id": "demo"}"#.utf8), "unchanged reads")

        try fm.removeItem(at: folder.appending(path: Extension.manifestName))
        try fm.createSymbolicLink(at: folder.appending(path: Extension.manifestName), withDestinationURL: elsewhere.appending(path: "secret.json"))
        try fm.moveItem(at: folder.appending(path: "lib"), to: rig.work.appending(path: "lib-moved"))
        try fm.createSymbolicLink(at: folder.appending(path: "lib"), withDestinationURL: elsewhere.appending(path: "lib"))
        for file in [manifest, module] {
            #expect(throws: ExtensionCatalogue.Problem.failed("\(file.path) changed while it was read")) { try ExtensionCheck.read(file, limit: 100) }
        }
        #expect(throws: ExtensionCatalogue.Problem.tooBig(path: "x.py", limit: 3), "more than the limit is too big") {
            try ExtensionCheck.read(ExtensionCheck.listing(rig.work.appending(path: "lib-moved"))[0], limit: 3)
        }
    }

    @Test("ext declares its flags: a typo is refused before anything runs; help names each subcommand")
    func flags() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        #expect(await rig.ask("ext", "catalogue", "--refrsh").error?.code == .unknownFlag)
        let help = try #require(try rig.verbs.verb("ext").detail?("get"))
        #expect(help.hasPrefix("pilot ext get <id>"))
    }
}
