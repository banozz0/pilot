import Foundation
import Observation
import OSLog
import PilotCore

/// This Mac's one sampler (cards agent-bo-95422788, agent-bo-95422830 and agent-bo-95422831): everything that shows a
/// reading (Home while on screen, later each menu-bar item) holds a `watch`, and the sampler reads only while one is
/// held, once a tick however many watch, at the shortest interval asked. When the last watch ends the loop stops; the
/// next run starts fresh, so its first tick reads the slow readings and shows no rates. A watch may also need the
/// process list (read only while one does) or the public IP (fetched only while one does, every 10 minutes: the one
/// reading that calls the internet). The reads run off the main thread.
@Observable @MainActor
final class SystemSampler: ScreenPausing {
    static let shared = SystemSampler(minutesFile: DayFile("stats-today"))

    /// What a watch shows (card agent-bo-95422836): This Mac's rows (Home, a popover), which read everything; the process
    /// list; the public IP. A menu-bar item shows none of these, only its own readings (its `stats`).
    struct Needs: OptionSet, Sendable {
        let rawValue: Int
        static let processes = Needs(rawValue: 1), publicIP = Needs(rawValue: 2), rows = Needs(rawValue: 4)
        /// Stats' minute history (card agent-bo-95422992): the readings its charts draw, kept a minute at a time.
        static let history = Needs(rawValue: 8)
        /// The busiest apps by CPU and by memory alone (the menu's stats cards, P42): the process list without nettop.
        static let apps = Needs(rawValue: 16)
        /// Low-battery alerts: the Bluetooth HID batteries with the slow readings, system_profiler only while shown.
        static let lowBattery = Needs(rawValue: 32)
    }
    /// What the minute history reads: every reading Stats charts over time.
    static let historyParts: SystemStats.Parts = [.cpu, .memory, .gpu, .network, .diskIO, .sensors]
    /// How often the history reads while nothing else is shown (card agent-bo-95422992: once a minute, all day).
    static let historyInterval: Duration = .seconds(60)
    static let publicIPInterval: Duration = .seconds(600)

