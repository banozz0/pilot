import Foundation
import Observation

/// Setup › Wi-Fi (card agent-bo-95422803): the switch and how Wi-Fi stands, read as the page shows; the networks nearby
/// and joining one are macOS's own Wi-Fi settings, which the card opens (Sven, 2026-11-26: "they open the actual Mac
/// settings"). The joined network's name shows only with Location access, which Settings › Permissions asks; the page
/// asks for nothing and scans nothing. No network name is logged.
@Observable @MainActor
final class SetupWiFi {
    static let hiddenLine = "macOS shows Wi-Fi network names only to apps with Location access; Pilot uses it for nothing else."
    static let deniedLine = "macOS refused Pilot Location access, so network names stay hidden. Allow it in System Settings › Privacy & Security › Location Services."
    /// macOS's own Wi-Fi settings, as the top bar's Wi-Fi settings… opens them.
    static let networksPane = "com.apple.wifi-settings-extension"

    private(set) var status: WiFiStatus?
    /// The status has been read since the page showed, so a nil status means the Mac has no Wi-Fi.
    private(set) var checked = false
    /// macOS's stored Location answer, read without asking: whether a network with no name is hidden or none is joined.
    private(set) var location = PrivacyAccess.notAsked
    private(set) var problem: String?
    @ObservationIgnored private let wifi: WiFiSystem

    init(wifi: WiFiSystem) {
        self.wifi = wifi
    }

    /// The page shows: the switch, the signal, and macOS's stored Location answer only when Wi-Fi is on with no name, the
    /// one line it words (reading it makes a CoreLocation manager).
    func start() {
        status = wifi.status()
        if status?.on == true, status?.network == nil { location = wifi.locationAccess() }
        checked = true
    }

    func setPower(_ on: Bool) async {
        do {
            try await wifi.setPower(on)
            problem = nil
            slog.notice("wi-fi \(on ? "on" : "off", privacy: .public)")
        } catch {
            problem = "macOS did not turn Wi-Fi \(on ? "on" : "off"): \(error.localizedDescription)"
            slog.error("wi-fi: macOS did not switch it")
        }
        status = wifi.status()
    }
}
