import Foundation

/// What a bar item's right-click menu does (card agent-bo-95423010, design JJPiA9o30SA version 1, the right-click shot):
/// its own actions first, then its style, then where it sits in the bar.
public enum BarAction: Equatable, Sendable {
    /// The item's click, named in its menu: Mute, Next layout, Show CPU.
    case click(BarClick)
    case workspace(next: Bool)
    /// Sound out of this output device, by name.
    case output(String)
    /// A System Settings pane, by its id.
    case settings(String)
    case activityMonitor
    /// A change to the bar's settings (BarSettings.apply).
    case edit(BarEdit)
    /// A registered action, by its id: Capture's rows run the capture actions.
    case run(String)
    /// A page of Pilot's window: Edit bar's the Menu bar page, where the bar is dragged (Q185; the on-bar edit mode is
    /// parked).
    case page(AppPage)
}

/// The menu's changes to the bar: a style, a side (last on that side), off.
public enum BarEdit: Equatable, Sendable {
    case style(BarStyle)
    case move(TopBarSide)
    case remove
}

/// One row of the menu, drawn as a native NSMenu; `hint` is the other way to do it, greyed at the right.
public enum BarMenuRow: Equatable, Sendable {
    case action(String, BarAction, checked: Bool = false, hint: String? = nil)
    case header(String)
    case submenu(String, [BarMenuRow])
    case separator
}

extension BarEntry {
    /// The right-click menu: its actions, its styles when it has more than one, Move to (the top bar's sides; the macOS
    /// menu bar has none), Remove from bar (neither on Pilot, which is pinned first on the left) and Edit bar, which opens
    /// the Menu bar page.
    public func menu(_ i: BarInputs, in place: BarPlace) -> [BarMenuRow] {
        let styles: [BarMenuRow] = kind.styles.count < 2 ? []
            : [.header("Style")] + kind.styles.map { .action($0.menuTitle, .edit(.style($0)), checked: $0 == style) }
        var bar: [BarMenuRow] = []
        if place == .topBar, !kind.pinned { bar.append(.submenu("Move to", TopBarSide.allCases.map { .action($0.rawValue.capitalized, .edit(.move($0)), checked: $0 == side) })) }
        if !kind.pinned { bar.append(.action("Remove from bar", .edit(.remove))) }
        bar.append(.action("Edit bar…", .page(.menuBar)))
        return Array([kind.actions(i, scrolls: place == .topBar), styles, bar].filter { !$0.isEmpty }.joined(separator: [.separator]))
    }
}

extension BarKind {
    /// Its own actions: its click by name, then what else it does; scroll is named only where it works, the top bar.
    public func actions(_ i: BarInputs, scrolls: Bool) -> [BarMenuRow] {
        let scroll = scrolls ? "scroll" : nil
        let clicked: BarMenuRow? = switch click {
        case .popover: .action("Show \(title)", .click(.popover), hint: "click")
        case .toggleKeepAwake: .action(i.keepAwake ? "Let the Mac sleep" : "Keep awake", .click(.toggleKeepAwake), hint: "click")
        // No item's click mutes now: Volume's Option-click does, its row below.
        case .toggleMute, .cycleLayout, .none, .extension, .menu: nil
        }
        let settings = { (name: String, pane: String) in BarMenuRow.action("\(name) settings…", .settings(pane)) }
        let more: [BarMenuRow] = switch self {
        case .workspaces: [.action("Next workspace", .workspace(next: true), hint: scroll), .action("Previous workspace", .workspace(next: false), hint: scroll)]
        case .cpu, .memory, .network, .graphics, .storage, .heat: [.action("Open Activity Monitor", .activityMonitor)]
        case .volume:
            [.action(i.muted == true ? "Unmute" : "Mute", .click(.toggleMute), hint: "⌥ click")]
                + (i.outputs.isEmpty ? [] : [.submenu("Output", i.outputs.map { .action($0, .output($0), checked: $0 == i.output) })])
                + [settings("Sound", "com.apple.Sound-Settings.extension")]
        case .keyboardLayout: [.action("Next layout", .click(.cycleLayout)), settings("Keyboard", "com.apple.Keyboard-Settings.extension")]
        // One pane, titled Energy on a Mac with no battery.
        case .battery: [settings(SystemStats.hasBattery ? "Battery" : "Energy", "com.apple.Battery-Settings.extension")]
        case .bluetoothBatteries: [settings("Bluetooth", "com.apple.BluetoothSettings")]
        case .wifi: [settings("Wi-Fi", "com.apple.wifi-settings-extension")]
        case .displays: [settings("Displays", "com.apple.Displays-Settings.extension")]
        case .clock: [settings("Date & Time", "com.apple.Date-Time-Settings.extension")]
        case .capture: Self.captureMenu(i)
        default: []
        }
        return (clicked.map { [$0] } ?? []) + more
    }

