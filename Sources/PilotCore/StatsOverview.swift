import Foundation

/// Stats' Overview (Sven's card layout, 2026-10-12, in place of Comfortable): six cards, Worth a look and Right now. What
/// it works out from readings Pilot already takes: the busiest apps' share of a ring, and the things worth a look.
public enum StatsOverview {
    /// One part of a ring: a name, its amount and its words.
    public struct Slice: Equatable, Sendable {
        public let name: String
        public let amount: Double
        public init(name: String, amount: Double) { self.name = name; self.amount = amount }
    }

    /// The first `most` items with an amount, then Other for what `total` holds beyond them; nothing past the total, so a
    /// ring never draws more than its whole.
    public static func slices(_ items: [Slice], total: Double, most: Int = 5) -> [Slice] {
        var left = max(0, total)
        var kept: [Slice] = []
        for item in items.filter({ $0.amount > 0 }).prefix(most) where left > 0 {
            let amount = min(item.amount, left)
            kept.append(Slice(name: item.name, amount: amount))
            left -= amount
        }
        // Other only when it is more than a rounding's worth of the whole.
        if left > total * 0.005 { kept.append(Slice(name: "Other", amount: left)) }
        return kept
    }

    /// The average of what was read; nil when nothing was.
    public static func average(_ values: [Double?]) -> Double? {
        let read = values.compactMap(\.self)
        return read.isEmpty ? nil : read.reduce(0, +) / Double(read.count)
    }

    /// A per-minute rate's total: each minute's average rate, a minute long.
    public static func total(perMinute rates: [Double?]) -> Double { rates.reduce(0) { $0 + ($1 ?? 0) * 60 } }

    // MARK: Worth a look

    /// One thing worth a look: what it is about, its words, its value now, its tag and when it was first seen.
    public struct Finding: Equatable, Sendable, Identifiable {
        public enum Tag: String, Sendable { case cpu = "CPU", memory = "Memory", disk = "Disk", heat = "Heat", battery = "Battery" }

        public let id: String
        /// The app it is about, for its icon; nil for the Mac itself.
        public let app: String?
        public let title: String
        public let line: String
        public let value: String
        public let tag: Tag
        public var since: Date

        public init(id: String, app: String?, title: String, line: String, value: String, tag: Tag, since: Date) {
            self.id = id; self.app = app; self.title = title; self.line = line; self.value = value; self.tag = tag; self.since = since
        }
    }

    /// The Mac's own readings a finding can come from.
    public struct Mac: Equatable, Sendable {
        public var pressure = SystemStats.Pressure.normal
        public var swapUsed: UInt64 = 0
        public var physicalMemory: UInt64 = 0
        public var disk: SystemStats.Disk?
        /// The CPU's average temperature in °C.
        public var heat: Double?
        public var thermal = SystemStats.Thermal.nominal
        public var battery: SystemStats.Battery?
        public init() {}
    }

    /// Watches the busiest apps across the process listings Stats already reads (every 10 s while it shows), grouped as
    /// Activity groups them, and names what is worth a look: an app keeping the CPU busy, one whose memory keeps growing, one holding a lot of it, and the Mac
    /// short of memory or disk, running hot or low on battery. Forgets everything older than `window`.
    public struct Watch: Sendable {
        public static let window: TimeInterval = 600
        /// An app busy on average over at least this long (a share of one core, as ps counts it).
        static let busyCPU = 50.0, busyFor: TimeInterval = 60
        /// Memory grown by this much and by a quarter, over at least this long.
        static let growth: UInt64 = 512 << 20, growthFor: TimeInterval = 120
        /// A macOS update wants about 20 GB free.
        static let lowDisk: Int64 = 20_000_000_000

        /// Each listing's CPU and memory by row id (an app's or a background process's pid), so two processes of one name
        /// stay two; the rows themselves only for the latest.
        private var samples: [(time: Date, apps: [String: (cpu: Double, memory: UInt64)])] = []
        private var latest: [Activity.Row] = []
        private var seen: [String: Date] = [:]
        public private(set) var findings: [Finding] = []

        public init() {}

        /// One listing's busiest rows (Activity's: each app with what it started, or a background process) and the Mac's
        /// readings at `now`.
        public mutating func record(_ apps: [Activity.Row], mac: Mac, at now: Date) {
            var ids = Set<String>()
            latest = apps.filter { ids.insert($0.id).inserted }
            samples.append((now, Dictionary(uniqueKeysWithValues: latest.map { ($0.id, ($0.cpu, $0.memory)) })))
            samples.removeAll { now.timeIntervalSince($0.time) > Self.window }
            var found = Self.macFindings(mac) + appFindings(now: now, physicalMemory: mac.physicalMemory)
            // Each keeps the time it was first seen; one gone is forgotten, so it counts afresh if it comes back.
            seen = seen.filter { id, _ in found.contains { $0.id == id } }
            for i in found.indices {
                found[i].since = seen[found[i].id] ?? now
                seen[found[i].id] = found[i].since
            }
            findings = found
        }

