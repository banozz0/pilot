import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95423242 (extensions phase 1, ADR 0010): a folder in Pilot's Extensions folder holding extension.json is
/// an extension; each of its commands is a Hyper+Space row and a bind, `ext.<id>.<command>`.
@Suite("Extensions")
struct ExtensionTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ path: String, in folder: URL, executable: Bool = false) throws {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    private let manifest = """
        {"id": "demo", "title": "Demo", "icon": "🧪", "runtime": "process",
         "permissions": {"network": ["api.github.com"], "clipboard": true, "files": ["~/Downloads"], "actions": ["windows.close"]},
         "preferences": [{"name": "token", "type": "password", "title": "Token"}],
         "commands": [{"name": "hello", "title": "Say hello", "mode": "no-view", "run": "bin/hello"},
                      {"name": "repos", "title": "My repos", "icon": "📦", "mode": "list", "run": "repos.py"}]}
        """

    @Test("A full manifest reads: id, title, icon, permissions and its commands with their action ids")
    func decodes() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = dir.appending(path: "demo-folder")
        try write(manifest, "extension.json", in: ext)
        try write("#!/bin/sh\n", "bin/hello", in: ext, executable: true)
        try write("#!/bin/sh\n", "repos.py", in: ext, executable: true)

        let read = try Extension(folder: ext)
        #expect(read.id == "demo" && read.title == "Demo" && read.icon == "🧪")
        #expect(read.permissions == Extension.Permissions(network: ["api.github.com"], clipboard: true, files: ["~/Downloads"],
                                                           actions: ["windows.close"]))
        #expect(read.preferences == [Extension.Preference(name: "token", title: "Token", kind: .password)])
        #expect(read.commands.map(\.name) == ["hello", "repos"])
        #expect(read.commands.map(\.mode) == [.noView, .list])
        #expect(read.commands[0].actionID == "ext.demo.hello")
        #expect(read.commands[0].icon == "🧪", "a command without an icon wears its extension's")
        #expect(read.commands[1].icon == "📦")
        #expect(read.commands[0].program == ext.appending(path: "bin/hello"))
    }

    @Test("A bad manifest is refused with its reason")
    func refuses() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        func problem(_ json: String, executable: Bool = true) throws -> Extension.Problem? {
            let ext = dir.appending(path: UUID().uuidString)
            try write(json, "extension.json", in: ext)
            try write("#!/bin/sh\n", "run", in: ext, executable: executable)
            do { _ = try Extension(folder: ext); return nil } catch let p as Extension.Problem { return p }
        }
        let command = #"{"name": "go", "title": "Go", "mode": "no-view", "run": "run"}"#
        #expect(try problem(#"{"id": "Bad.Id", "title": "X", "commands": [\#(command)]}"#) == .badID("Bad.Id"))
        #expect(try problem(#"{"id": "x", "title": "X", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "gone"}]}"#)
                == .missingProgram(command: "go", run: "gone"))
        #expect(try problem(#"{"id": "x", "title": "X", "commands": [\#(command)]}"#, executable: false)
                == .missingProgram(command: "go", run: "run"))
        #expect(try problem(#"{"id": "x", "title": "X", "commands": [{"name": "go", "title": "Go", "mode": "form", "run": "run"}]}"#)
                == .unknownMode(command: "go", mode: "form"))
        #expect(try problem(#"{"id": "x", "title": "X", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "../run"}]}"#)
                == .missingProgram(command: "go", run: "../run"), "a program outside its folder is not its own")
        #expect(try problem(#"{"id": "x", "title": "X", "runtime": "js", "commands": [\#(command)]}"#) == .unknownRuntime("js"))
        #expect(try problem(#"{"id": "x", "title": "X", "commands": []}"#) == .noCommands)
        #expect(try problem(#"{"id": "x", "title": "X", "commands": [{"name": "go", "title": "Go", "mode": "list", "run": "run", "filter": "fuzzy"}]}"#)
                == .unknownFilter(command: "go", filter: "fuzzy"))
        #expect(try problem(#"{"id": "x", "title": "X", "commands": [\#(command), \#(command)]}"#) == .duplicateCommand("go"))
        guard case .unreadable? = try problem("{not json") else { Issue.record("garbage reads"); return }
        #expect(Extension.Problem.badID("Bad.Id").reason.contains("Bad.Id"))
    }

    @Test("The Extensions folder lists each good extension by title and each bad folder with its reason")
    func find() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(manifest, "b/extension.json", in: dir)
        try write("#!/bin/sh\n", "b/bin/hello", in: dir, executable: true)
        try write("#!/bin/sh\n", "b/repos.py", in: dir, executable: true)
        try write(#"{"id": "alpha", "title": "Alpha", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "go"}]}"#,
                  "a/extension.json", in: dir)
        try write("#!/bin/sh\n", "a/go", in: dir, executable: true)
        try write("{", "broken/extension.json", in: dir)
        try write("loose file", "notes.txt", in: dir)
        try FileManager.default.createDirectory(at: dir.appending(path: "empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appending(path: ".hidden"), withIntermediateDirectories: true)

        let found = Extension.find(in: dir)
        #expect(found.extensions.map(\.id) == ["alpha", "demo"])
        #expect(found.broken.map(\.folder) == ["broken", "empty"])
        #expect(Extension.find(in: dir.appending(path: "missing")) == Extension.Found(extensions: [], broken: []))
    }

    @Test("Two folders with one id: the first by folder name wins, the second is broken")
    func duplicateID() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["one", "two"] {
            try write(#"{"id": "same", "title": "\#(name)", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "go"}]}"#,
                      "\(name)/extension.json", in: dir)
            try write("#!/bin/sh\n", "\(name)/go", in: dir, executable: true)
        }
        let found = Extension.find(in: dir)
        #expect(found.extensions.map(\.title) == ["one"])
        #expect(found.broken == [Extension.Broken(folder: "two", problem: .duplicateID("same"))])
    }

    @Test("ext ids name their extension and command; anything else is no extension command")
    func ids() {
        #expect(Extension.command(inAction: "ext.demo.hello") == Extension.CommandID(extension: "demo", command: "hello"))
        #expect(Extension.command(inAction: "ext.demo") == nil)
        #expect(Extension.command(inAction: "ext..hello") == nil)
        #expect(Extension.command(inAction: "scripts.run:x") == nil)
    }

    @Test("An extension command arrives switched off in an import and needs the link token over pilot://run")
    func arrivesOff() {
        #expect(BindStore.arrivesOff("ext.demo.hello"))
        #expect(!BindStore.arrivesOff("extensions.openFolder"))
    }

    @Test("A no-view command's keyword answers at the root: 'todo buy milk' gives Add a to-do: buy milk, its run carrying the text (2026-10-10)")
    func keywordAnswers() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"""
            {"id": "todo", "title": "To-do", "icon": "☑️",
             "commands": [{"name": "todo", "title": "To-do", "mode": "list", "filter": "self", "run": "main.py", "keyword": "todo"},
                          {"name": "add", "title": "Add a to-do", "mode": "no-view", "hidden": true, "run": "main.py", "keyword": "Todo"},
                          {"name": "odd", "title": "Odd", "mode": "no-view", "run": "main.py", "keyword": "two words"}]}
            """#, "todo/extension.json", in: dir)
        try write("#!/bin/sh\n", "todo/main.py", in: dir, executable: true)
        let extensions = Extension.find(in: dir).extensions
        // Only a no-view command takes a keyword, lowercased; anything but one word declares none.
        #expect(extensions.first?.commands.map(\.keyword) == [nil, "todo", nil])

        let row = try #require(Extension.answers(for: "Todo buy milk ", in: extensions).first)
        #expect(row.title == "Add a to-do: buy milk" && row.isAnswer && row.detail == "To-do" && row.icon == .command(emoji: "☑️"))
        guard case .action(let id) = row.target else { Issue.record("not an action: \(row.target)"); return }
        #expect(id == #"ext.todo.add/"buy milk""#)
        #expect(Extension.command(inAction: id) == Extension.CommandID(extension: "todo", command: "add"))
        #expect(Extension.input(inAction: id) == "buy milk")
        // A hidden command is no plain `ext.` action, but its keyword's answer finds it.
        #expect(Extension.command(inAction: "ext.todo.add", in: extensions) == nil)
        #expect(Extension.command(inAction: id, in: extensions)?.1.name == "add")
        // Text with dots and slashes stays one input.
        let odd = Extension.CommandID(extension: "todo", command: "add").actionID(input: "pay a.b/c \"now\"")
        #expect(Extension.command(inAction: odd)?.command == "add" && Extension.input(inAction: odd) == "pay a.b/c \"now\"")

        // The keyword alone, with only spaces after it, or inside a word answers nothing; so does an unknown word.
        for query in ["todo", "todo ", "todo   ", "todos buy", "odd buy", ""] {
            #expect(Extension.answers(for: query, in: extensions).isEmpty, "\(query)")
        }
        #expect(RootAnswers.entries(for: "todo buy milk", now: .now, extensions: extensions).first?.title == "Add a to-do: buy milk")
        #expect(Extension.input(inAction: "ext.todo.add") == nil)
    }
}

