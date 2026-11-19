import Foundation
import Testing
@testable import PilotCore

/// What This Mac shows beyond the totals, as the Stats app shows it (card agent-bo-95422831): each core, the busiest
/// processes, disk speed, the local IP, battery health and the charger, Bluetooth batteries. Fixtures only.
@Suite("System stats, more")
struct SystemStatsMoreTests {
    static func raw(time: TimeInterval = 0) -> SystemStats.Raw {
        var raw = SystemStatsTests.raw(time: time)
        raw.efficiencyCores = 2
        return raw
    }

    @Test("Each core's busy share between two samples, efficiency cores first as macOS numbers them")
    func cores() {
        var a = Self.raw(time: 0), b = Self.raw(time: 2)
        a.cores = [.init(user: 0, system: 0, idle: 100, nice: 0), .init(user: 0, system: 0, idle: 100, nice: 0),
                   .init(user: 10, system: 0, idle: 90, nice: 0)]
        b.cores = [.init(user: 25, system: 0, idle: 175, nice: 0), .init(user: 0, system: 0, idle: 200, nice: 0),
                   .init(user: 80, system: 10, idle: 110, nice: 0)]
        #expect(SystemStats.coreLoads(from: a.cores, to: b.cores) == [0.25, 0, 0.8])
        #expect(SystemStats.rows(previous: a, now: b).first { $0.name == "CPU cores" }?.value == "E 25 0 · P 80 %")
        #expect(SystemStats.rows(previous: nil, now: b).first { $0.name == "CPU cores" }?.value == "—")
        b.cores = []
        #expect(!SystemStats.rows(previous: a, now: b).map(\.name).contains("CPU cores"))
    }

    static let ps = """
          1398  89.7 239776 Finder
           612  49.3 113280 WindowServer
         78597  12.7 632816 Google Chrome Helper (Renderer)
         24299  33.3 2496448 claude
          1735   2.5  72272 Stats
             1   1.1  23248 launchd
          garbage line
        """

    @Test("The busiest five by CPU and by RAM from ps's listing, Pilot itself included; names keep their spaces")
    func processes() {
        let list = KillProcess.parse(Self.ps)
        #expect(list.count == 6)
        #expect(list.contains(.init(pid: 78597, cpu: 12.7, memoryKB: 632_816, name: "Google Chrome Helper (Renderer)")))
        #expect(SystemStats.busiest(KillProcess.parse(Self.ps + "\n 4242 50.0 50000 Pilot"), by: .cpu).contains { $0.name == "Pilot" })
        #expect(SystemStats.busiest(list, by: .cpu).map(\.name) == ["Finder", "WindowServer", "claude", "Google Chrome Helper (Renderer)", "Stats"])
        #expect(SystemStats.busiest(list, by: .cpu).first?.value == "89.7 %")
        #expect(SystemStats.busiest(list, by: .memory).map(\.name).prefix(2) == ["claude", "Google Chrome Helper (Renderer)"])
        #expect(SystemStats.busiest(list, by: .memory).map(\.value).prefix(2) == ["2.4 GB", "618 MB"])
    }

    @Test("Disk speed: bytes the startup disk's driver read and wrote between samples; a reset counter shows a dash")
    func diskSpeed() {
        let io = SystemStats.diskIO(["Bytes (Read)": 3_000, "Bytes (Write)": 500, "Operations (Read)": 3])
        #expect(io == .init(read: 3_000, written: 500))
        #expect(SystemStats.diskIO(["Other": 1]) == nil && SystemStats.diskIO(nil) == nil)
        var a = Self.raw(time: 0), b = Self.raw(time: 2)
        a.diskIO = io
        b.diskIO = .init(read: 2_403_000, written: 80_500)
        #expect(SystemStats.rows(previous: a, now: b).first { $0.name == "Disk speed" }?.value == "read 1.2 MB/s · write 40 KB/s")
        b.diskIO = .init(read: 10, written: 10)
        #expect(SystemStats.rows(previous: a, now: b).first { $0.name == "Disk speed" }?.value == "—")
    }

