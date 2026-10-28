import Foundation
import PilotCore
import WebApps

extension SettingsSchema {
    /// Install › Web apps' key: what sits at the top of every web app's window (Q355).
    func registerWebApps(_ window: WebAppWindow) {
        register([
            .choice(WindowTop.key, "Web app window top", page: "webApps", WindowTop.allCases, standard: WindowTop.initial,
                    read: { window.top }, write: { window.top = $0 }),
        ])
    }
}
