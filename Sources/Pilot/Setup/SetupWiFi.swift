import Foundation
import Observation

/// Setup › Wi-Fi (card agent-bo-95422803): the switch and the signal at once; the network's name and the networks nearby
/// only after the Show networks press, which raises macOS's Location prompt, since macOS hides every network name from
/// an app without Location access. Pilot remembers the press. No network name or password is logged or kept.
@Observable @MainActor
final class SetupWiFi {
    static let hiddenLine = "macOS shows Wi-Fi network names only to apps with Location access; Pilot uses it for nothing else."
    static let deniedLine = "macOS refused Pilot Location access, so network names stay hidden. Allow it in System Settings › Privacy & Security › Location Services."
    static let shownKey = "setup.wifi.shown"

    private(set) var status: WiFiStatus?
    /// The status has been read since the page showed, so a nil status means the Mac has no Wi-Fi.
    private(set) var checked = false
    private(set) var networks: [WiFiNetwork] = []
    private(set) var location = PrivacyAccess.notAsked
    private(set) var scanning = false
    private(set) var problem: String?
    /// Show networks was pressed once. Saved as it changes.
    private(set) var shown: Bool { didSet { defaults.set(shown, forKey: Self.shownKey) } }
    /// The Show networks button shows: never pressed, or macOS's answer was reset since.
    var offersShow: Bool { !shown || location == .notAsked }
    @ObservationIgnored private let wifi: WiFiSystem
    @ObservationIgnored private let defaults: UserDefaults

    init(wifi: WiFiSystem, defaults: UserDefaults = .pilot()) {
        self.wifi = wifi
        self.defaults = defaults
        shown = defaults.bool(forKey: Self.shownKey)
    }

    /// The page shows: the switch and the signal; once Show was pressed, macOS's stored Location answer and its last scan.
    func start() async {
        status = wifi.status()
        checked = true
        guard shown else { return }
        location = wifi.locationAccess()
        await refreshNetworks(fresh: false)
    }

    /// The Show networks press: macOS's Location prompt if Pilot was never asked, then the names and a scan.
    func showNetworks() async {
        shown = true
        location = await wifi.requestLocation()
        status = wifi.status()
        await refreshNetworks(fresh: true)
    }

    /// The networks nearby, strongest first, each name once; only with Location access and Wi-Fi on. `fresh` scans the
    /// radio (Show networks, Scan again); otherwise macOS's last results serve, which cost nothing.
    func refreshNetworks(fresh: Bool) async {
        guard location == .allowed, status?.on == true, !scanning else { return networks = [] }
        scanning = true
        defer { scanning = false }
        await attempt("Scanning failed") {
            let found = try await wifi.scan(fresh: fresh)
            networks = Dictionary(found.map { ($0.name, $0) }, uniquingKeysWith: { $0.signal >= $1.signal ? $0 : $1 }).values
                .sorted { ($0.signal, $1.name) > ($1.signal, $0.name) }
        }
    }

    func setPower(_ on: Bool) async {
        await attempt("macOS did not turn Wi-Fi \(on ? "on" : "off")") {
            try await wifi.setPower(on)
            slog.notice("wi-fi \(on ? "on" : "off", privacy: .public)")
        }
        status = wifi.status()
        if !on { networks = [] }
    }

    /// Joins `network`; a secured network's password goes to macOS once and is kept nowhere here.
    func join(_ network: WiFiNetwork, password: String?) async {
        await attempt("Did not join") {
            try await wifi.join(network.name, password: network.secured ? password : nil)
            slog.notice("wi-fi join done")
        }
        status = wifi.status()
    }

    /// Runs one change; its failure, prefixed, is the section's problem, and success clears it.
    private func attempt(_ failure: String, _ change: () async throws -> Void) async {
        do {
            try await change()
            problem = nil
        } catch {
            problem = "\(failure): \(error.localizedDescription)"
            slog.error("wi-fi: \(failure, privacy: .public)")
        }
    }

    func isJoined(_ network: WiFiNetwork) -> Bool { network.name == status?.network }
}
