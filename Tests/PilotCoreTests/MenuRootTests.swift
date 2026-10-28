import Foundation
import Testing
@testable import PilotCore

/// Your own menu (story 152, task N6): the root's branches in Sven's order, some hidden, found by a search all the same;
/// a saved id no branch has is ignored and a branch the saved order never named stands in its default place. Pure.
@Suite("Menu root")
struct MenuRootTests {
    static let today: [MenuBranch] = [.apps, .learn, .trigger, .install, .remove, .update, .clean, .extensions, .about, .system]

    func listed(_ nav: MenuNavigator) -> [MenuBranch] {
        nav.rows.compactMap { if case .branch(let b) = $0.target { b } else { nil } }
    }

    @Test("Nothing saved is today's nine in today's order, all shown")
    func standard() {
        #expect(MenuRoot().arranged() == Self.today)
        #expect(MenuRoot().isDefault())
        #expect(listed(MenuNavigator(entries: [], root: MenuRoot())) == Self.today)
    }

    @Test("A saved order and hidden rows shape the root before typing")
    func orderAndHide() {
        var root = MenuRoot()
        root.move(.system, to: 0)
        root.move(.apps, to: 99)
        root.show(.learn, false)
        root.show(.clean, false)
        #expect(root.order == ["system", "learn", "trigger", "install", "remove", "update", "clean", "extensions", "about", "apps"])
        #expect(root.shown() == [.system, .trigger, .install, .remove, .update, .extensions, .about, .apps])
        #expect(!root.isDefault())
        #expect(listed(MenuNavigator(entries: [], root: root)) == root.shown())
        root.show(.learn, true)
        #expect(root.shown().contains(.learn))
    }

    @Test("A hidden row still comes up when its name is typed at the root")
    func hiddenSearchable() {
        var nav = MenuNavigator(entries: [], root: MenuRoot(hidden: ["clean"]))
        #expect(!listed(nav).contains(.clean))
        nav.query = "clean"
        #expect(nav.rows.first?.target == .branch(.clean))
        // Config is an extra, off by default (Sven 2026-10-21): not listed, found by name all the same, once when on.
        var config = MenuNavigator(entries: [], root: MenuRoot())
        #expect(!listed(config).contains(.config))
        config.query = "config"
        #expect(config.rows.first?.target == .branch(.config))
        var on = MenuNavigator(entries: [], root: MenuRoot(extras: ["config"]))
        #expect(on.rows.last?.target == .branch(.config))
        on.query = "config"
        #expect(on.rows.count { $0.target == .branch(.config) } == 1)
        // A deeper branch an extra opened goes back to the root, its row selected (Sven 2026-10-21); through its parent,
        // back to the parent.
        var notes = MenuNavigator(entries: [], root: MenuRoot(extras: ["notes"]))
        while notes.selected?.target != .branch(.notes) { _ = notes.handle(.down) }
        _ = notes.handle(.return)
        #expect(notes.branch == .notes && notes.path == [.notes])
        _ = notes.handle(.escape)
        #expect(notes.branch == nil && notes.selected?.target == .branch(.notes))
        notes.go(to: .init(branch: .notes))
        #expect(notes.path == [.trigger, .notes])
        _ = notes.handle(.escape)
        #expect(notes.branch == .trigger)
    }

    @Test("Unknown saved ids are ignored; a new branch takes its default place, shown")
    func unknownAndNew() {
        let root = MenuRoot(order: ["gone", "system", "apps", "learn", "trigger", "install", "update", "clean", "config", "gone"],
                            hidden: ["gone", "reports"])
        // Remove, Extensions and About were never saved: each follows the branch it follows by default. "config", saved while
        // Config was a branch, is an unknown id now.
        #expect(root.arranged() == [.system, .apps, .learn, .trigger, .install, .remove, .update, .clean, .extensions, .about])
        let withConfig = MenuRoot(order: ["config", "system", "extra:config"], extras: ["config"]).rows()
        #expect(withConfig.filter { $0.title == "Config" }.count == 1 && withConfig.last?.extra?.id == "config")
        #expect(root.shown() == root.arranged())
        // A list with a new first branch the saved order never named puts it first.
        let withNew: [MenuBranch] = [.snippets] + Self.today
        #expect(MenuRoot(order: ["system", "apps"]).arranged(withNew)
                == [.snippets, .system, .apps, .learn, .trigger, .install, .remove, .update, .clean, .extensions, .about])
        // Unknown ids alone change nothing.
        #expect(MenuRoot(order: ["gone"], hidden: ["gone"]).isDefault())
    }
}
