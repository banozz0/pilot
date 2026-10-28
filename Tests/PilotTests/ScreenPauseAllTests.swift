import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Everything that reads on a timer pauses with the screen (card agent-bo-95422839, round 10): the sampler alone left
/// the bars' clock, Wi-Fi, battery and other apps' items, and the secure-input poll, ticking while locked. Fake lock and
/// sleep notices drive a real ScreenEvents; every reader runs on fakes.
@MainActor
@Suite("Screen pause, every reader")
struct ScreenPauseAllTests {
    final class Counts {
        var clock = 0, wifi = 0, battery = 0, secureInput = 0
    }

    final class CountingExtras: MenuExtrasReading, @unchecked Sendable {
        private let lock = NSLock()
        private var listed = 0
        var lists: Int { lock.withLock { listed } }
        func running() -> [MenuExtrasApp] { lock.withLock { listed += 1 }; return [] }
        func items(of pid: pid_t) throws -> [MenuExtrasRaw]? { nil }
        func press(_ handle: MenuItemHandle) -> Bool { false }
    }

    @Test("Locked, nothing reads, timers stopped; unlocked, every reader reads again at once")
    func everyReaderPauses() async throws {
        let counts = Counts(), extras = CountingExtras()
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: BarReadingsTests.Sources()),
                                   menuApps: MenuApps(reader: extras, ownPid: 13),
                                   readBattery: { counts.battery += 1; return SystemStats.Battery(percent: 82, charging: false, minutesLeft: nil) },
                                   readWiFi: { counts.wifi += 1; return nil },
                                   clock: { counts.clock += 1; return Date() },
                                   watchStats: { _ in Task {} })
        readings.clockSeconds = true
        for kind: BarKind in [.clock, .wifi, .battery, .otherApps] { readings.hold(kind) }
        let secure = SecureInputMonitor(isEnabled: { counts.secureInput += 1; return false })
        secure.start()
        let counter = SystemSamplerTests.Counter()
        let sampler = SystemSamplerTests.sampler(counter)
        let watch = Task { await sampler.watch(every: .milliseconds(200), needs: .rows) }
        defer {
            watch.cancel()
            secure.pause()   // its only stop
            for kind: BarKind in [.clock, .wifi, .battery, .otherApps] { readings.release(kind) }
        }
        #expect(try await SystemSamplerTests.wait { counter.reads > 0 })

        let distributed = NotificationCenter(), workspace = NotificationCenter()
        // Kept to the end: its observers hold it weakly.
        let screen = ScreenEvents(distributed: distributed, workspace: workspace, lockedNow: { false })
        screen.start(pausing: [sampler, readings, secure])
        let atLock = counter.reads
        distributed.post(name: ScreenEvents.locked, object: nil)
        #expect(readings.liveTimers == 0)
        // Other apps' items: the refresh and the launch observer are off (a scan already under way may still land).
        #expect(!readings.menuApps.isFollowing)
        let before = (counts.clock, counts.secureInput)
        try await Task.sleep(for: .milliseconds(2300))   // two of the clock's and secure input's 1 s ticks, ten sampler ticks
        #expect(counts.clock == before.0)
        #expect(counts.secureInput == before.1)
        #expect(counter.reads <= atLock + 1)   // only the sampler's pass already under way may land, however late

        let read = (counts.clock, counts.wifi, counts.battery, counts.secureInput, extras.lists)
        distributed.post(name: ScreenEvents.unlocked, object: nil)
        // At once, not at the next 30 s or 60 s tick: the bars show the time, Wi-Fi, battery and other apps of now.
        #expect(counts.clock > read.0 && counts.wifi > read.1 && counts.battery > read.2 && counts.secureInput > read.3)
        #expect(readings.liveTimers == 3)
        #expect(readings.menuApps.isFollowing)
        #expect(try await SystemSamplerTests.wait { extras.lists > read.4 })

        // Display sleep pauses the same way; an item placed meanwhile waits for the wake to read.
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        readings.release(.wifi)
        readings.hold(.wifi)
        #expect(readings.liveTimers == 0)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(readings.liveTimers == 3)
        withExtendedLifetime(screen) {}
    }

    @Test("An item released while paused stays stopped after the resume")
    func releasedWhilePaused() {
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: BarReadingsTests.Sources()),
                                   readBattery: { SystemStats.Battery(percent: 82, charging: false, minutesLeft: nil) },
                                   readWiFi: { nil }, watchStats: { _ in Task {} })
        readings.hold(.battery)
        readings.hold(.wifi)
        readings.pause()
        readings.release(.battery)
        readings.resume()
        #expect(readings.liveTimers == 1)
        readings.release(.wifi)
        #expect(readings.liveTimers == 0)
    }
}
