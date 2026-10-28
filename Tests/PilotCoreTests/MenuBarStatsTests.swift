import Foundation
import Testing
@testable import PilotCore

/// This Mac in the menu bar (card agent-bo-95422833): Stats' menu-bar choices carried into Pilot's, read only, and what
/// each item shows. Fixtures only.
@Suite("Menu-bar stats")
struct MenuBarStatsTests {
    /// Sven's eu.exelban.Stats on 2026-10-05, the keys that matter (defaults read eu.exelban.Stats).
    nonisolated(unsafe) static let svensStats: [String: Any] = [
        "Battery_state": 0, "Bluetooth_position": 6, "CPU_position": 0, "CPU_state": 1, "Clock_position": 8, "CombinedModules": 1,
        "Disk_position": 3, "Disk_state": 0, "GPU_position": 1, "GPU_state": 0, "Network_position": 5, "Network_state": 0,
        "RAM_position": 2, "Remote_position": 7, "Sensors_position": 4, "Sensors_state": 0, "Sensors_widget": "mini",
        "RAM_combinedProcesses": 1,
    ]

    @Test("The user's Stats gives CPU and RAM (RAM is on by Stats' own default), CPU first, as text, in one combined item")
    func svensChoices() {
        let choices = MenuBarStats.fromStats(Self.svensStats)
        #expect(choices.items.filter(\.on).map(\.stat) == [.cpu, .ram])
        #expect(choices.items.map(\.stat).prefix(4) == [.cpu, .gpu, .ram, .disk])
        #expect(choices.items.allSatisfy { $0.style == .text })
        #expect(choices.combined && choices.combineProcesses)
        #expect(Set(choices.items.map(\.stat)) == Set(MenuBarStats.Stat.allCases))
    }

    @Test("With nothing in Stats' domain, Stats' defaults: CPU, RAM, disk, network and battery on, each its own item")
    func statsDefaults() {
        let choices = MenuBarStats.fromStats([:])
        #expect(choices.items.filter(\.on).map(\.stat) == [.cpu, .ram, .disk, .network, .battery])
        #expect(!choices.combined)
        #expect(choices == MenuBarStats.Choices.statsDefaults)
    }

    @Test("Stats' widget maps to a style: its charts to a graph, its text, label and value widgets to text")
    func widgets() {
        let choices = MenuBarStats.fromStats(["CPU_widget": "line_chart", "RAM_widget": "bar_chart", "Network_widget": "network_chart",
                                              "Battery_widget": "battery", "GPU_widget": "line_chart", "Disk_widget": "mini"])
        let style = { (stat: MenuBarStats.Stat) in choices.items.first { $0.stat == stat }?.style }
        #expect(style(.cpu) == .graph && style(.ram) == .graph && style(.network) == .graph && style(.gpu) == .graph)
        #expect(style(.battery) == .text && style(.disk) == .text)
        // Stats keeps a module's widgets as a comma-separated list (Kit/module/widget.swift): any chart in it is a graph.
        let listed = MenuBarStats.fromStats(["CPU_widget": "label,line_chart", "RAM_widget": "mini,label", "GPU_widget": "pie_chart"])
        #expect(listed.items.first { $0.stat == .cpu }?.style == .graph)
        #expect(listed.items.first { $0.stat == .ram }?.style == .text)
        // A pie chart or a gauge shows the value now, not a line over time: text.
        #expect(listed.items.first { $0.stat == .gpu }?.style == .text)
        // A chart on a reading with no graph (Bluetooth) stays text.
        #expect(MenuBarStats.fromStats(["Bluetooth_widget": "bar_chart"]).items.first { $0.stat == .bluetooth }?.style == .text)
    }

    static func raw() -> SystemStats.Raw {
        var raw = SystemStatsTests.raw(time: 2)
        raw.battery = .init(percent: 81, charging: false, minutesLeft: nil)
        raw.sensors = .init(temperatures: ["Tp01": 59.6, "Tp05": 64.9], fans: [], power: nil)
        raw.slow.bluetooth = [.init(name: "MX Keys", level: "60 %")]
        return raw
    }
    static let values = SystemStats.Values(cpu: 0.123, ram: 0.58, gpu: 0.18, down: 1_234_000, up: 40_000, cores: nil,
                                           diskRead: 2_000_000, diskWrite: 0)

