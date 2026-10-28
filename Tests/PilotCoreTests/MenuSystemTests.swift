import Foundation
import Testing
@testable import PilotCore

/// The 2026-10-09 menu round: System in sub-branches opened with → (C6), and Space flipping a switch row with the menu
/// left open (S1). Pure, no GUI.
@Suite("Menu System")
struct MenuSystemTests {
    static let ids = MenuLayout.systemSections.flatMap(\.ids)
    static let switches = ["system.darkMode": false, "system.keepAwake": false, "system.idleLock": true, "system.nightShift": false,
                           "system.wifi": true]

    static func entries() -> [MenuEntry] {
        let actions = ids.map { BindsPage.ActionInfo(id: $0, label: $0 == "system.keepAwake" ? "Keep awake on or off" : $0, module: "system") }
        let extras = [MenuLayout.system("Sound"): [BindsPage.ActionInfo(id: "system.output:73", label: "Play through AirPods", module: "system")]]
        return MenuEntries.build(apps: [], actions: actions, store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher",
                                 openID: { "apps.open:\($0)" }, running: [], extras: extras, switches: switches)
    }

    func ids(_ rows: [MenuEntry]) -> [String] {
        rows.map {
            switch $0.target {
            case .action(let id): id
            case .branch(let b): b.rawValue
            default: "?"
            }
        }
    }

    @Test("System lists its six sub-branches in order, no heading, whatever was picked most")
    func subBranches() {
        var picks = Frecency()
        picks.record("branch:system:Fix it", at: .now)
        let nav = MenuNavigator(entries: Self.entries(), branch: .system, frecency: picks)
        #expect(ids(nav.rows) == ["system:Power", "system:Sound", "system:Connections", "system:Display", "system:Focus", "system:Fix it"])
        #expect(nav.rows.map(\.title) == ["Power", "Sound", "Connections", "Display", "Focus", "Fix it"])
        #expect(MenuGroups.headings(nav.rows, searching: false, branch: .system).isEmpty)
        #expect(MenuPanelSize.shape(branch: .system, query: "", isList: false) == .system)
    }

