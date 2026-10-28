import Foundation

/// The Hyper+Space menu's headings (design round 4, card agent-bo-95422895): a root search keeps its best match first and
/// gathers the rest by group (grouped), so each heading shows once, and a heading sits where the kind of row changes.
/// The root before typing is one list with no heading, and a search in System heads its sub-branches' rows (card
/// agent-bo-95422981, C6). The view draws the rows in the navigator's order, so the arrow keys and Return go where the
/// eye does.
public enum MenuGroups {
    public enum Group: Equatable, Sendable {
        case bestMatch, apps, windowsAndFiles, actions, menuItems, install, emoji, goTo
        /// Apps' own commands (P38); under the best match's app they head as "Music commands", a section.
        case commands
        /// A root search's offers: Ask AI, Search the web, Search files, and Search to install when nothing matched
        /// (MenuNavigator.fallbacks, Q182).
        case askOrSearch
        /// A branch's section, by title (MenuLayout.sections).
        case section(String)
    }

    /// A table, not a switch, so a kind added later heads with the actions until it has a row here.
    private static let groups: [MenuEntry.Kind: Group] = [
        .app: .apps, .window: .windowsAndFiles, .file: .windowsAndFiles, .action: .actions, .package: .install, .emoji: .emoji, .branch: .goTo,
        .answer: .bestMatch, .menuItem: .menuItems, .command: .commands,
    ]

    static func group(_ kind: MenuEntry.Kind) -> Group { groups[kind] ?? .actions }

    /// A row's group: every offer (Ask AI, Search the web, Search files, Search to install) heads as one, under Ask or
    /// search, whatever its kind (Q182); the rest by kind.
    static func group(of row: MenuEntry) -> Group {
        row.isOffer ? .askOrSearch : group(row.kind)
    }

    /// A root search's rows: the best match first, then the rest gathered by group, each group where its best row stood
    /// and the rank's order kept inside it.
    public static func grouped(_ rows: [MenuEntry]) -> [MenuEntry] {
        guard rows.count > 2 else { return rows }
        let rest = rows.dropFirst()
        var order: [Group] = []
        for row in rest where !order.contains(group(row.kind)) { order.append(group(row.kind)) }
        return [rows[0]] + order.flatMap { g in rest.filter { group($0.kind) == g } }
    }

    /// A live picker's rows gathered by their `section` (To-do B), each section where its first row stood and the order
    /// kept inside it, so a search Pilot ranks never heads one section twice; the rows as they are when none has one.
    public static func bySection(_ rows: [MenuEntry]) -> [MenuEntry] {
        guard rows.contains(where: { $0.section != nil }) else { return rows }
        var order: [String?] = [], gathered: [String?: [MenuEntry]] = [:]
        for row in rows {
            if gathered[row.section] == nil { order.append(row.section) }
            gathered[row.section, default: []].append(row)
        }
        return order.flatMap { gathered[$0] ?? [] }
    }

    /// A live picker's headings: each section's title over its first row; a row with none after a section heads nothing.
    public static func sections(_ rows: [MenuEntry]) -> [Int: Group] {
        var out: [Int: Group] = [:], last: String?
        for (i, row) in rows.enumerated() {
            if let section = row.section, section != last { out[i] = .section(section) }
            last = row.section
        }
        return out
    }

