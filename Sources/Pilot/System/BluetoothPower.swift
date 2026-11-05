import Foundation
import IOBluetooth
import IOKit

/// A keyboard, mouse or trackpad connected now, and whether it is connected over Bluetooth.
struct InputDevice: Equatable, Sendable {
    let name: String
    let bluetooth: Bool
}

/// Bluetooth's radio on and off (T47, Sven Q833). macOS has no public setter, so the switch calls IOBluetooth's private
/// IOBluetoothPreferenceSetControllerPowerState through dlsym, as `blueutil` does; it needs no root. When a macOS update
/// removes it, `setCall` is nil and every switch hides. The power is read back through its pair, the private getter, else
/// IOBluetoothHostController's public `powerState`. Turning it off warns first when Bluetooth keyboards or mice are the Mac's only input.
@MainActor
enum BluetoothPower {
    nonisolated static let setCall: (@convention(c) (Int32) -> Void)? = symbol("IOBluetoothPreferenceSetControllerPowerState").map {
        unsafeBitCast($0, to: (@convention(c) (Int32) -> Void).self)
    }
    /// The setter's own read, 1 for on, which answers with the radio off too, when IOBluetoothHostController may have
    /// no default controller to ask.
    nonisolated static let getCall: (@convention(c) () -> Int32)? = symbol("IOBluetoothPreferenceGetControllerPowerState").map {
        unsafeBitCast($0, to: (@convention(c) () -> Int32).self)
    }

    /// This Mac has a Bluetooth controller: the IO registry lists one whether the radio is on or off, and asks no
    /// permission. Without one the private getter still answers, so the power is nil and the switches hide.
    nonisolated static var hasController: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOBluetoothHCIController"))
        defer { if service != 0 { IOObjectRelease(service) } }
        return service != 0
    }

    private nonisolated static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY).flatMap { dlsym($0, name) }
    }

    /// The radio's power, nil with no controller.
    static func power() -> Bool? { hasController ? read() : nil }

    /// The power without the controller check: the private getter, else the public `powerState`.
    private static func read() -> Bool? {
        getCall.map { $0() == 1 } ?? IOBluetoothHostController.default().map { $0.powerState == kBluetoothHCIPowerStateON }
    }

    /// Calls the setter off the main thread, then reads the power back until it matches, for at most 10 s, as
    /// blueutil waits: the radio takes a moment to come up or go down. The controller is checked once, before.
    static func set(_ on: Bool) async -> Bool? {
        guard let call = setCall, hasController else { return nil }
        await Task.detached(priority: .userInitiated) { call(on ? 1 : 0) }.value
        let deadline = ContinuousClock.now + .seconds(10)
        while read() != on, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return read()
    }

    /// One switch at a time, whichever switch pressed it (System page, bar, action): a second press while one is under
    /// way is refused, so two presses never race the radio. `begin` claims it, false when taken; `end` frees it.
    private(set) static var switching = false

    static func begin() -> Bool {
        guard !switching else { return false }
        switching = true
        return true
    }

    static func end() { switching = false }

    /// Posted after the bar or the action switched the radio, so a System page on screen reads its switch again.
    static let changed = Notification.Name("dev.banozz.pilot.bluetoothPower")

    /// What a switch shows: the power, or nil to hide it (no setter, Bluetooth not allowed yet, no controller).
    static func state(_ bluetooth: BluetoothSystem) -> Bool? {
        guard bluetooth.canSetPower, bluetooth.authorization() == .allowed else { return nil }
        return bluetooth.powerOn()
    }

    /// The warning before Bluetooth goes off, or nil when another keyboard or mouse stays: the Bluetooth inputs are the
    /// Mac's only ones. One wired device of either kind counts, since a mouse alone turns Bluetooth back on.
    static func warning(_ inputs: [InputDevice]) -> String? {
        guard inputs.contains(where: \.bluetooth), !inputs.contains(where: { !$0.bluetooth }) else { return nil }
        var names: [String] = []
        for device in inputs where !names.contains(device.name) { names.append(device.name) }
        let list = ListFormatter.localizedString(byJoining: names)
        return "\(list) \(names.count == 1 ? "is" : "are") this Mac's only keyboard and mouse. Turning Bluetooth off "
            + "disconnects \(names.count == 1 ? "it" : "them"), and it takes a wired keyboard or mouse to turn it back on."
    }

    /// The pages and usages of a keyboard, mouse, pointer or trackpad.
    nonisolated static func isInput(page: Int, usage: Int) -> Bool { (page == 1 && [1, 2, 6].contains(usage)) || (page == 0x0D && usage == 5) }

    /// Bluetooth (classic or Low Energy), or a wired link a person types or points with; nil for virtual devices, a
    /// headset's buttons and the Mac's own sensors, which are not input.
    nonisolated static func link(_ transport: String) -> Bool? {
        if transport.localizedCaseInsensitiveContains("bluetooth") { return true }
        return ["USB", "SPI", "FIFO", "I2C"].contains(transport) ? false : nil
    }

    /// The IO registry's HID devices that are keyboards, mice or trackpads; a device with several interfaces is listed
    /// once per interface, which the warning folds by name.
    nonisolated static func connectedInputs() -> [InputDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [InputDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let value = { (key: String) in IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard let page = value("PrimaryUsagePage") as? Int, let usage = value("PrimaryUsage") as? Int,
                  isInput(page: page, usage: usage),
                  let transport = value("Transport") as? String, let bluetooth = link(transport)
            else { continue }
            found.append(InputDevice(name: value("Product") as? String ?? "A \(bluetooth ? "Bluetooth" : "wired") device", bluetooth: bluetooth))
        }
        return found
    }
}
