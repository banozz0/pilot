import AppKit

/// The apps in Command-Tab's order, the most recently used first (Arrows preset, Sven's Q439): next app is the one a
/// Command-Tab tap brings, so pressed again it goes back; previous is the last one, as a Command-Shift-Tab tap, so
/// pressed again it walks back through them all. No switcher shows. Pilot is never one; an app launched behind the
/// others comes last, as Command-Tab lists it.
@MainActor
final class AppOrder {
    static let shared = AppOrder()
    /// What `pilot actions --find` and the menu's search match besides the label.
    static let keywords = "switch switcher cmd-tab command-tab"

    private var pids: [pid_t] = []
    private var observer: NSObjectProtocol?

    /// Seeds the order from the windows on screen, front to back, and keeps it on each activation; once.
    func start() {
        guard observer == nil else { return }
        let front = NSWorkspace.shared.frontmostApplication.map { [$0.processIdentifier] } ?? []
        pids = unique(front + EngineObservers.onScreen().filter { $0.layer == 0 }.map(\.info.pid))
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                  object: nil, queue: .main) { note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { AppOrder.shared.pids = [pid] + AppOrder.shared.pids.filter { $0 != pid } }
        }
    }

    /// The running apps Command-Tab lists, most recently used first; quit ones drop out here.
    private func apps() -> [NSRunningApplication] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0 != .current && !$0.isTerminated }
        let byPid = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        pids = unique(pids.filter { byPid[$0] != nil } + running.map(\.processIdentifier))
        return pids.compactMap { byPid[$0] }
    }

    /// Brings the next or previous app forward; nothing when there is no other app.
    func switchApp(next: Bool) {
        let front = NSWorkspace.shared.frontmostApplication
        let others = apps().filter { $0 != front }
        guard let app = next ? others.first : others.last else { return }
        let ok = activate(app, from: front)
        alog.notice("\(next ? "next" : "previous", privacy: .public) app → \(app.bundleIdentifier ?? "?", privacy: .public): \(ok ? "activated" : "refused", privacy: .public)")
    }

    /// The tiler's public ways without its private call (AppActivation): from the app in front, else by AXFrontmost, else
    /// plainly. A hidden app is shown first, as Command-Tab does.
    private func activate(_ app: NSRunningApplication, from front: NSRunningApplication?) -> Bool {
        if app.isHidden { app.unhide() }
        if let front, app.activate(from: front, options: []) { return true }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        if AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success { return true }
        return app.activate()
    }

    private func unique(_ list: [pid_t]) -> [pid_t] {
        var seen = Set<pid_t>()
        return list.filter { seen.insert($0).inserted }
    }
}
