#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import Pilot

/// The top bar's own mouse (card agent-bo-95423027): lane 1's night check right-clicked and scrolled its items to no
/// effect while a left click worked. Each event goes through the bar's window as the window server sends it.
@MainActor
@Suite("Top bar events", .serialized)
struct TopBarEventsTests {
    final class Hits {
        var clicks = 0, menus = 0
        var steps: [Int] = []
    }

    /// One item as TopBarSlotView.item builds it (a plain button, its tooltip, its ScreenAnchor), in the bar's window at
    /// the screen's origin, so a scroll's screen point is its window point; hidden.
    static func bar(_ hits: Hits) -> NSPanel {
        let item = Button { hits.clicks += 1 } label: { Text("Volume 40%").frame(width: 120, height: 24) }
            .buttonStyle(.plain)
            .help("Volume 40%")
            .background(ScreenAnchor(box: ScreenAnchor.Box(), rightClick: { hits.menus += 1 }, scroll: { hits.steps.append($0) }))
        return PanelTestSupport.bar(HStack { item }.frame(width: 300, height: 30), size: CGSize(width: 300, height: 30))
    }

    static let onItem = NSPoint(x: 150, y: 15)

    /// One wheel notch up at `onItem` on the main screen (the panel sits at its origin).
    static func notch() throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        cg.location = CGPoint(x: onItem.x, y: NSScreen.screens[0].frame.height - onItem.y)
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test("The bar's window shows its items' tooltips while another app is in front (card agent-bo-95423028)")
    func tooltipsWhileInactive() {
        let panel = Self.bar(Hits())
        defer { panel.close() }
        #expect(panel.allowsToolTipsWhenApplicationIsInactive)
    }

    @Test("A right-click on an item opens its menu once and never runs its click")
    func rightClick() {
        let hits = Hits()
        let panel = Self.bar(hits)
        defer { panel.close() }
        PanelTestSupport.click(panel, at: Self.onItem, right: true)
        #expect(hits.menus == 1)
        #expect(hits.clicks == 0)
    }

    @Test("A scroll on an item steps it, up positive, and a left click still runs its click and no menu")
    func scrollAndClick() throws {
        let hits = Hits()
        let panel = Self.bar(hits)
        defer { panel.close() }
        panel.sendEvent(try Self.notch())
        // Up is up whichever way natural scrolling turns the wheel (ScreenAnchor.AnchorView.take).
        #expect(hits.steps == [1])
        PanelTestSupport.click(panel, at: Self.onItem)
        #expect(hits.clicks == 1)
        #expect(hits.menus == 0)
    }

    @Test("A right-click on another app's item opens that app's menu; Option+right-click opens Pilot's Other apps menu (Sven on build 60)")
    func otherAppsRightClick() {
        var apps = 0, pilot = 0
        // As TopBarSlotView draws Other apps: the slot's anchor (Pilot's menu) behind, an app's button (MenuAppButton) on it.
        let app = Button {} label: {
            Text("Wispr").frame(width: 60, height: 24)
                .background(ScreenAnchor(box: ScreenAnchor.Box(), rightClick: { apps += 1 }, optionPasses: true))
        }
        .buttonStyle(.plain)
        let slot = HStack(spacing: 0) { Text("›").frame(width: 30, height: 24); app }
            .background(ScreenAnchor(box: ScreenAnchor.Box(), rightClick: { pilot += 1 }))
        let panel = PanelTestSupport.bar(HStack { slot }.frame(width: 300, height: 30), size: CGSize(width: 300, height: 30))
        defer { panel.close() }
        let onApp = NSPoint(x: 165, y: 15), onChevron = NSPoint(x: 120, y: 15)
        PanelTestSupport.click(panel, at: onApp, right: true)
        #expect((apps, pilot) == (1, 0))
        PanelTestSupport.click(panel, at: onApp, right: true, modifiers: .option)
        #expect((apps, pilot) == (1, 1))
        PanelTestSupport.click(panel, at: onChevron, right: true)
        #expect((apps, pilot) == (1, 2))
    }
}
#endif
