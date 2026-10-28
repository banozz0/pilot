import AppKit
@testable import PilotTiler
import Testing

/// Card agent-bo-95422999, live bug "nothing tiles" (route 2): the engine manages Pilot's own windows through AppKit, never
/// AX to its own process. A fake stands in for Pilot's NSWindow; the other app's window is the tree's TestWindow.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct OwnWindowTests {
        /// Pilot's own process as a running app (`myPid`; -1 in the test runner, which is no app bundle).
        private final class TestProcess: NSRunningApplication, @unchecked Sendable {
            override var isTerminated: Bool { false }
            override var processIdentifier: pid_t { myPid }
        }

        private final class FakeOwnWindow: OwnWindow {
            let windowNumber: Int
            var frame: NSRect
            var engineWindowType: AxUiElementWindowType = .window
            let title = "Pilot"
            var isVisible = true
            var isMiniaturized = false
            var isKeyWindow = false
            init(_ windowNumber: Int, frame: NSRect) {
                self.windowNumber = windowNumber
                self.frame = frame
            }
            func setFrame(_ frame: NSRect, display: Bool) { self.frame = frame }
            func makeKeyAndOrderFront(_ sender: Any?) { isKeyWindow = true }
            func performClose(_ sender: Any?) { isVisible = false }
            var isFullScreen = false
            func miniaturize(_ sender: Any?) { isMiniaturized = true }
            func deminiaturize(_ sender: Any?) { isMiniaturized = false }
            func toggleFullScreen(_ sender: Any?) { isFullScreen.toggle() }
        }

        /// Registers this process as Pilot's own app over `windows`; the body runs with it, and everything is undone after.
        private func withOwnApp(_ windows: [FakeOwnWindow], _ body: (MacApp) async throws -> Void) async throws {
            let previous = OwnApp.windows
            OwnApp.windows = { windows }
            defer {
                OwnApp.windows = previous
                for window in windows { MacWindow.allWindowsMap[UInt32(window.windowNumber)] = nil }
                MacApp.allAppsMap[myPid] = nil
            }
            let app = try #require(try await MacApp.getOrRegister(TestProcess()), "Pilot's own app is registered")
            try await body(app)
        }

        private func numbers(_ rect: Rect) -> [CGFloat] { [rect.topLeftX, rect.topLeftY, rect.width, rect.height] }

        @Test func theEngineLaysOutAPilotWindowBesideAnotherAppsWindow() async throws {
            let workspace = focus.workspace
            let other = try TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
            let pilot = FakeOwnWindow(9_001, frame: NSRect(x: 300, y: 200, width: 800, height: 600))
            try await withOwnApp([pilot]) { app in
                #expect(try await app.refreshAndGetAliveWindowIds(frontmostAppBundleId: nil) == [9_001])
                let window = try await MacWindow.getOrRegister(windowId: 9_001, macApp: app)
                #expect(try window.parent === workspace.rootTilingContainer, "Pilot's window tiles")
                try await workspace.layoutWorkspace()

                // Test monitor 1920 x 1080, no gaps, layout height 1079: the other app left, Pilot right.
                #expect(try await other.getAxRect(.nonCancellable).map(numbers) == [0, 0, 960, 1079])
                #expect(try await window.getAxRect(.nonCancellable).map(numbers) == [960, 0, 960, 1079])
                #expect(pilot.frame == NSRect(x: 960, y: 1, width: 960, height: 1079), "set through AppKit, bottom-left origin")
            }
        }

        /// Live bug (overlap after a drag): the engine heard no release of Pilot's own window, so it stayed a drag, layout
        /// skipped it and it sat over its neighbour. This covers what the release does to Pilot's window; that the release
        /// arrives (GlobalObserver's session tap) has no unit seam, since tests never post real events: lane 1 drags it live.
        @Test func aReleasedDragOfAPilotWindowSwapsAndLaysItOut() async throws {
            let workspace = focus.workspace
            let other = try TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
            let pilot = FakeOwnWindow(9_005, frame: NSRect(x: 300, y: 200, width: 800, height: 600))
            try await withOwnApp([pilot]) { app in
                let window = try await MacWindow.getOrRegister(windowId: 9_005, macApp: app)
                try await workspace.layoutWorkspace()
                startDrag(window)
                #expect(currentlyManipulatedWithMouseWindowId == 9_005)

                unitTestScreen.withLock { $0.mouse = CGPoint(x: 100, y: 500) } // over the other app's window, left
                try await resetManipulatedWithMouseIfPossible()
                try dropDraggedWindow(at: mouseLocation)
                try await workspace.layoutWorkspace()

                #expect(draggedWindowId == nil && currentlyManipulatedWithMouseWindowId == nil)
                #expect(try workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(9_005), .window(1)]))
                #expect(pilot.frame == NSRect(x: 0, y: 1, width: 960, height: 1079), "laid out in the left tile, not left where dropped")
                #expect(try await other.getAxRect(.nonCancellable).map(numbers) == [960, 0, 960, 1079])
            }
        }

        @Test func stoppingTheEngineUnparksPilotsWindowWithoutAx() async throws {
            let pilot = FakeOwnWindow(9_002, frame: NSRect(x: 1919, y: -500, width: 800, height: 600))
            try await withOwnApp([pilot]) { app in
                let window = try await MacWindow.getOrRegister(windowId: 9_002, macApp: app)
                window.lastFloatingSize = CGSize(width: 800, height: 600)
                unparkAllWindows()
                #expect(pilot.frame == NSRect(x: 560, y: 240, width: 800, height: 600), "centred on the visible screen")
            }
        }

        /// Card agent-bo-95423038: a fault's unpark moved Pilot's top bars mid-screen (lane 1: a tiler AxTimeout fault 4 s
        /// after Switch on, then the bars at x 0, y half the visible height). The engine never laid them out, so it never
        /// moves them.
        @Test func unparkingLeavesPilotsPanelsWhereTheyAre() async throws {
            let bar = NSRect(x: 0, y: 1050, width: 1920, height: 30)
            let panel = FakeOwnWindow(9_006, frame: bar)
            panel.engineWindowType = .popup
            try await withOwnApp([panel]) { app in
                _ = try await MacWindow.getOrRegister(windowId: 9_006, macApp: app)
                unparkAllWindows()
                #expect(panel.frame == bar)
            }
        }

        /// A window parked on the second monitor is centred on that monitor, not at the same offset from the main one's corner.
        @Test func unparkCentresAWindowOnItsOwnMonitor() async throws {
            let second = MonitorInfoImpl(monitorAppKitNsScreenScreensId: 2, name: "Second Monitor",
                                         rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
                                         visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
            unitTestScreen.withLock { $0.monitors.append(second) }
            defer { unitTestScreen.withLock { $0.monitors.removeAll { $0.name == second.name } } }
            let pilot = FakeOwnWindow(9_007, frame: NSRect(x: 3839, y: -500, width: 800, height: 600))
            try await withOwnApp([pilot]) { app in
                let window = try await MacWindow.getOrRegister(windowId: 9_007, macApp: app)
                window.lastFloatingSize = CGSize(width: 800, height: 600)
                unparkAllWindows()
                #expect(pilot.frame == NSRect(x: 2480, y: 240, width: 800, height: 600), "centred on the second monitor")
            }
        }

        @Test func minimiseAndFullscreenGoThroughAppKit() async throws {
            let pilot = FakeOwnWindow(9_004, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            try await withOwnApp([pilot]) { app in
                let window = try await MacWindow.getOrRegister(windowId: 9_004, macApp: app)
                window.setNativeMinimized(true)
                #expect(try await window.isMacosMinimized(.nonCancellable))
                window.setNativeMinimized(false)
                window.setNativeFullscreen(true)
                #expect(try await window.isMacosFullscreen(.nonCancellable))
            }
        }

        @Test func pilotsPanelsAreNotTiled() async throws {
            let panel = FakeOwnWindow(9_003, frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            panel.engineWindowType = .popup
            try await withOwnApp([panel]) { app in
                let window = try await MacWindow.getOrRegister(windowId: 9_003, macApp: app)
                #expect(try window.parent === macosPopupWindowsContainer)
            }
        }

        /// Live bug (Sven 2026-10-10, Look › Wallpaper › Next clicked again within a tip's 3 s): the click's refresh listed
        /// the old tip, the new tip released it before it was typed, and a window that was gone counted as a tiled window,
        /// so Pilot's window shrank to half its tile beside nothing until the next refresh.
        @Test func aPilotWindowGoneBeforeItIsTypedIsNotTiled() async throws {
            let workspace = focus.workspace
            let pilot = FakeOwnWindow(9_008, frame: NSRect(x: 300, y: 200, width: 800, height: 600))
            let tip = FakeOwnWindow(9_009, frame: NSRect(x: 900, y: 500, width: 250, height: 44))
            tip.engineWindowType = .popup
            var open = [pilot, tip]
            let previous = OwnApp.windows
            defer { OwnApp.windows = previous }
            try await withOwnApp([]) { app in
                OwnApp.windows = { open }
                _ = try await MacWindow.getOrRegister(windowId: 9_008, macApp: app)
                #expect(try await app.refreshAndGetAliveWindowIds(frontmostAppBundleId: nil) == [9_008, 9_009])
                open = [pilot] // the next tip replaces it before it is registered
                let gone = try await MacWindow.getOrRegister(windowId: 9_009, macApp: app)
                MacWindow.allWindowsMap[9_009] = nil
                #expect(try !(gone.parent is TilingContainer), "a window that is gone takes no tile")
                try await workspace.layoutWorkspace()
                #expect(try workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(9_008)]))
                #expect(pilot.frame == NSRect(x: 0, y: 1, width: 1920, height: 1079), "Pilot's window keeps the whole tile")
            }
        }

        @Test func windowKinds() {
            let styled: (NSWindow.StyleMask) -> NSWindow = {
                NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: $0, backing: .buffered, defer: true)
            }
            #expect(styled([.titled, .resizable]).engineWindowType == .window)
            #expect(styled([.titled]).engineWindowType == .dialog)
            #expect(styled([.borderless]).engineWindowType == .popup)
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            #expect(panel.engineWindowType == .popup)
        }
    }
}
