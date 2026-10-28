import Foundation
import PilotCore
import Synchronization
import Testing
@testable import Pilot

/// Card agent-bo-95423242: `ext.<id>.<command>` runs that command from Hyper+Space, its bind or pilot://run, and shows
/// what it said. The runs here go to a fake; ExtensionRunTests runs real programs.
@MainActor
@Suite("Extensions module")
struct ExtensionsModuleTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-exts-\(UUID().uuidString)").resolvingSymlinksInPath()
        let ext = dir.appending(path: "demo")
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        try Data(#"""
            {"id": "demo", "title": "Demo", "commands": [{"name": "go", "title": "Say hello", "mode": "no-view", "run": "go"},
                                                        {"name": "rows", "title": "Rows", "mode": "list", "run": "go"}]}
            """#.utf8).write(to: ext.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: ext.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ext.appending(path: "go").path)
        return dir
    }

    private func shown(_ id: String, in dir: URL, _ outcome: ExtensionRun.Outcome, keychain: FakeKeychain = FakeKeychain()) async -> (ran: [String], hud: [String]) {
        var ran: [String] = [], hud: [String] = []
        let storage = ExtensionStorage(data: dir.appending(path: "data"), cache: dir.appending(path: "cache"), keychain: keychain)
        await ExtensionsModule.perform(id, in: dir, storage: storage, run: { command, inputs, input in
            ran.append(command.actionID + (inputs.preferences.isEmpty ? "" : " \(inputs.preferences)") + (input.map { " input \($0)" } ?? ""))
            return outcome
        }, list: { ran.append("list \($1.actionID)"); _ = $2 }, settings: { ran.append("settings \($0.id)") }, hud: { hud.append($0) })
        return (ran, hud)
    }

    /// The Keychain as a dictionary, so no test touches the real one.
    final class FakeKeychain: ExtensionKeychain {
        let items = Mutex<[String: String]>([:])
        func password(extension id: String, preference name: String) -> String? { items.withLock { $0["\(id)/\(name)"] } }
        func setPassword(_ password: String?, extension id: String, preference name: String) throws { items.withLock { $0["\(id)/\(name)"] = password } }
        func hasPassword(extension id: String, preference name: String) -> Bool { items.withLock { $0["\(id)/\(name)"] != nil } }
    }

    @Test("A command whose extension's required preference is unset runs nothing and names it; once set, the run gets it (card agent-bo-95423246)")
    func requiredPreference() async throws {
        // Card agent-bo-95423247: the stop opens the Extensions page at the extension.
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"""
            {"id": "demo", "title": "Demo", "preferences": [{"name": "pin", "type": "password", "title": "PIN", "required": true}],
             "commands": [{"name": "go", "title": "Say hello", "mode": "no-view", "run": "go"}]}
            """#.utf8).write(to: dir.appending(path: "demo/\(Extension.manifestName)"))
        let keychain = FakeKeychain()
        #expect(await shown("ext.demo.go", in: dir, .hud("Hello"), keychain: keychain) == (["settings demo"], ["Demo needs PIN set first."]))
        try keychain.setPassword("pw-SAMPLE-1", extension: "demo", preference: "pin")
        #expect(await shown("ext.demo.go", in: dir, .hud("Hello"), keychain: keychain) == ([#"ext.demo.go ["pin": PilotCore.JSONValue.string("pw-SAMPLE-1")]"#], ["Hello"]))
    }

    @Test("The action is named after its command and runs it; what the command said is the HUD line")
    func runs() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let action = try #require(ExtensionsModule.dynamic("ext.demo.go", folder: dir))
        #expect(action.label == "Say hello" && action.module == .drive)
        #expect(ExtensionsModule.dynamic("windows.close", folder: dir) == nil)
        #expect(await shown("ext.demo.go", in: dir, .hud("Hello")) == (["ext.demo.go"], ["Hello"]))
        #expect(await shown("ext.demo.go", in: dir, .hud(nil)).hud == ["Say hello ran"])
        #expect(await shown("ext.demo.go", in: dir, .error("No token set")).hud == ["Demo: No token set"])
        #expect(await shown("ext.demo.go", in: dir, .timedOut).hud == ["Say hello took longer than 30 s and was stopped."])
        #expect(await shown("ext.demo.go", in: dir, .failed("boom")).hud == ["Say hello failed; Pilot's log says why."])
    }

    @Test("A command gone from the folder runs nothing and says so; a list command opens its list")
    func refuses() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ExtensionsModule.dynamic("ext.demo.gone", folder: dir)?.label == "ext.demo.gone")
        #expect(await shown("ext.demo.gone", in: dir, .hud("x")) == ([], ["No extension command ext.demo.gone in Extensions."]))
        #expect(await shown("ext.demo.rows", in: dir, .hud("x")) == (["list ext.demo.rows"], []))
    }

    @Test("A keyword's answer runs its command, hidden or not, with the text typed as its input (2026-10-10)")
    func keywordRun() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"""
            {"id": "demo", "title": "Demo", "commands": [{"name": "go", "title": "Say hello", "mode": "no-view", "run": "go"},
                                                        {"name": "add", "title": "Add", "mode": "no-view", "run": "go", "hidden": true, "keyword": "todo"}]}
            """#.utf8).write(to: dir.appending(path: "demo/\(Extension.manifestName)"))
        let id = try #require({ if case .action(let id)? = Extension.answers(for: "todo buy milk", in: Extension.find(in: dir).extensions).first?.target { id } else { nil } }())
        #expect(ExtensionsModule.dynamic(id, folder: dir)?.label == "Add")
        #expect(await shown(id, in: dir, .hud("Added: buy milk")) == (["ext.demo.add input buy milk"], ["Added: buy milk"]))
        // The hidden command stays no plain action, and a command without a keyword takes no input from an id.
        #expect(await shown("ext.demo.add", in: dir, .hud("x")).ran.isEmpty)
        #expect(await shown(#"ext.demo.go/"x""#, in: dir, .hud("x")).ran.isEmpty)
        #expect(await shown("ext.demo.go", in: dir, .hud("Hello")).ran == ["ext.demo.go"])
    }
}

/// Card agent-bo-95423243: a list command's rows in the menu. Pilot's filter asks the program once; the program's own is
/// asked again for each search, the newest answer winning. The runs go to a fake.
@MainActor
@Suite("Extension list sessions")
struct ExtensionListSessionTests {
    private func command(filter: String) throws -> (Extension, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-session-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"id": "demo", "title": "Demo", "commands": [{"name": "rows", "title": "Rows", "mode": "list", "run": "go", "filter": "\#(filter)"}]}"#.utf8)
            .write(to: dir.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "go").path)
        return (try Extension(folder: dir), dir)
    }

    @Test("Pilot's filter runs the program once, whatever is typed after")
    func once() async throws {
        let (ext, dir) = try command(filter: "pilot")
        defer { try? FileManager.default.removeItem(at: dir) }
        var asked: [String] = [], shown: [[MenuEntry]] = []
        let session = ExtensionListSession(ext, ext.commands[0], inputs: .sample, run: { _, query in
            asked.append(query)
            return .items([Extension.Item(title: "pilot", actions: [.copy("p")])])
        })
        session.show = { shown.append($0) }
        session.search("")
        session.search("pi")
        await session.settled()
        #expect(asked == [""])
        #expect(shown.map { $0.map(\.title) } == [["pilot"]])
        #expect(session.action(for: try #require(shown.first?.first)) == .copy("p"))
    }

    @Test("The program's filter asks again once typing pauses, for the last search only, a slower older answer never replacing a newer one")
    func newestWins() async throws {
        let (ext, dir) = try command(filter: "self")
        defer { try? FileManager.default.removeItem(at: dir) }
        var asked: [String] = [], shown: [[MenuEntry]] = []
        var pauses: [CheckedContinuation<Void, Never>] = [], slow: CheckedContinuation<Void, Never>?
        let session = ExtensionListSession(ext, ext.commands[0], inputs: .sample, run: { _, query in
            asked.append(query)
            if query == "pil" { await withCheckedContinuation { slow = $0 } }
            return .items([Extension.Item(title: "for \(query)", actions: [])])
        }, pause: { await withCheckedContinuation { pauses.append($0) } })
        session.show = { shown.append($0) }
        /// Until `count` runs wait in the typing pause.
        func paused(_ count: Int) async { while pauses.count < count { await Task.yield() } }
        func release() { pauses.forEach { $0.resume() }; pauses = [] }

        session.search("")
        await session.settled()
        // Typed within one pause: only the last search is asked.
        session.search("p")
        await paused(1)
        session.search("pi")
        await paused(2)
        release()
        await session.settled()
        #expect(asked == ["", "pi"])
        // A slow answer for pil, overtaken by pilo, never shows.
        session.search("pil")
        await paused(1)
        release()
        while slow == nil { await Task.yield() }
        session.search("pilo")
        await paused(1)
        release()
        await session.settled()
        slow?.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(asked == ["", "pi", "pil", "pilo"])
        #expect(shown.map { $0.map(\.title) } == [["for "], ["for pi"], ["for pilo"]])
        #expect(shown.last?.allSatisfy { $0.isAnswer } == true, "the program's order is kept")
    }

    @Test("An error answer is the one error row, under the extension's title, and picks nothing")
    func error() async throws {
        let (ext, dir) = try command(filter: "pilot")
        defer { try? FileManager.default.removeItem(at: dir) }
        var shown: [[MenuEntry]] = []
        let session = ExtensionListSession(ext, ext.commands[0], inputs: .sample, run: { _, _ in .error("did not answer in 2 s") })
        session.show = { shown.append($0) }
        session.search("")
        await session.settled()
        #expect(shown.map { $0.map(\.title) } == [["Demo did not answer in 2 s"]])
        #expect(session.action(for: try #require(shown.first?.first)) == nil)
    }

    @Test("A detail answer is the view's one row, which the panel draws as the detail; its actions are Return's and Cmd+K's; closing ends the program")
    func detail() async throws {
        let (ext, dir) = try command(filter: "pilot")
        defer { try? FileManager.default.removeItem(at: dir) }
        let detail = Extension.Detail(markdown: "# pilot", metadata: [.init(label: "Stars", text: "12")], actions: [.copy("a"), .open("/tmp")])
        var shown: [[MenuEntry]] = [], ended = 0
        let session = ExtensionListSession(ext, ext.commands[0], inputs: .sample, run: { _, _ in .detail(detail) }, end: { ended += 1 })
        session.show = { shown.append($0) }
        session.search("")
        await session.settled()
        let row = try #require(shown.first?.first)
        var nav = MenuNavigator(list: [], title: "Rows", live: true)
        nav.replaceList(try #require(shown.first))
        #expect(nav.shownDetail == detail)
        #expect(session.action(for: row) == .copy("a") && session.action(1, for: row) == .open("/tmp"))
        session.close()
        #expect(ended == 1)
    }
}


/// Card agent-bo-95423244: what an extension row's actions do. Nothing here opens, copies or pastes for real.
@MainActor
@Suite("Extension actions in the app")
struct ExtensionActionsAppTests {
    private func demo() throws -> (Extension, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-act-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"""
            {"id": "demo", "title": "Demo", "commands": [{"name": "rows", "title": "Rows", "mode": "list", "run": "go"},
              {"name": "detail", "title": "Repo", "mode": "list", "run": "go"}, {"name": "star", "title": "Star", "mode": "no-view", "run": "go"},
              {"name": "readme", "title": "Readme", "mode": "detail", "run": "go"}]}
            """#.utf8).write(to: dir.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "go").path)
        return (try Extension(folder: dir), dir)
    }

    @Test("A push to one of its list commands stays in the panel with that command and the context; anything else closes it first")
    func push() throws {
        let (ext, dir) = try demo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context: JSONValue = .object(["repo": .string("pilot")])
        guard case .push(let title, let source) = ExtensionActions.pick(Extension.Item.Action(kind: .push(command: "detail", context: context)), in: ext, inputs: .sample),
              let session = source as? ExtensionListSession else { Issue.record("no push"); return }
        #expect(title == "Repo" && session.command.name == "detail" && session.context == context && session.inputs == .sample)
        guard case .push("Readme", let readme) = ExtensionActions.pick(Extension.Item.Action(kind: .push(command: "readme", context: nil)), in: ext, inputs: .sample),
              (readme as? ExtensionListSession)?.command.mode == .detail else { Issue.record("no push to a detail"); return }
        guard case .close = ExtensionActions.pick(.copy("x"), in: ext, inputs: .sample) else { Issue.record("copy stays"); return }
        guard case .close = ExtensionActions.pick(Extension.Item.Action(kind: .push(command: "star", context: nil)), in: ext, inputs: .sample) else {
            Issue.record("a push to a no-view command stays"); return
        }
    }

    @Test("A Pilot action outside the registry, or a drive route, is refused and says so; a missing command too")
    func refusals() throws {
        let (ext, dir) = try demo()
        defer { try? FileManager.default.removeItem(at: dir) }
        var said: [String] = []
        ExtensionActions.run(Extension.Item.Action(kind: .pilot("drive.shell:rm")), in: ext, inputs: .sample, isRegistered: { $0 == "drive.shell:rm" }, hud: { said.append($0) })
        ExtensionActions.run(Extension.Item.Action(kind: .run(command: "gone", context: nil)), in: ext, inputs: .sample, isRegistered: { _ in false }, hud: { said.append($0) })
        ExtensionActions.run(Extension.Item.Action(kind: .hud("Starred")), in: ext, inputs: .sample, isRegistered: { _ in false }, hud: { said.append($0) })
        #expect(said == ["Demo can't run drive.shell:rm.", "Demo has no command gone to run.", "Starred"])
    }

    @Test("A no-view command's action messages each run, in the order printed; a HUD line plays its sound")
    func noViewAction() async throws {
        let (ext, dir) = try demo()
        defer { try? FileManager.default.removeItem(at: dir) }
        var acted: [Extension.Item.Action] = [], played: [String] = [], said: [String] = []
        ExtensionsModule.show(.actions([.copy("v1"), .open("/tmp"), .copy("v2")], dropped: 3), of: ext.commands[2], in: ext,
                              act: { acted.append($0) }, hud: { said.append($0) }, play: { played.append($0) })
        #expect(acted == [.copy("v1"), .open("/tmp"), .copy("v2")] && said.isEmpty)
        ExtensionsModule.show(.hud("Done", sound: "Glass"), of: ext.commands[2], in: ext, act: { acted.append($0) }, hud: { said.append($0) },
                              play: { played.append($0) })
        ExtensionActions.run(Extension.Item.Action(kind: .hud("Starred", sound: "Pop")), in: ext, inputs: .sample, isRegistered: { _ in false },
                             hud: { said.append($0) }, play: { played.append($0) })
        #expect(said == ["Done", "Starred"] && played == ["Glass", "Pop"])
    }

    @Test("A pushed view pops back to the list under it as it was, its search kept")
    func popBack() throws {
        let (ext, dir) = try demo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = MenuModel(nav: MenuNavigator(list: [], title: "Rows", live: true))
        model.nav.replaceList([MenuEntry(title: "pilot", target: .action("ext.demo.rows#0"), isAnswer: true)])
        model.nav.query = "pil"
        let first = ExtensionListSession(ext, ext.commands[0], inputs: .sample)
        var heard: [String] = []
        model.onQuery = { heard.append($0) }
        model.push(MenuNavigator(list: [], title: "Repo", live: true), over: first)
        #expect(model.nav.title == "Repo" && model.nav.query.isEmpty)
        #expect(heard.isEmpty, "the pushed view's empty search never reaches the list under it")
        #expect(model.pop() === first)
        #expect(heard.isEmpty, "nor does the old search coming back")
        #expect(model.nav.title == "Rows" && model.nav.query == "pil" && model.nav.rows.map(\.title) == ["pilot"])
        #expect(model.pop() == nil)
    }
}

/// Card agent-bo-95423247: the Extensions page's state reads the folder with each extension's values and saves an edit
/// through the store as it changes, a password into the (fake) Keychain only.
@MainActor
@Suite("Extensions settings")
struct ExtensionsSettingsTests {
    @Test("The page lists the folder's extensions and its broken folder; an edit saves at once and shows the value a run gets")
    func edits() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-settings-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = dir.appending(path: "exts/demo")
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appending(path: "exts/empty"), withIntermediateDirectories: true)
        try Data(#"""
            {"id": "demo", "title": "Demo", "preferences": [{"name": "user", "type": "text", "title": "User", "default": "sven"},
                                                             {"name": "pin", "type": "password", "title": "PIN", "required": true}],
             "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "go"}]}
            """#.utf8).write(to: ext.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: ext.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ext.appending(path: "go").path)
        let keychain = ExtensionsModuleTests.FakeKeychain()
        let storage = ExtensionStorage(data: dir.appending(path: "data"), cache: dir.appending(path: "cache"), keychain: keychain)
        let settings = ExtensionsSettings(folder: dir.appending(path: "exts"), storage: storage, label: { _ in nil })
        await settings.load()
        #expect(settings.rows.map(\.id) == ["demo"] && settings.broken.map(\.folder) == ["empty"])
        let row = settings.rows[0]
        #expect(row.fields.map(\.value) == [.string("sven"), nil] && row.fields[1].isMissing)

        settings.set(.string("banozz0"), for: row.fields[0], of: row)
        settings.set(.string("pw-SAMPLE-7"), for: row.fields[1], of: row)
        #expect(settings.rows[0].fields.map(\.value) == [.string("banozz0"), .string("pw-SAMPLE-7")] && !settings.rows[0].fields[1].isMissing)
        #expect(storage.values(of: row.ext) == ["user": .string("banozz0"), "pin": .string("pw-SAMPLE-7")], "saved, not just shown")
        #expect(keychain.items.withLock { $0 } == ["demo/pin": "pw-SAMPLE-7"])

        settings.set(.string(""), for: row.fields[1], of: row)
        settings.set(nil, for: row.fields[0], of: row)
        #expect(settings.rows[0].fields.map(\.value) == [.string("sven"), nil], "cleared: the default again, the PIN gone")
        #expect(keychain.items.withLock { $0 }.isEmpty)
    }
}

extension ExtensionRun.Inputs {
    /// Inputs for a view whose runs go to a fake.
    static let sample = ExtensionRun.Inputs(preferences: [:], data: URL(filePath: "/tmp/pilot-ext-data"), cache: URL(filePath: "/tmp/pilot-ext-cache"))
}
