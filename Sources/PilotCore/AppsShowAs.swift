import Foundation

/// How every list in Pilot shows an app (story 154, Sven 2026-10-09): its own icon, its name, or both; set once on Look.
/// Icon only keeps the name in the row's tooltip and for search, Title only leaves the name alone on the row.
public enum AppsShowAs: String, CaseIterable, Sendable {
    case icon, title, both

    /// A fresh install shows both.
    public static let standard = AppsShowAs.both

    public var label: String {
        switch self {
        case .icon: "Icon only"
        case .title: "Title only"
        case .both: "Icon and title"
        }
    }

    /// How a row wears its app: `.app` a row whose title is the app's name (Apps, Remove, a picker's app), `.owner` a row
    /// whose icon is the app it belongs to beside words of its own (a window's title), which Icon only leaves whole.
    public enum Role: Sendable { case app, owner }

    /// Whether a row in `role` shows the app's icon and its title; a row that lists no app (nil) shows both.
    public func shows(_ role: Role? = .app) -> (icon: Bool, title: Bool) {
        guard let role else { return (true, true) }
        switch self {
        case .both: return (true, true)
        case .icon: return (true, role == .owner)
        case .title: return (false, true)
        }
    }
}

extension MenuIcon {
    /// Whether the icon is an app's own (by its path or bundle id) or a picture found for one, so its row lists an app.
    public var namesApp: Bool { appPath != nil || bundle != nil || remote != nil }
}

extension MenuEntry {
    /// How the row wears an app under Apps show as (story 154); nil for a row that lists no app. An app itself (Apps, Open
    /// With); a row Install, Remove or Update lists whose icon names an app or a picture found for it; a window, whose
    /// title is its own, as its app's owner. An app's action and a file keep their icon and title.
    public var appRole: AppsShowAs.Role? {
        switch target {
        case .app: return .app
        case .window: return .owner
        case .package, .remove, .update:
            return icon?.namesApp == true ? .app : nil
        default: return nil
        }
    }
}