    private(set) var rows: [SystemStats.Row] = []
    /// The five busiest processes by CPU and by memory, while a watch needs them; else empty.
    private(set) var busiestCPU: [SystemStats.Row] = []
    private(set) var busiestMemory: [SystemStats.Row] = []
    /// The five busiest by disk (each process's counters between reads) and by network (nettop snapshots), while a watch
    /// needs the process list (card agent-bo-95422834).
    private(set) var busiestDisk: [SystemStats.Row] = []
    private(set) var busiestNetwork: [SystemStats.Row] = []
    /// The four lists as live slots for Home, by the reading they rank by (CPU, RAM, disk, network): a refresh changes only
    /// the slots whose process or number changed (card agent-bo-95422838).
    private(set) var busiestSlots: [MenuBarStats.Stat: [LiveRow]] = [:]
    /// The busiest by CPU and by memory from the last process listing, grouped as Activity groups them (each app with what
    /// it started, then the background processes; Stats' Overview, 2026-10-12); empty while none is read.
    private(set) var appsByCPU: [Activity.Row] = []
    private(set) var appsByMemory: [Activity.Row] = []
    /// How many processes the last listing counted; nil while none is read.
    private(set) var processCount: Int?
    /// What is worth a look, worked out at each listing from the busiest apps and the Mac's readings.
    private(set) var findings: [StatsOverview.Finding] = []
    @ObservationIgnored private var lookout = StatsOverview.Watch()
    /// The last reading and its values, for the menu-bar items' text.
    private(set) var latest: SystemStats.Raw?
    private(set) var latestValues: SystemStats.Values?
    /// The newest values first to last, for mini graphs: at most `historyLength`, none older than `historyLength` ticks of
    /// 2 s, so the minute history's readings never stretch a 2-minute graph.
    private(set) var history: [SystemStats.Values] = []
    /// Each history value's reading time.
    @ObservationIgnored private var historyTimes: [TimeInterval] = []
    /// Today's readings a minute at a time, while a watch needs the history (Stats' 1 hour and Today).
    private(set) var minutes = StatsHistory()
    /// Where the minute history is saved, every 10 minutes and at quit; nil in the tests.
    @ObservationIgnored private let minutesFile: DayFile<StatsHistory>?
    @ObservationIgnored private var minutesSaved = Cadence(every: .seconds(600))
    /// How often the minute history reads its parts, whatever else ticks faster (a test reads it every tick).
    @ObservationIgnored private let historyEvery: Duration
    nonisolated private static let log = Logger(subsystem: "dev.banozz.pilot", category: "stats")
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let historyLength: Int
    /// How often the process list is read while one shows (card agent-bo-95422838): ps and each process's counters are
    /// most of a tick's cost, and the busiest lists barely change in 2 s.
    @ObservationIgnored private let processInterval: Duration
    /// How often This Mac's rows read the SMC (temperatures, fans, power), which move slowly and cost the most of a tick's
    /// readings; a Temperature item in the menu bar reads them every tick.
    @ObservationIgnored private let sensorInterval: Duration
    /// How often the slow readings (the disk's free space, Bluetooth, the slow details) are read while they show.
    @ObservationIgnored private let slowInterval: Duration
    /// Bluetooth's batteries, slower again: each read starts system_profiler, and earbud levels move by the hour.
    @ObservationIgnored private let bluetoothInterval: Duration
    /// The second process read comes this soon after the first, so the busiest by disk, a rate between two reads, shows
    /// quickly; then every processInterval.
    @ObservationIgnored private let relistAfter: Duration
    /// Set when the process list must be read again at once (Combined processes changed).
    @ObservationIgnored private var relist = false
    /// nettop's rest between its snapshots (each takes about 5 s itself), so the network list also refreshes about every
    /// 10 s, beside the others.
    @ObservationIgnored private let netTopPause: Duration
    @ObservationIgnored private let read: @Sendable (SystemStats.Parts) async -> SystemStats.Raw
    @ObservationIgnored private let fetchPublicIP: @Sendable () async -> String?
    @ObservationIgnored private let netTop: @Sendable () async -> String?
    /// The apps with a Dock icon, read on the main thread at each listing, for Activity's grouping.
    @ObservationIgnored private let runningApps: @MainActor () -> [Activity.App]
    /// nettop takes about five seconds a snapshot, so it runs in its own loop beside the ticks, only while needed.
    @ObservationIgnored private var netTopLoop: Task<Void, Never>?
    /// The last process list's names by pid, for nettop's shortened names.
    @ObservationIgnored private var processNames: [Int32: String] = [:]
    @ObservationIgnored private var watches: [UUID: (interval: Duration, needs: Needs, stats: Set<MenuBarStats.Stat>)] = [:]
    /// The reading loop is under way; false once its last pass has ended (tests wait on it rather than on the clock).
    @ObservationIgnored private(set) var running = false
    /// Stats' Combined processes for the busiest by RAM: an app's helpers under the app (MenuBarStatusItems sets it); a
    /// change shows at the next tick.
    @ObservationIgnored var combineProcesses = false {
        didSet { if combineProcesses != oldValue { relist = true } }
    }
    /// Handed each reading of the Bluetooth batteries (LowBatteryAlerts).
    @ObservationIgnored var onBluetooth: (@MainActor ([SystemStats.BluetoothDevice]) -> Void)?
    /// The loop's wait between ticks; a watch asking for a shorter interval cuts it short.
    @ObservationIgnored private var waiting: Task<Void, Never>?
    /// While the screen is locked or the display sleeps nothing is read (card agent-bo-95422839, ScreenEvents).
    @ObservationIgnored private(set) var paused = false
    /// Set by `resume`: the next pass starts afresh, however short the pause was.
    @ObservationIgnored private var restart = false
    /// The public IP while a watch wants it (Stats' Network block shows it); nil otherwise or before the fetch answers.
    private(set) var publicIP: String?
    @ObservationIgnored private var publicIPReadAt: ContinuousClock.Instant?

