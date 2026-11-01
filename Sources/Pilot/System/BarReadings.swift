import AppKit
import Observation
import PilotCore

/// What the bar items read, for the macOS menu bar and the top bar alike (cards agent-bo-95422852 and 911): the keyboard
/// layout (Look's, as Settings › Look switches it), the output's volume and mute (Setup's sound model), the battery,
/// Wi-Fi's state and signal, the clock's minute, and the sampler watch over the readings shown. A reader runs only
/// while an item on a shown bar holds it, so items not shown read nothing. Injected, so tests never touch the real
/// volume, layout, output or Wi-Fi.
@Observable @MainActor
final class BarReadings: ScreenPausing {
    let sound: SetupSound
    let look: Look
    let menuApps: MenuApps
    /// The time's popover's events, read on its first open (card agent-bo-95423011).
    let calendar: ClockCalendar
    let appMenus: AppMenus
    /// The Status lights item's sources, watched only while it is held (StatusLights).
    let statusLights: StatusLights
    private(set) var battery: SystemStats.Battery?
    /// The whole Mac's draw in whole watts (the SMC's PSTR) on a Mac with no battery, every 5 s while the battery item
    /// shows (Sven, 2026-10-16: his Mac mini has none).
    private(set) var watts: Int?
    /// Wi-Fi's power and signal (CoreWLAN, no prompt; the network's name is never read for the bars).
    private(set) var wifi: WiFiStatus?
    /// The clock's time, moved on each minute, or each second while `clockSeconds`, only while a clock or Keep awake's
    /// time shows.
    private(set) var now: Date
    /// The clock's pattern shows seconds.
    var clockSeconds = false
    /// The recorder as Capture draws it: its phase as it changes, and while it records its time each second (paused, the
    /// time stands), only while Capture is held.
    private(set) var recording: BarRecording?
    @ObservationIgnored private let recorder: Recorder
    @ObservationIgnored private var recordingTimer: Timer?
    /// Which watch over the recorder is current: a release moves it on, and a change seen by an old one is dropped.
    @ObservationIgnored private var recorderWatch = 0
    @ObservationIgnored private let readBattery: () -> SystemStats.Battery?
    @ObservationIgnored private let readWatts: () -> Double?
    @ObservationIgnored private let readWiFi: () -> WiFiStatus?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var wifiTimer: Timer?
    @ObservationIgnored private var clockTimer: Timer?
    @ObservationIgnored private var holds: [BarKind: Int] = [:]
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var batteryTimer: Timer?
    /// Starts a sampler watch over these stats until its task is cancelled; a fake in tests.
    /// The extensions' bar items, asked only while held and the screen is in use (story 161).
    @ObservationIgnored private let extensionBar: ExtensionBar
    @ObservationIgnored private let watchStats: @MainActor (Set<MenuBarStats.Stat>) -> Task<Void, Never>
    /// The one sampler watch the stat modules share, over every stat a shown bar holds.
    @ObservationIgnored private var statWatch: (task: Task<Void, Never>, stats: Set<MenuBarStats.Stat>)?

    init(sound: SetupSound, look: Look = .shared, menuApps: MenuApps = MenuApps(), appMenus: AppMenus = AppMenus(),
         readBattery: @escaping () -> SystemStats.Battery? = SystemReader.battery, readWatts: @escaping () -> Double? = { SMC.shared.power() },
         readWiFi: @escaping () -> WiFiStatus? = { BarReadings.coreWLAN.status() }, clock: @escaping () -> Date = Date.init,
         watchStats: @escaping @MainActor (Set<MenuBarStats.Stat>) -> Task<Void, Never> = BarReadings.sampleStats,
         calendar: ClockCalendar = ClockCalendar(), extensionBar: ExtensionBar = .shared, statusLights: StatusLights = .shared,
         recorder: Recorder = .shared) {
        self.sound = sound
        self.recorder = recorder
        self.statusLights = statusLights
        self.extensionBar = extensionBar
        self.calendar = calendar
        self.look = look
        self.menuApps = menuApps
        self.appMenus = appMenus
        self.readBattery = readBattery
        self.readWatts = readWatts
        self.readWiFi = readWiFi
        self.clock = clock
        self.watchStats = watchStats
        now = clock()
    }

    static let coreWLAN = CoreWLANSystem()

    /// The bars' own pace: every 5 s, not Stats' 1 s (Sven, 2026-10-09). Each change redraws the item once per menu
    /// bar, and at 1 s those redraws were nearly all of Pilot's idle CPU. Home, Stats and a popover keep their own.
    static let statsInterval: Duration = .seconds(5)

    /// The bars' watch at `statsInterval`, reading only these stats' parts (MenuBarStatusItems).
    static func sampleStats(_ stats: Set<MenuBarStats.Stat>) -> Task<Void, Never> {
        Task { await SystemSampler.shared.watch(every: statsInterval, needs: [], stats: stats) }
    }

    /// The sampler watch follows the held readings: replaced when what they show changes, ended with the last. The
    /// battery is the bar's own reading, once a minute.
    private func followStats() {
        let stats = Set(held.filter { $0 != .battery }.compactMap(\.stat))
        guard stats != statWatch?.stats ?? [] else { return }
        statWatch?.task.cancel()
        statWatch = stats.isEmpty ? nil : (watchStats(stats), stats)
    }

    /// An item showing on a bar: the first hold starts its reader.
    func hold(_ kind: BarKind) {
        holds[kind, default: 0] += 1
        guard holds[kind] == 1 else { return }
        followStats()
        switch kind {
        case .volume: sound.start()
        case .keyboardLayout: look.followLayouts()
        // Once per hold, not per resume: a watch cannot be taken back, only left to lapse at the next change.
        case .capture:
            followRecorder()
            startTimed(kind)
        default: startTimed(kind)
        }
    }

