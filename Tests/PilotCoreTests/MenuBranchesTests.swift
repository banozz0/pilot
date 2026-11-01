import Foundation
import Testing
@testable import PilotCore

/// Learn, Trigger and System (stories 22, 25, 27, 78 to 80; wireframe wo-nZ-ZEKkY sections 3 and 4): the menu's
/// branches fill from MenuLayout, the registry and the bind store. Pure, no GUI.
@Suite("Menu branches")
struct MenuBranchesTests {
    static let ids = ["engine.sheet", "captures.menu", "captures.area", "captures.activeWindow", "captures.fullscreen",
                      "captures.scrolling", "captures.screenRecording", "captures.ocr", "apps.emoji", "apps.clipboard",
                      "captures.pickColour", "system.menu", "system.lock", "system.sleep", "system.restart", "system.shutDown",
                      "system.logOut", "system.darkMode", "workspaces.rescue", "system.wifi", "system.bluetoothSettings",
                      "system.displaySettings", "system.focusSettings", "windows.close", "windows.minimise"]
    static let actions = ids.map { BindsPage.ActionInfo(id: $0, label: "label \($0)", module: "m") }
    static let store = BindStore(defaults: ["engine.sheet": Key("k"), "system.menu": Key("escape"), "captures.menu": Key("c", .ctrl),
                                            "captures.area": Key("s", .shift), "system.lock": Key("l", .ctrl), "windows.close": Key("w")])
    static let outputs = [BindsPage.ActionInfo(id: "system.output:73", label: "Play through AirPods", module: "system")]

    static func entries() -> [MenuEntry] {
        MenuEntries.build(apps: [], actions: actions, store: store, roleApps: [:], menu: "apps.launcher",
                          openID: { "apps.open:\($0)" }, running: [], extras: [MenuLayout.system("Sound"): outputs])
    }

    func ids(_ nav: MenuNavigator) -> [String] {
        nav.rows.map { if case .action(let id) = $0.target { id } else if case .branch(let b) = $0.target { "branch:\(b.rawValue)" } else { "?" } }
    }

    @Test("Learn holds Pilot's Keybindings only; AeroSpace's guide and the Omarchy manual are gone (card agent-bo-95422880)")
    func learn() {
        let nav = MenuNavigator(entries: Self.entries(), branch: .learn)
        #expect(nav.rows.map(\.title) == ["Keybindings"])
        #expect(nav.rows[0].detail == "Hyper+K")
        var root = MenuNavigator(entries: Self.entries())
        for guide in ["aerospace guide", "omarchy manual"] {
            root.query = guide
            #expect(root.matched.isEmpty)
        }
    }

    @Test("Keybindings lists every bind, as many rows as the store has binds, each with its key; Return runs one")
    func keybindings() {
        var nav = MenuNavigator(entries: Self.entries(), branch: .keybindings)
        #expect(nav.rows.count == Self.store.binds.count)
        #expect(nav.rows.allSatisfy { $0.detail != nil })
        nav.query = "label windows.close"
        #expect(nav.handle(.return) == .run(nav.rows[0]))
        #expect(nav.rows[0].target == .action("windows.close"))
    }

    @Test("A branch inside a branch: Escape goes up one level, to Learn with Keybindings selected, then to the root")
    func nested() {
        var nav = MenuNavigator(entries: Self.entries(), branch: .keybindings)
        #expect(nav.path == [.learn, .keybindings])
        #expect(nav.handle(.escape) == .handled)
        #expect(nav.branch == .learn)
        #expect(nav.selected?.title == "Keybindings")
        #expect(nav.handle(.return) == .handled)
        #expect(nav.branch == .keybindings)
        #expect(nav.handle(.left) == .handled)
        #expect(nav.handle(.escape) == .handled)
        #expect(nav.branch == nil)
        #expect(nav.selected?.title == "Learn")
    }

