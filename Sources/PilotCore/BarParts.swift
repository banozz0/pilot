import Foundation

/// What a bar item draws, part by part, the same in the macOS menu bar (a template picture) and the top bar (SwiftUI)
/// (card agent-bo-95422911, design round 4 section 6 and round 3's item styles). Pure: the readings come in as BarInputs,
/// so every item and style is testable without a Mac's readings.
public enum BarPart: Equatable, Sendable {
    /// A word beside a value: a second zone's city.
    case label(String)
    /// A reading's name beside its value: the macOS menu bar draws its few letters ("CPU"), the top bar's Strip its
    /// glyph (card agent-bo-95423013).
    case reading(MenuBarStats.Stat)
    /// A value, held to the width of `widest` so the item never jumps as numbers change.
    case value(String, widest: String? = nil)
    /// Plain text: a second zone's time, a layout's name, an output.
    case text(String)
    /// The clock's date, its own hit target: a click opens Calendar (card agent-bo-95423011).
    case date(String)
    /// The clock's time here, marked with the accent chip.
    case time(String)
    /// A mini graph's points, oldest first, each 0 to 1.
    case graph([Double])
    /// A meter filled to its share, 0 to 1.
    case bar(Double)
    /// An SF Symbol.
    case symbol(String)
    /// Pilot's own mark, the app icon's four boxes, drawn in the bar's one colour.
    case mark
    /// The timer's ring, the share of its time left.
    case ring(Double)
    /// A number or code in a small filled box: the Pilot number, the current workspace, a layout's code.
    case badge(String)
    /// The workspaces, the current one marked; `app` follows the current one's number in the with-app style.
    case workspaces([String], current: String?, app: String?)
    /// One dot per workspace, the current one solid.
    case dots(count: Int, current: Int?)
    /// The frontmost app's icon, and its name when shown.
    case app(name: String, showsName: Bool)
    /// Wi-Fi's strength in four bars.
    case strength(Int)
    /// Room between items, in points.
    case space(Double)
    case divider
    /// The reading is past its threshold (MenuBarStats.warns): the item draws amber.
    case warn
    /// How hard the reading runs (MenuBarStats.level), high or critical only: with Item colours on, the top bar draws it
    /// amber or red; otherwise nothing.
    case level(MenuBarStats.Level)
    /// One extension's bar item (Surfaces v2): its gauges, then its text; its own hit target, a click opens its popover.
    case extensionItem(ExtensionBarFace)
}

/// What one extension's bar item draws (Surfaces v2): its gauges and short text in their tones, named by its extension.
public struct ExtensionBarFace: Equatable, Sendable {
    public let id: String, title: String, text: String, gauges: [Extension.Gauge], tone: Extension.Tone?

    public init(id: String, title: String, answer: Extension.BarAnswer) {
        self.id = id; self.title = title; text = answer.text; gauges = answer.gauges; tone = answer.tone
    }
}

