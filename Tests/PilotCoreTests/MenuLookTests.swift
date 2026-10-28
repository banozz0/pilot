import Foundation
import Testing
@testable import PilotCore

/// The round 11 menu (card agent-bo-95422981, mockups A to C of card agent-bo-95422969): the root one narrow list that
/// widens as Sven types, System in sections, and what each row says beside its title. Pure, no GUI.
@Suite("Menu look")
struct MenuLookTests {
    static let systemIDs = ["system.lock", "system.sleep", "system.restart", "system.shutDown", "system.logOut", "system.darkMode",
                            "system.keepAwake", "system.nightShift", "system.idleLock", "workspaces.rescue", "system.wifi",
                            "system.bluetoothSettings", "system.displaySettings", "system.focusSettings", "system.killProcess",
                            "system.speedTest"]
    static let labels = ["system.darkMode": "Dark mode on or off", "system.wifi": "Wi-Fi on or off", "system.keepAwake": "Keep awake on or off",
                         "workspaces.rescue": "Rescue workspaces"]

    static func entries(switches: [String: Bool] = [:], apps: [(name: String, bundle: String)] = [], more: [BindsPage.ActionInfo] = []) -> [MenuEntry] {
        let actions = systemIDs.map { BindsPage.ActionInfo(id: $0, label: labels[$0] ?? $0, module: "system") } + more
        return MenuEntries.build(apps: apps, actions: actions, store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher",
                                 openID: { "apps.open:\($0)" }, running: [],
                                 extras: [MenuLayout.system("Sound"): [BindsPage.ActionInfo(id: "system.output:73", label: "Play through AirPods", module: "system")]],
                                 switches: switches)
    }

    func ids(_ rows: [MenuEntry]) -> [String] { rows.map { if case .action(let id) = $0.target { id } else { "?" } } }

    @Test("The root lists the nine branches as one list, Extensions above System, with no heading")
    func root() {
        #expect(MenuBranch.top == [.apps, .learn, .trigger, .install, .remove, .update, .clean, .extensions, .about, .system])
        let nav = MenuNavigator(entries: Self.entries())
        #expect(nav.rows.map(\.target) == MenuBranch.top.map { .branch($0) })
        #expect(MenuGroups.headings(nav.rows, searching: false).isEmpty)
    }

    @Test("Writing the same search again keeps the selection; a new one, or going in and up, ranks again")
    func sameQueryKeepsSelection() {
        var nav = MenuNavigator(entries: Self.entries())
        _ = nav.handle(.down)
        nav.query = ""
        #expect(nav.selection == 1, "the field hands back its text as it takes focus")
        _ = nav.handle(.return)
        #expect(nav.branch == .learn && !nav.rows.isEmpty, "going in with nothing typed still lists the branch")
        _ = nav.handle(.escape)
        #expect(nav.branch == nil && nav.rows.count == 10 && nav.selection == 1, "up lists the root with Learn selected")
        nav.query = "lo"
        #expect(nav.selection == 0)
    }

    @Test("With text typed Left and Right move the caret (Sven 2026-10-12); Tab and Shift+Tab step the kind tabs, wrapping; with nothing typed the arrows keep their jobs")
    func arrowsMoveTheCaret() {
        var nav = MenuNavigator(entries: Self.entries())
        nav.query = "shottr"
        #expect(nav.handle(.right) == .ignored, "the search field moves its caret")
        #expect(nav.handle(.left) == .ignored)
        #expect(nav.only == nil)
        #expect(nav.handle(.tab) == .handled)
        #expect(nav.only == .app)
        #expect(nav.handle(.backTab) == .handled)
        #expect(nav.only == nil)
        #expect(nav.handle(.backTab) == .handled)
        #expect(nav.only == .package, "Shift+Tab from All wraps to the last kind")
        #expect(nav.handle(.tab) == .handled)
        #expect(nav.only == nil, "Tab from the last kind wraps to All")
        // A root search whose selected row is a branch: → still leaves it to the caret.
        nav.query = "sys"
        #expect(nav.selected?.target == .branch(.system))
        #expect(nav.handle(.right) == .ignored)
        #expect(nav.branch == nil)
        // Nothing typed: → opens the selected branch, ← goes up.
        nav.query = ""
        while nav.selected?.target != .branch(.system) { _ = nav.handle(.down) }
        #expect(nav.handle(.right) == .handled)
        #expect(nav.branch == .system)
        // Inside a branch Left with nothing typed still goes up; with a filter typed the arrows move its caret.
        var filtered = MenuNavigator(entries: Self.entries(), branch: .system)
        filtered.query = "dark"
        #expect(filtered.handle(.left) == .ignored)
        #expect(filtered.handle(.right) == .ignored)
        var branch = MenuNavigator(entries: Self.entries(), branch: .system)
        #expect(branch.handle(.left) == .handled)
        #expect(branch.branch == nil)
    }

