import Foundation
import Testing
@testable import PilotCore

/// AI helper T10: `pilot ext test`'s check is the catalogue's scripts/check.py in Swift, and its runs are Pilot's own.
/// The catalogue (the repo's catalogue/) is only read: check.py runs with -B, so it writes no __pycache__ there, and
/// every broken manifest is a copy in a temporary folder. Only the templates' commands run.
@Suite("Extension check")
struct ExtensionCheckTests {
    static let catalogue = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../catalogue").standardizedFileURL
    static let checkScript = catalogue.appending(path: "scripts/check.py")
    static let hasCatalogue = FileManager.default.fileExists(atPath: checkScript.path)
    static let templates = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/ext-template").standardizedFileURL

    /// check.py's own `check(folder)` on each folder, one JSON list a line.
    private static let pyCheck = """
        import importlib.util, json, sys
        from pathlib import Path
        spec = importlib.util.spec_from_file_location("check", sys.argv[1])
        check = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(check)
        for folder in sys.argv[2:]:
            print(json.dumps(check.check(Path(folder))))
        """

    static func python(_ folders: [URL]) async throws -> [[String]] {
        let output = try await ChildProcess.run("/usr/bin/env", ["python3", "-I", "-B", "-c", pyCheck, checkScript.path] + folders.map(\.path),
                                                timeout: .seconds(30))
        return try output.split(separator: "\n").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    }

    /// A temporary folder holding `mode`'s template as extension `id`; each test removes `parent` when it ends.
    static func made(_ mode: ExtensionTemplate = .list, id: String = "demo") throws -> (folder: URL, parent: URL) {
        let parent = FileManager.default.temporaryDirectory.appending(path: "pilot-ext-check-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return (try mode.make(id: id, templates: templates, in: parent), parent)
    }

    static func remove(_ parent: URL) { try? FileManager.default.removeItem(at: parent) }

    @Test("Each catalogue extension (18 today) passes, as python3 scripts/check.py says", .enabled(if: hasCatalogue))
    func catalogueAgrees() async throws {
        let folders = try FileManager.default.contentsOfDirectory(at: Self.catalogue.appending(path: "extensions"), includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
        #expect(!folders.isEmpty)
        let python = try await Self.python(folders)
        for (folder, theirs) in zip(folders, python) {
            #expect(ExtensionCheck.problems(in: folder) == theirs, "\(folder.lastPathComponent)")
            #expect(theirs.isEmpty, "\(folder.lastPathComponent): \(theirs)")
        }
    }

    /// One fault each, made in a copy of the list template.
    static let faults: [(name: String, edit: @Sendable (URL) throws -> Void)] = [
        ("bad id", { try manifest($0) { $0["id"] = .string("Demo_X") } }),
        ("unknown mode", { try command($0) { $0["mode"] = .string("grid") } }),
        ("missing program", { try command($0) { $0["run"] = .string("nope.py") } }),
        ("no commands", { try manifest($0) { $0["commands"] = .array([]) } }),
        ("bad version", { try manifest($0) { $0["version"] = .string("1.0") } }),
        ("three examples", { try manifest($0) { $0["examples"] = .array(["a", "b", "c"].map(JSONValue.string)) } }),
        ("dropdown with no options", { try manifest($0) { $0["preferences"] = .array([.object(["name": .string("unit"), "title": .string("Unit"), "type": .string("dropdown")])]) } }),
        ("surface naming no command", { try manifest($0) { $0["surfaces"] = .object(["bar": .object(["command": .string("nope")])]) } }),
        ("keyword on a list", { try command($0) { $0["keyword"] = .string("demo") } }),
        ("every command hidden", { try command($0) { $0["hidden"] = .bool(true) } }),
        ("wrong shebang", { url in
            let main = url.appending(path: "main.py")
            let text = try String(contentsOf: main, encoding: .utf8).replacing("#!/usr/bin/env python3", with: "#!/usr/bin/python3", maxReplacements: 1)
            try text.write(to: main, atomically: true, encoding: .utf8)
        }),
        ("CRLF shebang", { url in
            let main = url.appending(path: "main.py")
            let text = try String(contentsOf: main, encoding: .utf8).replacing("#!/usr/bin/env python3\n", with: "#!/usr/bin/env python3\r\n", maxReplacements: 1)
            try text.write(to: main, atomically: true, encoding: .utf8)
        }),
        // Printable bytes: NULs would be check.py's hidden text too.
        ("file over 2 MB", { try Data(repeating: 0x61, count: ExtensionCheck.fileLimit + 1).write(to: $0.appending(path: "big.bin")) }),
    ]

    static func manifest(_ folder: URL, _ change: (inout [String: JSONValue]) -> Void) throws {
        let url = folder.appending(path: Extension.manifestName)
        guard case .object(var m) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)) else { throw CocoaError(.fileReadCorruptFile) }
        change(&m)
        try JSONEncoder().encode(JSONValue.object(m)).write(to: url)
    }

