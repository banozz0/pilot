import Foundation
import Testing
@testable import Pilot

/// Setup › Wi-Fi (card agent-bo-95422803): the switch, the signal, and, once Location access is given, the network's name;
/// the networks nearby are macOS's own settings. Every case runs on a fake; no test turns Wi-Fi off, scans, joins or asks
/// for Location.
@MainActor
@Suite("Setup Wi-Fi")
struct SetupWiFiTests {
    final class FakeWiFi: WiFiSystem {
        var power = true
        var location = PrivacyAccess.notAsked
        /// What Sven answers macOS's Location prompt with.
        var answer = PrivacyAccess.allowed
        var joined: String? = "Home"
        var nearby = [WiFiNetwork(name: "Cafe", signal: -71, secured: false), WiFiNetwork(name: "Home", signal: -48, secured: true),
                      WiFiNetwork(name: "Neighbour", signal: -80, secured: true), WiFiNetwork(name: "Home", signal: -60, secured: true)]
        var powerCalls: [Bool] = [], scans: [Bool] = [], asked = 0
        var joins: [(name: String, password: String?)] = []

        func status() -> WiFiStatus? {
            WiFiStatus(on: power, network: location == .allowed && power ? joined : nil, signal: power ? -48 : nil, rate: power ? 866 : nil)
        }
        func isOn() -> Bool? { power }
        func setPower(_ on: Bool) async throws { powerCalls.append(on); power = on }
        func locationAccess() -> PrivacyAccess { location }
        func requestLocation() async -> PrivacyAccess {
            if location == .notAsked { asked += 1; location = answer }
            return location
        }
        func scan(fresh: Bool) async throws -> [WiFiNetwork] { scans.append(fresh); return nearby }
        func join(_ name: String, password: String?) async throws { joins.append((name, password)); joined = name }
    }

    @Test("The switch calls setPower once with the new state")
    func power() async {
        let wifi = FakeWiFi(), section = SetupWiFi(wifi: wifi)
        section.start()
        #expect(section.status?.on == true && section.status?.signal == -48)
        await section.setPower(false)
        #expect(wifi.powerCalls == [false] && section.status?.on == false)
    }

    @Test("The page reads the status and macOS's stored Location answer only: it never asks, scans or joins")
    func readsOnly() {
        for access in [PrivacyAccess.notAsked, .denied, .allowed] {
            let wifi = FakeWiFi()
            wifi.location = access
            let section = SetupWiFi(wifi: wifi)
            section.start()
            // Allowed, the name shows, so the answer is not read; otherwise it words the hidden name.
            #expect(section.status?.network == (access == .allowed ? "Home" : nil) && section.checked)
            #expect(section.location == (access == .allowed ? .notAsked : access))
            #expect(wifi.asked == 0 && wifi.scans.isEmpty && wifi.joins.isEmpty)
        }
        #expect(SetupWiFi.hiddenLine.contains("Location") && SetupWiFi.deniedLine.contains("Privacy & Security"))
    }

    @Test("Info.plist says why Pilot asks for Location: macOS shows Wi-Fi names only to apps that have it")
    func usageDescription() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Info.plist").standardized
        let info = try #require(NSDictionary(contentsOf: plist))
        // macOS reads NSLocationUsageDescription; the When In Use key is iOS's and stays beside it, worded the same.
        let why = try #require(info["NSLocationUsageDescription"] as? String)
        #expect(why.contains("Wi-Fi") && why.contains("nothing else"))
        #expect(info["NSLocationWhenInUseUsageDescription"] as? String == why)
    }

    /// The real Wi-Fi interface, read-only: opt-in like every live test. Reads power and signal; never scans or joins.
    @Test("CoreWLAN reads this Mac's Wi-Fi power and signal", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func live() {
        let status = CoreWLANSystem().status()
        print("live: wi-fi \(String(describing: status.map { ($0.on, $0.signal ?? 0, $0.network == nil ? "name hidden" : "name shown") }))")
        #expect(status != nil)
    }
}
