import Foundation
import Testing
@testable import Pilot

/// Setup › Bluetooth (card agent-bo-95422802): the radio's switch and how it stands; the paired devices are macOS's own
/// settings. Every case runs on a fake; no test lists, connects or disconnects a real device or raises macOS's prompt.
@MainActor
@Suite("Setup Bluetooth")
struct SetupBluetoothTests {
    final class FakeBluetooth: BluetoothSystem {
        var devices = [
            BluetoothDevice(address: "aa-01", name: "AirPods Pro", connected: true),
            BluetoothDevice(address: "aa-02", name: "MX Master 3S", connected: false),
            BluetoothDevice(address: "aa-03", name: "Keychron K2", connected: false),
        ]
        var access = PrivacyAccess.allowed
        /// What Sven answers macOS's prompt with.
        var answer = PrivacyAccess.allowed
        var reached: Set<String> = ["aa-01", "aa-02"]
        var asked = 0, listed = 0, touched = 0
        var connects: [String] = [], disconnects: [String] = []

        func authorization() -> PrivacyAccess { touched += 1; return access }
        func requestAccess() async -> PrivacyAccess {
            touched += 1
            if access == .notAsked { asked += 1; access = answer }
            return access
        }
        func paired() async -> [BluetoothDevice] { touched += 1; listed += 1; return devices }
        func connect(_ address: String) async -> Bool {
            connects.append(address)
            guard reached.contains(address), let i = devices.firstIndex(where: { $0.address == address }) else { return false }
            devices[i].connected = true
            return true
        }
        func disconnect(_ address: String) async -> Bool {
            disconnects.append(address)
            guard let i = devices.firstIndex(where: { $0.address == address }) else { return false }
            devices[i].connected = false
            return true
        }

        /// The radio's fake power backend (T47): no test calls the private setter or reads the real radio.
        var power: Bool? = true, canSetPower = true
        var connectedInputs: [InputDevice] = []
        var powerSets: [Bool] = []
        func powerOn() -> Bool? { touched += 1; return power }
        func setPower(_ on: Bool) async -> Bool? {
            guard canSetPower else { return nil }
            powerSets.append(on)
            power = on
            return power
        }
        func inputs() -> [InputDevice] { connectedInputs }
    }

    @Test("Before Bluetooth is allowed the page reads only macOS's stored answer: no prompt, no radio, no list")
    func storedAnswerOnly() {
        for access in [PrivacyAccess.notAsked, .denied] {
            let bt = FakeBluetooth()
            bt.access = access
            let section = SetupBluetooth(bluetooth: bt)
            section.start()
            section.refreshPower()
            #expect(section.access == access && section.power == nil)
            #expect(bt.touched == 3 && bt.asked == 0 && bt.listed == 0, "only authorization() read, once per start and refresh")
        }
        #expect(SetupBluetooth.deniedLine.contains("Privacy & Security") && SetupBluetooth.deniedLine.contains("Bluetooth"))
    }

    @Test("Allowed: the page reads the radio for its switch and never lists the paired devices")
    func allowed() {
        let bt = FakeBluetooth(), section = SetupBluetooth(bluetooth: bt)
        section.start()
        #expect(section.access == .allowed && section.power == true && bt.listed == 0 && bt.asked == 0)
    }

    @Test("Info.plist says why Pilot uses Bluetooth, as macOS requires before it lists a device")
    func usageDescription() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Info.plist").standardized
        let info = try #require(NSDictionary(contentsOf: plist))
        let why = try #require(info["NSBluetoothAlwaysUsageDescription"] as? String)
        #expect(why.contains("paired Bluetooth devices") && why.contains("Permissions"))
    }
}
