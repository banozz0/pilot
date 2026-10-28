import Darwin
import Foundation

/// Activity (task N3, Sven 2026-10-09: "an own page which acts like activity monitor and we can remove from there"):
/// what runs on this Mac, apps first with their helpers rolled up under them, then what runs in the background, each
/// with what it costs and whether Pilot may quit it. The page and the menu's Kill a process read the same snapshot and
/// quit through the same plan.
public enum Activity {
    /// One process as `ps` lists it.
    public struct Process: Equatable, Sendable {
        public var pid, ppid: Int32
        public var uid: UInt32
        /// Percent of one core, as ps and Activity Monitor count it (ps's decaying average).
        public var cpu: Double
        /// Bytes in memory: ps's resident size, or the footprint where the reader can read it.
        public var memory: UInt64
        /// The program's full path, or its bare name where ps gives no path.
        public let path: String
        /// The program's own name, read once from its path.
        public let name: String

        public init(pid: Int32, ppid: Int32, uid: UInt32, cpu: Double, memory: UInt64, path: String) {
            self.pid = pid; self.ppid = ppid; self.uid = uid; self.cpu = cpu; self.memory = memory; self.path = path
            name = String(path.split(separator: "/").last ?? Substring(path))
        }
    }

    /// Every process, its parent, owner, CPU, resident size and program; about 30 ms for 900 processes on an M4.
    public static let psArguments = ["-Ao", "pid=,ppid=,uid=,pcpu=,rss=,comm="]