    /// Capture's menu, its click's and atop its right-click's (Sven, 2026-10-16; P69, as Snapzy's): a
    /// recording's Stop with its time and Pause or Resume first, then every capture, Record screen while none runs, the
    /// capture tools, the history and the settings. Each row runs its registered action, its key greyed at the right; a
    /// row whose action is not registered is left out, so Open history, Edit video and Combine images show once they
    /// exist. A capture action this list does not name (a new capture type) joins the captures under its own label.
    static func captureMenu(_ i: BarInputs) -> [BarMenuRow] {
        let row = { (title: String, id: String) -> BarMenuRow? in i.actions[id].map { .action(title, .run(id), hint: $0) } }
        let recording: [BarMenuRow?] = switch i.recording {
        case nil: []
        case .starting, .counting: [row("Cancel recording", record)]
        case .recording(let seconds): [row("Stop recording (\(RecordingClock.label(seconds)))", record), row("Pause recording", pause)]
        case .paused(let seconds): [row("Stop recording (\(RecordingClock.label(seconds)))", record), row("Resume recording", pause)]
        }
        let named = Set((captureGrabs + captureTools).map(\.1) + [record, pause] + captureLeftOut)
        let others = i.actionLabels.filter { !named.contains($0.key) }.sorted { $0.value < $1.value }.map { row($0.value, $0.key) }
        let history: BarMenuRow? = i.actions[historyID] == nil ? .action("Capture history…", .page(.captures)) : nil
        let sections: [[BarMenuRow?]] = [
            recording,
            captureGrabs.map(row) + others,
            i.recording == nil ? [row("Record screen", record)] : [],
            captureTools.map(row) + [history, .action("Captures settings…", .page(.captures))],
        ]
        return Array(sections.map { $0.compactMap { $0 } }.filter { !$0.isEmpty }.joined(separator: [.separator]))
    }

    static let captureGrabs = [("Capture area", "captures.area"), ("Capture window", "captures.activeWindow"),
                               ("Capture screen", "captures.fullscreen"), ("Scrolling capture", "captures.scrolling"),
                               ("Scrolling capture, upward", "captures.scrollingUp"), ("Capture text", "captures.ocr"),
                               ("Read QR on screen", "captures.readQRScreen"), ("Capture a UI element", "captures.smartElement"), ("Capture a subject", "captures.subject"),
                               ("Capture and mark up", "captures.markup"), ("Capture the last area again", "captures.repeatArea"),
                               ("Capture after a delay", "captures.delayed"), ("Pick a colour", "captures.pickColour")]
    /// The tools after the captures: P73's history, P71's video editor and the image combiner show once registered.
    static let captureTools = [("Edit last capture", "captures.editLast"), ("Pin last capture", "captures.pinLast"),
                               ("Show last thumbnail again", "captures.restoreThumbnail"), ("Combine images…", "captures.combineImages"),
                               ("Edit video…", "captures.editVideo"), ("Open history", historyID)]
    static let record = "captures.screenRecording", pause = "captures.pauseRecording", historyID = "captures.history"
    /// Capture actions that are not captures: the launcher's Capture branch and a setting's switch.
    static let captureLeftOut = ["captures.menu", "captures.toggleDesktopIcons"]
    /// Every action Capture's menu can run, which BarInputs.actions is read for.
    public static let captureActions = (captureGrabs + captureTools).map(\.1) + [record, pause]

    /// Scroll changes the volume on Volume and steps through the workspaces on Workspaces.
    public var scrolls: Bool { self == .volume || self == .workspaces }
}

extension BarStyle {
    /// Its name in a menu: "Icon + number".
    public var menuTitle: String { title.prefix(1).uppercased() + title.dropFirst() }
}

extension BarSettings {
    public mutating func apply(_ edit: BarEdit, on kind: BarKind) {
        switch edit {
        case .style(let style): set(kind, style: style)
        case .move(let side): move(kind, to: side)
        case .remove: set(kind, on: false)
        }
    }

    /// Puts the item on `side`, after every other item there.
    public mutating func move(_ kind: BarKind, to side: TopBarSide) {
        set(kind, side: side)
        let others = entries.filter { $0.kind != kind }
        let last = others.lastIndex { $0.side == side }
        move(kind, to: last.map { $0 + 1 } ?? others.count)
    }
}

/// An item's one-line tooltip, from the readings it draws (card agent-bo-95423010): CPU reads "CPU 9% · load 1.42".
public enum BarTooltip {
    public static func text(_ slot: BarSlot, _ i: BarInputs) -> String {
        switch slot {
        case .item(let entry): text(entry.kind, i)
        case .group(let entries): entries.map { text($0.kind, i) }.joined(separator: "  ·  ")
        }
    }