    @Test("Item colours' levels (Sven, Q251): CPU, GPU and RAM high at 70 % and critical at 90 %, the disk at 85 and 95 %, the heat at 80 and 95 °C; the battery the other way, 20 and 10 %, never while charging; network none")
    func levels() {
        func load(_ share: Double) -> SystemStats.Values {
            SystemStats.Values(cpu: share, ram: share, gpu: share, down: 1, up: 1, cores: nil, diskRead: nil, diskWrite: nil, heat: nil)
        }
        for stat in [MenuBarStats.Stat.cpu, .gpu, .ram] {
            #expect([0, 0.69, 0.7, 0.89, 0.9, 1].map { MenuBarStats.level(stat, values: load($0), raw: nil) }
                    == [.normal, .normal, .high, .high, .critical, .critical], "\(stat)")
        }
        let disk = { (used: Int64) -> MenuBarStats.Level in
            var raw = Self.raw()
            raw.slow.disk = .init(available: 100 - used, total: 100)
            return MenuBarStats.level(.disk, values: Self.values, raw: raw)
        }
        #expect([Int64(84), 85, 94, 95, 100].map(disk) == [MenuBarStats.Level.normal, .high, .high, .critical, .critical])
        let heat = { (c: Double) in
            MenuBarStats.level(.sensors, values: SystemStats.Values(cpu: 0, ram: 0, gpu: 0, down: 0, up: 0, cores: nil, diskRead: nil, diskWrite: nil, heat: c), raw: nil)
        }
        #expect([79.9, 80, 94.9, 95, 105].map(heat) == [.normal, .high, .high, .critical, .critical])
        #expect(MenuBarStats.level(.cpu, values: nil, raw: nil) == .normal)
        #expect(MenuBarStats.level(.network, values: load(1), raw: nil) == .normal)
        let battery = { (percent: Int, charging: Bool) in MenuBarStats.level(SystemStats.Battery(percent: percent, charging: charging, minutesLeft: nil)) }
        #expect([21, 20, 11, 10, 3].map { battery($0, false) } == [.normal, .high, .high, .critical, .critical])
        #expect(battery(3, true) == .normal)
    }

    @Test("A reading carries its level as a part only past normal, beside the old amber warning; Item colours reads it")
    func levelPart() {
        var i = BarInputs()
        i.values = SystemStats.Values(cpu: 1, ram: 0.75, gpu: 0.1, down: 0, up: 0, cores: nil, diskRead: nil, diskWrite: nil)
        #expect(BarParts.reading(.cpu, style: .text, i)?.contains(.level(.critical)) == true)
        #expect(BarParts.reading(.cpu, style: .text, i)?.contains(.warn) == true)
        #expect(BarParts.reading(.ram, style: .text, i)?.contains(.level(.high)) == true)
        #expect(BarParts.reading(.ram, style: .text, i)?.contains(.warn) == false)
        #expect(BarParts.reading(.gpu, style: .text, i)?.contains { if case .level = $0 { true } else { false } } == false)
    }

    @Test("Each item's text: short, the reading's label first; a reading the Mac lacks gives none, one not read yet a dash")
    func text() {
        let raw = Self.raw()
        let text = { (stat: MenuBarStats.Stat) in MenuBarStats.text(stat, values: Self.values, raw: raw) }
        #expect(text(.cpu) == "CPU 12%")
        #expect(text(.gpu) == "GPU 18%")
        #expect(text(.ram) == "RAM 58%")
        #expect(text(.disk) == "SSD 76%")          // used: 494 GB less 120 GB free
        #expect(text(.network) == "↓1.2M ↑40K")
        #expect(text(.battery) == "BAT 81%")
        #expect(text(.sensors) == "TEMP 62°")
        #expect(text(.bluetooth) == "MX Keys 60%")
        var bare = SystemStatsTests.raw(time: 0)
        bare.gpu = nil
        #expect(MenuBarStats.text(.battery, values: nil, raw: bare) == nil)
        #expect(MenuBarStats.text(.sensors, values: nil, raw: bare) == nil)
        #expect(MenuBarStats.text(.bluetooth, values: nil, raw: bare) == nil)
        #expect(MenuBarStats.text(.gpu, values: nil, raw: bare) == nil)
        #expect(MenuBarStats.text(.cpu, values: nil, raw: bare) == "CPU –")
        #expect(MenuBarStats.text(.cpu, values: nil, raw: nil) == "CPU –")
    }

    @Test("A graph's points run 0 to 1: shares as they are, rates against the busiest moment in view")
    func graph() {
        func v(cpu: Double?, down: Double?) -> SystemStats.Values {
            .init(cpu: cpu, ram: 0.5, gpu: nil, down: down, up: 0, cores: nil, diskRead: nil, diskWrite: nil)
        }
        let history = [v(cpu: 0.1, down: 100), v(cpu: nil, down: 400), v(cpu: 0.7, down: 200)]
        #expect(MenuBarStats.graph(.cpu, history: history) == [0.1, 0, 0.7])
        #expect(MenuBarStats.graph(.network, history: history) == [0.25, 1, 0.5])
        #expect(MenuBarStats.graph(.ram, history: history) == [0.5, 0.5, 0.5])
        #expect(MenuBarStats.graph(.network, history: [v(cpu: 0, down: 0)]) == [0])
        #expect(MenuBarStats.Stat.bluetooth.graphable == false && MenuBarStats.Stat.cpu.graphable)
    }
}

