import AppKit
import Observation

/// Setup › Bluetooth (card agent-bo-95422802): the paired devices, connected or not, and a connect or disconnect each.
/// Nothing touches Bluetooth until the first Show paired devices press, which raises macOS's prompt; Pilot remembers the
/// press, and from then on the section reads each time the page shows.
@Observable @MainActor
final class SetupBluetooth {
    static let deniedLine = "macOS refused Pilot access to Bluetooth. Allow it in System Settings › Privacy & Security › Bluetooth."
    static let resetFailedLine = "Pilot could not clear its Bluetooth answer, so macOS will not ask again. Use Open Settings and turn Pilot on there."
    static let settingsPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!

    private(set) var devices: [BluetoothDevice] = []
    private(set) var access = PrivacyAccess.notAsked
    private(set) var busy: Set<String> = []
    /// What went wrong on a device's row, by address.
    private(set) var failures: [String: String] = [:]
    /// The list has been read since the page showed; until then the section shows no "No paired devices".
    private(set) var read = false
    /// The radio (T47): nil hides the switch, when Pilot cannot switch it or Bluetooth is not allowed yet.
    private(set) var power: Bool?
    /// Turning Bluetooth off waits on this while Bluetooth keyboards and mice are the Mac's only input.
    private(set) var offWarning: String?
    private(set) var powerProblem: String?
    /// This page's switch is under way, its toggle greyed; BluetoothPower.begin holds the guard every switch shares.
    private(set) var switching = false
    /// Ask again could not clear Pilot's answer: what to do instead.
    private(set) var resetFailure: String?
    /// Show paired devices was pressed once. Saved as it changes.
    private(set) var shown: Bool { didSet { defaults.set(shown, forKey: Self.shownKey) } }
    /// The Show paired devices button shows: never pressed, or macOS's answer was reset since (tccutil, a new Mac).
    var offersShow: Bool { !shown || (read && access == .notAsked) }
    @ObservationIgnored private let bluetooth: BluetoothSystem
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let open: (URL) -> Void
    static let shownKey = "setup.bluetooth.shown"

    init(bluetooth: BluetoothSystem, defaults: UserDefaults = .pilot(), open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.bluetooth = bluetooth
        self.defaults = defaults
        self.open = open
        shown = defaults.bool(forKey: Self.shownKey)
    }

    /// The page shows: once Show was pressed, macOS's stored answer and the list.
    func start() async {
        guard shown else { return }
        access = bluetooth.authorization()
        await list()
    }

    /// The Show paired devices press: macOS's prompt if Pilot was never asked, then the list once it is answered.
    func show() async {
        shown = true
        access = await bluetooth.requestAccess()
        await list()
    }

    /// Ask again after a refusal (card agent-bo-95422970): macOS never asks twice, so Pilot clears its own answer
    /// first, then asks as Show does.
    func askAgain() async {
        guard await bluetooth.resetAccess() else { resetFailure = Self.resetFailedLine; return }
        resetFailure = nil
        await show()
    }

    /// Opens System Settings on Privacy & Security › Bluetooth.
    func openSettings() { open(Self.settingsPane) }

    /// Connects a device that is not connected, disconnects one that is.
    func toggle(_ device: BluetoothDevice) async {
        guard !busy.contains(device.address) else { return }
        busy.insert(device.address)
        defer { busy.remove(device.address) }
        let connecting = !device.connected
        let ok = connecting ? await bluetooth.connect(device.address) : await bluetooth.disconnect(device.address)
        slog.notice("bluetooth \(connecting ? "connect" : "disconnect", privacy: .public) \(ok ? "done" : "failed", privacy: .public)")
        if ok {
            failures[device.address] = nil
            if let i = devices.firstIndex(where: { $0.address == device.address }) { devices[i].connected = connecting }
        } else {
            failures[device.address] = connecting ? "Did not connect: it may be off, asleep or out of range" : "macOS did not disconnect it"
        }
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

    /// The switch read again, once shown: the bar's or the action's switch changed the radio (BluetoothPower.changed).
    func refreshPower() {
        guard shown, read else { return }
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
        await list()
    }

    private func list() async {
        devices = access == .allowed ? await bluetooth.paired() : []
        power = BluetoothPower.state(bluetooth)
        read = true
    }
}
