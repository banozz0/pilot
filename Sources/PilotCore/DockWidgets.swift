import Foundation

/// The dock's widgets (design round 3, Sven 2026-11-13: Q214 B, label over value; Q215 the eleven; revenue left out). Each
/// reads one of Pilot's own readers or an extension's bar answer and draws as faces: a glyph beside a small capitals
/// label over a value. Saved by raw value in DockSettings.widgets, in Sven's order.
public enum DockWidget: String, CaseIterable, Codable, Sendable {
    case aiUsage = "ai-usage", nextEvent = "next-event", nowPlaying = "now-playing", focus, system, weather
    case todo, github, markets, timeline, battery

    /// On by default: the six round 3 rendered.
    public static let defaults: [DockWidget] = [.aiUsage, .nextEvent, .nowPlaying, .focus, .system, .weather]

    public var title: String {
        switch self {
        case .aiUsage: "AI usage"
        case .nextEvent: "Next event"
        case .nowPlaying: "Now playing"
        case .focus: "Focus timer"
        case .system: "System stats"
        case .weather: "Weather"
        case .todo: "To-dos"
        case .github: "GitHub"
        case .markets: "Stocks and crypto"
        case .timeline: "Day timeline"
        case .battery: "Battery"
        }
    }

    /// Its SF Symbol in Settings' list.
    public var symbol: String {
        switch self {
        case .aiUsage: "gauge.with.needle"
        case .nextEvent: "calendar"
        case .nowPlaying: "music.note"
        case .focus: "timer"
        case .system: "cpu"
        case .weather: "cloud.sun"
        case .todo: "checklist"
        case .github: "arrow.triangle.pull"
        case .markets: "chart.line.uptrend.xyaxis"
        case .timeline: "calendar.day.timeline.left"
        case .battery: "battery.75percent"
        }
    }

    /// What it reads, for Settings and `pilot dock`.
    public var reads: String {
        switch self {
        case .aiUsage, .nowPlaying, .weather, .todo, .github, .markets: "the \(extensionID ?? rawValue) extension's bar item"
        case .nextEvent, .timeline: "Calendar, as the clock reads it"
        case .focus: "Pilot's timer (the Pomodoro extension starts it)"
        case .system: "Pilot's CPU and memory readings"
        case .battery: "the Mac's battery, else its Bluetooth devices'"
        }
    }

    /// The catalogue extension it reads; the focus timer's is the one that starts a timer.
    public var extensionID: String? {
        switch self {
        case .aiUsage, .nowPlaying, .weather, .todo, .github, .markets: rawValue
        case .focus: "pomodoro"
        case .nextEvent, .timeline, .system, .battery: nil
        }
    }

    /// A name as `pilot dock-widgets` takes it: its raw value or its title, any case.
    public init?(name: String) {
        let word = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let found = Self.allCases.first(where: { $0.rawValue == word || $0.title.lowercased() == word }) else { return nil }
        self = found
    }

    /// A widget saved before round 3, by the bar tray's names (`extension:ai-usage`, `kind:timer`, …); nil for one with
    /// no widget now (the clock, a group).
    public static func legacy(_ name: String) -> DockWidget? {
        if let widget = DockWidget(rawValue: name) { return widget }
        switch name {
        case "extension:ai-usage": return .aiUsage
        case "extension:now-playing": return .nowPlaying
        case "extension:weather": return .weather
        case "extension:todo": return .todo
        case "extension:github": return .github
        case "extension:markets": return .markets
        case "kind:timer", "timer", "extension:pomodoro": return .focus
        case "kind:cpu", "kind:memory", "cpu", "memory": return .system
        case "kind:battery", "kind:bluetoothBatteries", "battery": return .battery
        default: return nil
        }
    }

    /// Look A's saved three before round 3: a list that is still exactly them reads as the new six (Sven picked those).
    static let lookADefaults = ["extension:ai-usage", "kind:timer", "extension:weather"]

    /// A saved list read now: the new names kept, the old ones mapped, each once, the rest dropped.
    public static func migrated(_ saved: [String]) -> [DockWidget] {
        if saved == lookADefaults { return defaults }
        var seen = Set<DockWidget>()
        return saved.compactMap(legacy).filter { seen.insert($0).inserted }
    }
}