    // System's sub-branches, their order, search and headings: MenuSystemTests (C6).

    @Test("Other branches carry no headings")
    func otherBranches() {
        let rows = [MenuEntry(title: "Ghostty", target: .app("g"), home: .apps)]
        #expect(MenuGroups.headings(rows, searching: false, branch: .apps).isEmpty)
    }

    @Test("A switch's state rides on its row; a row with no switch has none")
    func switches() {
        let rows = Self.entries(switches: ["system.darkMode": true, "system.wifi": false])
        #expect(rows.first { $0.target == .action("system.darkMode") }?.isOn == true)
        #expect(rows.first { $0.target == .action("system.wifi") }?.isOn == false)
        #expect(rows.first { $0.target == .action("system.lock") }?.isOn == nil)
    }

    @Test("A switch row reads as the thing it switches, as mockup B: Dark mode, Wi-Fi, Keep awake; search keeps the full title")
    func switchTitles() {
        let switches = ["system.darkMode": true, "system.wifi": false, "system.keepAwake": false]
        let rows = Self.entries(switches: switches)
        func row(_ id: String) -> MenuEntry? { rows.first { $0.target == .action(id) } }
        #expect(row("system.darkMode")?.shownTitle == "Dark mode")
        #expect(row("system.wifi")?.shownTitle == "Wi-Fi")
        #expect(row("system.keepAwake")?.shownTitle == "Keep awake")
        #expect(row("system.lock")?.shownTitle == row("system.lock")?.title, "a row with no switch keeps its title")
        #expect(row("system.wifi")?.title == "Wi-Fi on or off")
    }

    @Test("Narrow at the root and in Trigger and Capture, System its own width, wide once typing at the root or anywhere else")
    func width() {
        #expect(MenuPanelSize.shape(branch: nil, query: "", isList: false) == .narrow)
        #expect(MenuPanelSize.shape(branch: nil, query: "g", isList: false) == .wide)
        for b in [MenuBranch.trigger, .capture] {
            #expect(MenuPanelSize.shape(branch: b, query: "", isList: false) == .narrow)
            #expect(MenuPanelSize.shape(branch: b, query: "x", isList: false) == .narrow, "a filter inside a branch keeps its width")
        }
        #expect(MenuPanelSize.shape(branch: .system, query: "", isList: false) == .system)
        for b in [MenuBranch.apps, .learn, .keybindings, .install, .homebrew, .remove, .update, .clean, .config, .translate, .reminders, .category("Fonts")] {
            #expect(MenuPanelSize.shape(branch: b, query: "", isList: false) == .wide)
        }
        #expect(MenuPanelSize.shape(branch: nil, query: "", isList: true) == .wide, "a picker")
        // Every size one scale step up (C3, PilotStyle.scale), as the menu's type and rows are.
        let s = MenuPanelSize.s
        #expect(s(360) == 388 && s(44) == 47, "one step: 14/13")
    }

