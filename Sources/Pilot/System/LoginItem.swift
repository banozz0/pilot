import Observation
import PilotCore
import ServiceManagement

/// Pilot's login item (story 40, card agent-bo-95422770): SMAppService.mainApp, registered or unregistered to match the
/// Launch at login setting at launch and on each change. The service is a seam: tests never touch the real login items.
@Observable @MainActor
final class LoginItem {
    struct Service {
        var status: () -> LaunchAtLogin.Status
        var register: () throws -> Void
        var unregister: () throws -> Void

        static var live: Service { Service(status: {
            switch SMAppService.mainApp.status {
            case .enabled: .enabled
            case .requiresApproval: .requiresApproval
            case .notFound: .notFound
            default: .notRegistered
            }
        }, register: { try SMAppService.mainApp.register() }, unregister: { try SMAppService.mainApp.unregister() }) }
    }

    static let shared = LoginItem(service: .live)

    @ObservationIgnored private let service: Service
    /// Read live, so an approval given in System Settings shows at onboarding's next check.
    var status: LaunchAtLogin.Status { service.status() }
    /// The last register or unregister failure, shown on Settings › General.
    private(set) var problem: String?

    init(service: Service) { self.service = service }

    func apply(_ wanted: Bool) {
        guard let step = LaunchAtLogin.step(wanted: wanted, status: status) else { return }
        do {
            try step == .register ? service.register() : service.unregister()
            problem = nil
        } catch {
            problem = error.localizedDescription
            log.error("launch at login: \(String(describing: step), privacy: .public) failed: \(self.problem ?? "", privacy: .public)")
        }
        log.notice("launch at login: \(String(describing: step), privacy: .public), now \(String(describing: self.status), privacy: .public)")
    }
}