extension MenuBarStatsTests {
    @Test("An item's popup shows This Mac's rows for its reading; Bluetooth's are the device rows")
    func popupRows() {
        var raw = Self.raw()
        raw.slow.disk = .init(available: 1, total: 2)
        let rows = SystemStats.rows(previous: nil, now: raw)
        #expect(MenuBarStats.rows(.ram, in: rows).map(\.name) == ["RAM", "RAM use", "Swap"])
        #expect(MenuBarStats.rows(.disk, in: rows).map(\.name) == ["Disk"])
        #expect(MenuBarStats.rows(.sensors, in: rows).map(\.name) == ["Heat", "SoC heat", "CPU heat"])
        #expect(MenuBarStats.rows(.bluetooth, in: rows).map(\.name) == ["MX Keys"])
        #expect(MenuBarStats.rows(.battery, in: rows).map(\.name) == ["Battery"])
    }

    @Test("A Mac with no battery shows its draw in the battery's place: the item's value, a Power draw row, and the Power row moved out of Heat")
    func powerDraw() {
        var raw = Self.raw()
        raw.battery = nil
        raw.systemPower = 36.78
        raw.sensors = .init(temperatures: ["Tp01": 59.6], fans: [], power: 36.78)
        #expect(MenuBarStats.text(.battery, values: Self.values, raw: raw) == "PWR 37 W")
        #expect(MenuBarStats.value(.battery, values: Self.values, raw: raw) == "37 W")
        let rows = SystemStats.rows(previous: nil, now: raw)
        #expect(MenuBarStats.rows(.battery, in: rows).map(\.name) == ["Power draw"])
        #expect(MenuBarStats.rows(.battery, in: rows).first?.value == "36.8 W")
        #expect(!MenuBarStats.rows(.sensors, in: rows).map(\.name).contains("Power"), "shown once, as Power draw")
        raw.systemPower = nil
        raw.sensors = nil
        #expect(MenuBarStats.text(.battery, values: Self.values, raw: raw) == nil, "no reading: the item hides")
        #expect(MenuBarStats.rows(.battery, in: SystemStats.rows(previous: nil, now: raw)).isEmpty)
    }

    @Test("A Mac is named for what its battery item shows: Battery with one, Power draw without")
    func powerDrawName() {
        let named = SystemStats.hasBattery ? "Battery" : "Power draw"
        #expect(BarKind.battery.title == named && MenuBarStats.Stat.battery.title == named)
        #expect(MenuBarStats.Stat.battery.short == (SystemStats.hasBattery ? "BAT" : "PWR"))
    }
}
