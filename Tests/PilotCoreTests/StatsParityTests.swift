import Foundation
import Testing
@testable import PilotCore

/// What the parity check against the Stats app found missing and built (card agent-bo-95422834). Fixtures only.
@Suite("Stats parity")
struct StatsParityTests {
    static func pair() -> (SystemStats.Raw, SystemStats.Raw) {
        var a = SystemStatsTests.raw(time: 0, cpu: .init(user: 100, system: 50, idle: 800, nice: 0))
        var b = SystemStatsTests.raw(time: 2, cpu: .init(user: 130, system: 60, idle: 860, nice: 0))   // 30 user, 10 system, 60 idle
        a.network = .init(received: 12_000_000_000, sent: 3_000_000_000)
        b.network = .init(received: 12_400_000_000, sent: 3_100_000_000)
        b.diskIO = .init(read: 1_294_000_000_000, written: 789_000_000_000)
        a.diskIO = b.diskIO
        return (a, b)
    }
    static func row(_ name: String, _ rows: [SystemStats.Row]) -> String? { rows.first { $0.name == name }?.value }

    @Test("CPU splits into user, system and idle as Stats' popup does; load average over 1, 5 and 15 minutes")
    func cpu() {
        var (a, b) = Self.pair()
        b.load = [1.2, 0.984, 0.85]
        let rows = SystemStats.rows(previous: a, now: b)
        #expect(Self.row("CPU split", rows) == "user 30 % · system 10 % · idle 60 %")
        #expect(Self.row("Load", rows) == "1.20 · 0.98 · 0.85")
        #expect(Self.row("CPU split", SystemStats.rows(previous: nil, now: b)) == "—")
        a.load = []
        #expect(Self.row("Load", SystemStats.rows(previous: nil, now: a)) == nil)
    }

    @Test("RAM use names the free memory too")
    func ramFree() {
        // 16 GiB less 600 000 used pages of 16 KiB.
        #expect(Self.row("RAM use", SystemStats.rows(previous: nil, now: Self.pair().1)) == "app 6.0 · wired 2.3 · compressed 0.9 · free 6.8 GB")
    }

    @Test("GPU: the renderer's and tiler's share and the chip's name and cores, where the accelerator gives them")
    func gpu() {
        let detail = SystemStats.GPUDetail.reading(["Device Utilization %": 22, "Renderer Utilization %": 30, "Tiler Utilization %": 12],
                                                   model: "Apple M4", cores: 10)
        #expect(detail == .init(renderer: 0.3, tiler: 0.12, model: "Apple M4", cores: 10))
        var (_, b) = Self.pair()
        b.gpu = 0.22
        b.gpuDetail = detail
        let rows = SystemStats.rows(previous: nil, now: b)
        #expect(Self.row("GPU parts", rows) == "renderer 30 % · tiler 12 %")
        #expect(Self.row("Graphics", rows) == "Apple M4 · 10 cores")
        b.gpuDetail = SystemStats.GPUDetail.reading(["GPU Activity(%)": 7], model: nil, cores: nil)
        #expect(Self.row("GPU parts", SystemStats.rows(previous: nil, now: b)) == nil)
        #expect(Self.row("Graphics", SystemStats.rows(previous: nil, now: b)) == nil)
    }

    @Test("Totals since start-up: what the startup disk read and wrote, what the network brought and sent")
    func totals() {
        let rows = SystemStats.rows(previous: nil, now: Self.pair().1)
        #expect(Self.row("Disk totals", rows) == "read 1.3 TB · written 789 GB")
        #expect(Self.row("Network totals", rows) == "↓ 12 GB · ↑ 3.1 GB")
    }