/// Every reading a bar item can draw from, as the app gathers them (BarSources); a field left nil is a reading this Mac
/// lacks or has not read yet.
public struct BarInputs: Sendable {
    public var pilotTitle = "–"
    /// Accessibility is not granted: Pilot's icon is a warning until it is.
    public var pilotAlert = false
    /// The share of onboarding's Extras downloaded while they run (Sven, 2026-10-28, Q543): Pilot's icon adds a meter.
    public var pilotDownload: Double?
    public var workspaces: [String] = []
    public var focusedWorkspace: String?
    /// Each workspace's first app, for the with-app style.
    public var firstApp: [String: String] = [:]
    public var focusedApp: String?
    public var latest: SystemStats.Raw?
    public var values: SystemStats.Values?
    public var history: [SystemStats.Values] = []
    public var battery: SystemStats.Battery?
    /// The whole Mac's draw in watts, on a Mac with no battery (BarReadings).
    public var watts: Int?
    public var bluetooth: [SystemStats.BluetoothDevice] = []
    /// Bluetooth's radio, read for its item's menu alone; nil hides the switch (Pilot cannot switch it, or not allowed yet).
    public var bluetoothOn: Bool?
    public var keepAwake = false
    /// What is left of Keep awake; nil while off or on until turned off.
    public var keepAwakeLeft: TimeInterval?
    public var volume: Float?
    public var muted: Bool?
    public var output: String?
    /// The output devices by name, for Volume's Output menu.
    public var outputs: [String] = []
    public var keyboardLayout: String?
    public var wifiOn: Bool?
    /// The Wi-Fi link's signal in dBm; nil when not joined.
    public var wifiSignal: Int?
    public var now = Date()
    public var timeZone = TimeZone.autoupdatingCurrent
    public var locale = Locale.autoupdatingCurrent
    /// The extension timer's time left, its share left and its title; nil with none.
    public var timerCountdown: String?
    public var timerLeft: Double?
    public var timerTitle: String?
    /// The extensions' bar items with something to show, placed in the bar being drawn (ExtensionBar, story 161).
    public var extensionBars: [ExtensionBarFace] = []
    /// The Status lights item's lit sources (StatusLights): agents, privacy, jobs.
    public var statusLights: [StatusLight] = []
    /// The recorder, as Capture draws it; nil while it is idle.
    public var recording: BarRecording?
    /// The registered actions Capture's menu runs, each with its key as the dropdown signs it (nil with none), read for its
    /// menu alone.
    public var actions: [String: String?] = [:]
    /// Every registered capture action's label by id, so one Capture's menu does not name (a new capture type) still
    /// gets its row.
    public var actionLabels: [String: String] = [:]

    public init() {}
}

/// Pilot's recorder as Capture's item draws it (Recorder.phase), the time in seconds with pauses left out.
public enum BarRecording: Equatable, Sendable {
    case starting, counting(Int), recording(Double), paused(Double)

    /// "Recording in 3", "Recording · 2:14", "Recording paused · 2:14": the bar's tooltip and the dropdown's Now say it so.
    public var words: String {
        switch self {
        case .starting: "Recording is starting"
        case .counting(let n): "Recording in \(n)"
        case .recording(let seconds): "Recording · \(RecordingClock.label(seconds))"
        case .paused(let seconds): "Recording paused · \(RecordingClock.label(seconds))"
        }
    }
}

/// One hit target of an item: the parts it draws and what a click on them does.
public struct BarTarget: Equatable, Sendable {
    public var parts: [[BarPart]]
    public var click: BarClick

    public init(parts: [[BarPart]], click: BarClick) {
        self.parts = parts
        self.click = click
    }
}

extension BarPart {
    /// A part with a click of its own, apart from its item's: an extension's own item opens its popover. The clock's date
    /// and time are one target, its popover (SPEC story 168).
    public var click: BarClick? {
        if case .extensionItem(let face) = self { return .extension(face.id) }
        return nil
    }
}

