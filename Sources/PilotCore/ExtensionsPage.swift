import Foundation

/// What the Extensions page shows (card agent-bo-95423247): every extension in the Extensions folder with its commands,
/// what it says it touches in plain words, and a field per preference holding its value; then the folders that are not
/// extensions, each with why. Since pilot-1-1 (Q600, Q601) one list holds the installed ones and the catalogue's others,
/// the picked one's detail beside it.
public enum ExtensionsPage {
    public struct Row: Equatable, Sendable, Identifiable {
        public let ext: Extension
        /// What it says it touches, a line each (notEnforced goes under them).
        public let permissions: [Permission]
        /// Its preferences in the manifest's order, each with the value a run gets now (nil when it has none).
        public var fields: [Field]
        public var id: String { ext.id }

        public init(ext: Extension, permissions: [Permission], fields: [Field]) { self.ext = ext; self.permissions = permissions; self.fields = fields }

        /// Its manifest's version; nil when it says none.
        public var version: String? { ext.version }
        /// Where it shows, each with its pace (pilot-1-1 T6).
        public var surfaces: [Surface] { ExtensionsPage.surfaces(ext) }
        /// The commands only its own views reach, never listed on the page.
        public var hiddenCommands: Int { ext.commands.count - ext.listed.count }
    }

