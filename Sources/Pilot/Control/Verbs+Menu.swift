import PilotCore

extension ControlVerbs {
    /// `menu search`: what the Hyper+Space menu lists for a query, in its order, without drawing it (spec launcher-best T3,
    /// Q324), so a launcher change is proved without a press on Sven's screen. Read-only: no acting verb (AGENTS.md). Built
    /// from the entries, picks, favourites, aliases and root PilotMenu's toggleNow hands MenuNavigator, plus the settings
    /// rows its search provides; the rows that arrive after a keystroke from elsewhere (windows, files, app menu items,
    /// Install, emoji, answers, Translate, Define) are left out, and Search the web names no browser (webVia unread).
    func registerMenu() {
        let flags: [ControlVerb.Flag] = [.init("size", help: "also the face size the panel would take for these rows (MenuPanelSize, Line)", takesValue: false)]
        register(ControlVerb("menu", help: "What the Hyper+Space menu lists for a search, in its order, read without drawing it.",
                             usage: "pilot menu search <words> [--size]", flags: flags) { call throws(ControlError) in
            let args = call.arguments()
            guard let word = args.positional.first, word == "search" else {
                throw ControlError(.badValue, "pilot menu takes search: pilot menu search <words>")
            }
            guard let engine = Engine.shared else { throw ControlError(.notReady, "the key engine is not up yet") }
            let scripts = ScriptCommand.find(), extensions = Extension.find().extensions
            let entries = PilotMenu.entries(engine, scripts: scripts, extensions: extensions)
            var nav = MenuNavigator(entries: entries, frecency: PilotMenu.shared.frecency ?? Frecency(), favourites: FavouriteBook.shared.rows,
                                    aliases: AliasBook.shared.aliases, root: MenuRootSettings.shared.root.listed)
            let query = args.positional.dropFirst().joined(separator: " ")
            nav.query = query
            nav.provideSettings(query, developer: DeveloperPages.on)
            let headings = MenuGroups.headings(nav.rows, searching: !query.isEmpty)
            let rows: [JSONValue] = nav.rows.enumerated().map { index, row in
                let favourite = row.frecencyKey.map(nav.favourites.contains) ?? false
                // As selectedActions lists them: Change languages only at the root.
                let actions = RowAction.list(for: row, favourite: favourite).filter { $0 != .changeLanguages || nav.branch == nil }
                return .object([
                    "kind": .string(row.kind.rawValue), "title": .string(row.shownTitle),
                    "frecencyKey": row.frecencyKey.map(JSONValue.string) ?? .null,
                    "key": row.detailIsKey ? row.detail.map(JSONValue.string) ?? .null : .null,
                    "detail": row.detailIsKey ? .null : row.detail.map(JSONValue.string) ?? .null,
                    "heading": headings[index].map { .string(Self.heading($0)) } ?? .null,
                    "offer": .bool(row.isOffer), "favourite": .bool(favourite),
                    "actions": .array(actions.map { .string($0.title) }),
                ])
            }
            var answer: [String: JSONValue] = ["query": .string(query), "rows": .array(rows)]
            if args.has("size") {
                let noMatch = !query.isEmpty && !nav.rows.isEmpty && nav.rows.allSatisfy(\.isOffer)
                let shape = MenuPanelSize.shape(branch: nav.branch, query: query, isList: nav.isList, only: nav.only)
                // The face as Line draws it, without an answer card's room or the window's shadow margins.
                let size = query.isEmpty ? MenuPanelSize.lineRoot(rows: nav.rows.count)
                    : MenuPanelSize.line(shape, rows: nav.rows.count, headings: headings.count, extra: noMatch ? MenuModel.noMatchRoom : 0)
                answer["size"] = .object(["width": .number(Double(size.width)), "height": .number(Double(size.height))])
            }
            return .object(answer)
        })
    }

    /// A heading's word as `menu search` prints it.
    private static func heading(_ group: MenuGroups.Group) -> String {
        if case .section(let title) = group { return title }
        return String(describing: group)
    }
}
