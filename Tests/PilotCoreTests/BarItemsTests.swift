import Foundation
import PilotCore
import Testing

/// One item list for the macOS menu bar and Pilot's top bar (card agent-bo-95422910, design round 4 section 6, approved by
/// Sven in chat 2026-10-06): 21 items in six groups, each with its styles, order and place; round 4's defaults; today's
/// saved menu-bar readings, top bar layout and pomodoro countdown (now the timer's item) carried over.
@Suite("Bar items")
struct BarItemsTests {
    /// Sven's menuBar.stats as saved on his Mac on 2026-10-06 (defaults export dev.banozz.pilot).
    static let svensStats = #"{"items":[{"stat":"cpu","on":true,"style":"text"},{"stat":"gpu","on":false,"style":"text"},{"stat":"ram","on":true,"style":"text"},{"stat":"disk","on":false,"style":"text"},{"stat":"sensors","on":false,"style":"text"},{"stat":"network","on":false,"style":"text"},{"stat":"battery","on":false,"style":"text"},{"stat":"bluetooth","on":false,"style":"text"}],"combined":true,"combineProcesses":true}"#

    static func stats(_ json: String = svensStats) throws -> MenuBarStats.Choices {
        try JSONDecoder().decode(MenuBarStats.Choices.self, from: Data(json.utf8))
    }

