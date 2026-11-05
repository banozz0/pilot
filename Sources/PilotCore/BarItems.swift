import Foundation

/// The items of the macOS menu bar and Pilot's top bar, one list for both (card agent-bo-95422910; design round 4 section 6,
/// artifact 5sh21HWjCjsWYAwWKTibcE, approved by Sven in chat 2026-10-06; round 3's menu bar, "Menu bar changes ok"). Each
/// item has its styles, a place in one order, and a placement: the menu bar, the top bar or both.
public enum BarKind: String, Codable, CaseIterable, Sendable {
    case pilot, workspaces, focusedApp, appMenus, otherApps
    case cpu, memory, network, graphics, storage, heat
    case battery, bluetoothBatteries, keepAwake
    /// Lock, sleep, restart, shut down and log out in its popover (PowerAction).
    case power
    case volume, keyboardLayout, wifi
    /// Each screen's brightness, resolution and refresh rate in its popover, as System's Displays card (Sven 2026-10-12).
    case displays
    /// The bar drops' items (spec Bar drops T4, design C): each lights while its drop hangs under the top bar, and a click
    /// toggles it. Left of the status lights, in the bar's middle, so the drops hang under them.
    case terminal, askAI
    /// Capture as a bar item (Sven, 2026-10-16): a click opens the capture menu, and the recording's time
    /// shows on it while one runs, in place of the separate red-dot control.
    case capture
    /// Status lights (Sven, 2026-10-16, Q194-Q196): dots around the Pilot mark for agents, privacy and jobs, the plain
    /// mark while all is quiet (StatusLights); a click opens their popover. Left of the clock. Its raw value is the Mode
    /// lights' it replaced, so saved layouts keep it.
    case modes
    /// The extension timer's item (ExtensionTimer); it was the pomodoro's, so saved layouts keep reading its raw value.
    case clock, timer = "pomodoro"
    /// The kind of an extension's own bar item (story 161, ExtensionBar): each placed in the top bar is an entry of its
    /// own in the one order, its `extensionID` naming it (Sven, 2026-11-04, spec pilot-1.1 T50); in the macOS menu bar each
    /// is its own item (Surfaces v2, BarSettings.extensionItems). The entry with no id is where they all drew as one slot
    /// before T50: kept so saved layouts read, it draws nothing now.
    case extensions
    case spacer, divider, group

    public var title: String {
        switch self {
        case .pilot: "Pilot"
        case .workspaces: "Workspaces"
        case .focusedApp: "Focused app"
        case .appMenus: "App menus"
        case .otherApps: "Other apps"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .graphics: "Graphics"
        case .storage: "Storage"
        case .heat: "Heat"
        case .battery: SystemStats.hasBattery ? "Battery" : "Power draw"
        case .bluetoothBatteries: "Bluetooth batteries"
        case .keepAwake: "Keep awake"
        case .power: "Power"
        case .volume: "Volume"
        case .keyboardLayout: "Keyboard layout"
        case .wifi: "Wi-Fi"
        case .displays: "Displays"
        case .terminal: "Terminal"
        case .askAI: "Ask AI"
        case .capture: "Capture"
        case .modes: "Status lights"
        case .clock: "Clock"
        case .timer: "Timer"
        case .extensions: "Extensions"
        case .spacer: "Spacer"
        case .divider: "Divider"
        case .group: "Group"
        }
    }

    public var group: BarGroup {
        switch self {
        case .pilot, .workspaces, .focusedApp, .appMenus, .otherApps: .spacesAndWindows
        case .cpu, .memory, .network, .graphics, .storage, .heat: .readings
        case .battery, .bluetoothBatteries, .keepAwake, .power: .power
        case .volume, .keyboardLayout, .wifi, .displays: .controls
        case .modes, .clock, .timer: .timeAndFocus
        case .terminal, .askAI, .capture: .drops
        case .extensions: .extensions
        case .spacer, .divider, .group: .layout
        }
    }

