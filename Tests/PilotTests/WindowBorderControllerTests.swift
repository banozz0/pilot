import AppKit
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95422950: the focused-window border's settings, its controller on a fake surface, and the panel it
/// draws in, never ordered front. No real window is read or framed.
@MainActor
@Suite("Window border controller")
struct WindowBorderControllerTests {
    /// Records what the controller asks the panel to show.
    final class FakeSurface: WindowBorderSurface {
        var shown: (frame: CGRect, width: Int, color: UInt32)?
        var hides = 0
        func show(frame: CGRect, width: Int, color: UInt32, above: CGWindowID?) { shown = (frame, width, color) }
        func hide() { shown = nil; hides += 1 }
    }

    /// A Look of the test's own; the same `defaults` twice reads back what the first saved.
    static func look(defaults: UserDefaults = LookTests.defaults()) -> Look {
        Look(themes: [], ghostty: LookTests.FakeGhostty(), defaults: defaults)
    }

    static let window = WindowBorder.Window(frame: CGRect(x: 100, y: 50, width: 800, height: 600), subrole: "AXStandardWindow", fullScreen: false, minimised: false)

    func controller(_ look: Look, _ surface: FakeSurface) -> WindowBorderController {
        WindowBorderController(surface: surface, look: look, screens: { [CGRect(x: 0, y: 0, width: 1920, height: 1080)] }, primaryHeight: { 1080 })
    }

    @Test("On with width 2 by default; both settings are saved and read back")
    func settings() {
        let defaults = LookTests.defaults()
        let look = Self.look(defaults: defaults)
        #expect(look.windowBorder == true)
        #expect(look.windowBorderWidth == 2)
        look.windowBorder = false
        look.windowBorderWidth = 12
        #expect(look.windowBorderWidth == 8)
        let again = Self.look(defaults: defaults)
        #expect(again.windowBorder == false)
        #expect(again.windowBorderWidth == 8)
    }

    @Test("The border's colour is the theme's accent until a colour is picked; the pick is saved, read back and drawn (Sven, 2026-10-10)")
    func colour() {
        let defaults = LookTests.defaults()
        let look = Self.look(defaults: defaults)
        #expect(look.windowBorderColour == .theme)
        let surface = FakeSurface()
        let c = controller(look, surface)
        c.update(Self.window)
        #expect(surface.shown?.color == look.theme.accent)
        look.windowBorderColour = .custom(0xC62828)
        c.refresh()
        #expect(surface.shown?.color == 0xC62828)
        #expect(Self.look(defaults: defaults).windowBorderColour == .custom(0xC62828))
    }

    @Test("Shows the computed frame in the theme's accent, hides on focus loss and in fullscreen")
    func follows() {
        let look = Self.look()
        let surface = FakeSurface()
        let c = controller(look, surface)
        c.update(Self.window)
        #expect(surface.shown?.frame == CGRect(x: 98, y: 428, width: 804, height: 604))
        #expect(surface.shown?.color == look.theme.accent)
        #expect(surface.shown?.width == 2)
        c.update(nil)
        #expect(surface.shown == nil)
        c.update(WindowBorder.Window(frame: Self.window.frame, subrole: "AXStandardWindow", fullScreen: true, minimised: false))
        #expect(surface.shown == nil)
    }

    @Test("Minimising the focused window hides the border at once, then it moves to the next window (card agent-bo-95422995)")
    func minimise() {
        let look = Self.look()
        let surface = FakeSurface()
        let c = controller(look, surface)
        c.update(Self.window)
        var minimised = Self.window
        minimised.minimised = true
        c.update(minimised)
        #expect(surface.shown == nil)
        c.update(WindowBorder.Window(frame: CGRect(x: 960, y: 50, width: 900, height: 600), subrole: "AXStandardWindow", fullScreen: false, minimised: false))
        #expect(surface.shown?.frame == CGRect(x: 958, y: 428, width: 904, height: 604))
    }