    /// ps's lines as processes; a line that does not read is left out. The path may hold spaces.
    public static func parse(_ ps: String) -> [Process] {
        ps.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard f.count == 6, let pid = Int32(f[0]), let ppid = Int32(f[1]), let uid = UInt32(f[2]), let cpu = Double(f[3]),
                  let rss = UInt64(f[4]) else { return nil }
            return Process(pid: pid, ppid: ppid, uid: uid, cpu: cpu, memory: rss * 1024, path: String(f[5]))
        }
    }

    /// Your processes' memory as Activity Monitor counts it, the footprint, where `footprint` reads one; the rest keep ps's
    /// resident size. Activity and Stats' Overview both count memory this way.
    public static func footprinted(_ processes: [Process], me: UInt32 = getuid(), footprint: (Int32) -> UInt64?) -> [Process] {
        processes.map { p in
            guard p.uid == me, let bytes = footprint(p.pid), bytes > 0 else { return p }
            var p = p
            p.memory = bytes
            return p
        }
    }

    /// An app as macOS runs it with a Dock icon (NSRunningApplication's regular apps).
    public struct App: Equatable, Sendable {
        public var pid: Int32
        public var name: String
        /// Its bundle, "/Applications/Zen.app"; the processes inside it are its helpers.
        public var bundlePath: String?
        public init(pid: Int32, name: String, bundlePath: String?) { self.pid = pid; self.name = name; self.bundlePath = bundlePath }
    }

    /// What Pilot may do to a row.
    public enum Rights: Equatable, Sendable {
        /// Yours: quit, and force quit when it will not.
        case quitAndForce
        /// Yours but macOS's own (a program under /System or /usr): asked to quit, macOS starts it again; never forced.
        case quitOnly
        /// Not Pilot's to quit, and why: another user's or the system's, macOS needs it, or it is Pilot.
        case none(Reason)

        /// Why, as a row says it under its name.
        public enum Reason: String, Sendable { case system = "System", macOS = "Needed by macOS", pilot = "Pilot" }

        public var canQuit: Bool { if case .none = self { false } else { true } }
        public var canForce: Bool { self == .quitAndForce }
    }

    /// How heavy a row is: a hog takes most of a core or a fifth of the memory; busy, a fifth of a core or a twentieth.
    public enum Heat: Int, Comparable, Sendable {
        case calm, busy, hog
        public static func < (a: Heat, b: Heat) -> Bool { a.rawValue < b.rawValue }
    }

    public static func heat(cpu: Double, memory: UInt64, physicalMemory: UInt64) -> Heat {
        max(heat(cpu: cpu), heat(memory: memory, physicalMemory: physicalMemory))
    }

    public static func heat(cpu: Double) -> Heat { cpu >= 70 ? .hog : cpu >= 20 ? .busy : .calm }

    /// In whole bytes, so a fifth of the memory is a fifth however it divides.
    public static func heat(memory: UInt64, physicalMemory: UInt64) -> Heat {
        guard physicalMemory > 0 else { return .calm }
        return memory * 5 >= physicalMemory ? .hog : memory * 20 >= physicalMemory ? .busy : .calm
    }

    /// One line of the page: an app with its helpers summed in, a helper under it, or a background process.
    public struct Row: Identifiable, Equatable, Sendable {
        public enum Kind: Sendable { case app, process }
        public var kind: Kind
        public var pid: Int32
        public var name: String
        public var bundlePath: String?
        /// The row's own and its helpers' together.
        public var cpu: Double
        public var memory: UInt64
        public var rights: Rights
        /// An app's helpers, heaviest first by CPU; empty for a process.
        public var children: [Row]
        /// "app.123" or "pid.123": a pid is an app's or a process's, never both.
        public var id: String { (kind == .app ? "app." : "pid.") + String(pid) }
        /// The app's own process and its helpers.
        public var processCount: Int { 1 + children.count }

        public init(kind: Kind, pid: Int32, name: String, bundlePath: String? = nil, cpu: Double, memory: UInt64, rights: Rights,
                    children: [Row] = []) {
            self.kind = kind; self.pid = pid; self.name = name; self.bundlePath = bundlePath
            self.cpu = cpu; self.memory = memory; self.rights = rights; self.children = children
        }
    }

    /// Everything running, read at once: the apps with their helpers, and the background processes.
    public struct Snapshot: Equatable, Sendable {
        public var apps: [Row]
        public var background: [Row]
        public init(apps: [Row], background: [Row]) { self.apps = apps; self.background = background }
        public static let empty = Snapshot(apps: [], background: [])

        public var all: [Row] { apps + background }
        /// Every row's id, an app's helpers' included.
        public var ids: Set<String> { Set(all.flatMap { [$0.id] + $0.children.map(\.id) }) }
        /// The row with this id, an app's helper included.
        public func row(_ id: String) -> Row? {
            for row in all {
                if row.id == id { return row }
                if let child = row.children.first(where: { $0.id == id }) { return child }
            }
            return nil
        }
    }

    /// Your programs macOS needs running: quitting loginwindow logs you out. Never quit from here (root's and other
    /// users' are already the system's).
    static let neededByMacOS: Set<String> = ["loginwindow"]
    /// Where macOS keeps its own programs: yours to ask to quit, never to force.
    static let systemFolders = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]

    /// Groups `processes` by app: a process inside a running app's bundle, or started by one (a terminal's shells and what
    /// runs in them), counts under that app; the rest are background. `me` is your uid, `pilot` Pilot's own pid: Pilot
    /// and what it started are shown but never quit from here. Unsorted; `sorted` orders them.
    public static func snapshot(_ processes: [Process], apps: [App], me: UInt32 = getuid(), pilot: Int32 = getpid()) -> Snapshot {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let running = apps.filter { byPid[$0.pid] != nil }
        let appByPid = Dictionary(running.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        // The outermost bundle first, so a bundle inside another app's (Zen's plugin-container.app) counts under that app.
        let bundles = running.compactMap { app in app.bundlePath.map { ($0.hasSuffix("/") ? $0 : $0 + "/", app.pid) } }
            .sorted { $0.0.count < $1.0.count }

        /// The first answer `hit` gives for `pid` or the process that started it, climbing at most 64 parents (launchd
        /// ends the climb), each answer kept in `memo`.
        func climb(_ pid: Int32, _ memo: inout [Int32: Int32?], _ hit: (Process) -> Int32?) -> Int32? {
            var path: [Int32] = [], at = pid, found: Int32?
            while path.count < 64 {
                if let known = memo[at] { found = known; break }
                guard let p = byPid[at] else { break }
                path.append(at)
                if let h = hit(p) { found = h; break }
                guard p.ppid > 1, p.ppid != at else { break }
                at = p.ppid
            }
            for visited in path { memo[visited] = found }
            return found
        }
        var owners: [Int32: Int32?] = [:], pilots: [Int32: Int32?] = [:]
        func owner(_ pid: Int32) -> Int32? {
            climb(pid, &owners) { p in appByPid[p.pid] != nil ? p.pid : bundles.first { p.path.hasPrefix($0.0) }?.1 }
        }
        // Pilot and everything it started (its file index, a ps it runs), wherever they are listed.
        func fromPilot(_ pid: Int32) -> Bool { climb(pid, &pilots) { $0.pid == pilot ? pilot : nil } != nil }

        func rights(_ p: Process, app: Bool) -> Rights {
            if fromPilot(p.pid) { return .none(.pilot) }
            if p.uid != me || p.pid <= 1 { return .none(.system) }
            if neededByMacOS.contains(p.name) { return .none(.macOS) }
            // An app is quit through macOS, so its folder does not limit it: Finder is quit and forced as any app.
            return !app && systemFolders.contains { p.path.hasPrefix($0) } ? .quitOnly : .quitAndForce
        }

        var helpers: [Int32: [Row]] = [:], background: [Row] = []
        for p in processes where appByPid[p.pid] == nil {
            let row = Row(kind: .process, pid: p.pid, name: p.name, cpu: p.cpu, memory: p.memory, rights: rights(p, app: false))
            if let app = owner(p.pid) { helpers[app, default: []].append(row) } else { background.append(row) }
        }
        let appRows = running.compactMap { app -> Row? in
            guard let p = byPid[app.pid] else { return nil }
            let children = helpers[app.pid] ?? []
            return Row(kind: .app, pid: app.pid, name: app.name, bundlePath: app.bundlePath,
                       cpu: children.reduce(p.cpu) { $0 + $1.cpu }, memory: children.reduce(p.memory) { $0 + $1.memory },
                       rights: rights(p, app: true), children: children)
        }
        return Snapshot(apps: appRows, background: background)
    }

    public enum Sort: String, CaseIterable, Sendable {
        case cpu, memory
        public var title: String { self == .cpu ? "CPU" : "Memory" }
    }

    /// Heaviest first by `sort`, the other reading then the name breaking ties; each app's helpers too.
    public static func sorted(_ rows: [Row], by sort: Sort) -> [Row] {
        func heavier(_ a: Row, _ b: Row) -> Bool {
            let (x, y) = sort == .cpu ? ((a.cpu, Double(a.memory)), (b.cpu, Double(b.memory))) : ((Double(a.memory), a.cpu), (Double(b.memory), b.cpu))
            if x != y { return x > y }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return rows.map { row in
            var row = row
            row.children = row.children.sorted(by: heavier)
            return row
        }.sorted(by: heavier)
    }

    public static func sorted(_ snapshot: Snapshot, by sort: Sort) -> Snapshot {
        Snapshot(apps: sorted(snapshot.apps, by: sort), background: sorted(snapshot.background, by: sort))
    }

    /// The rows whose name holds `query` (any case) or whose pid is it, else, when none, those a typo of it names
    /// (FuzzyRanker.Filter); an app whose own name does not match keeps only its helpers that do. A blank query keeps
    /// everything.
    public static func filtered(_ rows: [Row], query: String) -> [Row] {
        let filter = FuzzyRanker.Filter(query), q = filter.typed
        guard !q.isEmpty else { return rows }
        return filter.search { test in filtered(rows) { String($0.pid) == q || test([$0.name]) } }
    }

    private static func filtered(_ rows: [Row], by hit: (Row) -> Bool) -> [Row] {
        rows.compactMap { row in
            if hit(row) { return row }
            let children = row.children.filter(hit)
            guard !children.isEmpty else { return nil }
            var kept = row
            kept.children = children
            return kept
        }
    }

    public static func filtered(_ snapshot: Snapshot, query: String) -> Snapshot {
        Snapshot(apps: filtered(snapshot.apps, query: query), background: filtered(snapshot.background, query: query))
    }

    /// How a row is quit: an app through macOS (it may ask to save first; forced, at once), anything else by a signal.
    public enum Quit: Equatable, Sendable {
        case app(pid: Int32, force: Bool)
        case signal(pid: Int32, Int32)
    }

    /// The quit `row` gets, forced or not; nil when its rights do not allow it.
    public static func quit(_ row: Row, force: Bool) -> Quit? {
        guard force ? row.rights.canForce : row.rights.canQuit else { return nil }
        return row.kind == .app ? .app(pid: row.pid, force: force) : .signal(pid: row.pid, force ? SIGKILL : SIGTERM)
    }

    // MARK: Words

    /// "18.2 %", one place as Activity Monitor shows it.
    public static func cpuText(_ cpu: Double) -> String { String(format: "%.1f %%", cpu) }
    public static func memoryText(_ bytes: UInt64) -> String { SystemStats.memorySize(bytes) }

    /// The menu's Kill a process rows: the apps and your background processes Pilot may quit, busiest CPU first, each
    /// "18.2 % CPU · 1.4 GB · 9 processes"; the row's id rides in the target.
    public static func entries(_ snapshot: Snapshot) -> [MenuEntry] {
        sorted(snapshot.all.filter(\.rights.canQuit), by: .cpu).map { row in
            let count = row.processCount > 1 ? " · \(row.processCount) processes" : ""
            return MenuEntry(title: row.name, target: .action(row.id),
                             detail: "\(cpuText(row.cpu)) CPU · \(memoryText(row.memory))" + count)
        }
    }

    /// Hyper+Space › Activity's rows (Sven 2026-10-21, Q399 A): the apps, then the background, each busiest CPU first under
    /// its heading; each its icon, under its name how many processes it holds or whose it is, its CPU and memory at the
    /// right. Every row is listed, the ones Pilot may not quit too, so the screen is what runs; Return on one of those says
    /// why instead (PilotMenu). `quitting` says Quitting… on the rows asked to quit.
    public static func screenEntries(_ snapshot: Snapshot, quitting: Set<String> = []) -> [MenuEntry] {
        let shown = sorted(snapshot, by: .cpu)
        func entry(_ row: Row, _ section: String) -> MenuEntry {
            let owner: String? = switch row.rights {
            case .none(let reason): reason.rawValue
            case .quitOnly: "macOS"
            case .quitAndForce: nil
            }
            let under = quitting.contains(row.id) ? "Quitting…"
                : row.kind == .app ? (row.children.isEmpty ? nil : "\(row.processCount) processes") : owner
            let glyph = row.kind == .app ? MenuIcon.glyph("app.dashed", .neutral) : .glyph("gearshape", .neutral)
            var e = MenuEntry(title: row.name, target: .process(row.id), home: .activity,
                              detail: "\(cpuText(row.cpu)) · \(memoryText(row.memory))", inSearch: false, subtitle: under,
                              icon: glyph.app(path: row.bundlePath))
            e.section = section
            return e
        }
        return shown.apps.map { entry($0, "Apps") } + shown.background.map { entry($0, "Background") }
    }

    /// What Return or Cmd+Return on an Activity row cannot do, in words, as the menu's foot says it; nil when it can.
    public static func refusal(_ row: Row, force: Bool) -> String? {
        if case .none(let reason) = row.rights {
            return switch reason {
            case .pilot: "That is Pilot itself; quit it from its menu bar menu"
            case .macOS: "macOS needs \(row.name); Pilot never quits it"
            case .system: "\(row.name) is the system's or another user's; Pilot cannot quit it"
            }
        }
        return force && !row.rights.canForce ? "macOS starts \(row.name) again, so Pilot never forces it; Return asks it to quit" : nil
    }
}
