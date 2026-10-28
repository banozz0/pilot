import Foundation

/// The drive catalogue (GLOSSARY.md; story 46; card agent-bo-95422445): the shipped JSON of known apps and their
/// plain-English drive actions, `Packaging/drive-catalogue.json`, copied into Pilot.app's Resources. Each app names the
/// vendor page its routes were checked against and the date; an app with no entry is not supported, never guessed.
public struct DriveCatalogue: Decodable, Sendable {
    public struct App: Decodable, Sendable {
        public var name: String, bundle: String
        /// The vendor's page the routes were checked against, and when (yyyy-MM-dd).
        public var doc: String, checked: String
        public var actions: [Entry]
    }

    /// One action: what the Binds screen shows and the action id it binds, a DriveRoute, an AppLink or one of Pilot's own
    /// actions doing the app's job (Music's Play or pause is `media.playPause`, the media key). The menu lists
    /// each as a command of its app (P38), its badge `symbol`; `opens` brings the app forward first, launching it, for a
    /// route whose result shows in the app (a menu item's New Event).
    public struct Entry: Decodable, Sendable, Hashable {
        public var label: String, route: String
        public var symbol: String?, opens: Bool?
    }

    public enum Problem: Error, Equatable {
        case unreadable(String)
        case route(app: String, action: String)
        case doc(app: String)
        case date(app: String)
    }

    public let apps: [App]

    /// Refuses the whole file on one bad entry: a route Pilot cannot run, a doc that is not a web page, a date that is not one.
    public init(json: Data) throws(Problem) {
        do { apps = try JSONDecoder().decode(File.self, from: json).apps }
        catch { throw .unreadable(String(describing: error)) }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")
        for app in apps {
            guard let url = URL(string: app.doc), url.scheme == "https", url.host != nil else { throw .doc(app: app.name) }
            guard day.date(from: app.checked) != nil else { throw .date(app: app.name) }
            for entry in app.actions where DriveRoute(id: entry.route) == nil && AppLink(id: entry.route) == nil && !Self.ownAction(entry.route) {
                throw .route(app: app.name, action: entry.label)
            }
        }
    }

    /// One of Pilot's own action ids, a module and a name ("media.next"): no link or route.
    static func ownAction(_ id: String) -> Bool { id.wholeMatch(of: /[a-z]+\.[A-Za-z]+/) != nil }

    /// An empty catalogue, for a Pilot run outside its bundle.
    public init() { apps = [] }

    private struct File: Decodable { var apps: [App] }

    /// The app's actions; nil when the catalogue does not hold it: not supported.
    public func actions(for bundle: String) -> [Entry]? { apps.first { $0.bundle == bundle }?.actions }

    /// The app and action holding a bound route.
    public func app(for route: String) -> (app: App, entry: Entry)? {
        for app in apps { if let entry = app.actions.first(where: { $0.route == route }) { return (app, entry) } }
        return nil
    }

    /// "Ghostty: New window" for a bound route the catalogue holds.
    public func label(for route: String) -> String? { app(for: route).map { "\($0.app.name): \($0.entry.label)" } }
}