    /// Round 4's styles, the first the default; Pilot's mark alone first (spec pilot-1-1 T28, Sven 2026-10-30).
    public var styles: [BarStyle] {
        switch self {
        case .pilot: [.icon, .iconNumber, .number]
        case .workspaces: [.numbers, .dots, .current, .withApp, .icons]
        case .focusedApp: [.icon, .iconName]
        case .appMenus: [.text]
        case .otherApps: [.icons, .oneButton]
        case .cpu, .memory: [.text, .graph, .bar]
        case .network, .graphics, .heat: [.text, .graph]
        case .storage: [.text, .bar]
        case .battery, .bluetoothBatteries: [.iconPercent, .icon]
        case .keepAwake: [.icon, .iconTime]
        case .power: [.icon]
        case .volume: [.icon, .iconPercent, .output]
        case .keyboardLayout: [.code, .icon, .name]
        case .wifi: [.icon, .strength]
        case .displays: [.icon]
        case .terminal, .askAI: [.iconName, .icon]
        case .capture: [.icon, .iconName]
        case .modes: [.icons]
        case .clock: [.time, .dateTime, .twoZones]
        case .timer: [.countdown, .ring, .icon]
        case .extensions: [.text]
        case .spacer: [.fixed, .flexible]
        case .divider: [.line]
        case .group: [.allInOne]
        }
    }

    /// The This Mac reading it shows (MenuBarStats, SystemSampler); nil for the rest.
    public var stat: MenuBarStats.Stat? {
        switch self {
        case .cpu: .cpu
        case .memory: .ram
        case .network: .network
        case .graphics: .gpu
        case .storage: .disk
        case .heat: .sensors
        case .battery: .battery
        case .bluetoothBatteries: .bluetooth
        default: nil
        }
    }

    public init(_ stat: MenuBarStats.Stat) {
        self = Self.allCases.first { $0.stat == stat }!
    }

    /// Other apps' items and the front app's menus are listed only in the top bar: in the menu bar they are already there.
    /// Status lights are the top bar's alone: their dots are drawn there. So are the bar drops' items: their drops
    /// hang from the top bar.
    public var topBarOnly: Bool { self == .otherApps || self == .appMenus || self == .extensions || self == .modes || isDrop }
    /// Joins a saved layout on: the extensions' item draws nothing until an installed extension declares a bar item, so
    /// installing one is the ask (story 161); the bar drops' items are placed by default (spec Bar drops T4). Every other
    /// new item joins off, Status lights too: they are placed in edit mode.
    var joinsOn: Bool { self == .extensions || isDrop }
    /// The bar drop it toggles: the terminal's or Ask AI's; nil for every other item.
    public var drop: BarDropKind? {
        switch self {
        case .terminal: .terminal
        case .askAI: .askAI
        default: nil
        }
    }
    var isDrop: Bool { drop != nil }
    /// Shrinks in a crowded top bar before any item goes (card agent-bo-95423016): the app's menus fold behind a chevron.
    public var folds: Bool { self == .appMenus }

    /// Pilot's own icon: always on, always in the macOS menu bar, and while the top bar is on its first left item, whatever
    /// its placement (card agent-bo-95423009: the macOS menu bar hides under the top bar).
    public var pinned: Bool { self == .pilot }

    /// What a click on it does (cards agent-bo-95422911 and 912): most open their popover, Pilot's being the dropdown, and
    /// Volume its Sound popover as macOS's own Sound item does (Sven on build 21), the keyboard layout its layouts (Sven on
    /// build 36; its menu keeps Next layout); Keep awake switches, as round 3 says; a spacer or divider does nothing. A bar
    /// drop's item toggles its drop, which the top bar does itself (TopBarDropItem), so its click here is none. Capture
    /// opens its menu.
    public var click: BarClick {
        switch self {
        case .keepAwake: .toggleKeepAwake
        case .capture: .menu
        case .spacer, .divider, .otherApps, .appMenus, .terminal, .askAI: .none
        default: .popover
        }
    }

    /// What an Option-click does instead: Volume mutes or unmutes (story 116); nil where it does what a click does.
    public var optionClick: BarClick? { self == .volume ? .toggleMute : nil }

    /// The side of the top bar it starts on: spaces and windows left, the clock centre, the rest right (round 4's bar).
    var side: TopBarSide {
        switch self {
        case .pilot, .workspaces, .focusedApp, .appMenus: .left
        case .terminal, .askAI, .modes, .clock: .centre
        default: .right
        }
    }
}