    public static func text(_ kind: BarKind, _ i: BarInputs) -> String {
        let line = { (parts: [String?]) in parts.compactMap { $0 }.joined(separator: " · ") }
        // The reading's value as the item draws it.
        let value = { kind.stat.flatMap { MenuBarStats.value($0, values: i.values, raw: i.latest) } ?? "–" }
        switch kind {
        case .pilot:
            if i.pilotAlert { return "Pilot: Accessibility is off" }
            return i.pilotDownload.map { "Pilot's menu · extras \(Int($0 * 100))% downloaded" } ?? "Pilot's menu"
        case .workspaces: return i.focusedWorkspace.map { "Workspace \($0)" } ?? kind.title
        case .focusedApp: return i.focusedApp ?? "No app in front"
        case .otherApps: return "Other apps' menu bar items"
        case .appMenus: return "The front app's menus"
        case .cpu: return line(["CPU " + value(), i.latest?.load.first.map { String(format: "load %.2f", $0) }])
        case .memory, .storage: return "\(kind.title) \(value()) used"
        case .network, .graphics, .heat: return "\(kind.title) \(value())"
        case .battery:
            guard let battery = i.battery else { return i.watts.map { "This Mac draws \($0) W" } ?? "No battery" }
            return line(["Battery \(battery.percent)%", battery.charging ? "charging" : battery.minutesLeft.map { SystemStats.duration(minutes: $0) + " left" }])
        case .bluetoothBatteries:
            return i.bluetooth.isEmpty ? "No Bluetooth batteries" : i.bluetooth.map { "\($0.name) \($0.shortLevel)" }.joined(separator: " · ")
        case .keepAwake:
            guard i.keepAwake else { return "Keep awake is off" }
            return line(["Keep awake is on", i.keepAwakeLeft.map { "\(BarParts.duration($0)) left" }])
        case .power: return "Lock, sleep, restart or shut down"
        case .volume: return line(["Volume " + TopBarText.volume(i.volume, muted: i.muted), i.output])
        case .keyboardLayout: return "Keyboard layout " + (i.keyboardLayout ?? "–")
        case .wifi:
            guard i.wifiOn == true else { return "Wi-Fi is off" }
            return i.wifiSignal.map { "Wi-Fi · \(BarParts.wifiBars($0)) of 4 bars" } ?? "Wi-Fi is on, not joined"
        case .displays: return "Brightness, resolution and refresh rate"
        case .clock: return i.now.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: i.locale, timeZone: i.timeZone))
        case .timer: return i.timerCountdown.map { "\(i.timerTitle ?? "Timer") · \($0) left" } ?? "No timer running"
        case .extensions: return i.extensionBars.isEmpty ? "No extension shows anything here" : i.extensionBars.map(\.tooltip).joined(separator: " · ")
        case .terminal: return "Drop the terminal · click shows or hides it"
        case .askAI: return "Drop Ask AI · click shows or hides it"
        case .modes: return StatusDots.summary(i.statusLights)
        case .capture:
            switch i.recording {
            case nil: return "Capture · click for every capture and recording"
            case .starting: return "Recording is starting"
            case .counting(let n): return "Recording in \(n)"
            case .recording(let seconds): return "Recording · \(RecordingClock.label(seconds)) · click to stop or pause"
            case .paused(let seconds): return "Recording paused · \(RecordingClock.label(seconds)) · click to resume or stop"
            }
        case .spacer, .divider, .group: return kind.title
        }
    }
}

/// Scroll on an item: Volume 5 percent a step, Workspaces the previous one up and the next one down.
public enum BarScroll {
    static let volumeStep: Float = 0.05

    @MainActor public static func perform(_ kind: BarKind, steps: Int, on target: some BarScrollTarget) {
        switch kind {
        case .volume:
            guard let level = target.volume else { return }
            target.setVolume(min(max(level + Float(steps) * volumeStep, 0), 1))
        case .workspaces:
            for _ in 0..<abs(steps) { target.run(steps > 0 ? .workspacePrevious : .workspaceNext) }
        default: break
        }
    }

    /// Scroll deltas as steps, up positive: a wheel's notch is one, a trackpad's fine deltas add up to one every 12 points
    /// (`points`; a Hyper scroll bind's step is longer, HyperScroll).
    public struct Steps: Sendable {
        let points: Double
        private var carried = 0.0

        public init(points: Double = 12) { self.points = points }

        public mutating func add(_ delta: Double, precise: Bool) -> Int {
            guard precise else { return delta > 0 ? 1 : delta < 0 ? -1 : 0 }
            carried += delta
            let steps = Int(carried / points)
            carried -= Double(steps) * points
            return steps
        }
    }
}

/// What a scroll reaches: the output volume (SetupSound) and the tiler's workspaces (TilerService, which sends the
/// command to Pilot's tiler); fakes in tests.
@MainActor public protocol BarScrollTarget {
    var volume: Float? { get }
    func setVolume(_ level: Float)
    func run(_ command: AeroCommand)
}
