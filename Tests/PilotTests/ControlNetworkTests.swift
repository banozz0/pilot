import Foundation
import PilotCore
import Testing
@testable import Pilot

/// `pilot wifi` and `pilot bluetooth` (CLI W8), asked through the registry the socket answers from, on the Setup page's
/// fakes: no test turns Wi-Fi off, scans, joins, connects a real device or raises macOS's Location or Bluetooth prompt.
@MainActor
@Suite("Control network")
struct ControlNetworkTests {
    /// The Setup fake, with a Mac that has no Wi-Fi and a join or switch macOS refuses.
    final class RefusingWiFi: WiFiSystem {
        let fake = SetupWiFiTests.FakeWiFi()
        var present = true, refuses = false
        struct Refused: LocalizedError { var errorDescription: String? { "the operation couldn't be completed" } }

        func status() -> WiFiStatus? { present ? fake.status() : nil }
        func isOn() -> Bool? { present ? fake.isOn() : nil }
        func setPower(_ on: Bool) async throws { if refuses { throw Refused() }; try await fake.setPower(on) }
        func locationAccess() -> PrivacyAccess { fake.locationAccess() }
        func requestLocation() async -> PrivacyAccess { await fake.requestLocation() }
        func scan(fresh: Bool) async throws -> [WiFiNetwork] { try await fake.scan(fresh: fresh) }
        func join(_ name: String, password: String?) async throws { if refuses { throw Refused() }; try await fake.join(name, password: password) }
    }

    @MainActor final class Rig {
        let wifi = RefusingWiFi()
        let bluetooth = SetupBluetoothTests.FakeBluetooth()
        let verbs = ControlVerbs()
        var fake: SetupWiFiTests.FakeWiFi { wifi.fake }
        /// Every Allow the verbs asked, in words, answered `allows`: never Pilot's prompt (T52).
        var asked: [String] = [], allows = true

        init(location: PrivacyAccess = .allowed) {
            let tools = NetworkTools()
            tools.wifi = wifi
            tools.bluetooth = bluetooth
            wifi.fake.location = location
            tools.gate = ControlGate { [weak self] ask, _ in
                self?.asked.append(ask.text)
                return self?.allows ?? false
            }
            verbs.registerNetwork(tools)
        }

