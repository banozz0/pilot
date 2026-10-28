import CoreLocation
import CoreWLAN

struct WiFiStatus: Equatable, Sendable {
    var on: Bool
    /// The joined network's name; nil when off, not joined, or hidden for want of Location access.
    var network: String?
    /// dBm, nil when off.
    var signal: Int?
    /// Mbit/s, nil when off.
    var rate: Double?
}

struct WiFiNetwork: Equatable, Sendable {
    let name: String
    let signal: Int
    let secured: Bool
}

/// The Mac's Wi-Fi: CoreWLAN and CoreLocation are the real ones; the tests use a fake, so no test turns Wi-Fi off,
/// scans, joins or raises macOS's Location prompt.
@MainActor
protocol WiFiSystem: AnyObject {
    /// nil when the Mac has no Wi-Fi.
    func status() -> WiFiStatus?
    /// Only whether the radio is on, for the menu's switch; nil when the Mac has no Wi-Fi.
    func isOn() -> Bool?
    func setPower(_ on: Bool) async throws
    /// macOS's stored Location answer, read without asking.
    func locationAccess() -> PrivacyAccess
    /// Raises macOS's Location prompt when Pilot was never asked, and returns once it is answered.
    func requestLocation() async -> PrivacyAccess
    /// The networks nearby: a new scan of the radio, or macOS's last results, which cost nothing.
    func scan(fresh: Bool) async throws -> [WiFiNetwork]
    /// `password` nil for an open network, or a secured one this Mac already knows (macOS uses its saved password).
    func join(_ name: String, password: String?) async throws
}

/// CoreWLAN's public interface calls (Setup › Wi-Fi, card agent-bo-95422803); scanning and joining take seconds, so they
/// run off the main thread. Location goes through CoreLocation: macOS hides every network name from an app without it.
final class CoreWLANSystem: NSObject, WiFiSystem, CLLocationManagerDelegate {
    struct NotFound: Error, CustomStringConvertible { var description: String { "the network is no longer in range" } }

    private lazy var location = CLLocationManager()
    private let asking = PermissionAsk()
    /// The networks the last scan found, by name, so a join needs no second scan.
    private var scanned: [String: CWNetwork] = [:]

    func status() -> WiFiStatus? {
        guard let wifi = CWWiFiClient.shared().interface() else { return nil }
        guard wifi.powerOn() else { return WiFiStatus(on: false) }
        return WiFiStatus(on: true, network: wifi.ssid(), signal: wifi.rssiValue(), rate: wifi.transmitRate())
    }

    func isOn() -> Bool? { CWWiFiClient.shared().interface()?.powerOn() }

    func setPower(_ on: Bool) async throws {
        try await Task.detached(priority: .userInitiated) { try CWWiFiClient.shared().interface()?.setPower(on) }.value
    }

    func locationAccess() -> PrivacyAccess {
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    func requestLocation() async -> PrivacyAccess {
        await asking.ask(current: locationAccess) {
            location.delegate = self
            location.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { asking.answered(locationAccess()) }
    }

    func scan(fresh: Bool) async throws -> [WiFiNetwork] {
        let found = try await Task.detached(priority: .userInitiated) {
            let wifi = CWWiFiClient.shared().interface()
            return Found(networks: Array(try fresh ? wifi?.scanForNetworks(withName: nil) ?? [] : wifi?.cachedScanResults() ?? []))
        }.value.networks
        scanned = Dictionary(found.compactMap { n in n.ssid.map { ($0, n) } }, uniquingKeysWith: { $0.rssiValue >= $1.rssiValue ? $0 : $1 })
        return scanned.map { WiFiNetwork(name: $0.key, signal: $0.value.rssiValue, secured: !$0.value.supportsSecurity(.none)) }
    }

    func join(_ name: String, password: String?) async throws {
        let known = scanned[name].map(Found.init)
        try await Task.detached(priority: .userInitiated) {
            guard let wifi = CWWiFiClient.shared().interface(),
                  let network = try known?.networks.first ?? wifi.scanForNetworks(withName: name).max(by: { $0.rssiValue < $1.rssiValue })
            else { throw NotFound() }
            try wifi.associate(to: network, password: password)
        }.value
    }

    /// CoreWLAN's networks carried across the hop off the main thread; CWNetwork is immutable once scanned.
    private struct Found: @unchecked Sendable {
        let networks: [CWNetwork]
        init(networks: [CWNetwork]) { self.networks = networks }
        init(_ network: CWNetwork) { networks = [network] }
    }
}
