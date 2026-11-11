#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Hyper+Space menu as the Rail draws it (menu Rail and Classic T6, frames B1–B3, B7, B8), Tokyo Night and Porcelain,
/// through HUD.makePanel as Pilot shows it: the root with and without recents and Waiting, Tab at the empty root onto Apps
/// and Windows, a root search, no match, Install, System and its switches, an answer and Cmd+K at the root. The sizes and what the search line counts are
/// checked always; the pictures are opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter RailMenuRenders`
extension SharedLook {
@MainActor
@Suite("Rail menu renders")
struct RailMenuRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The Rail is 750 wide everywhere (Q130); up to 650 tall wherever its whole rail shows, which fits")
    func sizes() throws {
        let states = try Dictionary(uniqueKeysWithValues: Self.states())
        let root = try #require(states["B1-root"])
        #expect(root.railBand == .root)
        #expect(root.instrumentSize.width == MenuPanelSize.width)
        #expect(root.instrumentSize.height <= MenuPanelSize.railTallest)
        // The whole rail fits the root unscrolled: 6 kinds, the 10 branches and Clipboard under Go to.
        #expect(root.railItems == 17)
        #expect(MenuPanelSize.railHeight(.root, items: root.railItems) + MenuPanelSize.railChrome <= root.instrumentSize.height)
        for name in ["B2-tab-apps", "B2-tab-windows", "B3-search", "B7-no-match"] {
            let model = try #require(states[name])
            #expect(model.railBand == .full, "\(name)")
            #expect(model.instrumentSize.width == MenuPanelSize.width, "\(name)")
            #expect(model.instrumentSize.height <= MenuPanelSize.railTallest, "\(name)")
            // The whole rail fits beside a search too, unscrolled (coordinator, build mode).
            #expect(MenuPanelSize.railHeight(.full, items: model.railItems) + MenuPanelSize.railChrome <= model.instrumentSize.height, "\(name)")
        }
        for name in ["B8-install", "B4-sum", "trigger", "system", "system-power"] {
            let model = try #require(states[name])
            #expect(model.railBand == .slim, "\(name)")
            #expect(model.instrumentSize.width == MenuPanelSize.width && model.shape == .wide, "\(name): every branch takes the wide panel in the Rail")
        }
        // Classic keeps today's shapes: Trigger stays narrow, at the one width.
        let classic = try #require(states["trigger"])
        classic.layout = .classic
        #expect(classic.railBand == .none && classic.shape == .narrow && classic.instrumentSize.width == MenuPanelSize.width)
    }

    @Test("Before typing, the line counts what a kind lists whole and nothing is the best match; windows head their workspace")
    func emptyRootKinds() throws {
        let states = try Dictionary(uniqueKeysWithValues: Self.states())
        let windows = try #require(states["B2-tab-windows"])
        #expect(windows.resultCount == "4 windows")
        #expect(windows.headings.mapValues { $0.title(goTo: true) } == [0: "Workspace 1", 3: "Workspace 2"])
        let apps = try #require(states["B2-tab-apps"])
        #expect(apps.resultCount == "5 apps")
        #expect(apps.headings.isEmpty, "a kind listed whole has no best match to head")
        #expect(try #require(states["B1-root"]).resultCount == nil)
        #expect(try #require(states["B3-search"]).resultCount?.hasSuffix("results") == true)
        var files = MenuNavigator(entries: try Self.built())
        for _ in 0..<3 { _ = files.handle(.tab) }
        #expect(MenuModel(nav: files).resultCount == nil, "Files before a search counts nothing")
    }

    @Test("System keeps its switches in the Rail, wide as it draws it, as in Classic")
    func systemSwitches() throws {
        let states = try Dictionary(uniqueKeysWithValues: Self.states())
        let power = try #require(states["system-power"])
        #expect(power.shape == .wide && power.inSystem, "the Rail draws System wide and still knows it is System")
        #expect(power.nav.rows.contains { $0.isOn != nil }, "Power lists switches")
        #expect(power.nav.spaceToggles, "Space flips Keep awake")
        power.layout = .classic
        #expect(power.shape == .system && power.inSystem)
        let search = try #require(states["B3-search"])
        #expect(!search.inSystem)
    }

    @Test("Waiting lists Update with its count and Clean with its size, only when each has something")
    func waiting() {
        let rows = MenuModel.waiting(updates: 3, clean: "2.1 GB")
        #expect(rows.map(\.title) == [MenuBranch.update.title, MenuBranch.clean.title])
        #expect(rows.map(\.detail) == ["3", "2.1 GB"])
        #expect(rows.map(\.target) == [.branch(.update), .branch(.clean)])
        #expect(MenuModel.waiting(updates: 0, clean: nil).isEmpty)
        #expect(MenuModel.waiting(updates: nil, clean: "").isEmpty)
    }

    @Test("Recent is the entries picked last, newest first, five at most")
    func recent() throws {
        let built = try Self.built()
        let now = Date(timeIntervalSince1970: 1_791_028_800)
        var picks = Frecency()
        for (i, key) in ["app:com.apple.finder", "app:com.mitchellh.ghostty", "action:system.lock"].enumerated() {
            picks.record(key, at: now.addingTimeInterval(Double(i) * 60))
        }
        let keys = MenuModel.recent(built, picks: picks).compactMap(\.frecencyKey)
        #expect(keys.first == "action:system.lock")
        let picked: Set<String> = ["app:com.apple.finder", "app:com.mitchellh.ghostty", "action:system.lock"]
        #expect(Set(keys) == picked.intersection(built.compactMap(\.frecencyKey)))
        #expect(MenuModel.recent(built, picks: Frecency()).isEmpty)
    }