    @Test("Network details: the interface, its hardware address and the DNS servers")
    func networkDetails() {
        var (_, b) = Self.pair()
        b.slow.localIP = "192.168.0.240"
        b.slow.interface = .init(name: "en0", hardwareAddress: "a4:fc:14:00:00:01", dns: ["192.168.0.1", "1.1.1.1"])
        #expect(Self.row("Network details", SystemStats.rows(previous: nil, now: b)) == "en0 · a4:fc:14:00:00:01 · DNS 192.168.0.1, 1.1.1.1")
        b.slow.interface = nil
        #expect(Self.row("Network details", SystemStats.rows(previous: nil, now: b)) == nil)
    }

    @Test("Battery power: its temperature, voltage and current from the battery's registry entry, on a Mac with a battery")
    func batteryPower() {
        let power = SystemStats.BatteryPower.reading(["Temperature": 3050, "Voltage": 12_600, "Amperage": -1_234])
        #expect(power == .init(celsius: 30.5, volts: 12.6, amps: -1.234))
        #expect(SystemStats.BatteryPower.reading(["Voltage": 12_600]) == nil)
        var (_, b) = Self.pair()
        b.batteryPower = power
        #expect(Self.row("Battery power", SystemStats.rows(previous: nil, now: b)) == nil)   // no battery
        b.battery = .init(percent: 50, charging: false, minutesLeft: nil)
        #expect(Self.row("Battery power", SystemStats.rows(previous: nil, now: b)) == "30.5 °C · 12.6 V · -1.23 A · -15.5 W")
    }

    @Test("Combined processes, as the user has them in Stats: an app's helpers count under the app")
    func combined() {
        let list = KillProcess.parse("""
            1 10.0 100000 Google Chrome
            2 5.0 600000 Google Chrome Helper (Renderer)
            3 1.0 50000 Google Chrome Helper (GPU)
            4 20.0 200000 Finder
            5 2.0 10000 Code Helper (Plugin)
            """)
        let merged = SystemStats.combined(list)
        #expect(merged.first { $0.name == "Google Chrome" } == .init(pid: 1, cpu: 16, memoryKB: 750_000, name: "Google Chrome"))
        #expect(merged.first { $0.name == "Code" }?.memoryKB == 10_000)
        #expect(merged.count == 3)
        #expect(SystemStats.busiest(merged, by: .memory).first?.name == "Google Chrome")
    }

    @Test("This Mac's chip and macOS, as Stats' dashboard names them")
    func machine() {
        var (_, b) = Self.pair()
        b.slow.machine = .init(chip: "Apple M4", model: "Mac16,10", macOS: "27.0.1")
        #expect(Self.row("This Mac", SystemStats.rows(previous: nil, now: b)) == "Apple M4 · Mac16,10 · macOS 27.0.1")
    }

    @Test("Stats' Combined processes setting comes over with the menu-bar choices; the user's is on")
    func combinedSetting() {
        #expect(MenuBarStats.fromStats(["RAM_combinedProcesses": 1]).combineProcesses)
        #expect(!MenuBarStats.fromStats([:]).combineProcesses)
        // Choices saved before the setting existed still read, with it off.
        let old = Data(#"{"items":[{"stat":"cpu","on":true,"style":"text"}],"combined":true}"#.utf8)
        #expect((try? JSONDecoder().decode(MenuBarStats.Choices.self, from: old))?.combineProcesses == false)
    }
}

/// Moody's REJECT on the parity check (http://localhost:8228/p/EyYGTbH3T78): what it found Stats shows and Pilot did not.
extension StatsParityTests {
    @Test("The temperature item carries its label, as Stats' mini widget does with the user's Sensor_mini_label")
    func temperatureLabel() {
        var raw = SystemStatsTests.raw(time: 0)
        raw.sensors = .init(temperatures: ["Tp01": 59.6, "Tp05": 64.9], fans: [], power: nil)
        #expect(MenuBarStats.text(.sensors, values: nil, raw: raw) == "TEMP 62°")
    }

