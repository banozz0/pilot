#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Home settles with a scroller that always shows (Sven, builds 23 and 24, 2026-10-10: the app window open on Home with
/// Glass on hung the main thread ~20 s after launch, its page drawn wider than the window). The
/// width Home lays its blocks out by was the scroll view's, which with such a scroller is its content's plus the
/// scroller's, so each pass grew the page by a scroller until the render never ended. It sets Look.shared, so it runs
/// inside SharedLook, one suite at a time.
extension SharedLook {
@MainActor
@Suite("Home settles", .serialized)
struct HomeSettleTests {
    /// Ends the run when the main thread is still in one step after `seconds`: a render that never ends never hands back
    /// to the test, so no expectation could fail.
    final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var armed: (what: String, step: Int)?
        private var step = 0

        func arm(_ what: String, seconds: Double = 10) {
            let mine = lock.withLock { step += 1; armed = (what, step); return step }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                if let armed = lock.withLock({ armed }), armed.step == mine { fatalError("Home never settled at \(armed.what)") }
            }
        }

        func disarm() { lock.withLock { armed = nil } }
    }

    @Test("Home in the app window settles at every size with a scroller that always shows, and its page keeps to the window; Instrument's fills the window while it fits, else scrolls (2026-10-10, idle RAM)")
    func settles() throws {
        testApp()
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        defer { (look.style, look.themeID, look.glass) = saved }
        (look.style, look.themeID, look.glass) = (.instrument, "orchid", true)

        // Taller than the smaller windows, so the scroller shows there.
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        var home = HomeLayout(rows: [])
        for id in ["workspaces", "keyboard", "thisMac"] { home.set(id, shown: true) }
        let store = HomeLayoutStore(defaults: defaults)
        store.save(home)
        var sources = HomeSources()
        sources.lastCopied = { nil }
        sources.recentCopies = { [] }
        sources.pages = { [] }
        sources.layout = { store }
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        model.go(AppPlace(.home))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model)
            .environment(try SharedLook.HomeRenders.engine()).environment(\.homeSources, sources)))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        defer { window.close() }
        // The scroller Sven's Mac shows with a mouse attached, in place of the overlay one a test run reads.
        window.contentView?.layoutSubtreeIfNeeded()
        PanelTestSupport.pump(0.1)
        func scrollViews(_ view: NSView) -> [NSScrollView] { [view as? NSScrollView].compactMap { $0 } + view.subviews.flatMap(scrollViews) }
        let scrolls = scrollViews(try #require(window.contentView))
        try #require(!scrolls.isEmpty, "Home drew no scroll view")
        for scroll in scrolls { scroll.scrollerStyle = .legacy }

        let dog = Watchdog()
        // Sven's window, the smallest, the tiler's whole-screen tile, and back down.
        for size in [NSSize(width: 1629, height: 1183), NSSize(width: 800, height: 600), NSSize(width: 2659, height: 1183), NSSize(width: 1000, height: 600)] {
            dog.arm("\(size)")
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            PanelTestSupport.pump(0.1)
            dog.disarm()
            #expect(window.contentRect(forFrameRect: window.frame).size == size, "Home pushed the window past \(size)")
            // Home's own scroll view, the widest (the sidebar has one too).
            if let scroll = scrolls.max(by: { $0.frame.width < $1.frame.width }), let page = scroll.documentView {
                // The tall windows hold the page whole: it fills them to the foot; the short ones scroll it.
                let fills = size.height > 1000
                #expect((page.frame.height <= scroll.contentView.bounds.height + 0.5) == fills, "\(size): page \(page.frame.height) in \(scroll.contentView.bounds.height)")
                #expect(scroll.hasVerticalScroller == !fills, "\(size): a scroller on a page that fits, or none on one that scrolls")
            }
        }
    }

    static func key(_ characters: String, code: UInt16, command: Bool = false, in window: NSWindow) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? .command : [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        return event.map(window.performKeyEquivalent) ?? false
    }

    @Test("Edit mode starts from ⌘E in the app window; its bar lies inside the window at its foot at 760×520, 1000×660, 1440×900 and 1720×1440; Escape throws the edit away (spec home-edit, check 10)")
    func editBarInside() throws {
        testApp()
        let look = Look.shared
        let saved = (look.style, look.themeID)
        defer { (look.style, look.themeID) = saved }
        (look.style, look.themeID) = (.instrument, "lagoon")
        let store = HomeLayoutStore(defaults: try #require(UserDefaults(suiteName: testSuite())))
        var sources = HomeSources()
        sources.lastCopied = { nil }
        sources.recentCopies = { [] }
        sources.pages = { [] }
        sources.layout = { store }
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        model.go(AppPlace(.home))
        let watch = HomeEditWatch()
        let host = NSHostingView(rootView: AppWindowView(model: model).environment(try SharedLook.HomeRenders.engine())
            .environment(\.homeSources, sources).environment(\.homeEditWatch, watch))
        let window = AppWindowController.makeWindow(content: host)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        defer { window.close() }
        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            PanelTestSupport.pump(0.3)
        }
        settle()
        #expect(!watch.on && watch.bar == nil, "edit mode is off at first")
        #expect(Self.key("e", code: 14, command: true, in: window), "⌘E found no Edit Home")
        settle()
        for size in [NSSize(width: 760, height: 520), NSSize(width: 1000, height: 660), NSSize(width: 1440, height: 900), NSSize(width: 1720, height: 1440)] {
            window.setContentSize(size)
            settle()
            #expect(watch.on, "\(size): edit mode off after ⌘E")
            let bar = try #require(watch.bar, "\(size): no edit bar after ⌘E")
            let room = CGRect(origin: .zero, size: size).insetBy(dx: HomeEditBar.margin - 0.5, dy: HomeEditBar.margin - 0.5)
            #expect(room.contains(bar) && bar.height == HomeEditBar.height, "\(size): the edit bar at \(bar) is not inside the window")
            // Pinned to the window's foot, and at least as wide as its buttons and some tray.
            #expect(abs(bar.maxY - (size.height - HomeEditBar.margin)) < 1 && bar.width >= 400, "\(size): the edit bar at \(bar) is not at the foot")
        }
        // Escape, as a key press reaches the window: the edit is thrown away and edit mode ends; nothing is saved.
        window.makeFirstResponder(host)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        settle()
        #expect(!watch.on, "edit mode still on after Escape")
        #expect(store.layout == .standard)
        // ⌘E again, then Return: Done keeps the layout, the default as nothing saved, and edit mode ends.
        #expect(Self.key("e", code: 14, command: true, in: window))
        settle()
        #expect(watch.on)
        #expect(Self.key("\r", code: 36, in: window), "Return found no Done")
        settle()
        #expect(!watch.on, "edit mode still on after Return")
        #expect(store.layout == .standard)
    }
}
}
#endif
