import AppKit
import PilotCore

/// Ghostex's window and sidebar colour through its own CLI, which saves through the running app as its Settings do.
/// Never starts Ghostex, never touches its terminal colours (Sven, Q20, Q21). A fake takes its place in every test host.
@MainActor enum GhostexColours {
    /// Past Ghostex's own 3 s save, so a slow save is never killed half done.
    private static let timeout: Duration = .seconds(4)

    static func effects() -> ThemeCoordinator.GhostexEffects {
        // Every call is a child awaited off the main thread, so the Hyper tap never waits on Ghostex.
        .init(installed: { StatusLights.ghostex != nil }, read: {
            // A Ghostex that does not answer counts as closed, so it can never stop a theme.
            guard running, let ghostex = StatusLights.ghostex,
                  let text = try? await ChildProcess.run(ghostex.path, list, environment: environment, timeout: timeout) else { return nil }
            return try parse(Data(text.utf8))
        }, write: { key, value in
            guard GhostexInterface.valid(key: key, values: [value]), let ghostex = StatusLights.ghostex else { throw ThemeFailure("refused Ghostex setting \(key)") }
            // After `--` a negative Colourfulness is a value, not short flags (Ghostex's parse_args).
            _ = try await ChildProcess.run(ghostex.path, ["settings", "set", "--json", "--", key, value], environment: environment, timeout: timeout)
        })
    }
    private static let list = ["settings", "list", "--json", "--tab", "theme"]
    private static var environment: [String: String] { ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory()] }
    private static func parse(_ data: Data) throws -> [String: String]? {
        guard let rows = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["settings"] as? [[String: Any]] else { throw ThemeFailure("unreadable Ghostex settings") }
        var found: [String: String] = [:]
        for row in rows {
            guard let key = row["key"] as? String, GhostexInterface.keys.contains(key) else { continue }
            if let value = row["current"] as? String { found[key] = value }
            else if GhostexInterface.numbers.contains(key), let value = row["current"] as? NSNumber { found[key] = GhostexInterface.text(value.doubleValue) }
        }
        return GhostexInterface.required.allSatisfy { found[$0] != nil } ? found : nil  // A Ghostex without these counts as not there.
    }

    private static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.madda.ghostex.gpui").isEmpty }

}
