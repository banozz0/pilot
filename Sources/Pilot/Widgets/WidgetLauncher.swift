import AppKit
import OSLog
import PilotCore

private let launchLog = Logger(subsystem: "dev.banozz.pilot", category: "widgets")

/// The Launcher's tiles (Sven, 1.0.2 build 6: "all of the launchers options into a cool widget"): Hyper+Space rows by
/// their keys (Widget.menuPicks), picked in Edit widget from the menu's own list, each drawn with its icon and run as its
/// menu row runs: an app opens, an action or an extension command runs, a branch opens Hyper+Space inside it. Rows that
/// type into the app in front (emoji, snippets, stickers), name a window or a file, or take arguments in the search are
/// not offered: a click on the desktop has no app to type into and no search.
@MainActor
enum WidgetLauncher {
    /// One tile as Pilot has its row now: the app's own icon, else the row's glyph.
    struct Tile: Equatable {
        let key: String, title: String, symbol: String
        let icon: NSImage?
    }

    /// Every app, action, app command and branch Hyper+Space lists, in its order, grouped as the menu heads them; read
    /// once as Edit widget opens, as the menu reads them as it opens.
    static func choices() -> [WidgetEditChoices.Pick] {
        guard let engine = Engine.shared else { return [] }
        var seen: Set<String> = [], names: [String: String] = [:]
        return PilotMenu.entries(engine, scripts: ScriptCommand.find(), extensions: Extension.find().extensions).compactMap { entry in
            // A script that asks for its arguments takes them in the menu's search, which a tile has none of.
            guard !entry.isOffer, entry.fills == nil, let key = entry.target.key, Widget.isMenuKey(key), seen.insert(key).inserted else { return nil }
            let group: String = switch entry.target {
            case .app: "Apps"
            case .branch: "Menus"
            // An app's commands under its name, looked up once an app.
            default: entry.kind != .command ? entry.home?.title ?? "Actions"
                : "\(entry.app.map { bundle in names[bundle] ?? { names[bundle] = AppsModule.displayName(bundle); return names[bundle]! }() } ?? "App") commands"
            }
            return .init(id: key, title: entry.title, group: group)
        }
    }

    /// The picks Pilot has now, as tiles; a row gone since (an app removed, an extension uninstalled) is left out.
    static func tiles(_ value: JSONValue?) -> [Tile] { Widget.menuPicks(value).compactMap(tile) }

    static func tile(_ key: String) -> Tile? {
        switch MenuEntry.Target(key: key) {
        case .app(let bundle)?:
            // One LaunchServices lookup for its name; the icon is AppsModule's, kept.
            guard let url = AppsModule.url(forBundle: bundle) else { return nil }
            return Tile(key: key, title: AppsModule.appName(at: url), symbol: MenuIcon.app.symbol, icon: AppsModule.icon(bundle: bundle))
        case .action(let id)?:
            guard let action = Engine.shared?.action(id) else { return nil }
            return Tile(key: key, title: action.label, symbol: DeskKit.symbol(forAction: id), icon: nil)
        case .branch(let branch)?:
            return Tile(key: key, title: branch.title, symbol: branch.look.symbol, icon: nil)
        default: return nil
        }
    }

    /// A tile's press, as its menu row runs it.
    static func run(_ key: String) {
        switch MenuEntry.Target(key: key) {
        case .app(let bundle)?:
            launchLog.notice("launcher: open \(bundle, privacy: .public) \(AppsModule.open(bundle: bundle) ? "opened" : "not installed", privacy: .public)")
        case .action(let id)?:
            guard let action = Engine.shared?.action(id) else { return HUD.tip("Launcher: Pilot has no action \(id)") }
            launchLog.notice("launcher: runs \(id, privacy: .public)")
            action.run()
        case .branch(let branch)?: PilotMenu.shared.open(branch: branch)
        default: break
        }
    }
}
