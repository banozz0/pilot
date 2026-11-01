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

    /// Install › Hidden apps' list (Q713): the bundle ids Pilot leaves out, comma-separated; a set hides and unhides as the
    /// page's rows do, Finder's flag included.
    func registerHiddenApps(_ hidden: HiddenApps) {
        register([
            .text(HiddenApps.key, "Apps Pilot's lists leave out, and Finder too in Applications (bundle ids, comma-separated)", page: "hiddenApps",
                  standard: "", read: { hidden.bundles.sorted().joined(separator: ",") },
                  write: { word throws(ControlError) in
                      let bundles = word.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                      let missing = bundles.filter { !hidden.isHidden($0) && !AppsModule.isInstalled($0) }
                      guard missing.isEmpty else { throw ControlError(.badValue, "no app \(missing.joined(separator: ", ")) is installed; give bundle ids from pilot list apps") }
                      hidden.set(bundles)
                  }),
        ])
    }
}