public enum BarClick: Equatable, Sendable {
    case popover, cycleLayout, toggleKeepAwake, toggleMute, none
    /// The item's own menu, hung under it: Capture's area, window, screen, recording and the rest (BarKind.actions).
    case menu
    /// An extension's own bar item, by its id: its popover (Surfaces v2).
    case `extension`(String)

    /// A click on what a bar draws: the group opens its popover; an item does what its kind does. A right-click opens the
    /// item's menu (BarEntry.menu). With Option held an item with an Option-click does that.
    public init(_ kinds: [BarKind], isGroup: Bool, option: Bool = false) {
        self = isGroup ? .popover : (option ? kinds.first?.optionClick : nil) ?? kinds.first?.click ?? .none
    }
}

/// The Menu bar page's groups, its tiles and the bar tray's sections, in their order (Sven, 2026-10-16: the bar drops and
/// the extensions are not time and focus; Wi-Fi and Displays are controls, not sound and input). Tools holds the bar drops'
/// items and Capture.
public enum BarGroup: CaseIterable, Sendable {
    case spacesAndWindows, readings, power, controls, timeAndFocus, drops, extensions, layout

    public var title: String {
        switch self {
        case .spacesAndWindows: "Spaces and windows"
        case .readings: "Readings"
        case .power: "Power"
        case .controls: "Controls"
        case .timeAndFocus: "Time and focus"
        case .drops: "Tools"
        case .extensions: "Extensions"
        case .layout: "Layout"
        }
    }
}

/// Every look an item can take; each item offers a few (BarKind.styles).
public enum BarStyle: String, Codable, Sendable {
    case iconNumber, icon, number, numbers, dots, current, withApp, iconName, icons, oneButton
    case text, graph, bar, iconPercent, iconTime, output, code, name, strength
    case time, dateTime, twoZones, countdown, ring, fixed, flexible, line, allInOne

    public var title: String {
        switch self {
        case .iconNumber: "icon + number"
        case .withApp: "with app"
        case .iconName: "icon + name"
        case .oneButton: "one button"
        case .iconPercent: "icon + %"
        case .iconTime: "icon + time"
        case .dateTime: "date + time"
        case .twoZones: "two zones"
        case .allInOne: "all in one"
        default: rawValue
        }
    }
}

public enum BarPlacement: String, Codable, CaseIterable, Sendable {
    case menuBar, topBar, both
}

/// Where a list of items is drawn.
public enum BarPlace: Sendable {
    case menuBar, topBar
}

/// One item as Sven set it.
public struct BarEntry: Codable, Equatable, Sendable {
    public let kind: BarKind
    public internal(set) var on: Bool
    public internal(set) var style: BarStyle
    public internal(set) var placement: BarPlacement
    /// Its side of the top bar.
    public internal(set) var side: TopBarSide
    /// The spacer's width in points as stretched in edit mode (BarSpacer); nil draws its style's.
    public internal(set) var width: Double?
    /// The extension whose bar item this is, its place in the top bar's order (spec pilot-1.1 T50); nil for a built-in
    /// item. Whether it shows is its ExtensionBarEntry's on and placement; this entry holds only its side and place.
    public internal(set) var extensionID: String?

    /// What it is in a drag and in the order: a built-in item, or an extension's.
    public var item: BarTrayItem { extensionID.map(BarTrayItem.extension) ?? .kind(kind) }

    /// An extension's item's place in the top bar, on `side`.
    init(extension id: String, side: TopBarSide) {
        self.init(.extensions, on: true, placement: .topBar)
        (extensionID, self.side) = (id, side)
    }

    init(_ kind: BarKind, on: Bool = false, style: BarStyle? = nil, placement: BarPlacement = .both) {
        self.kind = kind
        self.on = on
        self.style = style ?? kind.styles[0]
        self.placement = placement
        side = kind.side
        keepRules()
    }

    /// The rules no setting can break: a pinned item stays on and on the left, a top-bar-only item stays in the top bar.
    mutating func keepRules() {
        if kind.pinned { (on, side) = (true, .left) }
        if kind.topBarOnly { placement = .topBar }
    }

