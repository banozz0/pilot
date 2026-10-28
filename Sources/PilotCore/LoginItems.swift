import Foundation

/// Mac › Update & Clean's Login and background items (Sven, Q386, from Toolbox for Mac): what starts at login or runs in
/// the background. macOS keeps its full list (the BTM store) from every app but root, so Pilot lists what it can read:
/// the login items, and the launchd jobs in ~/Library/LaunchAgents, /Library/LaunchAgents and /Library/LaunchDaemons.
/// Each turns off and back on here (Sven, Q412): a login item through System Events, a job through launchctl (a daemon's
/// as root, behind macOS's own password prompt). Never Pilot's own or a com.apple job; an item an app registered itself
/// (SMAppService) is in neither list, so Open Login Items… stays for those.
public enum LoginItems {
    public enum Kind: String, Sendable, CaseIterable {
        /// An app in Open at Login.
        case loginItem
        /// A launchd agent in ~/Library/LaunchAgents: yours.
        case agent
        /// An agent in /Library/LaunchAgents, run for every user, each in their own domain: it switches for your account.
        case sharedAgent
        /// A daemon in /Library/LaunchDaemons, run as root.
        case daemon

        public var title: String {
            switch self {
            case .loginItem: "Login item"
            case .agent: "Your agent"
            case .sharedAgent: "Agent for all users"
            case .daemon: "Background daemon"
            }
        }
    }

    public struct Item: Equatable, Sendable, Identifiable {
        public var id: String { "\(kind.rawValue):\(label)" }
        /// The job's launchd label, or a login item's name.
        public let label: String
        public let kind: Kind
        /// The plist or the login item's app.
        public let path: String
        /// The app it belongs to, by bundle id (AssociatedBundleIdentifiers), when the plist names one.
        public let bundleID: String?
        /// The `.app` its program sits in, when it sits in one.
        public let appPath: String?
        /// launchd's disabled flag is set: it does not start at login.
        public var disabled: Bool
        /// Pilot's own (its bundle, or a job labelled under its id), which only General › Launch at login turns off.
        public var isPilot = false

        public init(label: String, kind: Kind, path: String, bundleID: String? = nil, appPath: String? = nil, disabled: Bool = false) {
            self.label = label; self.kind = kind; self.path = path; self.bundleID = bundleID; self.appPath = appPath; self.disabled = disabled
        }

        /// Marks it Pilot's own when it is the app at `path`, carries its bundle id, or is labelled under it.
        public mutating func mark(pilot bundle: String, path: String) {
            isPilot = appPath == path || bundleID == bundle || label.hasPrefix(bundle)
        }

        /// Pilot turns it off and on itself: anything but Pilot's own and macOS's (com.apple), a job only under a label
        /// launchctl takes as is, a login item only with its app's path, which Turn on puts back.
        public var canSwitch: Bool {
            guard !isPilot, !label.hasPrefix("com.apple.") else { return false }
            return kind == .loginItem ? !path.isEmpty : LoginItems.plainLabel(label)
        }

        /// A daemon switches as root, so macOS asks for an administrator password first.
        public var needsAdmin: Bool { kind == .daemon }
    }

    /// A launchd label of ASCII letters, digits, dots, dashes and underscores; any other came from a plist Pilot will
    /// not hand to launchctl.
    public static func plainLabel(_ label: String) -> Bool {
        !label.isEmpty && label.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// One job from its plist; nil for a file that is not a launchd job (no Label).
    public static func job(_ data: Data, path: String, kind: Kind) -> Item? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty else { return nil }
        let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
        let bundle = (plist["AssociatedBundleIdentifiers"] as? [String])?.first ?? plist["AssociatedBundleIdentifiers"] as? String
        return Item(label: label, kind: kind, path: path, bundleID: bundle, appPath: program.flatMap(app))
    }

