import Foundation

/// This Mac in the menu bar (card agent-bo-95422833, Sven 2026-10-05: "we should have ability to show these in menubar
/// so this app even replaces stats app for me"): each reading can be its own menu-bar item, as text or a mini graph, or
/// all in one item; the first start takes Stats' (exelban/stats, MIT) own choices from its preferences, read only.
public enum MenuBarStats {
    /// The readings an item can show, one per Stats module that has a menu-bar widget (Clock and Remote are left out).
    public enum Stat: String, CaseIterable, Codable, Sendable {
        case cpu, gpu, ram, disk, sensors, network, battery, bluetooth

        /// The module's name in Stats' preferences (CPU_state, RAM_position …).
        public var statsModule: String {
            switch self {
            case .cpu: "CPU"
            case .gpu: "GPU"
            case .ram: "RAM"
            case .disk: "Disk"
            case .sensors: "Sensors"
            case .network: "Network"
            case .battery: "Battery"
            case .bluetooth: "Bluetooth"
            }
        }
        /// Whether Stats shows it when its preferences say nothing: each module's own config.plist State (Stats 3.0.19).
        var statsDefault: Bool { [.cpu, .ram, .disk, .network, .battery].contains(self) }
        public var title: String {
            switch self {
            case .cpu: "CPU"
            case .gpu: "GPU"
            case .ram: "RAM"
            case .disk: "Disk"
            case .sensors: "Temperature"
            case .network: "Network"
            case .battery: SystemStats.hasBattery ? "Battery" : "Power draw"
            case .bluetooth: "Bluetooth batteries"
            }
        }
        /// Its SF Symbol, on the top bar's page and in the dock's System stats.
        public var symbol: String {
            switch self {
            case .cpu: "cpu"
            case .gpu: "display"
            case .ram: "square.stack.3d.up"
            case .disk: "cylinder"
            case .sensors: "thermometer.medium"
            case .network: "network"
            case .battery: "battery.75"
            case .bluetooth: "headphones"
            }
        }
        /// The few letters a graph item shows beside its line.
        public var short: String {
            switch self {
            case .cpu: "CPU"
            case .gpu: "GPU"
            case .ram: "RAM"
            case .disk: "SSD"
            case .sensors: "TEMP"
            case .network: "NET"
            case .battery: SystemStats.hasBattery ? "BAT" : "PWR"
            case .bluetooth: "BT"
            }
        }
        /// What a tick must read for this item alone (card agent-bo-95422836).
        public var parts: SystemStats.Parts {
            switch self {
            case .cpu: .cpu
            case .gpu: .gpu
            case .ram: .memory
            case .disk: [.diskSpace, .diskIO]   // the text shows space used, the graph read and write
            case .sensors: .sensors
            case .network: .network
            case .battery: .battery
            case .bluetooth: .bluetooth
            }
        }
        /// Whether a mini graph means something for it: a share, a rate or a temperature over time.
        public var graphable: Bool { [.cpu, .gpu, .ram, .disk, .network, .sensors].contains(self) }
    }

    public enum Style: String, Codable, Sendable { case text, graph }

    public struct Item: Codable, Equatable, Sendable {
        public var stat: Stat, on: Bool, style: Style
        public init(stat: Stat, on: Bool, style: Style) { self.stat = stat; self.on = on; self.style = style }
    }

