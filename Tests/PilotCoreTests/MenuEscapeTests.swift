import Foundation
import Testing
@testable import PilotCore

/// Escape goes back one level everywhere in the menu, and closes it only at the root (card agent-bo-95423020): inside
/// every branch, and in a picker opened from a menu row (System › Kill a process, a confirm).
@Suite("Menu Escape")
struct MenuEscapeTests {
    /// Every branch's own row in its parent, as MenuEntries.build places them, plus an Install category.
    static let branches = MenuBranch.allCases + [.category("Editors")]
    static let entries = branches.compactMap { b in b.parent.map { MenuEntry(title: b.title, target: .branch(b), home: $0) } }

    @Test("Escape inside every branch goes up to its parent with the branch just left selected; at the root it closes")
    func everyBranchGoesUp() {
        for branch in Self.branches {
            // Config, Activity and Stats are extra rows since Sven 2026-10-21: on, so the root lists them to select.
            var nav = MenuNavigator(entries: Self.entries, branch: branch, root: MenuRoot(extras: ["config", "activity", "stats"]))
            #expect(nav.handle(.escape) == .handled, "\(branch.rawValue) closed the menu")
            #expect(nav.branch == branch.parent, "\(branch.rawValue)")
            #expect(nav.selected?.target == .branch(branch), "\(branch.rawValue)")
        }
        var root = MenuNavigator(entries: Self.entries)
        #expect(root.handle(.escape) == .close)
    }

    @Test("One Escape inside a branch with a filter typed drops the filter and goes up")
    func filterGoesWithIt() {
        var nav = MenuNavigator(entries: Self.entries, branch: .learn)
        nav.query = "key"
        #expect(nav.handle(.escape) == .handled)
        #expect(nav.branch == nil)
    }

    @Test("A picker opened from a menu row goes back there on Escape, typed filter and all; one a bind opened closes")
    func pickerGoesBack() {
        let rows = [MenuEntry(title: "swift-frontend", target: .action("30061")), MenuEntry(title: "find", target: .action("33146"))]
        let entries = Self.entries + [MenuEntry(title: "Lock", target: .action("system.lock"), home: .system),
                                      MenuEntry(title: "Kill a process", target: .action("system.killProcess"), home: .system)]
        var system = MenuNavigator(entries: entries, branch: .system)
        system.query = "kill"
        let spot = system.spot
        #expect(spot == MenuNavigator.Spot(branch: .system, query: "kill", row: .action("system.killProcess")))

        var picker = MenuNavigator(list: rows, title: "Kill a process", back: spot)
        #expect(picker.back == spot)
        picker.query = "fin"
        #expect(picker.handle(.escape) == .back(spot), "the typed filter does not stop the way back")

        var bound = MenuNavigator(list: rows, title: "Kill a process")
        #expect(bound.back == nil)
        #expect(bound.handle(.escape) == .close)

        // The panel reopens the menu and puts it back where it stood.
        var reopened = MenuNavigator(entries: entries, branch: .system)
        reopened.go(to: spot)
        #expect(reopened.branch == .system)
        #expect(reopened.query == "kill")
        #expect(reopened.selected?.target == .action("system.killProcess"))
    }

    @Test("Back at the root or a branch with nothing typed, the row that opened the picker is selected")
    func backSelectsTheRow() {
        var nav = MenuNavigator(entries: Self.entries, branch: .trigger)
        nav.go(to: MenuNavigator.Spot(branch: .trigger, row: .branch(.reminders)))
        #expect(nav.selected?.target == .branch(.reminders))
        nav.go(to: MenuNavigator.Spot(branch: nil, row: .branch(.update)))
        #expect(nav.branch == nil)
        #expect(nav.selected?.target == .branch(.update))
    }
}