        func ask(_ verb: String, _ args: String...) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil)
        }
    }

    static func field(_ answer: ControlAnswer, _ name: String) -> JSONValue? {
        if case .object(let o)? = answer.result { o[name] } else { nil }
    }

    static func rows(_ value: JSONValue?) -> [[String: JSONValue]] {
        guard case .array(let rows)? = value else { return [] }
        return rows.compactMap { if case .object(let o) = $0 { o } else { nil } }
    }

    @Test("wifi reads the switch, the signal, the rate and Location; the name only with Location; a Mac without Wi-Fi says so")
    func status() async {
        let rig = Rig()
        let on = await rig.ask("wifi")
        #expect(Self.field(on, "present") == .bool(true) && Self.field(on, "on") == .bool(true))
        #expect(Self.field(on, "network") == .string("Home") && Self.field(on, "signal") == .number(-48) && Self.field(on, "rate") == .number(866))
        #expect(Self.field(on, "location") == .string("allowed"))

        rig.fake.location = .denied
        let hidden = await rig.ask("wifi", "status")
        #expect(Self.field(hidden, "network") == nil && Self.field(hidden, "location") == .string("denied"))

        rig.wifi.present = false
        #expect(await rig.ask("wifi").result == .object(["present": .bool(false)]))
        #expect(rig.fake.asked == 0)
    }

    @Test("wifi off and on ask Allow, call setPower once each and answer the status after; a deny runs nothing; macOS's refusal is the page's line")
    func power() async {
        let rig = Rig()
        let off = await rig.ask("wifi", "off")
        #expect(rig.fake.powerCalls == [false] && Self.field(off, "on") == .bool(false) && Self.field(off, "signal") == nil)
        #expect(Self.field(await rig.ask("wifi", "on"), "on") == .bool(true) && rig.fake.powerCalls == [false, true])
        #expect(rig.asked == ["Turn Wi-Fi off: pilot wifi off", "Turn Wi-Fi on: pilot wifi on"])

        rig.allows = false
        #expect(await rig.ask("wifi", "off").error?.code == .denied && rig.fake.powerCalls == [false, true])
        rig.allows = true

        rig.wifi.refuses = true
        let refused = await rig.ask("wifi", "off")
        #expect(refused.error?.code == .badValue && refused.error?.message.hasPrefix("macOS did not turn Wi-Fi off") == true)
    }

    @Test("networks: strongest first, each name once, the joined one marked; --fresh scans the radio, plain reads the last scan")
    func networks() async {
        let rig = Rig()
        let rows = Self.rows(await rig.ask("wifi", "networks").result)
        #expect(rows.map { $0["name"] } == [.string("Home"), .string("Cafe"), .string("Neighbour")])
        #expect(rows[0]["signal"] == .number(-48) && rows[0]["secured"] == .bool(true) && rows[0]["joined"] == .bool(true))
        #expect(rows[1]["joined"] == .bool(false) && rows[1]["secured"] == .bool(false))
        _ = await rig.ask("wifi", "networks", "--fresh")
        #expect(rig.fake.scans == [false, true])
        #expect(await rig.ask("wifi", "status", "--fresh").error?.code == .unknownFlag)
    }

    @Test("Without Location or with Wi-Fi off, networks and join answer not-ready with the page, and never ask or scan")
    func blocked() async {
        let rig = Rig(location: .notAsked)
        let notAsked = await rig.ask("wifi", "networks")
        #expect(notAsked.error?.code == .notReady && notAsked.error?.message.contains("pilot open system --section wifi") == true)
        #expect(notAsked.error?.message.contains(SetupWiFi.hiddenLine) == true)
        rig.fake.location = .denied
        #expect(await rig.ask("wifi", "join", "Cafe").error?.message.contains(SetupWiFi.deniedLine) == true)
        rig.fake.location = .allowed
        rig.fake.power = false
        #expect(await rig.ask("wifi", "networks").error?.message.contains("pilot wifi on") == true)
        #expect(rig.fake.asked == 0 && rig.fake.scans.isEmpty && rig.fake.joins.isEmpty)
    }

    @Test("join takes no password: an open or known network joins from the last scan and the status follows; a refusal says why")
    func join() async {
        let rig = Rig()
        let joined = await rig.ask("wifi", "join", "Cafe")
        #expect(rig.fake.joins.map(\.name) == ["Cafe"] && rig.fake.joins.allSatisfy { $0.password == nil })
        #expect(Self.field(joined, "network") == .string("Cafe") && rig.fake.scans == [false])
        #expect(rig.asked == ["Join Wi-Fi network: Cafe, an open network"])
        rig.allows = false
        #expect(await rig.ask("wifi", "join", "Home").error?.code == .denied && rig.fake.joins.map(\.name) == ["Cafe"])
        rig.allows = true

        rig.wifi.refuses = true
        let unknown = await rig.ask("wifi", "join", "Neighbour")
        #expect(unknown.error?.message.hasPrefix("Did not join") == true && unknown.error?.message.contains("password on the page") == true)
        let open = await rig.ask("wifi", "join", "Cafe")
        #expect(open.error?.message.contains("password") == false)
        #expect(await rig.ask("wifi", "join", "Cafe", "--password", "x").error?.code == .unknownFlag)
    }

    @Test("bluetooth lists the paired devices only once access is allowed; before, it reads only the stored answer")
    func devices() async {
        let rig = Rig()
        rig.bluetooth.access = .notAsked
        #expect(await rig.ask("bluetooth").result == .object(["access": .string("notAsked"), "canSwitch": .bool(true)]))
        #expect(rig.bluetooth.listed == 0 && rig.bluetooth.asked == 0)

        rig.bluetooth.access = .allowed
        let rows = Self.rows(Self.field(await rig.ask("bluetooth", "devices"), "devices"))
        #expect(rows.map { $0["address"] } == [.string("aa-01"), .string("aa-02"), .string("aa-03")])
        #expect(rows[0]["name"] == .string("AirPods Pro") && rows[0]["connected"] == .bool(true))
        // The radio's power reads back once allowed (T47).
        #expect(Self.field(await rig.ask("bluetooth"), "power") == .bool(true))
        rig.bluetooth.power = false
        #expect(Self.field(await rig.ask("bluetooth"), "power") == .bool(false))
    }

    @Test("connect and disconnect by address or name answer the row read again; one already so is not touched; a miss is the page's line")
    func connect() async {
        let rig = Rig()
        let mouse = await rig.ask("bluetooth", "connect", "MX Master 3S")
        #expect(rig.bluetooth.connects == ["aa-02"] && Self.field(mouse, "connected") == .bool(true))
        #expect(Self.field(await rig.ask("bluetooth", "connect", "AA-01"), "connected") == .bool(true) && rig.bluetooth.connects == ["aa-02"])
        #expect(Self.field(await rig.ask("bluetooth", "disconnect", "aa-01"), "connected") == .bool(false) && rig.bluetooth.disconnects == ["aa-01"])
        // The one already connected was not asked about.
        #expect(rig.asked == ["Connect Bluetooth device: MX Master 3S (aa-02)", "Disconnect Bluetooth device: AirPods Pro (aa-01)"])
        rig.allows = false
        #expect(await rig.ask("bluetooth", "disconnect", "aa-02").error?.code == .denied && rig.bluetooth.disconnects == ["aa-01"])
        rig.allows = true

        let away = await rig.ask("bluetooth", "connect", "Keychron K2")
        #expect(away.error?.code == .badValue && away.error?.message.hasPrefix("Did not connect") == true)
        #expect(await rig.ask("bluetooth", "connect", "Nothing").error?.code == .badValue)

        rig.bluetooth.access = .denied
        let denied = await rig.ask("bluetooth", "disconnect", "aa-02")
        #expect(denied.error?.code == .notReady && denied.error?.message.contains(SetupBluetooth.deniedLine) == true)
        #expect(rig.bluetooth.disconnects == ["aa-01"] && rig.bluetooth.asked == 0 && rig.bluetooth.resets == 0)
    }

    @Test("Two devices of one name are refused with their addresses")
    func sameName() async {
        let rig = Rig()
        rig.bluetooth.devices.append(BluetoothDevice(address: "aa-04", name: "MX Master 3S", connected: false))
        let both = await rig.ask("bluetooth", "connect", "MX Master 3S")
        #expect(both.error?.message.contains("aa-02, aa-04") == true && rig.bluetooth.connects.isEmpty)
    }

    @Test("Help, schema and flags: each subcommand explained, rows keyed, undeclared flags refused")
    func contract() async throws {
        let rig = Rig()
        #expect(try rig.verbs.verb("wifi").detail?("join")?.contains("never sent through the command") == true)
        #expect(try rig.verbs.verb("bluetooth").detail?("disconnect")?.contains("asks Allow, then connects or disconnects") == true)
        #expect(try rig.verbs.verb("wifi").detail?("off")?.contains("asks Allow") == true)
        guard case .object(let wifi)? = try rig.verbs.verb("wifi").schema?(), case .object(let bt)? = try rig.verbs.verb("bluetooth").schema?() else {
            Issue.record("no schema"); return
        }
        #expect(wifi["rowKey"] == .string("name") && bt["rowKey"] == .string("address"))
        #expect(await rig.ask("bluetooth", "--all").error?.code == .unknownFlag)
        #expect(await rig.ask("wifi", "scan").error?.code == .badValue)
        #expect(await rig.ask("bluetooth", "connect").error?.code == .badRequest)
    }
}