    /// Whether it shows in `place`, the top bar being on or off; Pilot's own icon is in the macOS menu bar always and in
    /// the top bar while it is on.
    func shows(in place: BarPlace, topBarOn: Bool) -> Bool {
        guard on else { return false }
        switch place {
        case .menuBar: return kind.pinned || placement == .menuBar || (placement == .both && !topBarOn)
        case .topBar: return topBarOn && (kind.pinned || placement != .menuBar)
        }
    }

}

extension BarEntry {
    enum CodingKeys: String, CodingKey {
        case kind, on, style, placement, side, width
        case extensionID = "extension"
    }

    /// An extension's item saves its kind as `extension`, which a Pilot from before T50 lacks, so it skips the entry
    /// rather than drawing its old Extensions slot once per extension.
    static let extensionKind = "extension"

    /// Saved by another Pilot: a style the item lacks takes its first; an item this Pilot lacks fails, and the list skips it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? c.decode(String.self, forKey: .extensionID), try c.decode(String.self, forKey: .kind) == Self.extensionKind {
            self.init(extension: id, side: (try? c.decode(TopBarSide.self, forKey: .side)) ?? .right)
            return
        }
        let kind = try c.decode(BarKind.self, forKey: .kind)
        let style = (try? c.decode(BarStyle.self, forKey: .style)).flatMap { kind.styles.contains($0) ? $0 : nil }
        self.init(kind, on: try c.decode(Bool.self, forKey: .on), style: style,
                  placement: (try? c.decode(BarPlacement.self, forKey: .placement)) ?? .both)
        side = (try? c.decode(TopBarSide.self, forKey: .side)) ?? kind.side
        width = kind == .spacer ? (try? c.decodeIfPresent(Double.self, forKey: .width)).flatMap { $0 } : nil
        keepRules()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let extensionID {
            try c.encode(Self.extensionKind, forKey: .kind)
            try c.encode(extensionID, forKey: .extensionID)
            try c.encode(side, forKey: .side)
            return
        }
        try c.encode(kind, forKey: .kind)
        try c.encode(on, forKey: .on)
        try c.encode(style, forKey: .style)
        try c.encode(placement, forKey: .placement)
        try c.encode(side, forKey: .side)
        try c.encodeIfPresent(width, forKey: .width)
    }
}

/// One thing drawn in a bar: an item, or the group's readings as one.
public enum BarSlot: Equatable, Sendable {
    case item(BarEntry)
    case group([BarEntry])

    public var entries: [BarEntry] {
        switch self {
        case .item(let entry): [entry]
        case .group(let entries): entries
        }
    }
    public var kinds: [BarKind] { entries.map(\.kind) }
    public var isGroup: Bool { if case .group = self { true } else { false } }
    /// What a click on it does: the group opens its popover, an item does what its kind does.
    public var click: BarClick { BarClick(kinds, isGroup: isGroup) }
    /// The item its right-click menu is for: the Group for the group.
    public var kind: BarKind { isGroup ? .group : kinds[0] }
    /// What a drag of it moves: the Group, a built-in item or an extension's own item.
    public var item: BarTrayItem { isGroup ? .kind(.group) : entries[0].item }
    /// Its name in `pilot bar` and the observers dump: its items joined by +, an extension's as extension:<id>.
    public var name: String {
        if case .extension = item { return item.rawValue }
        return kinds.map(\.rawValue).joined(separator: "+")
    }
}

/// Every item once, in order, plus the clock's pattern and the busiest-by-RAM rule the readings' popovers use. Saved as
/// `bar.items`; the first start carries today's settings over (`migrated`).
public struct BarSettings: Codable, Equatable, Sendable {
    public private(set) var entries: [BarEntry]
    /// The clock's time, a date pattern as DateFormatter takes it; date + time puts the day before it.
    public var clock: TopBarClockFormat
    /// The clock's second zone, a time zone identifier, for the two zones style; set from the clock's popover.
    public var clockZone: String?
    /// The clock's popover lists Calendar's events (SPEC story 168): off until Sven turns on Show events there, which
    /// is when Calendar access is asked.
    public var clockEvents = false
    /// Other apps' items in the top bar's drawer drawn as macOS draws them, captured off the menu bar (Sven's yes,
    /// 2026-10-10, ADR 0012): off until Sven turns on Show exact menu bar items, which is when Screen Recording is asked.
    public var exactMenuItems = false
    /// Stats' RAM Combined processes: the busiest by RAM count an app's helpers under the app (card agent-bo-95422834).
    public var combineProcesses: Bool
    /// Each extension's bar item as Sven placed it (Surfaces v2); one never placed is on in the macOS menu bar.
    public internal(set) var extensionItems: [ExtensionBarEntry] = []