    @Test("Right opens a sub-branch, Left goes back to System on it; the outputs land in Sound, Focus holds its settings")
    func rightOpens() {
        var nav = MenuNavigator(entries: Self.entries(), branch: .system)
        _ = nav.handle(.down)
        #expect(nav.handle(.right) == .handled)
        #expect(nav.branch == MenuLayout.system("Sound") && nav.path == [.system, MenuLayout.system("Sound")])
        #expect(ids(nav.rows) == ["system.soundSettings", "system.output:73"])
        #expect(MenuPanelSize.shape(branch: nav.branch, query: "", isList: false) == .system, "a sub-branch keeps System's width")
        #expect(nav.handle(.left) == .handled)
        #expect(nav.branch == .system && nav.selected?.target == .branch(MenuLayout.system("Sound")))
        let focus = MenuNavigator(entries: Self.entries(), branch: MenuLayout.system("Focus"))
        #expect(ids(focus.rows) == ["system.focusSettings"])
        let power = MenuNavigator(entries: Self.entries(), branch: MenuLayout.system("Power"))
        #expect(ids(power.rows) == ["system.lock", "system.sleep", "system.restart", "system.shutDown", "system.logOut",
                                    "system.keepAwake", "system.idleLock"])
    }

    @Test("Every row System held before is in exactly one sub-branch")
    func everyRowPlaced() {
        let before = ["system.lock", "system.sleep", "system.restart", "system.shutDown", "system.logOut", "system.darkMode",
                      "system.keepAwake", "system.nightShift", "system.idleLock", "system.wifi", "system.bluetoothSettings",
                      "system.displaySettings", "system.focusSettings", "system.nextWallpaper", "system.previousWallpaper",
                      "workspaces.rescue", "system.killProcess", "system.speedTest"]
        for id in before { #expect(Self.ids.filter { $0 == id }.count == 1, "\(id)") }
    }

    @Test("A search in System finds rows in every sub-branch, headed by its name, the sub-branch rows it matched under Go to")
    func search() {
        var nav = MenuNavigator(entries: Self.entries(), branch: .system)
        nav.query = "dark"
        #expect(ids(nav.rows) == ["system.darkMode"])
        #expect(MenuGroups.headings(nav.rows, searching: false, branch: .system) == [0: .section("Display")])
        nav.query = "sound"
        #expect(ids(nav.rows).contains("system:Sound") && ids(nav.rows).contains("system.soundSettings"))
        let headings = MenuGroups.headings(nav.rows, searching: false, branch: .system)
        let sound = nav.rows.firstIndex { $0.target == .branch(MenuLayout.system("Sound")) }!
        #expect(headings.values.contains(.goTo) && headings.values.contains(.section("Sound")), "\(headings)")
        #expect((0...sound).reversed().compactMap { headings[$0] }.first == .goTo, "the Sound row sits under Go to")
    }

    @Test("Space on a switch with nothing typed flips its row and keeps the menu open; Return still runs it")
    func spaceToggles() {
        var nav = MenuNavigator(entries: Self.entries(), branch: MenuLayout.system("Power"))
        for _ in 0..<6 where nav.selected?.target != .action("system.keepAwake") { _ = nav.handle(.down) }
        let row = nav.selected!
        #expect(nav.handle(.space) == .toggle(row))
        #expect(nav.selected?.target == .action("system.keepAwake"), "the selection stays on the row")
        #expect(nav.selected?.isOn == true, "the row shows its new state at once")
        #expect(nav.branch == MenuLayout.system("Power"))
        let flipped = nav.selected!
        #expect(nav.handle(.space) == .toggle(flipped))
        #expect(nav.selected?.isOn == false)
        #expect(nav.handle(.return) == .run(nav.selected!), "Return keeps today's behaviour")
    }

    @Test("Space is typed whenever something is typed, or the row is no switch")
    func spaceTyped() {
        var typed = MenuNavigator(entries: Self.entries(), branch: MenuLayout.system("Power"))
        typed.query = "keep"
        #expect(typed.selected?.target == .action("system.keepAwake"))
        #expect(typed.handle(.space) == .ignored, "a space inside a search is the search's")
        #expect(typed.selected?.isOn == false)
        var plain = MenuNavigator(entries: Self.entries(), branch: MenuLayout.system("Power"))
        #expect(plain.selected?.target == .action("system.lock"))
        #expect(plain.handle(.space) == .ignored, "Lock screen switches nothing")
        var root = MenuNavigator(entries: Self.entries())
        #expect(root.handle(.space) == .ignored)
        var picker = MenuNavigator(list: [MenuEntry(title: "On", target: .action("x"), isOn: true)])
        #expect(picker.handle(.space) == .ignored, "a picker's rows are picked, never flipped")
    }

    @Test("The states read again after a toggle land on their rows, the selection kept")
    func statesReadAgain() {
        var nav = MenuNavigator(entries: Self.entries(), branch: MenuLayout.system("Power"))
        for _ in 0..<6 where nav.selected?.target != .action("system.keepAwake") { _ = nav.handle(.down) }
        _ = nav.handle(.space)
        nav.switches(["system.keepAwake": true, "system.idleLock": false])
        #expect(nav.selected?.target == .action("system.keepAwake"))
        #expect(nav.rows.first { $0.target == .action("system.idleLock") }?.isOn == false, "Lock when idle follows Keep awake")
        #expect(nav.rows.first { $0.target == .action("system.lock") }?.isOn == nil, "a row with no switch gets none")
    }

    @Test("The QR tools and Eject all disks sit in Trigger beside the colour picker, Eject no longer in Power (Sven, Build 79)")
    func toolboxRows() {
        #expect(MenuLayout.rows[MenuLayout.system("Power")]?.contains(.action("system.ejectAll")) == false)
        let trigger = MenuLayout.rows[.trigger] ?? []
        let colour = trigger.firstIndex(of: .action("captures.pickColour"))
        #expect(colour.map { Array(trigger[($0 + 1)...($0 + 3)]) } == [.action("captures.makeQR"), .action("captures.readQR"), .action("system.ejectAll")])
    }

    @Test("More rows' QR opens Trigger › QR with Make and Read, back goes to the root, and a search finds each once (Sven, Q398)")
    func qrBranch() {
        #expect(MenuBranch.qr.parent == .trigger && MenuBranch.qr.title == "QR")
        #expect(MenuLayout.rows[.qr] == [.action("captures.makeQR"), .action("captures.readQR")])
        #expect(MenuLayout.rows[.capture]?.contains(.action("captures.readQRScreen")) == true)
        let actions = ["captures.makeQR", "captures.readQR", "captures.readQRScreen"].map { BindsPage.ActionInfo(id: $0, label: $0, module: "captures") }
        let entries = MenuEntries.build(apps: [], actions: actions, store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher",
                                        openID: { "apps.open:\($0)" }, running: [])
        var nav = MenuNavigator(entries: entries, root: MenuRoot(extras: ["qr"]))
        for _ in 0..<20 where nav.selected?.target != .branch(.qr) { _ = nav.handle(.down) }
        _ = nav.handle(.return)
        #expect(nav.branch == .qr)
        #expect(ids(nav.rows) == ["captures.makeQR", "captures.readQR"])
        _ = nav.handle(.escape)
        #expect(nav.branch == nil, "a branch opened from a root extra goes back to the root")
        nav.query = "captures.makeQR"
        #expect(nav.rows.count { $0.target == .action("captures.makeQR") } == 1, "Trigger's copy alone is searched")
    }
}
