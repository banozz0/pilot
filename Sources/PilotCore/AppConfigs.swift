import Foundation

/// Paths as Pilot shows them. The config catalogue that once lived here went with the Configs page (Sven, 2026-11-22, Q351);
/// the name stays for the pages, verbs and reports that write paths with ~.
public enum AppConfigs {
    /// A path with the home folder written ~.
    public static func tilde(_ path: String, home: String) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