    static func command(_ folder: URL, _ change: @escaping (inout [String: JSONValue]) -> Void) throws {
        try manifest(folder) { m in
            guard case .array(var commands)? = m["commands"], case .object(var first) = commands[0] else { return }
            change(&first)
            commands[0] = .object(first)
            m["commands"] = .array(commands)
        }
    }

    @Test("A broken manifest fails with the reason the Extensions page shows, then check.py's own words")
    func brokenManifests() async throws {
        var folders: [URL] = [], parents: [URL] = []
        defer { parents.forEach(Self.remove) }
        for fault in Self.faults {
            let (folder, parent) = try Self.made()
            parents.append(parent)
            try fault.edit(folder)
            folders.append(folder)
            let problems = ExtensionCheck.problems(in: folder)
            #expect(!problems.isEmpty, "\(fault.name)")
            // The page lists the folders Extension.find could not read, each with its problem's reason.
            if let page = Extension.find(in: parent).broken.first?.problem.reason {
                #expect(problems.first == page, "\(fault.name)")
            }
        }
        let byPage = folders.filter { !Extension.find(in: $0.deletingLastPathComponent()).broken.isEmpty }.count
        #expect(byPage == 6, "the faults Pilot itself refuses: id, mode, program, no commands, dropdown, surface")
        guard Self.hasCatalogue else { return }
        for (i, theirs) in try await Self.python(folders).enumerated() {
            // check.py's hidden-text rule (public-repo spec T18) has no Swift twin yet, so a CR in a file is check.py's
            // alone: known until ExtensionCheck catches up, and this fails once it does.
            withKnownIssue("ExtensionCheck lacks check.py's hidden-text rule") {
                #expect(ExtensionCheck.catalogue(folders[i]) == theirs, "\(Self.faults[i].name)")
                #expect(Set(theirs).isSubset(of: ExtensionCheck.problems(in: folders[i])), "\(Self.faults[i].name)")
            } when: { Self.faults[i].name == "CRLF shebang" }
        }
    }

