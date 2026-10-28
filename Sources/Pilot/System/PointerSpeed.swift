import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem
import Observation

/// macOS's tracking speed as Pilot reaches it: the HID event system is the real one; the tests and renders use a fake, so
/// none moves the pointer.
protocol PointerSystem: AnyObject, Sendable {
    /// The speed every mouse moves at now, 0 to 3 as System Settings' Tracking speed; nil when macOS says none.
    func read() -> Double?
    /// Puts `speed` on every mouse now and saves it where System Settings keeps it, for the next login.
    func write(_ speed: Double)
    /// The mice connected now, by name.
    func mice() -> [String]
    /// From now on, a mouse plugged in gets the saved speed too.
    func followPlugIns()
}

/// The real one, as System Settings does it: `com.apple.mouse.scaling` in the global domain, and `HIDMouseAcceleration`
/// on the HID event system and each mouse's service, in 16.16 fixed point (1.5 is 98304). `com.apple.mouse.linear`
/// (pointer acceleration) stays as macOS has it. Writes and the plug-in watch run on one serial queue, off the main thread;
/// a slider's drag sets the mice at each step and saves the last one once it rests.
final class HIDPointerSystem: PointerSystem, @unchecked Sendable {
    static let key = "com.apple.mouse.scaling"
    static let fixed = 65536.0
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private let queue = DispatchQueue(label: "dev.banozz.pilot.pointer-speed", qos: .userInitiated)
    /// The plug-in watch, made once on the queue.
    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    /// The save waiting for a drag to rest, on the queue.
    private var save: DispatchWorkItem?

    func read() -> Double? {
        queue.sync {
            let live = mouseServices().lazy.compactMap { IOHIDServiceClientCopyProperty($0, kIOHIDMouseAccelerationType as CFString) as? NSNumber }.first
            return live.map { $0.doubleValue / Self.fixed } ?? Self.saved()
        }
    }

    func write(_ speed: Double) {
        queue.async { [self] in
            apply(speed)
            save?.cancel()
            let item = DispatchWorkItem {
                slog.notice("pointer speed saved: \(speed, privacy: .public)")
                CFPreferencesSetValue(Self.key as CFString, speed as CFNumber, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
            save = item
            queue.asyncAfter(deadline: .now() + 0.3, execute: item)
        }
    }

    func mice() -> [String] {
        queue.sync {
            var seen = Set<String>()
            return mouseServices().compactMap { IOHIDServiceClientCopyProperty($0, kIOHIDProductKey as CFString) as? String }.filter { seen.insert($0).inserted }
        }
    }

    func followPlugIns() {
        queue.async { [self] in
            guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
            IONotificationPortSetDispatchQueue(port, queue)
            let matching = IOServiceMatching("IOHIDEventService") as NSMutableDictionary
            matching[kIOHIDPrimaryUsagePageKey] = kHIDPage_GenericDesktop
            matching[kIOHIDPrimaryUsageKey] = kHIDUsage_GD_Mouse
            let added: IOServiceMatchingCallback = { me, iterator in
                guard let me, HIDPointerSystem.drain(iterator) > 0 else { return }
                Unmanaged<HIDPointerSystem>.fromOpaque(me).takeUnretainedValue().plugged()
            }
            IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching, added, Unmanaged.passUnretained(self).toOpaque(), &iterator)
            // The mice already here have the speed: the first pass only arms the watch.
            _ = Self.drain(iterator)
            self.port = port
        }
    }

    /// A mouse just plugged in gets macOS's saved speed, so one changed in System Settings since is not fought. Its HID
    /// service shows up a moment after its IOKit match.
    private func plugged() {
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard let speed = Self.saved() else { return }
            apply(speed)
            slog.notice("pointer speed: a mouse plugged in, set to \(speed, privacy: .public)")
        }
    }

    private func apply(_ speed: Double) {
        let key = kIOHIDMouseAccelerationType as CFString, value = Int((speed * Self.fixed).rounded()) as CFNumber
        let system = IOHIDEventSystemClientSetProperty(client, key, value)
        let mice = mouseServices(), set = mice.filter { IOHIDServiceClientSetProperty($0, key, value) }.count
        slog.debug("pointer speed \(speed, privacy: .public): event system \(system, privacy: .public), \(set, privacy: .public) of \(mice.count, privacy: .public) mice")
    }

