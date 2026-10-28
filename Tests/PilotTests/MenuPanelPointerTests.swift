import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The menu by mouse (card agent-bo-95422994, G6), in the real panel and view, hidden (alpha 0, no mouse):
/// hovers go to the hosting view, clicks through the panel, and the pointer's place on the screen is the test's.
/// The panel draws on Look.shared, so it runs inside SharedLook: another suite's style there moved the kind tabs.
extension SharedLook {
@MainActor
@Suite("Menu panel pointer", .serialized)
final class MenuPanelPointerTests {
    let pointer = TestPointer()
    /// What the clicks came to, as the panel would carry them out.
    var outcomes: [MenuNavigator.Outcome] = []

    /// Two apps matching "te" at the root: Best match, Apps and Search files, each under its heading, all in view.
    static let entries = ["Terminal", "TextEdit"].map { MenuEntry(title: $0, target: .app("dev.banozz.test.\($0)"), home: .apps) }

    func menu(_ nav: MenuNavigator) -> (MenuModel, NSPanel) {
        let model = MenuModel(nav: nav)
        model.onClick = { [unowned self] outcome, _ in outcomes.append(outcome) }
        return (model, PanelTestSupport.open(MenuView(model: model, pointer: pointer.track)))
    }

    func rootSearch() -> MenuNavigator {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "te"
        return nav
    }

    /// The panel's search field, as HUD finds it.
    static func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }

