import AppKit
import Observation
import PilotCore

/// Login and background items (Q386) as Mac › Update & Clean lists them: read off the main thread each time the page
/// shows, never polled, and held only while the page does. A switch runs only after the page's confirm, in a child: a
/// login item through System Events (the ones Pilot took out remembered with their app, so they list as Off), an agent
/// through launchctl, a daemon through launchctl as root behind macOS's own password prompt (Sven, Q412).
@Observable @MainActor
final class LoginItemsModel {
    /// Nil until the first read.
    private(set) var items: [LoginItems.Item]?
    /// The item a switch is running on.
    private(set) var busy: String?
    /// The last switch that failed, said under the list.
    private(set) var problem: String?
    /// Login items System Events would not take out: their app registered them itself, so only System Settings switches them.
    private(set) var appHeld: Set<String> = []

    /// The login items Pilot took out, name to app, in Pilot's settings.
    @ObservationIgnored private let defaults = UserDefaults.pilot()
    private static let removedKey = "loginItems.removed"
    private var removed: [String: String] {
        get { defaults.dictionary(forKey: Self.removedKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.removedKey) }
    }

    nonisolated private static let folders: [(path: String, kind: LoginItems.Kind)] = [
        (FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents").path(percentEncoded: false), .agent),
        ("/Library/LaunchAgents", .sharedAgent), ("/Library/LaunchDaemons", .daemon),
    ]

    /// The login items (System Events) and the launchd jobs, read side by side.
    func reload() async {
        async let logins = Self.loginItems()
        async let jobs = Self.jobs()
        items = mark(LoginItems.sorted(withRemoved(await logins) + (await jobs)))
    }

    /// The live login items plus the ones Pilot took out, listed as Off.
    private func withRemoved(_ live: [LoginItems.Item]) -> [LoginItems.Item] {
        let (all, kept) = LoginItems.withRemoved(live, removed: removed)
        if kept != removed { removed = kept }
        return all
    }

    /// The login items again after one switched, the jobs kept.
    private func reloadLogins() async {
        let jobs = items?.filter { $0.kind != .loginItem } ?? []
        items = mark(LoginItems.sorted(withRemoved(await Self.loginItems()) + jobs))
    }

    /// The launchd jobs again after a switch, the login items kept: a switch changes only a job's flag.
    private func reloadJobs() async {
        let logins = items?.filter { $0.kind == .loginItem } ?? []
        items = mark(LoginItems.sorted(logins + (await Self.jobs())))
    }

    private func mark(_ items: [LoginItems.Item]) -> [LoginItems.Item] {
        let bundle = Bundle.main.bundleIdentifier ?? "dev.banozz.pilot", path = Bundle.main.bundlePath
        return items.map { var item = $0; item.mark(pilot: bundle, path: path); return item }
    }

    /// The launchd jobs in the three folders, each with launchd's disabled flag from its own domain (a daemon's is the
    /// system's, an agent's yours); the files are read off the main thread.
    private static func jobs() async -> [LoginItems.Item] {
        async let gui = (try? ChildProcess.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"], timeout: .seconds(10))) ?? ""
        async let system = (try? ChildProcess.run("/bin/launchctl", ["print-disabled", "system"], timeout: .seconds(10))) ?? ""
        let found = await Task.detached(priority: .userInitiated) {
            folders.flatMap { folder -> [LoginItems.Item] in
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                return names.filter { $0.hasSuffix(".plist") }.compactMap { name in
                    let path = (folder.path as NSString).appendingPathComponent(name)
                    return FileManager.default.contents(atPath: path).flatMap { LoginItems.job($0, path: path, kind: folder.kind) }
                }
            }
        }.value
        let agentsOff = LoginItems.disabled(printDisabled: await gui), daemonsOff = LoginItems.disabled(printDisabled: await system)
        return found.map { var item = $0; item.disabled = (item.kind == .daemon ? daemonsOff : agentsOff).contains(item.label); return item }
    }

    /// Open at Login's apps through System Events in a child osascript; none when it cannot say (logged).
    private static func loginItems() async -> [LoginItems.Item] {
        do { return LoginItems.loginItems(try await ChildProcess.run("/usr/bin/osascript", ["-e", LoginItems.loginItemsScript], timeout: .seconds(10))) } catch {
            slog.notice("login items: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Turns an item off or back on; only one Pilot may switch, and the page asks first.
    func set(_ item: LoginItems.Item, on: Bool) async {
        guard item.canSwitch, busy == nil else { return }
        busy = item.id
        problem = nil
        defer { busy = nil }
        slog.notice("login items: \(on ? "on" : "off", privacy: .public) \(item.label, privacy: .public)")
        switch item.kind {
        case .loginItem: await setLogin(item, on: on)
        case .daemon: await setAsRoot(item, on: on)
        case .agent, .sharedAgent: await setJob(item, on: on)
        }
    }

    /// A login item out of Open at Login (remembered with its app) or back in. One its app registered itself stays
    /// listed after the delete: its row then says System Settings switches it.
    private func setLogin(_ item: LoginItems.Item, on: Bool) async {
        let script = on ? LoginItems.addLoginItemScript : LoginItems.removeLoginItemScript
        guard await Self.osascript(script, on ? item.path : item.label) != nil else {
            problem = "\(item.label) was not turned \(on ? "on" : "off")."
            return await reloadLogins()
        }
        removed[item.label] = on ? nil : item.path
        await reloadLogins()
        if !on, items?.contains(where: { $0.kind == .loginItem && $0.label == item.label && !$0.disabled }) == true {
            appHeld.insert(item.label)
        }
    }

    /// Your agent, or a shared one for your account: off is bootout, then the disabled flag; on clears the flag, then
    /// bootstraps. A bootout of a job that is not loaded (launchctl's 3 and 113) is fine; any other bootout failure is
    /// said, since the confirm promised it stops now. A bootstrap of a job already loaded is not a failure: the flag is
    /// what decides the next login.
    private func setJob(_ item: LoginItems.Item, on: Bool) async {
        let (flag, now) = LoginItems.steps(item, on: on, uid: getuid())
        let stopped = on ? true : await Self.launchctl(now, alsoFine: Self.notLoaded)
        guard await Self.launchctl(flag) else {
            problem = "\(item.label) was not turned \(on ? "on" : "off")."
            return await reloadJobs()
        }
        if on { await Self.launchctl(now) }
        if !stopped { problem = "\(item.label) is off from the next login, but launchctl could not stop it now." }
        await reloadJobs()
    }

    /// A daemon, as root: the same steps in the system domain in one `do shell script` with administrator privileges,
    /// so macOS shows its own password prompt, with no timeout while it waits. A cancelled prompt changes nothing.
    private func setAsRoot(_ item: LoginItems.Item, on: Bool) async {
        switch await Self.osascript(LoginItems.rootScript, LoginItems.rootLine(item, on: on), timeout: nil) {
        case nil: problem = "\(item.label) was not turned \(on ? "on" : "off")."
        case let out? where out.contains("not-stopped"): problem = "\(item.label) is off from the next start, but launchctl could not stop it now."
        default: break
        }
        await reloadJobs()
    }

    /// A script with its one argument (never spliced into the script) in a child osascript: its output, empty when the
    /// password prompt was cancelled (-128), nil when it failed (logged).
    private static func osascript(_ script: String, _ argument: String, timeout: Duration? = .seconds(20)) async -> String? {
        do { return try await ChildProcess.run("/usr/bin/osascript", ["-e", script, argument], timeout: timeout) } catch {
            if String(describing: error).contains("(-128)") { return "" }
            slog.notice("login items: osascript: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// bootout's exits for a job that is not loaded: "No such process" and "Could not find specified service".
    private static let notLoaded: Set<Int32> = [3, 113]

    /// One launchctl step; false when it failed (an exit outside 0 and `alsoFine`), logged.
    @discardableResult
    private static func launchctl(_ arguments: [String], alsoFine: Set<Int32> = []) async -> Bool {
        do {
            _ = try await ChildProcess.run("/bin/launchctl", arguments, timeout: .seconds(10), success: alsoFine.union([0]))
            return true
        } catch {
            slog.notice("login items: launchctl \(arguments.joined(separator: " "), privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// System Settings › General › Login Items, where macOS switches what an app registered itself.
    static func openSettings() { SystemModule.pane("com.apple.LoginItems-Settings.extension") }
}
