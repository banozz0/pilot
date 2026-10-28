import Foundation

/// A pane of macOS System Settings the searches find (Q131, Sven 2026-10-15: "If I type 'privacy and security' it should
/// show me Privacy & Security and direct me to Settings"). Written by hand: the panes' own ExtensionKit names are internal
/// ("PowerPreferences", "UsersGroups") or missing, so each carries the title System Settings shows and the words it is
/// searched by. Ids read off macOS 27.0.1's `/System/Library/ExtensionKit/Extensions`; the parts of Privacy & Security use
/// the legacy security pane's anchors, which Pilot already opens (Accessibility, Full Disk Access, Screen Recording).
public struct SystemPane: Hashable, Sendable {
    public let title: String
    /// What `x-apple.systempreferences:` opens: an extension id, or the security pane with a `Privacy_` anchor.
    public let id: String
    /// The pane this one is a part of (General for Storage, Privacy & Security for Screen Recording); nil for a sidebar pane.
    public let parent: String?
    /// Other names it goes by: an older one (Apple ID), the desktop's (Energy for Battery).
    let spellings: [String]
    let keywords: [String]

    init(_ title: String, _ id: String, in parent: String? = nil, also spellings: [String] = [], _ keywords: [String] = []) {
        self.title = title; self.id = id; self.parent = parent; self.spellings = spellings; self.keywords = keywords
    }

    public var url: URL { URL(string: "x-apple.systempreferences:\(id)")! }
    /// "System Settings › Privacy & Security › Automation", as the window's search lists it.
    public var path: String { (["System Settings"] + [parent].compactMap(\.self) + [title]).joined(separator: " › ") }

    /// The names a search reads as the title: the title and its spellings, each "&" also as "and", since every typed word
    /// must match ("privacy and security").
    var names: String {
        let all = [title] + spellings
        return (all + all.filter { $0.contains("&") }.map { $0.replacingOccurrences(of: "&", with: "and") }).joined(separator: " ")
    }
}

/// Settings by name, Pilot's and macOS's (Q131, spec settings-search): the rows Hyper+Space's root search lists, and the
/// panes the window's search lists under Pilot's places (AppPlace.search).
public enum SettingsSearch {
    /// `system.pane:<pane id>` opens that System Settings pane; `window.page:<page or part>` opens that place of Pilot's
    /// window (AppPlace.named). Dynamic ids, so the menu's picks rank them and Cmd+K binds them like any action.
    public static let paneAction = "system.pane:", placeAction = "window.page:"

    /// The pane id an action names; nil for another action.
    public static func pane(inAction id: String) -> String? {
        guard id.hasPrefix(paneAction) else { return nil }
        let pane = String(id.dropFirst(paneAction.count))
        return pane.isEmpty ? nil : pane
    }

    /// The place of Pilot's window an action names; nil for another action or an unknown place.
    public static func place(inAction id: String) -> AppPlace? {
        guard id.hasPrefix(placeAction) else { return nil }
        return AppPlace.named(String(id.dropFirst(placeAction.count)))
    }

    /// A pane by its id, for its title.
    public static func pane(_ id: String) -> SystemPane? { panes.first { $0.id == id } }

    public static func actionID(_ pane: SystemPane) -> String { paneAction + pane.id }
    public static func actionID(_ place: AppPlace) -> String { placeAction + (place.section?.rawValue ?? place.page.rawValue) }

    /// What the panes' names and words scored, ranked again on each keystroke at the root.
    private static let memo = FuzzyRanker.Memo()

