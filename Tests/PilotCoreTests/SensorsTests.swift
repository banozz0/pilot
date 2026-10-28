import Foundation
import Testing
@testable import PilotCore

/// Temperatures, fans and power draw (card agent-bo-95422832), read as the Stats app reads them, through the SMC's private
/// interface; here only the decoding and grouping, on fixtures. A reading that fails or makes no sense is left out.
@Suite("Sensors")
struct SensorsTests {
    @Test("SMC values decode by their type: flt is a little-endian float, fpe2 and sp78 big-endian fixed point, ui8 to ui32")
    func decode() {
        #expect(SMCValue.decode(type: "flt ", bytes: [121, 93, 110, 66]).map { ($0 * 100).rounded() / 100 } == 59.59)
        #expect(SMCValue.decode(type: "fpe2", bytes: [0x1f, 0x40]) == 2000)       // 8000 / 4
        #expect(SMCValue.decode(type: "sp78", bytes: [0x2e, 0x80]) == 46.5)       // 46 + 128/256
        #expect(SMCValue.decode(type: "sp78", bytes: [0xff, 0x00]) == -1)
        #expect(SMCValue.decode(type: "ui8 ", bytes: [1]) == 1)
        #expect(SMCValue.decode(type: "ui16", bytes: [0x01, 0x02]) == 258)
        #expect(SMCValue.decode(type: "ui32", bytes: [0, 0, 5, 89]) == 1369)
        #expect(SMCValue.decode(type: "flt ", bytes: [1, 2]) == nil)
        #expect(SMCValue.decode(type: "{jst", bytes: [1, 2, 3, 4]) == nil)
    }

    static let sensors = SystemStats.Sensors(
        temperatures: ["Tp01": 59.6, "Tp05": 64.9, "Te05": 56.2, "Tg0j": 49.1, "Tg0k": 54.3, "Ts00": 49, "Ta01": 6,
                       "Tp0X": 400, "Te0Q": -3, "TB0T": 31],
        fans: [.init(actual: 1000, minimum: 1000, maximum: 4900)], power: 8.96)

    @Test("CPU is the P and E core sensors' average and hottest, GPU its own; nonsense values (below 0, above 150) are dropped")
    func groups() {
        let rounded = { (t: SystemStats.Temperature?) in t.map { [($0.average * 100).rounded() / 100, $0.hottest] } }
        #expect(rounded(SystemStats.temperature(Self.sensors.temperatures, prefixes: SystemStats.cpuSensors)) == [60.23, 64.9])
        #expect(rounded(SystemStats.temperature(Self.sensors.temperatures, prefixes: SystemStats.gpuSensors)) == [51.7, 54.3])
        #expect(SystemStats.temperature(["Ta01": 6], prefixes: SystemStats.gpuSensors) == nil)
        // The whole chip: the cores, the GPU and the chip's other sensors (Ts) together.
        #expect(rounded(SystemStats.temperature(Self.sensors.temperatures, prefixes: SystemStats.socSensors)) == [55.52, 64.9])
    }

    @Test("The rows: temperatures, each fan, power draw, each saying it may stop after a macOS update")
    func rows() {
        let rows = SystemStats.sensorRows(Self.sensors)
        #expect(rows.map(\.name) == ["SoC heat", "CPU heat", "GPU heat", "Fan", "Power"])
        #expect(rows[0].value == "56 °C · hottest 65 °C")
        #expect(rows[1].value == "60 °C · hottest 65 °C")
        #expect(rows[2].value == "52 °C · hottest 54 °C")
        #expect(rows[3].value == "1000 rpm · 1000 to 4900")
        #expect(rows[4].value == "9.0 W")
        // An Intel Mac's CPU sensors (TC) and its Ts keys, which are not on a chip there: no SoC row.
        #expect(!SystemStats.sensorRows(.init(temperatures: ["TC0P": 55, "Ts0P": 30], fans: [], power: nil)).map(\.name).contains("SoC heat"))
        for row in rows { #expect(row.explanation.contains("may stop after a macOS update"), "\(row.name)") }
        let twoFans = SystemStats.Sensors(temperatures: [:], fans: [.init(actual: 1200, minimum: 1000, maximum: 5000),
                                                                    .init(actual: 1300, minimum: 1000, maximum: 5000)], power: nil)
        #expect(SystemStats.sensorRows(twoFans).map(\.name) == ["Fan 1", "Fan 2"])
    }

    @Test("A Mac whose sensors cannot be read shows no sensor rows, and the rest of This Mac as before")
    func unreadable() {
        var now = SystemStatsTests.raw(time: 0)
        #expect(SystemStats.rows(previous: nil, now: now).filter { $0.name.contains("heat") || $0.name.hasPrefix("Fan") || $0.name == "Power" }.isEmpty)
        now.sensors = Self.sensors
        let names = SystemStats.rows(previous: nil, now: now).map(\.name)
        #expect(names.contains("CPU heat") && names.firstIndex(of: "CPU heat")! > names.firstIndex(of: "Heat")!)
        now.sensors = .init(temperatures: ["Tp01": 999], fans: [.init(actual: -5, minimum: 0, maximum: 0)], power: .nan)
        #expect(SystemStats.sensorRows(now.sensors!).isEmpty)
    }

    @Test("A fan range the SMC did not give, or gave as nonsense (NaN, infinite, past Int), is left off; the speed still shows")
    func badFanRange() {
        for (minimum, maximum) in [(Double.nan, 4900), (1000, .infinity), (-1e300, 1e300), (5000, 1000), (0, 0)] {
            let rows = SystemStats.sensorRows(.init(temperatures: [:], fans: [.init(actual: 1200, minimum: minimum, maximum: maximum)], power: nil))
            #expect(rows.map(\.value) == ["1200 rpm"], "\(minimum) \(maximum)")
        }
        let wild = SystemStats.sensorRows(.init(temperatures: [:], fans: [.init(actual: .infinity, minimum: 0, maximum: 1),
                                                                         .init(actual: .nan, minimum: 0, maximum: 1)], power: .infinity))
        #expect(wild.isEmpty)
    }

    @Test("A count the SMC gives is used only when it is a sensible whole number, so a bad one never traps")
    func counts() {
        #expect(SMCValue.count(1369, limit: 10_000) == 1369)
        #expect(SMCValue.count(2, limit: 4) == 2 && SMCValue.count(9, limit: 4) == 4)
        #expect(SMCValue.count(.nan, limit: 4) == 0 && SMCValue.count(-3, limit: 4) == 0 && SMCValue.count(.infinity, limit: 4) == 0)
        #expect(SMCValue.count(nil, limit: 4) == 0)
    }
}