    @Test("Every template, made as demo, passes the check and check.py, compiles on macOS's Python 3.9, and each command answers")
    func templates() async throws {
        for mode in ExtensionTemplate.allCases {
            let (folder, parent) = try Self.made(mode)
            defer { Self.remove(parent) }
            #expect(ExtensionCheck.problems(in: folder) == [], "\(mode)")
            let ext = try Extension(folder: folder)
            #expect(ext.id == "demo" && ext.title == "Demo", "\(mode)")
            #expect(ext.commands.allSatisfy { FileManager.default.isExecutableFile(atPath: $0.program.path) })
            _ = try await ChildProcess.run("/usr/bin/python3", ["-I", "-B", "-c", "import ast, sys; ast.parse(open(sys.argv[1]).read())",
                                                                folder.appending(path: "main.py").path], timeout: .seconds(10))
            if Self.hasCatalogue { #expect(try await Self.python([folder]) == [[]], "\(mode)") }
            let runs = await ExtensionCheck.runs(ext)
            #expect(runs.count == ext.commands.count)
            for run in runs { #expect(run.ok && run.why == nil, "\(mode) \(run.command): \(run.why ?? "") \(run.first)") }
            let first = runs.map(\.first).joined()
            switch mode {
            case .list: #expect(runs.map(\.ranAs) == ["list"] && first.contains(#""type": "list""#))
            case .noView: #expect(runs.map(\.ranAs) == ["no-view"] && first.contains("Hello from demo"))
            case .detail: #expect(runs.map(\.ranAs) == ["detail"] && first.contains(#""type": "detail""#))
            case .bar: #expect(runs.map(\.ranAs) == ["no-view", "bar"] && runs[1].first.contains(#""type": "bar""#))
            }
        }
    }

    @Test("A title may be given, and a taken folder or a bad id makes nothing")
    func making() throws {
        let (folder, parent) = try Self.made()
        defer { Self.remove(parent) }
        let titled = try ExtensionTemplate.detail.make(id: "dash-board", title: #"My "Board""#, templates: Self.templates, in: parent)
        #expect(try Extension(folder: titled).title == #"My "Board""#)
        #expect(try ExtensionTemplate.bar.make(id: "two-words", templates: Self.templates, in: parent).lastPathComponent == "two-words")
        #expect(try Extension(folder: parent.appending(path: "two-words")).title == "Two words")
        #expect(throws: (any Error).self) { try ExtensionTemplate.list.make(id: "demo", templates: Self.templates, in: parent) }
        #expect(throws: Extension.Problem.badID("Bad")) { try ExtensionTemplate.list.make(id: "Bad", templates: Self.templates, in: parent) }
        #expect(!FileManager.default.fileExists(atPath: parent.appending(path: "Bad").path))
        #expect(FileManager.default.fileExists(atPath: folder.path), "the taken folder is left as it was")
    }

    @Test("A run fails on a line outside the protocol, a slow answer, a failed exit or no answer; its own error message is an answer")
    func failingRuns() async throws {
        let (folder, parent) = try Self.made()
        defer { Self.remove(parent) }
        let main = folder.appending(path: "main.py")
        func runs(_ body: String) async throws -> ExtensionCheck.Run {
            try Data("#!/usr/bin/env python3\nimport sys, time, json\nsys.stdin.readline()\n\(body)\n".utf8).write(to: main)
            return await ExtensionCheck.runs(try Extension(folder: folder))[0]
        }
        let plain = try await runs("print('hello')")
        #expect(!plain.ok && plain.why?.contains("outside the protocol") == true)
        let slow = try await runs("time.sleep(3)")
        #expect(!slow.ok && slow.why == "did not answer in 2 s")
        let exit = try await runs("sys.exit(2)")
        #expect(!exit.ok && exit.why?.contains("stopped with an error") == true)
        let silent = try await runs("pass")
        #expect(!silent.ok, "a list that sends no list: \(silent.why ?? "")")
        let own = try await runs(#"print(json.dumps({"type": "error", "text": "gh is not signed in"}))"#)
        #expect(own.ok && own.first.contains("gh is not signed in"))
    }

    @Test("A required preference with no default runs nothing, and every command fails")
    func unsetPreference() async throws {
        let (folder, parent) = try Self.made(.bar)
        defer { Self.remove(parent) }
        try Self.manifest(folder) { $0["preferences"] = .array([.object(["name": .string("token"), "title": .string("Token"), "type": .string("text"), "required": .bool(true)])]) }
        let runs = await ExtensionCheck.runs(try Extension(folder: folder))
        #expect(runs.map(\.command) == ["now", "bar"])
        #expect(runs.allSatisfy { !$0.ok && $0.first.isEmpty && $0.why == "not run: Demo needs Token set first." }, "\(runs)")
    }

    @Test("An install's entry holds to the catalogue's rules: a symlink is never taken, a path with a backslash (the catalogue's unsafe path) or past 200 files refuses")
    func entryRules() async throws {
        let (folder, parent) = try Self.made()
        defer { Self.remove(parent) }
        let outside = parent.appending(path: "secret.txt")
        try Data("not the extension's".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "escape"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: folder.appending(path: "lib"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "lib/up"), withDestinationURL: parent)
        let staged = try await ExtensionCheck.stage(folder)
        #expect(staged.entry?.files.map(\.path) == ["extension.json", "main.py"], "symlinks, to a file or a folder, are left out")
        #expect(try FileManager.default.contentsOfDirectory(atPath: staged.copy.path).sorted() == ["extension.json", "main.py"])
        #expect(staged.copy.lastPathComponent == "demo" && staged.ext?.folder == staged.copy, "read from the copy, named as its source")
        staged.remove()
        #expect(!FileManager.default.fileExists(atPath: staged.copy.deletingLastPathComponent().path), "remove leaves nothing")

        try Data().write(to: folder.appending(path: #"lib\up.txt"#))
        await #expect(throws: ExtensionCatalogue.Problem.failed(#"file path "lib\up.txt" leaves its folder"#)) { try await ExtensionCheck.stage(folder) }
        try FileManager.default.removeItem(at: folder.appending(path: #"lib\up.txt"#))

        for i in 0..<ExtensionCatalogue.mostFiles { try Data().write(to: folder.appending(path: "lib/f\(i).txt")) }
        await #expect(throws: ExtensionCatalogue.Problem.failed("it has 202 files, more than the 200 an extension may have")) {
            try await ExtensionCheck.stage(folder)
        }
    }

    @Test("A run gets a temporary HOME and its own data folder, removed after")
    func sandbox() async throws {
        let (folder, parent) = try Self.made()
        defer { Self.remove(parent) }
        try Data(#"""
            #!/usr/bin/env python3
            import json, os, sys
            run = json.loads(sys.stdin.readline())
            print(json.dumps({"type": "list", "items": [{"title": os.environ["HOME"]}, {"title": run["paths"]["data"]}]}))
            """#.utf8).write(to: folder.appending(path: "main.py"))
        let run = await ExtensionCheck.runs(try Extension(folder: folder))[0]
        #expect(run.ok)
        let home = try #require(run.first.firstMatch(of: /"title": "([^"]+)"/)?.1).description
        #expect(home.contains("pilot-ext-test-") && home.hasSuffix("/home"))
        #expect(!FileManager.default.fileExists(atPath: home), "the sandbox is removed after the runs")
    }
}