    private func mouseServices() -> [IOHIDServiceClient] {
        let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return all.filter { IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0 }
    }

    private static func saved() -> Double? {
        (CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.doubleValue
    }

    /// Empties a match iterator, as IOKit needs before it fires again; the number of services in it.
    private static func drain(_ iterator: io_iterator_t) -> Int {
        var count = 0, service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            count += 1
            service = IOIteratorNext(iterator)
        }
        return count
    }
}

/// System › Mouse's pointer speed (Sven, Q440 to Q442): macOS's Tracking speed in steps of 0.05, where System Settings has
/// ten notches, and three saved speeds, Slow, Normal and Fast; picking one uses it, the slider changes the one picked.
/// The mouse's DPI stays in its firmware: its DPI button sends the Mac nothing. Building or reading it never changes the
/// speed; Pilot puts none back at launch, so a change in System Settings stands.
@Observable @MainActor
final class PointerSpeed {
    static let names = ["Slow", "Normal", "Fast"]
    static let range: ClosedRange<Double> = 0...3
    static let step = 0.05
    /// macOS's own default, for Normal's first value when the Mac says no speed.
    static let macDefault = 0.6875

    private enum Keys {
        static let saved = "pointerSpeed.saved", picked = "pointerSpeed.picked", applied = "pointerSpeed.applied"
    }

    @ObservationIgnored let system: PointerSystem
    @ObservationIgnored private let defaults: UserDefaults
    /// Slow, Normal and Fast.
    private(set) var saved: [Double]
    private(set) var picked: Int
    /// The speed the pointer moves at, read as the page shows and set by each change; nil until read, or when macOS says none.
    private(set) var current: Double?

    static let shared = PointerSpeed(system: HIDPointerSystem())

    /// The plug-in watch is on.
    @ObservationIgnored private var following = false

    /// The first time, Normal is the speed macOS has now, Slow and Fast 0.8 and 2.4 at most and least; the Mac is read
    /// only then.
    init(system: PointerSystem, defaults: UserDefaults = .pilot()) {
        self.system = system
        self.defaults = defaults
        if let stored = defaults.array(forKey: Keys.saved) as? [Double], stored.count == Self.names.count {
            saved = stored
        } else {
            let normal = system.read() ?? Self.macDefault, first = [min(0.8, normal), normal, max(2.4, normal)]
            saved = first
            defaults.set(first, forKey: Keys.saved)
        }
        picked = (defaults.object(forKey: Keys.picked) as? Int).map { min(max($0, 0), Self.names.count - 1) } ?? 1
    }

    /// At launch: once Pilot has set a speed, a mouse plugged in later gets it too. Nothing else is read or made.
    static func start() {
        if UserDefaults.pilot().bool(forKey: Keys.applied) { shared.follow() }
    }

    func refresh() { current = system.read() }

    var mice: [String] { system.mice() }

    /// Uses saved speed `index`.
    func pick(_ index: Int) {
        picked = index
        defaults.set(index, forKey: Keys.picked)
        apply(saved[index])
    }

    /// The slider: the picked speed becomes `speed`, on the 0.05 grid; a drag's move within one step changes nothing.
    func set(_ speed: Double) {
        let speed = Self.snap(speed)
        guard speed != current || speed != saved[picked] else { return }
        saved[picked] = speed
        defaults.set(saved, forKey: Keys.saved)
        apply(speed)
    }

    /// The next saved speed, Fast back to Slow.
    func cycle() { pick((picked + 1) % saved.count) }

    /// "Pointer speed: Fast · 2.40".
    var tip: String { "Pointer speed: \(Self.names[picked]) · \(Self.label(saved[picked]))" }

    static func label(_ speed: Double) -> String { String(format: "%.2f", speed) }

    /// On the 0.05 grid with the float noise rounded off, so a drag's repeat of one step compares equal; VoiceOver's
    /// slider sends values off the grid.
    static func snap(_ speed: Double) -> Double {
        let snapped = ((speed / step).rounded() * step * 100).rounded() / 100
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    private func apply(_ speed: Double) {
        system.write(speed)
        current = speed
        follow()
    }

    private func follow() {
        guard !following else { return }
        following = true
        defaults.set(true, forKey: Keys.applied)
        system.followPlugIns()
    }
}
