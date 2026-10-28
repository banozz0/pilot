import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The one panel hung from a bar item (card agent-bo-95422914), on a fake presenter: no test shows a panel or touches the
/// real menu bar.
@MainActor
@Suite("Bar panel")
struct BarPanelTests {
    final class FakePresenter: BarPanelPresenting {
        var closed: () -> Void = {}
        var presented: [CGRect] = []
        var dismissed = 0
        func present(_ content: AnyView, under item: CGRect) { presented.append(item) }
        func dismiss() { dismissed += 1 }
    }

    static let cpu = CGRect(x: 1000, y: 870, width: 40, height: 30)
    static let clock = CGRect(x: 1200, y: 870, width: 60, height: 30)

    @Test("A click on the item showing its panel closes it; the next click opens it again")
    func sameItemCloses() {
        let fake = FakePresenter(), panel = BarPanel(presenter: fake)
        panel.toggle([.cpu], under: Self.cpu, AnyView(EmptyView()))
        #expect(fake.presented == [Self.cpu] && panel.shown == [.cpu])
        panel.toggle([.cpu], under: Self.cpu, AnyView(EmptyView()))
        #expect(fake.dismissed == 1 && panel.shown == nil)
        panel.toggle([.cpu], under: Self.cpu, AnyView(EmptyView()))
        #expect(fake.presented.count == 2 && panel.shown == [.cpu])
    }

    @Test("A click on another item opens that one's panel in its place")
    func otherItemReplaces() {
        let fake = FakePresenter(), panel = BarPanel(presenter: fake)
        panel.toggle([.cpu], under: Self.cpu, AnyView(EmptyView()))
        panel.toggle([.clock], under: Self.clock, AnyView(EmptyView()))
        #expect(fake.presented == [Self.cpu, Self.clock] && panel.shown == [.clock])
    }

    @Test("Closed from outside (a click elsewhere, Escape), the item's next click opens it rather than closing nothing")
    func outsideClose() {
        let fake = FakePresenter(), panel = BarPanel(presenter: fake)
        panel.toggle([.cpu], under: Self.cpu, AnyView(EmptyView()))
        fake.closed()
        #expect(panel.shown == nil)
        panel.toggle([.cpu], under: Self.cpu, AnyView(EmptyView()))
        #expect(fake.presented.count == 2 && panel.shown == [.cpu])
    }

    @Test("A display reconfiguration dismisses the old anchor; reopening uses the current bar position")
    func screenChangeCloses() {
        let fake = FakePresenter(), panel = BarPanel(presenter: fake)
        panel.toggle([.displays], under: Self.cpu, AnyView(EmptyView()))
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(fake.dismissed == 1 && panel.shown == nil)
        panel.toggle([.displays], under: Self.clock, AnyView(EmptyView()))
        #expect(fake.presented == [Self.cpu, Self.clock] && panel.shown == [.displays])
    }

    @Test("A right-click in a bar popover's panel reaches the row's anchor, never SwiftUI's context menu; off the row nothing takes it")
    func rightClickReachesAnchor() throws {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)), row = NSView(frame: NSRect(x: 0, y: 50, width: 200, height: 30))
        let anchor = ScreenAnchor.AnchorView(frame: row.bounds)
        var menus = 0
        anchor.rightClick = { menus += 1 }
        row.addSubview(anchor)
        root.addSubview(row)
        panel.contentView = root
        func send(_ type: NSEvent.EventType, at point: NSPoint) throws {
            panel.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        try send(.rightMouseDown, at: NSPoint(x: 20, y: 60))
        #expect(menus == 0)
        try send(.rightMouseUp, at: NSPoint(x: 20, y: 60))
        #expect(menus == 1)
        // Off the row nothing takes it.
        try send(.rightMouseUp, at: NSPoint(x: 20, y: 10))
        #expect(menus == 1)
    }
}
