import Foundation

/// One thing Remove lists (story 84): a Homebrew formula or cask, a web app Pilot stamped, an app Homebrew did not
/// install, by its path (card agent-bo-95422979), or a global npm package in the tree at `prefix` (card agent-bo-95422989).
public struct RemoveRow: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case package(Package), webApp(bundleID: String), app(path: String), npm(String, prefix: String) }

    public let source: Source, name: String
    /// A formula another installed formula depends on: brew refuses to remove it, so the row says so first.
    public let needed: Bool
    /// A cask's app, whose Spotlight last-used date sorts Least used; formulae have none.
    public var app: String?
    public var pilot = false, lastUsed: Date?
    /// An app from the App Store, by the receipt in its bundle (card agent-bo-95423022).
    public var appStore = false
    /// An app that is part of macOS (/System/Applications, or Safari's link there): listed so a search finds it, never
    /// removed; Return says why.
    public var system = false
    /// Its size on disk in bytes, once measured (InstallModule.measure); nil until then or when it cannot be read.
    public var size: Int64?

    public init(source: Source, name: String, needed: Bool = false, app: String? = nil) {
        self.source = source; self.name = name; self.needed = needed; self.app = app
    }

    /// `formula:hello`, `cask:zed`, `webapp:<bundle id>`, `app:<path>` or `npm:<prefix>:<name>`, as Update keys npm.
    public var key: String {
        switch source {
        case .package(let p): p.key
        case .webApp(let id): "webapp:\(id)"
        case .app(let path): "app:\(path)"
        case .npm(let name, let prefix): "npm:\(prefix):\(name)"
        }
    }

    /// The key Pilot's record of its installs uses: an npm tool's is `npm:<name>`, whichever tree has it.
    public var recordKey: String { if case .npm(let name, _) = source { "npm:\(name)" } else { key } }

    /// The category Remove lists it under (card agent-bo-95423022).
    public var category: RemoveList.Category {
        switch source {
        case .webApp: .webApps
        case .app: system ? .system : .apps
        case .npm: .tools
        case .package(let p):
            if p.kind.isTool { .tools } else if p.kind == .mas { .apps } else { app == nil ? .casks : .apps }
        }
    }

    /// Where it came from, as its row says: Homebrew, the App Store, uv, which npm tree, Pilot's web apps, or the app alone.
    public func origin(home: String) -> String {
        switch source {
        case .package(let p) where [.cask, .formula].contains(p.kind): "Homebrew \(p.kind.rawValue)"
        case .package(let p): p.kindLabel
        case .webApp: "web app"
        case .app(let path): system ? "part of macOS, can't be removed" : appStore ? "App Store" : Self.appOrigin(path, home: home)
        case .npm(_, let prefix): "npm in \(AppConfigs.tilde(prefix, home: home))"
        }
    }

    /// An app's own: "app" in an application folder, else where it sits ("app in ~/Downloads").
    private static func appOrigin(_ path: String, home: String) -> String {
        let folder = URL(filePath: path).deletingLastPathComponent().path
        return ["/Applications", home + "/Applications"].contains(folder) ? "app" : "app in \(AppConfigs.tilde(folder, home: home))"
    }

    /// What its size is measured on: its app, a formula's keg, a cask's Caskroom folder, a uv tool's environment or an
    /// npm package's folder; nil when Pilot does not know where it lives.
    public func sizePath(brewPrefix: String, home: String) -> String? {
        if system { return nil }
        if let app { return app }
        switch source {
        case .app(let path): return path
        case .webApp: return nil
        case .npm(let name, let prefix): return "\(prefix)/lib/node_modules/\(name)"
        case .package(let p):
            let token = p.name.split(separator: "/").last.map(String.init) ?? p.name
            switch p.kind {
            case .formula: return "\(brewPrefix)/Cellar/\(token)"
            case .cask: return "\(brewPrefix)/Caskroom/\(token)"
            case .uv: return "\(home)/.local/share/uv/tools/\(p.name)"
            case .npm: return "\(brewPrefix)/lib/node_modules/\(p.name)"
            case .pipx: return "\(home)/.local/share/pipx/venvs/\(p.name)"
            case .mas, .cargo, .go: return nil
            }
        }
    }
}

