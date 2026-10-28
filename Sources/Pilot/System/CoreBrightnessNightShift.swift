import Foundation
import PilotCore

/// Night Shift through CBBlueLightClient in Apple's private CoreBrightness framework, as the Displays pane does (card
/// agent-bo-95422972). Loaded on first use; a missing class or selector reads as not available.
final class CoreBrightnessNightShift: NightShiftClient {
    private let client: NSObject?

    init() {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        client = (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
    }

    /// getBlueLightStatus: fills a StatusData struct (active, enabled, sunSchedulePermitted, mode, schedule,
    /// disableFlags, available: 40 bytes); `enabled` is its second byte. The buffer is roomier in case it grows.
    func isOn() -> Bool? {
        typealias Status = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Bool
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard let client, client.responds(to: sel), client.responds(to: NSSelectorFromString("setEnabled:")) else { return nil }
        let read = unsafeBitCast(client.method(for: sel), to: Status.self)
        return withUnsafeTemporaryAllocation(byteCount: 128, alignment: 8) { buffer in
            guard let base = buffer.baseAddress else { return nil }
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            return read(client, sel, base) ? base.load(fromByteOffset: 1, as: Bool.self) : nil
        }
    }

    func set(_ on: Bool) -> Bool {
        typealias SetEnabled = @convention(c) (NSObject, Selector, Bool) -> Bool
        let sel = NSSelectorFromString("setEnabled:")
        guard let client, client.responds(to: sel) else { return false }
        return unsafeBitCast(client.method(for: sel), to: SetEnabled.self)(client, sel, on)
    }
}
