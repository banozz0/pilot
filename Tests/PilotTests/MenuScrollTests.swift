import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Sven, 2026-10-07: Arrow Down onto the last row of a long search (Search files for "…") left it under the list's
/// edge; only the scroll wheel showed it. The real panel and view, hidden (alpha 0, no mouse), in the styles named
/// (card agent-bo-95423182), each picked here: Look.shared's defaults domain is the test runner's, shared by every run.
@MainActor
@Suite("Menu scroll", .serialized)
struct MenuScrollTests {
    /// Draws `style`'s menu while `body` runs, then puts the pick back.
    static func picking(_ style: PilotStyle, _ body: () throws -> Void) rethrows {
        let look = Look.shared
        let was = look.style
        look.style = style
        defer { look.style = was }
        try body()
    }

    @Test("Arrow Down to the last row of a long list scrolls it whole into view", arguments: [PilotStyle.toybox])
    func lastRowShows(_ style: PilotStyle) throws { try Self.picking(style) { try lastRowShows() } }

    func lastRowShows() throws {
        testApp()
        let apps = (1...30).map { MenuEntry(title: "Appy \($0)", target: .app("dev.banozz.test.appy\($0)"), home: .apps) }
        var nav = MenuNavigator(entries: apps)
        nav.query = "appy"
        let model = MenuModel(nav: nav)
        let panel = Self.panel(model)
        defer { panel.orderOut(nil) }
        panel.orderFront(nil)
        PanelTestSupport.pump()
        // The offers sit after the best match (Q182), so the list ends with its last app.
        #expect(model.nav.rows.last?.kind == .app)
        for _ in model.nav.rows.indices {
            _ = model.nav.handle(.down)
            PanelTestSupport.pump()
        }
        #expect(model.nav.selection == model.nav.rows.count - 1)
        let scroll = try #require(Self.scrollViews(in: panel.contentView).first)
        let document = try #require(scroll.documentView)
        // The list ends with the last row and the list's inset; the whole row must be inside what shows. Waited for, not
        // pumped a fixed while: a loaded run starves the scroll past pump's quiet turns (full runs, 2026-10-11).
        #expect(AliasesListTests.until(within: 10) { Self.bottomGap(scroll) <= 10 },
                "visible \(scroll.documentVisibleRect), document \(document.bounds), flipped \(document.isFlipped)")
    }

    /// Sven, 2026-10-07: an app's ten Cmd+K actions rode over the search line and the kind tabs, the last one hidden with
    /// no hint. They stay under the search line's hairline and scroll there, Arrow Down bringing the last one whole into view.
    @Test("Cmd+K's actions stay under the search line and Arrow Down scrolls the last one into view",
          arguments: PilotStyle.allCases)
    func actionsStayUnderTheSearchLine(_ style: PilotStyle) throws { try Self.picking(style) { try actionsStayUnderTheSearchLine() } }

    func actionsStayUnderTheSearchLine() throws {
        testApp()
        var nav = MenuNavigator(entries: [MenuEntry(title: "Finder", target: .app("com.apple.finder"), home: .apps, running: true)])
        nav.query = "finder"
        _ = nav.handle(.commandK)
        let model = MenuModel(nav: nav)
        // Eleven since Set alias… (card agent-bo-95423037); Pin to the top came and went (Sven 2026-10-20).
        #expect(model.nav.actions?.visible.count == 11)
        let panel = Self.panel(model)
        defer { panel.orderOut(nil) }
        panel.orderFront(nil)
        PanelTestSupport.pump()
        // The list's scroll is the panel's width; the popover's is its own, narrower.
        let scroll = try #require(Self.scrollViews(in: panel.contentView).min { $0.frame.width < $1.frame.width })
        let content = try #require(panel.contentView)
        // Instrument's popover is a ViewThatFits: the plain list when every action fits whole, its scroll only when they do
        // not. C3's bigger panel holds all eleven, so no scroll of the popover's own is the proof that none is cut; Arrow
        // Down still walks to the last one.
        if Look.shared.style == .instrument {
            #expect(scroll.frame.width >= content.bounds.width, "Instrument's eleven actions no longer fit whole: they scroll")
            for _ in 1...10 {
                _ = model.nav.handle(.down)
                PanelTestSupport.pump(0.05)
            }
            #expect(model.nav.actions?.selection == 10)
            return
        }
        #expect(scroll.frame.width < content.bounds.width, "no scroll inside the popover: \(Self.scrollViews(in: panel.contentView).map(\.frame))")
        let searchLine: CGFloat = 62
        let top = scroll.convert(scroll.bounds, to: content).maxY
        #expect(top <= content.bounds.height - searchLine, "the actions start \(content.bounds.height - top) pt from the top")
        // To the one before the last: in view with the list's end at most a hairline below it.
        for _ in 1..<10 {
            _ = model.nav.handle(.down)
            PanelTestSupport.pump(0.15)
        }
        #expect(model.nav.actions?.selection == 9)
        let document = try #require(scroll.documentView)
        let visible = scroll.documentVisibleRect
        #expect(Self.bottomGap(scroll) <= 7, "visible \(visible), document \(document.bounds), flipped \(document.isFlipped)")
        // B3 (Sven, 2026-10-09): the last action, Set Hyper bind, sat under the bottom fade and its chevron. Reaching it
        // scrolls to the list's very end, so nothing is cut below and no fade draws over it.
        _ = model.nav.handle(.down)
        PanelTestSupport.pump(0.15)
        #expect(model.nav.actions?.selection == 10)
        #expect(Self.bottomGap(scroll) <= 1, "last action: visible \(scroll.documentVisibleRect), document \(document.bounds)")
    }

    /// The menu's panel as PilotMenu.makePanel builds it, hidden, on a pointer that never moves. Its default reads the real
    /// one: Sven's or another agent's mouse moving over where the hidden panel sits hovers the rows the keys scroll under
    /// it, and the selection follows the pointer back up the list (the full runs' 3-in-5 flake, 2026-10-12).
    static func panel(_ model: MenuModel) -> NSPanel {
        PanelTestSupport.hide(HUD.makePanel(MenuView(model: model, pointer: PointerTrack { .zero }), surface: .menu))
    }

    /// How far the document's end lies past what shows.
    static func bottomGap(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return .infinity }
        let visible = scroll.documentVisibleRect
        return document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
    }

    static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        if let scroll = view as? NSScrollView, scroll.documentView != nil { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }
}
}