        static func macFindings(_ mac: Mac) -> [Finding] {
            var found: [Finding] = []
            if mac.thermal == .serious || mac.thermal == .critical || (mac.heat ?? 0) >= 95 {
                let heat = mac.heat.map { "CPU at \(Int($0.rounded())) °C" } ?? "macOS reports \(mac.thermal.rawValue.lowercased()) heat"
                found.append(Finding(id: "mac.heat", app: nil, title: "This Mac is running hot",
                                     line: "\(heat); macOS slows it down to cool it.", value: mac.heat.map { "\(Int($0.rounded())) °C" } ?? mac.thermal.rawValue,
                                     tag: .heat, since: .distantPast))
            }
            if mac.pressure != .normal {
                found.append(Finding(id: "mac.pressure", app: nil, title: "Memory is under pressure",
                                     line: mac.pressure == .critical ? "macOS is out of room and swapping; quit a heavy app."
                                         : "macOS is squeezing memory to make room; a heavy app may be the cause.",
                                     value: mac.swapUsed > 0 ? "Swap \(SystemStats.memorySize(mac.swapUsed))" : mac.pressure.rawValue.capitalized,
                                     tag: .memory, since: .distantPast))
            }
            if let disk = mac.disk, disk.total > 0, disk.available < lowDisk {
                found.append(Finding(id: "mac.disk", app: nil, title: "The disk is nearly full",
                                     line: "\(SystemStats.decimal(Double(disk.available))) free of \(SystemStats.decimal(Double(disk.total))); a macOS update wants about 20 GB.",
                                     value: "\(SystemStats.decimal(Double(disk.available))) free", tag: .disk, since: .distantPast))
            }
            if let battery = mac.battery, battery.percent < 20, !battery.pluggedIn, !battery.charging {
                let left = battery.minutesLeft.map { ", about \(SystemStats.duration(minutes: $0)) left" } ?? ""
                found.append(Finding(id: "mac.battery", app: nil, title: "The battery is low", line: "\(battery.percent) %\(left).",
                                     value: "\(battery.percent) %", tag: .battery, since: .distantPast))
            }
            return found
        }

        private func appFindings(now: Date, physicalMemory: UInt64) -> [Finding] {
            guard let first = samples.first, let last = samples.last else { return [] }
            let span = now.timeIntervalSince(first.time)
            var found: [Finding] = [], named = Set<String>()
            // Busy: the average across every listing in the window, one the app was not among counting as idle.
            if span >= Self.busyFor {
                let busy = latest.compactMap { app -> (Activity.Row, Double)? in
                    let average = samples.reduce(0) { $0 + ($1.apps[app.id]?.cpu ?? 0) } / Double(samples.count)
                    return average >= Self.busyCPU ? (app, average) : nil
                }
                for (app, average) in busy.sorted(by: { $0.1 > $1.1 }) {
                    found.append(Finding(id: "cpu.\(app.id)", app: app.name, title: "\(app.name) is keeping the CPU busy",
                                         line: "\(Int(average.rounded())) % of a core on average for \(Self.words(span))\(Self.across(app)).",
                                         value: String(format: "Now %.1f %%", app.cpu), tag: .cpu, since: .distantPast))
                    named.insert(app.id)
                }
            }
            // Growing: from its first listing in the window to now, by `growth` and by a quarter.
            for app in latest.sorted(by: { $0.memory > $1.memory }) {
                guard let start = samples.first(where: { $0.apps[app.id] != nil }), let was = start.apps[app.id]?.memory else { continue }
                let now = app.memory
                let over = last.time.timeIntervalSince(start.time)
                if over >= Self.growthFor, now >= was + Self.growth, Double(now) >= Double(was) * 1.25 {
                    found.append(Finding(id: "grow.\(app.id)", app: app.name, title: "\(app.name) is using more and more memory",
                                         line: "Up \(SystemStats.memorySize(now - was)) in \(Self.words(over)), now \(SystemStats.memorySize(now))\(Self.across(app)).",
                                         value: "Now \(SystemStats.memorySize(now))", tag: .memory, since: .distantPast))
                    named.insert(app.id)
                } else if physicalMemory > 0, !named.contains(app.id),
                          Activity.heat(memory: now, physicalMemory: physicalMemory) == .hog {
                    let share = Int((Double(now) / Double(physicalMemory) * 100).rounded())
                    found.append(Finding(id: "big.\(app.id)", app: app.name, title: "\(app.name) holds a lot of memory",
                                         line: "\(share) % of this Mac's \(SystemStats.memorySize(physicalMemory))\(Self.across(app)).",
                                         value: SystemStats.memorySize(now), tag: .memory, since: .distantPast))
                }
            }
            return found
        }

        /// ", across 318 processes" for an app with what it started; nothing for one process.
        static func across(_ row: Activity.Row) -> String { row.processCount > 1 ? ", across \(row.processCount) processes" : "" }

        /// "the last 4 minutes", "the last minute".
        static func words(_ seconds: TimeInterval) -> String {
            let minutes = Int((seconds / 60).rounded())
            return minutes <= 1 ? "the last minute" : "the last \(minutes) minutes"
        }
    }

    /// "just now", "4 min ago", "1 h ago": how long since a finding was first seen.
    public static func ago(_ since: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(since) / 60)
        return minutes < 1 ? "just now" : minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h ago"
    }
}
