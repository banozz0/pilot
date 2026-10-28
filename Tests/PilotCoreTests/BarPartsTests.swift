import Foundation
@testable import PilotCore
import Testing

/// Every bar item drawn in each of its styles (card agent-bo-95422911): parts from fixed readings, the same for the
/// macOS menu bar and the top bar; a reading this Mac lacks draws nothing.
@Suite("Bar parts")
struct BarPartsTests {
    /// A Mac with every reading: two ticks of CPU, RAM, GPU, network, disk, sensors, a battery and earbuds.
    static var inputs: BarInputs {
        var i = BarInputs()
        i.pilotTitle = "2"
        i.workspaces = ["1", "2", "4"]
        i.focusedWorkspace = "2"
        i.firstApp = ["2": "Zen"]
        i.focusedApp = "Zen"
        let memory = SystemStats.Memory(total: 1, pageSize: 1, active: 0, inactive: 0, speculative: 0, wired: 0, compressed: 0, purgeable: 0,
                                        external: 0, pressure: .normal, swapUsed: 0, swapTotal: 0)
        var raw = SystemStats.Raw(time: 0, cpu: .init(user: 0, system: 0, idle: 0, nice: 0), memory: memory, network: .init(received: 0, sent: 0),
                                  battery: nil, thermal: .nominal, uptime: 0, gpu: nil)
        raw.slow.disk = .init(available: 280, total: 1000)
        raw.slow.bluetooth = [.init(name: "AirPods Pro", level: "72 %"), .init(name: "Mouse", level: "40 %")]
        raw.sensors = .init(temperatures: ["Tp01": 52], fans: [], power: nil)
        raw.battery = .init(percent: 88, charging: true, minutesLeft: 30)
        i.latest = raw
        i.battery = raw.battery
        i.bluetooth = raw.slow.bluetooth
        i.values = .init(cpu: 0.23, ram: 0.61, gpu: 0.08, down: 2_100_000, up: 140_000, cores: nil, diskRead: 0, diskWrite: 0, heat: 52)
        i.history = [0.1, 0.3, 0.2].map { .init(cpu: $0, ram: 0.6, gpu: 0.1, down: $0 * 1e6, up: 0, cores: nil, diskRead: 0, diskWrite: 0, heat: 50) }
        i.keepAwake = true
        i.keepAwakeLeft = 3600
        i.statusLights = [StatusLight(id: "a", family: .agent, state: .working, title: "Agent", source: "Ghostex")]
        i.volume = 0.5
        i.muted = false
        i.output = "Speakers"
        i.keyboardLayout = "British – PC"
        i.wifiOn = true
        i.wifiSignal = -55
        i.now = Date(timeIntervalSince1970: 1_791_158_400 + 22 * 3600 + 14 * 60)   // Mon 5 Oct 2026 22:14 UTC
        i.timeZone = TimeZone(identifier: "UTC")!
        i.locale = Locale(identifier: "en_GB")
        i.timerCountdown = "18:42"
        i.timerLeft = 0.75
        i.extensionBars = [ExtensionBarFace(id: "ai", title: "AI", answer: Extension.BarAnswer(text: "AI 52%"))]
        return i
    }

    static func parts(_ kind: BarKind, _ style: BarStyle, _ i: BarInputs = inputs, zone: String? = nil) -> [BarPart]? {
        var s = BarSettings.defaults
        s.set(kind, style: style)
        return BarParts.parts(s.entry(kind), i, clock: .time24, zone: zone)
    }

    @Test("Every item draws something in every style from a full set of readings; other apps, app menus and the group draw elsewhere")
    func everyStyle() {
        for kind in BarKind.allCases where ![.otherApps, .appMenus, .group].contains(kind) {
            for style in kind.styles {
                let parts = Self.parts(kind, style)
                #expect(parts?.isEmpty == false, "\(kind) \(style)")
            }
        }
    }