    /// The list's scroll, in window coordinates, short of a scroller.
    func list(_ panel: NSPanel) throws -> CGRect {
        PanelTestSupport.shown(try #require(SharedLook.MenuScrollTests.scrollViews(in: panel.contentView).max { $0.frame.width < $1.frame.width }))
    }

    @Test("A track counts the hovers of one pointer move, from the first that sees it somewhere new until the run loop turns; not as the panel opens, nor after")
    func counts() {
        let track = pointer.track
        #expect(!track.moved())
        pointer.at.y -= 30
        // The panel's hover, then the row's, inside one mouse event.
        #expect(track.moved())
        #expect(track.moved())
        PanelTestSupport.pump(0.05)
        // The keys scrolled another row under the still pointer: its hover is no move.
        #expect(!track.moved())
    }

    @Test("The pointer selects each row it moves onto in order, headings are no rows, a click anywhere across a row runs it as Return does, and the search keeps the keyboard", .pilotFocus)
    func rows() throws {
        let (model, panel) = menu(rootSearch())
        defer { panel.orderOut(nil) }
        let list = try list(panel)
        let rows = model.nav.rows
        // From the last row, so the first one's top edge shows as a change.
        model.nav.point(at: rows.count - 1)
        PanelTestSupport.pump(0.1)
        let tops = pointer.sweep(panel, x: list.midX, from: list.maxY - 1, to: list.minY + 1) { model.nav.selection }
        #expect(tops.map(\.index) == Array(rows.indices), "rows met top to bottom: \(tops.map(\.index)) of \(rows.count)")
        let top = Dictionary(uniqueKeysWithValues: tops.map { ($0.index, $0.y) })

        // A heading sits just over the first row of its group: neither a hover nor a click there does anything.
        let headed = MenuGroups.headings(rows, searching: true, branch: nil).keys.sorted()
        #expect(headed.count >= 2)
        for index in headed {
            let over = CGPoint(x: list.midX, y: try #require(top[index]) + 9)
            let before = model.nav.selection
            pointer.move(panel, to: over)
            PanelTestSupport.click(panel, at: over)
            #expect(model.nav.selection == before, "the heading over row \(index) took the selection")
            #expect(outcomes.isEmpty, "the heading over row \(index) ran \(outcomes)")
        }

        // A click near either edge runs the row under it, as Return on it does.
        // The best match, then Ask AI (Sven Q174): both run on Return.
        #expect(rows[0].kind == .app && rows[1].target == .ask("te"), "rows: \(rows.map(\.title))")
        PanelTestSupport.click(panel, at: CGPoint(x: list.minX + 14, y: try #require(top[1]) - 8))
        PanelTestSupport.click(panel, at: CGPoint(x: list.maxX - 14, y: try #require(top[0]) - 8))
        #expect(outcomes == [.run(rows[1]), .run(rows[0])])
        #expect(HUD.focusSearch(in: panel) == .had)
    }

    @Test("A list the keys scroll under a still pointer keeps the keys' row; the pointer moving again takes the row under it", .pilotFocus)
    func stillPointer() throws {
        let apps = (1...30).map { MenuEntry(title: "Appy \($0)", target: .app("dev.banozz.test.appy\($0)"), home: .apps) }
        var nav = MenuNavigator(entries: apps)
        nav.query = "appy"
        let (model, panel) = menu(nav)
        defer { panel.orderOut(nil) }
        let list = try list(panel)
        let spot = CGPoint(x: list.midX, y: list.maxY - 120)
        pointer.move(panel, to: spot)
        let pointed = model.nav.selection
        #expect(pointed > 0)
        // The pointer comes to rest on the list's top inset, over no row, and the keys run the list to its end.
        let inset = CGPoint(x: list.midX, y: list.maxY - 2)
        pointer.move(panel, to: inset)
        for _ in model.nav.rows.indices {
            _ = model.nav.handle(.down)
            PanelTestSupport.pump(0.03)
        }
        let last = model.nav.rows.count - 1
        #expect(model.nav.selection == last)
        // The rows under the pointer changed while it stayed: the hovers SwiftUI tells them are no move.
        PanelTestSupport.hover(panel, at: CGPoint(x: inset.x + 1, y: inset.y))
        PanelTestSupport.hover(panel, at: CGPoint(x: inset.x + 1, y: inset.y - 30))
        #expect(model.nav.selection == last, "a row slid under the still pointer took the selection")
        pointer.move(panel, to: CGPoint(x: spot.x + 2, y: spot.y))
        #expect(model.nav.selection > pointed && model.nav.selection < last, "after the scroll the pointer is over \(model.nav.selection)")
    }

    @Test("A click on each kind tab shows that kind, left to right in Tab's order, and the search keeps the keyboard", .pilotFocus)
    func kinds() throws {
        let (model, panel) = menu(rootSearch())
        defer { panel.orderOut(nil) }
        let list = try list(panel)
        var shown: [MenuEntry.Kind?] = [model.nav.only]
        // 12 pt apart, under the narrowest kind's width, across the status line Classic draws at the panel's foot (Classic
        // Shell, Q139), level with that line's middle. A kind shown resizes the panel (it is as tall as its rows), so the
        // panel is fitted again before each click.
        #expect(model.layout == .classic)
        for x in stride(from: list.minX + 2, to: list.maxX - 2, by: 12) {
            // The panel follows the menu's size as the app's does: the Files view takes the full height for its preview pane.
            PilotMenu.fit(panel, face: model.instrumentSize)
            panel.contentView?.layoutSubtreeIfNeeded()
            let content = try #require(panel.contentView)
            let line = content.convert(content.bounds, to: nil).minY + MenuPanelSize.classicStatus / 2
            PanelTestSupport.click(panel, at: CGPoint(x: x, y: line))
            if model.nav.only != shown.last { shown.append(model.nav.only) }
        }
        #expect(shown == MenuEntry.Kind.tabOrder, "kinds clicked: \(shown)")
        #expect(HUD.focusSearch(in: panel) == .had)
    }

    @Test("Cmd+K's actions take the pointer in order over the list, and a click runs one as Return on it does", .pilotFocus)
    func actions() throws {
        var nav = rootSearch()
        // The second hit that has actions: Ask AI and Search the web follow the best match and have none (Sven Q174).
        let row = try #require(nav.rows.indices.dropFirst().first { !nav.rows[$0].isOffer })
        for _ in 0..<row { _ = nav.handle(.down) }
        #expect(nav.handle(.commandK) == .handled)
        var viaKeys = nav
        _ = viaKeys.handle(.down)
        let expected = viaKeys.handle(.return)
        let (model, panel) = menu(nav)
        defer { panel.orderOut(nil) }
        let list = try list(panel)
        let x = try #require(panel.contentView).bounds.maxX - 70
        // From the first action, the one Cmd+K opens on: each next one's top edge shows as a change.
        let tops = pointer.sweep(panel, x: x, from: list.maxY - 1, to: list.minY + 1) { model.nav.actions?.selection ?? -1 }
        let count = try #require(model.nav.actions).visible.count
        #expect(tops.count >= min(count - 1, 3) && tops.map(\.index) == Array(1...tops.count), "actions met: \(tops.map(\.index)) of \(count)")
        // The first sits over the second, clear of a group's hairline, which is no action; the list's rows under the
        // pointer stayed as they were.
        pointer.move(panel, to: CGPoint(x: x, y: try #require(tops.first).y + 14))
        #expect(model.nav.actions?.selection == 0)
        #expect(model.nav.selection == row)
        PanelTestSupport.click(panel, at: CGPoint(x: x, y: try #require(tops.first { $0.index == 1 }).y - 8))
        #expect(outcomes == [expected])
        #expect(model.nav.actions == nil)
    }
}
}