    /// Round 4's pick 7: Pilot's icon (the mark alone since spec pilot-1-1 T28: the workspaces item has the number), the workspaces, one group of CPU, Memory and Network, and
    /// the timer, in both places; the top bar adds the clock, the bar drops' items, the status lights and other apps' items,
    /// which it hides with the macOS bar. Capture's menu is on in the macOS menu bar only (Q368), never the top bar.
    public static let defaults: BarSettings = {
        let on: [BarKind: BarStyle] = [.pilot: .icon, .workspaces: .numbers, .group: .allInOne, .cpu: .text, .memory: .text,
                                       .network: .text, .timer: .countdown, .clock: .dateTime, .otherApps: .icons, .extensions: .text,
                                       .modes: .icons, .terminal: .iconName, .askAI: .iconName, .capture: .icon]
        var kinds = BarKind.allCases.filter { $0 != .group }
        kinds.insert(.group, at: kinds.firstIndex(of: .cpu)!)
        let entries = kinds.map { kind in
            BarEntry(kind, on: on[kind] != nil, style: on[kind], placement: kind == .clock ? .topBar : kind == .capture ? .menuBar : .both)
        }
        return BarSettings(entries: entries, clock: .time24, clockZone: nil, combineProcesses: false)
    }()

    public func entry(_ kind: BarKind) -> BarEntry { entries.first { $0.item == .kind(kind) }! }

    /// Where `item` is in the order: a built-in item always is; an extension's once it was put in the top bar.
    func index(of item: BarTrayItem) -> Int? { entries.firstIndex { $0.item == item } }

    public mutating func set(_ kind: BarKind, on: Bool) { edit(kind) { $0.on = on } }

    /// A style the item lacks changes nothing; a style picked for the spacer drops its stretched width.
    public mutating func set(_ kind: BarKind, style: BarStyle) {
        edit(kind) { if kind.styles.contains(style) { ($0.style, $0.width) = (style, nil) } }
    }

    /// The spacer's stretched width, within BarSpacer.widths and to the point; nil goes back to its style's.
    public mutating func setSpacer(width: Double?) { edit(.spacer) { $0.width = width.map(BarSpacer.clamp) } }

    public mutating func set(_ kind: BarKind, placement: BarPlacement) { edit(kind) { $0.placement = placement } }

    public mutating func set(_ kind: BarKind, side: TopBarSide) { set(.kind(kind), side: side) }

    /// The side of the top bar `item` is on; an extension's item with no place yet gets none.
    mutating func set(_ item: BarTrayItem, side: TopBarSide) {
        guard let index = index(of: item) else { return }
        entries[index].side = side
        entries[index].keepRules()
    }

    /// Restore defaults, beside the Menu bar page's Clear all (Q411), for the placement the page shows: Both puts the
    /// items, their order and places back as `defaults` has them, the extensions' items unplaced; one bar gets back the
    /// default items in it, the top bar their default sides too, and the other bar keeps what it has. The clock's
    /// pattern and the other settings stay.
    public mutating func restoreDefaultItems(in placement: BarPlacement) {
        guard placement != .both else {
            entries = Self.defaults.entries
            extensionItems = []
            return
        }
        for entry in Self.defaults.entries {
            set(entry.kind, in: placement, on: Self.defaults.isOn(entry.kind, in: placement))
            if placement == .topBar { set(entry.kind, side: entry.side) }
        }
        for item in extensionItems where isOn(extension: item.id, in: placement) != Self.defaults.isOn(extension: item.id, in: placement) {
            toggle(extension: item.id, in: placement)
        }
    }

    /// Moves the item to `index` in the order.
    public mutating func move(_ kind: BarKind, to index: Int) { move(.kind(kind), to: index) }

