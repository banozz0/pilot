import Foundation
import Testing
@testable import PilotCore

/// Home's This Mac section (card agent-bo-95422788), modelled on exelban/stats (MIT): its behaviour and the public APIs it
/// reads, no code. Two samples make a rate; everything here is arithmetic and wording on fixtures.
@Suite("System stats")
struct SystemStatsTests {
    static let gb: UInt64 = 1 << 30

    static func raw(time: TimeInterval, cpu: SystemStats.CPUTicks = .init(user: 0, system: 0, idle: 0, nice: 0),
                    received: UInt64 = 0, sent: UInt64 = 0, battery: SystemStats.Battery? = nil,
                    thermal: SystemStats.Thermal = .nominal) -> SystemStats.Raw {
        let page: UInt64 = 16384
        let memory = SystemStats.Memory(total: 16 * gb, pageSize: page, active: 300_000, inactive: 200_000, speculative: 10_000,
                                        wired: 150_000, compressed: 60_000, purgeable: 20_000, external: 100_000, pressure: .normal,
                                        swapUsed: 0, swapTotal: 0)
        var raw = SystemStats.Raw(time: time, cpu: cpu, memory: memory, network: .init(received: received, sent: sent), battery: battery,
                                  thermal: thermal, uptime: 3 * 86400 + 4 * 3600 + 120, gpu: nil)
        raw.slow.disk = .init(available: 120_000_000_000, total: 494_000_000_000)
        return raw
    }

    @Test("CPU is the busy share of the ticks between two samples; the first sample has none")
    func cpu() {
        let a = SystemStats.CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let b = SystemStats.CPUTicks(user: 160, system: 70, idle: 900, nice: 70)   // busy 100 of 200
        #expect(SystemStats.cpuLoad(from: a, to: b) == 0.5)
        #expect(SystemStats.cpuLoad(from: a, to: a) == nil)
        let rows = SystemStats.rows(previous: nil, now: Self.raw(time: 0, cpu: a))
        #expect(rows.first { $0.name == "CPU" }?.value == "—")
        #expect(SystemStats.rows(previous: Self.raw(time: 0, cpu: a), now: Self.raw(time: 2, cpu: b)).first { $0.name == "CPU" }?.value == "50 %")
    }

    @Test("Memory used is Stats' sum: active, inactive, speculative, wired and compressed, less purgeable and file-backed")
    func memory() {
        let m = Self.raw(time: 0).memory
        #expect(m.used == (300_000 + 200_000 + 10_000 + 150_000 + 60_000 - 20_000 - 100_000) * 16384)
        #expect(SystemStats.Pressure(level: 4) == .critical && SystemStats.Pressure(level: 2) == .warning && SystemStats.Pressure(level: 1) == .normal)
        #expect(SystemStats.rows(previous: nil, now: Self.raw(time: 0)).first { $0.name == "RAM" }?.value == "9.2 of 16 GB · pressure normal")
    }

    @Test("RAM splits as Stats does: app is used less wired and compressed; swap is used of total from vm.swapusage")
    func ramParts() {
        var now = Self.raw(time: 0)
        now.memory.swapUsed = 512 << 20; now.memory.swapTotal = 2 * Self.gb
        // used 600 000 pages; wired 150 000 and compressed 60 000 pages; app 390 000 pages, at 16 KiB each.
        #expect(now.memory.app == 390_000 * 16384)
        let rows = SystemStats.rows(previous: nil, now: now)
        #expect(rows.first { $0.name == "RAM use" }?.value == "app 6.0 · wired 2.3 · compressed 0.9 · free 6.8 GB")
        #expect(rows.first { $0.name == "Swap" }?.value == "0.5 of 2.0 GB")
        now.memory.swapTotal = 0; now.memory.swapUsed = 0
        #expect(SystemStats.rows(previous: nil, now: now).first { $0.name == "Swap" }?.value == "none")
        // Wired and compressed above the used sum (purgeable pages counted as freed) never make app negative.
        now.memory.purgeable = 900_000
        #expect(now.memory.app == 0)
    }