public enum BarParts {
    /// An item's parts in its style; nil hides it (a battery on a Mac with none, a reading not on this Mac, no app in
    /// front). Other apps are drawn by the top bar's own view; the Group draws as `group`.
    public static func parts(_ entry: BarEntry, _ i: BarInputs, clock: TopBarClockFormat = .time24, zone: String? = nil) -> [BarPart]? {
        let style = entry.style
        switch entry.kind {
        case .cpu, .memory, .network, .graphics, .storage, .heat: return entry.kind.stat.flatMap { reading($0, style: style, i) }
        case .pilot:
            if i.pilotAlert { return [.symbol("exclamationmark.triangle")] }
            let base: [BarPart] = switch style {
            case .icon: [.mark]
            case .number: [.badge(i.pilotTitle)]
            default: [.mark, .value(i.pilotTitle)]
            }
            // To a twentieth, so the item redraws at most twenty times over a download.
            return base + (i.pilotDownload.map { [.bar(($0 * 20).rounded(.down) / 20)] } ?? [])
        case .workspaces:
            guard !i.workspaces.isEmpty || i.focusedWorkspace != nil else { return nil }
            let names = workspaceNames(i)
            switch style {
            case .dots: return [.dots(count: names.count, current: i.focusedWorkspace.flatMap(names.firstIndex))]
            case .current: return i.focusedWorkspace.map { [.badge($0)] }
            case .withApp: return [.workspaces(names, current: i.focusedWorkspace, app: i.focusedWorkspace.flatMap { i.firstApp[$0] })]
            default: return [.workspaces(names, current: i.focusedWorkspace, app: nil)]
            }
        case .focusedApp:
            return TopBarText.focusedApp(i.focusedApp).map { [.app(name: $0, showsName: style == .iconName)] }
        case .battery:
            guard let battery = i.battery else {
                // A Mac with no battery (a Mac mini) shows the watts it draws instead.
                guard let watts = i.watts else { return nil }
                return style == .icon ? [.symbol("bolt")] : [.symbol("bolt"), .value("\(watts) W", widest: "000 W")]
            }
            // SF Symbols has the bolt only on the full battery.
            let symbol = battery.charging ? "battery.100.bolt" : TopBarText.batterySymbol(battery)
            let parts: [BarPart] = style == .icon ? [.symbol(symbol)] : [.symbol(symbol), .value("\(battery.percent)%", widest: "100%")]
            return parts + (MenuBarStats.warns(battery) ? [.warn] : []) + marker(MenuBarStats.level(battery))
        case .bluetoothBatteries:
            // The lowest battery first: the one that needs charging.
            guard let device = i.bluetooth.min(by: { level($0) < level($1) }) else { return nil }
            let parts: [BarPart] = style == .icon ? [.symbol(bluetoothSymbol)] : [.symbol(bluetoothSymbol), .value(device.shortLevel)]
            // Low as the battery item is: the warning at 20 %, amber then red with Item colours.
            let low = MenuBarStats.level(percent: level(device))
            return parts + (low == .normal ? [] : [.warn]) + marker(low)
        case .keepAwake:
            let symbol = i.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer"
            guard style == .iconTime, i.keepAwake else { return [.symbol(symbol)] }
            return [.symbol(symbol), .value(i.keepAwakeLeft.map(duration) ?? "∞")]
        case .power: return [.symbol("power")]
        case .displays: return [.symbol("display")]
        case .volume:
            let symbol = i.muted == true ? "speaker.slash" : "speaker.wave.2"
            switch style {
            case .iconPercent: return [.symbol(symbol), .value(TopBarText.volume(i.volume, muted: i.muted), widest: "100 %")]
            case .output: return [.symbol(symbol)] + (i.output.map { [.text($0)] } ?? [])
            default: return [.symbol(symbol)]
            }
        case .keyboardLayout:
            switch style {
            case .icon: return [.symbol("keyboard")]
            case .name: return [.text(i.keyboardLayout ?? "–")]
            default: return [.badge(TopBarText.inputSource(i.keyboardLayout, style: .code))]
            }
        case .wifi:
            guard i.wifiOn == true else { return [.symbol("wifi.slash")] }
            guard style == .strength, let signal = i.wifiSignal else { return [.symbol("wifi")] }
            return [.symbol("wifi"), .strength(wifiBars(signal))]
        case .clock:
            let here = BarPart.time(clock.text(i.now, timeZone: i.timeZone, locale: i.locale))
            if style == .dateTime { return [.date(TopBarClockFormat.date.text(i.now, timeZone: i.timeZone, locale: i.locale)), here] }
            guard style == .twoZones, let zone = zone.flatMap(TimeZone.init(identifier:)) else { return [here] }
            return [here, .label(city(zone)), .text(clock.text(i.now, timeZone: zone, locale: i.locale))]
        case .timer:
            guard let countdown = i.timerCountdown, style != .icon else { return [.symbol("timer")] }
            // To a sixtieth: finer than a 12-point ring shows, and each finer step would redraw the item.
            let ring = BarPart.ring(((i.timerLeft ?? 0) * 60).rounded() / 60)
            return style == .ring ? [ring] : [ring, .value(countdown, widest: countdown.count > 5 ? "8:88:88" : "88:88")]
        case .extensions:
            // An extension's own slot draws its own item (spec pilot-1.1 T50); the old Extensions slot, every one, each its
            // own target, apart by the top bar's insets. Nothing to show hides it.
            let faces = entry.extensionID.map { id in i.extensionBars.filter { $0.id == id } } ?? i.extensionBars
            guard !faces.isEmpty else { return nil }
            return faces.map(BarPart.extensionItem)
        // The top bar draws the dots itself (TopBarStatusLights); elsewhere (the drag's chip), the item's symbol.
        case .modes: return [.symbol(statusSymbol)]
        case .capture: return capture(i.recording, style: style)
        case .terminal, .askAI, .pill:
            // What the Menu bar page's strip and the drag's chip draw; the top bar draws its own lit item (TopBarDropItem).
            let symbol = BarPart.symbol(dropSymbol(entry.kind))
            return style == .icon ? [symbol] : [symbol, .text(entry.kind.title.uppercased())]
        case .spacer: return [.space(BarSpacer.width(entry))]
        case .divider: return [.divider]
        case .otherApps, .appMenus, .group: return nil
        }
    }

