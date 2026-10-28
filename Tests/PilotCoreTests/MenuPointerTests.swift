import Foundation
import Testing
@testable import PilotCore

/// The menu by mouse (card agent-bo-95422994, G6): a click on a kind tab shows that kind, a hover puts the selection on
/// the row under the pointer, and a click on a row does what Return does there. Pure, no GUI.
@Suite("Menu pointer")
struct MenuPointerTests {
    static let textEdit = MenuEntry(title: "TextEdit", target: .app("com.apple.TextEdit"), home: .apps)
    static let terminal = MenuEntry(title: "Terminal", target: .app("com.apple.Terminal"), home: .apps)
    static let lock = MenuEntry(title: "Terminal: lock", target: .action("system.lock"))
    static let entries = [textEdit, terminal, lock]

    @Test("A click on a kind tab shows that kind, as Tab reaching it does; All shows every kind again")
    func tabClick() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "term"
        nav.show(.action)
        #expect(nav.only == .action)
        #expect(nav.rows.map(\.target) == [Self.lock.target])
        nav.show(nil)
        #expect(nav.only == nil)
        #expect(nav.rows.contains(Self.terminal))
    }

    @Test("A hover selects the row under the pointer; a row past the end changes nothing")
    func hover() {
        var nav = MenuNavigator(entries: Self.entries, branch: .apps)
        nav.point(at: 1)
        #expect(nav.selection == 1)
        nav.point(at: 9)
        #expect(nav.selection == 1)
    }

    @Test("A click on a row is Return on it: an app runs, a branch opens")
    func rowClick() {
        var apps = MenuNavigator(entries: Self.entries, branch: .apps)
        let row = apps.rows[1]
        #expect(apps.click(at: 1) == .run(row))
        var root = MenuNavigator(entries: Self.entries)
        let learn = try! #require(root.rows.firstIndex { $0.target == .branch(.learn) })
        #expect(root.click(at: learn) == .handled)
        #expect(root.branch == .learn)
    }

    @Test("While Cmd+K's actions show, a hover or click on a list row does nothing; their own rows take it")
    func actionsFirst() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "textedit"
        #expect(nav.handle(.commandK) == .handled)
        let menu = try! #require(nav.actions)
        nav.point(at: 1)
        #expect(nav.selection == 0)
        #expect(nav.click(at: 0) == .handled)
        #expect(nav.actions != nil)
        nav.pointAction(at: 1)
        #expect(nav.actions?.selection == 1)
        let second = menu.visible[1]
        let outcome = nav.clickAction(at: 1)
        #expect(nav.actions == nil)
        var viaReturn = MenuNavigator(entries: Self.entries)
        viaReturn.query = "textedit"
        _ = viaReturn.handle(.commandK)
        _ = viaReturn.handle(.down)
        #expect(viaReturn.actions?.selected == second)
        #expect(viaReturn.handle(.return) == outcome)
    }
}