    @Test("Styles look as round 4 draws them")
    func looks() {
        #expect(Self.parts(.pilot, .iconNumber) == [.mark, .value("2")])
        #expect(Self.parts(.pilot, .number) == [.badge("2")])
        #expect(Self.parts(.workspaces, .numbers) == [.workspaces(["1", "2", "4"], current: "2", app: nil)])
        #expect(Self.parts(.workspaces, .dots) == [.dots(count: 3, current: 1)])
        #expect(Self.parts(.workspaces, .current) == [.badge("2")])
        #expect(Self.parts(.workspaces, .withApp) == [.workspaces(["1", "2", "4"], current: "2", app: "Zen")])
        #expect(Self.parts(.focusedApp, .icon) == [.app(name: "Zen", showsName: false)])
        #expect(Self.parts(.cpu, .text) == [.reading(.cpu), .value("23%", widest: "100%")])
        // Points to the 28 steps a 12-point line shows.
        #expect(Self.parts(.cpu, .graph) == [.reading(.cpu), .graph([3, 8, 6].map { $0 / 28 })])
        #expect(Self.parts(.memory, .bar) == [.reading(.ram), .bar(0.61)])
        #expect(Self.parts(.storage, .bar) == [.reading(.disk), .bar(0.72)])
        #expect(Self.parts(.network, .text) == [.reading(.network), .value("↓2.1M ↑140K", widest: "↓999.9M ↑999.9M")])
        #expect(Self.parts(.heat, .text) == [.reading(.sensors), .value("52°", widest: "100°")])
        #expect(Self.parts(.battery, .iconPercent) == [.symbol("battery.100.bolt"), .value("88%", widest: "100%")])
        #expect(Self.parts(.bluetoothBatteries, .iconPercent) == [.symbol("headphones"), .value("40%")])
        // Low as the battery is: the warning at 20 %, amber, then red at 10; earbuds by their lowest bud.
        for (level, marks) in [("19 %", [BarPart.warn, .level(.high)]), ("L 9 % · R 80 % · case 100 %", [.warn, .level(.critical)])] {
            var low = Self.inputs
            low.bluetooth.append(.init(name: "Keychron", level: level, fromProfiler: level.hasPrefix("L")))
            #expect(Self.parts(.bluetoothBatteries, .iconPercent, low)?.dropFirst(2).map { $0 } == marks, "\(level)")
        }
        #expect(Self.parts(.keepAwake, .iconTime) == [.symbol("cup.and.saucer.fill"), .value("1h")])
        #expect(Self.parts(.volume, .iconPercent) == [.symbol("speaker.wave.2"), .value("50 %", widest: "100 %")])
        #expect(Self.parts(.volume, .output) == [.symbol("speaker.wave.2"), .text("Speakers")])
        #expect(Self.parts(.keyboardLayout, .code) == [.badge("BR")])
        #expect(Self.parts(.wifi, .strength) == [.symbol("wifi"), .strength(3)])
        #expect(Self.parts(.clock, .time) == [.time("22:14")])
        #expect(Self.parts(.clock, .dateTime) == [.date("Mon 5 Oct"), .time("22:14")])
        #expect(Self.parts(.clock, .twoZones, zone: "America/New_York") == [.time("22:14"), .label("New York"), .text("18:14")])
        #expect(Self.parts(.timer, .countdown) == [.ring(0.75), .value("18:42", widest: "88:88")])
        #expect(Self.parts(.timer, .ring) == [.ring(0.75)])
        #expect(Self.parts(.spacer, .flexible) == [.space(40)])
    }

    /// Q231 (Sven 2026-10-17): the clock shows day, date and time by default. The date + time style adds the day and
    /// date before the time pattern, so the pattern stays the time alone and the 12 h choice still holds.
    @Test("By default the clock reads Sat 17 Oct 09:05: the date + time style on the 24 h pattern; 12 h keeps the date")
    func clockDefault() throws {
        var i = Self.inputs
        i.now = Date(timeIntervalSince1970: 1_792_195_200 + 9 * 3600 + 5 * 60)   // Sat 17 Oct 2026 09:05 UTC
        let fresh = BarSettings.defaults
        #expect(fresh.entry(.clock).style == .dateTime && fresh.clock == .time24)
        #expect(BarParts.parts(.item(fresh.entry(.clock)), i, settings: fresh) == [[.date("Sat 17 Oct"), .time("09:05")]])
        // Sven's saved bar (style dateTime, pattern HH:mm) reads the same; the 12 h choice keeps the day and date.
        let saved = try JSONDecoder().decode(BarSettings.self, from: Data(BarItemsTests.svensItems.utf8))
        #expect(BarParts.parts(.item(saved.entry(.clock)), i, settings: saved) == [[.date("Sat 17 Oct"), .time("09:05")]])
        var twelve = saved
        twelve.clock = .time12
        #expect(BarParts.parts(.item(twelve.entry(.clock)), i, settings: twelve) == [[.date("Sat 17 Oct"), .time("9:05 am")]])
    }

    @Test("The clock's date and time are one hit target, its popover (SPEC story 168)")
    func clockTargets() throws {
        let parts = try #require(Self.parts(.clock, .dateTime))
        #expect(BarParts.targets([parts], click: .popover) == [BarTarget(parts: [[.date("Mon 5 Oct"), .time("22:14")]], click: .popover)])
        // Anything else is one target doing the item's click.
        let cpu = try #require(Self.parts(.cpu, .text))
        #expect(BarParts.targets([cpu], click: .popover) == [BarTarget(parts: [cpu], click: .popover)])
        #expect(BarParts.targets([cpu, cpu], click: .popover) == [BarTarget(parts: [cpu, cpu], click: .popover)])
    }

