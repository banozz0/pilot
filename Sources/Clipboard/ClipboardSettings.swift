import Foundation

/// Settings › Clipboard (story 89, wireframe mSEMT3YCZpU section 10), stored in UserDefaults and read at launch.
/// Skip passwords is not here: SPEC.md says a password manager's copies are never kept, so it is no switch.
public struct ClipboardSettings: Equatable, Sendable {
    public enum ReturnAction: String, CaseIterable, Sendable { case paste, copy }

    /// Unpinned items kept.
    public var keepCount: Int
    /// Days an unpinned item is kept; nil keeps it until `keepCount` pushes it out.
    public var keepDays: Int?
    public var saveImages: Bool
    /// Bundle ids whose copies are never recorded.
    public var ignoredApps: [String]
    /// What Return does in the panel; Cmd+C does the other.
    public var returnAction: ReturnAction
    /// The panel's sort, as Cmd+S and Cmd+Shift+S left it (card agent-bo-95422783).
    public var order: ClipOrder
    /// A copied card number or key leaves the history after `secretMinutes` (P65); a pinned one stays.
    public var expireSecrets: Bool
    public var secretMinutes: Int

    /// What `secretMinutes` may be: a minute to a day.
    public static let secretMinuteRange = 1...1440

    init(keepCount: Int, keepDays: Int?, saveImages: Bool, ignoredApps: [String], returnAction: ReturnAction,
         order: ClipOrder = ClipOrder(), expireSecrets: Bool = true, secretMinutes: Int = 5) {
        self.keepCount = keepCount; self.keepDays = keepDays; self.saveImages = saveImages
        self.ignoredApps = ignoredApps; self.returnAction = returnAction; self.order = order
        self.expireSecrets = expireSecrets; self.secretMinutes = secretMinutes
    }

    /// ClipBook Rust's settings on Sven's Mac, read 2026-10-04 (card agent-bo-95422733): retention_days null for
    /// every kind (kept forever), ignored_apps Bitwarden, Return pastes, images kept. ClipBook has no count limit;
    /// SPEC.md's 500 stands. Passwords and Keychain Access join the list as the wireframe draws it.
    public static let `default` = ClipboardSettings(
        keepCount: 500, keepDays: nil, saveImages: true,
        ignoredApps: ["com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess"], returnAction: .paste)

    private enum Keys {
        static let keepCount = "clipboard.keepCount", keepDays = "clipboard.keepDays", saveImages = "clipboard.saveImages"
        static let ignoredApps = "clipboard.ignoredApps", returnAction = "clipboard.returnAction"
        static let sort = "clipboard.sort", sortReversed = "clipboard.sortReversed"
        static let expireSecrets = "clipboard.expireSecrets", secretMinutes = "clipboard.secretMinutes"
    }

    /// An unset row reads as its default; keep-days 0 is stored for "forever", so it is never mistaken for unset.
    /// Keep-last is at least 1: 0 would empty the history on the next copy, and a negative cap is no cap in SQLite.
    public init(defaults: UserDefaults) {
        let d = Self.default
        keepCount = max(defaults.object(forKey: Keys.keepCount) as? Int ?? d.keepCount, 1)
        keepDays = (defaults.object(forKey: Keys.keepDays) as? Int).map { $0 > 0 ? $0 : nil } ?? d.keepDays
        saveImages = defaults.object(forKey: Keys.saveImages) as? Bool ?? d.saveImages
        ignoredApps = defaults.stringArray(forKey: Keys.ignoredApps) ?? d.ignoredApps
        returnAction = defaults.string(forKey: Keys.returnAction).flatMap(ReturnAction.init(rawValue:)) ?? d.returnAction
        order = ClipOrder(sort: defaults.string(forKey: Keys.sort).flatMap(ClipSort.init(rawValue:)) ?? d.order.sort,
                          reversed: defaults.object(forKey: Keys.sortReversed) as? Bool ?? d.order.reversed)
        expireSecrets = defaults.object(forKey: Keys.expireSecrets) as? Bool ?? d.expireSecrets
        let minutes = defaults.object(forKey: Keys.secretMinutes) as? Int ?? d.secretMinutes
        secretMinutes = min(max(minutes, Self.secretMinuteRange.lowerBound), Self.secretMinuteRange.upperBound)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(keepCount, forKey: Keys.keepCount)
        defaults.set(keepDays ?? 0, forKey: Keys.keepDays)
        defaults.set(saveImages, forKey: Keys.saveImages)
        defaults.set(ignoredApps, forKey: Keys.ignoredApps)
        defaults.set(returnAction.rawValue, forKey: Keys.returnAction)
        defaults.set(order.sort.rawValue, forKey: Keys.sort)
        defaults.set(order.reversed, forKey: Keys.sortReversed)
        defaults.set(expireSecrets, forKey: Keys.expireSecrets)
        defaults.set(secretMinutes, forKey: Keys.secretMinutes)
    }

    public var maxAge: TimeInterval? { keepDays.map { TimeInterval($0) * 86_400 } }

    /// Seconds a copied secret is kept; nil while the switch is off.
    public var secretLifetime: TimeInterval? { expireSecrets ? TimeInterval(secretMinutes) * 60 : nil }

    public var capture: ClipboardCapture {
        var capture = ClipboardCapture()
        capture.ignoredApps = Set(ignoredApps)
        capture.saveImages = saveImages
        return capture
    }
}