/// Remove's list (SPEC.md: Homebrew's casks and formulae, what Pilot installed first, then web apps; sorted by name, by
/// installed by Pilot and by least used).
public enum RemoveList {
    /// Remove's categories, browsed as Install's are (card agent-bo-95423022), in this order; one with no rows is not listed.
    public enum Category: String, CaseIterable, Sendable {
        case apps = "Apps", tools = "Command-line tools", casks = "Casks without an app", webApps = "Web apps", system = "Part of macOS"

        public var branch: MenuBranch { .category(rawValue, in: .remove) }
    }

    /// What a row of Remove is: a thing to remove, by RemoveRow.key.
    public enum Pick: Hashable, Sendable { case row(String) }

    public enum Order: CaseIterable, Sendable {
        case pilotFirst, leastUsed, name

        public var title: String {
            switch self { case .pilotFirst: "Pilot's installs first"; case .leastUsed: "Least used"; case .name: "Name" }
        }

        /// Tab's next order, round again after Name.
        public var next: Order { Self.allCases[((Self.allCases.firstIndex(of: self) ?? 0) + 1) % Self.allCases.count] }
    }

    /// `brew info --json=v2 --installed`: formulae, then casks.
    public static func parse(_ installed: Data) throws -> [RemoveRow] {
        let json = try JSONDecoder().decode(Installed.self, from: installed)
        // What installed formulae and casks depend on, by short or tapped name.
        let needed = Set(json.formulae.flatMap(\.dependencies) + json.casks.flatMap { $0.depends_on?.formula ?? [] })
        let formulae = json.formulae.compactMap { f in
            Package(.formula, f.full_name).map {
                RemoveRow(source: .package($0), name: f.full_name, needed: needed.contains(f.name) || needed.contains(f.full_name))
            }
        }
        let casks = json.casks.compactMap { c -> RemoveRow? in
            guard let package = Package(.cask, c.full_token) else { return nil }
            // Only an app artifact names the app; a binary's target is a command-line tool's path.
            let app = c.artifacts.lazy.compactMap { a in a.app?.first.map { a.target ?? "/Applications/\($0)" } }.first
            return RemoveRow(source: .package(package), name: c.name.first ?? c.full_token, app: app)
        }
        return formulae + casks
    }

    /// The apps at `paths` (top-level bundles of the application folders) that are not already rows: a cask's own app
    /// is skipped, a cask that names no app (a pkg, such as Karabiner-Elements) takes the app of its own name, and any
    /// other app becomes an app row. `skipping` holds paths listed elsewhere, such as web apps; `appStore` the apps that
    /// carry an App Store receipt; `system` marks every app added as part of macOS.
    public static func addApps(_ rows: inout [RemoveRow], paths: [String], skipping: Set<String>, appStore: Set<String> = [], system: Bool = false) {
        let caskApps = Set(rows.compactMap { $0.app.map { URL(filePath: $0).lastPathComponent } })
        for path in paths where !skipping.contains(path) {
            let file = URL(filePath: path).lastPathComponent
            guard file.hasSuffix(".app"), !caskApps.contains(file) else { continue }
            let name = String(file.dropLast(4))
            if let i = rows.firstIndex(where: { $0.category == .casks && $0.name == name }) { rows[i].app = path; continue }
            var row = RemoveRow(source: .app(path: path), name: name, app: path)
            row.appStore = appStore.contains(path)
            row.system = system
            rows.append(row)
        }
    }