    /// The panes whose name matches the query, best first, then those found by a word they are searched by; empty for a
    /// blank query.
    public static func panes(_ query: String) -> [SystemPane] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let byName = FuzzyRanker.rank(panes, query: query, title: \.names, memo: memo)
        let named = Set(byName)
        let byWord = FuzzyRanker.rank(panes.filter { !named.contains($0) }, query: query, title: { $0.keywords.joined(separator: " ") }, memo: memo)
        return byName + byWord
    }

    /// The root search's rows for a query: the places of Pilot's window it finds (AppPlace.search, the window's own rule),
    /// then the panes (panes(_:)), a Setting each, so an app or action that matches as well stays above them, unless a setting's title is what was typed (P53). Provided per
    /// query, as emoji are: listed whole, their long keyword lists matched letters scattered across words ("gaps" found
    /// Export and import by its initials, "msg" the Menu page over Messages).
    public static func entries(for query: String) -> [MenuEntry] {
        AppPlace.search(query).map { place in
            MenuEntry(title: place.path, target: .action(actionID(place)), keywords: place.keywords.joined(separator: " "),
                      ownKind: .setting, subtitle: "Pilot", icon: .glyph(place.page.symbol, .accent))
        } + panes(query).map { pane in
            MenuEntry(title: pane.title, target: .action(actionID(pane)),
                      keywords: ([pane.names] + pane.keywords).joined(separator: " "), ownKind: .setting,
                      subtitle: pane.parent ?? "System Settings", icon: MenuIcon.glyph("gearshape", .neutral).app(bundle: settingsApp))
        }
    }

    /// System Settings' bundle id, whose icon the pane rows wear.
    static let settingsApp = "com.apple.systempreferences"

    private static let privacy = "Privacy & Security", general = "General"
    private static func privacyPart(_ title: String, _ anchor: String, also: [String] = [], _ keywords: [String] = []) -> SystemPane {
        SystemPane(title, "com.apple.preference.security?Privacy_\(anchor)", in: privacy, also: also, ["privacy", "permission"] + keywords)
    }

    /// The sidebar's panes in its order, then General's parts, then Privacy & Security's.
    public static let panes: [SystemPane] = [
        SystemPane("Wi-Fi", "com.apple.wifi-settings-extension", ["wireless", "network", "internet"]),
        SystemPane("Bluetooth", "com.apple.BluetoothSettings", ["airpods", "headphones", "pair"]),
        SystemPane("Network", "com.apple.Network-Settings.extension", ["ethernet", "firewall", "proxy", "dns", "internet"]),
        SystemPane("VPN", "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", ["tunnel"]),
        SystemPane("Battery", "com.apple.Battery-Settings.extension", also: ["Energy"], ["power", "low power", "charging", "sleep"]),
        SystemPane(general, "com.apple.systempreferences.GeneralSettings"),
        SystemPane("Accessibility", "com.apple.Accessibility-Settings.extension", ["zoom", "voiceover", "reduce motion", "contrast"]),
        SystemPane("Appearance", "com.apple.Appearance-Settings.extension", ["dark mode", "light mode", "accent colour", "accent color"]),
        SystemPane("Apple Intelligence & Siri", "com.apple.Siri-Settings.extension", also: ["Siri"], ["voice", "assistant"]),
        SystemPane("Menu Bar", "com.apple.ControlCenter-Settings.extension", also: ["Control Center", "Control Centre"]),
        SystemPane("Desktop & Dock", "com.apple.Desktop-Settings.extension",
                   ["dock", "stage manager", "mission control", "hot corners", "widgets", "windows"]),
        SystemPane("Displays", "com.apple.Displays-Settings.extension", ["monitor", "resolution", "brightness", "night shift", "true tone"]),
        SystemPane("Spotlight", "com.apple.Spotlight-Settings.extension", ["search"]),
        SystemPane("Wallpaper", "com.apple.Wallpaper-Settings.extension", ["background", "desktop picture"]),
        SystemPane("Notifications", "com.apple.Notifications-Settings.extension", ["alerts", "banners", "badges"]),
        SystemPane("Sound", "com.apple.Sound-Settings.extension", ["volume", "output", "input", "microphone", "speakers", "alert sound"]),
        SystemPane("Focus", "com.apple.Focus-Settings.extension", ["do not disturb", "dnd"]),
        SystemPane("Screen Time", "com.apple.Screen-Time-Settings.extension", ["app limits", "downtime"]),
        SystemPane("Lock Screen", "com.apple.Lock-Screen-Settings.extension", ["screen saver", "require password", "display off"]),
        SystemPane(privacy, "com.apple.settings.PrivacySecurity.extension", ["permissions", "filevault", "gatekeeper"]),
        SystemPane("Touch ID & Password", "com.apple.Touch-ID-Settings.extension", also: ["Login Password"], ["fingerprint"]),
        SystemPane("Users & Groups", "com.apple.Users-Groups-Settings.extension", ["accounts", "guest", "admin"]),
        SystemPane("Internet Accounts", "com.apple.Internet-Accounts-Settings.extension", ["mail", "google"]),
        SystemPane("Game Center", "com.apple.Game-Center-Settings.extension"),
        SystemPane("Game Controllers", "com.apple.Game-Controller-Settings.extension", ["gamepad", "controller"]),
        SystemPane("Wallet & Apple Pay", "com.apple.WalletSettingsExtension", ["cards"]),
        SystemPane("Keyboard", "com.apple.Keyboard-Settings.extension",
                   ["keyboard shortcuts", "input sources", "dictation", "key repeat", "text replacements"]),
        SystemPane("Mouse", "com.apple.Mouse-Settings.extension", ["tracking speed", "scrolling"]),
        SystemPane("Trackpad", "com.apple.Trackpad-Settings.extension", ["gestures", "tap to click", "scrolling"]),
        SystemPane("Printers & Scanners", "com.apple.Print-Scan-Settings.extension", ["printer"]),
        SystemPane("Apple Account", "com.apple.systempreferences.AppleIDSettings", also: ["Apple ID"], ["icloud", "sign in"]),
        SystemPane("Family", "com.apple.Family-Settings.extension", ["family sharing"]),

        SystemPane("About", "com.apple.SystemProfiler.AboutExtension", in: general, ["serial number", "macos version", "this mac"]),
        SystemPane("Software Update", "com.apple.Software-Update-Settings.extension", in: general, ["macos update", "upgrade"]),
        SystemPane("Storage", "com.apple.settings.Storage", in: general, ["disk space", "free space"]),
        SystemPane("AirDrop & Handoff", "com.apple.AirDrop-Handoff-Settings.extension", in: general, ["airplay receiver", "continuity"]),
        SystemPane("Login Items & Extensions", "com.apple.LoginItems-Settings.extension", in: general,
                   ["open at login", "startup", "background items"]),
        SystemPane("Language & Region", "com.apple.Localization-Settings.extension", in: general, ["language", "region", "date format"]),
        SystemPane("Date & Time", "com.apple.Date-Time-Settings.extension", in: general, ["clock", "time zone"]),
        SystemPane("Sharing", "com.apple.Sharing-Settings.extension", in: general,
                   ["screen sharing", "file sharing", "remote login", "ssh", "computer name"]),
        SystemPane("Time Machine", "com.apple.Time-Machine-Settings.extension", in: general, ["backup"]),
        SystemPane("Transfer or Reset", "com.apple.Transfer-Reset-Settings.extension", in: general, ["erase", "factory reset"]),
        SystemPane("Startup Disk", "com.apple.Startup-Disk-Settings.extension", in: general),
        SystemPane("Device Management", "com.apple.Profiles-Settings.extension", in: general, ["profiles", "mdm"]),

        privacyPart("Accessibility", "Accessibility", ["allow control"]),
        privacyPart("Full Disk Access", "AllFiles"),
        privacyPart("Screen & System Audio Recording", "ScreenCapture", also: ["Screen Recording"]),
        privacyPart("Automation", "Automation", ["apple events", "system events"]),
        privacyPart("Input Monitoring", "ListenEvent", ["keyboard"]),
        privacyPart("Camera", "Camera"),
        privacyPart("Microphone", "Microphone"),
        privacyPart("Location Services", "LocationServices", ["location"]),
        privacyPart("Files & Folders", "FilesAndFolders"),
        privacyPart("Developer Tools", "DevTools"),
        privacyPart("Bluetooth", "Bluetooth"),
        privacyPart("App Management", "AppBundles"),
    ]
}

extension MenuNavigator {
    /// The settings a root search finds (SettingsSearch.entries(for:)); none inside a branch.
    public mutating func provideSettings(_ query: String) {
        provide(.setting, branch == nil ? SettingsSearch.entries(for: query) : [])
    }
}
