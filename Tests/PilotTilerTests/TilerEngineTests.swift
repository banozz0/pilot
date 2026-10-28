import Foundation
import PilotCore
@testable import PilotTiler
import Testing

// Nested in TilerTreeTests: it reads isTilerEnabled, which the enable test flips.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct TilerEngineTests {
        /// The engine never started, so the seam takes no call and the session never runs.
        @Test func theSeamRefusesWhileTheEngineIsOff() async {
            var ran = false
            let tiler = InProcessTiler { _, _ in ran = true; return "" }
            #expect(!tiler.isRunning)
            await #expect(throws: TilerNotRunning.self) { try await tiler.run(.workspace("2")) }
            #expect(!ran)
        }

        /// Card agent-bo-95422999, AC1: two tilers would fight over every window, so the engine refuses to start while
        /// the old tiler runs, and the tiling switch cannot turn on an engine that never started.
        @Test func theEngineRefusesToStartWhileTheOtherTilerRuns() async {
            isTilerEnabled = false
            tilerStarted = false
            var ran = false
            let tiler = InProcessTiler(session: { _, _ in ran = true; return "" }, otherTilerRunning: { true })
            await #expect(throws: OtherTilerRunning.self) { try await tiler.start() }
            #expect(!tiler.isRunning && !tilerStarted)
            await #expect(throws: TilerNotRunning.self) { try await tiler.run(.enable(true)) }
            #expect(!ran && !isTilerEnabled)
        }

        /// Card agent-bo-95422999: the stream starts with the current state (the port's subscriptions.swift, sendInitial),
        /// so Pilot's top bar, Workspaces page and Home know the focused workspace before anything changes. Stopped, it
        /// says nothing.
        @Test func theStreamStartsWithTheCurrentStateWhileRunning() async throws {
            #expect(Workspace.get(byName: "3").focusWorkspace())
            let tiler = InProcessTiler(session: { _, body in try await body() }, otherTilerRunning: { false })
            let stopped = tiler.events()
            isTilerEnabled = true
            let running = tiler.events()
            broadcastEvent(.workspaceChanged(workspace: "4", prevWorkspace: "3"))
            let fromRunning = await first(4, of: running), fromStopped = await first(1, of: stopped)
            #expect(fromRunning == [.focusedWorkspaceChanged(workspace: "3", previous: "3"), .focusedMonitorChanged(monitorId: 1, workspace: "3"),
                                    .focusChanged(workspace: "3"), .focusedWorkspaceChanged(workspace: "4", previous: "3")])
            #expect(fromStopped == [.focusedWorkspaceChanged(workspace: "4", previous: "3")])
        }

        /// Up to `count` events, or what came within a second: a stream that never starts fails the test, not hangs it.
        func first(_ count: Int, of stream: AsyncStream<AeroEvent>) async -> [AeroEvent] {
            let reading = Task {
                var events: [AeroEvent] = []
                for await event in stream { events.append(event); if events.count == count { break } }
                return events
            }
            let timeout = Task { try? await Task.sleep(for: .seconds(1)); reading.cancel() }
            defer { timeout.cancel() }
            return await reading.value
        }
    }
}
