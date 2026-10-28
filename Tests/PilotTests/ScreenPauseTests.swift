import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Nothing is read while the screen is locked or the display sleeps (card agent-bo-95422839): lane 1 measured Pilot near
/// 1 % with the screen locked, the Stats app at 0. Fake notification centers stand in for macOS's.
@MainActor
@Suite("Screen pause")
struct ScreenPauseTests {
    @Test("A paused sampler reads nothing; resumed, it reads again from a fresh start, with no rate across the pause")
    func pauseAndResume() async throws {
        let counter = SystemSamplerTests.Counter()
        let sampler = SystemSamplerTests.sampler(counter)
        let watch = Task { await sampler.watch(every: .seconds(2), needs: .rows) }
        // An hourly watch beside it outlasts it, so the resumed loop's next tick is an hour off.
        let hourly = Task { await sampler.watch(every: SystemSamplerTests.hour, needs: .rows) }
        #expect(try await SystemSamplerTests.wait { sampler.latestValues?.cpu != nil && !sampler.history.isEmpty })
        sampler.pause()
        try await Task.sleep(for: .milliseconds(2300))   // the pause holds from the next pass, within one 2 s tick
        let paused = counter.reads
        try await Task.sleep(for: .milliseconds(500))
        #expect(counter.reads == paused)
        watch.cancel()
        await watch.value
        sampler.resume()
        // At once, not after the paused loop's day-long wait, and from a fresh start: no CPU rate yet and the graphs begin
        // again. With only the hourly watch left, that reading stays until the test has looked.
        #expect(try await SystemSamplerTests.wait { counter.reads > paused && sampler.latestValues?.cpu == nil && sampler.history.isEmpty })
        hourly.cancel()
        await hourly.value
    }

    @Test("After a pause the process list is read again at once, not kept from before the lock")
    func listsFreshAfterPause() async throws {
        let counter = SystemSamplerTests.Counter()
        let sampler = SystemSampler(processInterval: SystemSamplerTests.hour, relistAfter: SystemSamplerTests.hour, read: { parts in
            let processes = parts.contains(.processes)
            return SystemSamplerTests.raw(Double(counter.bump(slow: false, processes: processes)), slow: false, processes: processes)
        }, fetchPublicIP: { nil }, netTop: { nil })
        let home = Task { await sampler.watch(every: .milliseconds(10), needs: [.rows, .processes]) }
        #expect(try await SystemSamplerTests.wait { counter.processReads == 1 })
        sampler.pause()
        try await Task.sleep(for: .milliseconds(100))
        sampler.resume()
        #expect(try await SystemSamplerTests.wait { counter.processReads == 2 })
        home.cancel()
        await home.value
    }

    @Test("Lock and display sleep pause, unlock and wake resume; locked at start means paused from the start")
    func events() {
        let distributed = NotificationCenter(), workspace = NotificationCenter()
        var states: [Bool] = []
        let screen = ScreenEvents(distributed: distributed, workspace: workspace, lockedNow: { true })
        screen.start { states.append($0) }
        #expect(states == [false])
        distributed.post(name: ScreenEvents.unlocked, object: nil)
        #expect(states.last == true)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(states.last == false)
        distributed.post(name: ScreenEvents.locked, object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(states.last == false)            // awake but still locked
        distributed.post(name: ScreenEvents.unlocked, object: nil)
        #expect(states.last == true)
        #expect(states == [false, true, false, true])   // only changes are told
    }
}