    @Test("The Rail renders in Tokyo Night and Porcelain, frames B1–B3, B7, B8", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let (style, theme) = (look.style, look.themeID)
        defer { look.style = style; look.themeID = theme }
        look.style = .instrument
        let only = Self.env["PILOT_RENDER_ONLY"]
        for themeID in ["tokyo-night", "porcelain"] {
            look.themeID = themeID
            let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("menu-rail-\(themeID == "tokyo-night" ? "dark" : "light")")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, model) in try Self.states() where only.map(name.contains) ?? true {
                try InstrumentMenuRenders.render(MenuView(model: model), name, in: dir)
            }
        }
    }

    static func built() throws -> [MenuEntry] {
        let engine = Engine()
        return MenuEntries.build(
            apps: [("Ghostty", "com.mitchellh.ghostty"), ("Ghostex", "com.madda.ghostex.host"), ("Finder", "com.apple.finder"),
                   ("TextEdit", "com.apple.TextEdit"), ("Bitwarden", "com.bitwarden.desktop")],
            actions: engine.bindActions,
            store: BindStore(defaults: ["apps.terminal": Key("return"), AppsModule.openID(bundle: "com.madda.ghostex.host"): Key("g"),
                                        "system.lock": Key("escape"), "system.darkMode": Key("d", shift: true),
                                        "captures.menu": Key("c", .ctrl), "apps.emoji": Key("e", .ctrl)]),
            roleApps: ["apps.terminal": "com.mitchellh.ghostty"], menu: AppsModule.menuID, openID: AppsModule.openID(bundle:),
            running: ["com.mitchellh.ghostty", "com.apple.finder"],
            switches: ["system.darkMode": true, "system.keepAwake": false, "system.idleLock": true, "system.nightShift": false, "system.wifi": true])
    }

    /// Every state, named for its frame on the design page.
    static func states() throws -> [(String, MenuModel)] {
        let windows = try AeroWindow.parse(InstrumentMenuRenders.windows)
        let built = try built()
        let day = Date(timeIntervalSince1970: 1_791_028_800), home = NSHomeDirectory()
        func model(_ nav: MenuNavigator, recent: Bool = true, waiting: Bool = false) -> MenuModel {
            let m = MenuModel(nav: nav)
            m.layout = .rail
            m.windows = windows
            if waiting { m.waiting = MenuModel.waiting(updates: 3, clean: "2.1 GB") }
            if recent {
                var picks = Frecency()
                for (i, key) in ["app:com.madda.ghostex.host", "action:system.lock", "app:com.apple.finder", "app:com.mitchellh.ghostty"].enumerated() {
                    picks.record(key, at: day.addingTimeInterval(Double(i) * 60))
                }
                m.recent = MenuModel.recent(built, picks: picks)
            }
            return m
        }
        func withWindows(_ nav: inout MenuNavigator) { nav.provide(.window, MenuEntries.windows(windows, excluding: nil)) }
        var states: [(String, MenuModel)] = []

        states.append(("B1-root", model(MenuNavigator(entries: built), waiting: true)))
        states.append(("B1-root-no-recent", model(MenuNavigator(entries: built), recent: false)))
        var down = MenuNavigator(entries: built)
        for _ in 0..<3 { _ = down.handle(.down) }
        states.append(("B1-root-arrows", model(down)))

        var tabApps = MenuNavigator(entries: built)
        withWindows(&tabApps)
        _ = tabApps.handle(.tab)
        states.append(("B2-tab-apps", model(tabApps)))
        var tabWindows = tabApps
        _ = tabWindows.handle(.tab)
        _ = tabWindows.handle(.down)
        states.append(("B2-tab-windows", model(tabWindows)))

        var search = MenuNavigator(entries: built)
        search.query = "ghost"
        withWindows(&search)
        search.provide(.package, [MenuEntry(title: "Ghostty", target: .package("cask:ghostty"), detail: "1.2.0 → 1.2.1", icon: .cask)])
        search.provide(.file, MenuEntries.files([(home + "/.config/ghostty/config", day)], home: home))
        states.append(("B3-search", model(search)))
        var searchActions = search
        _ = searchActions.handle(.commandK)
        states.append(("B3-search-actions", model(searchActions)))

        var none = MenuNavigator(entries: built)
        none.query = "zzqxv"
        states.append(("B7-no-match", model(none)))

        states.append(("B8-install", model(MenuNavigator(entries: built, branch: .install))))

        var sum = MenuNavigator(entries: built)
        sum.query = "12*7+3"
        sum.provide(.answer, RootAnswers.entries(for: sum.query, now: day))
        states.append(("B4-sum", model(sum)))
        states.append(("trigger", model(MenuNavigator(entries: built, branch: .trigger))))
        states.append(("system", model(MenuNavigator(entries: built, branch: .system))))
        var power = MenuNavigator(entries: built, branch: MenuLayout.system("Power"))
        for _ in 0..<6 where power.selected?.target != .action("system.keepAwake") { _ = power.handle(.down) }
        states.append(("system-power", model(power)))
        var rootActions = MenuNavigator(entries: built)
        _ = rootActions.handle(.commandK)
        states.append(("root-actions", model(rootActions)))
        return states
    }
}
}
#endif