    @Test("IP: the local address; the public one only when it was read, which only happens with its setting on")
    func ip() {
        var now = Self.raw()
        #expect(!SystemStats.rows(previous: nil, now: now).map(\.name).contains("IP"))
        now.slow.localIP = "192.168.1.20"
        #expect(SystemStats.rows(previous: nil, now: now).first { $0.name == "IP" }?.value == "192.168.1.20")
        let rows = SystemStats.rows(SystemStats.values(previous: nil, now: now), now: now, publicIP: "203.0.113.7")
        #expect(rows.first { $0.name == "IP" }?.value == "192.168.1.20 · public 203.0.113.7")
    }

    @Test("Battery health is the battery's full charge against its design, with its cycles; the charger shows its watts")
    func batteryHealth() {
        let health = SystemStats.BatteryHealth.reading(["CycleCount": 312, "AppleRawMaxCapacity": 4_600, "DesignCapacity": 5_000,
                                                        "NominalChargeCapacity": 4_700])
        #expect(health == .init(cycles: 312, percent: 92))
        #expect(SystemStats.BatteryHealth.reading(["CycleCount": 3, "NominalChargeCapacity": 4_900, "DesignCapacity": 5_000])?.percent == 98)
        #expect(SystemStats.BatteryHealth.reading(["CycleCount": 3]) == nil)
        var now = Self.raw()
        now.battery = .init(percent: 80, charging: false, minutesLeft: nil)
        now.slow.batteryHealth = health
        now.slow.chargerWatts = 96
        let rows = SystemStats.rows(previous: nil, now: now)
        #expect(rows.first { $0.name == "Battery health" }?.value == "92 % · 312 cycles")
        #expect(rows.first { $0.name == "Charger" }?.value == "96 W")
        now.battery = nil
        #expect(SystemStats.rows(previous: nil, now: now).filter { ["Battery health", "Charger"].contains($0.name) }.isEmpty)
    }

    static let profiler = Data("""
        {"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on"},
          "device_connected":[{"Sven's AirPods Pro":{"device_batteryLevelLeft":"90%","device_batteryLevelRight":"85%",
            "device_batteryLevelCase":"40%","device_minorType":"Headphones"}},
            {"MX Keys":{"device_batteryLevelMain":"60%"}},
            {"Speaker":{"device_minorType":"Speaker"}}],
          "device_not_connected":[{"Old Mouse":{"device_batteryLevelMain":"5%"}}]}]}
        """.utf8)

    @Test("Bluetooth batteries: HID devices from the registry, headphones from system_profiler; connected only; none, no row")
    func bluetooth() {
        let devices = SystemStats.bluetooth(hid: [["Product": "Magic Trackpad", "BatteryPercent": 71], ["Product": "No battery"]],
                                            profiler: Self.profiler)
        #expect(devices == [.init(name: "Magic Trackpad", level: "71 %"),
                            .init(name: "Sven's AirPods Pro", level: "L 90 % · R 85 % · case 40 %", fromProfiler: true),
                            .init(name: "MX Keys", level: "60 %", fromProfiler: true)])
        // The lowest earbud, the case only when alone.
        #expect(devices.map(\.percent) == [71, 85, 60])
        #expect(SystemStats.BluetoothDevice(name: "Case", level: "case 30 %").percent == 30)
        #expect(SystemStats.bluetooth(hid: [], profiler: Data("not json".utf8)).isEmpty)
        var now = Self.raw()
        now.slow.bluetooth = devices
        let rows = SystemStats.rows(previous: nil, now: now)
        #expect(rows.first { $0.name == "Magic Trackpad" }?.value == "71 %")
        now.slow.bluetooth = []
        #expect(SystemStats.rows(previous: nil, now: now).count == SystemStats.rows(previous: nil, now: Self.raw()).count)
    }

    @Test("The battery reads its percentage, charging or plugged in, then the time to full or left")
    func battery() {
        #expect(SystemStats.Battery(percent: 82, charging: true, pluggedIn: true, minutesLeft: 80).phrase == "82 % · charging · 1 h 20 min to full")
        #expect(SystemStats.Battery(percent: 54, charging: false, minutesLeft: 190).phrase == "54 % · 3 h 10 min left")
        #expect(SystemStats.Battery(percent: 100, charging: false, pluggedIn: true, minutesLeft: nil).phrase == "100 % · plugged in")
    }
}
