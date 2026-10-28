import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The top bar's switch in the app (card agent-bo-95422850). Every case runs on fakes: no window is shown, the real
/// menu bar's autohide and the tiler's settings are never touched.
@MainActor
@Suite("Top bar controller")
struct TopBarControllerTests {
    final class FakeAutohide: MenuBarAutohide, @unchecked Sendable {
        var hidden = false
        func isHidden() async throws -> Bool { hidden }
        func setHidden(_ hidden: Bool) async throws { self.hidden = hidden }
    }

    final class FakePanels: TopBarPanels {
        var shown: [String] = []
        var level = TopBarWindows.aboveMenuBar
        func show(on screens: [TopBarGeometry.Screen]) { shown = screens.map(\.name) }
        func hideAll() { shown = [] }
    }

    final class Bars: @unchecked Sendable {
        var written: [[PilotBlock.BarInset]] = []
    }

    static let screens = [TopBarGeometry.Screen(name: "CU34G4Z", strip: 30), .init(name: "24G1WG4", strip: 30)]

    static func make(_ defaults: UserDefaults, autohide: FakeAutohide = FakeAutohide(), bars: Bars = Bars(),
                     panels: FakePanels = FakePanels()) -> TopBarController {
        TopBarController(defaults: defaults, autohide: autohide, writeBars: { bars.written.append($0) },
                         screens: { screens }, panels: panels)
    }

    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: testSuite())!
    }

    /// Lets the switch's task finish.
    static func settle(_ controller: TopBarController) async {
        while controller.busy { await Task.yield() }
    }

    @Test("Off by default: a fresh Pilot shows no bar and touches nothing")
    func offByDefault() {
        let panels = FakePanels(), bars = Bars(), autohide = FakeAutohide()
        let controller = Self.make(Self.defaults(), autohide: autohide, bars: bars, panels: panels)
        controller.start()
        #expect(!controller.isOn)
        #expect(panels.shown.isEmpty)
        #expect(bars.written.isEmpty)
        #expect(!autohide.hidden)
    }

    @Test("On shows a bar per screen and makes their room; off hides them and puts the menu bar back")
    func onOff() async {
        let panels = FakePanels(), bars = Bars(), autohide = FakeAutohide()
        let controller = Self.make(Self.defaults(), autohide: autohide, bars: bars, panels: panels)
        controller.set(true)
        await Self.settle(controller)
        #expect(controller.isOn)
        #expect(autohide.hidden)
        #expect(panels.shown == ["CU34G4Z", "24G1WG4"])
        #expect(bars.written == [[.init(monitor: "CU34G4Z", height: 30), .init(monitor: "24G1WG4", height: 30)]])
        controller.set(false)
        await Self.settle(controller)
        #expect(!controller.isOn)
        #expect(!autohide.hidden)
        #expect(panels.shown.isEmpty)
        #expect(bars.written.last == [])
    }

    @Test("The Menu bar page shows Top bar once the top bar is switched on and Menu bar once off; a pick by hand stays until the next switch (Sven, 2026-10-11)")
    func pagePlacementFollowsTheSwitch() async throws {
        let store = BarItemsStore(defaults: try MenuBarStatusItemsTests.defaults()) { [:] }
        let autohide = FakeAutohide()
        let controller = Self.make(Self.defaults(), autohide: autohide)
        controller.switched = store.topBarSwitched
        controller.set(true)
        await Self.settle(controller)
        #expect(store.pagePlacement == .topBar)
        // Picked by hand while on, then switched off and on again: each switch moves it.
        store.pagePlacement = .both
        controller.set(false)
        await Self.settle(controller)
        #expect(store.pagePlacement == .menuBar)
        controller.set(true)
        await Self.settle(controller)
        #expect(store.pagePlacement == .topBar)
    }

    @Test("A screen left out loses its bar and its room at once, and stays out after a relaunch")
    func leaveOut() async {
        let defaults = Self.defaults(), panels = FakePanels(), bars = Bars(), autohide = FakeAutohide()
        let controller = Self.make(defaults, autohide: autohide, bars: bars, panels: panels)
        controller.set(true)
        await Self.settle(controller)
        controller.leftOut.insert("24G1WG4")
        for _ in 0..<1000 where bars.written.count < 2 { await Task.yield() }
        #expect(panels.shown == ["CU34G4Z"])
        #expect(bars.written.last == [.init(monitor: "CU34G4Z", height: 30)])
        // Relaunch: the switch and the screen choice come back, the bar shows without switching again.
        let relaunched = FakePanels()
        let again = Self.make(defaults, autohide: autohide, panels: relaunched)
        again.start()
        #expect(again.isOn)
        #expect(again.state.savedAutohide == false)
        #expect(relaunched.shown == ["CU34G4Z"])
    }

    @Test("A screen left out while switching on loses its room once the switch is on")
    func leaveOutWhileSwitching() async {
        let panels = FakePanels(), bars = Bars()
        let controller = Self.make(Self.defaults(), bars: bars, panels: panels)
        controller.set(true)
        controller.leftOut.insert("24G1WG4")
        await Self.settle(controller)
        for _ in 0..<1000 where bars.written.count < 2 { await Task.yield() }
        #expect(bars.written.last == [.init(monitor: "CU34G4Z", height: 30)])
        #expect(panels.shown == ["CU34G4Z"])
    }

    /// Card agent-bo-95423038: a bar moved by anyone (the tiler's unpark, AppKit) stayed moved until Pilot restarted. A
    /// panel never shown posts no move of its own, so the test posts what AppKit posts after a move.
    @Test("A bar moved or resized by anyone goes back to its frame, and AppKit's constraint leaves it in the menu bar strip",
          arguments: [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification])
    func barSnapsBack(_ moved: Notification.Name) {
        let panel = TopBarWindows.panel(NSView(), level: TopBarWindows.aboveMenuBar)
        let bar = NSRect(x: -1080, y: 1890, width: 1080, height: 30)
        panel.pin(bar)
        #expect(panel.frame == bar)
        panel.setFrame(NSRect(x: 0, y: 465, width: 1080, height: 30), display: false)
        NotificationCenter.default.post(name: moved, object: panel)
        #expect(panel.frame == bar)

        let above = NSRect(x: 0, y: 5000, width: 3440, height: 30)
        #expect(panel.constrainFrameRect(above, to: NSScreen.screens.first) == above)
    }

    @Test("The bars sit above the menu bar, so an autohidden menu bar revealing on hover slides out under them (card agent-bo-95423007)")
    func aboveMenuBar() {
        #expect(TopBarWindows.aboveMenuBar > .mainMenu)
    }

    @Test("The strip is solid, every pixel opaque, so nothing of the menu bar revealing under them shows through (card agent-bo-95423007)")
    func solidStrip() async throws {
        let strip = TopBarStrip(sides: [:]) { _ in EmptyView() }.frame(width: 400, height: 30)
        let rep = try #require(try await snapshot(rendering: strip))
        // RGBA bytes, alpha last.
        let bytes = try #require(rep.bitmapData)
        let seeThrough = (0..<rep.pixelsHigh).reduce(0) { n, y in n + (0..<rep.pixelsWide).count { bytes[y * rep.bytesPerRow + $0 * 4 + 3] < 255 } }
        #expect(seeThrough == 0, "\(seeThrough) of \(rep.pixelsWide * rep.pixelsHigh) pixels see-through")
    }
}