    @Test("Every item is in one of the groups, each group holds an item, and Terminal, Ask AI and Extensions are not Time and focus (Sven, 2026-10-16)")
    func everyItemGrouped() {
        #expect(BarKind.allCases.allSatisfy { BarGroup.allCases.contains($0.group) })
        #expect(BarGroup.allCases.allSatisfy { group in BarKind.allCases.contains { $0.group == group } })
        for kind in [BarKind.terminal, .askAI, .extensions] { #expect(kind.group != .timeAndFocus, "\(kind)") }
        #expect(BarKind.terminal.group == BarKind.askAI.group && BarKind.extensions.group == .extensions)
    }

    @Test("29 items in eight groups: round 4's, with Terminal, Ask AI and Capture under Tools, and Extensions, in groups of their own and Wi-Fi and Displays under Controls (Sven, 2026-10-16); App menus (card agent-bo-95423015), Extensions (story 161), Power, Displays, Status lights and the bar drops' items (spec Bar drops T4), each with exactly round 4's styles")
    func catalogue() {
        let groups = BarGroup.allCases.map { group in (group.title, BarKind.allCases.filter { $0.group == group }.map(\.title)) }
        #expect(groups.map(\.0) == ["Spaces and windows", "Readings", "Power", "Controls", "Time and focus", "Tools", "Extensions", "Layout"])
        #expect(groups.map(\.1) == [["Pilot", "Workspaces", "Focused app", "App menus", "Other apps"],
                                    ["CPU", "Memory", "Network", "Graphics", "Storage", "Heat"],
                                    [SystemStats.hasBattery ? "Battery" : "Power draw", "Bluetooth batteries", "Keep awake", "Power"],
                                    ["Volume", "Keyboard layout", "Wi-Fi", "Displays"],
                                    ["Status lights", "Clock", "Timer"],
                                    ["Terminal", "Ask AI", "Capture"],
                                    ["Extensions"],
                                    ["Spacer", "Divider", "Group"]])
        #expect(BarKind.allCases.count == 29)
        let styles = Dictionary(uniqueKeysWithValues: BarKind.allCases.map { ($0, $0.styles.map(\.title)) })
        #expect(styles == [
            .pilot: ["icon + number", "icon", "number"], .workspaces: ["numbers", "dots", "current", "with app", "icons"],
            .focusedApp: ["icon", "icon + name"], .appMenus: ["text"], .otherApps: ["icons", "one button"],
            .cpu: ["text", "graph", "bar"], .memory: ["text", "graph", "bar"], .network: ["text", "graph"],
            .graphics: ["text", "graph"], .storage: ["text", "bar"], .heat: ["text", "graph"],
            .battery: ["icon + %", "icon"], .bluetoothBatteries: ["icon + %", "icon"], .keepAwake: ["icon", "icon + time"], .power: ["icon"],
            .volume: ["icon", "icon + %", "output"], .keyboardLayout: ["code", "icon", "name"], .wifi: ["icon", "strength"], .displays: ["icon"],
            .terminal: ["icon + name", "icon"], .askAI: ["icon + name", "icon"], .capture: ["icon", "icon + name"], .modes: ["icons"], .clock: ["time", "date + time", "two zones"], .timer: ["countdown", "ring", "icon"], .extensions: ["text"],
            .spacer: ["fixed", "flexible"], .divider: ["line"], .group: ["all in one"],
        ])
    }

    @Test("A fresh start holds round 4's pick 7: Pilot, Workspaces, one group of CPU, Memory and Network, the timer; the top bar adds its clock, mode lights and other apps; Capture's menu is in the menu bar only")
    func defaults() {
        let s = BarSettings.defaults
        // The catalogue's order, the Group just before the readings it gathers.
        var order = BarKind.allCases.filter { $0 != .group }
        order.insert(.group, at: 5)
        #expect(s.entries.map(\.kind) == order)
        let on = s.entries.filter(\.on)
        #expect(on.map(\.kind) == [.pilot, .workspaces, .otherApps, .group, .cpu, .memory, .network, .terminal, .askAI, .capture, .modes, .clock, .timer, .extensions])
        #expect(on.map(\.style) == [.iconNumber, .numbers, .icons, .allInOne, .text, .text, .text, .iconName, .iconName, .icon, .icons, .dateTime, .countdown, .text])
        #expect(on.filter { $0.placement == .both }.map(\.kind) == [.pilot, .workspaces, .group, .cpu, .memory, .network, .timer])
        #expect(s.entry(.clock).placement == .topBar && s.entry(.otherApps).placement == .topBar && s.entry(.extensions).placement == .topBar)
        #expect(s.entry(.capture).placement == .menuBar)
        // Top bar off: the macOS menu bar shows Pilot, Workspaces, the group of three readings, Capture, the timer.
        #expect(s.slots(in: .menuBar, topBarOn: false) == [.item(s.entry(.pilot)), .item(s.entry(.workspaces)),
                                                          .group([s.entry(.cpu), s.entry(.memory), s.entry(.network)]),
                                                          .item(s.entry(.capture)), .item(s.entry(.timer))])
    }

    @Test("Items placed in both leave the macOS menu bar while the top bar is on; Pilot's own icon never does")
    func nothingTwice() {
        let s = BarSettings.defaults
        #expect(s.slots(in: .menuBar, topBarOn: true) == [.item(s.entry(.pilot)), .item(s.entry(.capture))])
        #expect(s.slots(in: .topBar, topBarOn: true, side: .left).map(\.kinds) == [[.pilot], [.workspaces]])
        #expect(s.slots(in: .topBar, topBarOn: true, side: .centre).map(\.kinds) == [[.terminal], [.askAI], [.modes], [.clock]])
        #expect(s.slots(in: .topBar, topBarOn: true, side: .right).map(\.kinds) == [[.otherApps], [.cpu, .memory, .network], [.timer], [.extensions]])
        // The top bar off shows nothing in it.
        #expect(s.slots(in: .topBar, topBarOn: false, side: .left).isEmpty)
        // A menu-bar-only item stays in the menu bar with the top bar on; other apps never reach the menu bar.
        var t = s
        t.set(.timer, placement: .menuBar)
        t.set(.otherApps, placement: .both)
        #expect(t.slots(in: .menuBar, topBarOn: true).map(\.kinds) == [[.pilot], [.capture], [.timer]])
        #expect(t.entry(.otherApps).placement == .topBar)
    }

    @Test("The group sits where Group sits and holds every reading on in that place; without Group each reading is its own item")
    func grouping() {
        var s = BarSettings.defaults
        s.set(.heat, on: true)
        s.set(.battery, on: true)
        s.move(.group, to: 0)
        #expect(s.slots(in: .menuBar, topBarOn: false).map(\.kinds) == [[.cpu, .memory, .network, .heat], [.pilot], [.workspaces], [.battery], [.capture], [.timer]])
        s.set(.group, on: false)
        #expect(s.slots(in: .menuBar, topBarOn: false).map(\.kinds) == [[.pilot], [.workspaces], [.cpu], [.memory], [.network], [.heat], [.battery], [.capture], [.timer]])
        // A reading only in the menu bar stays out of the top bar's group.
        s.set(.group, on: true)
        s.set(.memory, placement: .menuBar)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .right).map(\.kinds).contains([.cpu, .network, .heat]))
    }

    @Test("A style an item lacks is refused; Pilot cannot be switched off")
    func refusals() {
        var s = BarSettings.defaults
        s.set(.clock, style: .graph)
        s.set(.cpu, style: .bar)
        s.set(.pilot, on: false)
        #expect(s.entry(.clock).style == .dateTime && s.entry(.cpu).style == .bar && s.entry(.pilot).on)
    }

    @Test("Moving an item changes only the order")
    func move() {
        var s = BarSettings.defaults
        s.move(.timer, to: 1)
        #expect(s.entries.map(\.kind).prefix(3) == [.pilot, .timer, .workspaces])
        #expect(Set(s.entries.map(\.kind)) == Set(BarKind.allCases) && s.entries.count == 29)
    }

    @Test("The user's saved readings carry over: CPU and Memory on as text in one group, Combined processes on, the rest off")
    func svensReadings() throws {
        let s = BarSettings.migrated(stats: try Self.stats(), topBar: nil, pomodoroCountdown: nil)
        #expect(s.entries.filter { $0.kind.group == .readings && $0.on }.map(\.kind) == [.cpu, .memory])
        #expect(s.entry(.cpu).style == .text && s.entry(.memory).style == .text)
        #expect(!s.entry(.battery).on && !s.entry(.bluetoothBatteries).on && s.entry(.group).on && s.combineProcesses)
        // Round 4's defaults fill what he never set.
        #expect(s.entry(.workspaces).on && s.entry(.timer).on && s.entry(.pilot).on)
        #expect(s.slots(in: .menuBar, topBarOn: false).map(\.kinds) == [[.pilot], [.workspaces], [.cpu, .memory], [.capture], [.timer]])
    }

    @Test("Saved readings keep their order, graphs, a battery on and one item each when not combined")
    func readingsKept() throws {
        let json = #"{"items":[{"stat":"network","on":true,"style":"graph"},{"stat":"cpu","on":true,"style":"graph"},{"stat":"sensors","on":true,"style":"text"},{"stat":"battery","on":true,"style":"text"},{"stat":"gpu","on":false,"style":"text"},{"stat":"ram","on":false,"style":"text"},{"stat":"disk","on":true,"style":"graph"},{"stat":"bluetooth","on":true,"style":"text"}],"combined":false}"#
        let s = BarSettings.migrated(stats: try Self.stats(json), topBar: nil, pomodoroCountdown: nil)
        #expect(s.entries.filter { $0.kind.group == .readings }.map(\.kind) == [.network, .cpu, .heat, .graphics, .memory, .storage])
        #expect(s.entry(.network).style == .graph && s.entry(.cpu).style == .graph && s.entry(.heat).style == .text)
        // Storage has no graph in round 4: its saved read-and-write graph shows as text.
        #expect(s.entry(.storage).on && s.entry(.storage).style == .text)
        #expect(s.entry(.battery).on && s.entry(.bluetoothBatteries).on && !s.entry(.group).on && !s.combineProcesses)
    }

    @Test("A saved top bar layout keeps its items, sides, order, styles and clock pattern; the menu bar keeps what it showed")
    func topBarKept() throws {
        let saved = #"{"standard":{"left":[{"module":"workspaces","style":"text"},{"module":"focusedApp"}],"centre":[{"module":"cpu","style":"graph"},{"module":"clock"}],"right":[{"module":"volume","style":"compact"},{"module":"menuApps","style":"text"},{"module":"inputSource","style":"text"}]},"screens":{},"clock":"HH:mm:ss"}"#
        let topBar = try JSONDecoder().decode(TopBarSettings.self, from: Data(saved.utf8))
        let s = BarSettings.migrated(stats: try Self.stats(), topBar: topBar, pomodoroCountdown: nil)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .left).map(\.kinds) == [[.pilot], [.workspaces], [.focusedApp]])
        #expect(s.slots(in: .topBar, topBarOn: true, side: .centre).map(\.kinds) == [[.cpu], [.clock]])
        #expect(s.slots(in: .topBar, topBarOn: true, side: .right).map(\.kinds) == [[.volume], [.otherApps], [.keyboardLayout]])
        #expect(s.entry(.workspaces).style == .withApp && s.entry(.focusedApp).style == .iconName && s.entry(.volume).style == .iconPercent)
        #expect(s.entry(.keyboardLayout).style == .name && s.entry(.otherApps).style == .icons && s.entry(.clock).style == .time)
        #expect(s.clock.rawValue == "HH:mm:ss")
        // CPU was in both, so it is placed in both; Memory only in the menu bar; the clock only in the top bar.
        #expect(s.entry(.cpu).placement == .both && s.entry(.memory).placement == .menuBar && s.entry(.clock).placement == .topBar)
        // CPU's top bar graph wins over its menu bar text: one item, one style.
        #expect(s.entry(.cpu).style == .graph)
        // Things the saved layout left out stay out of the top bar.
        #expect(s.entry(.timer).placement == .menuBar && s.entry(.pilot).placement == .menuBar)
        #expect(s.slots(in: .menuBar, topBarOn: false).map(\.kinds) == [[.pilot], [.workspaces], [.cpu, .memory], [.timer]])
        #expect(s.slots(in: .menuBar, topBarOn: true).map(\.kinds) == [[.pilot], [.memory], [.timer]])
    }

    @Test("A saved side naming an item twice keeps it once, in its first place, and loses no other item")
    func twiceNamed() throws {
        let saved = #"{"standard":{"left":[{"module":"clock"},{"module":"workspaces"}],"centre":[],"right":[{"module":"clock"},{"module":"cpu"}]},"screens":{},"clock":"HH:mm"}"#
        let s = BarSettings.migrated(stats: nil, topBar: try JSONDecoder().decode(TopBarSettings.self, from: Data(saved.utf8)), pomodoroCountdown: nil)
        #expect(s.entries.count == 29 && Set(s.entries.map(\.kind)) == Set(BarKind.allCases))
        #expect(s.entries.firstIndex { $0.kind == .clock }! < s.entries.firstIndex { $0.kind == .workspaces }!)
    }

    @Test("The old clock default carries as its look, the old top bar's default as its items")
    func oldClockDefault() throws {
        let s = BarSettings.migrated(stats: nil, topBar: TopBarSettings(), pomodoroCountdown: nil)
        #expect(s.entry(.clock).style == .time && s.clock == .dateTime24)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .left).map(\.kinds) == [[.pilot], [.workspaces]])
        #expect(s.slots(in: .topBar, topBarOn: true, side: .right).map(\.kinds) == [[.clock]])
    }

    @Test("Countdown in menu bar off carries as the Timer item off (its raw value is still pomodoro)")
    func pomodoroOff() {
        #expect(!BarSettings.migrated(stats: nil, topBar: nil, pomodoroCountdown: false).entry(.timer).on)
        #expect(BarSettings.migrated(stats: nil, topBar: nil, pomodoroCountdown: nil) == .defaults)
    }

    @Test("Saved settings come back as they were; an item a later Pilot added is skipped, one this Pilot added joins off (Extensions on, story 161; the bar drops' items on, spec Bar drops T4), a bad style takes the first")
    func savedLossy() throws {
        var s = BarSettings.defaults
        s.set(.heat, on: true)
        s.set(.heat, style: .graph)
        s.move(.heat, to: 0)
        s.clock = .time12
        s.clockZone = "America/New_York"
        s.clockEvents = true
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(BarSettings.self, from: data) == s)
        let odd = #"{"entries":[{"kind":"cpu","on":true,"style":"dots","placement":"both","side":"right"},{"kind":"weather","on":true,"style":"icon","placement":"both","side":"right"}],"clock":"HH:mm","combineProcesses":false}"#
        let read = try JSONDecoder().decode(BarSettings.self, from: Data(odd.utf8))
        #expect(read.entries.count == 29 && read.entries.first?.kind == .cpu && read.entry(.cpu).style == .text && !read.clockEvents)
        #expect(read.entries.dropFirst().allSatisfy { !$0.on || $0.kind == .pilot || $0.kind == .extensions || $0.kind.drop != nil } && read.entry(.extensions).on)
        #expect(read.entry(.terminal).on && read.entry(.askAI).on)
    }

    @Test("Heat draws a graph from its temperatures, 0 to 100 °C")
    func heatGraph() {
        let history = [40.0, 50.0, nil].map {
            SystemStats.Values(cpu: nil, ram: 0, gpu: nil, down: nil, up: nil, cores: nil, diskRead: nil, diskWrite: nil, heat: $0)
        }
        #expect(MenuBarStats.graph(.sensors, history: history) == [0.4, 0.5, 0])
        #expect(MenuBarStats.Stat.sensors.graphable)
    }

    /// Sven's bar.items as saved on his Mac on 2026-10-08 (defaults export dev.banozz.pilot): Pilot placed menuBar.
    static let svensItems = #"{"clock":"HH:mm","entries":[{"on":true,"placement":"menuBar","side":"left","style":"iconNumber","kind":"pilot"},{"on":true,"placement":"both","side":"left","style":"numbers","kind":"workspaces"},{"on":false,"placement":"menuBar","side":"left","style":"icon","kind":"focusedApp"},{"on":false,"placement":"topBar","side":"right","style":"flexible","kind":"spacer"},{"on":true,"placement":"topBar","side":"right","style":"icons","kind":"otherApps"},{"on":true,"placement":"menuBar","side":"right","style":"allInOne","kind":"group"},{"on":true,"placement":"both","side":"right","style":"text","kind":"cpu"},{"on":false,"placement":"menuBar","side":"right","style":"text","kind":"graphics"},{"on":true,"placement":"both","side":"right","style":"text","kind":"memory"},{"on":true,"placement":"both","side":"right","style":"text","kind":"storage"},{"on":true,"placement":"both","side":"right","style":"text","kind":"heat"},{"on":false,"placement":"menuBar","side":"right","style":"text","kind":"network"},{"on":false,"placement":"topBar","side":"right","style":"iconPercent","kind":"battery"},{"on":false,"placement":"topBar","side":"right","style":"iconPercent","kind":"bluetoothBatteries"},{"on":false,"placement":"both","side":"right","style":"icon","kind":"keepAwake"},{"on":true,"placement":"both","side":"right","style":"icon","kind":"volume"},{"on":true,"placement":"topBar","side":"right","style":"code","kind":"keyboardLayout"},{"on":false,"placement":"both","side":"right","style":"icon","kind":"wifi"},{"on":true,"placement":"topBar","side":"centre","style":"countdown","kind":"pomodoro"},{"on":true,"placement":"both","side":"centre","style":"dateTime","kind":"clock"},{"on":false,"placement":"both","side":"right","style":"line","kind":"divider"}],"combineProcesses":true}"#

    @Test("Pilot's icon is the top bar's first left item while it is on, whatever its placement or side, and stays in the menu bar (card agent-bo-95423009)")
    func pilotInTopBar() throws {
        var s = try JSONDecoder().decode(BarSettings.self, from: Data(Self.svensItems.utf8))
        #expect(s.entry(.pilot).placement == .menuBar)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .left).map(\.kinds) == [[.pilot], [.workspaces]])
        #expect(s.slots(in: .topBar, topBarOn: false, side: .left).isEmpty)
        #expect(s.slots(in: .topBar, topBarOn: true).first?.kinds == [.pilot])
        #expect(s.slots(in: .menuBar, topBarOn: false).first?.kinds == [.pilot])
        // Moved or reordered, it stays first on the left; its click is the dropdown's popover.
        s.move(.pilot, to: TopBarSide.right)
        s.move(.pilot, to: 5)
        #expect(s.slots(in: .topBar, topBarOn: true, side: .left).first?.kinds == [.pilot])
        #expect(s.slots(in: .topBar, topBarOn: true, side: .right).allSatisfy { $0.kinds != [.pilot] })
        #expect(s.slots(in: .topBar, topBarOn: true, side: .left).first?.click == .popover)
        // Saved on the right by an earlier Pilot, it comes back on the left.
        let right = Self.svensItems.replacingOccurrences(of: #""side":"left","style":"iconNumber""#, with: #""side":"right","style":"iconNumber""#)
        #expect(right != Self.svensItems)
        let saved = try JSONDecoder().decode(BarSettings.self, from: Data(right.utf8))
        #expect(saved.entry(.pilot).side == .left && saved.slots(in: .topBar, topBarOn: true, side: .left).first?.kinds == [.pilot])
    }

    @Test("The user's saved layout, from before the bar drops, loads whole and gains Terminal and Ask AI on, in the bar's middle before the clock (spec Bar drops T4)")
    func dropsJoinSavedLayout() throws {
        let s = try JSONDecoder().decode(BarSettings.self, from: Data(Self.svensItems.utf8))
        #expect(s.entries.count == 29 && Set(s.entries.map(\.kind)) == Set(BarKind.allCases))
        #expect(s.slots(in: .topBar, topBarOn: true, side: .centre).map(\.kinds) == [[.timer], [.terminal], [.askAI], [.clock]])
        #expect(s.entry(.terminal).style == .iconName && s.entry(.askAI).placement == .topBar)
        // Never in the macOS menu bar: the drops hang from the top bar. A click is the top bar's own (TopBarDropItem).
        #expect(s.slots(in: .menuBar, topBarOn: false).allSatisfy { $0.kind.drop == nil })
        #expect(BarKind.terminal.drop == .terminal && BarKind.askAI.drop == .askAI && BarKind.terminal.click == .none)
        // Turned off and saved, they stay off.
        var off = s
        off.set(.terminal, on: false)
        let again = try JSONDecoder().decode(BarSettings.self, from: try JSONEncoder().encode(off))
        #expect(!again.entry(.terminal).on && again.entry(.askAI).on)
    }

    @Test("A click opens the item's popover (Power's, the keyboard layout's and Displays' too); Capture its menu; Keep awake switches, Option-click mutes, spacers do nothing")
    func clicks() {
        #expect(BarKind.allCases.filter { $0.click == .popover } == [.pilot, .workspaces, .focusedApp, .cpu, .memory, .network, .graphics, .storage, .heat,
                                                                      .battery, .bluetoothBatteries, .power, .volume, .keyboardLayout, .wifi, .displays, .modes,
                                                                      .clock, .timer, .extensions, .group])
        #expect(BarKind.keepAwake.click == .toggleKeepAwake && !BarKind.allCases.contains { $0.click == .cycleLayout })
        // Capture opens its menu, and it alone.
        #expect(BarKind.allCases.filter { $0.click == .menu } == [.capture])
        // Volume opens its Sound popover; Option-click mutes, and only Volume has an Option-click.
        #expect(BarClick([.volume], isGroup: false, option: true) == .toggleMute && BarClick([.volume], isGroup: false) == .popover)
        #expect(BarKind.allCases.filter { $0.optionClick != nil } == [.volume] && BarClick([.cpu], isGroup: false, option: true) == .popover)
        // The group opens its popover even with one reading in it; an item does what its kind does.
        let s = BarSettings.defaults
        #expect(BarSlot.group([s.entry(.cpu)]).click == .popover && BarSlot.group([s.entry(.cpu)]).isGroup)
        #expect(BarSlot.item(s.entry(.keepAwake)).click == .toggleKeepAwake && !BarSlot.item(s.entry(.cpu)).isGroup)
    }
}