    /// Moves a built-in item or an extension's to `index` in the order.
    public mutating func move(_ item: BarTrayItem, to index: Int) {
        guard let from = self.index(of: item) else { return }
        let entry = entries.remove(at: from)
        entries.insert(entry, at: min(max(index, 0), entries.count))
    }

    private mutating func edit(_ kind: BarKind, _ change: (inout BarEntry) -> Void) {
        guard let index = index(of: .kind(kind)) else { return }
        change(&entries[index])
        entries[index].keepRules()
    }

    /// What `place` draws, in order (one side of the top bar when `side` is given). With the Group shown there, every
    /// reading shown there joins one slot at the Group's place; without it each reading is its own. Each extension's item
    /// placed in the top bar is a slot of its own there, drawn once it has something to show (BarParts); the old
    /// Extensions slot draws nowhere.
    public func slots(in place: BarPlace, topBarOn: Bool, side: TopBarSide? = nil) -> [BarSlot] {
        // Pilot's icon leads the top bar, in whatever order it was saved.
        let inTopBar = place == .topBar && topBarOn ? Set(extensionItems.filter { $0.on && $0.placement != .menuBar }.map(\.id)) : []
        let shown = entries.filter { entry in
            guard side == nil || entry.side == side else { return false }
            if let id = entry.extensionID { return inTopBar.contains(id) }
            return entry.kind != .extensions && entry.shows(in: place, topBarOn: topBarOn)
        }
            .sorted { place == .topBar && $0.kind.pinned && !$1.kind.pinned }
        // The group gathers its readings from the whole bar, wherever their own side is.
        let grouped = entry(.group).shows(in: place, topBarOn: topBarOn)
        let readings = grouped ? entries.filter { $0.kind.group == .readings && $0.shows(in: place, topBarOn: topBarOn) } : []
        return shown.compactMap { entry in
            if entry.kind == .group { return readings.isEmpty ? nil : .group(readings) }
            return grouped && entry.kind.group == .readings ? nil : .item(entry)
        }
    }

    /// Today's settings carried over (memory note 1: nothing Sven set is lost): round 4's defaults, then the menu bar's
    /// readings (menuBar.stats: each one's on, style and order, combined as the Group, Combined processes), the pomodoro's
    /// Countdown in menu bar (pomodoro.countdown) and the top bar's layout (topBar.settings: its standard layout's items,
    /// sides, order and styles, its clock). A screen's own layout is not carried: one layout serves every screen.
    public static func migrated(stats: MenuBarStats.Choices?, topBar: TopBarSettings?, pomodoroCountdown: Bool?) -> BarSettings {
        var s = defaults
        // A Pilot from before bar items keeps what it had: Capture's menu is on only if its top bar held it.
        if topBar != nil || pomodoroCountdown != nil { s.set(.capture, on: false) }
        if let stats {
            for item in stats.items {
                let kind = BarKind(item.stat)
                s.set(kind, on: item.on)
                s.set(kind, style: item.style == .graph ? .graph : kind.styles[0])
            }
            s.reorder(stats.items.map { BarKind($0.stat) })
            s.set(.group, on: stats.combined)
            s.combineProcesses = stats.combineProcesses
        }
        if let pomodoroCountdown { s.set(.timer, on: pomodoroCountdown) }
        if let topBar {
            let layout = topBar.standard
            let saved = TopBarSide.allCases.flatMap { side in layout[side].filter { $0.kind != nil }.map { ($0, side) } }
            for index in s.entries.indices {
                let entry = s.entries[index]
                let inMenuBar = entry.on && entry.placement != .topBar, inTopBar = saved.contains { $0.0.kind == entry.kind }
                s.entries[index].on = inMenuBar || inTopBar
                switch (inMenuBar, inTopBar) {
                case (true, true): s.entries[index].placement = .both
                case (false, true): s.entries[index].placement = .topBar
                default: s.entries[index].placement = .menuBar
                }
                s.entries[index].keepRules()
            }
            for (item, side) in saved {
                let kind = item.kind!
                s.set(kind, side: side)
                if let style = item.barStyle { s.set(kind, style: style) }
            }
            s.reorder(saved.map { $0.0.kind! })
            s.clock = topBar.clock
        }
        return s
    }