/// Card agent-bo-95423242: extension commands sit among the menu's actions as scripts do, found by their title or their
/// extension's.
@Suite("Extension menu rows")
struct ExtensionMenuTests {
    @Test("Each command is an action row with its icon and its extension's title as a keyword; a bound one keeps one row")
    func actions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-menu-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"""
            {"id": "gh", "title": "GitHub", "icon": "🐙", "commands": [
              {"name": "prs", "title": "Open my pull requests", "mode": "no-view", "run": "go"},
              {"name": "repos", "title": "Search repos", "mode": "list", "run": "go"}]}
            """#.utf8).write(to: dir.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "go").path)
        let ext = try Extension(folder: dir)

        let bound = BindsPage.ActionInfo(id: "ext.gh.prs", label: "ext.gh.prs", module: Module.drive.rawValue)
        let other = BindsPage.ActionInfo(id: "windows.close", label: "Close window", module: Module.windows.rawValue)
        let rows = Extension.actions([other, bound], with: [ext])
        #expect(rows.map(\.id) == ["windows.close", "ext.gh.prs", "ext.gh.repos"])
        let prs = try #require(rows.dropLast().last)
        #expect(prs.label == "Open my pull requests" && prs.keywords == "GitHub" && prs.icon?.emoji == "🐙")
    }
}