    @Test("Instrument's menu is 750 wide (Q130) and as tall as its rows and headings in every shape, two rows at least, up to each shape's tallest, which Cmd+K takes (card agent-bo-95423181)")
    func instrumentHeight() {
        // Mockup A's heights, one scale step up (C3), rows a step taller and every shape Raycast's 750 wide (Q130).
        let s = MenuPanelSize.s, w: CGFloat = 750
        let rows = MenuPanelSize.instrument(.wide, rows: 6, headings: 3), more = MenuPanelSize.instrument(.wide, rows: 7, headings: 3)
        #expect(rows == CGSize(width: w, height: s(112) + 6 * s(44) + 3 * s(28)), "search line, foot and insets 112, rows 44, headings 28")
        #expect(more.height - rows.height == MenuPanelSize.instrumentWideRow)
        #expect(MenuPanelSize.instrument(.narrow, rows: 9, headings: 0) == CGSize(width: w, height: s(112) + 9 * s(40)), "the root's nine whole")
        #expect(MenuPanelSize.instrument(.wide, rows: 0, headings: 0) == CGSize(width: w, height: s(112) + 2 * s(44)), "an empty list keeps room for its line")
        #expect(MenuPanelSize.instrument(.wide, rows: 1, headings: 1, extra: 76) == CGSize(width: w, height: s(112) + s(44) + s(28) + 76),
                "what shows under the rows takes the empty line's place: no phantom row (Moody vzACUY1p1lU)")
        #expect(MenuPanelSize.instrument(.wide, rows: 0, headings: 0, extra: 330) == CGSize(width: w, height: s(112) + 330), "Clean's wait at its own height")
        #expect(MenuPanelSize.instrument(.wide, rows: 40, headings: 6).height == s(540))
        #expect(MenuPanelSize.instrument(.system, rows: 40, headings: 6) == CGSize(width: w, height: s(600)))
        #expect(MenuPanelSize.instrument(.narrow, rows: 3, headings: 0, full: true).height == s(560))
    }

    @Test("Toybox's panel: its 50 pt rows set a narrow panel's height up to a cap; it keeps its own widths, Instrument's 750 aside (Q130)")
    func toyboxSize() {
        let nine = MenuPanelSize.toybox(.narrow, rows: 9), four = MenuPanelSize.toybox(.narrow, rows: 4)
        #expect(nine.height - four.height == 5 * MenuPanelSize.toyboxRowPitch)
        #expect(MenuPanelSize.toyboxRowPitch == MenuPanelSize.s(50), "mockup B's 50, one scale step up (C3)")
        #expect(nine.width == MenuPanelSize.s(440))
        #expect(MenuPanelSize.toybox(.narrow, rows: 40).height == MenuPanelSize.toybox(.narrow, rows: 30).height, "capped")
        #expect(MenuPanelSize.toybox(.narrow, rows: 0).height == MenuPanelSize.toybox(.narrow, rows: 2).height, "an empty one keeps room for its line")
        for shape in [MenuPanelSize.Shape.system, .wide] {
            #expect(MenuPanelSize.toybox(shape, rows: 3) == MenuPanelSize.toybox(shape, rows: 40), "\(shape) is one size")
            #expect(MenuPanelSize.toybox(shape, rows: 3).width == MenuPanelSize.s(shape == .wide ? 720 : 480))
        }
    }

    @Test("An action titled App: verb belongs to that app: its icon, the verb as its title, the app's name beside it")
    func owner() {
        let rows = Self.entries(apps: [("Bitwarden", "com.bitwarden.desktop")],
                                more: [.init(id: "apps.bitwardenSearch", label: "Bitwarden: search vault", module: "apps"),
                                       .init(id: "apps.lazygit", label: "lazygit: pick a repo", module: "apps"),
                                       .init(id: "x.y", label: "Nope: no such app", module: "x")])
        let search = rows.first { $0.target == .action("apps.bitwardenSearch") }!
        #expect(search.app == "com.bitwarden.desktop")
        #expect(search.shownTitle == "Search vault")
        #expect(search.subtitle == "Bitwarden")
        #expect(search.searchText == "Bitwarden: search vault", "search still matches the whole title")
        let other = rows.first { $0.target == .action("x.y") }!
        #expect(other.app == nil && other.shownTitle == "Nope: no such app" && other.subtitle == nil)
    }

    @Test("A window belongs to its app")
    func windowApp() {
        let w = AeroWindow(id: 4, appName: "Finder", bundleId: "com.apple.finder", pid: 1, workspace: "3", monitorId: 1, layout: "h_tiles", title: "Downloads")
        #expect(MenuEntries.windows([w], excluding: nil).first?.app == "com.apple.finder")
    }

    @Test("Each row's kind as a word on the right; a file shows its day instead, an answer nothing")
    func kindWord() {
        #expect(MenuEntry(title: "Ghostty", target: .app("g")).kindWord == "App")
        #expect(MenuEntry(title: "x", target: .window(1)).kindWord == "Window")
        #expect(MenuEntry(title: "x", target: .action("a")).kindWord == "Action")
        #expect(MenuEntry(title: "x", target: .package("p")).kindWord == "Package")
        #expect(MenuEntry(title: "x", target: .branch(.apps)).kindWord == "Menu")
        #expect(MenuEntry(title: "x", target: .file("/f")).kindWord == nil)
        #expect(MenuEntry(title: "= 4", target: .copy("4"), isAnswer: true).kindWord == nil)
    }

    @Test("The foot names what Return does to the current row")
    func returnLabel() {
        #expect(MenuEntry(title: "Ghostty", target: .app("g")).returnLabel == "Open app")
        #expect(MenuEntry(title: "x", target: .window(1)).returnLabel == "Focus window")
        #expect(MenuEntry(title: "x", target: .file("/f")).returnLabel == "Open file")
        #expect(MenuEntry(title: "Bitwarden: search vault", target: .action("a")).returnLabel == "Run")
        #expect(MenuEntry(title: "x", target: .package("p")).returnLabel == "Install")
        #expect(MenuEntry(title: "Apps", target: .branch(.apps)).returnLabel == "Open")
        #expect(MenuEntry(title: "= 4", target: .copy("4"), isAnswer: true).returnLabel == "Copy")
        #expect(MenuEntry(title: "🔥", target: .emoji("🔥")).returnLabel == "Type")
    }
}
