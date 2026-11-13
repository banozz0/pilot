import AppKit
import Observation
import PilotCore

/// Low-battery alerts (Sven, Q394), on until turned off in Menu bar › Bluetooth batteries: while on, the sampler reads the
/// Bluetooth HID batteries with its slow readings (every minute, no timer of its own), and a device falling to 20 % and
/// then 10 % shows Pilot's tip with a sound and posts a notification, once each (LowBattery). Earbuds and headphones come
/// from system_profiler, read only while the Bluetooth batteries item or Stats shows them, so they alert only then.
/// macOS asks once for the notification at the first alert; the tip shows whatever the answer.
@Observable @MainActor
final class LowBatteryAlerts {
    static let shared = LowBatteryAlerts()
    static let key = "bar.lowBatteryAlerts"

    var isOn: Bool {
        didSet {
            defaults.set(isOn, forKey: Self.key)
            follow()
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sampler: SystemSampler
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var state = LowBattery()

    init(defaults: UserDefaults = .pilot(), sampler: SystemSampler = .shared) {
        self.defaults = defaults
        self.sampler = sampler
        isOn = defaults.object(forKey: Self.key) as? Bool ?? true
    }

    /// Holds the sampler's watch while on; started once at launch.
    func follow() {
        watch?.cancel()
        watch = nil
        sampler.onBluetooth = nil
        guard isOn else { return }
        sampler.onBluetooth = { [weak self] devices in
            guard let self else { return }
            for alert in state.record(devices) { Self.show(alert) }
        }
        watch = Task { [sampler] in await sampler.watch(every: .seconds(SystemStats.diskInterval), needs: .lowBattery) }
    }

    /// Through smart nudges' funnel, so quiet hours hold it with the rest.
    private static func show(_ alert: LowBattery.Alert) {
        SmartNudgeCenter.shared.post(.init(id: "lowBattery.\(alert.name)", title: "Low battery", body: alert.text, sound: true))
    }
}