/// One face of a widget: a glyph beside a small capitals label over a value (treatment B).
public struct DockFace: Equatable, Sendable {
    public enum Glyph: Equatable, Sendable {
        /// An SF Symbol, in its own colours where it has them (weather), else the ink.
        case symbol(String, multicolor: Bool = false)
        /// A provider's glyph in its brand colour (Claude, OpenAI), as the bar draws it with Item colours.
        case provider(Extension.Gauge.Icon)
        /// A calendar day as Calendar's icon draws one: the weekday small over the date.
        case day(weekday: String, date: String)
        /// A picture's bytes: now playing's artwork.
        case image(Data)
        /// A ring filled to its share: the focus timer's time left.
        case ring(Double)
    }

    public var glyph: Glyph
    public var label: String
    public var value: String
    public var tone: Extension.Tone?
    /// 0 to 1: the share a reading runs at, kept for the words `pilot dock` gives.
    public var meter: Double?

    public init(glyph: Glyph, label: String, value: String, tone: Extension.Tone? = nil, meter: Double? = nil) {
        self.glyph = glyph; self.label = label; self.value = value; self.tone = tone; self.meter = meter
    }

    /// "CLAUDE 72%": the face as `pilot dock` says it.
    public var words: String { "\(label.uppercased()) \(value)" }
}

/// The day timeline's wider face: today's timed events across the hours they span, now marked.
public struct DockTimeline: Equatable, Sendable {
    public struct Span: Equatable, Sendable {
        public var title: String, start: Double, end: Double, colour: Paint?
        public init(title: String, start: Double, end: Double, colour: Paint?) { self.title = title; self.start = start; self.end = end; self.colour = colour }
    }

    /// The hours drawn, as hours since midnight: 8 to 20, widened to every event and to now.
    public var from: Double, to: Double
    public var now: Double
    public var spans: [Span]
    public var label: String

    public init(from: Double, to: Double, now: Double, spans: [Span], label: String) {
        self.from = from; self.to = to; self.now = now; self.spans = spans; self.label = label
    }

    /// A share of the drawn hours, 0 to 1.
    public func at(_ hour: Double) -> Double { to > from ? min(max((hour - from) / (to - from), 0), 1) : 0 }
}

/// Why a widget shows Set up, and where its click goes.
public enum DockSetUp: Equatable, Sendable {
    /// Its extension is not installed: the catalogue.
    case install(String)
    /// Its extension answers with a problem or needs a setting (no GitHub sign-in, no tickers): its row in Extensions.
    case settings(String)
    /// Calendar was never asked: the click asks.
    case askCalendar
    /// Calendar was refused: Privacy & Security's Calendars pane.
    case calendarPrivacy
    /// No battery and no Bluetooth device with one: Bluetooth's settings.
    case bluetooth
}

/// What one widget draws now.
public enum DockWidgetBody: Equatable, Sendable {
    case faces([DockFace])
    case timeline(DockTimeline)
    case setUp(DockSetUp)
}

/// Each widget's faces from what its reader last gave: pure, so `pilot dock` and the renders go through the same mapping
/// the dock draws.
public enum DockFaces {
    /// AI usage: one face per gauge, its provider's glyph and name over the share left (the OpenAI gauge is Codex's).
    public static func aiUsage(_ answer: Extension.BarAnswer) -> [DockFace] {
        guard !answer.gauges.isEmpty else { return [DockFace(glyph: .symbol("gauge.with.needle"), label: "AI usage", value: plain(answer.text), tone: answer.tone)] }
        return answer.gauges.map { g in
            let share = Double(g.text.filter(\.isNumber)).map { $0 / 100 }
            let label = !g.label.isEmpty ? g.label : g.icon == .openai ? "Codex" : g.icon?.title ?? "AI"
            return DockFace(glyph: g.icon.map(DockFace.Glyph.provider) ?? .symbol("gauge.with.needle"), label: label, value: g.text, tone: g.tone, meter: share)
        }
    }

    /// Now playing: the track row its bar answer carries (round 3: with its artwork), the artist over the title; the
    /// app's name while paused.
    public static func nowPlaying(_ answer: Extension.BarAnswer) -> DockFace? {
        guard let row = rows(answer.blocks).first else { return nil }
        let paused = answer.text.trimmingCharacters(in: .whitespaces) == "♫"
        let label = paused ? "Paused" : row.subtitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Now playing"
        return DockFace(glyph: row.image.map(DockFace.Glyph.image) ?? .symbol("music.note"), label: label, value: row.title)
    }

    /// Weather: its bar text's emoji as a symbol in its own colours and the condition's word, over the temperature.
    public static func weather(_ answer: Extension.BarAnswer) -> DockFace {
        let text = answer.text.trimmingCharacters(in: .whitespaces)
        // By its first scalar: the extension's ☀️ carries a variation selector the table's keys leave out.
        let emoji = text.unicodeScalars.first.map { String($0) } ?? ""
        let (symbol, word) = weatherGlyphs[emoji] ?? ("thermometer.medium", "Weather")
        return DockFace(glyph: .symbol(symbol, multicolor: true), label: word, value: plain(text), tone: answer.tone)
    }

