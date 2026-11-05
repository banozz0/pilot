import Foundation
import Testing
@testable import Pilot

/// Setup › Bluetooth (card agent-bo-95422802): the paired devices, connected or not, and a connect or disconnect per
/// device. Every case runs on a fake; no test lists, connects or disconnects a real device or raises macOS's prompt.
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
        /// Whether resetting Pilot's answer works, and how often it ran.
        var resetWorks = true, resets = 0
        var connects: [String] = [], disconnects: [String] = []

        func authorization() -> PrivacyAccess { touched += 1; return access }
        func requestAccess() async -> PrivacyAccess {
            touched += 1
            if access == .notAsked { asked += 1; access = answer }
            return access
        }
        func resetAccess() async -> Bool {
            resets += 1
            if resetWorks { access = .notAsked }
            return resetWorks
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
        func powerOn() -> Bool? { power }
        func setPower(_ on: Bool) async -> Bool? {
            guard canSetPower else { return nil }
            powerSets.append(on)
            power = on
            return power
        }
        func inputs() -> [InputDevice] { connectedInputs }
    }

    static func defaults(shown: Bool = false) -> UserDefaults { setupDefaults(SetupBluetooth.shownKey, shown: shown) }

    @Test("Nothing touches Bluetooth before the first Show press; Show asks once and lists; the page remembers the press")
    func lazy() async {
        let bt = FakeBluetooth(), store = Self.defaults()
        bt.access = .notAsked
        let section = SetupBluetooth(bluetooth: bt, defaults: store)
        await section.start()
        #expect(bt.touched == 0 && section.devices.isEmpty && !section.shown && section.offersShow)
        await section.show()
        #expect(bt.asked == 1 && section.access == .allowed && section.devices.count == 3 && section.shown)
        // The next time the page shows, it reads at once and asks nothing.
        let again = SetupBluetooth(bluetooth: bt, defaults: store)
        await again.start()
        #expect(again.devices.count == 3 && bt.asked == 1)
    }

    @Test("macOS's answer reset after the press: the Show button comes back, and Show asks again")
    func resetAnswer() async {
        let bt = FakeBluetooth()
        bt.access = .notAsked
        let section = SetupBluetooth(bluetooth: bt, defaults: Self.defaults(shown: true))
        #expect(!section.offersShow)
        await section.start()
        #expect(section.offersShow && section.devices.isEmpty && bt.asked == 0)
        await section.show()
        #expect(!section.offersShow && bt.asked == 1 && section.devices.count == 3)
    }

    @Test("The section lists the three paired devices, the connected one marked")
    func lists() async {
        let bt = FakeBluetooth(), section = SetupBluetooth(bluetooth: bt, defaults: Self.defaults(shown: true))
        await section.start()
        #expect(bt.asked == 0)
        #expect(section.devices.map(\.name) == ["AirPods Pro", "MX Master 3S", "Keychron K2"])
        #expect(section.devices.map(\.connected) == [true, false, false])
    }

    @Test("Disconnect closes that device only, once, and its row reads disconnected")
    func disconnect() async {
        let bt = FakeBluetooth(), section = SetupBluetooth(bluetooth: bt, defaults: Self.defaults(shown: true))
        await section.start()
        await section.toggle(section.devices[0])
        #expect(bt.disconnects == ["aa-01"] && bt.connects.isEmpty)
        #expect(section.devices.map(\.connected) == [false, false, false])
        #expect(section.failures.isEmpty && section.busy.isEmpty)
    }

    @Test("A device that cannot be reached says so on its row; the others stay as they were")
    func failure() async {
        let bt = FakeBluetooth(), section = SetupBluetooth(bluetooth: bt, defaults: Self.defaults(shown: true))
        await section.start()
        await section.toggle(section.devices[2])
        #expect(bt.connects == ["aa-03"])
        #expect(section.failures["aa-03"] != nil && section.failures.count == 1)
        #expect(section.devices[2].connected == false && section.devices[0].connected)
        // Connecting another device works and leaves the failed one's line.
        await section.toggle(section.devices[1])
        #expect(section.devices[1].connected && section.failures.keys.sorted() == ["aa-03"])
    }

    @Test("Refused at the prompt or before: no list is read, and the line names where to allow it")
    func denied() async {
        let bt = FakeBluetooth()
        bt.access = .notAsked
        bt.answer = .denied
        let store = Self.defaults()
        let section = SetupBluetooth(bluetooth: bt, defaults: store)
        await section.show()
        #expect(section.access == .denied && section.devices.isEmpty && bt.listed == 0)
        // The next time the page shows, macOS's stored refusal is read without asking again.
        let again = SetupBluetooth(bluetooth: bt, defaults: store)
        await again.start()
        #expect(again.access == .denied && bt.asked == 1 && bt.listed == 0)
        #expect(SetupBluetooth.deniedLine.contains("Privacy & Security") && SetupBluetooth.deniedLine.contains("Bluetooth"))
    }

    @Test("Refused: Ask again resets Pilot's own answer once, raises macOS's prompt, and lists once allowed")
    func askAgain() async {
        let bt = FakeBluetooth()
        bt.access = .denied
        let section = SetupBluetooth(bluetooth: bt, defaults: Self.defaults(shown: true))
        await section.start()
        #expect(section.access == .denied && section.devices.isEmpty)
        await section.askAgain()
        #expect(bt.resets == 1 && bt.asked == 1 && section.access == .allowed && section.devices.count == 3)
        #expect(section.resetFailure == nil)
    }

    @Test("Asked again and refused again: the refusal stands and no list is read")
    func askAgainRefused() async {
        let bt = FakeBluetooth()
        bt.access = .denied
        bt.answer = .denied
        let section = SetupBluetooth(bluetooth: bt, defaults: Self.defaults(shown: true))
        await section.askAgain()
        #expect(bt.resets == 1 && bt.asked == 1 && section.access == .denied && bt.listed == 0)
    }

    @Test("A reset that fails asks nothing, keeps the refusal and says so in plain words")
    func askAgainFails() async {
        let bt = FakeBluetooth()
        bt.access = .denied
        bt.resetWorks = false
        let section = SetupBluetooth(bluetooth: bt, defaults: Self.defaults(shown: true))
        await section.start()
        await section.askAgain()
        #expect(bt.resets == 1 && bt.asked == 0 && section.access == .denied)
        #expect(section.resetFailure == SetupBluetooth.resetFailedLine)
        #expect(SetupBluetooth.resetFailedLine.contains("Open Settings"))
    }

    @Test("Open Settings opens the Bluetooth privacy pane")
    func openSettings() {
        var opened: [URL] = []
        let section = SetupBluetooth(bluetooth: FakeBluetooth(), defaults: Self.defaults(), open: { opened.append($0) })
        section.openSettings()
        #expect(opened.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"])
    }

    @Test("The real reset is tccutil on Pilot's own bundle id and the Bluetooth service only, without sudo")
    func resetCommand() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Info.plist").standardized
        let info = try #require(NSDictionary(contentsOf: plist))
        let id = try #require(info["CFBundleIdentifier"] as? String)
        #expect(IOBluetoothSystem.resetCommand == ["/usr/bin/tccutil", "reset", "BluetoothAlways", id])
    }

    @Test("Info.plist says why Pilot uses Bluetooth, as macOS requires before it lists a device")
    func usageDescription() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Info.plist").standardized
        let info = try #require(NSDictionary(contentsOf: plist))
        let why = try #require(info["NSBluetoothAlwaysUsageDescription"] as? String)
        #expect(why.contains("paired Bluetooth devices") && why.contains("Setup"))
    }
}