    /// The item left its bar: the last release stops its reader. Look keeps following layouts for its own page.
    func release(_ kind: BarKind) {
        guard let count = holds[kind], count > 0 else { return }
        holds[kind] = count - 1
        guard count == 1 else { return }
        followStats()
        switch kind {
        case .volume: sound.stop()
        case .capture:
            recorderWatch += 1
            stopTimed(kind)
        case .clock, .keepAwake:
            guard (holds[.clock] ?? 0) + (holds[.keepAwake] ?? 0) == 0 else { break }
            stopTimed(kind)
        default: stopTimed(kind)
        }
    }

    /// The screen locked or its displays slept (card agent-bo-95422839): the timed readers stop and the items keep their
    /// last picture. The stat modules' watch pauses with the sampler, sound and layouts only follow changes.
    func pause() {
        guard !paused else { return }
        paused = true
        held.forEach(stopTimed)
    }

    /// The screen is in use again: each held timed reader reads now, then on its own pace.
    func resume() {
        guard paused else { return }
        paused = false
        held.forEach(startTimed)
    }

    /// The kinds an item on a shown bar holds.
    private var held: [BarKind] { holds.filter { $0.value > 0 }.map(\.key) }

    /// The timers running, for the tests.
    var liveTimers: Int { [wifiTimer, clockTimer, batteryTimer, recordingTimer].count { $0 != nil } }

    /// A reader on a timer reads now and then on its pace; while paused it waits for `resume`.
    private func startTimed(_ kind: BarKind) {
        guard !paused else { return }
        switch kind {
        case .otherApps: menuApps.start()
        case .appMenus: appMenus.start()
        case .extensions: extensionBar.start()
        case .modes: statusLights.start()
        case .capture:
            readRecording()
            if recorder.phase == .recording { tickRecording() }
        case .wifi:
            wifi = readWiFi()
            wifiTimer = repeating(30) { $0.wifi = $0.readWiFi() }
        case .clock, .keepAwake:
            guard clockTimer == nil else { break }
            now = clock()
            tickClock()
        case .battery:
            battery = readBattery()
            // Once a minute is enough for a percentage. A Mac with no battery shows its draw, which moves by the second,
            // at the bars' 5 s; one with neither is asked again only after a pause.
            if battery != nil {
                batteryTimer = repeating(60) { $0.battery = $0.readBattery() }
            } else {
                readPower()
                if watts != nil { batteryTimer = repeating(5) { $0.readPower() } }
            }
        default: break
        }
    }

    /// Reads the draw, in whole watts, set only when it moved, so a steady draw redraws nothing.
    private func readPower() {
        let now = readWatts().flatMap { $0.isFinite && $0 > 0 && $0 < 2_000 ? Int($0.rounded()) : nil }
        if now != watts { watts = now }
    }

    private func stopTimed(_ kind: BarKind) {
        switch kind {
        case .otherApps: menuApps.stop()
        case .appMenus: appMenus.stop()
        case .extensions: extensionBar.stop()
        case .modes: statusLights.stop()
        case .capture:
            recordingTimer?.invalidate()
            recordingTimer = nil
        case .wifi:
            wifiTimer?.invalidate()
            wifiTimer = nil
        case .clock, .keepAwake:
            clockTimer?.invalidate()
            clockTimer = nil
        case .battery:
            batteryTimer?.invalidate()
            batteryTimer = nil
        default: break
        }
    }

    /// Wakes once at the next minute, or the next second when the clock shows seconds, never in between.
    private func tickClock() {
        let unit: TimeInterval = clockSeconds ? 1 : 60, now = clock()
        let next = (now.timeIntervalSinceReferenceDate / unit).rounded(.down) * unit + unit
        let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: next), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.clockTimer != nil else { return }
                self.now = self.clock()
                self.tickClock()
            }
        }
        timer.tolerance = unit / 10
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    /// Watches the recorder's phase while Capture is held: each change reads it again, and starts or stops the tick.
    private func followRecorder() {
        recorderWatch += 1
        let watch = recorderWatch
        _ = withObservationTracking { recorder.phase } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.recorderWatch == watch else { return }
                self.followRecorder()
                self.stopTimed(.capture)
                self.startTimed(.capture)
            }
        }
    }

    private func readRecording() {
        let now = recorder.reading
        if now != recording { recording = now }
    }

    /// Wakes as the recording's time turns the next second, never in between.
    private func tickRecording() {
        let elapsed = recorder.clock.elapsed(at: Recorder.now())
        let timer = Timer(timeInterval: 1 - elapsed.truncatingRemainder(dividingBy: 1) + 0.01, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recordingTimer != nil else { return }
                self.readRecording()
                self.tickRecording()
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    /// Holds the readers `kinds` need and releases those of `held` it no longer has: one bar's whole set at a time.
    func hold(_ kinds: Set<BarKind>, replacing held: inout Set<BarKind>) {
        kinds.subtracting(held).forEach(hold)
        held.subtracting(kinds).forEach(release)
        held = kinds
    }

    /// A timer on the main run loop's common modes, so it keeps going while a menu is open.
    private func repeating(_ seconds: TimeInterval, _ tick: @escaping @MainActor (BarReadings) -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self.map(tick) } }
        // A tenth late at most, so macOS fires it with Pilot's other wake-ups rather than on its own.
        timer.tolerance = seconds / 10
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
