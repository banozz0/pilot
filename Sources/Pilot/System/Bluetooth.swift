import CoreBluetooth
import IOBluetooth
import PilotCore

struct BluetoothDevice: Equatable, Sendable {
    let address: String
    let name: String
    var connected: Bool
}

/// The Mac's paired Bluetooth devices: IOBluetooth is the real one; the tests use a fake, so no test lists or connects a
/// real device or raises macOS's Bluetooth prompt.
@MainActor
protocol BluetoothSystem: AnyObject {
    /// macOS's stored answer, read without asking.
    func authorization() -> PrivacyAccess
    /// Raises macOS's prompt when Pilot was never asked, and returns once it is answered.
    func requestAccess() async -> PrivacyAccess
    /// Clears Pilot's own stored answer, so the next request raises macOS's prompt again; false when that failed.
    func resetAccess() async -> Bool
    func paired() async -> [BluetoothDevice]
    func connect(_ address: String) async -> Bool
    func disconnect(_ address: String) async -> Bool
}

/// IOBluetooth's public device calls (Setup › Bluetooth, card agent-bo-95422802), each off the main thread, since a
/// connect pages the device for seconds. Asking goes through CoreBluetooth: making a central manager raises macOS's
/// prompt, and its state callback comes once the prompt is answered.
final class IOBluetoothSystem: NSObject, BluetoothSystem, CBCentralManagerDelegate {
    private var asker: CBCentralManager?
    private let asking = PermissionAsk()

    func authorization() -> PrivacyAccess {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    func requestAccess() async -> PrivacyAccess {
        let access = await asking.ask(current: authorization) { asker = CBCentralManager(delegate: self, queue: .main) }
        asker = nil
        return access
    }

    /// macOS never asks twice, so Ask again (card agent-bo-95422970) clears Pilot's own Bluetooth answer and nothing
    /// else; a user may reset their own app's answer without sudo (checked on macOS 27, 2026-10-07).
    static let resetCommand = ["/usr/bin/tccutil", "reset", "BluetoothAlways", "dev.banozz.pilot"]

    func resetAccess() async -> Bool {
        (try? await ChildProcess.run(Self.resetCommand[0], Array(Self.resetCommand.dropFirst()), timeout: .seconds(10))) != nil
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { asking.answered(authorization()) }
    }

    func paired() async -> [BluetoothDevice] {
        await Task.detached(priority: .userInitiated) {
            (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device in
                guard let address = device.addressString else { return nil }
                return BluetoothDevice(address: address, name: device.nameOrAddress ?? address, connected: device.isConnected())
            }
        }.value
    }

    func connect(_ address: String) async -> Bool { await Self.run(address) { $0.openConnection() } }
    func disconnect(_ address: String) async -> Bool { await Self.run(address) { $0.closeConnection() } }

    private static func run(_ address: String, _ call: @escaping @Sendable (IOBluetoothDevice) -> IOReturn) async -> Bool {
        await Task.detached(priority: .userInitiated) { IOBluetoothDevice(addressString: address).map(call) == kIOReturnSuccess }.value
    }
}