    /// `npm ls -g --depth=0 --json --long` from one npm: each global package with its tree, from its `path`
    /// (`<prefix>/lib/node_modules/…`); npm and corepack themselves stay out.
    public static func parseNPM(_ json: Data) -> [RemoveRow] {
        struct Tree: Decodable { struct Dependency: Decodable { let path: String? }; let dependencies: [String: Dependency]? }
        guard let tree = try? JSONDecoder().decode(Tree.self, from: json) else { return [] }
        return (tree.dependencies ?? [:]).sorted { $0.key < $1.key }.compactMap { name, d -> RemoveRow? in
            guard !["npm", "corepack"].contains(name), Package.isName(name), let prefix = d.path.flatMap(UpdateList.npmPrefix) else { return nil }
            return RemoveRow(source: .npm(name, prefix: prefix), name: name)
        }
    }

    /// Marks Pilot's installs (package keys) and each app's last use (by app path), and adds the uv tools Pilot
    /// installed, which Homebrew does not list.
    public static func mark(_ rows: inout [RemoveRow], pilot: Set<String>, lastUsed: [String: Date]) {
        rows += pilot.sorted().compactMap(Package.init(key:)).filter { $0.kind == .uv }.map { RemoveRow(source: .package($0), name: $0.name) }
        for i in rows.indices {
            rows[i].pilot = pilot.contains(rows[i].recordKey)
            rows[i].lastUsed = rows[i].app.flatMap { lastUsed[$0] }
        }
    }

    /// Web apps always after Homebrew's packages; ties by name.
    public static func sorted(_ rows: [RemoveRow], _ order: Order) -> [RemoveRow] {
        func byName(_ a: RemoveRow, _ b: RemoveRow) -> Bool { a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        func isWeb(_ r: RemoveRow) -> Bool { if case .webApp = r.source { true } else { false } }
        return rows.sorted { a, b in
            if isWeb(a) != isWeb(b) { return isWeb(b) }
            switch order {
            case .name: break
            case .pilotFirst: if a.pilot != b.pilot { return a.pilot }
            case .leastUsed:
                switch (a.lastUsed, b.lastUsed) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            return byName(a, b)
        }
    }

    /// The rows Remove shows (card agent-bo-95423022, after Install's): a branch per category that has rows, with its
    /// count and their size, then each row in its category with where it came from, its size and what Pilot knows of it.
    /// A row with no app of its own on disk (a command-line cask, a formula) wears `icons`' by package key: the Install
    /// catalogue's shipped picture (Sven 2026-10-09).
    public static func entries(_ rows: [RemoveRow], icons: [String: MenuIcon] = [:], home: String = NSHomeDirectory()) -> [MenuEntry] {
        let categories = Category.allCases.compactMap { c -> MenuEntry? in
            let mine = rows.filter { $0.category == c }
            guard !mine.isEmpty else { return nil }
            let sizes = mine.compactMap(\.size)
            return MenuEntry(title: c.rawValue, target: .branch(c.branch), home: .remove,
                             detail: (["\(mine.count)"] + (sizes.isEmpty ? [] : [size(sizes.reduce(0, +))])).joined(separator: " · "),
                             icon: MenuIcon.removeCategory(c))
        }
        return categories + rows.map { r in
            let used = r.lastUsed.map { "last used \($0.formatted(.dateTime.day().month(.abbreviated).year()))" }
            let detail = [r.origin(home: home), r.size.map(size), r.pilot ? "installed by Pilot" : nil, r.needed ? "needed by other packages" : nil, used]
                .compactMap(\.self).joined(separator: " · ")
            return MenuEntry(title: r.name, target: .remove(.row(r.key)), home: r.category.branch, detail: detail, inSearch: false,
                             icon: r.app == nil ? icons[r.key] ?? MenuIcon.remove(r) : MenuIcon.remove(r))
        }
    }

    /// A size as Finder writes it: "412 MB".
    public static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private struct Installed: Decodable {
        struct Formula: Decodable { let name: String; let full_name: String; let dependencies: [String] }
        struct Cask: Decodable {
            struct Artifact: Decodable { let app: [String]?; let target: String? }
            struct DependsOn: Decodable { let formula: [String]? }
            let full_token: String; let name: [String]; let artifacts: [Artifact]; let depends_on: DependsOn?
        }
        let formulae: [Formula]
        let casks: [Cask]
    }
}