    @Test("The focused window is re-read on minimise, un-minimise, hide, unhide, quit and Pilot's own window closing (card agent-bo-95422995)")
    func triggers() {
        let ax = EngineObservers.axNotifications
        for n in [kAXFocusedWindowChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification,
                  kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            #expect(ax.contains(n), "\(n)")
        }
        let workspace = EngineObservers.workspaceRefreshNotifications
        for n in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            #expect(workspace.contains(n), "\(n.rawValue)")
        }
        let own = EngineObservers.ownWindowRefreshNotifications
        for n in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            #expect(own.contains(n), "\(n.rawValue)")
        }
    }

    @Test("A tiler reflow moves the border: the focused window is re-read when the tiler lands it, not other windows (Sven's test 2026-10-09)")
    func followsTilerWrites() {
        let surface = FakeSurface()
        let c = controller(Self.look(), surface)
        let observers = EngineObservers()
        observers.seed(focusedApp: .current)
        observers.onFocusedWindow = { c.update($0) }
        // Zen in the top quarter, then grown to the whole screen once the app below it closed
        var zen: WindowBorder.Window? = WindowBorder.Window(frame: CGRect(x: 0, y: 30, width: 1920, height: 262), subrole: "AXStandardWindow",
                                                            fullScreen: false, minimised: false, windowID: 7)
        var reads = 0
        observers.readFocusedWindow = { _ in reads += 1; return zen.map { ("Zen", $0, nil) } }
        observers.refreshFocusedWindow()
        #expect(surface.shown?.frame == CGRect(x: -2, y: 786, width: 1924, height: 266))
        zen?.frame = CGRect(x: 0, y: 30, width: 1920, height: 1049)
        observers.tilerLanded([8]) // another window's write
        #expect(reads == 1 && surface.shown?.frame == CGRect(x: -2, y: 786, width: 1924, height: 266))
        observers.tilerLanded([7, 8])
        #expect(surface.shown?.frame == CGRect(x: -2, y: -1, width: 1924, height: 1053))
        zen = nil // the focused window went away
        observers.tilerLanded([7])
        #expect(surface.shown == nil)
    }

    /// Tester bug 9 (Sven on build 2778, 2026-11-19): the border sat at Pilot's settings window's opening frame, centred,
    /// after the tiler had moved the window to its tile. The window server takes a moved window's new frame only when
    /// AppKit commits it, a run loop turn later; the read the move sets off ran first, and the server's old frame won
    /// over AppKit's own. A real, near see-through panel (alpha 0 would read as not drawn), never key, moved and resized
    /// and read at once as the move's notification does: Pilot's own read of it (as of its key window), through the
    /// focused-window read the border takes. Shows a window: `PILOT_FOCUS=1 swift test --filter WindowBorderControllerTests`.
    @Test("Live: Pilot's own window moved or resized: the read right after it is the window's new frame", .pilotFocus)
    func ownWindowReadsItsNewFrame() {
        testApp()
        let panel = NSPanel(contentRect: NSRect(x: 40, y: 40, width: 160, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.alphaValue = 0.05
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        defer { panel.orderOut(nil) }
        panel.orderFrontRegardless()
        PanelTestSupport.pump()
        let observers = EngineObservers()
        observers.seed(focusedApp: .current)
        observers.readFocusedWindow = { pid in EngineObservers.drawnFocusedWindow(pid) { _ in EngineObservers.ownWindow(panel, marked: false) } }
        for i in 1...3 {
            let target = NSRect(x: 40 + 30 * i, y: 40 + 10 * i, width: 160 + 40 * i, height: 120 + 20 * i)
            panel.setFrame(target, display: true)
            observers.refreshFocusedWindow()
            #expect(observers.focusedWindowFrame == WindowGeometry.flip(target, primaryHeight: Screens.primaryHeight), "move \(i)")
            PanelTestSupport.pump(0.05)
        }
        // A window just ordered front, read at once as another app's (pid 1, past the own-window rule): not drawn yet,
        // so no border; drawn a moment later, when the settle reads ring it
        let fresh = NSPanel(contentRect: NSRect(x: 300, y: 40, width: 160, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        fresh.alphaValue = 0.05
        fresh.ignoresMouseEvents = true
        defer { fresh.orderOut(nil) }
        fresh.orderFrontRegardless()
        let opened = EngineObservers.drawnFocusedWindow(1) { _ in EngineObservers.ownWindow(fresh, marked: false) }
        #expect(opened?.window.drawn == false)
        PanelTestSupport.pump(0.2)
        #expect(DragFollower.drawnBounds(of: CGWindowID(fresh.windowNumber)) != nil, "drawn by the first settle read's time")
    }

    @Test("Once started it redraws by itself when Look's width, switch or theme changes")
    func followsLook() async {
        let look = Self.look()
        let surface = FakeSurface()
        let c = controller(look, surface)
        c.start()
        c.update(Self.window)
        look.windowBorderWidth = 6
        #expect(await Self.settles { surface.shown?.width == 6 })
        #expect(surface.shown?.frame == CGRect(x: 94, y: 424, width: 812, height: 612))
        look.pick("folio")
        #expect(await Self.settles { surface.shown?.color == look.theme.accent })
        look.windowBorder = false
        #expect(await Self.settles { surface.shown == nil })
        look.windowBorder = true
        #expect(await Self.settles { surface.shown != nil })
    }

    /// The controller redraws on a main-actor task after the change: give it a few turns.
    static func settles(_ done: () -> Bool) async -> Bool {
        for _ in 0..<200 where !done() { await Task.yield() }
        return done()
    }

    @Test("The panel lets clicks through, has no shadow, joins every Space, stays out of the window cycle, and is not shown")
    func panel() {
        testApp()
        let p = WindowBorderPanel()
        #expect(p.window.ignoresMouseEvents)
        #expect(!p.window.hasShadow)
        #expect(!p.window.isOpaque)
        #expect(p.window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(p.window.collectionBehavior.contains(.ignoresCycle))
        #expect(!p.window.hidesOnDeactivate)
        #expect(!p.window.isVisible)
    }
}
