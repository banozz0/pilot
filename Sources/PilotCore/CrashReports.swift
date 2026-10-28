import Foundation

/// Crash reports a stranger can send (SH12, Sven Q315: no crash SDK in 1.0): macOS writes Pilot's and its helpers' to the
/// Mac's DiagnosticReports folder, and they stay there. Pilot only names the newest one and shows it in Finder; it never
/// reads one or sends it. Only the file names are read: the process and the date are in them.
public enum CrashReports {
    /// The Mac's reports folder; a test run's own throwaway one, so the sandbox host never lists Sven's.
    public static let folder = isIsolatedTestRun
        ? PilotFolder.support.appending(path: "DiagnosticReports", directoryHint: .isDirectory)
        : FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    /// How the folder is named to the AI and in the bug form: never the home folder's path.
    public static let shownFolder = "~/Library/Logs/DiagnosticReports"
    /// Pilot's process and its helpers' (Scripts/build-app.sh), and every web app's (WebAppSpec.executable).
    public static let processes = ["Pilot", "pilot", "pilot-text", "pilot-upscale", "pilot-dictate", "pilot-files", "pilot-mcp", "PilotWebApp"]
    /// A report older than this is not named: the bug it shows is likely fixed or already reported.
    public static let recent: TimeInterval = 7 * 24 * 3600

    public struct Report: Sendable, Equatable {
        public let url: URL
        public let process: String
        public let date: Date
        public var name: String { url.lastPathComponent }
    }

    /// "Pilot-2026-10-18-201000.ips", "ExcUserFault_Pilot-2026-10-18-201000.ips", "pilot-text-2026-10-18-201000.1.ips".
    nonisolated(unsafe) private static let pattern = /^(?:[A-Za-z]+_)?(.+)-(\d{4}-\d{2}-\d{2}-\d{6})(?:\.\d+)?\.ips$/

    /// The newest of Pilot's reports in `folder` from the last `recent`, or nil. Lists names only.
    public static func newest(in folder: URL = folder, now: Date = Date()) -> Report? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        return names.compactMap { name -> Report? in
            guard let match = name.wholeMatch(of: pattern), processes.contains(String(match.1)),
                  let date = stamp.date(from: String(match.2)), date <= now, now.timeIntervalSince(date) <= recent else { return nil }
            return Report(url: folder.appending(path: name), process: String(match.1), date: date)
        }.max { $0.date < $1.date }
    }
}
