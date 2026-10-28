// Parity AC2 (card agent-bo-95422997): every AeroCommand Pilot sends runs through InProcessTiler, the tiler Pilot drives,
// and each test checks the tree it leaves and, for a listing, that PilotCore parses the answer.
import AppKit
import PilotCore
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct AeroCommandCallsTest {
        /// The engine on, each call as the harness's `run` (layout needs real AX, so no runLightSession here).
        private func tiler() -> InProcessTiler {
            isTilerEnabled = true
            tilerStarted = true
            return InProcessTiler { _, body in try await run(body) }
        }

        /// Windows 1 and 2 side by side on `name`, 1 focused.
        @discardableResult
        private func twoTiles() throws -> Workspace {
            try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                    try TestWindow.new(id: 2, parent: $0)
                }
            }
        }

        @Test func offRefusesEveryCall() async throws {
            try twoTiles()
            await #expect(throws: TilerNotRunning.self) { try await InProcessTiler().run(.focus(.right)) }
            #expect(focus.windowOrNil?.windowId == 1)
        }

        @Test func anUnknownWindowIsRefusedAsTheCLIExits1() async throws {
            try twoTiles()
            await #expect(throws: TilerCallRefused(command: ["swap", "--window-id", "9", "left"])) {
                try await tiler().run(.swap(id: 9, .left))
            }
        }

        @Test func listWindowsParsesAsAeroWindow() async throws {
            let workspace = try twoTiles()
            try TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
            let all = try await tiler().windows(.all)
            #expect(all.map(\.id) == [1, 2, 3])
            #expect(all.map(\.layout) == ["h_tiles", "h_tiles", "floating"])
            #expect(all.allSatisfy { $0.workspace == name && $0.monitorId == 1 })
            #expect(try await tiler().windows(.focused).map(\.id) == [1])
            #expect(try await tiler().windows(.workspace("other")).isEmpty)
        }

        @Test func workspaceQueriesParseAsAeroWorkspace() async throws {
            try twoTiles()
            let focused = try await tiler().focusedWorkspace()
            #expect(focused?.workspace == name)
            #expect(focused?.rootLayout == "h_tiles")
            #expect(try AeroWorkspace.parse(try await tiler().run(.mouseWorkspace)).map(\.workspace) == [name])
            let visible = try await tiler().visibleWorkspaces()
            #expect(visible.map(\.workspace) == [name])
            #expect(visible.map(\.monitorId) == [1])
        }

        @Test func workspaceSwitches() async throws {
            for n in ["1", "2", "3"] { try TestWindow.new(id: UInt32(n)!, parent: Workspace.get(byName: n).rootTilingContainer) }
            try await tiler().run(.workspace("1"))
            #expect(focus.workspace.name == "1")
            try await tiler().run(.workspaceNext)
            #expect(focus.workspace.name == "2")
            try await tiler().run(.workspacePrevious)
            #expect(focus.workspace.name == "1")
            try await tiler().run(.workspace("3"))
            try await tiler().run(.workspaceBackAndForth)
            #expect(focus.workspace.name == "1")
        }

        @Test func moveWindowToWorkspace() async throws {
            try twoTiles()
            try await tiler().run(.moveWindow(id: 2, toWorkspace: "2"))
            #expect(try Workspace.get(byName: "2").layoutDescription == .workspace([.h_tiles([.window(2)])]))
            #expect(try Workspace.get(byName: name).layoutDescription == .workspace([.h_tiles([.window(1)])]))
        }

        /// Hyper+Shift+N leaves you where you are; Hyper+Alt+N (workspaces.moveFollow) goes along and focuses the window.
        @Test func moveWindowStaysOrFollows() async throws {
            try twoTiles()
            try await tiler().run(.focusWindow(id: 1))
            try await tiler().run(.moveWindow(id: 2, toWorkspace: "2"))
            #expect(focus.workspace.name == name && focus.windowOrNil?.windowId == 1)
            try await tiler().run(.moveWindow(id: 1, toWorkspace: "3", follow: true))
            #expect(focus.workspace.name == "3" && focus.windowOrNil?.windowId == 1)
            #expect(try Workspace.get(byName: "3").layoutDescription == .workspace([.h_tiles([.window(1)])]))
        }

        @Test func focusDirectionWindowAndRing() async throws {
            try twoTiles()
            try await tiler().run(.focus(.right))
            #expect(focus.windowOrNil?.windowId == 2)
            try await tiler().run(.focusWindow(id: 1))
            #expect(focus.windowOrNil?.windowId == 1)
            try await tiler().run(.focusRing(next: false))
            #expect(focus.windowOrNil?.windowId == 2, "dfs-prev wraps around the workspace")
        }

        @Test func joinSwapAndFlip() async throws {
            let workspace = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    try TestWindow.new(id: 1, parent: $0)
                    try TestWindow.new(id: 2, parent: $0)
                    try TestWindow.new(id: 3, parent: $0)
                }
            }
            try await tiler().run(.swap(id: 1, .right))
            #expect(try workspace.layoutDescription == .workspace([.h_tiles([.window(2), .window(1), .window(3)])]))
            try await tiler().run(.joinWith(id: 3, .left))
            #expect(try workspace.layoutDescription == .workspace([.h_tiles([.window(2), .v_tiles([.window(1), .window(3)])])]))
            try await tiler().run(.flipSplit(id: 3))
            #expect(try workspace.layoutDescription == .workspace([.h_tiles([.window(2), .h_tiles([.window(1), .window(3)])])]))
        }

        @Test func moveStopsAtTheEdge() async throws {
            let workspace = try twoTiles()
            try await tiler().run(.move(id: 1, .right))
            #expect(try workspace.layoutDescription == .workspace([.h_tiles([.window(2), .window(1)])]))
            try await tiler().run(.move(id: 1, .right))
            #expect(try workspace.layoutDescription == .workspace([.h_tiles([.window(2), .window(1)])]))
        }

        @Test func resizeAndBalance() async throws {
            let workspace = try twoTiles()
            let one = try #require(Window.get(byId: 1))
            try await tiler().run(.resize(id: 1, .width, by: 50))
            #expect(try one.hWeight == 51)
            await #expect(throws: TilerCallRefused.self) { try await tiler().run(.resize(id: 1, .height, by: 50)) }
            try await tiler().run(.balanceSizes(workspace: name))
            #expect(try workspace.rootTilingContainer.children.map { try $0.hWeight } == [1, 1])
        }

        @Test func rootLayoutScrollingAndFlatten() async throws {
            let workspace = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    try TestWindow.new(id: 1, parent: $0)
                    try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with { try TestWindow.new(id: 2, parent: $0) }
                }
            }
            try await tiler().run(.toggleScrolling(workspace: name))
            #expect(try workspace.rootTilingContainer.layout == .scrolling)
            try await tiler().run(.toggleScrolling(workspace: name))
            #expect(try workspace.rootTilingContainer.layout == .tiles)
            try await tiler().run(.flatten(workspace: name))
            #expect(try workspace.layoutDescription == .workspace([.h_tiles([.window(1), .window(2)])]))
            try await tiler().run(.setRootLayout(workspace: name, "v_tiles"))
            #expect(try workspace.layoutDescription == .workspace([.v_tiles([.window(1), .window(2)])]))
            await #expect(throws: TilerCallRefused.self) { try await tiler().run(.setRootLayout(workspace: name, "spiral")) }
            try await tiler().run(.setRootLayout(workspace: name, "h_scrolling"))
            #expect(try workspace.rootTilingContainer.layout == .scrolling && workspace.rootTilingContainer.orientation == .h)
        }

        /// Checks 3 and 6 of the scrolling layout (spec scrolling-layout) through the calls Hyper+→ and Hyper+←, Hyper+R,
        /// Hyper+Shift+R, Hyper+Alt+C and Hyper+= send: focus scrolls the strip the least, landing a column whole one gap
        /// from the edge; widths step round both ways; centre puts the column in the middle; grow widens the column.
        @Test func columnKeysOnAStrip() async throws {
            config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10),
                               outer: .init(left: .constant(10), bottom: .constant(10), top: .constant(10), right: .constant(10)))
            let workspace = Workspace.get(byName: name)
            let windows = try (1...5).map { try TestWindow.new(id: UInt32($0), parent: workspace.rootTilingContainer) }
            #expect(workspace.focusWorkspace())
            try await tiler().run(.toggleScrolling(workspace: name))
            let usable = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps, half = (usable.width + 10) / 2 - 10
            func close(_ a: CGFloat?, _ b: CGFloat) -> Bool { a.map { abs($0 - b) < 0.5 } == true }
            func key(_ command: AeroCommand) async throws {
                try await tiler().run(command)
                try await workspace.layoutWorkspace()
            }

            // Check 3: columns 1 and 2 in view, half each (T8); Hyper+→ to 3 scrolls just enough, Hyper+← back to 1 mirrors it.
            #expect(try windows[1].focusWindow())
            try await workspace.layoutWorkspace()
            try await key(.focus(.right))
            #expect(focus.windowOrNil == windows[2])
            #expect(close(windows[2].axRect?.maxX, usable.maxX) && close(windows[2].axRect?.width, half), "whole, one gap from the edge")
            #expect(close(windows[1].axRect?.maxX, (windows[2].axRect?.minX ?? 0) - 10))
            try await key(.focus(.left))
            #expect(close(windows[1].axRect?.minX, usable.minX), "column 2 was in view: no scroll")
            try await key(.focus(.left))
            #expect(focus.windowOrNil == windows[0] && close(windows[0].axRect?.minX, usable.minX))

            // Check 6: Hyper+R steps 1/2 → 2/3 → full → 1/3 → 1/2, Hyper+Shift+R steps back.
            func cycle(forward: Bool) async throws -> [CGFloat?] {
                var widths: [CGFloat?] = []
                for _ in 1...4 { try await key(.cycleColumnWidth(id: 3, forward: forward)); widths.append(windows[2].columnWidth) }
                return widths
            }
            let forward: [CGFloat?] = [2.0 / 3, 1, 1.0 / 3, 1.0 / 2], back: [CGFloat?] = [1.0 / 3, 1, 2.0 / 3, 1.0 / 2]
            #expect(try await cycle(forward: true) == forward)
            #expect(try await cycle(forward: false) == back)
            // Hyper+Alt+C centres column 3, which lands at the right edge once focused.
            #expect(try windows[2].focusWindow())
            try await workspace.layoutWorkspace()
            #expect(!close(windows[2].axRect?.center.x, usable.center.x))
            try await key(.centreColumn(id: 3))
            #expect(close(windows[2].axRect?.center.x, usable.center.x))
            #expect(close(windows[2].axRect?.width, half))

            // Hyper+= and Hyper+−: a step of points on the column's share of the usable width plus a gap.
            try await key(.resize(id: 3, .width, by: 191))
            #expect(close(windows[2].axRect?.width, half + 191))
            try await key(.resize(id: 3, .width, by: -5000))
            #expect(windows[2].columnWidth == 0.1)
            await #expect(throws: TilerCallRefused.self) { try await tiler().run(.resize(id: 3, .width, by: -60)) }

            // Outside a strip the column keys do nothing, and the tiler says so.
            let tiled = try TestWindow.new(id: 9, parent: Workspace.get(byName: "tiles").rootTilingContainer)
            await #expect(throws: TilerCallRefused.self) { try await tiler().run(.cycleColumnWidth(id: Int(tiled.windowId), forward: true)) }
            await #expect(throws: TilerCallRefused.self) { try await tiler().run(.centreColumn(id: Int(tiled.windowId))) }
        }

        /// Spec scrolling-layout, T3: a snapshot's restore sets each column back to the points it was saved at, a width
        /// in the settings exactly when it was one.
        @Test func setColumnWidthTakesItsPoints() async throws {
            config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10),
                               outer: .init(left: .constant(10), bottom: .constant(10), top: .constant(10), right: .constant(10)))
            let workspace = Workspace.get(byName: name)
            let root = try workspace.rootTilingContainer
            root.layout = .scrolling
            let windows = try (1...2).map { try TestWindow.new(id: UInt32($0), parent: root) }
            let across = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps.width + 10
            try await tiler().run(.setColumnWidth(id: 1, points: Int((across / 2 - 10).rounded())))
            #expect(windows[0].columnWidth == 1.0 / 2, "half a strip, snapped to the setting")
            try await tiler().run(.setColumnWidth(id: 2, points: 900))
            #expect(windows[1].columnWidth.map { abs($0 - 910 / across) < 0.0001 } == true)
            let tiled = try TestWindow.new(id: 9, parent: Workspace.get(byName: "tiles").rootTilingContainer)
            await #expect(throws: TilerCallRefused.self) { try await tiler().run(.setColumnWidth(id: Int(tiled.windowId), points: 900)) }
        }

        /// Moody's REJECT of T3 v1: the saved root layout is usually the one the workspace still has, and that call alone
        /// is refused, so a restore runs each step as one eval, as Pilot's WorkspaceSnapshots does. A strip comes back in
        /// its saved order with each column at its saved width.
        @Test func restoringAStripOntoAStrip() async throws {
            config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10),
                               outer: .init(left: .constant(10), bottom: .constant(10), top: .constant(10), right: .constant(10)))
            let workspace = Workspace.get(byName: name)
            let root = try workspace.rootTilingContainer
            root.layout = .scrolling
            let windows = try (1...3).map { try TestWindow.new(id: UInt32($0), parent: root) }
            #expect(workspace.focusWorkspace())
            let listed = try await tiler().windows(.workspace(name))
            let across = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps.width + 10
            func column(_ fraction: CGFloat) -> CGRect { CGRect(x: 0, y: 0, width: fraction * across - 10, height: 900) }
            // Saved as 3, 1, 2 at a half, two thirds and a third.
            let strip = try #require(try await tiler().focusedWorkspace())
            #expect(strip.rootLayout == "h_scrolling")
            let snapshot = try #require(Snapshot.capture(strip, windows: [listed[2], listed[0], listed[1]],
                                                         frames: [3: column(1.0 / 2), 1: column(2.0 / 3), 2: column(1.0 / 3)], at: .now))
            await #expect(throws: TilerCallRefused.self) { try await tiler().run(.setRootLayout(workspace: name, "h_scrolling")) }
            let plan = SnapshotRestore(snapshot, current: listed)
            try await tiler().run(.eval(plan.placeCommands))
            try await tiler().run(.eval(plan.arrangeCommands(windows: try await tiler().windows(.workspace(name)), frames: [:])))
            #expect(try root.layoutDescription == .h_scrolling([.window(3), .window(1), .window(2)]))
            let saved: [CGFloat?] = [2.0 / 3, 1.0 / 3, 1.0 / 2]
            #expect(windows.map(\.columnWidth) == saved)
        }

        /// The same for tiles onto tiles: the order and each tile's share come back.
        @Test func restoringTilesOntoTiles() async throws {
            let workspace = Workspace.get(byName: name)
            let windows = try (1...3).map { try TestWindow.new(id: UInt32($0), parent: workspace.rootTilingContainer) }
            #expect(workspace.focusWorkspace())
            try await workspace.layoutWorkspace()
            let listed = try await tiler().windows(.workspace(name))
            let area = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
            func slot(_ from: CGFloat, _ share: CGFloat) -> CGRect { CGRect(x: area.minX + from * area.width, y: area.minY, width: share * area.width, height: area.height) }
            // Saved as 2, 3, 1 at 30 %, 50 % and 20 %.
            let tiles = try #require(try await tiler().focusedWorkspace())
            #expect(tiles.rootLayout == "h_tiles")
            let snapshot = try #require(Snapshot.capture(tiles, windows: listed,
                                                         frames: [2: slot(0, 0.3), 3: slot(0.3, 0.5), 1: slot(0.8, 0.2)], at: .now))
            let plan = SnapshotRestore(snapshot, current: listed)
            try await tiler().run(.eval(plan.placeCommands))
            try await workspace.layoutWorkspace()
            let frames = Dictionary(uniqueKeysWithValues: windows.map { (Int($0.windowId), $0.axRect?.cgRect ?? .zero) })
            try await tiler().run(.eval(plan.arrangeCommands(windows: try await tiler().windows(.workspace(name)), frames: frames)))
            try await workspace.layoutWorkspace()
            #expect(try workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(2), .window(3), .window(1)]))
            let widths: [CGFloat] = [windows[1], windows[2], windows[0]].map { ($0.axRect?.width ?? 0) / area.width }
            let near = zip(widths, [0.3, 0.5, 0.2] as [CGFloat]).allSatisfy { abs($0 - $1) < 0.01 }
            #expect(near, "\(widths)")
        }

        @Test func floatAndTile() async throws {
            let workspace = try twoTiles()
            try await tiler().run(.setFloating(id: 2, true))
            #expect(Window.get(byId: 2)?.parent is FloatingWindowsContainer)
            try await tiler().run(.setFloating(id: 2, false))
            #expect(try workspace.layoutDescription == .workspace([.h_tiles([.window(1), .window(2)]), .floatingWindowsContainer([])]))
        }

        @Test func closeAllButCurrent() async throws {
            let workspace = try twoTiles()
            try await tiler().run(.closeAllButCurrent)
            #expect(workspace.allLeafWindowsRecursive.map(\.windowId) == [1])
        }

        @Test func monitorFocusAndMove() async throws {
            try twoTiles()
            let second = MonitorInfoImpl(
                monitorAppKitNsScreenScreensId: 2, name: "Second Monitor",
                rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
                visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false,
            )
            unitTestScreen.withLock { $0.monitors.append(second) }
            gcMonitors()
            try await tiler().run(.moveToMonitor(id: 2, .right))
            #expect(Window.get(byId: 2)?.nodeWorkspace == second.activeWorkspace)
            #expect(focus.windowOrNil?.windowId == 2, "--focus-follows-window")
            try await tiler().run(.focusMonitor(.left))
            #expect(focus.workspace.name == name)
        }

        @Test func evalRunsEachInOneCall() async throws {
            let workspace = try twoTiles()
            try await tiler().run(.eval([.move(id: 1, .right), .swap(id: 9, .left), .setRootLayout(workspace: name, "v_tiles")]))
            #expect(try workspace.layoutDescription == .workspace([.v_tiles([.window(2), .window(1)])]), "a refused step does not stop the rest, as with `;`")
        }

        @Test func enableAndEvents() async throws {
            let tiler = tiler()
            #expect(AeroEvent(TilerEvent.workspaceChanged(workspace: "2", prevWorkspace: "1")) == .focusedWorkspaceChanged(workspace: "2", previous: "1"))
            #expect(AeroEvent(TilerEvent.windowDetected(windowId: 1, workspace: "2", appBundleId: nil, appName: nil)) == .windowDetected(workspace: "2"))
            #expect(AeroEvent(TilerEvent.focusChanged(windowId: 1, workspace: "3")) == .focusChanged(workspace: "3"))
            #expect(AeroEvent(TilerEvent.focusedMonitorChanged(workspace: "4", monitorId: 2)) == .focusedMonitorChanged(monitorId: 2, workspace: "4"))
            try await tiler.run(.enable(false))
            #expect(!tiler.isRunning)
            // Moody REJECT vojyLSPFmNQ: the tiling switch turns it back on; every other call still waits for that.
            await #expect(throws: TilerNotRunning.self) { try await tiler.run(.focus(.right)) }
            try await tiler.run(.enable(true))
            #expect(tiler.isRunning)
        }
    }
}
