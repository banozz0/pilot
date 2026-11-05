import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Extensions page (card agent-bo-95423247) drawn offscreen on a folder of its own: three extensions whose
/// preferences cover all seven types, a required folder left unset, and two folders that are not extensions. Its values
/// sit in a temporary data folder and a fake Keychain, so nothing reads or writes Sven's Extensions folder, defaults or
/// Keychain. The whole window's renders (inside Instrument's and Toybox's frames, dark and light) are opt-in like the
/// others:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter ExtensionsPageViewTests`
extension SharedLook {
@MainActor
@Suite("Extensions page")
struct ExtensionsPageViewTests {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// The manifests by folder name: GitHub (text, password, checkbox, dropdown), Daily notes (folder, file, app), Dice
    /// (nothing to set, touches nothing); `weather` has a bad id and `scratch` no manifest.
    static let manifests: [(folder: String, json: String)] = [
        ("github", #"""
            {"id": "github", "title": "GitHub", "icon": "🐙",
             "description": "Your pull requests, issues and CI runs without opening a browser.",
             "examples": ["Type pilot: the open PRs on pilot, each with its checks", "Return on a red run opens its log on GitHub"],
             "permissions": {"network": ["api.github.com"], "clipboard": true},
             "preferences": [
               {"name": "user", "type": "text", "title": "Username", "required": true, "description": "Your GitHub login; searches start from your repositories."},
               {"name": "pin", "type": "password", "title": "Access PIN", "required": true},
               {"name": "forks", "type": "checkbox", "title": "Include forks", "default": false, "description": "Forks show in Search repositories too."},
               {"name": "sort", "type": "dropdown", "title": "Sort by", "default": "stars",
                "data": [{"title": "Stars", "value": "stars"}, {"title": "Recently updated", "value": "updated"}, {"title": "Name", "value": "name"}]}],
             "commands": [{"name": "search", "title": "Search repositories", "mode": "list", "run": "run"},
                          {"name": "pr", "title": "Open pull request", "icon": "🔀", "mode": "detail", "run": "run"},
                          {"name": "copy-url", "title": "Copy repository URL", "icon": "📋", "mode": "no-view", "run": "run"}]}
            """#),
        ("daily-notes", #"""
            {"id": "notes", "title": "Daily notes", "icon": "📓",
             "permissions": {"files": ["~/Notes"], "actions": ["system.lock"]},
             "preferences": [
               {"name": "vault", "type": "folder", "title": "Notes folder", "required": true, "description": "Where today's note is written."},
               {"name": "template", "type": "file", "title": "Template", "description": "A Markdown file each new note starts from."},
               {"name": "editor", "type": "app", "title": "Open in", "description": "The app a note opens in."}],
             "commands": [{"name": "today", "title": "Open today's note", "mode": "no-view", "run": "run"},
                          {"name": "find", "title": "Find a note", "icon": "🔎", "mode": "list", "run": "run", "filter": "self"}]}
            """#),
        ("dice", #"{"id": "dice", "title": "Dice", "icon": "🎲", "commands": [{"name": "roll", "title": "Roll a die", "mode": "no-view", "run": "run"}]}"#),
        ("weather", #"{"id": "Weather", "title": "Weather", "commands": [{"name": "now", "title": "Now", "mode": "no-view", "run": "run"}]}"#),
    ]

    /// The fixture's folders under `dir` (`scratch` left empty) and the page's state on them, its values saved first:
    /// GitHub's username, PIN (in `keychain`) and sort; Daily notes' template and app, its folder left unset.
    static func fixture(in dir: URL, keychain: ExtensionsModuleTests.FakeKeychain = .init()) async throws -> ExtensionsSettings {
        let exts = dir.appending(path: "exts")
        for (folder, json) in manifests {
            let ext = exts.appending(path: folder)
            try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: ext.appending(path: Extension.manifestName))
            try Data("#!/bin/sh\n".utf8).write(to: ext.appending(path: "run"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ext.appending(path: "run").path)
        }
        try FileManager.default.createDirectory(at: exts.appending(path: "scratch"), withIntermediateDirectories: true)
        let storage = ExtensionStorage(data: dir.appending(path: "data"), cache: dir.appending(path: "cache"), keychain: keychain)
        let found = Extension.find(in: exts).extensions
        func save(_ ext: String, _ name: String, _ value: JSONValue) throws {
            let ext = try #require(found.first { $0.id == ext })
            try storage.set(value, for: try #require(ext.preferences.first { $0.name == name }), of: ext)
        }
        try save("github", "user", .string("banozz0"))
        try save("github", "pin", .string("pw-SAMPLE-7"))
        try save("github", "sort", .string("updated"))
        try save("notes", "template", .string(NSHomeDirectory() + "/Notes/Templates/Daily.md"))
        try save("notes", "editor", .string("/Applications/Safari.app"))
        let settings = ExtensionsSettings(folder: exts, storage: storage, label: { ["system.lock": "Lock screen"][$0] })
        await settings.load()
        return settings
    }

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-page-\(UUID().uuidString)").resolvingSymlinksInPath()
    }

    @Test("The fixture reads as three extensions by title with every preference type, Daily notes' folder needed, and two folders not read")
    func fixtureReads() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = try await Self.fixture(in: dir)
        #expect(settings.rows.map(\.id) == ["notes", "dice", "github"])
        #expect(Set(settings.broken.map(\.folder)) == ["scratch", "weather"])
        let kinds = settings.rows.flatMap(\.fields).map { "\($0.preference.kind)".prefix { $0 != "(" } }
        #expect(Set(kinds) == ["text", "password", "checkbox", "dropdown", "app", "file", "folder"])
        #expect(settings.rows.flatMap(\.fields).filter(\.isMissing).map(\.id) == ["vault"])
        #expect(settings.rows[0].permissions.map(\.text) == ["Reads and writes ~/Notes", "Asks for Pilot actions it may not run: Lock screen"])
    }

    @Test("Uninstall moves the extension's folder to the Trash, keeps its settings, reads the folder again and says so (story 158)")
    func uninstall() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = ExtensionsModuleTests.FakeKeychain()
        let read = try await Self.fixture(in: dir, keychain: keychain)
        let bin = dir.appending(path: "Trash")
        let exts = dir.appending(path: "exts")
        let installer = ExtensionInstaller(extensions: exts, trash: { url in
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: bin.appending(path: url.lastPathComponent))
        })
        let storage = ExtensionStorage(data: dir.appending(path: "data"), cache: dir.appending(path: "cache"), keychain: keychain)
        let catalogue = ExtensionCatalogueModel(installer: installer)
        let settings = ExtensionsSettings(folder: exts, storage: storage, label: { _ in nil }, catalogue: catalogue)
        await settings.load()
        #expect(settings.rows.map(\.id) == read.rows.map(\.id))
        let github = try #require(settings.rows.first { $0.id == "github" })
        #expect(github.ext.description.hasPrefix("Your pull requests") && github.ext.examples.count == 2)

        let line = await settings.uninstall(github)
        #expect(line == "GitHub moved to the Trash. Its settings are kept.")
        #expect(settings.rows.map(\.id) == ["notes", "dice"] && catalogue.installed["github"] == nil)
        #expect(FileManager.default.fileExists(atPath: bin.appending(path: "github/extension.json").path))
        #expect(!FileManager.default.fileExists(atPath: exts.appending(path: "github").path))
        let back = ExtensionStorage(data: dir.appending(path: "data"), cache: dir.appending(path: "cache"), keychain: keychain)
            .values(of: github.ext)
        #expect(back["user"] == .string("banozz0") && back["pin"] == .string("pw-SAMPLE-7"), "its settings and Keychain item stay")

        // One already gone says why, and the page stays as it is.
        let again = await settings.uninstall(github)
        #expect(again?.hasPrefix("Not removed: ") == true && settings.rows.map(\.id) == ["notes", "dice"])
    }

    /// The pixels of `page` at `size`, at 1x.
    func pixels(_ page: some View, _ size: CGSize) throws -> Data {
        testApp()
        let (window, host) = ExtensionDetailViewTests.host(page.pilotTheme(), size)
        defer { window.close() }
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        PanelTestSupport.pump()
        host.layoutSubtreeIfNeeded()
        let rep = try #require(snapshot(host))
        return Data(bytes: try #require(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
    }

    @Test("The full folder and the empty one each draw something of their own")
    func bodies() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let full = try await Self.fixture(in: dir)
        let none = ExtensionsSettings(folder: dir.appending(path: "none"), storage: ExtensionStorage(data: dir.appending(path: "data"),
                                      cache: dir.appending(path: "cache"), keychain: ExtensionsModuleTests.FakeKeychain()), label: { _ in nil })
        await none.load()
        let size = CGSize(width: 1000, height: 900)
        let page = try pixels(ExtensionsPageView(onScreen: false, settings: full), size)
        let empty = try pixels(ExtensionsPageView(onScreen: false, settings: none), size)
        #expect(Set(page).count > 16 && Set(empty).count > 16, "a page drew blank")
        #expect(page != empty, "the empty folder drew the full page")
    }

    @Test("A card puts its preferences beside its commands only when wide enough for both halves")
    func halves() {
        // The page column beside the sidebar in the default 1000 pt window is about 750 wide: stacked. In a 1440 one,
        // about 1190: not.
        #expect(!ExtensionsPageView.halves(width: 750) && ExtensionsPageView.halves(width: 1190))
    }

    final class Asked { var focus: String? }

    @Test("A link's extension is landed on once the folder is read again and cleared; one not in the folder is dropped",
          arguments: ["github", "gone"])
    func lands(_ id: String) async throws {
        testApp()
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = try await Self.fixture(in: dir)
        let asked = Asked()
        asked.focus = id
        let focus = Binding(get: { asked.focus }, set: { asked.focus = $0 })
        let (window, _) = ExtensionDetailViewTests.host(ExtensionsPageView(onScreen: false, focus: focus, settings: settings).pilotTheme(),
                                                        CGSize(width: 1000, height: 700))
        defer { window.close() }
        // On the window list but far off every screen, so the page appears and its read of the folder starts.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        // Awaited, not spun: the read's hop back to the main actor runs only while the test yields it.
        let deadline = Date().addingTimeInterval(5)
        while asked.focus != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(asked.focus == nil, "the ask was never cleared")
    }

    // MARK: Renders

    @Test("The page renders inside Instrument's and Toybox's frames, dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("extensions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let engine = try SharedLook.HomeRenders.engine()
        engine.binds.replace("ext.github.search", with: Key("g", .shift))
        engine.binds.replace("ext.dice.roll", with: Key("6", .alt))
        let fixture = URL(fileURLWithPath: home).appending(path: "extensions-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let full = try await Self.fixture(in: fixture)
        let none = ExtensionsSettings(folder: fixture.appending(path: "none"), storage: ExtensionStorage(data: fixture.appending(path: "data"),
                                      cache: fixture.appending(path: "cache"), keychain: ExtensionsModuleTests.FakeKeychain()), label: { _ in nil })
        await none.load()
        var shown = full
        let make = ExtensionsPageView.make
        ExtensionsPageView.make = { shown }
        defer { ExtensionsPageView.make = make }

        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map(name.contains) ?? true }
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        defer { look.themeID = PilotTheme.defaultID; look.style = .instrument }

        func shot(_ name: String, style: PilotStyle = .instrument, dark: Bool = true, size: (Int, Int) = (1440, 900),
                  settings: ExtensionsSettings? = nil, focus: String? = nil) async throws {
            guard wanted(name) else { return }
            shown = settings ?? full
            look.themeID = dark ? "lagoon" : "workshop"
            look.style = style
            AppWindowController.applyLook(.shared, to: window)
            window.setContentSize(NSSize(width: CGFloat(size.0), height: CGFloat(size.1)))
            // Off the page and back, so the page is made again on the folder this shot shows. Awaited, not spun, so the
            // page's read of the folder comes back to the main actor and lands on the extension asked for.
            model.go(AppPlace(.home))
            try await Task.sleep(for: .milliseconds(300))
            model.extensionFocus = focus
            model.go(AppPlace(.extensions))
            try await Task.sleep(for: .seconds(1))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }

        try await shot("instrument-dark-1440")
        try await shot("instrument-light-1440", dark: false)
        try await shot("instrument-dark-1000", size: (1000, 660))
        try await shot("instrument-dark-760", size: (760, 620))
        try await shot("instrument-focus-notes", size: (1000, 660), focus: "notes")
        try await shot("instrument-empty", size: (1000, 660), settings: none)
        try await shot("toybox-dark", style: .toybox)
        try await shot("toybox-light", style: .toybox, dark: false)
    }
}
}