    /// The weather extension's emoji (its CODES), each an SF Symbol and a word.
    static let weatherGlyphs: [String: (String, String)] = [
        "☀": ("sun.max.fill", "Clear"), "🌤": ("sun.max.fill", "Mainly clear"), "⛅": ("cloud.sun.fill", "Partly cloudy"),
        "☁": ("cloud.fill", "Cloudy"), "🌫": ("cloud.fog.fill", "Fog"), "🌦": ("cloud.sun.rain.fill", "Showers"),
        "🌧": ("cloud.rain.fill", "Rain"), "🌨": ("cloud.snow.fill", "Snow"), "❄": ("snowflake", "Snow"),
        "⛈": ("cloud.bolt.rain.fill", "Storm"), "🌙": ("moon.stars.fill", "Clear"),
    ]

    /// To-dos: its "☑️ 3 · 1" as the count open, and the ones due today or overdue in its label (amber).
    public static func todo(_ answer: Extension.BarAnswer) -> DockFace {
        let numbers = plain(answer.text).split(separator: "·").map { Int($0.filter(\.isNumber)) ?? 0 }
        let open = numbers.first ?? 0, due = numbers.count > 1 ? numbers[1] : 0
        return DockFace(glyph: .symbol("checklist"), label: due > 0 ? "\(due) due today" : "To-dos", value: open == 0 ? "All done" : "\(open) open",
                        tone: due > 0 ? .warn : nil)
    }

    /// GitHub: red CI or reviews waiting, in their tones; quiet, all clear.
    public static func github(_ answer: Extension.BarAnswer) -> DockFace {
        let text = plain(answer.text)
        return DockFace(glyph: .symbol("arrow.triangle.pull"), label: "GitHub", value: text.isEmpty ? "All clear" : text, tone: answer.tone)
    }

    /// Markets: a face per symbol it follows, at most two: its bar gauges where it sends them, else its rows' symbol over
    /// the price, the change's badge giving the tone. Nil with no symbols (Set up).
    public static func markets(_ answer: Extension.BarAnswer) -> [DockFace]? {
        if !answer.gauges.isEmpty {
            return answer.gauges.prefix(2).map { DockFace(glyph: .symbol("chart.line.uptrend.xyaxis"), label: $0.label.isEmpty ? "Markets" : $0.label, value: $0.text, tone: $0.tone) }
        }
        let found = rows(answer.blocks).prefix(2)
        guard !found.isEmpty else { return nil }
        return found.map { row in
            let parts = row.title.components(separatedBy: " · ")
            let change = row.badges.first
            return DockFace(glyph: .symbol(change?.tone == .alert ? "chart.line.downtrend.xyaxis" : "chart.line.uptrend.xyaxis"),
                            label: parts.first ?? row.title, value: parts.count > 1 ? parts[1] : change?.text ?? "–", tone: change?.tone)
        }
    }

    /// The focus timer: a ring of the time left beside its title over the countdown; with none running, Focus over Start.
    public static func focus(countdown: String?, left: Double?, title: String?, paused: Bool) -> DockFace {
        guard let countdown else { return DockFace(glyph: .ring(0), label: "Focus", value: "Start") }
        return DockFace(glyph: .ring(left ?? 0), label: paused ? "Paused" : title.flatMap { $0.isEmpty ? nil : $0 } ?? "Focus", value: countdown)
    }

    /// System stats: CPU and memory, each over its share, amber or red as hard as it runs.
    public static func system(_ values: SystemStats.Values?, raw: SystemStats.Raw?) -> [DockFace] {
        [(MenuBarStats.Stat.cpu, "cpu", "CPU"), (.ram, "memorychip", "Memory")].map { stat, symbol, label in
            DockFace(glyph: .symbol(symbol), label: label, value: MenuBarStats.value(stat, values: values, raw: raw) ?? "–",
                     tone: tone(MenuBarStats.level(stat, values: values, raw: raw)), meter: MenuBarStats.share(stat, values: values, raw: raw))
        }
    }

