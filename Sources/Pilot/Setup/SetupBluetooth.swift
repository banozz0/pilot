import Foundation
import Observation

/// Setup › Bluetooth (card agent-bo-95422802): the radio's switch and how it stands; the paired devices, connecting and
/// pairing are macOS's own Bluetooth settings, which the card opens (Sven, 2026-11-26: "they open the actual Mac
/// settings"). Only macOS's stored answer is read until Bluetooth is allowed, which Settings › Permissions asks: the radio
/// is read only after, since IOBluetooth may raise macOS's prompt.
@Observable @MainActor
final class SetupBluetooth {
    static let deniedLine = "macOS refused Pilot access to Bluetooth. Allow it in System Settings › Privacy & Security › Bluetooth."
    static let settingsPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
    /// macOS's own Bluetooth settings, as the top bar's Bluetooth settings… opens them.
    static let devicesPane = "com.apple.BluetoothSettings"

    private(set) var access = PrivacyAccess.notAsked
    /// The radio (T47): nil hides the switch, when Pilot cannot switch it or Bluetooth is not allowed yet.
    private(set) var power: Bool?
    /// Turning Bluetooth off waits on this while Bluetooth keyboards and mice are the Mac's only input.
    private(set) var offWarning: String?
    private(set) var powerProblem: String?
    /// This page's switch is under way, its toggle greyed; BluetoothPower.begin holds the guard every switch shares.
    private(set) var switching = false
    @ObservationIgnored private let bluetooth: BluetoothSystem

    init(bluetooth: BluetoothSystem) {
        self.bluetooth = bluetooth
    }

    /// The page shows: macOS's stored answer, and the radio once Bluetooth is allowed.
    func start() {
        access = bluetooth.authorization()
        power = BluetoothPower.state(bluetooth)
    }

    /// The switch: on at once; off at once too, unless Bluetooth keyboards and mice are the only input, when it waits
    /// for Turn off under the warning.
    func setPower(_ on: Bool) async {
        if !on, let warning = BluetoothPower.warning(bluetooth.inputs()) {
            offWarning = warning
            return slog.notice("bluetooth off: asking, only Bluetooth input")
        }
        await switchPower(on)
    }

    func confirmOff() async {
        offWarning = nil
        await switchPower(false)
    }

    func cancelOff() { offWarning = nil }

    /// The switch read again: the bar's or the action's switch changed the radio (BluetoothPower.changed).
    func refreshPower() {
        power = BluetoothPower.state(bluetooth)
    }

    private func switchPower(_ on: Bool) async {
        guard BluetoothPower.begin() else { return }
        switching = true
        defer {
            switching = false
            BluetoothPower.end()
        }
        let after = await bluetooth.setPower(on)
        slog.notice("bluetooth \(on ? "on" : "off", privacy: .public): \(after == on ? "done" : "failed", privacy: .public)")
        powerProblem = after == on ? nil : "macOS did not turn Bluetooth \(on ? "on" : "off")"
        power = BluetoothPower.state(bluetooth)
    }
}