    /// Puts `kinds` in this order in the places they hold between them; everything else stays where it is. A kind named
    /// twice (a saved side with two clocks) keeps its first place.
    private mutating func reorder(_ named: [BarKind]) {
        let kinds = named.reduce(into: [BarKind]()) { if !$0.contains($1) { $0.append($1) } }
        let places = entries.indices.filter { kinds.contains(entries[$0].kind) }
        let moved = kinds.map(entry)
        for (place, entry) in zip(places, moved) { entries[place] = entry }
    }
}

private extension TopBarItem {
    /// The item this saved top bar module became.
    var kind: BarKind? {
        switch module {
        case .workspaces: .workspaces
        case .clock: .clock
        case .focusedApp: .focusedApp
        case .inputSource: .keyboardLayout
        case .volume: .volume
        case .pomodoro: .timer
        case .battery: .battery
        case .menuApps: .otherApps
        case .cpu: .cpu
        case .gpu: .graphics
        case .ram: .memory
        case .disk: .storage
        case .temperature: .heat
        case .network: .network
        case .bluetooth: .bluetoothBatteries
        }
    }

    /// Its look as the item's style: what the old module drew, the nearest round 4 style. The old clock pattern carries as
    /// the time style, so the clock draws the same text; other apps' names fold into icons (the names show on hover).
    var barStyle: BarStyle? {
        switch (module, style) {
        case (.workspaces, .text): .withApp
        case (.workspaces, _): .numbers
        case (.inputSource, .compact): .code
        case (.inputSource, _): .name
        case (.volume, .text): .output
        case (.volume, _): .iconPercent
        case (.menuApps, _): .icons
        case (.focusedApp, _): .iconName
        case (.battery, _): .iconPercent
        case (.clock, _): .time
        case (_, .graph): .graph
        case (_, _) where kind?.stat != nil: .text
        default: nil
        }
    }
}

extension BarSettings {
    /// A later Pilot's item is skipped, an item this Pilot added since joins off at the end; Status lights join just before
    /// the clock and on its side, so turned on they sit left of it. The bar drops' items join on, just before the clock in
    /// the bar's middle, so the drops hang under them (spec Bar drops T4).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var entries = try c.decode([Lossy<BarEntry>].self, forKey: .entries).compactMap(\.value)
        for kind in BarKind.allCases where !entries.contains(where: { $0.item == .kind(kind) }) {
            let clock = kind == .modes || kind.isDrop ? entries.firstIndex { $0.kind == .clock } : nil
            var entry = BarEntry(kind, on: kind.joinsOn)
            if let clock, !kind.isDrop { entry.side = entries[clock].side }
            entries.insert(entry, at: clock ?? entries.endIndex)
        }
        self.init(entries: entries, clock: (try? c.decode(TopBarClockFormat.self, forKey: .clock)) ?? .time24,
                  clockZone: try? c.decodeIfPresent(String.self, forKey: .clockZone),
                  clockEvents: (try? c.decode(Bool.self, forKey: .clockEvents)) ?? false,
                  exactMenuItems: (try? c.decode(Bool.self, forKey: .exactMenuItems)) ?? false,
                  combineProcesses: (try? c.decode(Bool.self, forKey: .combineProcesses)) ?? false,
                  extensionItems: (try? c.decode([Lossy<ExtensionBarEntry>].self, forKey: .extensionItems))?.compactMap(\.value) ?? [])
        placeGroupedExtensions(order: decoder.userInfo[Self.extensionOrder] as? @Sendable () -> [String])
    }

    /// The decoder's `userInfo` key for the order the extensions' items drew in the old Extensions slot: their ids as
    /// ExtensionBar lists them, by title. A function, so the folder is read only when a saved bar needs it.
    public static let extensionOrder = CodingUserInfoKey(rawValue: "pilot.bar.extensionOrder")!

    /// A bar saved before T50 drew every extension's item in the top bar in one Extensions slot: each gets its own
    /// place where that slot was, on its side, in the order they drew (`order`, else the order they were placed in), so
    /// the bar looks as it did. While that slot was off they drew nowhere, so they leave the top bar instead. Idempotent:
    /// an item with its place already keeps it.
    mutating func placeGroupedExtensions(order: (() -> [String])?) {
        let unplaced = extensionItems.filter { $0.on && $0.placement != .menuBar && index(of: .extension($0.id)) == nil }.map(\.id)
        guard !unplaced.isEmpty, let anchor = index(of: .kind(.extensions)) else { return }
        let order = order?() ?? []
        let ranked = order.filter(unplaced.contains) + unplaced.filter { !order.contains($0) }
        let slot = entries[anchor]
        guard slot.on else {
            for id in ranked { set(extension: id, on: extensionEntry(id).placement == .both, placement: .menuBar) }
            return
        }
        entries.insert(contentsOf: ranked.map { BarEntry(extension: $0, side: slot.side) }, at: anchor)
    }

    /// Whether `kind` shows in `place` now.
    public func shows(_ kind: BarKind, in place: BarPlace, topBarOn: Bool) -> Bool {
        entry(kind).shows(in: place, topBarOn: topBarOn)
    }
}

