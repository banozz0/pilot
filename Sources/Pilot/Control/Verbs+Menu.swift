import PilotCore

extension ControlVerbs {
    /// `menu search`: what the Hyper+Space menu lists for a query, in its order, without drawing it (spec launcher-best T3,
    /// Q324), so a launcher change is proved without a press on Sven's screen. Read-only; `menu pick` (T7) writes the ranking
    /// alone, after Allow, and runs no row (AGENTS.md: no acting verb). Built
    /// from the entries, picks, favourites, aliases and root PilotMenu's toggleNow hands MenuNavigator, plus the settings
    /// rows its search provides; the rows that arrive after a keystroke from elsewhere (windows, files, app menu items,
    /// Install, emoji, answers, Translate, Define) are left out, and Search the web names no browser (webVia unread).
    func registerMenu() {
        let flags: [ControlVerb.Flag] = [.init("size", help: "also the face size the panel would take for these rows (MenuPanelSize, Line)", takesValue: false)]
        register(ControlVerb("menu", help: "What the Hyper+Space menu lists for a search, in its order, read without drawing it; pick records a pick "
                             + "of a listed row for that search, as Return does, without running it (learned abbreviations), after Allow.",
                             usage: "pilot menu search <words> [--size] | pilot menu pick <words> <row>", flags: flags) { call throws(ControlError) in
            let args = call.arguments()
            guard let word = args.positional.first, word == "search" || word == "pick" else {
                throw ControlError(.badValue, "pilot menu takes search or pick: pilot menu search <words>, pilot menu pick <words> <row>")
            }
            if word == "pick" { return try await Self.pick(Array(args.positional.dropFirst()), peer: call.peer) }
            let query = args.positional.dropFirst().joined(separator: " ")
            let nav = try await Self.navigator(query)
            let headings = MenuGroups.headings(nav.rows, searching: !query.isEmpty)
            let rows: [JSONValue] = nav.rows.enumerated().map { index, row in
                let favourite = row.frecencyKey.map(nav.favourites.contains) ?? false
                // As selectedActions lists them: Change languages only at the root.
                let actions = RowAction.list(for: row, favourite: favourite).filter { $0 != .changeLanguages || nav.branch == nil }
                return .object([
                    "kind": .string(row.kind.rawValue), "title": .string(row.shownTitle),
                    "frecencyKey": row.frecencyKey.map(JSONValue.string) ?? .null, "target": row.target.key.map(JSONValue.string) ?? .null,
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

    /// The navigator the menu would open with `query` typed at its root.
    private static func navigator(_ query: String) async throws(ControlError) -> MenuNavigator {
        guard let engine = Engine.shared else { throw ControlError(.notReady, "the key engine is not up yet") }
        let scripts = ScriptCommand.find(), extensions = Extension.find().extensions
        await DockCalendar.shared.readCalls(now: .now) // As the menu's open reads it, the call to join (T5).
        let entries = PilotMenu.entries(engine, scripts: scripts, extensions: extensions)
        var nav = MenuNavigator(entries: entries, frecency: PilotMenu.shared.frecency ?? Frecency(), favourites: FavouriteBook.shared.rows,
                                aliases: AliasBook.shared.aliases, root: MenuRootSettings.shared.root.listed)
        nav.query = query
        nav.provideSettings(query, developer: DeveloperPages.on)
        return nav
    }

    /// `menu pick <words> <row>` (spec launcher-best T7): a pick of a row `menu search <words>` lists, by its frecency key,
    /// recorded as Return records it, so the words are learned for it; the row is never run. Asks Allow: it writes the
    /// menu's ranking.
    private static func pick(_ words: [String], peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard words.count >= 2, let key = words.last else { throw ControlError(.badValue, "pilot menu pick <words> <row>: a row's frecencyKey from pilot menu search") }
        let query = words.dropLast().joined(separator: " ")
        let nav = try await navigator(query)
        guard let row = nav.rows.first(where: { $0.frecencyKey == key }) else {
            throw ControlError(.badValue, "\(key) is not listed for \"\(query)\"; pilot menu search \(query) lists its rows")
        }
        return try await AllowPrompt.gate.allow(ControlGate.Ask("Record a menu pick", "\(row.shownTitle) for \"\(query)\""), peer: peer) { () throws(ControlError) in
            let saved: Frecency?
            do { saved = try PilotMenu.shared.recordPick(key, query: query) } catch {
                throw ControlError(.badValue, "the ranking was not saved: \(error.localizedDescription)")
            }
            guard let saved else { throw ControlError(.badValue, "frecency.json does not read, so nothing was saved over it") }
            let folded = Frecency.Typed.folded(query)
            return .object([
                "row": .string(key), "query": .string(query), "picks": .number(Double(saved.picks[key]?.count ?? 0)),
                "fromQuery": .number(Double(saved.typed[key]?.count { $0.query == folded } ?? 0)),
                "learned": saved.learned(query).map(JSONValue.string) ?? .null,
            ])
        }
    }

    /// A heading's word as `menu search` prints it.
    private static func heading(_ group: MenuGroups.Group) -> String {
        if case .section(let title) = group { return title }
        return String(describing: group)
    }
}
