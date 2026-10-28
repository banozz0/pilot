import Foundation

/// How far back the Stats page draws (card agent-bo-95422992; Sven, 2026-10-07: all three): the sampler's last 2 minutes
/// while a page shows, else the minute history's last hour or today.
public enum StatsRange: String, CaseIterable, Sendable {
    case twoMinutes, hour, today

    public var title: String {
        switch self {
        case .twoMinutes: "2 min"
        case .hour: "1 hour"
        case .today: "Today"
        }
    }

    /// The three words under a chart: its start, its middle and now; Today's middle the hour halfway since midnight.
    public func axis(now: Date, calendar: Calendar = .current) -> [String] {
        switch self {
        case .twoMinutes: return ["2 min ago", "1 min", "now"]
        case .hour: return ["60 min ago", "30 min", "now"]
        case .today:
            let midnight = calendar.startOfDay(for: now)
            let middle = calendar.component(.hour, from: midnight.addingTimeInterval(now.timeIntervalSince(midnight) / 2))
            return ["00:00", String(format: "%02d:00", middle), "now"]
        }
    }
}

/// This Mac's readings a minute at a time, for Stats' 1 hour and Today (card agent-bo-95422992): every reading inside a
/// minute averages into that minute's one point, a reading with no value leaving that value out; today's finished minutes
/// are kept and saved, yesterday's dropped at local midnight.
public struct StatsHistory: Codable, Equatable, Sendable {
    /// One minute's average; nil for a value no reading in it had.
    public struct Point: Codable, Equatable, Sendable {
        /// The minute's start.
        public var time: Date
        public var cpu, ram, gpu, down, up, diskRead, diskWrite, heat, fan: Double?

        public init(time: Date, cpu: Double? = nil, ram: Double? = nil, gpu: Double? = nil, down: Double? = nil, up: Double? = nil,
                    diskRead: Double? = nil, diskWrite: Double? = nil, heat: Double? = nil, fan: Double? = nil) {
            self.time = time; self.cpu = cpu; self.ram = ram; self.gpu = gpu; self.down = down; self.up = up
            self.diskRead = diskRead; self.diskWrite = diskWrite; self.heat = heat; self.fan = fan
        }

        /// A reading's values as a point at `time`.
        public init(time: Date, _ v: SystemStats.Values) {
            self.init(time: time, cpu: v.cpu, ram: v.ram, gpu: v.gpu, down: v.down, up: v.up, diskRead: v.diskRead,
                      diskWrite: v.diskWrite, heat: v.heat, fan: v.fan)
        }

        /// Its values in one order, for the averaging and the charts.
        public static let fields: [WritableKeyPath<Point, Double?> & Sendable] = [\.cpu, \.ram, \.gpu, \.down, \.up, \.diskRead, \.diskWrite, \.heat, \.fan]
    }

    /// Finished minutes, oldest first: today's, and since the last midnight passed the hour before it.
    public private(set) var points: [Point] = []
    /// The minute being read: each value's sum and how many readings had it.
    private var open: (time: Date, sums: [Double], counts: [Int])?

    public init() {}

    private enum CodingKeys: String, CodingKey { case points }

    public static func == (a: StatsHistory, b: StatsHistory) -> Bool {
        a.points == b.points && a.open?.time == b.open?.time && a.open?.sums == b.open?.sums && a.open?.counts == b.open?.counts
    }

    /// One reading at `time`: added to its minute, which closes the minute before it.
    public mutating func record(_ values: SystemStats.Values, at time: Date, calendar: Calendar = .current) {
        let minute = calendar.dateInterval(of: .minute, for: time)?.start ?? time
        if let open, open.time != minute { close(before: time, calendar: calendar) }
        var current = open ?? (minute, Array(repeating: 0, count: Point.fields.count), Array(repeating: 0, count: Point.fields.count))
        let reading = Point(time: minute, values)
        for (i, field) in Point.fields.enumerated() {
            guard let value = reading[keyPath: field] else { continue }
            current.sums[i] += value
            current.counts[i] += 1
        }
        open = current
    }