    @Test("GPU is the accelerator's own busy percent: Device Utilization % on Apple silicon, GPU Activity(%) on AMD, else no row")
    func gpu() {
        #expect(SystemStats.gpuLoad(["Device Utilization %": 22, "Renderer Utilization %": 30, "Alloc system memory": 1_712_734_208]) == 0.22)
        #expect(SystemStats.gpuLoad(["GPU Activity(%)": 7]) == 0.07)
        #expect(SystemStats.gpuLoad(["Alloc system memory": 5]) == nil)
        #expect(SystemStats.gpuLoad(["Device Utilization %": 140]) == 1)
        var now = Self.raw(time: 0)
        #expect(!SystemStats.rows(previous: nil, now: now).map(\.name).contains("GPU"))
        now.gpu = 0.22
        #expect(SystemStats.rows(previous: nil, now: now).first { $0.name == "GPU" }?.value == "22 %")
    }

    @Test("Network is bytes per second between samples; a counter that went down was reset and counts nothing")
    func network() {
        let down = SystemStats.rate(from: 1_000, to: 2_401_000, seconds: 2)
        #expect(down == 1_200_000)
        #expect(SystemStats.rate(from: 3_000_000_000, to: 5, seconds: 2) == nil)
        #expect(SystemStats.rate(from: 5, to: 5, seconds: 0) == nil)
        let rows = SystemStats.rows(previous: Self.raw(time: 0, received: 0, sent: 0), now: Self.raw(time: 2, received: 2_400_000, sent: 80_000))
        #expect(rows.first { $0.name == "Network" }?.value == "↓ 1.2 MB/s  ↑ 40 KB/s")
    }

    @Test("Each row has a one-line explanation; battery shows only on a Mac with one; disk, heat and uptime read plainly")
    func rows() {
        let none = SystemStats.rows(previous: nil, now: Self.raw(time: 0))
        #expect(none.map(\.name) == ["CPU", "CPU split", "RAM", "RAM use", "Swap", "Disk", "Network", "Network totals", "Heat", "Uptime"])
        for row in none { #expect(!row.explanation.isEmpty && !row.explanation.contains("\n") && row.explanation.count <= 100, "\(row.name)") }
        #expect(none.first { $0.name == "Disk" }?.value == "120 GB free of 494 GB")
        #expect(none.first { $0.name == "Heat" }?.value == "Nominal")
        #expect(none.first { $0.name == "Uptime" }?.value == "3 d 4 h")
        let laptop = SystemStats.rows(previous: nil, now: Self.raw(time: 0, battery: .init(percent: 80, charging: true, minutesLeft: 80)))
        #expect(laptop.map(\.name).contains("Battery"))
        #expect(laptop.first { $0.name == "Battery" }?.value == "80 % · charging · 1 h 20 min to full")
    }

    @Test("Rates use the awake clock; Uptime is wall time since boot, so a Mac that slept still shows its whole uptime")
    func clocks() {
        var a = Self.raw(time: 100, received: 0), b = Self.raw(time: 102, received: 2_000_000)
        a.uptime = 50_000; b.uptime = 90_000   // slept in between: the wall clock moved far more than the awake one
        #expect(SystemStats.rows(previous: a, now: b).first { $0.name == "Network" }?.value.hasPrefix("↓ 1.0 MB/s") == true)
        #expect(SystemStats.rows(previous: a, now: b).first { $0.name == "Uptime" }?.value == "1 d 1 h")
    }

    @Test("Battery: time to full only while charging, time left only on battery power, none on AC when charged")
    func batteryTimes() {
        let charged = SystemStats.Battery.reading(percent: 100, charging: false, onACPower: true, toFull: 0, toEmpty: 0)
        #expect(charged == .init(percent: 100, charging: false, pluggedIn: true, minutesLeft: nil))
        #expect(SystemStats.Battery.reading(percent: 60, charging: true, onACPower: true, toFull: 45, toEmpty: 0).minutesLeft == 45)
        #expect(SystemStats.Battery.reading(percent: 60, charging: false, onACPower: false, toFull: 0, toEmpty: 200).minutesLeft == 200)
        #expect(SystemStats.Battery.reading(percent: 60, charging: false, onACPower: false, toFull: 0, toEmpty: -1).minutesLeft == nil)
        let rows = SystemStats.rows(previous: nil, now: Self.raw(time: 0, battery: charged))
        #expect(rows.first { $0.name == "Battery" }?.value == "100 % · plugged in")
    }
}