    #if DEBUG
    /// The renders' readings: shown as if read, nothing read from this Mac.
    func seed(history: [SystemStats.Values], latest: SystemStats.Raw?, rows: [SystemStats.Row],
              apps: (cpu: [Activity.Row], memory: [Activity.Row], processes: Int?) = ([], [], nil),
              findings: [StatsOverview.Finding] = [], busiest: [MenuBarStats.Stat: [LiveRow]]) {
        appsByCPU = apps.cpu
        appsByMemory = apps.memory
        processCount = apps.processes
        self.findings = findings
        self.history = history
        latestValues = history.last
        self.latest = latest
        self.rows = rows
        busiestSlots = busiest
    }
    #endif

    init(historyLength: Int = 60, processInterval: Duration = .seconds(10), netTopPause: Duration = .seconds(5),
         sensorInterval: Duration = .seconds(6), slowInterval: Duration = .seconds(SystemStats.diskInterval),
         bluetoothInterval: Duration = .seconds(300),
         relistAfter: Duration = .seconds(2),
         read: @escaping @Sendable (SystemStats.Parts) async -> SystemStats.Raw = { await SystemReader.read($0) },
         fetchPublicIP: @escaping @Sendable () async -> String? = { await SystemReader.publicIP() },
         netTop: @escaping @Sendable () async -> String? = { await SystemReader.netTop() },
         runningApps: @escaping @MainActor () -> [Activity.App] = { ActivityMonitor.runningApps() },
         minutesFile: DayFile<StatsHistory>? = nil, clock: @escaping @Sendable () -> Date = { Date() },
         historyEvery: Duration = SystemSampler.historyInterval) {
        self.minutesFile = minutesFile
        self.historyEvery = historyEvery
        self.clock = clock
        self.historyLength = historyLength
        self.processInterval = processInterval
        self.sensorInterval = sensorInterval
        self.slowInterval = slowInterval
        self.bluetoothInterval = bluetoothInterval
        self.relistAfter = relistAfter
        self.netTopPause = netTopPause
        self.read = read
        self.fetchPublicIP = fetchPublicIP
        self.netTop = netTop
        self.runningApps = runningApps
    }

    /// Keeps the sampler reading at least every `interval` what `needs` and `stats` show, until the calling task is
    /// cancelled.
    func watch(every interval: Duration = .seconds(SystemStats.interval), needs: Needs = [], stats: Set<MenuBarStats.Stat> = []) async {
        let id = UUID()
        let shorter = watches.values.allSatisfy { interval < $0.interval }
        // A watch that shows something no other watch does (Home opening beside the menu bar) gets its first reading now.
        let adds = !needs.isSubset(of: watches.values.reduce(Needs()) { $0.union($1.needs) })
            || !stats.isSubset(of: Set(watches.values.flatMap(\.stats)))
        watches[id] = (interval, needs, stats)
        if shorter || adds { waiting?.cancel() }
        if !running {
            running = true
            Task { await self.run() }
        }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        watches[id] = nil
    }