    /// The range's points, oldest first, the minute being read last: the last 60 minutes for an hour, since local
    /// midnight for today; none for 2 minutes, which the sampler's own history draws.
    public func points(_ range: StatsRange, now: Date, calendar: Calendar = .current) -> [Point] {
        let all = points + (openPoint.map { [$0] } ?? [])
        switch range {
        case .twoMinutes: return []
        case .hour:
            let from = (calendar.dateInterval(of: .minute, for: now)?.start ?? now).addingTimeInterval(-59 * 60)
            return all.filter { $0.time >= from && $0.time <= now }
        case .today:
            let midnight = calendar.startOfDay(for: now)
            return all.filter { $0.time >= midnight && $0.time <= now }
        }
    }

    /// What is saved: today's finished minutes, without the one being read.
    public func kept(now: Date, calendar: Calendar = .current) -> StatsHistory {
        var kept = StatsHistory()
        kept.points = points.filter { calendar.isDate($0.time, inSameDayAs: now) }
        return kept
    }

    /// The open minute's averages as a point.
    private var openPoint: Point? {
        guard let open else { return nil }
        var point = Point(time: open.time)
        for (i, field) in Point.fields.enumerated() where open.counts[i] > 0 { point[keyPath: field] = open.sums[i] / Double(open.counts[i]) }
        return point
    }

    /// Ends the open minute and forgets what neither the last hour nor today needs any more.
    private mutating func close(before time: Date, calendar: Calendar) {
        if let point = openPoint { points.append(point) }
        open = nil
        let hourAgo = time.addingTimeInterval(-3600)
        points.removeAll { $0.time < hourAgo && !calendar.isDate($0.time, inSameDayAs: time) }
    }
}

/// Today's presses (card agent-bo-95422992): Home's count, its most used and its presses by hour, kept apart from the
/// last 50 presses Pilot shows, starting over at local midnight and saved so a restart keeps the day.
public struct TodayPresses: Codable, Equatable, Sendable {
    /// The day counted, as its midnight; nil before the first press.
    public private(set) var day: Date?
    public private(set) var counts: [String: Int] = [:]
    public private(set) var byHour: [Int] = Array(repeating: 0, count: 24)

    public init() {}

    public mutating func count(_ action: String, at time: Date, calendar: Calendar = .current) {
        let midnight = calendar.startOfDay(for: time)
        if day != midnight { self = TodayPresses(); day = midnight }
        counts[action, default: 0] += 1
        byHour[calendar.component(.hour, from: time)] += 1
    }

    /// The day as of `now`: this one while it is still today, an empty one once midnight has passed.
    private func on(_ now: Date, _ calendar: Calendar) -> TodayPresses {
        day.map { calendar.isDate($0, inSameDayAs: now) } == true ? self : TodayPresses()
    }

    public func total(now: Date, calendar: Calendar = .current) -> Int { on(now, calendar).byHour.reduce(0, +) }

    /// How often `action` ran today.
    public func count(of action: String, now: Date, calendar: Calendar = .current) -> Int { on(now, calendar).counts[action, default: 0] }

    /// The `n` most pressed today, most first, ties by name.
    public func top(_ n: Int, now: Date, calendar: Calendar = .current) -> [(action: String, count: Int)] {
        on(now, calendar).counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(n).map { ($0.key, $0.value) }
    }

    /// Presses in each hour, 0 to 23.
    public func hours(now: Date, calendar: Calendar = .current) -> [Int] { on(now, calendar).byHour }
}

/// Where the day's minute history and presses are saved: ~/Library/Application Support/Pilot/<name>.json.
public struct DayFile<Value: Codable & Sendable>: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public init(_ name: String) { url = PilotFolder.support.appending(path: "\(name).json") }

    /// `empty` when not saved yet; a file that does not decode throws, so no save wipes it.
    public func load(or empty: Value) throws -> Value { try JSONFile(url: url).load(or: empty) }
    public func save(_ value: Value) throws { try JSONFile(url: url).save(value) }
}