/// Pomodoro as an extension (2026-10-10): a hidden command is no row, no bind and no `ext.` action, yet its own
/// extension still runs it by name.
@Suite("Hidden extension commands")
struct HiddenCommandTests {
    @Test("A hidden command is not listed, not a menu row and not an ext. action, but its extension's run still finds it")
    func hidden() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-hidden-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"""
            {"id": "pomodoro", "title": "Pomodoro", "icon": "🍅", "commands": [
              {"name": "focus", "title": "Focus", "mode": "no-view", "run": "go"},
              {"name": "tick", "title": "Block ended", "mode": "no-view", "run": "go", "hidden": true},
              {"name": "log", "title": "Today", "mode": "list", "run": "go", "hidden": true}]}
            """#.utf8).write(to: dir.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "go").path)
        let ext = try Extension(folder: dir)

        #expect(ext.commands.map(\.hidden) == [false, true, true])
        #expect(ext.listed.map(\.name) == ["focus"])
        #expect(Extension.actions([], with: [ext]).map(\.id) == ["ext.pomodoro.focus"], "no menu row, so no bind either")
        #expect(Extension.command(Extension.CommandID(extension: "pomodoro", command: "tick"), in: [ext]) == nil, "no ext. action")
        #expect(Extension.command(Extension.CommandID(extension: "pomodoro", command: "focus"), in: [ext])?.1.name == "focus")
        #expect(ext.noView("tick")?.name == "tick", "its own run action, or a timer's end, still runs it")
        #expect(ext.view("log")?.name == "log", "and a push still shows a hidden view")
    }
}

/// Moody l8cEdH7tJF8 (card agent-bo-95423243): a live picker's rows are all its source's, so each answer replaces the
/// last whatever their kind; the program's own order arrives as answer rows, which a kind-by-kind provide left behind.
@Suite("Live picker rows")
struct LivePickerTests {
    private func row(_ title: String, answer: Bool) -> MenuEntry {
        MenuEntry(title: title, target: .action("ext.demo.rows#\(title)"), isAnswer: answer)
    }

    @Test("Each answer replaces the rows before it, answers and ranked rows alike, the selection back on the first")
    func replaces() {
        var nav = MenuNavigator(list: [], title: "Rows", live: true)
        nav.replaceList([row("error", answer: true)])
        nav.replaceList([row("for p", answer: true), row("for p 2", answer: true)])
        _ = nav.handle(.down)
        nav.replaceList([row("for pi", answer: true)])
        #expect(nav.rows.map(\.title) == ["for pi"])
        #expect(nav.selection == 0)
        nav.replaceList([row("beta", answer: false), row("alpha", answer: false)])
        nav.query = "alp"
        #expect(nav.rows.map(\.title) == ["alpha"], "ranked rows are still narrowed by the search")
    }
}