    @Test("Wi-Fi link: channel and band, signal and noise, rate and standard, never the network's name")
    func wifi() {
        var (_, b) = Self.pair()
        b.slow.wifi = .init(channel: 36, band: "5 GHz", signal: -52, noise: -92, rate: 866, standard: "802.11ax")
        #expect(Self.row("Wi-Fi", SystemStats.rows(previous: nil, now: b)) == "channel 36 · 5 GHz · −52 dBm · noise −92 dBm · 866 Mbit/s · 802.11ax")
        b.slow.wifi = nil
        #expect(Self.row("Wi-Fi", SystemStats.rows(previous: nil, now: b)) == nil)
    }

    @Test("Busiest by disk: each process's bytes read and written between two readings, the busiest first")
    func busiestDisk() {
        let names = [1: "Finder", 2: "mds", 3: "Code"].mapValues { $0 }
        let before: [Int32: SystemStats.DiskIO] = [1: .init(read: 0, written: 0), 2: .init(read: 1_000, written: 0), 3: .init(read: 5, written: 5)]
        let after: [Int32: SystemStats.DiskIO] = [1: .init(read: 200_000, written: 0), 2: .init(read: 4_001_000, written: 2_000_000),
                                                  3: .init(read: 5, written: 5), 4: .init(read: 9_000_000, written: 0)]
        let rows = SystemStats.busiestIO(before: before, after: after, seconds: 2, names: { names[Int($0)] })
        #expect(rows.map(\.name) == ["mds", "Finder"])      // a process new since the first reading has no rate yet; an idle one is left out
        #expect(rows.first?.value == "3.0 MB/s")
    }

    static let nettop = """
        ,bytes_in,bytes_out,
        launchd.1,0,0,
        apsd.582,14935,76390,
        Google Chrome H.4242,3396720,2838089,
        """

    @Test("Busiest by network: nettop's per-process byte counts, two snapshots apart, the busiest first")
    func busiestNetwork() {
        let first = SystemStats.nettop(Self.nettop)
        #expect(first["Google Chrome H.4242"] == .init(read: 3_396_720, written: 2_838_089))
        #expect(first.count == 3)
        let later = SystemStats.nettop(Self.nettop.replacingOccurrences(of: "3396720,2838089", with: "13396720,2838089")
            .replacingOccurrences(of: "14935,76390", with: "14935,96390"))
        // nettop cuts names short; ps's full name for the same pid wins where the process list has it.
        let rows = SystemStats.busiestNetwork(before: first, after: later, seconds: 5, names: { $0 == 4242 ? "Google Chrome Helper" : nil })
        #expect(rows.map(\.name) == ["Google Chrome Helper", "apsd"])
        #expect(rows.map(\.value) == ["↓ 2.0 MB/s ↑ 0 B/s", "↓ 0 B/s ↑ 4.0 KB/s"])
    }

    @Test("Battery power names the watts; the charger shows what it delivers now and at what voltage, on a Mac with a battery")
    func power() {
        var (_, b) = Self.pair()
        b.battery = .init(percent: 50, charging: true, pluggedIn: true, minutesLeft: nil)
        b.batteryPower = .init(celsius: 30.5, volts: 12.6, amps: 1.5)
        b.slow.chargerWatts = 96
        b.sensors = .init(temperatures: [:], fans: [], power: 14, powerIn: 45.2)
        b.adapterVolts = 20
        let rows = SystemStats.rows(previous: nil, now: b)
        #expect(Self.row("Battery power", rows) == "30.5 °C · 12.6 V · 1.50 A · 18.9 W")
        #expect(Self.row("Charger", rows) == "96 W · now 45.2 W at 20.0 V")
    }

    @Test("Disk details: the startup volume's file system and how the disk is connected")
    func diskDetails() {
        var (_, b) = Self.pair()
        b.slow.diskKind = .init(fileSystem: "APFS", connection: "Apple Fabric")
        #expect(Self.row("Disk details", SystemStats.rows(previous: nil, now: b)) == "APFS · Apple Fabric")
    }
}