    /// The parts' words alone, two spaces apart, as the clock reads in a line of text: "Sun 18 Oct  13:27".
    public static func text(_ parts: [BarPart]) -> String {
        parts.compactMap { part -> String? in
            switch part {
            case .date(let s), .time(let s), .label(let s), .text(let s): s
            default: nil
            }
        }.joined(separator: "  ")
    }

    /// Capture's parts: its camera, named in icon + name; while a recording runs, its time in place of the red-dot
    /// control (Sven, 2026-10-16), the count before it, and the pause glyph while paused.
    static func capture(_ recording: BarRecording?, style: BarStyle) -> [BarPart] {
        let time = { (seconds: Double) in BarPart.value(RecordingClock.label(seconds), widest: seconds >= 3600 ? "8:88:88" : "88:88") }
        switch recording {
        case nil: return style == .iconName ? [.symbol(captureSymbol), .text(BarKind.capture.title)] : [.symbol(captureSymbol)]
        case .starting: return [.symbol("record.circle")]
        case .counting(let n): return [.symbol("record.circle"), .value("\(n)")]
        case .recording(let seconds): return [.symbol("record.circle.fill"), time(seconds)]
        case .paused(let seconds): return [.symbol("pause.circle"), time(seconds)]
        }
    }

    /// Capture's camera, the Captures page's own.
    public static let captureSymbol = AppPage.captures.symbol
    /// Status lights' symbol where its dots are not drawn: the Menu bar page's list and the drag's chip.
    public static let statusSymbol = "smallcircle.circle"

    /// The Group's parts: each reading in its own style, side by side; nil when none has a reading.
    public static func group(_ entries: [BarEntry], _ i: BarInputs) -> [[BarPart]]? {
        let readings = entries.compactMap { parts($0, i) }
        return readings.isEmpty ? nil : readings
    }

    /// A reading: its label and its value, mini graph or meter; nil for one this Mac lacks.
    static func reading(_ stat: MenuBarStats.Stat, style: BarStyle, _ i: BarInputs) -> [BarPart]? {
        guard let value = MenuBarStats.value(stat, values: i.values, raw: i.latest) else { return nil }
        let parts: [BarPart] = switch style {
        // Points to what a 12-point line can show, so a still graph is the same picture tick to tick and never redrawn.
        case .graph where stat.graphable: [.reading(stat), .graph(MenuBarStats.graph(stat, history: i.history).map { ($0 * 28).rounded() / 28 })]
        case .bar: [.reading(stat), .bar(MenuBarStats.share(stat, values: i.values, raw: i.latest) ?? 0)]
        default: [.reading(stat), .value(value, widest: MenuBarStats.widest(stat))]
        }
        return parts + (MenuBarStats.warns(stat, values: i.values, raw: i.latest) ? [.warn] : []) + marker(MenuBarStats.level(stat, values: i.values, raw: i.latest))
    }

    /// A level's marker part: none while normal.
    static func marker(_ level: MenuBarStats.Level) -> [BarPart] { level == .normal ? [] : [.level(level)] }

    /// The workspaces to show: the tiler's occupied ones and the focused one, in its order.
    static func workspaceNames(_ i: BarInputs) -> [String] {
        TopBarWorkspaces.items(occupied: i.workspaces, focused: i.focusedWorkspace, visibleHere: nil).map(\.name)
    }

    /// A workspace's label: its number, and its first app in the with-app style.
    public static func workspaceLabel(_ name: String, app: String?) -> String { app.map { "\(name) · \($0)" } ?? name }

