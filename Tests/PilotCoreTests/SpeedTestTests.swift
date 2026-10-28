import Foundation
import Testing
@testable import PilotCore

/// Test internet speed (card agent-bo-95422772): macOS's own networkQuality, its JSON read here; the runner is faked,
/// so no test touches the network.
@Suite("Speed test")
@MainActor
struct SpeedTestTests {
    /// Recorded from `networkQuality -c` on Sven's Mac, 2026-10-05 (fields trimmed to the ones read).
    static let json = """
        {"base_rtt":53.708957672119141,"dl_throughput":887197184,"ul_throughput":54324452,\
        "responsiveness":383.8204345703125,"interface_name":"en0","start_date":"2026-10-05 10:22:36.412",\
        "end_date":"2026-10-05 10:22:53.088"}
        """

    @Test("The JSON reads as download and upload in Mbit/s and responsiveness; anything else is no result")
    func parse() {
        #expect(SpeedTest.summary(Self.json) == "Download 887 Mbit/s · Upload 54 Mbit/s · Responsiveness 384 RPM")
        #expect(SpeedTest.summary("networkQuality: no network") == nil)
        #expect(SpeedTest.summary(#"{"dl_throughput":1}"#) == nil)
    }

    @Test("One run at a time: it says it is testing, then the result; a press while it runs starts nothing")
    func oneAtATime() async {
        var said: [String] = [], runs = 0
        let test = SpeedTest(measure: { runs += 1; return Self.json }, say: { said.append($0) })
        let first = test.start()
        #expect(test.start() == nil)
        _ = await first?.value
        #expect(runs == 1)
        #expect(said == ["Testing internet speed…", "Download 887 Mbit/s · Upload 54 Mbit/s · Responsiveness 384 RPM"])
        #expect(!test.running)
    }

    @Test("Output that is not networkQuality's JSON says the test could not run, never the raw text")
    func brokenOutput() async {
        var said: [String] = []
        let test = SpeedTest(measure: { "networkQuality: no network" }, say: { said.append($0) })
        _ = await test.start()?.value
        #expect(said.last == "The speed test could not run; check the connection")
    }

    @Test("A failed run says so and frees the next press")
    func failure() async {
        var said: [String] = []
        struct Down: Error {}
        let test = SpeedTest(measure: { throw Down() }, say: { said.append($0) })
        _ = await test.start()?.value
        #expect(said.last == "The speed test could not run; check the connection")
        #expect(test.start() != nil)
    }
}
