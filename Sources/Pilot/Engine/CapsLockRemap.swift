import Foundation
import IOKit.hidsystem
import PilotCore

/// Caps Lock becomes F18 at the HID level, the hidutil technique, on every keyboard service (the Keychron's second
/// interface included), and Binds › Swap keys' pairs swap there too (Q406): one mapping set
/// (KeyMappingEntry.pilotSet), applied at launch, removed on quit or when the layer keys or swaps change. Entries Pilot
/// did not write are written back with it, globally: one set on a single keyboard spreads to every keyboard and stays
/// there after quit. Karabiner grabbing the keyboard makes this a no-op, and the conflict tip says so.
enum CapsLockRemap {
    /// Every distinct entry on any keyboard service.
    static var current: [KeyMappingEntry] {
        let keyboards = #"{"PrimaryUsagePage":1,"PrimaryUsage":6}"#
        return KeyMappingEntry.parse(hidutil: hidutil(["property", "--matching", keyboards, "--get", "UserKeyMapping"]) ?? "")
    }

    /// Pilot's set `next` over `current`, the mapping as read just before, less every entry of Pilot's (`own`), so a change
    /// costs one hidutil read and one write. False when hidutil refused it.
    static func apply(_ next: [KeyMappingEntry], over current: [KeyMappingEntry], own: Set<KeyMappingEntry>) -> Bool {
        run(mapping: KeyMappingEntry.merged(current, own: own, next: next))
    }

    /// Shift+Caps Lock: flips the real Caps Lock state (and its light) through IOHIDSystem. Returns the new state.
    static func toggleCapsLockState() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connect) }
        var on = false
        guard IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &on) == KERN_SUCCESS,
              IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), !on) == KERN_SUCCESS else { return nil }
        return !on
    }

    private static func run(mapping: [KeyMappingEntry]) -> Bool {
        let entries = mapping.map { ["HIDKeyboardModifierMappingSrc": $0.src, "HIDKeyboardModifierMappingDst": $0.dst] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["UserKeyMapping": entries]),
              let json = String(data: data, encoding: .utf8) else { return false }
        return hidutil(["property", "--set", json]) != nil
    }

    private static func hidutil(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return nil }
        // Read before waiting: --get prints a block per HID service (130 on Sven's Mac) and can fill the pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
