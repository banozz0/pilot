import Foundation
import IOKit.ps

/// Home's This Mac section (card agent-bo-95422788, Sven 2026-10-05): CPU, GPU, RAM, disk, network, battery, heat and
/// uptime (RAM's parts, swap and GPU: card agent-bo-95422830), modelled on exelban/stats (MIT) — its behaviour and the public APIs it reads, none of its code. The app reads
/// a Raw sample every 2 s while Home is on screen; everything here is the arithmetic and the words, so it is tested on
/// fixtures. Rates need two samples, so the first shows a dash.
public enum SystemStats {
    /// Seconds between Home's readings while it is on screen; the disk, which barely moves and costs most to read, every 60.
    public static let interval: TimeInterval = 2, diskInterval: TimeInterval = 60
    /// HOST_CPU_LOAD_INFO's tick counters, all cores together.
    public struct CPUTicks: Equatable, Sendable {
        public var user, system, idle, nice: UInt64
        public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
            self.user = user; self.system = system; self.idle = idle; self.nice = nice
        }
        /// A part not read (Parts).
        public static let zero = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        var busy: UInt64 { user + system + nice }
        var all: UInt64 { busy + idle }
    }

    /// kern.memorystatus_vm_pressure_level.
    public enum Pressure: String, Sendable {
        case normal, warning, critical
        public init(level: Int32) { self = level >= 4 ? .critical : level == 2 ? .warning : .normal }
    }

    /// HOST_VM_INFO64's page counts, the page size and the installed memory, plus vm.swapusage in bytes.
    public struct Memory: Equatable, Sendable {
        public var total, pageSize, active, inactive, speculative, wired, compressed, purgeable, external: UInt64
        public var pressure: Pressure
        public var swapUsed, swapTotal: UInt64
        public init(total: UInt64, pageSize: UInt64, active: UInt64, inactive: UInt64, speculative: UInt64, wired: UInt64,
                    compressed: UInt64, purgeable: UInt64, external: UInt64, pressure: Pressure, swapUsed: UInt64, swapTotal: UInt64) {
            self.total = total; self.pageSize = pageSize; self.active = active; self.inactive = inactive
            self.speculative = speculative; self.wired = wired; self.compressed = compressed; self.purgeable = purgeable
            self.external = external; self.pressure = pressure; self.swapUsed = swapUsed; self.swapTotal = swapTotal
        }

        public static let zero = Memory(total: 0, pageSize: 0, active: 0, inactive: 0, speculative: 0, wired: 0, compressed: 0,
                                        purgeable: 0, external: 0, pressure: .normal, swapUsed: 0, swapTotal: 0)

        /// Stats' used memory: what apps and macOS hold, less what macOS can drop at once (purgeable, file-backed).
        public var used: UInt64 {
            let held = active + inactive + speculative + wired + compressed
            let free = purgeable + external
            return (held > free ? held - free : 0) * pageSize
        }

        /// Stats' app memory: used, less what macOS keeps in place (wired) and what it squeezed (compressed).
        public var app: UInt64 {
            let kept = (wired + compressed) * pageSize
            return used > kept ? used - kept : 0
        }
    }

    /// The Wi-Fi and Ethernet interfaces' byte counters, summed.
    public struct Network: Equatable, Sendable {
        public var received, sent: UInt64
        public init(received: UInt64, sent: UInt64) { self.received = received; self.sent = sent }
        public static let zero = Network(received: 0, sent: 0)
    }

    /// The startup disk, counting space macOS can clear when it needs it.
    public struct Disk: Equatable, Sendable {
        public var available, total: Int64
        public init(available: Int64, total: Int64) { self.available = available; self.total = total }
    }

    /// Whether this Mac has a battery: IOKit's power sources list an internal one. Read once; on a Mac with none the
    /// battery item and reading are named Power draw and show the watts it draws.
    public static let hasBattery: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { (IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any])?[kIOPSTypeKey] as? String
            == kIOPSInternalBatteryType }
    }()

    public struct Battery: Equatable, Sendable {
        public var percent: Int
        public var charging: Bool
        public var pluggedIn: Bool
        /// To full while charging, to empty otherwise; nil while macOS is still working it out.
        public var minutesLeft: Int?
        public init(percent: Int, charging: Bool, pluggedIn: Bool = false, minutesLeft: Int?) {
            self.percent = percent; self.charging = charging; self.pluggedIn = pluggedIn; self.minutesLeft = minutesLeft
        }

        /// From IOKit's power source: the time to full counts only while charging and the time to empty only on battery
        /// power, since a charged Mac on AC reports 0 for both; a negative time is macOS still working it out.
        public static func reading(percent: Int, charging: Bool, onACPower: Bool, toFull: Int?, toEmpty: Int?) -> Battery {
            let minutes = charging ? toFull : onACPower ? nil : toEmpty
            return Battery(percent: percent, charging: charging, pluggedIn: onACPower, minutesLeft: minutes.flatMap { $0 >= 0 ? $0 : nil })
        }

        /// "82 % · charging · 1 h 20 min to full", "54 % · 3 h 10 min left", "100 % · plugged in".
        public var phrase: String {
            var parts = ["\(percent) %"]
            if charging { parts.append("charging") } else if pluggedIn { parts.append("plugged in") }
            if let minutesLeft { parts.append(SystemStats.duration(minutes: minutesLeft) + (charging ? " to full" : " left")) }
            return parts.joined(separator: " · ")
        }
    }

    /// ProcessInfo.thermalState.
    public enum Thermal: String, Sendable { case nominal = "Nominal", fair = "Fair", serious = "Serious", critical = "Critical" }

    /// What one reading covers (card agent-bo-95422836): a tick reads only what something on screen shows, all of it for
    /// This Mac's rows, a menu-bar item's own part for the item (MenuBarStats.Stat.parts). The slow parts are read every
    /// diskInterval; processes only while a list shows them.
    public struct Parts: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let cpu = Parts(rawValue: 1 << 0), memory = Parts(rawValue: 1 << 1), gpu = Parts(rawValue: 1 << 2)
        public static let network = Parts(rawValue: 1 << 3), battery = Parts(rawValue: 1 << 4), sensors = Parts(rawValue: 1 << 5)
        /// Per core, a battery's power: the rest of This Mac's per-tick rows (the load comes with .cpu).
        public static let details = Parts(rawValue: 1 << 6)
        /// The startup disk's byte counters: Disk speed, and the Disk item's graph.
        public static let diskIO = Parts(rawValue: 1 << 11)
        /// Slow: the startup disk's space; Bluetooth batteries (system_profiler); the rest (IP, interface, Wi-Fi, battery
        /// health, charger, machine, disk kind).
        public static let diskSpace = Parts(rawValue: 1 << 7), bluetooth = Parts(rawValue: 1 << 8), slowDetails = Parts(rawValue: 1 << 9)
        public static let processes = Parts(rawValue: 1 << 10)
        /// Slow too: the Bluetooth HID devices' batteries alone (keyboards, mice, trackpads), a registry walk without
        /// system_profiler, for Low-battery alerts while nothing shows Bluetooth.
        public static let bluetoothHID = Parts(rawValue: 1 << 12)
        /// Everything This Mac's rows show; the process list is asked for on its own.
        public static let all: Parts = [.cpu, .memory, .gpu, .network, .battery, .sensors, .details, .diskIO, .diskSpace, .bluetooth,
                                        .slowDetails]
        public static let slow: Parts = [.diskSpace, .bluetooth, .bluetoothHID, .slowDetails]
    }

    /// One reading of everything.
    public struct Raw: Equatable, Sendable {
        /// What this reading measured; a part left out reads as zero or nil and gives no rate (values).
        public var parts: Parts = .all
        /// The awake clock (ProcessInfo.systemUptime), which the rates divide by: it stops while the Mac sleeps, as the
        /// counters do.
        public var time: TimeInterval
        public var cpu: CPUTicks
        public var memory: Memory
        public var network: Network
        /// Nil on a Mac with no battery.
        public var battery: Battery?
        public var thermal: Thermal
        /// Wall time since the Mac started (kern.boottime), sleep included.
        public var uptime: TimeInterval
        /// The graphics chip's busy share, 0 to 1 (gpuLoad); nil when no accelerator answers.
        public var gpu: Double?
        // Card agent-bo-95422831, the readings Stats shows beyond the totals; empty or nil where the Mac has none.
        /// PROCESSOR_CPU_LOAD_INFO's ticks per core, in macOS's order: the efficiency cores first.
        public var cores: [CPUTicks] = []
        /// How many of `cores` are efficiency cores (hw.perflevel1.logicalcpu); 0 on a Mac with one kind.
        public var efficiencyCores = 0
        /// ps's listing, only while a view lists the busiest: each process's resident size, for the busiest lists.
        public var processes: [KillProcess.Row]?
        /// The same listing as Activity reads it (parent, owner, path; memory as Activity counts it), for Stats' Overview
        /// to group by app as Activity does.
        public var tree: [Activity.Process]?
        /// The startup disk driver's byte counters (diskIO).
        public var diskIO: DiskIO?
        /// The readings that barely move, read every diskInterval and kept between.
        public var slow = Slow()
        /// The startup disk's used share, 0 to 1; nil until its space is read.
        public var diskUsed: Double? { slow.disk.flatMap { $0.total > 0 ? Double($0.total - $0.available) / Double($0.total) : nil } }
        /// Temperatures, fans and power from the SMC (card agent-bo-95422832); nil where it cannot be read.
        public var sensors: Sensors?
        // Card agent-bo-95422834, what the parity check with Stats found missing.
        /// getloadavg's 1, 5 and 15 minute load averages; empty when it failed.
        public var load: [Double] = []
        /// The graphics accelerator's parts and name, where it gives them.
        public var gpuDetail: GPUDetail?
        /// A battery's temperature, voltage and current; read each tick, as they move by the second.
        public var batteryPower: BatteryPower?
        /// The power adapter's voltage now (AppleSmartBattery's AdapterDetails), on a Mac with a battery.
        public var adapterVolts: Double?
        /// The whole Mac's draw in watts (the SMC's PSTR), read with the battery on a Mac that has none.
        public var systemPower: Double?
        /// Each listed process's bytes read and written since it started (proc_pid_rusage), while the busiest are listed.
        public var processIO: [Int32: DiskIO]?
        public init(time: TimeInterval, cpu: CPUTicks, memory: Memory, network: Network, battery: Battery?, thermal: Thermal,
                    uptime: TimeInterval, gpu: Double?) {
            self.time = time; self.cpu = cpu; self.memory = memory; self.network = network
            self.battery = battery; self.thermal = thermal; self.uptime = uptime; self.gpu = gpu
        }
    }

    /// The slow readings: the startup disk's space, the primary interface's IPv4 address, the battery's health and the
    /// charger, connected Bluetooth devices that report a battery.
    public struct Slow: Equatable, Sendable {
        public var disk: Disk?
        public var localIP: String?
        public var batteryHealth: BatteryHealth?
        public var chargerWatts: Int?
        public var bluetooth: [BluetoothDevice] = []
        /// The primary interface's name, hardware address and DNS servers (card agent-bo-95422834).
        public var interface: Interface?
        public var machine: Machine?
        /// The Wi-Fi link, from CoreWLAN, without the network's name (that needs Location access).
        public var wifi: WiFiLink?
        public var diskKind: DiskKind?
        public init() {}

        /// These readings, with what `parts` did not read now taken from `older` (each slow part is read on its own
        /// schedule).
        public func keeping(_ older: Slow, readNow parts: Parts) -> Slow {
            var merged = older
            if parts.contains(.diskSpace) { merged.disk = disk }
            if parts.contains(.bluetooth) {
                merged.bluetooth = bluetooth
            } else if parts.contains(.bluetoothHID) {
                // The HID devices afresh; the earbuds system_profiler gave last, as they were.
                merged.bluetooth = bluetooth + older.bluetooth.filter { old in old.fromProfiler && !bluetooth.contains { $0.name == old.name } }
            }
            if parts.contains(.slowDetails) {
                merged.localIP = localIP; merged.interface = interface; merged.machine = machine; merged.wifi = wifi
                merged.diskKind = diskKind; merged.chargerWatts = chargerWatts; merged.batteryHealth = batteryHealth
            }
            return merged
        }
    }

    public struct WiFiLink: Equatable, Sendable {
        public var channel: Int, band: String?, signal: Int, noise: Int, rate: Double, standard: String?
        public init(channel: Int, band: String?, signal: Int, noise: Int, rate: Double, standard: String?) {
            self.channel = channel; self.band = band; self.signal = signal; self.noise = noise; self.rate = rate; self.standard = standard
        }
    }

    /// The startup volume's file system ("APFS") and how its disk is connected ("Apple Fabric", "PCI-Express").
    public struct DiskKind: Equatable, Sendable {
        public var fileSystem: String?, connection: String?
        public init(fileSystem: String?, connection: String?) { self.fileSystem = fileSystem; self.connection = connection }
    }

    public struct Interface: Equatable, Sendable {
        public var name: String, hardwareAddress: String?, dns: [String]
        public init(name: String, hardwareAddress: String?, dns: [String]) { self.name = name; self.hardwareAddress = hardwareAddress; self.dns = dns }
    }

    /// The chip (machdep.cpu.brand_string), the model identifier (hw.model) and the macOS version.
    public struct Machine: Equatable, Sendable {
        public var chip: String, model: String, macOS: String
        public init(chip: String, model: String, macOS: String) { self.chip = chip; self.model = model; self.macOS = macOS }
    }

    /// The renderer's and tiler's busy shares (Apple silicon's PerformanceStatistics) and the chip's name and GPU cores.
    public struct GPUDetail: Equatable, Sendable {
        public var renderer: Double?, tiler: Double?, model: String?, cores: Int?
        public init(renderer: Double?, tiler: Double?, model: String?, cores: Int?) {
            self.renderer = renderer; self.tiler = tiler; self.model = model; self.cores = cores
        }

        public static func reading(_ statistics: [String: Any], model: String?, cores: Int?) -> GPUDetail {
            GPUDetail(renderer: share(statistics, "Renderer Utilization %"), tiler: share(statistics, "Tiler Utilization %"),
                      model: model, cores: cores)
        }
    }

    /// The battery's temperature, voltage and current (AppleSmartBattery: Temperature in hundredths of °C, Voltage in mV,
    /// Amperage in mA, negative while it drains).
    public struct BatteryPower: Equatable, Sendable {
        public var celsius, volts, amps: Double
        public init(celsius: Double, volts: Double, amps: Double) { self.celsius = celsius; self.volts = volts; self.amps = amps }

        public static func reading(_ registry: [String: Any]) -> BatteryPower? {
            let number = { (key: String) in (registry[key] as? NSNumber)?.doubleValue }
            guard let temperature = number("Temperature"), let voltage = number("Voltage"), let amperage = number("Amperage") else { return nil }
            return BatteryPower(celsius: temperature / 100, volts: voltage / 1000, amps: amperage / 1000)
        }
    }

    public struct DiskIO: Equatable, Sendable {
        public var read, written: UInt64
        public init(read: UInt64, written: UInt64) { self.read = read; self.written = written }
    }

    public struct BatteryHealth: Equatable, Sendable {
        public var cycles: Int, percent: Int
        public init(cycles: Int, percent: Int) { self.cycles = cycles; self.percent = percent }

        /// From AppleSmartBattery's registry entry: the full charge it holds now (AppleRawMaxCapacity, else
        /// NominalChargeCapacity) against DesignCapacity, as Stats and System Information count it.
        public static func reading(_ registry: [String: Any]) -> BatteryHealth? {
            let number = { (key: String) in (registry[key] as? NSNumber)?.intValue }
            guard let cycles = number("CycleCount"), let design = number("DesignCapacity"), design > 0,
                  let full = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity") else { return nil }
            return BatteryHealth(cycles: cycles, percent: Int((Double(full) * 100 / Double(design)).rounded()))
        }
    }

    /// A Bluetooth device and its battery, "71 %" or, for earbuds, "L 90 % · R 85 % · case 40 %".
    public struct BluetoothDevice: Equatable, Sendable {
        public var name, level: String
        /// Read through system_profiler (earbuds, headphones), not the HID registry.
        public var fromProfiler: Bool
        public init(name: String, level: String, fromProfiler: Bool = false) { self.name = name; self.level = level; self.fromProfiler = fromProfiler }

        /// The lowest of its batteries: the earbuds count, the case only when alone; nil when none reads.
        public var percent: Int? {
            let parts = level.components(separatedBy: " · ")
            let levels = { (ps: [String]) in ps.compactMap { Int($0.filter(\.isNumber)) } }
            let worn = levels(parts.filter { !$0.hasPrefix("case") })
            return (worn.isEmpty ? levels(parts) : worn).min()
        }
    }

    /// What the SMC's private interface gave: each temperature sensor by its key in °C, each fan, and the whole Mac's
    /// power draw in watts (PSTR). As Stats reads them; a macOS update may change or close the interface.
    public struct Sensors: Equatable, Sendable {
        public var temperatures: [String: Double]
        public var fans: [Fan]
        public var power: Double?
        /// What the power adapter delivers now (PDTR), as Stats' battery popup shows it.
        public var powerIn: Double?
        public init(temperatures: [String: Double], fans: [Fan], power: Double?, powerIn: Double? = nil) {
            self.temperatures = temperatures; self.fans = fans; self.power = power; self.powerIn = powerIn
        }
    }

    public struct Fan: Equatable, Sendable {
        public var actual, minimum, maximum: Double
        public init(actual: Double, minimum: Double, maximum: Double) { self.actual = actual; self.minimum = minimum; self.maximum = maximum }
    }

    public struct Temperature: Equatable, Sendable {
        public var average, hottest: Double
    }

    /// The SMC key prefixes of the CPU's sensors (Apple silicon's P and E cores, an Intel Mac's CPU) and the GPU's; the
    /// whole chip's (SoC, Apple silicon only) are those and its other sensors, the Ts keys, which read in the same range
    /// as the cores on Sven's M4. Apple documents none of them, so which part of the chip a Ts key sits on is unverified.
    public static let cpuSensors = ["Tp", "Te", "TC"], gpuSensors = ["Tg", "TG"], socSensors = ["Tp", "Te", "Tg", "Ts"]

    /// The average and hottest of the sensors under `prefixes`, leaving out values no sensor gives (below 0, above 150 °C).
    public static func temperature(_ temperatures: [String: Double], prefixes: [String]) -> Temperature? {
        let values = temperatures.filter { key, value in prefixes.contains { key.hasPrefix($0) } && value > 0 && value <= 150 }.values
        guard let hottest = values.max() else { return nil }
        return Temperature(average: values.reduce(0, +) / Double(values.count), hottest: hottest)
    }

    /// The sensor rows, those that read sensibly.
    public static func sensorRows(_ sensors: Sensors) -> [Row] {
        let caveat = "From a private macOS interface; may stop after a macOS update."
        let heat = { (name: String, prefixes: [String]) in
            temperature(sensors.temperatures, prefixes: prefixes).map {
                Row(name: name, value: "\(Int($0.average.rounded())) °C · hottest \(Int($0.hottest.rounded())) °C", explanation: caveat)
            }
        }
        let rpm = { (value: Double) in value.isFinite && value >= 0 && value < 20_000 ? Int(value.rounded()) : nil }
        let fans = sensors.fans.filter { rpm($0.actual) != nil }
        let fanRows = fans.enumerated().map { i, fan in
            // The range only when the SMC gave a sensible one; a failed read is NaN.
            let range = rpm(fan.minimum).flatMap { low in rpm(fan.maximum).flatMap { high in high > low ? " · \(low) to \(high)" : nil } }
            return Row(name: fans.count == 1 ? "Fan" : "Fan \(i + 1)", value: "\(rpm(fan.actual)!) rpm" + (range ?? ""), explanation: caveat)
        }
        let power = sensors.power.flatMap { $0.isFinite && $0 > 0 && $0 < 2_000 ? $0 : nil }.map {
            Row(name: "Power", value: String(format: "%.1f W", $0), explanation: "The whole Mac's draw. " + caveat)
        }
        let appleSilicon = sensors.temperatures.keys.contains { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }
        return ([appleSilicon ? heat("SoC heat", socSensors) : nil, heat("CPU heat", cpuSensors), heat("GPU heat", gpuSensors)]
                + fanRows + [power]).compactMap(\.self)
    }

    /// The numbers a mini graph draws, for one tick: shares 0 to 1, rates in bytes a second; nil until two readings
    /// make a rate, or where the Mac has no such reading.
    public struct Values: Equatable, Sendable {
        public var cpu: Double?, ram: Double, gpu: Double?, down: Double?, up: Double?
        /// Each core's share; nil until two readings with the same cores.
        public var cores: [Double]?
        public var diskRead: Double?, diskWrite: Double?
        /// The user, system and idle shares, nil until two readings.
        public var split: [Double]?
        /// The CPU's average temperature in °C, for Heat's graph (card agent-bo-95422910); nil when not read.
        public var heat: Double?
        /// The first fan's speed in rpm, for Stats' Fan chart (card agent-bo-95422992); nil with no fan or not read.
        public var fan: Double?
        public init(cpu: Double?, ram: Double, gpu: Double?, down: Double?, up: Double?, cores: [Double]?, diskRead: Double?,
                    diskWrite: Double?, split: [Double]? = nil, heat: Double? = nil, fan: Double? = nil) {
            self.cpu = cpu; self.ram = ram; self.gpu = gpu; self.down = down; self.up = up
            self.cores = cores; self.diskRead = diskRead; self.diskWrite = diskWrite; self.split = split; self.heat = heat; self.fan = fan
        }
    }

    /// `now`'s values, with rates since `previous`.
    public static func values(previous: Raw?, now: Raw) -> Values {
        let seconds = previous.map { now.time - $0.time } ?? 0
        let m = now.memory
        let between = { (old: UInt64?, new: UInt64?) in old.flatMap { o in new.flatMap { rate(from: o, to: $0, seconds: seconds) } } }
        // A rate needs both readings to have measured its part: a counter read only now is not a rise from zero.
        let both = { (part: Parts) in previous.map { $0.parts.contains(part) && now.parts.contains(part) } ?? false }
        let cpuPrevious = both(.cpu) ? previous : nil, networkPrevious = both(.network) ? previous : nil
        return Values(cpu: cpuPrevious.flatMap { cpuLoad(from: $0.cpu, to: now.cpu) },
                      ram: m.total > 0 ? Double(m.used) / Double(m.total) : 0, gpu: now.gpu,
                      down: between(networkPrevious?.network.received, now.network.received),
                      up: between(networkPrevious?.network.sent, now.network.sent),
                      cores: previous.flatMap { $0.cores.count == now.cores.count && !now.cores.isEmpty ? coreLoads(from: $0.cores, to: now.cores) : nil },
                      diskRead: between(previous?.diskIO?.read, now.diskIO?.read),
                      diskWrite: between(previous?.diskIO?.written, now.diskIO?.written),
                      split: cpuPrevious.flatMap { cpuSplit(from: $0.cpu, to: now.cpu) },
                      heat: now.sensors.flatMap { temperature($0.temperatures, prefixes: cpuSensors)?.average },
                      fan: now.sensors?.fans.first?.actual)
    }

    /// One line of the section: the reading and what it means.
    public struct Row: Equatable, Identifiable, Sendable {
        public var name, value, explanation: String
        /// The menu-bar item whose popup shows it (MenuBarStats.rows); nil for one no item shows.
        public var topic: MenuBarStats.Stat?
        /// The name and the line under it: two processes can share a name, never a pid.
        public var id: String { name + "\u{1}" + explanation }
        public init(name: String, value: String, explanation: String, topic: MenuBarStats.Stat? = nil) {
            self.name = name; self.value = value; self.explanation = explanation; self.topic = topic
        }
    }

    /// The section's rows for `now`, with rates since `previous`; a row the Mac has no reading for is left out.
    public static func rows(previous: Raw?, now: Raw) -> [Row] {
        rows(values(previous: previous, now: now), now: now)
    }

    /// The rows for `now` from its values, worked out once a tick by whoever also keeps them for graphs; the public IP
    /// only when its setting is on and it was read.
    public static func rows(_ v: Values, now: Raw, publicIP: String? = nil) -> [Row] {
        let slow = now.slow
        let cores: Row? = now.cores.isEmpty ? nil : Row(
            name: "CPU cores", value: v.cores.map { coreLine($0, efficiency: now.efficiencyCores) } ?? "—",
            explanation: "Each core's share; E cores save power, P cores are the fast ones.")
        let diskSpeed: Row? = now.diskIO == nil ? nil : Row(
            name: "Disk speed", value: v.diskRead.flatMap { r in v.diskWrite.map { "read \(decimal(r))/s · write \(decimal($0))/s" } } ?? "—",
            explanation: "Read from and written to the startup disk right now.")
        let ip: Row? = slow.localIP.map {
            Row(name: "IP", value: [$0, publicIP.map { "public \($0)" }].compactMap(\.self).joined(separator: " · "),
                explanation: "This Mac's address on the network it is on.")
        }
        // A desktop Mac may still name an adapter; its health and charger rows come with a battery only. One with none
        // shows its draw in the battery's place (Sven, 2026-10-16: a Mac mini).
        let draw = (now.systemPower ?? now.sensors?.power).flatMap { $0.isFinite && $0 > 0 && $0 < 2_000 ? $0 : nil }
        let powerRows: [Row?] = now.battery == nil ? [draw.map {
            Row(name: "Power draw", value: String(format: "%.1f W", $0),
                explanation: "What the whole Mac draws right now, from its power management chip (SMC). From a private macOS interface; may stop after a macOS update.")
        }] : []
        let batteryRows: [Row?] = now.battery.map { b in
            [Row(name: "Battery", value: b.phrase, explanation: "Charge left, and whether it is charging."),
                    slow.batteryHealth.map {
                        Row(name: "Battery health", value: "\($0.percent) % · \($0.cycles) cycles",
                            explanation: "The charge it holds against when it was new, and how many full charges it has done.")
                    },
                    slow.chargerWatts.map { watts in
                        let now = now.sensors?.powerIn.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }.map { power in
                            " · now " + String(format: "%.1f W", power) + (now.adapterVolts.map { String(format: " at %.1f V", $0) } ?? "")
                        }
                        return Row(name: "Charger", value: "\(watts) W" + (now ?? ""), explanation: "The power adapter: what it is rated for, and what it gives now.")
                    },
                    now.batteryPower.map {
                        Row(name: "Battery power", value: String(format: "%.1f °C · %.1f V · %.2f A · %.1f W", $0.celsius, $0.volts, $0.amps, $0.volts * $0.amps),
                            explanation: "Its temperature, voltage, current and power; negative while it drains.")
                    }]
        } ?? []
        let devices = slow.bluetooth.map { Row(name: $0.name, value: $0.level, explanation: "Bluetooth battery.") }
        let network = if let down = v.down, let up = v.up { "↓ \(decimal(down))/s  ↑ \(decimal(up))/s" } else { "—" }
        let m = now.memory
        // Each reading's rows under the menu-bar item they belong to (MenuBarStats.rows), Uptime under none.
        let sections: [(MenuBarStats.Stat?, [Row?])] = [
            (.cpu, [Row(name: "CPU", value: v.cpu.map(percent) ?? "—",
                        explanation: "How busy the processor was since the last reading, all cores together."), cores,
                    Row(name: "CPU split", value: v.split.map { "user \(percent($0[0])) · system \(percent($0[1])) · idle \(percent($0[2]))" } ?? "—",
                        explanation: "Apps' share, macOS's own share, and the share left idle."),
                    now.load.count == 3 ? Row(name: "Load", value: now.load.map { String(format: "%.2f", $0) }.joined(separator: " · "),
                                              explanation: "Work waiting for a core, averaged over 1, 5 and 15 minutes.") : nil]),
            (.gpu, [v.gpu.map { Row(name: "GPU", value: percent($0), explanation: "How busy the graphics chip is, by its own count.") },
                    now.gpuDetail.flatMap { d in d.renderer.flatMap { r in d.tiler.map { t in
                        Row(name: "GPU parts", value: "renderer \(percent(r)) · tiler \(percent(t))",
                            explanation: "Drawing the picture, and sorting what to draw.") } } },
                    now.gpuDetail.flatMap { d in d.model.map { model in
                        Row(name: "Graphics", value: [model, d.cores.map { "\($0) cores" }].compactMap(\.self).joined(separator: " · "),
                            explanation: "The graphics chip.") } }]),
            (.ram, [Row(name: "RAM", value: "\(binary(m.used, digits: 1)) of \(binary(m.total, digits: 0)) GB · pressure \(m.pressure.rawValue)",
                        explanation: "Held by apps and macOS; pressure says whether the Mac is running short."),
                    Row(name: "RAM use", value: "app \(binary(m.app, digits: 1)) · wired \(binary(m.wired * m.pageSize, digits: 1)) · compressed "
                            + "\(binary(m.compressed * m.pageSize, digits: 1)) · free \(binary(m.total > m.used ? m.total - m.used : 0, digits: 1)) GB",
                        explanation: "Apps' own; what macOS keeps in place; what it squeezed to make room; what is free."),
                    Row(name: "Swap", value: m.swapTotal == 0 ? "none" : "\(binary(m.swapUsed, digits: 1)) of \(binary(m.swapTotal, digits: 1)) GB",
                        explanation: "RAM moved out to the disk when it ran short; while it grows the Mac slows.")]),
            (.disk, [Row(name: "Disk", value: slow.disk.map { "\(decimal(Double($0.available))) free of \(decimal(Double($0.total)))" } ?? "—",
                         explanation: "Free on the startup disk, counting space macOS clears when it needs it."), diskSpeed,
                     slow.diskKind.flatMap { kind in
                         let parts = [kind.fileSystem, kind.connection].compactMap(\.self)
                         return parts.isEmpty ? nil : Row(name: "Disk details", value: parts.joined(separator: " · "),
                                                          explanation: "The startup disk's file system, and how the disk is connected.")
                     },
                     now.diskIO.map { Row(name: "Disk totals", value: "read \(decimal(Double($0.read))) · written \(decimal(Double($0.written)))",
                                          explanation: "Read from and written to the startup disk since it started.") }]),
            (.network, [Row(name: "Network", value: network,
                            explanation: "Download and upload right now, over Wi-Fi and Ethernet together."), ip,
                        slow.wifi.map { w in
                            let minus = { (n: Int) in "\(n)".replacingOccurrences(of: "-", with: "−") }
                            return Row(name: "Wi-Fi", value: (["channel \(w.channel)", w.band, "\(minus(w.signal)) dBm", "noise \(minus(w.noise)) dBm",
                                                               "\(Int(w.rate.rounded())) Mbit/s", w.standard] as [String?]).compactMap(\.self)
                                                              .joined(separator: " · "),
                                       explanation: "The Wi-Fi link: its channel, signal against noise, speed and standard.")
                        },
                        slow.interface.map { i in
                            Row(name: "Network details", value: ([i.name, i.hardwareAddress] + [i.dns.isEmpty ? nil : "DNS " + i.dns.joined(separator: ", ")])
                                    .compactMap(\.self).joined(separator: " · "),
                                explanation: "The connection in use, its hardware address, and who answers its name lookups.") },
                        Row(name: "Network totals",
                            value: "↓ \(decimal(Double(now.network.received))) · ↑ \(decimal(Double(now.network.sent)))",
                            explanation: "Downloaded and uploaded over Wi-Fi and Ethernet since the Mac started.")]),
            (.battery, batteryRows + powerRows),
            (.bluetooth, devices),
            (.sensors, [Row(name: "Heat", value: now.thermal.rawValue,
                            explanation: "macOS's own heat level; at Serious or Critical it slows the Mac to cool it.")]
                + (now.sensors.map(sensorRows) ?? []).filter { now.battery != nil || $0.name != "Power" }),
            (nil, [slow.machine.map { Row(name: "This Mac", value: "\($0.chip) · \($0.model) · macOS \($0.macOS)",
                                          explanation: "The chip, the model and the macOS it runs.") },
                   Row(name: "Uptime", value: duration(minutes: Int(now.uptime / 60)), explanation: "Time since this Mac last started up.")]),
        ]
        return sections.flatMap { topic, rows in rows.compactMap { $0.map { row in var row = row; row.topic = topic; return row } } }
    }

    /// The user, system and idle shares between two samples, nice counted with user as Activity Monitor does.
    static func cpuSplit(from a: CPUTicks, to b: CPUTicks) -> [Double]? {
        guard b.all > a.all, b.user >= a.user, b.nice >= a.nice, b.system >= a.system, b.idle >= a.idle else { return nil }
        let all = Double(b.all - a.all)
        return [Double(b.user - a.user + b.nice - a.nice) / all, Double(b.system - a.system) / all, Double(b.idle - a.idle) / all]
    }

    /// Stats' Combined processes: an app's helpers ("Google Chrome Helper (Renderer)") count under the app ("Google
    /// Chrome"), CPU and memory summed, under the app's pid when it runs, else the first helper's. By name, as ps gives it.
    public static func combined(_ processes: [KillProcess.Row]) -> [KillProcess.Row] {
        var merged: [String: KillProcess.Row] = [:], order: [String] = []
        for p in processes {
            let app = p.name.range(of: " Helper").map { String(p.name[..<$0.lowerBound]) } ?? p.name
            if var row = merged[app] {
                row.cpu += p.cpu
                row.memoryKB += p.memoryKB
                if p.name == app { row.pid = p.pid }
                merged[app] = row
            } else {
                merged[app] = KillProcess.Row(pid: p.pid, cpu: p.cpu, memoryKB: p.memoryKB, name: app)
                order.append(app)
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// The busiest processes by disk, bytes read and written a second between two readings of each process's counters
    /// (proc_pid_rusage); a process new since the first reading, or idle, is left out.
    public static func busiestIO(before: [Int32: DiskIO], after: [Int32: DiskIO], seconds: TimeInterval, names: (Int32) -> String?,
                                 count: Int = 5) -> [Row] {
        guard seconds > 0 else { return [] }
        let rates = after.compactMap { pid, now -> (Int32, Double)? in
            guard let then = before[pid], now.read >= then.read, now.written >= then.written else { return nil }
            let rate = Double(now.read - then.read + now.written - then.written) / seconds
            return rate > 0 ? (pid, rate) : nil
        }
        return rates.sorted { $0.1 > $1.1 }.prefix(count).compactMap { pid, rate in
            names(pid).map { Row(name: $0, value: "\(decimal(rate))/s", explanation: "pid \(pid)", topic: .disk) }
        }
    }

    /// `nettop -P -L 1 -x -J bytes_in,bytes_out`'s lines, "name.pid,in,out,", as each process's bytes in (read) and out
    /// (written) since it started.
    public static func nettop(_ csv: String) -> [String: DiskIO] {
        var counts: [String: DiskIO] = [:]
        for line in csv.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let received = UInt64(fields[1]), let sent = UInt64(fields[2]), fields[0].contains(".") else { continue }
            counts[String(fields[0])] = DiskIO(read: received, written: sent)
        }
        return counts
    }

    /// The busiest processes by network between two nettop snapshots, download and upload a second each; named by `names`
    /// (ps's full name for the pid) where it knows the pid, as nettop cuts names short.
    public static func busiestNetwork(before: [String: DiskIO], after: [String: DiskIO], seconds: TimeInterval,
                                      names: (Int32) -> String? = { _ in nil }, count: Int = 5) -> [Row] {
        guard seconds > 0 else { return [] }
        let rates = after.compactMap { key, now -> (String, Double, Double)? in
            guard let then = before[key], now.read >= then.read, now.written >= then.written else { return nil }
            let down = Double(now.read - then.read) / seconds, up = Double(now.written - then.written) / seconds
            return down + up > 0 ? (key, down, up) : nil
        }
        return rates.sorted { $0.1 + $0.2 > $1.1 + $1.2 }.prefix(count).map { key, down, up in
            let pid = key.split(separator: ".").last.map(String.init) ?? ""
            let name = Int32(pid).flatMap(names) ?? key.split(separator: ".").dropLast().joined(separator: ".")
            return Row(name: name, value: "↓ \(decimal(down))/s ↑ \(decimal(up))/s", explanation: "pid " + pid, topic: .network)
        }
    }

    /// Each core's busy share between two samples; a core with no tick between them reads 0.
    public static func coreLoads(from a: [CPUTicks], to b: [CPUTicks]) -> [Double] {
        zip(a, b).map { cpuLoad(from: $0, to: $1) ?? 0 }
    }

    /// "E 25 0 · P 80 %": each core in whole percent, the `efficiency` cores first.
    static func coreLine(_ shares: [Double], efficiency: Int) -> String {
        let loads = shares.map { String(Int(($0 * 100).rounded())) }
        let e = min(efficiency, loads.count)
        let groups = [e > 0 ? "E " + loads[..<e].joined(separator: " ") : nil,
                      e < loads.count ? (e > 0 ? "P " : "") + loads[e...].joined(separator: " ") : nil]
        return groups.compactMap(\.self).joined(separator: " · ") + " %"
    }

    public enum ProcessOrder: Sendable { case cpu, memory }

    /// The five busiest processes by CPU (percent of one core, as ps and Activity Monitor count it) or by resident memory,
    /// as rows: the name, its share or size, and its pid.
    public static func busiest(_ processes: [KillProcess.Row], by order: ProcessOrder, count: Int = 5) -> [Row] {
        let sorted = processes.sorted { order == .cpu ? $0.cpu > $1.cpu : $0.memoryKB > $1.memoryKB }
        return sorted.prefix(count).map { p in
            Row(name: p.name, value: order == .cpu ? String(format: "%.1f %%", p.cpu) : memorySize(UInt64(p.memoryKB) * 1024),
                explanation: "pid \(p.pid)")
        }
    }

    /// The startup disk driver's Statistics (IOBlockStorageDriver): bytes read and written since it started.
    public static func diskIO(_ statistics: [String: Any]?) -> DiskIO? {
        guard let read = statistics?["Bytes (Read)"] as? NSNumber, let written = statistics?["Bytes (Write)"] as? NSNumber else { return nil }
        return DiskIO(read: read.uint64Value, written: written.uint64Value)
    }

    /// Connected devices that report a battery: HID devices from the registry (AppleDeviceManagementHIDEventService's
    /// Product and BatteryPercent), then earbuds and the rest from `system_profiler SPBluetoothDataType -json`.
    public static func bluetooth(hid: [[String: Any]], profiler: Data) -> [BluetoothDevice] {
        let fromHID = hid.compactMap { d -> BluetoothDevice? in
            guard let name = d["Product"] as? String, let level = (d["BatteryPercent"] as? NSNumber)?.intValue else { return nil }
            return BluetoothDevice(name: name, level: "\(level) %")
        }
        let root = (try? JSONSerialization.jsonObject(with: profiler)) as? [String: Any]
        let controllers = root?["SPBluetoothDataType"] as? [[String: Any]] ?? []
        let connected = controllers.flatMap { $0["device_connected"] as? [[String: [String: Any]]] ?? [] }.flatMap { $0 }
        let fromProfiler = connected.compactMap { name, info -> BluetoothDevice? in
            let level = { (key: String) in (info[key] as? String).map { $0.replacingOccurrences(of: "%", with: " %") } }
            let parts = [level("device_batteryLevelLeft").map { "L \($0)" }, level("device_batteryLevelRight").map { "R \($0)" },
                         level("device_batteryLevelCase").map { "case \($0)" }].compactMap(\.self)
            guard let shown = parts.isEmpty ? level("device_batteryLevelMain") : parts.joined(separator: " · ") else { return nil }
            return BluetoothDevice(name: name, level: shown, fromProfiler: true)
        }
        return fromHID + fromProfiler.filter { device in !fromHID.contains { $0.name == device.name } }
    }

    /// "618 MB", "2.4 GB": binary units, as Activity Monitor counts memory.
    public static func memorySize(_ bytes: UInt64) -> String {
        bytes >= 1 << 30 ? binary(bytes, digits: 1) + " GB" : String(format: "%.0f MB", Double(bytes) / Double(1 << 20))
    }

    /// The busy share of the ticks between two samples; nil when no tick passed.
    public static func cpuLoad(from a: CPUTicks, to b: CPUTicks) -> Double? {
        guard b.all > a.all, b.busy >= a.busy else { return nil }
        return Double(b.busy - a.busy) / Double(b.all - a.all)
    }

    /// The busy share from one IOAccelerator's PerformanceStatistics: Device Utilization % on Apple silicon and Intel
    /// graphics, GPU Activity(%) on AMD, as Stats reads them; nil when neither is there.
    public static func gpuLoad(_ statistics: [String: Any]) -> Double? {
        share(statistics, "Device Utilization %") ?? share(statistics, "GPU Activity(%)")
    }

    /// A PerformanceStatistics percentage as a share, 0 to 1.
    static func share(_ statistics: [String: Any], _ key: String) -> Double? {
        (statistics[key] as? NSNumber).map { min(max($0.doubleValue / 100, 0), 1) }
    }

    /// "22 %".
    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded())) %" }

    /// Bytes per second between two readings of a 64-bit interface counter (if_data64, through NET_RT_IFLIST2 as Stats
    /// reads it, so it never wraps); a counter that went down was reset, by a reconnect, and counts as no reading.
    public static func rate(from old: UInt64, to new: UInt64, seconds: TimeInterval) -> Double? {
        guard seconds > 0, new >= old else { return nil }
        return Double(new - old) / seconds
    }

    /// "1.2 MB", "40 KB", "494 GB": decimal units, as Finder counts disks and networks count bytes.
    public static func decimal(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = bytes, unit = 0
        while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
        let digits = value < 10 && unit > 0 ? 1 : 0
        return String(format: "%.\(digits)f %@", value, units[unit])
    }

    /// Gigabytes of 1024³ bytes, as Activity Monitor counts memory.
    static func binary(_ bytes: UInt64, digits: Int) -> String {
        String(format: "%.\(digits)f", Double(bytes) / Double(1 << 30))
    }

    /// "3 d 4 h", "1 h 20 min", "12 min".
    public static func duration(minutes: Int) -> String {
        let d = minutes / 1440, h = minutes % 1440 / 60, m = minutes % 60
        if d > 0 { return "\(d) d \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        return "\(m) min"
    }
}

