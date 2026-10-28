import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The top bar's own modules (card agent-bo-95422852). Every case runs on fakes or a timer on its own defaults: nothing
/// changes the real volume, keyboard layout or output, and no window shows.
@MainActor
@Suite("Top bar readings")
struct BarReadingsTests {
    final class Sources: InputSourceSystem {
        var current = "british"
        var selected: [String] = []
        func all() -> [InputSource] {
            [("abc", "ABC"), ("british", "British – PC"), ("spanish", "Spanish – ISO")].map {
                InputSource(id: $0.0, name: $0.1, isKeyboard: true, isEnabled: true, isSelectable: true, isCurrent: $0.0 == current)
            }
        }
        func select(_ id: String) throws { selected.append(id); current = id }
    }

    /// Card agent-bo-95423038: the bar's CPU tooltip read "CPU 88%" alone, since a tick that only the CPU item watches
    /// read no load. getloadavg is a read of this Mac, nothing changed.
    @Test("The CPU item's own reading carries the load its tooltip shows")
    func cpuLoad() async throws {
        var i = BarInputs()
        i.latest = await SystemReader.read(try #require(BarKind.cpu.stat).parts)
        #expect(BarTooltip.text(.cpu, i).contains(" · load "))
    }

    /// Sven, 2026-10-09: at Stats' 1 s the menu bar's redraws were nearly all of Pilot's idle CPU.
    @Test("The bars' readings refresh every 5 s")
    func statsPace() {
        #expect(BarReadings.statsInterval == .seconds(5))
    }

    @Test("A click on the keyboard layout selects the next enabled one, wrapping round")
    func nextLayout() {
        let sources = Sources()
        let look = Look(inputSources: sources)
        look.followLayouts()
        look.pickNextLayout()
        look.pickNextLayout()
        #expect(sources.selected == ["spanish", "abc"])
        #expect(look.currentLayout?.id == "abc")
    }

    @Test("A click on the volume mutes the output, a second unmutes it")
    func mute() {
        let audio = SetupSoundTests.FakeAudio()
        let sound = SetupSound(audio: audio)
        sound.start()
        defer { sound.stop() }
        sound.toggleMute(.output)
        sound.toggleMute(.output)
        #expect(audio.setMutedCalls.map(\.0) == [true, false])
        #expect(audio.setMutedCalls.allSatisfy { $0.1 == 10 && $0.2 == .output })
    }

    @Test("A reader runs while a module holds it: sound follows from the first volume to the last, a Mac with no battery is read once")
    func holds() {
        let audio = SetupSoundTests.FakeAudio()
        var batteryReads = 0
        let readings = BarReadings(sound: SetupSound(audio: audio), look: Look(inputSources: Sources()), readBattery: { batteryReads += 1; return nil },
                                   readWatts: { nil })
        readings.hold(.workspaces)
        #expect(audio.watched.isEmpty)
        readings.hold(.volume)
        readings.hold(.volume)
        #expect(audio.watched == [10, 20])
        readings.release(.volume)
        #expect(audio.watched == [10, 20])
        readings.release(.volume)
        #expect(audio.watched.isEmpty)
        readings.hold(.battery)
        #expect(readings.battery == nil && batteryReads == 1)
        readings.release(.battery)
        readings.release(.battery)
    }

    @Test("A Mac with no battery shows the watts it draws, whole, and redraws only when they move")
    func watts() {
        var draw: Double? = 36.78
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: Sources()),
                                   readBattery: { nil }, readWatts: { draw })
        readings.hold(.battery)
        defer { readings.release(.battery) }
        #expect(readings.battery == nil && readings.watts == 37)
        #expect(readings.liveTimers == 1, "asked again every 5 s")
        draw = .nan
        readings.release(.battery)
        readings.hold(.battery)
        #expect(readings.watts == nil && readings.liveTimers == 0, "no reading: nothing shows and nothing is asked")
    }

    @Test("A battery is read when its module shows")
    func battery() {
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: Sources()),
                                      readBattery: { SystemStats.Battery(percent: 82, charging: false, minutesLeft: nil) })
        readings.hold(.battery)
        defer { readings.release(.battery) }
        #expect(readings.battery?.percent == 82)
    }

    @Test("Capture follows the recorder while it is held: its phase as it changes and, while it records, its time each second; paused, the time stands and nothing ticks; released, it stops following",
          .timeLimit(.minutes(1)))
    func recording() async {
        let recorder = Recorder()
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: Sources()), recorder: recorder)
        readings.hold(.capture)
        #expect(readings.recording == nil && readings.liveTimers == 0)
        recorder.pose(.recording, elapsed: 5.5)
        // Whole seconds, from 5; the next ticks in on its own. A busy main thread (the full suite) may stall for seconds, so
        // each is a lower bound.
        let seconds = { () -> Double? in if case .recording(let s) = readings.recording { s } else { nil } }
        await AIChatAgentTests.until { readings.recording != nil }
        let first = seconds() ?? 0
        #expect(first >= 5 && first == first.rounded(.down) && readings.liveTimers == 1)
        await AIChatAgentTests.until { (seconds() ?? 0) > first }
        recorder.pose(.paused, elapsed: 9)
        await AIChatAgentTests.until { readings.recording == .paused(9) }
        #expect(readings.liveTimers == 0)
        readings.release(.capture)
        recorder.pose(.recording, elapsed: 1)
        await Task.yield()
        #expect(readings.recording == .paused(9) && readings.liveTimers == 0)
    }
}

/// The stat modules' sampler watch (card agent-bo-95422854), on a fake watch: the real sampler never reads.
@MainActor
@Suite("Top bar stats readings")
struct TopBarStatsReadingsTests {
    final class Watches {
        var made: [(stats: Set<MenuBarStats.Stat>, task: Task<Void, Never>)] = []
        var live: [Set<MenuBarStats.Stat>] { made.filter { !$0.task.isCancelled }.map(\.stats) }
        func watch(_ stats: Set<MenuBarStats.Stat>) -> Task<Void, Never> {
            let task = Task<Void, Never> { while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) } }
            made.append((stats, task))
            return task
        }
    }

    @Test("Stat modules on the bar share one sampler watch over what they show; none once the last goes")
    func oneWatch() {
        let watches = Watches()
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: BarReadingsTests.Sources()),
                                      watchStats: { watches.watch($0) })
        readings.hold(.clock)
        #expect(watches.made.isEmpty)
        readings.hold(.cpu)
        #expect(watches.live == [[.cpu]])
        readings.hold(.cpu)
        readings.hold(.heat)
        #expect(watches.live == [[.cpu, .sensors]])
        readings.release(.cpu)
        #expect(watches.live == [[.cpu, .sensors]])
        readings.release(.cpu)
        #expect(watches.live == [[.sensors]])
        readings.release(.heat)
        #expect(watches.live.isEmpty)
        // The battery is the bar's own once-a-minute reading, never a sampler watch.
        readings.hold(.battery)
        #expect(watches.live.isEmpty)
        readings.release(.battery)
    }
}