    /// Battery: the Mac's own, charging or not; on a Mac with none, the Bluetooth devices' (two at most, lowest first).
    /// Nil with neither (Set up).
    public static func battery(_ battery: SystemStats.Battery?, bluetooth: [SystemStats.BluetoothDevice]) -> [DockFace]? {
        if let battery {
            let level = MenuBarStats.level(battery)
            return [DockFace(glyph: .symbol(battery.charging ? "battery.100percent.bolt" : batterySymbol(battery.percent)),
                             label: battery.charging ? "Charging" : "Battery", value: "\(battery.percent)%", tone: tone(level),
                             meter: Double(battery.percent) / 100)]
        }
        let devices = bluetooth.filter { $0.percent != nil }.sorted { ($0.percent ?? 0) < ($1.percent ?? 0) }.prefix(2)
        guard !devices.isEmpty else { return nil }
        return devices.map { device in
            let percent = device.percent ?? 0
            return DockFace(glyph: .symbol(deviceSymbol(device.name)), label: device.name, value: "\(percent)%",
                            tone: tone(MenuBarStats.level(percent: percent)), meter: Double(percent) / 100)
        }
    }

    static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    static func deviceSymbol(_ name: String) -> String {
        let word = name.lowercased()
        if word.contains("airpods") || word.contains("buds") || word.contains("beats") { return "airpods" }
        if word.contains("mouse") { return "magicmouse.fill" }
        if word.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if word.contains("keyboard") { return "keyboard.fill" }
        return "battery.75percent"
    }

    /// The events a widget counts: timed ones (no all-day, no holidays), by start.
    public static func timed(_ events: [ClockEvent]) -> [ClockEvent] {
        events.filter { !$0.allDay && !$0.holiday && $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    /// Next event: the one on now ("Now · until 15:30"), else the next today ("In 25 min", "At 16:00"), over its title, beside
    /// today's day; with none left, Today over Nothing left.
    public static func nextEvent(_ events: [ClockEvent], now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> DockFace {
        let weekday = now.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)).uppercased()
        let glyph = DockFace.Glyph.day(weekday: weekday, date: String(calendar.component(.day, from: now)))
        let endOfDay = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        let clock = { (date: Date) in date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour(.twoDigits(amPM: .omitted)).minute()) }
        let left = timed(events).filter { $0.end > now && $0.start < endOfDay }
        guard let next = left.first else { return DockFace(glyph: glyph, label: "Today", value: "Nothing left") }
        let title = next.title.isEmpty ? "Event" : next.title
        if next.start <= now { return DockFace(glyph: glyph, label: "Now · until \(clock(next.end))", value: title, tone: .warn) }
        let minutes = Int((next.start.timeIntervalSince(now) / 60).rounded(.up))
        let label = minutes < 60 ? "In \(minutes) min" : "At \(clock(next.start))"
        return DockFace(glyph: glyph, label: label, value: title, tone: minutes <= 10 ? .warn : nil)
    }

    /// Day timeline: today's timed events from 8 to 20 (wider for any outside it), now marked; its label the count left.
    public static func timeline(_ events: [ClockEvent], now: Date, calendar: Calendar = .autoupdatingCurrent) -> DockTimeline {
        let midnight = calendar.startOfDay(for: now)
        let hour = { (date: Date) in min(max(date.timeIntervalSince(midnight) / 3600, 0), 24) }
        let today = timed(events).filter { $0.end > midnight && $0.start < midnight.addingTimeInterval(86_400) }
        let spans = today.map { DockTimeline.Span(title: $0.title, start: hour($0.start), end: hour($0.end), colour: $0.colour) }
        let at = hour(now)
        let from = ([8, at - 1] + spans.map(\.start)).min().map { max(0, $0.rounded(.down)) } ?? 8
        let to = ([20, at + 1] + spans.map(\.end)).max().map { min(24, $0.rounded(.up)) } ?? 20
        let left = today.filter { $0.end > now }.count
        return DockTimeline(from: from, to: to, now: at, spans: spans, label: left == 0 ? "Today · clear" : left == 1 ? "Today · 1 left" : "Today · \(left) left")
    }

    /// A reading's level as a face's tone.
    static func tone(_ level: MenuBarStats.Level) -> Extension.Tone? {
        switch level {
        case .normal: nil
        case .high: .warn
        case .critical: .alert
        }
    }

    /// A bar text without its leading emoji or symbol: "☀️ 24°" is "24°".
    public static func plain(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first, !first.properties.isAlphabetic, !CharacterSet.decimalDigits.contains(first),
              let space = trimmed.firstIndex(of: " ") else { return trimmed }
        return String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Every list row in `blocks`, a section's included.
    static func rows(_ blocks: [Extension.Block]) -> [Extension.Item] {
        blocks.flatMap { block -> [Extension.Item] in
            switch block {
            case .list(_, let items, _): items
            case .section(_, _, _, _, let inner, _, _): rows(inner)
            default: []
            }
        }
    }
}