    /// One place an extension shows (pilot-1-1 T6): its top-bar item, its Hyper+Space branch, its page in the window;
    /// `every` how often Pilot asks it again in seconds, nil for Hyper+Space, asked only as it is typed into.
    public struct Surface: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case bar, menu, page }
        public let kind: Kind, every: Int?
        public init(_ kind: Kind, every: Int? = nil) { self.kind = kind; self.every = every }
    }

    /// Where `ext` shows: its bar item, Hyper+Space while it lists a command, its page.
    public static func surfaces(_ ext: Extension) -> [Surface] {
        var surfaces: [Surface] = []
        if let bar = ext.bar { surfaces.append(Surface(.bar, every: bar.every)) }
        if !ext.listed.isEmpty { surfaces.append(Surface(.menu)) }
        if let page = ext.page { surfaces.append(Surface(.page, every: page.every)) }
        return surfaces
    }

    /// "in the menu bar, Hyper+Space and a page"; nil when it shows nowhere.
    public static func whereItShows(_ surfaces: [Surface]) -> String? {
        guard !surfaces.isEmpty else { return nil }
        return "in " + spokenList(surfaces.map { switch $0.kind { case .bar: "the menu bar"; case .menu: "Hyper+Space"; case .page: "a page" } })
    }

    // MARK: The one list

    /// One row of the one Extensions list (Q601): an installed extension, a catalogue entry not installed, or a Raycast
    /// store folder not installed (T25).
    public struct Entry: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable { case installed, catalogue, store }
        /// What the row's right says: ✓, Update or Get.
        public enum Mark: Equatable, Sendable { case installed, update, get }
        public let id: String, title: String, icon: String?
        /// Its one line: what it is for, in its own words.
        public let line: String
        public let version: String?
        public let kind: Kind, mark: Mark
        /// A Raycast extension's or store folder's icon file (T25); nil for an emoji's.
        public let picture: String?

        public init(id: String, title: String, icon: String?, line: String, version: String?, kind: Kind, mark: Mark, picture: String? = nil) {
            self.id = id; self.title = title; self.icon = icon; self.line = line; self.version = version; self.kind = kind; self.mark = mark
            self.picture = picture
        }
    }

    /// The list's filters (T25): every Raycast extension (installed, then Raycast's store), the installed ones, and
    /// Pilot's own extension.json extensions with Pilot's catalogue, set aside behind one chip until T23 deletes them.
    public enum Filter: String, CaseIterable, Sendable {
        case all, installed, old
        public var title: String { switch self { case .all: "All"; case .installed: "Installed"; case .old: "Pilot's own (old)" } }
    }

    /// What the list shows under a filter and a search, and the counts its filters and search wear, which neither moves.
    public struct Listing: Equatable, Sendable {
        /// The installed rows shown (Raycast ones, or Pilot's own under `old`), Pilot's catalogue's (only under `old`)
        /// and Raycast's store's not installed (only under `all`).
        public let installed: [Entry], catalogue: [Entry], store: [Entry]
        /// Installed Raycast extensions, and those plus the store's others (All's count).
        public let installedCount: Int, total: Int
        /// Pilot's own installed, Pilot's catalogue's others, and both (the old chip's count).
        public let ownCount: Int, catalogueCount: Int
        /// Pilot's own installed that its catalogue has newer, by id, whatever the search shows: Update all's.
        public let updatable: [String]
        public var updates: Int { updatable.count }
        public var oldTotal: Int { ownCount + catalogueCount }

        public func count(_ filter: Filter) -> Int {
            switch filter { case .all: total; case .installed: installedCount; case .old: oldTotal }
        }
    }

    /// Installed first, A to Z as the folder reads: Raycast's, or Pilot's own under `old`; then under `old` Pilot's
    /// catalogue's entries not installed as it sorts them (nil before it is read), under `all` `store`, Raycast's store's
    /// folders not installed, already narrowed by the search (RaycastStore.matches), of `storeCount` in all. `query`
    /// narrows the rest; the counts stay whole.
    public static func listing(_ rows: [Row], catalogue: [ExtensionCatalogue.Entry]?, filter: Filter = .all, query: String = "",
                               store: [Entry] = [], storeCount: Int = 0) -> Listing {
        let raycast = rows.filter(\.ext.isRaycast), own = rows.filter { !$0.ext.isRaycast }
        let installed = Dictionary(own.map { ($0.id, ExtensionCatalogue.Installed(id: $0.id, version: $0.version, folder: $0.ext.folder)) }) { a, _ in a }
        let offered = Dictionary((catalogue ?? []).map { ($0.id, $0) }) { a, _ in a }
        func entry(_ row: Row) -> Entry {
            let update = !row.ext.isRaycast && (offered[row.id].map { ExtensionCatalogue.standing(of: $0, installed: installed) == .update } ?? false)
            return Entry(id: row.id, title: row.ext.title, icon: row.ext.icon, line: row.ext.description, version: row.version,
                         kind: .installed, mark: update ? .update : .installed, picture: row.ext.picture)
        }
        let ids = Set(rows.map(\.id))
        let others = (catalogue ?? []).filter { !ids.contains($0.id) }
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = filter == .old ? own : raycast
        let shownRows = q.isEmpty ? shown.map(entry) : FuzzyRanker.Filter(q).filter(shown) { row in
            [row.ext.title, row.id, row.ext.description] + row.ext.examples + row.ext.listed.map(\.title)
        }.map(entry)
        let shownOthers = filter == .old ? ExtensionCatalogue.search(others, q).map {
            Entry(id: $0.id, title: $0.title, icon: $0.icon, line: $0.description, version: $0.version, kind: .catalogue, mark: .get)
        } : []
        let storeShown = filter == .all ? store.filter { !ids.contains($0.id) } : []
        return Listing(installed: shownRows, catalogue: shownOthers, store: storeShown,
                       installedCount: raycast.count, total: raycast.count + storeCount, ownCount: own.count, catalogueCount: others.count,
                       updatable: own.map(entry).filter { $0.mark == .update }.map(\.id))
    }

    public struct Field: Equatable, Sendable, Identifiable {
        public let preference: Extension.Preference
        public let value: JSONValue?
        public var id: String { preference.name }

        public init(preference: Extension.Preference, value: JSONValue?) { self.preference = preference; self.value = value }

        /// A required preference with no value: its command does not run.
        public var isMissing: Bool { preference.isMissing(value) }
    }

    /// One thing an extension says it touches, in plain words, with its kind so the page can draw its symbol.
    public struct Permission: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case network, clipboard, files, actions, nothing }
        public let kind: Kind, text: String
        public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
    }

    /// The line under every extension's permissions.
    public static let notEnforced = "Shown, not enforced: it runs as you."

    /// The page's rows: `found`'s extensions by title with their values from `values`, a Pilot action named by `label`
    /// when it has one.
    public static func rows(_ found: Extension.Found, values: (Extension) -> [String: JSONValue],
                            label: (String) -> String? = { _ in nil }) -> [Row] {
        found.extensions.map { ext in
            let values = values(ext)
            return Row(ext: ext, permissions: permissions(ext.permissions, label: label),
                       fields: ext.preferences.map { Field(preference: $0, value: values[$0.name]) })
        }
    }

    /// `permissions` in plain words, a line per kind it declares; "Touches nothing it names" when none. `label` is the
    /// registry's: an action it names no label for is not on this Mac. The actions an extension row is never let run
    /// (ExtensionList.allowsPilot against that registry: one Pilot lacks, Wi-Fi, power, a shell, …) get a line of their
    /// own, so the page never says it runs one (T52 review).
    public static func permissions(_ permissions: Extension.Permissions, label: (String) -> String? = { _ in nil }) -> [Permission] {
        var lines: [Permission] = []
        if !permissions.network.isEmpty { lines.append(Permission(.network, "Connects to \(spokenList(permissions.network))")) }
        if permissions.clipboard { lines.append(Permission(.clipboard, "Reads and writes the clipboard")) }
        if !permissions.files.isEmpty { lines.append(Permission(.files, "Reads and writes \(spokenList(permissions.files))")) }
        let (runs, refused) = permissions.actions.reduce(into: ([String](), [String]())) { split, id in
            if ExtensionList.allowsPilot(id, isRegistered: { label($0) != nil }) { split.0.append(id) } else { split.1.append(id) }
        }
        if !runs.isEmpty { lines.append(Permission(.actions, "Runs Pilot actions: \(spokenList(runs.map { label($0) ?? $0 }))")) }
        if !refused.isEmpty {
            lines.append(Permission(.actions, "Asks for Pilot actions it may not run: \(spokenList(refused.map { label($0) ?? $0 }))"))
        }
        return lines.isEmpty ? [Permission(.nothing, "Touches nothing it names")] : lines
    }
}