    @Test("Trigger holds Capture, the emoji grid, the colour picker, clipboard history, Stickers and GIFs, Translate, Define, Reminders, Snippets, Notes and QR; Capture holds the grabs")
    func trigger() {
        let trigger = MenuNavigator(entries: Self.entries(), branch: .trigger)
        #expect(ids(trigger) == ["branch:capture", "branch:emoji", "captures.pickColour", "apps.clipboard", "branch:stickers", "branch:translate", "branch:define", "branch:reminders",
                               "branch:snippets", "branch:notes", "branch:qr"])
        #expect(trigger.rows[0].detail == "Hyper+Ctrl+C")
        let capture = MenuNavigator(entries: Self.entries(), branch: .capture)
        #expect(ids(capture) == ["captures.area", "captures.activeWindow", "captures.fullscreen", "captures.scrolling",
                                 "captures.screenRecording", "captures.ocr"])
        #expect(capture.path == [.trigger, .capture])
    }

    @Test("System holds the machine controls, dark mode, rescue, Hammerspoon's chooser rows and one row per sound output, in sub-branches (C6)")
    func system() {
        let nav = MenuNavigator(entries: Self.entries(), branch: .system)
        // Only the sub-branches something landed in (unregistered() has none).
        #expect(nav.rows.map(\.title) == ["Power", "Sound", "Connections", "Display", "Focus", "Fix it"])
        func ids(in title: String) -> [String] { self.ids(MenuNavigator(entries: Self.entries(), branch: MenuLayout.system(title))) }
        #expect(ids(in: "Power") == ["system.lock", "system.sleep", "system.restart", "system.shutDown", "system.logOut"])
        #expect(ids(in: "Sound") == ["system.output:73"])
        #expect(ids(in: "Connections") == ["system.wifi", "system.bluetoothSettings"])
        #expect(ids(in: "Display") == ["system.darkMode", "system.displaySettings"])
        #expect(ids(in: "Focus") == ["system.focusSettings"])
        #expect(ids(in: "Fix it") == ["workspaces.rescue"])
        let power = MenuNavigator(entries: Self.entries(), branch: MenuLayout.system("Power"))
        #expect(power.rows[0].detail == "Hyper+Ctrl+L")
        #expect(MenuNavigator(entries: Self.entries(), branch: MenuLayout.system("Sound")).rows.first?.title == "Play through AirPods")
    }

    @Test("Typing at the root finds a bound action once, as its branch's row, an opener only as its branch, and the inner branches")
    func search() {
        var nav = MenuNavigator(entries: Self.entries())
        nav.query = "label system.lock"
        #expect(nav.rows.filter { $0.target == .action("system.lock") }.count == 1)
        #expect(nav.rows[0].target == .action("system.lock"))
        #expect(nav.rows[0].home == MenuLayout.system("Power"))
        nav.query = "label engine.sheet"
        #expect(nav.matched.isEmpty)
        nav.query = "label system.menu"
        #expect(nav.matched.isEmpty)
        nav.query = "capture"
        #expect(nav.rows.first?.target == .branch(.capture))
        #expect(nav.handle(.return) == .handled)
        #expect(nav.path == [.trigger, .capture])
    }

    @Test("A layout row whose action is not registered is left out, never shown as a dead row")
    func unregistered() {
        let entries = MenuEntries.build(apps: [], actions: [], store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher",
                                        openID: { "apps.open:\($0)" }, running: [])
        #expect(MenuNavigator(entries: entries, branch: .system).rows.isEmpty)
        #expect(MenuNavigator(entries: entries, branch: .learn).rows.map(\.title) == ["Keybindings"])
    }

    @Test("The root lists the ten top branches, Clean after Update (card agent-bo-95422881), About above System (Q446), System last; Config, Activity and Stats are extra rows")
    func branches() {
        #expect(MenuBranch.top == [.apps, .learn, .trigger, .install, .remove, .update, .clean, .extensions, .about, .system])
        #expect(MenuBranch.searched == MenuBranch.top.dropLast(3) + [.config, .extensions, .about, .system, .activity, .stats])
        #expect(MenuBranch.keybindings.parent == .learn)
        #expect(MenuBranch.capture.parent == .trigger)
    }
}