    /// Reads while any watch is held, from a fresh start; on the main actor, so a watch never lands between the last
    /// check and `running = false`.
    private func run() async {
        var last: SystemStats.Raw?
        var slowRead: (at: ContinuousClock.Instant, parts: SystemStats.Parts)?
        var bluetoothRead: ContinuousClock.Instant?
        /// The last reading that listed the processes, for the busiest by disk between two of them.
        var lastListing: SystemStats.Raw?
        var listing = Cadence(every: processInterval), sensing = Cadence(every: sensorInterval)
        var listings = 0
        /// The minute history's last reading, its rates measured from there: it reads once a minute, so the menu bar's
        /// own 2 s ticks never read what only the history needs.
        var lastHistory: SystemStats.Raw?
        var historyRead = Cadence(every: historyEvery)
        /// The process list starts over: the busiest lists empty, the next listing at once.
        func forgetListing() {
            lastListing = nil
            listing.reset()
            listings = 0
            clearBusiest()
        }
        history = []
        historyTimes = []
        while !watches.isEmpty {
            // Locked or asleep: read nothing, stop nettop, and start afresh on resume, so no rate spans the pause.
            if paused {
                updateNetTop(wanted: false)
                // The tick's own wait, a day long: resume cuts it short.
                let wait = Task { _ = try? await Task.sleep(for: .seconds(86_400)) }
                waiting = wait
                await wait.value
                continue
            }
            if restart {
                // Everything afresh after a pause: no rate across it, and the lists, sensors and slow readings read now.
                restart = false
                last = nil
                history = []   // the mini graphs start again rather than join across the pause
                historyTimes = []
                slowRead = nil
                bluetoothRead = nil
                sensing.reset()
                lastHistory = nil
                historyRead.reset()
                forgetListing()
            }
            let needs = watches.values.reduce(Needs()) { $0.union($1.needs) }
            // Only what is shown: everything for This Mac's rows, else each menu-bar item's own part.
            let historyDue = needs.contains(.history) && historyRead.due()
            var shown = needs.contains(.rows) ? SystemStats.Parts.all
                : watches.values.flatMap(\.stats).reduce(historyDue ? Self.historyParts : []) { $0.union($1.parts) }
            if needs.contains(.lowBattery) { shown.insert(.bluetoothHID) }
            var parts = shown.subtracting(.slow)
            // The slow parts every slowInterval, and at once when one is newly shown.
            let slowShown = shown.intersection(.slow).subtracting(.bluetooth)
            let slowDue = slowRead.map { $0.at.duration(to: .now) >= slowInterval || !slowShown.isSubset(of: $0.parts) } ?? true
            if !slowShown.isEmpty, slowDue {
                parts.formUnion(slowShown)
                slowRead = (.now, slowShown)
            }
            // Bluetooth every bluetoothInterval, and at once when it is newly shown.
            if !shown.contains(.bluetooth) {
                bluetoothRead = nil
            } else if bluetoothRead.map({ $0.duration(to: .now) >= bluetoothInterval }) ?? true {
                parts.insert(.bluetooth)
                bluetoothRead = .now
            }
            // The sensors every sensorInterval for the rows, unless a menu-bar item shows them.
            let itemShowsSensors = watches.values.contains { $0.stats.contains(.sensors) }
            if parts.contains(.sensors), !itemShowsSensors, !historyDue, !sensing.due() { parts.remove(.sensors) }
            let processes = !needs.isDisjoint(with: [.processes, .apps])
            let lists = processes && (relist || listing.due(every: listings == 1 ? relistAfter : nil))
            if lists {
                parts.insert(.processes)
                listings += 1
                relist = false
            }
            updatePublicIP(wanted: needs.contains(.publicIP))
            // Off the main thread: the disk's free space alone takes about 20 ms to work out, ps about 50; a listing's grouping
            // by app and its busiest too, the apps read here, where NSWorkspace lives. The tree is dropped once grouped, so the
            // readings kept between ticks never hold every process's path.
            let read = read, asked = parts, apps = lists ? runningApps() : []
            let (fresh, busiestApps) = await Task.detached(priority: .utility) {
                var raw = await read(asked)
                let grouped = raw.tree.map { Activity.snapshot($0, apps: apps).all }
                raw.tree = nil
                func top(_ rows: [Activity.Row], _ sort: Activity.Sort) -> [Activity.Row] { Array(Activity.sorted(rows, by: sort).prefix(6)) }
                return (raw, grouped.map { (cpu: top($0, .cpu), memory: top($0, .memory)) })
            }.value
            var now = fresh
            if let last {
                now.slow = now.slow.keeping(last.slow, readNow: parts)
                if !parts.contains(.sensors) { now.sensors = last.sensors }
            }
            let values = SystemStats.values(previous: last, now: now)
            // Rows and lists only for what shows them, set only when they change: a closed Home that still holds them sees
            // nothing new and redraws nothing.
            if needs.contains(.rows) {
                let new = SystemStats.rows(values, now: now, publicIP: publicIP)
                if new != rows { rows = new }
            }
            if lists {
                let listed = now.processes ?? []
                set(\.busiestCPU, .cpu, SystemStats.busiest(listed, by: .cpu))
                set(\.busiestMemory, .ram, SystemStats.busiest(combineProcesses ? SystemStats.combined(listed) : listed, by: .memory))
                processNames = Dictionary(listed.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })
                listApps(busiestApps ?? ([], []), processes: listed.count, now: now, values: values)
                if let before = lastListing?.processIO, let after = now.processIO, let lastListing {
                    let names = processNames
                    set(\.busiestDisk, .disk, SystemStats.busiestIO(before: before, after: after, seconds: now.time - lastListing.time,
                                                                    names: { names[$0] }))
                }
                lastListing = now
            } else if !processes {
                forgetListing()
            }
            updateNetTop(wanted: needs.contains(.processes))
            if last != nil {
                history.append(values)
                historyTimes.append(now.time)
                let stale = historyTimes.firstIndex { now.time - $0 < Double(historyLength) * SystemStats.interval } ?? historyTimes.count
                let drop = max(stale, history.count - historyLength)
                if drop > 0 { history.removeFirst(drop); historyTimes.removeFirst(drop) }
            }
            if historyDue {
                if lastHistory != nil { minutes.record(SystemStats.values(previous: lastHistory, now: now), at: clock()) }
                lastHistory = now
                if minutesSaved.due() { saveMinutes(waiting: false) }
            }
            last = now
            latest = now
            latestValues = values
            if !parts.isDisjoint(with: [.bluetooth, .bluetoothHID]) { onBluetooth?(now.slow.bluetooth) }
            // Chosen after the read, so a shorter watch that came during it counts.
            guard let interval = watches.values.map(\.interval).min() else { break }
            // A tenth of the interval late at most, so macOS can fire the tick with other wake-ups.
            let wait = Task { _ = try? await Task.sleep(for: interval, tolerance: interval / 10) }
            waiting = wait
            await wait.value
        }
        running = false
        clearBusiest()
        updateNetTop(wanted: false)
        updatePublicIP(wanted: false)
    }

    /// Today's minute history as saved, read once at launch; a file that does not decode is left alone and logged.
    func loadMinutes() {
        guard let minutesFile else { return }
        do { minutes = try minutesFile.load(or: StatsHistory()).kept(now: clock()) } catch {
            Self.log.error("stats-today: not read: \(String(describing: error), privacy: .public)")
        }
    }

    /// Saves today's finished minutes: every 10 minutes while reading, off the main thread so the tap never waits on the
    /// encoding, and at quit, waiting for it.
    func saveMinutes(waiting: Bool = true) {
        guard let minutesFile else { return }
        let kept = minutes.kept(now: clock())
        let save: @Sendable () -> Void = {
            do { try minutesFile.save(kept) } catch { Self.log.error("stats-today: not written: \(String(describing: error), privacy: .public)") }
        }
        if waiting { save() } else { Task.detached(priority: .utility, operation: save) }
    }

    /// Stops reading until `resume`, as the screen locks or the display sleeps.
    func pause() {
        paused = true
    }

    /// Reads again at once, from a fresh start.
    func resume() {
        guard paused else { return }
        paused = false
        restart = true
        waiting?.cancel()
    }

    /// Sets a busiest list and its live slots, `stat` naming which, only when it changed: every assignment wakes what
    /// observes it.
    private func set(_ list: ReferenceWritableKeyPath<SystemSampler, [SystemStats.Row]>, _ stat: MenuBarStats.Stat,
                     _ value: [SystemStats.Row]) {
        guard self[keyPath: list] != value else { return }
        self[keyPath: list] = value
        if let rebuilt = LiveRow.sync(busiestSlots[stat] ?? [], to: value, id: { i, _ in "\(stat.rawValue).\(i)" }) {
            busiestSlots[stat] = rebuilt
        }
    }

    private func clearBusiest() {
        set(\.busiestCPU, .cpu, [])
        set(\.busiestMemory, .ram, [])
        set(\.busiestDisk, .disk, [])
        lookout = StatsOverview.Watch()
        if !appsByCPU.isEmpty { appsByCPU = [] }
        if !appsByMemory.isEmpty { appsByMemory = [] }
        if processCount != nil { processCount = nil }
        if !findings.isEmpty { findings = [] }
    }

    /// The busiest by CPU and by memory from one listing grouped as Activity groups it, and what is worth a look; each set
    /// only when it changed.
    private func listApps(_ busiest: (cpu: [Activity.Row], memory: [Activity.Row]), processes: Int, now: SystemStats.Raw,
                          values: SystemStats.Values) {
        let (byCPU, byMemory) = busiest
        if byCPU != appsByCPU { appsByCPU = byCPU }
        if byMemory != appsByMemory { appsByMemory = byMemory }
        if processCount != processes { processCount = processes }
        var mac = StatsOverview.Mac()
        mac.pressure = now.memory.pressure
        mac.swapUsed = now.memory.swapUsed
        mac.physicalMemory = now.memory.total
        mac.disk = now.slow.disk
        mac.heat = values.heat
        mac.thermal = now.thermal
        mac.battery = now.battery
        lookout.record(byCPU + byMemory, mac: mac, at: clock())
        if lookout.findings != findings { findings = lookout.findings }
    }

    /// Starts nettop's loop when the busiest are listed, and stops it, forgetting its list, when they are not.
    private func updateNetTop(wanted: Bool) {
        if wanted {
            guard netTopLoop == nil else { return }
            let netTop = netTop, pause = netTopPause
            netTopLoop = Task {
                var before: (counts: [String: SystemStats.DiskIO], at: ContinuousClock.Instant)?
                while !Task.isCancelled {
                    guard let csv = await netTop() else { try? await Task.sleep(for: .seconds(1)); continue }
                    guard !Task.isCancelled else { break }
                    let counts = SystemStats.nettop(csv), at = ContinuousClock.now
                    if let before {
                        let seconds = Double(before.at.duration(to: at).components.attoseconds) / 1e18
                            + Double(before.at.duration(to: at).components.seconds)
                        let names = processNames
                        set(\.busiestNetwork, .network, SystemStats.busiestNetwork(before: before.counts, after: counts, seconds: seconds, names: { names[$0] }))
                    }
                    before = (counts, at)
                    try? await Task.sleep(for: pause, tolerance: pause / 10)
                }
            }
        } else {
            netTopLoop?.cancel()
            netTopLoop = nil
            set(\.busiestNetwork, .network, [])
        }
    }

    /// Fetches the public IP when a watch wants it and the last fetch is 10 minutes old; forgets it when none does.
    private func updatePublicIP(wanted: Bool) {
        // Set only when it changes: every assignment wakes what observes it, and this runs each tick.
        guard wanted else { if publicIP != nil { publicIP = nil }; publicIPReadAt = nil; return }
        if let at = publicIPReadAt, at.duration(to: .now) < Self.publicIPInterval { return }
        publicIPReadAt = .now
        let fetch = fetchPublicIP
        Task {
            let ip = await fetch()
            if publicIPReadAt != nil, publicIP != ip { publicIP = ip }
        }
    }
}

