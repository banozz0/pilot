import AppKit
@testable import PilotTiler
import Synchronization
import Testing

/// Card agent-bo-95422997, AC6, at the session (Moody REJECT vojyLSPFmNQ): an app whose AX thread never answers in time
/// no longer holds a session. The app is real AX plumbing (MacApp) on its own AX thread, kept busy for 3 s, with one window the
/// engine already knows; the session's refresh of it gives up within the messaging timeout plus 0.5 s and keeps the window.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct HungAppSessionTests {
        /// This test process as a running app: the test runner reports itself terminated, which the refresh drops.
        private final class TestProcess: NSRunningApplication, @unchecked Sendable {
            override var isTerminated: Bool { false }
            override var processIdentifier: pid_t { getpid() }
        }

        /// Card agent-bo-95423310 (Moody REJECT rD_eQVitpGw): a registration still going at its deadline leaves the app out,
        /// later sessions skip it without waiting or starting another, and its late landing hands the skip to the app and
        /// refreshes once when the skip ends.
        @Test func aSlowRegistrationIsSkippedThenLandsWithARefresh() async throws {
            let pid: pid_t = 2_000_000_123
            var started: [AwaitableOneTimeBroadcastLatch] = []
            let t0 = ContinuousClock.now
            #expect(try await MacApp.registering(pid, "Hung", deadline: .milliseconds(200)) { started.append($0) } == nil)
            #expect(ContinuousClock.now - t0 < .milliseconds(200) + .milliseconds(300))
            #expect(started.count == 1 && MacApp.slowSince[pid] != nil)

            let t1 = ContinuousClock.now
            #expect(try await MacApp.registering(pid, "Hung", deadline: .milliseconds(200)) { started.append($0) } == nil)
            #expect(ContinuousClock.now - t1 < .milliseconds(50))
            #expect(started.count == 1)

            let app = await MacApp.unitTestApp(TestProcess(), hangingFor: 0)
            var refreshed = 0
            await MacApp.finishRegistration(pid, app, try #require(started.first)) { refreshed += 1 }
            #expect(MacApp.allAppsMap[pid] === app && MacApp.slowSince[pid] == nil && refreshed == 0)
            let end = ContinuousClock.now + axUnansweredPause + .seconds(2)
            while refreshed == 0, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(50)) }
            #expect(refreshed == 1, "the skip ended without the late refresh")
            MacApp.allAppsMap[pid] = nil
            await app.destroy()
        }

        /// OW P6: a registration that lands after its deadline while the app still does not answer keeps the skip, so the
        /// next bind gives up on it at once rather than waiting the deadline again; the late refresh comes when the skip ends.
        @Test func aLateRegistrationOfAStillHungAppStaysSkipped() async throws {
            let pid: pid_t = 2_000_000_124
            var started: [AwaitableOneTimeBroadcastLatch] = []
            #expect(try await MacApp.registering(pid, "Hung", deadline: .milliseconds(200)) { started.append($0) } == nil)
            let app = await MacApp.unitTestApp(TestProcess(), hangingFor: 3)
            var refreshed = 0
            await MacApp.finishRegistration(pid, app, try #require(started.first)) { refreshed += 1 }
            #expect(MacApp.allAppsMap[pid] === app && MacApp.slowSince[pid] == nil)
            #expect(refreshed == 0, "the refresh waits for the skip to end")
            let t = ContinuousClock.now
            await #expect(throws: AxTimeout.self) { _ = try await app.getFocusedWindow(.cancellable) }
            #expect(ContinuousClock.now - t < .milliseconds(100), "the stall carries over: no axWaitDeadline wait")
            MacApp.allAppsMap[pid] = nil
            await app.destroy()
        }

        @Test func aSessionWithAHungAppFinishesWithinTheTimeout() async throws {
            let app = await MacApp.unitTestApp(TestProcess(), hangingFor: 3)
            let window = try MacWindow.unitTestWindow(id: 4_001, app, parent: Workspace.get(byName: name).floatingWindowsContainer)
            defer {
                MacWindow.allWindowsMap[window.windowId] = nil
                Task { await app.destroy() }
            }
            let start = ContinuousClock.now
            let alive = try await runLightSession(.pilotCall("hung-app test"), .forceRun) {
                try await app.refreshAndGetAliveWindowIds(frontmostAppBundleId: nil)
            }
            #expect(ContinuousClock.now - start < axMessagingTimeout + .milliseconds(500))
            #expect(alive == [window.windowId], "a hung app keeps the windows the engine knows")
        }

        // Card agent-bo-95423039: Ghostex's AX stalls threw AxTimeout out of the refresh session every few minutes, where
        // the catch-all called it an illegal error and recovered from a fault: every window unparked, the tree dropped.

        @Test func aHungAppsWindowIsSkippedAndTheOthersAreNormalized() async throws {
            let app = await MacApp.unitTestApp(TestProcess(), hangingFor: 3)
            let workspace = try Workspace.get(byName: name)
            let hung = try MacWindow.unitTestWindow(id: 4_002, app, parent: workspace.rootTilingContainer)
            let fullscreen = try TestWindow.new(id: 4_003, parent: workspace.rootTilingContainer)
            fullscreen.isMacosFullscreenForTest = true
            defer {
                MacWindow.allWindowsMap[hung.windowId] = nil
                Task { await app.destroy() }
            }
            try await normalizeLayoutReason()
            #expect(fullscreen.parent === (try workspace.macOsNativeFullscreenWindowsContainer))
            #expect(hung.parent === (try workspace.rootTilingContainer), "the hung app's window waits for the next session")
        }

        @Test func aTimeoutAtTheSessionIsNoFault() async throws {
            let app = await MacApp.unitTestApp(TestProcess(), hangingFor: 0)
            let window = try MacWindow.unitTestWindow(id: 4_004, app, parent: Workspace.get(byName: name).rootTilingContainer)
            defer {
                MacWindow.allWindowsMap[window.windowId] = nil
                Task { await app.destroy() }
            }
            endRefreshSession(.failure(AxTimeout()), assumeCancellable: true) // a fault would be recorded by .tilerTree
            #expect(MacWindow.allWindowsMap[window.windowId] === window, "no fault recovery: the window map is kept")
        }

        @Test func aStallIsLoggedOncePerApp() async throws {
            let app = await MacApp.unitTestApp(TestProcess(), hangingFor: 3)
            let window = try MacWindow.unitTestWindow(id: 4_005, app, parent: Workspace.get(byName: name).floatingWindowsContainer)
            defer {
                MacWindow.allWindowsMap[window.windowId] = nil
                Task { await app.destroy() }
            }
            let logged = Mutex<[String]>([])
            let previous = axStallLog
            axStallLog = { line in logged.withLock { $0.append(line) } }
            defer { axStallLog = previous }
            for _ in 0..<3 { _ = try? await app.getAxRect(window.windowId, .cancellable) }
            #expect(logged.withLock { $0.count } == 1)
        }

        @Test func aHungAppsNewWindowsWaitAndRegistrationGoesOn() async throws {
            let app = await MacApp.unitTestApp(TestProcess(), hangingFor: 3)
            defer { Task { await app.destroy() } }
            try await registerWindows(of: app, [4_006])
            #expect(MacWindow.allWindowsMap[4_006] == nil, "registered by a later session")
        }

        @Test func aHungAppsWindowStaysOutOfTheCornerAndHidingGoesOn() async throws {
            let app = await MacApp.unitTestApp(TestProcess(), hangingFor: 3)
            let hidden = try Workspace.get(byName: "hidden")
            let window = try MacWindow.unitTestWindow(id: 4_007, app, parent: hidden.rootTilingContainer)
            defer {
                MacWindow.allWindowsMap[window.windowId] = nil
                Task { await app.destroy() }
            }
            try await hideInCorner(hidden, .bottomRightCorner)
            #expect(!window.isHiddenInCorner)
        }

        @Test func aWindowBackFromFullscreenWaitsForASlowApp() async throws {
            let app = await MacApp.unitTestApp(TestProcess(), hangingFor: 3)
            let workspace = try Workspace.get(byName: name)
            let window = try MacWindow.unitTestWindow(id: 4_008, app, parent: workspace.macOsNativeFullscreenWindowsContainer)
            window.layoutReason = .macos(prevParentKind: .macosPopupWindowsContainer)
            defer {
                MacWindow.allWindowsMap[window.windowId] = nil
                Task { await app.destroy() }
            }
            await #expect(throws: AxTimeout.self) {
                try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: .macosPopupWindowsContainer, workspace: workspace, .cancellable)
            }
            #expect(window.layoutReason == .macos(prevParentKind: .macosPopupWindowsContainer), "the next session brings it back")
            #expect(window.parent === (try workspace.macOsNativeFullscreenWindowsContainer))
        }
    }
}
