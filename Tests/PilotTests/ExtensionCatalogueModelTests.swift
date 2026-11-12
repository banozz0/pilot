import Foundation
import PilotCore
import Synchronization
import Testing
@testable import Pilot

/// The extension catalogue in Pilot (2026-10-10): its shared state read only when asked and kept ten minutes, an install
/// and a remove through it, the menu's Extension catalogue (its loading row, rows, Return and Cmd+K), and a push reaching
/// a hidden view. Files come from the PilotCore fixture (the catalogue's index trimmed, Ports' files); the
/// Extensions folder and the Trash are temporary folders; nothing reaches GitHub.
@MainActor
@Suite("Extension catalogue model")
struct ExtensionCatalogueModelTests {
    nonisolated static let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "PilotCoreTests/Fixtures/extension-catalogue")

    /// The fixture as the repo, counting what was asked; `down` stands in for GitHub out of reach, `slow` for one that
    /// has not answered yet.
    final class Served: Sendable {
        let asked = Mutex<[String]>([])
        let down: Bool, slow: Bool
        init(down: Bool = false, slow: Bool = false) { self.down = down; self.slow = slow }
        var source: ExtensionCatalogue.Source {
            ExtensionCatalogue.Source { [self] path, _ in
                asked.withLock { $0.append(path) }
                if slow { try await Task.sleep(for: .seconds(30)) }
                if down { throw ExtensionCatalogue.Problem.unreachable("the catalogue is private; sign in to GitHub with gh auth login") }
                // A file the fixture lacks answers as gh does for one the repo lacks.
                guard let data = try? Data(contentsOf: ExtensionCatalogueModelTests.fixture.appending(path: path)) else {
                    throw ExtensionCatalogue.Problem.unreachable("gh can't see banozz0/pilot with the account it is signed in to")
                }
                return data
            }
        }
        var indexReads: Int { asked.withLock { $0.filter { $0 == ExtensionCatalogue.indexPath }.count } }
    }

    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 2_000_000) }

    /// An extension folder `name` under `dir` with `manifest` and an executable `run`.
    static func write(_ manifest: String, as name: String, in dir: URL) throws {
        let ext = dir.appending(path: name)
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: ext.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: ext.appending(path: "run"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ext.appending(path: "run").path)
    }

    /// A model on the fixture in a fresh folder: Extensions, its Trash and the folder they sit in.
    static func model(_ served: Served = Served(), clock: Clock = Clock()) throws -> (ExtensionCatalogueModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-catalogue-app-\(UUID().uuidString)").resolvingSymlinksInPath()
        let exts = dir.appending(path: "Extensions"), trash = dir.appending(path: "Trash")
        try FileManager.default.createDirectory(at: exts, withIntermediateDirectories: true)
        let installer = ExtensionInstaller(extensions: exts, source: served.source, trash: { url in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appending(path: UUID().uuidString))
        })
        return (ExtensionCatalogueModel(installer: installer, now: { clock.now }), dir)
    }

    @Test("Nothing is read until the catalogue opens; an open within ten minutes reads nothing again, Refresh and a later open do")
    func readsOnlyWhenAsked() async throws {
        let served = Served(), clock = Clock()
        let (model, dir) = try Self.model(served, clock: clock)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.load == .idle && served.indexReads == 0)
        await model.open()
        #expect(model.load == .loaded && model.entries().map(\.id) == ["claude-sessions", "pomodoro", "ports"] && served.indexReads == 1)
        clock.now += 300
        await model.open()
        #expect(served.indexReads == 1)
        await model.refresh()
        #expect(served.indexReads == 2)
        clock.now += 601
        await model.open()
        #expect(served.indexReads == 3)
        #expect(model.entries("ports").map(\.id) == ["ports"])
    }

    @Test("A catalogue out of reach says why")
    func failure() async throws {
        let (model, dir) = try Self.model(Served(down: true))
        defer { try? FileManager.default.removeItem(at: dir) }
        await model.open()
        #expect(model.load == .failed("Pilot's catalogue could not be reached: the catalogue is private; sign in to GitHub with gh auth login."))
        #expect(model.entries().isEmpty)
    }

    @Test("Install lands the extension and its standing turns Installed; Remove trashes it and it is Install again")
    func installAndRemove() async throws {
        let (model, dir) = try Self.model()
        defer { try? FileManager.default.removeItem(at: dir) }
        await model.open()
        let ports = try #require(model.index?.entry("ports"))
        #expect(model.standing(of: ports) == .install)
        #expect(await model.install(ports) == "Ports installed. Its commands are in Hyper+Space.")
        #expect(model.standing(of: ports) == .installed && model.busy.isEmpty && model.failures.isEmpty)
        #expect(await model.install(ports) == "Ports updated to 1.0.0. Its commands are in Hyper+Space.", "a reinstall replaces it")
        #expect(await model.remove("ports") == "Ports moved to the Trash. Its settings are kept.")
        #expect(model.standing(of: ports) == .install)
        #expect(await model.remove("ports") == "Not removed: No extension ports is installed." && model.failures["ports"] == "No extension ports is installed.")
    }

    @Test("A failed install leaves why on its card")
    func installFails() async throws {
        let (model, dir) = try Self.model()
        defer { try? FileManager.default.removeItem(at: dir) }
        await model.open()
        let pomodoro = try #require(model.index?.entry("pomodoro"))
        // The fixture holds only Ports' files.
        #expect(await model.install(pomodoro)
                == "Pomodoro was not installed: Pilot's catalogue could not be reached: gh can't see banozz0/pilot with the account it is signed in to.")
        #expect(model.failures["pomodoro"] != nil && model.standing(of: pomodoro) == .install && model.busy.isEmpty)
    }

    // MARK: The menu

    @Test("The menu's catalogue shows its loading row, then a row per entry saying where it stands, with Cmd+K's actions by standing")
    func menuRows() async throws {
        let (model, dir) = try Self.model()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Ports installed older than the catalogue's: an update.
        try Self.write(#"{"id": "ports", "title": "Ports", "version": "0.9.0", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "run"}]}"#,
                       as: "ports", in: model.installer.extensions)
        let menu = ExtensionCatalogueMenu(model: model, hud: { _ in }, page: { _, _ in })
        var shown: [[MenuEntry]] = []
        menu.show = { shown.append($0) }
        menu.search("")
        #expect(shown.first?.map(\.title) == [ExtensionCatalogueMenu.reading] && shown.first?.first?.isAnswer == true)
        await menu.settled()
        menu.search("po")
        let rows = try #require(shown.last)
        #expect(shown.count == 2, "a later search is Pilot's to rank, not a new read")
        #expect(rows.map(\.title) == ["Claude Sessions", "Pomodoro", "Ports"] && rows.allSatisfy { !$0.isAnswer })
        #expect(rows[2].subtitle == "See which program holds a listening TCP port and quit it: the dev server you forgot. · Update to 1.0.0")
        #expect(rows[2].ownActions == ["Update to 1.0.0", "Uninstall", "Show on Extensions page"])
        #expect(rows[1].ownActions == ["Install", "Show on Extensions page"] && rows[1].subtitle?.hasSuffix(" · Install") == true)
        #expect(rows[0].keywords?.contains("Claude sessions") == true)
        #expect(ExtensionCatalogueMenu.actions(.installed) == [.show, .remove])
    }

    @Test("Return installs (a HUD says so when done); on one installed it opens the Extensions page at it; Cmd+K's Show opens the catalogue for one not installed")
    func menuPicks() async throws {
        let (model, dir) = try Self.model()
        defer { try? FileManager.default.removeItem(at: dir) }
        var said: [String] = [], opened: [(AppPlace, String)] = []
        let menu = ExtensionCatalogueMenu(model: model, hud: { said.append($0) }, page: { opened.append(($0, $1)) })
        var rows: [MenuEntry] = []
        menu.show = { rows = $0 }
        menu.search("")
        await menu.settled()
        let ports = try #require(rows.first { $0.title == "Ports" })
        guard case .close(let install) = menu.pick(ports, action: 0) else { Issue.record("Return did not close to install"); return }
        install()
        // Until the install has said it is done, however long a loaded Mac takes: Show below needs Ports installed.
        #expect(try await SystemSamplerTests.wait { said.count >= 2 })
        #expect(said == ["Installing Ports…", "Ports installed. Its commands are in Hyper+Space."])
        guard case .close(let show) = menu.pick(menu.row(try #require(model.index?.entry("ports"))), action: 0) else { Issue.record("no show"); return }
        show()
        guard case .close(let browse) = menu.pick(try #require(rows.first { $0.title == "Pomodoro" }), action: 1) else { Issue.record("no show"); return }
        browse()
        #expect(opened.map(\.0) == [AppPlace(.extensions), AppPlace(.extensionCatalogue)] && opened.map(\.1) == ["ports", "pomodoro"])
        guard case .stay = menu.pick(ExtensionCatalogueMenu.status("x"), action: 0) else { Issue.record("the status row picks"); return }
    }

    @Test("Cmd+K's Uninstall asks first in the page's words: Cancel moves nothing, the yes moves the folder to the Trash and says so")
    func menuUninstallAsks() async throws {
        let (model, dir) = try Self.model()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write(#"{"id": "ports", "title": "Ports", "version": "1.0.0", "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "run"}]}"#,
                       as: "ports", in: model.installer.extensions)
        var said: [String] = [], asked: [(String, String)] = [], yes: (@MainActor () -> Void)?
        let menu = ExtensionCatalogueMenu(model: model, hud: { said.append($0) }, page: { _, _ in },
                                          confirm: { title, note, then in asked.append((title, note)); yes = then })
        var rows: [MenuEntry] = []
        menu.show = { rows = $0 }
        menu.search("")
        await menu.settled()
        let ports = try #require(rows.first { $0.title == "Ports" })
        let uninstall = try #require(ports.ownActions?.firstIndex(of: "Uninstall"))
        guard case .close(let ask) = menu.pick(ports, action: uninstall) else { Issue.record("Uninstall did not close to ask"); return }
        ask()
        #expect(asked.map(\.0) == ["Uninstall Ports?"] && asked.map(\.1) == [ExtensionCatalogue.uninstallNote])
        let folder = model.installer.extensions.appending(path: "ports")
        #expect(FileManager.default.fileExists(atPath: folder.path), "nothing moves before the yes")
        let go = try #require(yes)
        go()
        #expect(try await SystemSamplerTests.wait { !said.isEmpty })
        #expect(said == ["Ports moved to the Trash. Its settings are kept."] && !FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("Extension catalogue is a registered action, found by the words people use for it")
    func registered() throws {
        var registry = ActionRegistry()
        ExtensionsModule.register(into: &registry)
        let action = try #require(registry.actions[ExtensionCatalogueMenu.actionID])
        #expect(action.label == "Extension catalogue" && action.defaultKey == nil)
        for word in ["extensions", "install extension", "pomodoro"] { #expect(action.keywords?.contains(word) == true, "\(word)") }
    }

    // MARK: Hidden views

    @Test("A push reaches a hidden list or detail of the same extension, which still has no ext. row or bind")
    func pushToHidden() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-hidden-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write(#"""
            {"id": "sessions", "title": "Sessions", "commands": [
              {"name": "list", "title": "Sessions", "mode": "list", "run": "run"},
              {"name": "detail", "title": "Session", "mode": "detail", "hidden": true, "run": "run"},
              {"name": "more", "title": "More", "mode": "list", "hidden": true, "run": "run"}]}
            """#, as: "sessions", in: dir)
        let ext = try #require(Extension.find(in: dir).extensions.first)
        let context: JSONValue = .object(["file": .string("/tmp/a.jsonl")])
        guard case .push("Session", let source) = ExtensionActions.pick(Extension.Item.Action(kind: .push(command: "detail", context: context)), in: ext, inputs: .sample),
              let session = source as? ExtensionListSession else { Issue.record("the push to a hidden detail did not stay"); return }
        #expect(session.command.name == "detail" && session.command.hidden && session.context == context)
        guard case .push("More", _) = ExtensionActions.pick(Extension.Item.Action(kind: .push(command: "more", context: nil)), in: ext, inputs: .sample) else {
            Issue.record("the push to a hidden list did not stay"); return
        }
        #expect(ext.listed.map(\.actionID) == ["ext.sessions.list"])
        #expect(Extension.command(Extension.CommandID(extension: "sessions", command: "detail"), in: [ext]) == nil, "no ext. action")
        #expect(Extension.actions([], with: [ext]).map(\.id) == ["ext.sessions.list"], "no menu row or bind")
    }
}
