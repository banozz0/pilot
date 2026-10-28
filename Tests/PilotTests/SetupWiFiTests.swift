import Foundation
import Testing
@testable import Pilot

/// Setup › Wi-Fi (card agent-bo-95422803): the switch, the signal, and, once Location access is given, the network's name
/// and the networks nearby to join. Every case runs on a fake; no test turns Wi-Fi off, scans, joins or asks for Location.
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

    static func defaults(shown: Bool = false) -> UserDefaults { setupDefaults(SetupWiFi.shownKey, shown: shown) }

    @Test("The switch calls setPower once with the new state")
    func power() async {
        let wifi = FakeWiFi(), section = SetupWiFi(wifi: wifi, defaults: Self.defaults())
        await section.start()
        #expect(section.status?.on == true && section.status?.signal == -48)
        await section.setPower(false)
        #expect(wifi.powerCalls == [false] && section.status?.on == false)
    }

    @Test("Without Location access: no network name, the line saying why, and no scan, not even after starting again")
    func noLocation() async {
        let wifi = FakeWiFi()
        wifi.location = .denied
        let section = SetupWiFi(wifi: wifi, defaults: Self.defaults(shown: true))
        await section.start()
        await section.refreshNetworks(fresh: true)
        #expect(section.status?.network == nil && section.networks.isEmpty && wifi.scans.isEmpty)
        #expect(section.location == .denied)
        #expect(SetupWiFi.hiddenLine.contains("Location") && SetupWiFi.deniedLine.contains("Privacy & Security"))
    }

    @Test("Nothing asks for Location before Show networks; Show asks once, then lists the networks strongest first, joined one marked")
    func showNetworks() async {
        let wifi = FakeWiFi(), store = Self.defaults()
        let section = SetupWiFi(wifi: wifi, defaults: store)
        await section.start()
        #expect(wifi.asked == 0 && wifi.scans.isEmpty && section.offersShow)
        await section.showNetworks()
        #expect(wifi.asked == 1 && wifi.scans == [true] && !section.offersShow)
        #expect(section.status?.network == "Home")
        #expect(section.networks.map(\.name) == ["Home", "Cafe", "Neighbour"])
        #expect(section.networks.first?.signal == -48)
        #expect(section.isJoined(section.networks[0]) && !section.isJoined(section.networks[1]))
        // The press is remembered: the next page show lists macOS's last scan without asking or scanning the radio.
        let again = SetupWiFi(wifi: wifi, defaults: store)
        await again.start()
        #expect(wifi.asked == 1 && wifi.scans == [true, false] && again.networks.count == 3)
    }

    @Test("Joining a secured network passes the typed password once, and the section keeps no copy of it")
    func join() async {
        let wifi = FakeWiFi(), section = SetupWiFi(wifi: wifi, defaults: Self.defaults(shown: true))
        wifi.location = .allowed
        await section.start()
        let neighbour = section.networks[2], typed = "hunter22-sample"
        await section.join(neighbour, password: typed)
        #expect(wifi.joins.count == 1 && wifi.joins[0].name == "Neighbour" && wifi.joins[0].password == typed)
        #expect(section.status?.network == "Neighbour" && section.problem == nil)
        #expect(!String(describing: Mirror(reflecting: section).children.map(\.value)).contains(typed))
        // An open network joins with no password at all.
        await section.join(section.networks.first { $0.name == "Cafe" }!, password: "ignored")
        #expect(wifi.joins.count == 2)
        #expect(wifi.joins.last?.password == nil)
        // A secured network this Mac already knows joins with no password typed: macOS uses the one it saved.
        await section.join(neighbour, password: nil)
        #expect(wifi.joins.count == 3 && wifi.joins.last?.name == "Neighbour" && wifi.joins.last?.password == nil)
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
