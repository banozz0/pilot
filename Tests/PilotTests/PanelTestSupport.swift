import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Pilot

extension Trait where Self == ConditionTrait {
    /// Sven's QA, never an agent's run: the test makes a non-activating panel key, which takes his keyboard from the front
    /// app even hidden or off screen, or shows a window on his screen. `PILOT_FOCUS=1 swift test --filter <Suite>` runs it.
    static var pilotFocus: Self {
        .enabled(if: ProcessInfo.processInfo.environment["PILOT_FOCUS"] == "1", "takes the keyboard or shows a window: PILOT_FOCUS=1")
    }
}

/// The hidden-panel harness the menu and clipboard focus tests share: a real HUD panel, never drawn (alpha 0, no mouse).
@MainActor
enum PanelTestSupport {
    /// Turns the run loop until it has had nothing to do for two 10 ms turns in a row, at most `seconds`: what a change
    /// set off on this thread (SwiftUI's update, a scroll to the selection, the search field's focus, a main-actor Task)
    /// has landed by then, so a quiet panel costs about 20 ms instead of the whole wait (card agent-bo-95423300).
    static func pump(_ seconds: Double = 0.3) {
        drawingQoS()
        let deadline = Date.now + seconds
        var quiet = 0
        while quiet < 2, Date.now < deadline {
            let end = min(Date.now + 0.01, deadline)
            // Returns early once it has handled a source: something still ran.
            RunLoop.current.run(mode: .default, before: end)
            quiet = Date.now >= end ? quiet + 1 : 0
        }
    }

    /// `view` in a top bar's own window (TopBarWindows.panel) at the screen's origin, `size` big, shown but hidden.
    static func bar(_ view: some View, size: CGSize) -> NSPanel {
        testApp()
        let panel = TopBarWindows.panel(NSHostingView(rootView: view), level: TopBarWindows.aboveMenuBar)
        panel.setFrame(NSRect(origin: .zero, size: size), display: false)
        hide(panel).orderFrontRegardless()
        pump()
        return panel
    }

    static func hide(_ panel: NSPanel) -> NSPanel {
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        return panel
    }

    /// `view` in a panel as HUD.makePanel builds it, hidden, key, its search field given the keyboard.
    static func open(_ view: some View) -> NSPanel {
        testApp()
        let panel = hide(HUD.makePanel(view))
        panel.makeKeyAndOrderFront(nil)
        pump()
        return panel
    }

    /// One key through a search panel's key monitor as Pilot runs it (HUD.searchKey), then to the window when the
    /// monitor passes it on, as AppKit would. `handle` stands in for the panel's own keys.
    static func key(_ c: String, code: UInt16 = 8, flags: NSEvent.ModifierFlags = [], into panel: NSWindow,
                    handle: @MainActor (UInt16, NSEvent.ModifierFlags, String?) -> Bool = { _, _, _ in false },
                    keepsSearch: @MainActor () -> Bool = { true }, beforeTyping: @MainActor () -> Void = {}) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber,
                                     context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code)!
        if !HUD.searchKey(event, in: panel, handle: handle, keepsSearch: keepsSearch, beforeTyping: beforeTyping, log: { _ in }) { panel.sendEvent(event) }
    }

    static func type(_ text: String, into panel: NSWindow) {
        for c in text {
            let s = String(c)
            panel.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                             context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: 8)!)
        }
        pump(0.1)
    }

    /// The pointer over `point` (window coordinates): told to the hosting view as the window server would, since a hidden
    /// panel gets no mouse of its own. What decides whether the pointer moved is the test's PointerTrack (TestPointer).
    static func hover(_ panel: NSWindow, at point: CGPoint) {
        guard let host = (panel.contentView as? MaterialBackdrop)?.content,
              let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return }
        host.mouseEntered(with: event)
        host.mouseMoved(with: event)
        pump(0.01)
    }

    /// A click at `point` (window coordinates), down and up, through the panel as the window server sends one. Never on a
    /// scroller: it tracks the press in a loop of its own, waiting for an up a hidden panel never gets (and SwiftUI drops
    /// a tap whose up is already queued as the down arrives). `right` presses the right button.
    static func click(_ panel: NSWindow, at point: CGPoint, right: Bool = false, modifiers: NSEvent.ModifierFlags = []) {
        if panel.contentView?.hitTest(point) is NSScroller { Issue.record("the click at \(point) lands on a scroller"); return }
        let now = ProcessInfo.processInfo.systemUptime
        let (down, up): (NSEvent.EventType, NSEvent.EventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        for (type, at) in [(down, now), (up, now + 0.05)] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: at, windowNumber: panel.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: type == down ? 1 : 0) else { return }
            panel.sendEvent(event)
        }
        pump(0.05)
    }

    /// What a scroll view shows, in its window's coordinates: its rows' full width, short of a scroller's gutter.
    static func shown(_ scroll: NSScrollView) -> CGRect { scroll.convert(scroll.contentView.frame, to: nil) }
}

/// The pointer on the screen as a test moves it (card agent-bo-95422994): the panel's PointerTrack reads it, so nothing
/// reads or moves Sven's pointer.
@MainActor
final class TestPointer {
    var at = CGPoint(x: 500, y: 500)
    lazy var track = PointerTrack { [unowned self] in self.at }

    /// The pointer moved onto `point` (window coordinates): a new place on the screen, then the hover there.
    func move(_ panel: NSWindow, to point: CGPoint) {
        at.x += 1
        PanelTestSupport.hover(panel, at: point)
    }

    /// The pointer moved down a column from `top` to `bottom`, 3 pt a step: each index `selection` changed to, with the
    /// height it changed at, within 3 pt under that row's top edge.
    func sweep(_ panel: NSWindow, x: CGFloat, from top: CGFloat, to bottom: CGFloat, _ selection: () -> Int) -> [(index: Int, y: CGFloat)] {
        var met: [(index: Int, y: CGFloat)] = []
        var last = selection()
        for y in stride(from: top, to: bottom, by: -3) {
            move(panel, to: CGPoint(x: x, y: y))
            let now = selection()
            if now != last { met.append((now, y)) }
            last = now
        }
        return met
    }
}
