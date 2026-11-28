import Foundation
@testable import PilotCore
import Testing

/// Pilot's checks inside the app (setup-overhaul T40), fed made-up times and footprints: nothing sleeps or allocates. The
/// real stall and spike are the sandbox host's (`<socket>.stall`, `<socket>.spike`).
@Suite("Diagnostics")
struct DiagnosticsTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func ns(_ seconds: Double) -> UInt64 { UInt64(seconds * 1e9) }

    @Test("A busy gap past the line is one stall, timed from its start; a wait for work is none")
    func stall() {
        let checks = Diagnostics(footprint: { nil })
        checks.step(waiting: false, nanos: ns(100), date: start)
        checks.step(waiting: true, nanos: ns(100.1), date: start.addingTimeInterval(0.1))
        checks.step(waiting: false, nanos: ns(160), date: start.addingTimeInterval(60))   // a minute asleep waiting: no stall
        checks.step(waiting: false, nanos: ns(161), date: start.addingTimeInterval(61))   // 1 s busy: under the line
        checks.tick(nanos: ns(164), date: start.addingTimeInterval(64))                   // still going: logged, not kept
        checks.step(waiting: false, nanos: ns(164.2), date: start.addingTimeInterval(64.2))
        #expect(checks.findings.count == 1)
        let stall = checks.findings.first
        #expect(stall?.kind == .stall)
        #expect(abs((stall?.amount ?? 0) - 3.2) < 0.001)
        #expect(stall?.time == start.addingTimeInterval(61))
    }

    @Test("A footprint over the line is one spike at its peak until it falls back under the re-arm share")
    func spike() {
        let readings = ReadingQueue([300, 1100, 1300, 900, 700, 1200])
        let checks = Diagnostics(footprint: { readings.next() })
        for n in 0..<6 { checks.tick(nanos: ns(Double(n * 5)), date: start.addingTimeInterval(Double(n * 5))) }
        #expect(checks.findings.map(\.kind) == [.memory, .memory])
        #expect(checks.findings.map(\.amount) == [1300, 1200])
        #expect(checks.findings.map(\.time) == [start.addingTimeInterval(5), start.addingTimeInterval(25)])
    }

    @Test("The footprint reader reads this process")
    func footprint() {
        #expect((Diagnostics.footprintMB() ?? 0) > 1)
    }
}

/// Footprints handed out one per read.
private final class ReadingQueue: @unchecked Sendable {
    private var left: [Double]
    init(_ readings: [Double]) { left = readings }
    func next() -> Double? { left.isEmpty ? nil : left.removeFirst() }
}