    /// The `.app` a path sits in: "/Applications/Foo.app/Contents/MacOS/foo" is "/Applications/Foo.app".
    public static func app(_ path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) else { return path.lowercased().hasSuffix(".app") ? path : nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Open at Login's apps as System Events lists them, "name<tab>path" a line.
    public static func loginItems(_ text: String) -> [Item] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let name = parts.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            let path = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            return Item(label: name, kind: .loginItem, path: path, appPath: app(path))
        }
    }

    /// The AppleScript that lists them, run in a child osascript (System Events, the one automation target).
    public static let loginItemsScript = """
        set out to ""
        tell application "System Events"
            repeat with i in (every login item)
                set out to out & (name of i) & tab & (path of i) & linefeed
            end repeat
        end tell
        return out
        """

    /// The labels `launchctl print-disabled gui/<uid>` lists as disabled (`"label" => disabled`).
    public static func disabled(printDisabled text: String) -> Set<String> {
        Set(text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\"")
            guard parts.count >= 3, parts[2].contains("=> disabled") else { return nil }
            return String(parts[1])
        })
    }

    /// The order the list shows: login items, then your agents, then the shared ones and the daemons; by name inside each.
    public static func sorted(_ items: [Item]) -> [Item] {
        let rank = Dictionary(uniqueKeysWithValues: Kind.allCases.enumerated().map { ($1, $0) })
        return items.sorted { (rank[$0.kind]!, $0.label.lowercased()) < (rank[$1.kind]!, $1.label.lowercased()) }
    }

    /// The launchctl arguments that switch a job: `flag` sets or clears launchd's disabled flag, which decides the
    /// next login; `now` stops it (bootout) or starts it (bootstrap) in this session. Off runs `now` first, on runs it last.
    /// A daemon's domain is the system's; an agent's, shared or yours, is your login's.
    public static func steps(_ item: Item, on: Bool, uid: uid_t) -> (flag: [String], now: [String]) {
        let domain = item.kind == .daemon ? "system" : "gui/\(uid)", target = "\(domain)/\(item.label)"
        return on ? (["enable", target], ["bootstrap", domain, item.path]) : (["disable", target], ["bootout", target])
    }

    /// The shell line a daemon's switch runs as root: one password prompt for both steps, each word single-quoted.
    /// Off: a bootout that fails other than "not loaded" (3, 113) prints `not-stopped`; a failed disable fails the line.
    /// On: a failed enable fails it; a bootstrap of a job already loaded does not, the flag decides the next start.
    public static func rootLine(_ item: Item, on: Bool) -> String {
        let (flag, now) = steps(item, on: on, uid: 0)
        let launchctl = { (arguments: [String]) in (["/bin/launchctl"] + arguments).map(quoted).joined(separator: " ") }
        return on ? "\(launchctl(flag)) || exit 1; \(launchctl(now)) >/dev/null 2>&1; exit 0"
            : "\(launchctl(now)) >/dev/null 2>&1; s=$?; \(launchctl(flag)) || exit 1; case $s in 0|3|113) ;; *) echo not-stopped;; esac"
    }

    /// A shell word in single quotes, a quote inside closed and reopened.
    public static func quoted(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// Runs its one argument as root behind macOS's own password prompt; Pilot never sees the password.
    public static let rootScript = """
        on run argv
            do shell script (item 1 of argv) with administrator privileges
        end run
        """

    /// Takes the login item named by its one argument out of Open at Login.
    public static let removeLoginItemScript = """
        on run argv
            tell application "System Events" to delete login item (item 1 of argv)
        end run
        """

    /// Puts the app at its one argument back in Open at Login.
    public static let addLoginItemScript = """
        on run argv
            tell application "System Events" to make login item at end with properties {path:(item 1 of argv), hidden:false}
        end run
        """

    /// The login items with the ones Pilot took out (name to app, from Pilot's settings) listed again as Off, and what
    /// to keep remembering: a name System Events lists again was put back elsewhere, so it is let go.
    public static func withRemoved(_ live: [Item], removed: [String: String]) -> (items: [Item], removed: [String: String]) {
        let names = Set(live.map(\.label))
        let kept = removed.filter { !names.contains($0.key) }
        return (live + kept.map { Item(label: $0.key, kind: .loginItem, path: $0.value, appPath: app($0.value), disabled: true) }, kept)
    }
}
