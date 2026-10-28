import Foundation
import Testing
@testable import PilotCore

/// A tick reads only what is shown (card agent-bo-95422836): Pilot cost more than Stats with only CPU and RAM in the menu
/// bar, because every tick read and laid out all of This Mac.
@Suite("Reading parts")
struct ReadingPartsTests {
    @Test("Each menu-bar reading needs only its own part; This Mac's rows need them all")
    func parts() {
        #expect(MenuBarStats.Stat.cpu.parts == .cpu && MenuBarStats.Stat.ram.parts == .memory)
        #expect(MenuBarStats.Stat.disk.parts == [.diskSpace, .diskIO] && MenuBarStats.Stat.bluetooth.parts == .bluetooth)
        #expect(MenuBarStats.Stat.sensors.parts == .sensors && MenuBarStats.Stat.network.parts == .network)
        let union = MenuBarStats.Stat.allCases.reduce(SystemStats.Parts()) { $0.union($1.parts) }
        #expect(SystemStats.Parts.all.isSuperset(of: union) && union != .all)
        #expect(!SystemStats.Parts.all.contains(.processes))
    }

    @Test("A rate needs both readings to have measured it: a part read only now gives no rate, never one from zero")
    func ratesNeedBothReadings() {
        var before = SystemStatsTests.raw(time: 0, cpu: .init(user: 0, system: 0, idle: 0, nice: 0), received: 0, sent: 0)
        before.parts = [.cpu, .memory]   // the menu bar's CPU and RAM only: network not read, its counters zero
        let now = SystemStatsTests.raw(time: 1, cpu: .init(user: 100, system: 0, idle: 300, nice: 0), received: 12_000_000_000, sent: 9)
        let v = SystemStats.values(previous: before, now: now)
        #expect(v.cpu == 0.25)
        #expect(v.down == nil && v.up == nil)
        before.parts = [.memory]
        #expect(SystemStats.values(previous: before, now: now).cpu == nil)
    }
}