    @Test("Pilot's icon is a warning while Accessibility is missing, whatever its style")
    func pilotAlert() {
        var i = Self.inputs
        i.pilotAlert = true
        #expect(BarKind.pilot.styles.allSatisfy { Self.parts(.pilot, $0, i) == [.symbol("exclamationmark.triangle")] })
    }

    @Test("A Mac with no battery shows the watts it draws in the battery's place; its tooltip says so")
    func watts() {
        var i = BarInputs()
        i.watts = 37
        #expect(Self.parts(.battery, .iconPercent, i) == [.symbol("bolt"), .value("37 W", widest: "000 W")])
        #expect(Self.parts(.battery, .icon, i) == [.symbol("bolt")])
        #expect(BarTooltip.text(.item(BarSettings.defaults.entry(.battery)), i) == "This Mac draws 37 W")
        i.battery = .init(percent: 88, charging: false, minutesLeft: nil)
        #expect(Self.parts(.battery, .iconPercent, i)?.first != .symbol("bolt"), "a battery wins")
    }

    @Test("A reading this Mac lacks takes no room; idle items show their symbol")
    func missing() {
        var i = BarInputs()
        for kind in [BarKind.graphics, .battery, .bluetoothBatteries, .focusedApp, .workspaces] {
            #expect(Self.parts(kind, kind.styles[0], i) == nil, "\(kind)")
        }
        #expect(Self.parts(.timer, .countdown, i) == [.symbol("timer")])
        #expect(Self.parts(.keepAwake, .iconTime, i) == [.symbol("cup.and.saucer")])
        #expect(Self.parts(.wifi, .strength, i) == [.symbol("wifi.slash")])
        // Two zones with no second zone set shows the time here only.
        i.now = Self.inputs.now
        i.timeZone = Self.inputs.timeZone
        #expect(Self.parts(.clock, .twoZones, i)?.count == 1)
    }

    @Test("The group draws each reading on in its own style, and nothing when none has a reading")
    func group() {
        var s = BarSettings.defaults
        s.set(.memory, style: .graph)
        let entries = [s.entry(.cpu), s.entry(.memory), s.entry(.graphics)]
        #expect(BarParts.group(entries, Self.inputs) == [[.reading(.cpu), .value("23%", widest: "100%")], [.reading(.ram), .graph([17, 17, 17].map { $0 / 28 })],
                                                         [.reading(.gpu), .value("8%", widest: "100%")]])
        #expect(BarParts.group([s.entry(.graphics)], BarInputs()) == nil)
    }

    @Test("Status lights: its symbol wherever its dots are not drawn, its tooltip the lit count, a click its popover")
    func modes() {
        var i = BarInputs()
        let entry = BarSettings.defaults.entry(.modes)
        #expect(BarParts.parts(entry, i) == [.symbol(BarParts.statusSymbol)])
        #expect(BarTooltip.text(.modes, i) == "Status lights: nothing lit")
        i.statusLights = [StatusLight(id: "a", family: .agent, state: .waiting, title: "Coordinator", source: "Ghostex"),
                          StatusLight(id: "m", family: .privacy, state: .watching, title: "Zoom", source: "microphone")]
        #expect(BarTooltip.text(.modes, i) == "1 waiting on you, 1 in use")
        // One target, its popover, in the top bar alone, left of the clock; its raw value is the Mode lights' it replaced.
        #expect(BarKind.modes.title == "Status lights" && BarKind.modes.rawValue == "modes")
        #expect(BarKind.modes.click == .popover && BarKind.modes.topBarOnly && entry.on && entry.side == .centre && entry.placement == .topBar)
        let kinds = BarSettings.defaults.entries.map(\.kind)
        #expect(kinds.firstIndex(of: .modes)! + 1 == kinds.firstIndex(of: .clock)!)
    }

    @Test("A saved layout gains Status lights off, just before its clock and on the clock's side, for edit mode to place")
    func modesJoin() throws {
        var s = BarSettings.defaults
        s.set(.clock, side: .right)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        json["entries"] = (json["entries"] as! [[String: Any]]).filter { $0["kind"] as? String != "modes" }
        let read = try JSONDecoder().decode(BarSettings.self, from: JSONSerialization.data(withJSONObject: json))
        let kinds = read.entries.map(\.kind)
        #expect(kinds.firstIndex(of: .modes)! + 1 == kinds.firstIndex(of: .clock)!)
        #expect(!read.entry(.modes).on && read.entry(.modes).side == .right)
    }

    @Test("Wi-Fi's four bars and Keep awake's time left")
    func steps() {
        #expect([-40, -55, -65, -80].map(BarParts.wifiBars) == [4, 3, 2, 1])
        #expect([3600, 12_000, 700].map { BarParts.duration(TimeInterval($0)) } == ["1h", "3h 20m", "12m"])
    }
}