/// One of the busiest slots, observed on its own, so a new value redraws that slot alone (card agent-bo-95422838).
@Observable @MainActor
final class LiveRow: Identifiable {
    let id: String
    var row: SystemStats.Row
    init(_ row: SystemStats.Row, id: String? = nil) { self.id = id ?? row.id; self.row = row }

    /// Brings `live` in line with `rows`, changing a live row only when its row changed; returns the new list when rows
    /// came or went (keeping the live rows whose id stays), nil when the list itself stays.
    static func sync(_ live: [LiveRow], to rows: [SystemStats.Row], id: (Int, SystemStats.Row) -> String) -> [LiveRow]? {
        let ids = rows.enumerated().map { id($0, $1) }
        if ids == live.map(\.id) {
            for (item, row) in zip(live, rows) where item.row != row { item.row = row }
            return nil
        }
        let kept = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return zip(ids, rows).map { id, row in
            guard let item = kept[id] else { return LiveRow(row, id: id) }
            if item.row != row { item.row = row }
            return item
        }
    }
}

/// A reading on its own schedule: due at the first ask, then once `every` has passed since the last due.
struct Cadence {
    let every: Duration
    private var last: ContinuousClock.Instant?
    init(every: Duration) { self.every = every }
    /// Due when `every` (or, this once, `other`) has passed since the last due.
    mutating func due(every other: Duration? = nil) -> Bool {
        if let last, last.duration(to: .now) < (other ?? every) { return false }
        last = .now
        return true
    }
    mutating func reset() { last = nil }
}
