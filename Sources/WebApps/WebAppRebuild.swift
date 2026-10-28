import AppKit

/// Which web apps run, and asking one to quit: NSWorkspace in the app, a fake in tests.
public protocol RunningWebApps: Sendable {
    func isRunning(_ bundleID: String) -> Bool
    func quit(_ bundleID: String)
}

public struct WorkspaceRunningApps: RunningWebApps {
    public init() {}
    public func isRunning(_ bundleID: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    public func quit(_ bundleID: String) { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() } }
}

/// A web app is rebuilt only once it has quit: its binary is replaced under it (card agent-bo-95422813).
public enum WebAppRebuild {
    /// What happened to one app: rebuilt, or why not.
    public struct Outcome: Sendable, Equatable {
        public let name: String
        public let failure: String?
    }

    /// Settings › Web apps → Rebuild and Rebuild all, off the main thread (codesign and the keychain lookup block): the
    /// running ones are asked to quit together, then each is rebuilt once it has gone.
    @concurrent
    public static func all(_ apps: [InstalledWebApp], running: any RunningWebApps = WorkspaceRunningApps(),
                           template: URL = WebAppStamper.bundledTemplate, identity: @Sendable () -> String = SigningIdentity.resolve,
                           wait: Duration = .seconds(5)) async -> [Outcome] {
        apps.filter { running.isRunning($0.bundleID) }.forEach { running.quit($0.bundleID) }
        let signer = identity()
        var outcomes: [Outcome] = []
        for app in apps {
            do {
                try await whenQuit(app.bundleID, name: app.name, apps: running, wait: wait) {
                    try WebAppStamper.rebuild(app, template: template, signingIdentity: signer)
                }
                outcomes.append(Outcome(name: app.name, failure: nil))
            } catch let still as StillRunning {
                outcomes.append(Outcome(name: app.name, failure: still.message))
            } catch {
                outcomes.append(Outcome(name: app.name, failure: "\(app.name) was not rebuilt: \(error.localizedDescription)"))
            }
        }
        return outcomes
    }

    public struct StillRunning: Error, Equatable {
        public let name: String
        public var message: String { "\(name) is still running; quit it and press Rebuild again." }
    }

    /// Asks a running app to quit and waits up to `wait` for it, then builds; one that stays running is not touched.
    public static func whenQuit(_ bundleID: String, name: String, apps: any RunningWebApps, wait: Duration = .seconds(5),
                                isolation: isolated (any Actor)? = #isolation, build: () throws -> Void) async throws {
        if apps.isRunning(bundleID) {
            apps.quit(bundleID)
            let deadline = ContinuousClock.now + wait
            while apps.isRunning(bundleID), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            guard !apps.isRunning(bundleID) else { throw StillRunning(name: name) }
        }
        try build()
    }
}