/// One extension's bar item as Sven placed it (Surfaces v2, design https://claude.ai/artifact/Cd9woPtPXQ4HJWKUYXRSYh): on
/// or off, in the macOS menu bar (its own item, the default), Pilot's top bar (drawn where the Extensions item sits) or
/// both, as the built-in items are.
public struct ExtensionBarEntry: Codable, Equatable, Sendable {
    public let id: String
    public internal(set) var on: Bool
    public internal(set) var placement: BarPlacement

    public init(id: String, on: Bool = true, placement: BarPlacement = .menuBar) { self.id = id; self.on = on; self.placement = placement }
}

extension BarSettings {
    /// `id`'s bar item as placed; one never placed is on in the macOS menu bar.
    public func extensionEntry(_ id: String) -> ExtensionBarEntry {
        extensionItems.first { $0.id == id } ?? ExtensionBarEntry(id: id)
    }

    /// Whether `id`'s bar item shows in `place`, as a built-in item would: its own item in the macOS menu bar, its own
    /// slot in the top bar (spec pilot-1.1 T50).
    public func shows(extension id: String, in place: BarPlace, topBarOn: Bool) -> Bool {
        let item = extensionEntry(id)
        guard item.on else { return false }
        switch place {
        case .menuBar: return item.placement == .menuBar || (item.placement == .both && !topBarOn)
        case .topBar: return topBarOn && item.placement != .menuBar
        }
    }

    /// The Menu bar page's + or switch for an extension's item in `placement`, as for a built-in item (isOn).
    public func isOn(extension id: String, in placement: BarPlacement) -> Bool {
        let item = extensionEntry(id)
        guard item.on else { return false }
        switch placement {
        case .both: return item.placement == .both
        case .menuBar: return item.placement != .topBar
        case .topBar: return item.placement != .menuBar
        }
    }

    /// In, the item joins `placement` and keeps the other bar it was in; out, it leaves it and stays in the other, or goes
    /// off. Joining the top bar for the first time puts it last there (set(extension:)).
    public mutating func toggle(extension id: String, in placement: BarPlacement) {
        let item = extensionEntry(id), joining = !isOn(extension: id, in: placement)
        let wasMenu = item.on && item.placement != .topBar, wasTop = item.on && item.placement != .menuBar
        let (menu, top) = switch placement {
        case .menuBar: (joining, wasTop)
        case .topBar: (wasMenu, joining)
        case .both: (joining, joining)
        }
        set(extension: id, on: menu || top, placement: menu || top ? (menu && top ? .both : menu ? .menuBar : .topBar) : item.placement)
    }

    /// Places `id`'s item: on or off, and where. One put in the top bar for the first time lands last there, at the end
    /// of its right side (spec pilot-1.1 T50); one that was there before keeps its place.
    public mutating func set(extension id: String, on: Bool, placement: BarPlacement) {
        let item = ExtensionBarEntry(id: id, on: on, placement: placement)
        if let index = extensionItems.firstIndex(where: { $0.id == id }) { extensionItems[index] = item } else { extensionItems.append(item) }
        if on, placement != .menuBar, index(of: .extension(id)) == nil { entries.append(BarEntry(extension: id, side: .right)) }
    }
}