    /// Wi-Fi's four bars, shortest first, in points.
    public static let strengthHeights: [Double] = [4, 7, 10, 12]

    /// An item's hit targets: each run of parts with the same click, a part's own click (BarPart.click) or else the item's
    /// `click`, in order; a group is one target.
    public static func targets(_ items: [[BarPart]], click: BarClick) -> [BarTarget] {
        guard items.count == 1 else { return [BarTarget(parts: items, click: click)] }
        var targets: [BarTarget] = []
        for part in items[0] {
            let partClick = part.click ?? click
            if targets.last?.click == partClick { targets[targets.count - 1].parts[0].append(part) }
            else { targets.append(BarTarget(parts: [[part]], click: partClick)) }
        }
        return targets
    }

    /// A hit target and the items its click is for.
    public typealias KindTarget = (target: BarTarget, kinds: [BarKind])

    /// The Group's hit targets (Sven on build 2372: a group holds any groupable item): each run of its readings one
    /// target opening their popover together, as the Group's click did, every other item its own targets with its own
    /// click, each with the items its click is for.
    public static func groupTargets(_ entries: [BarEntry], _ i: BarInputs) -> [KindTarget] {
        var targets: [KindTarget] = []
        for entry in entries {
            guard let parts = parts(entry, i) else { continue }
            guard entry.kind.group == .readings else {
                targets += Self.targets([parts], click: entry.kind.click).map { ($0, [entry.kind]) }
                continue
            }
            if let last = targets.last, last.kinds.allSatisfy({ $0.group == .readings }) {
                targets[targets.count - 1].target.parts.append(parts)
                targets[targets.count - 1].kinds.append(entry.kind)
            } else {
                targets.append((BarTarget(parts: [parts], click: .popover), [entry.kind]))
            }
        }
        return targets
    }

    /// The second zone's name as round 3 labels it, its city ("New York"); macOS's abbreviation reads "GMT-4" in most
    /// languages.
    public static func city(_ zone: TimeZone) -> String {
        zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
    }

    /// Four bars from the signal, as macOS's own Wi-Fi menu steps it: -50 dBm or better is full.
    public static func wifiBars(_ signal: Int) -> Int {
        signal >= -50 ? 4 : signal >= -60 ? 3 : signal >= -70 ? 2 : 1
    }

    /// "1h", "3h 20m", "12m": what is left of Keep awake.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up)), h = minutes / 60, m = minutes % 60
        return h == 0 ? "\(m)m" : m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    static func level(_ device: SystemStats.BluetoothDevice) -> Int { device.percent ?? 100 }

    /// A bar drop's glyph, the C frames' `>_` and `✦`.
    public static func dropSymbol(_ kind: BarKind) -> String {
        switch kind {
        case .askAI: "sparkle"
        case .pill: "capsule"
        default: "apple.terminal"
        }
    }

    /// Bluetooth's logo is Apple's to draw only in its own menu; Pilot shows what the battery is in.
    static let bluetoothSymbol = "headphones"
}

/// Which apps record from the microphone (CoreAudio's processes running input) and whether the input is muted at the
/// device; an app's own mute (Zoom's, Meet's) is not visible to other apps, so it reads as recording.
public struct MicState: Equatable, Sendable {
    public var apps: [String]
    public var muted: Bool
    public init(apps: [String] = [], muted: Bool = false) { self.apps = apps; self.muted = muted }
}

extension BarParts {
    /// A slot's parts, one list per item drawn in it (the group's readings each their own); nil draws nothing.
    public static func parts(_ slot: BarSlot, _ i: BarInputs, settings: BarSettings) -> [[BarPart]]? {
        switch slot {
        case .item(let entry): parts(entry, i, clock: settings.clock, zone: settings.clockZone).map { [$0] }
        case .group(let entries): group(entries, i)
        }
    }
}

extension SystemStats.BluetoothDevice {
    /// Its battery as the bars show it: "72%".
    public var shortLevel: String { level.replacingOccurrences(of: " %", with: "%") }
}

extension ExtensionBarFace {
    /// Its tooltip: the extension's title, then its text, then each gauge as "C 34% · 25%" or "Claude 66%".
    public var tooltip: String {
        ([title, text] + gauges.map(\.words)).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