    /// Every reading in its menu-bar order, each on or off, and whether the ones on share one item.
    public struct Choices: Codable, Equatable, Sendable {
        public var items: [Item]
        public var combined: Bool
        /// Stats' RAM Combined processes: the busiest by RAM count an app's helpers under the app (card agent-bo-95422834).
        public var combineProcesses: Bool
        public init(items: [Item], combined: Bool, combineProcesses: Bool = false) {
            self.items = items; self.combined = combined; self.combineProcesses = combineProcesses
        }
        /// Choices saved before combineProcesses existed read with it off.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            items = try c.decode([Item].self, forKey: .items)
            combined = try c.decode(Bool.self, forKey: .combined)
            combineProcesses = try c.decodeIfPresent(Bool.self, forKey: .combineProcesses) ?? false
        }
        static let statsDefaults = fromStats([:])
    }

    /// Stats' widgets that draw a reading over time; its value, label, text, pie and gauge widgets read as text.
    static let graphWidgets: Set<String> = ["line_chart", "bar_chart", "network_chart"]

    /// Pilot's choices from Stats' preferences (CFPreferences domain eu.exelban.Stats): <Module>_state, else the module's
    /// default; <Module>_position for the order, Stats' own module order breaking ties and filling gaps; <Module>_widget,
    /// a comma-separated list of the module's widgets (Stats' Kit/module/widget.swift), a graph when any is a chart;
    /// CombinedModules for one shared item.
    public static func fromStats(_ prefs: [String: Any]) -> Choices {
        let number = { (key: String) in prefs[key] as? NSNumber }
        let order = Stat.allCases.enumerated().map { index, stat in
            (stat, number("\(stat.statsModule)_position")?.intValue ?? index, index)
        }
        let items = order.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map { stat, _, _ in
            let widgets = Set((prefs["\(stat.statsModule)_widget"] as? String ?? "").split(separator: ",").map(String.init))
            return Item(stat: stat, on: number("\(stat.statsModule)_state")?.boolValue ?? stat.statsDefault,
                        style: stat.graphable && !widgets.isDisjoint(with: graphWidgets) ? .graph : .text)
        }
        return Choices(items: items, combined: number("CombinedModules")?.boolValue ?? false,
                       combineProcesses: number("RAM_combinedProcesses")?.boolValue ?? false)
    }

    /// An item's text from the last reading and its values: "CPU 12%", "↓1.2M ↑40K"; a dash for a rate before the second
    /// reading; nil for a reading this Mac lacks (a battery, sensors, a GPU, Bluetooth devices), which hides the item.
    public static func text(_ stat: Stat, values: SystemStats.Values?, raw: SystemStats.Raw?) -> String? {
        let percent = { (label: String, share: Double?) in "\(label) " + (share.map { "\(Int(($0 * 100).rounded()))%" } ?? "–") }
        switch stat {
        case .cpu: return percent("CPU", values?.cpu)
        case .gpu: return values?.gpu.map { percent("GPU", $0) }
        case .ram: return percent("RAM", values?.ram)
        case .disk: return percent("SSD", raw?.diskUsed)
        case .network: return "↓\(values?.down.map(compact) ?? "–") ↑\(values?.up.map(compact) ?? "–")"
        case .battery:
            if let battery = raw?.battery { return "BAT \(battery.percent)%" }
            return (raw?.systemPower ?? raw?.sensors?.power).flatMap { $0.isFinite && $0 > 0 && $0 < 2_000 ? "PWR \(Int($0.rounded())) W" : nil }
        case .sensors:
            return raw?.sensors.flatMap { SystemStats.temperature($0.temperatures, prefixes: SystemStats.cpuSensors) }
                .map { "TEMP \(Int($0.average.rounded()))°" }
        case .bluetooth:
            return raw?.slow.bluetooth.first.map { "\($0.name) \($0.shortLevel)" }
        }
    }

    /// An item's value without its label: "12%", "↓1.2M ↑40K", "52°"; nil for a reading this Mac lacks, as `text`.
    public static func value(_ stat: Stat, values: SystemStats.Values?, raw: SystemStats.Raw?) -> String? {
        guard let text = text(stat, values: values, raw: raw) else { return nil }
        switch stat {
        case .network: return text
        case .bluetooth: return raw?.slow.bluetooth.first?.shortLevel
        default: return text.split(separator: " ", maxSplits: 1).last.map(String.init)
        }
    }

    /// A meter's share, 0 to 1: CPU, GPU and RAM as they are, the startup disk's space used; nil for the rest.
    public static func share(_ stat: Stat, values: SystemStats.Values?, raw: SystemStats.Raw?) -> Double? {
        switch stat {
        case .cpu: values?.cpu
        case .gpu: values?.gpu
        case .ram: values?.ram
        case .disk: raw?.slow.disk.flatMap { $0.total > 0 ? Double($0.total - $0.available) / Double($0.total) : nil }
        default: nil
        }
    }

    /// Past this share CPU, GPU, RAM and the startup disk turn amber (design JJPiA9o30SA: disk at 90%).
    static let warnShare = 0.9
    /// Past this the CPU's temperature turns amber, in °C.
    static let warnHeat = 90.0

    /// Whether a reading is past its threshold.
    public static func warns(_ stat: Stat, values: SystemStats.Values?, raw: SystemStats.Raw?) -> Bool {
        switch stat {
        case .sensors: (values?.heat ?? 0) >= warnHeat
        default: (share(stat, values: values, raw: raw) ?? 0) >= warnShare
        }
    }

    /// A battery at 20 percent or less, not charging.
    public static func warns(_ battery: SystemStats.Battery) -> Bool { battery.percent <= 20 && !battery.charging }

    /// How hard a reading runs, for its colour on the top bar while Item colours is on (Sven, Q251: "cpu when at 100
    /// looks red"): normal, high (amber), critical (red).
    public enum Level: Int, Comparable, Sendable {
        case normal, high, critical
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Where a reading turns high and critical: CPU, GPU and memory at 70 and 90 % of their share; the startup disk
    /// fuller, at 85 and 95 % used; the CPU's heat at 80 and 95 °C.
    public static let loadLevels = (high: 0.7, critical: 0.9), diskLevels = (high: 0.85, critical: 0.95), heatLevels = (high: 80.0, critical: 95.0)
    /// A battery not charging is low at 20 % and nearly empty at 10 %.
    public static let batteryLevels = (high: 20, critical: 10)

    /// How hard `stat` runs now; normal for a reading with no load (network, Bluetooth) or none read yet.
    public static func level(_ stat: Stat, values: SystemStats.Values?, raw: SystemStats.Raw?) -> Level {
        let reading: (value: Double?, at: (high: Double, critical: Double))? = switch stat {
        case .cpu, .gpu, .ram: (share(stat, values: values, raw: raw), loadLevels)
        case .disk: (share(stat, values: values, raw: raw), diskLevels)
        case .sensors: (values?.heat, heatLevels)
        default: nil
        }
        guard let reading, let value = reading.value else { return .normal }
        return value >= reading.at.critical ? .critical : value >= reading.at.high ? .high : .normal
    }

    /// A battery's level: the other way round, low is red; charging, always normal.
    public static func level(_ battery: SystemStats.Battery) -> Level {
        battery.charging ? .normal : level(percent: battery.percent)
    }

    /// A charge's level by its percent alone (a Bluetooth device's, which says nothing of charging).
    public static func level(percent: Int) -> Level {
        percent <= batteryLevels.critical ? .critical : percent <= batteryLevels.high ? .high : .normal
    }

    /// The widest value a reading shows, so its item keeps one width as the numbers change.
    public static func widest(_ stat: Stat) -> String {
        switch stat {
        case .network: "↓999.9M ↑999.9M"
        case .sensors: "100°"
        default: "100%"
        }
    }

    /// A mini graph's points, oldest first, each 0 to 1: shares as they are, rates against the highest in `history`,
    /// temperatures against 100 °C.
    public static func graph(_ stat: Stat, history: [SystemStats.Values]) -> [Double] {
        let scaled = { (rates: [Double]) in
            let top = rates.max() ?? 0
            return rates.map { top > 0 ? $0 / top : 0 }
        }
        switch stat {
        case .cpu: return history.map { $0.cpu ?? 0 }
        case .gpu: return history.map { $0.gpu ?? 0 }
        case .ram: return history.map(\.ram)
        case .network: return scaled(history.map { $0.down ?? 0 })
        case .disk: return scaled(history.map { ($0.diskRead ?? 0) + ($0.diskWrite ?? 0) })
        case .sensors: return history.map { min(max(($0.heat ?? 0) / 100, 0), 1) }
        case .battery, .bluetooth: return []
        }
    }

    /// The readings whose popup lists the busiest processes, so it keeps the process list read while open.
    public static let listsProcesses: Set<Stat> = [.cpu, .ram, .disk, .network]

    /// This Mac's rows that belong to `stat`'s popup, in This Mac's order.
    public static func rows(_ stat: Stat, in rows: [SystemStats.Row]) -> [SystemStats.Row] {
        rows.filter { $0.topic == stat }
    }

    /// "1.2M", "40K", "800B": bytes a second, decimal, as short as the menu bar needs.
    static func compact(_ bytes: Double) -> String {
        bytes >= 1_000_000 ? String(format: "%.1fM", bytes / 1_000_000) : bytes >= 1_000 ? String(format: "%.0fK", bytes / 1_000)
            : String(format: "%.0fB", bytes)
    }
}