    /// Vicinae's root search (card agent-bo-95422968): the best-ranked app leads when it matches the query as well as
    /// every row ranked above it, so frecency never puts "Bitwarden: search vault" over Bitwarden itself, and the actions
    /// titled with its name ("Bitwarden: …") come next, in rank order. An answer keeps the lead, and so does a row whose
    /// title is a stronger match (FuzzyRanker.strength, P53).
    public static func appFirst(_ rows: [MenuEntry], query: String) -> [MenuEntry] {
        guard rows.first?.isAnswer != true, let i = rows.firstIndex(where: { $0.kind == .app }),
              let best = FuzzyRanker.score(query, in: rows[i].searchText) else { return rows }
        let strength = FuzzyRanker.strength(query, of: rows[i].title)
        guard rows[..<i].allSatisfy({ (FuzzyRanker.score(query, in: $0.searchText) ?? 0) <= best
                                      && FuzzyRanker.strength(query, of: $0.title) <= strength }) else { return rows }
        let app = rows[i], prefix = app.title.lowercased() + ": "
        // An app command Pilot's own action does (Music's Play or pause, P38) is the app's by `app`, not by its title.
        func owned(_ row: MenuEntry) -> Bool {
            row.kind.tab == .action && (row.title.lowercased().hasPrefix(prefix) || row.app.map(MenuEntry.Target.app) == app.target)
        }
        return [app] + rows.filter(owned) + rows.filter { $0.id != app.id && !owned($0) }
    }

    /// Each heading by the index of the row it sits over: the sections of `branch`, or a root search's groups
    /// (`searching`); none at the root before typing, in a picker or in a branch with no sections.
    public static func headings(_ rows: [MenuEntry], searching: Bool, branch: MenuBranch? = nil) -> [Int: Group] {
        var out: [Int: Group] = [:]
        var last: Group?
        func head(_ i: Int, _ group: Group) {
            if group != last { out[i] = group }
            last = group
        }
        if let branch {
            // System lists its sub-branches alone with no heading; a search there heads each one's rows with its name and
            // the sub-branch rows it found under Go to.
            let sections = MenuLayout.sections(branch)
            guard !sections.isEmpty else { return [:] }
            let found = rows.map { MenuLayout.section(of: $0, in: branch) }
            guard found.contains(where: { $0 != nil }) else { return [:] }
            // Install's search heads the catalogue's own packages as the catalogue (N9).
            let catalogue = MenuLayout.keepsOrder(branch)
            for (i, s) in found.enumerated() {
                head(i, s.map { .section(sections[$0].title) } ?? (catalogue && rows[i].kind == .package ? .section("Catalogue") : .goTo))
            }
            return out
        }
        guard searching else { return [:] }
        // The best match's own commands, which appFirst put under it, head with its name (P38, frame 2).
        let lead: String? = if case .app(let bundle)? = rows.first?.target { bundle } else { nil }
        for (i, row) in rows.enumerated() {
            let group = i == 0 && group(of: row) != .askOrSearch ? .bestMatch : group(of: row)
            head(i, group == .commands && lead != nil && row.app == lead ? .section("\(rows[0].title) commands") : group)
        }
        return out
    }

    /// A branch's ranked rows gathered by section: in the sections' order before typing, so System's sub-branches keep
    /// their order whatever was picked; while typing, each section where its best row stood, so the best match stays first.
    /// Install and Search packages keep their sources' order while typing too (N9): the catalogue's matches, then
    /// Homebrew to the web, then the branches.
    public static func sectioned(_ rows: [MenuEntry], in branch: MenuBranch, searching: Bool) -> [MenuEntry] {
        let count = MenuLayout.sections(branch).count
        guard count > 0 else { return rows }
        if searching, MenuLayout.keepsOrder(branch) {
            func place(_ row: MenuEntry) -> Int { MenuLayout.section(of: row, in: branch) ?? (row.kind == .package ? -1 : count) }
            return rows.enumerated().sorted { (place($0.element), $0.offset) < (place($1.element), $1.offset) }.map(\.element)
        }
        func opened(_ row: MenuEntry) -> Int? {
            guard !searching, case .branch(let sub) = row.target else { return nil }
            return MenuLayout.section(sub, in: branch)
        }
        let indexed = rows.map { (row: $0, section: MenuLayout.section(of: $0, in: branch) ?? opened($0) ?? count) }
        var order = searching ? [] : Array(0...count)
        for s in indexed.map(\.section) where !order.contains(s) { order.append(s) }
        return order.flatMap { s in indexed.filter { $0.section == s }.map(\.row) }
    }
}
