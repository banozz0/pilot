#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The one Extensions list (Q601, pilot-1-1 T7) drawn offscreen on the fixture catalogue: Claude Sessions not installed
/// (its install failed, so its detail says why), Pomodoro installed at 0.9.0 (an update), Ports installed at its version.
/// In Instrument, a catalogue entry and an installed one picked, plus the list while the catalogue is read and
/// when it could not be. Then Raycast's store (raycast-extensions T24): the page's Raycast Store, Hyper+Space's Raycast
/// Store, and the root search typed "raycast", with the first rows "raycast", "store" and "install" rank printed. Then
/// T26: a Raycast list's List.EmptyView in the menu's empty look (menu-t26-empty).
/// T25: the page's All (an installed Raycast extension with its icon, then the store; Pilot's own set aside), its search
/// over both, Pilot's own (old), and the root search typed "process", the Raycast command read as Extension beside the
/// store's hit, their first rows printed.
/// Temporary folders and a fixture source only; opt-in like the other renders:
/// `PILOT_RENDER_DIR=<fresh dir> swift test --filter ExtensionCatalogueRenders`
extension SharedLook {
@MainActor
@Suite("Extension catalogue renders")
struct ExtensionCatalogueRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The one list renders loaded, reading and out of reach, in every style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil))
    func render() async throws {
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("extension-catalogue")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }

        let (loaded, dir) = try ExtensionCatalogueModelTests.model()
        defer { try? FileManager.default.removeItem(at: dir) }
        await loaded.open()
        await loaded.install(try #require(loaded.index?.entry("ports")))
        try ExtensionCatalogueModelTests.write(#"""
            {"id": "pomodoro", "title": "Pomodoro", "version": "0.9.0", "commands": [{"name": "focus", "title": "Focus", "mode": "no-view", "run": "run"}]}
            """#, as: "pomodoro", in: loaded.installer.extensions)
        // The fixture holds only Ports' files, so this install fails and its card says why.
        await loaded.install(try #require(loaded.index?.entry("claude-sessions")))
        await loaded.readInstalled()
        #expect(loaded.failures["claude-sessions"] != nil)

        let (failed, failedDir) = try ExtensionCatalogueModelTests.model(.init(down: true))
        defer { try? FileManager.default.removeItem(at: failedDir) }
        await failed.open()
        let (reading, readingDir) = try ExtensionCatalogueModelTests.model(.init(slow: true))
        defer { try? FileManager.default.removeItem(at: readingDir) }
        let read = Task { await reading.open() }
        defer { read.cancel() }
        try await Task.sleep(for: .milliseconds(50))

        // Pilot's own and its catalogue sit behind Pilot's own (old) since T25.
        func shot(_ name: String, _ model: ExtensionCatalogueModel, style: PilotStyle, theme: String, pick: String? = nil,
                  size: CGSize = CGSize(width: 1000, height: 640)) async throws {
            look.themeID = theme
            look.style = style
            let settings = await Self.settings(model)
            let page = Ground { ExtensionsPageView(onScreen: false, settings: settings, pick: pick, filter: .old).frame(width: size.width, height: size.height) }
                .styled(.page(.extensions), look: look).pilotTheme(look: look)
            try writeRender(page, to: out.appendingPathComponent("\(name).png"), wait: 0.6)
        }
        try await shot("instrument-loaded", loaded, style: .instrument, theme: "nightwatch", pick: "claude-sessions")
        try await shot("instrument-installed", loaded, style: .instrument, theme: "nightwatch", pick: "pomodoro")
        try await shot("instrument-failed", failed, style: .instrument, theme: "nightwatch")
        try await shot("instrument-reading", reading, style: .instrument, theme: "nightwatch")

        // Raycast's store (raycast-extensions T24) on a fixture listing: the page's Raycast Store with Kill Process picked
        // and read, Brew read, the rest by folder name; Hyper+Space's Raycast Store over the same model; and the root
        // search for each word that offers it, its first rows printed.
        let (store, storeDir) = try Self.storeModel()
        defer { try? FileManager.default.removeItem(at: storeDir) }
        await store.open()
        await store.info("kill-process")
        await store.info("brew")
        look.themeID = "nightwatch"
        look.style = .instrument
        let settings = await Self.settings(loaded)
        let page = Ground { ExtensionsPageView(onScreen: false, settings: settings, store: true, storeModel: store).frame(width: 1000, height: 640) }
            .styled(.page(.extensions), look: look).pilotTheme(look: look)
        try writeRender(page, to: out.appendingPathComponent("instrument-raycast-store.png"), wait: 0.6)
        var nav = MenuNavigator(list: [], title: RaycastStoreMenu.title, live: true)
        nav.replaceList(RaycastStoreMenu(model: store).rows())
        try InstrumentMenuRenders.render(MenuView(model: MenuModel(nav: nav)), "menu-raycast-store", in: out)
        // An Engine reads Pilot's support folder: only in a home that moved (CFFIXED_USER_HOME, either spelling of /tmp) or
        // a run without one, whose folder is its own.
        if let home = Self.env["CFFIXED_USER_HOME"] {
            try #require(URL(filePath: NSHomeDirectory()).resolvingSymlinksInPath() == URL(filePath: home).resolvingSymlinksInPath(),
                         "the home directory did not move; refusing to start an engine on Sven's data")
        }
        let entries = MenuEntries.build(apps: [], actions: Engine().bindActions, store: BindStore(defaults: [:]), roleApps: [:],
                                        menu: AppsModule.menuID, openID: AppsModule.openID(bundle:), running: [])
        for word in ["raycast", "store", "install"] {
            var root = MenuNavigator(entries: entries)
            root.query = word
            print("ROOT \(word): " + root.rows.prefix(6).enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: " | ")
                  + " … Raycast Store at \((root.rows.firstIndex { $0.target == .action(RaycastStoreMenu.actionID) } ?? -2) + 1) of \(root.rows.count)")
            if word == "raycast" { try InstrumentMenuRenders.render(MenuView(model: MenuModel(nav: root)), "menu-root-raycast", in: out) }
        }

        // T25: Kill Process installed from the store (Raycast-format, its icon in assets/) beside Pilot's own Pomodoro.
        let t25 = storeDir.appending(path: "t25")
        let raycast = try Self.raycastFixture(in: t25.appending(path: "Extensions"))
        try ExtensionCatalogueModelTests.write(#"""
            {"id": "pomodoro", "title": "Pomodoro", "version": "0.9.0", "commands": [{"name": "focus", "title": "Focus", "mode": "no-view", "run": "run"}]}
            """#, as: "pomodoro", in: t25.appending(path: "Extensions"))
        await store.openKept(installed: [raycast])
        let mine = ExtensionsSettings(folder: t25.appending(path: "Extensions"),
                                      storage: ExtensionStorage(data: t25.appending(path: "data"), cache: t25.appending(path: "cache"),
                                                                keychain: ExtensionsModuleTests.FakeKeychain()),
                                      label: { _ in nil }, catalogue: loaded)
        await mine.load()
        for (name, filter, query, pick) in [("instrument-t25-all", ExtensionsPage.Filter.all, "", "kill-process"),
                                            ("instrument-t25-search", .all, "o", "obsidian"), ("instrument-t25-old", .old, "", "pomodoro")] {
            let view = Ground { ExtensionsPageView(onScreen: false, settings: mine, pick: pick, storeModel: store, filter: filter, query: query)
                .frame(width: 1000, height: 640) }.styled(.page(.extensions), look: look).pilotTheme(look: look)
            try writeRender(view, to: out.appendingPathComponent("\(name).png"), wait: 0.6)
        }
        // Both installed: Kill Process (Raycast) and Pilot's own Pomodoro, which still answers in Hyper+Space ("pomodoro").
        let withRaycast = PilotMenu.entries(Engine(), scripts: [], extensions: Extension.find(in: t25.appending(path: "Extensions")).extensions)
        for word in ["process", "killprocess", "pomodoro"] {
            var root = MenuNavigator(entries: withRaycast)
            root.query = word
            root.provide(.store, store.rootRows(word))
            print("T25 ROOT \(word): " + root.rows.prefix(8).enumerated().map { "\($0.offset + 1). \($0.element.shownTitle) [\($0.element.kindWord ?? "-")\($0.element.subtitle.map { " · \($0)" } ?? "")]" }.joined(separator: " | "))
            if word != "pomodoro" { try InstrumentMenuRenders.render(MenuView(model: MenuModel(nav: root)), "menu-root-t25-\(word)", in: out) }
        }
        // T26: a Raycast list with no rows shows its List.EmptyView (Speedtest's failure view: Icon.LevelMeter, the error);
        // T28: with its actions, Return's named under it and its one row kept behind the look.
        let speedtestFailed = Extension.Empty(title: "Could not install speedtest cli", description: "Check your connection, then press Restart.",
                                     symbol: "gauge.with.dots.needle.67percent",
                                     actions: [.init(kind: .invoke(handler: "1.onAction"), title: "Restart"), .init(kind: .invoke(handler: "2.onAction"), title: "Copy Error")])
        var emptied = MenuNavigator(list: speedtestFailed.item.map { ExtensionList.entries([$0], of: raycast.commands[0]) } ?? [],
                                    title: "Speedtest", live: true)
        emptied.emptyView = speedtestFailed
        try InstrumentMenuRenders.render(MenuView(model: MenuModel(nav: emptied)), "menu-t26-empty", in: out)
    }

    /// Kill Process as a store install leaves it (T25): Raycast's package.json, its icon in assets/, its built command.
    static func raycastFixture(in extensions: URL) throws -> Extension {
        let folder = extensions.appending(path: "kill-process")
        try FileManager.default.createDirectory(at: folder.appending(path: "assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "dist"), withIntermediateDirectories: true)
        try Data(#"{"name":"kill-process","title":"Kill Process","description":"Terminate processes sorted by CPU or memory usage","icon":"icon.png","commands":[{"name":"index","title":"Kill Process","mode":"view"}]}"#.utf8)
            .write(to: folder.appending(path: "package.json"))
        try Data("module.exports = {};".utf8).write(to: folder.appending(path: "dist/index.js"))
        let icon = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/webapp-icons/x.png")
        try FileManager.default.copyItem(at: icon, to: folder.appending(path: "assets/icon.png"))
        return try Extension(folder: folder)
    }

    /// A store model on a fixture listing of five folders, two with a package.json, in a temporary folder of its own.
    static func storeModel() throws -> (RaycastStoreModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "raycast-store-render-\(UUID().uuidString)")
        let fixture = dir.appending(path: "github")
        let folders = ["brew", "google-chrome", "kill-process", "obsidian", "process-manager"]
        let tree = folders.enumerated().map { #"{"path":"\#($1)","type":"tree","sha":"\#(String(repeating: "\($0 + 1)", count: 40))"}"# }
        try FileManager.default.createDirectory(at: fixture.appending(path: "kill-process/assets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.appending(path: "brew"), withIntermediateDirectories: true)
        try Data(#"{"tree":[\#(tree.joined(separator: ","))],"truncated":false}"#.utf8).write(to: fixture.appending(path: "tree.json"))
        try Data(#"{"name":"kill-process","title":"Kill Process","description":"Terminate processes sorted by CPU or memory usage","icon":"icon.png","author":"rolandleth","commands":[{"name":"index"}]}"#.utf8)
            .write(to: fixture.appending(path: "kill-process/package.json"))
        try Data(#"{"name":"brew","title":"Brew","description":"Search and install Homebrew formulae and casks","author":"nhojb","commands":[{"name":"search"},{"name":"installed"}]}"#.utf8)
            .write(to: fixture.appending(path: "brew/package.json"))
        let icon = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/webapp-icons/x.png")
        try FileManager.default.copyItem(at: icon, to: fixture.appending(path: "kill-process/assets/icon.png"))
        let extensions = dir.appending(path: "Extensions")
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        return (RaycastStoreModel(source: .standIn(fixture, cache: dir.appending(path: "cache")), extensions: extensions), dir)
    }

    /// The page's state on `model`'s Extensions folder, read, with no Keychain or settings of Sven's.
    static func settings(_ model: ExtensionCatalogueModel) async -> ExtensionsSettings {
        let dir = model.installer.extensions.deletingLastPathComponent()
        let settings = ExtensionsSettings(folder: model.installer.extensions,
                                          storage: ExtensionStorage(data: dir.appending(path: "data"), cache: dir.appending(path: "cache"),
                                                                    keychain: ExtensionsModuleTests.FakeKeychain()),
                                          label: { _ in nil }, catalogue: model)
        await settings.load()
        return settings
    }
}

/// The page on its style's ground, as the window lays it.
private struct Ground<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.background(ink.background) }
}
}
#endif
