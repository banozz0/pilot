import Testing
@testable import PilotCore

@Suite("Tiled window keys")
struct TiledKeyTests {
    static func window(_ layout: String) -> AeroWindow {
        AeroWindow(id: 7, appName: "Finder", bundleId: "com.apple.finder", pid: 1, workspace: "3", monitorId: 1,
                   layout: layout, title: "a")
    }

    @Test("A tiled window's keys go to the tiler, aimed at that window or its workspace")
    func tiled() {
        let w = Self.window("h_tiles")
        #expect(TiledKey.focus(.left).route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.focus(.left)))
        #expect(TiledKey.swap(.up).route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.swap(id: 7, .up)))
        #expect(TiledKey.resize(.height, by: -60).route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.resize(id: 7, .height, by: -60)))
        #expect(TiledKey.flipSplit.route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.flipSplit(id: 7)))
        #expect(TiledKey.toggleScrolling.route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.toggleScrolling(workspace: "3")))
        #expect(TiledKey.focusMonitor(.right).route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.focusMonitor(.right)))
        #expect(TiledKey.sendToMonitor(.left).route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.moveToMonitor(id: 7, .left)))
    }

    @Test("A floating window swaps and resizes through Pilot's own code; it has no split to flip")
    func floating() {
        let w = Self.window("floating")
        #expect(TiledKey.swap(.up).route(running: true, window: w, tiler: "Pilot's tiler") == .pilot)
        #expect(TiledKey.resize(.width, by: 60).route(running: true, window: w, tiler: "Pilot's tiler") == .pilot)
        #expect(TiledKey.flipSplit.route(running: true, window: w, tiler: "Pilot's tiler") == .unavailable("A floating window has no split"))
        #expect(TiledKey.focus(.left).route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.focus(.left)))
        #expect(TiledKey.toggleScrolling.route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.toggleScrolling(workspace: "3")))
        #expect(TiledKey.sendToMonitor(.right).route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.moveToMonitor(id: 7, .right)))
    }

    @Test("With the tiler off, Pilot's own code is the fallback; split, layout and column keys have none")
    func tilerOff() {
        for key in [TiledKey.focus(.down), .swap(.left), .resize(.width, by: 60), .focusMonitor(.left), .sendToMonitor(.right)] {
            #expect(key.route(running: false, window: nil, tiler: "Pilot's tiler") == .pilot)
        }
        #expect(TiledKey.flipSplit.route(running: false, window: nil, tiler: "Pilot's tiler") == .unavailable("Pilot's tiler is not running"))
        // Pilot's own tiler on (card agent-bo-95423025): the tip names it.
        #expect(TiledKey.flipSplit.route(running: false, window: nil, tiler: "Pilot's tiler") == .unavailable("Pilot's tiler is not running"))
        #expect(TiledKey.toggleScrolling.route(running: false, window: nil, tiler: "Pilot's tiler") == .unavailable("Pilot's tiler is not running"))
    }

    /// Check 6's keys (spec scrolling-layout): Hyper+R, Hyper+Shift+R and Hyper+Alt+C go to the tiler aimed at the window
    /// in front, which refuses them outside a strip; a floating window has no column, and only the tiler has columns.
    @Test("The scrolling layout's column keys: next and previous width and centre, aimed at the window in front")
    func columnKeys() {
        let w = Self.window("h_scrolling")
        #expect(TiledKey.cycleColumnWidth(forward: true).route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.cycleColumnWidth(id: 7, forward: true)))
        #expect(TiledKey.cycleColumnWidth(forward: false).route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.cycleColumnWidth(id: 7, forward: false)))
        #expect(TiledKey.centreColumn.route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.centreColumn(id: 7)))
        #expect(TiledKey.maximiseColumn.route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.maximiseColumn(id: 7)))
        #expect(TiledKey.leaveStack.route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.leaveStack(id: 7)))
        // Hyper+→ on a strip is the plain focus key: the tiler scrolls the strip (check 3).
        #expect(TiledKey.focus(.right).route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.focus(.right)))
        for key in [TiledKey.cycleColumnWidth(forward: true), .cycleColumnWidth(forward: false), .centreColumn, .maximiseColumn, .leaveStack] {
            #expect(key.route(running: true, window: Self.window("floating"), tiler: "Pilot's tiler") == .unavailable("A floating window has no column"))
            #expect(key.route(running: false, window: nil, tiler: "Pilot's tiler") == .unavailable("Pilot's tiler is not running"))
        }
    }

    @Test("With the tiler up but no focused window (an empty workspace), focus still moves; window keys say why not")
    func noFocusedWindow() {
        #expect(TiledKey.focus(.left).route(running: true, window: nil, tiler: "Pilot's tiler") == .tiler(.focus(.left)))
        #expect(TiledKey.focusMonitor(.right).route(running: true, window: nil, tiler: "Pilot's tiler") == .tiler(.focusMonitor(.right)))
        for key in [TiledKey.swap(.left), .resize(.width, by: 60), .flipSplit, .toggleScrolling, .cycleColumnWidth(forward: true), .centreColumn, .sendToMonitor(.left)] {
            #expect(key.route(running: true, window: nil, tiler: "Pilot's tiler") == .unavailable("No window to act on"))
        }
    }

    @Test("The window ring (Omarchy's Alt+Tab) walks every window on the workspace through the tiler, wrapping around")
    func focusRing() {
        #expect(AeroCommand.focusRing(next: true).arguments == ["focus", "dfs-next", "--boundaries-action", "wrap-around-the-workspace"])
        #expect(AeroCommand.focusRing(next: false).arguments == ["focus", "dfs-prev", "--boundaries-action", "wrap-around-the-workspace"])
        #expect(TiledKey.focusRing(next: true).route(running: true, window: nil, tiler: "Pilot's tiler") == .tiler(.focusRing(next: true)))
        #expect(TiledKey.focusRing(next: true).route(running: false, window: nil, tiler: "Pilot's tiler") == .unavailable("Pilot's tiler is not running"))
    }

    @Test("The old tiler's service-mode commands as plain actions (Sven, 2026-10-05): join, equal sizes, reset layout, close others")
    func serviceCommands() {
        let w = Self.window("h_tiles")
        #expect(AeroCommand.joinWith(id: 7, .left).arguments == ["join-with", "--window-id", "7", "left"])
        #expect(AeroCommand.balanceSizes(workspace: "3").arguments == ["balance-sizes", "--workspace", "3"])
        #expect(AeroCommand.closeAllButCurrent.arguments == ["close-all-windows-but-current"])
        #expect(TiledKey.join(.down).route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.joinWith(id: 7, .down)))
        #expect(TiledKey.balance.route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.balanceSizes(workspace: "3")))
        #expect(TiledKey.resetLayout.route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.flatten(workspace: "3")))
        #expect(TiledKey.closeOthers.route(running: true, window: w, tiler: "Pilot's tiler") == .tiler(.closeAllButCurrent))
        #expect(TiledKey.join(.up).route(running: true, window: Self.window("floating"), tiler: "Pilot's tiler") == .unavailable("A floating window joins no group"))
        #expect(TiledKey.balance.route(running: false, window: nil, tiler: "Pilot's tiler") == .unavailable("Pilot's tiler is not running"))
    }
}
