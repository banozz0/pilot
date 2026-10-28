import Foundation
import Observation
import OSLog
import PilotCore

let swlog = Logger(subsystem: "dev.banozz.pilot", category: "switch")

/// The dropdown's on/off switch (story 60): on arms Pilot's binds, off disarms them.
@Observable @MainActor
final class PilotSwitch {
    private static let defaults = UserDefaults.pilot()

    /// On unless switched off: Pilot ran its binds before the switch existed.
    private(set) var isOn = defaults.object(forKey: "switch.on") as? Bool ?? true {
        didSet { Self.defaults.set(isOn, forKey: "switch.on") }
    }
    /// Called with the new state after the switch flips.
    var onBinds: (Bool) -> Void = { _ in }

    func set(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        onBinds(on)
        swlog.notice("switch \(on ? "on" : "off", privacy: .public)")
    }
}
