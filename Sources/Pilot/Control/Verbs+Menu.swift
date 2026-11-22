import Foundation
import PilotCore

extension ControlVerbs {
    /// `menu search`: what the Hyper+Space menu lists for a query, in its order, without drawing it (spec launcher-best T3,
    /// Q324), so a launcher change is proved without a press on Sven's screen. Read-only; `menu pick` (T7) writes the ranking
    /// alone, after Allow, and runs no row (AGENTS.md: no acting verb). Built
    /// from the entries, picks, favourites, aliases and root PilotMenu's toggleNow hands MenuNavigator, plus the settings
    /// rows its search provides and the browsers' bookmarks and `hist` pages (T9); the rows that arrive after a keystroke from elsewhere (windows, files, app menu items,
    /// Install, emoji, answers, Translate, Define) are left out, and Search the web names no browser (webVia unread).
    /// `--selection-text` and `--selection-files` stand in for what the menu opened over (T11): the rows SelectionActions
    /// gives the panel, the real selection never read; `menu send` shows what Send to an app would run, and runs nothing.
    func registerMenu() {
        let flags: [ControlVerb.Flag] = [.init("size", help: "also the face size the panel would take for these rows (MenuPanelSize, Line)", takesValue: false),
                                         .init("selection-text", help: "the menu opened over this selected text: its actions lead the root"),
                                         .init("selection-files", help: "the menu opened over these files selected in Finder, comma-separated paths")]
        register(ControlVerb("menu", help: "What the Hyper+Space menu lists for a search, in its order, read without drawing it; pick records a pick "
                             + "of a listed row for that search, as Return does, without running it (learned abbreviations), after Allow; "
                             + "send shows what Send to an app would run for a selection, and runs nothing.",
                             usage: "pilot menu search <words> [--size] [--selection-text <text> | --selection-files <paths>] | pilot menu pick <words> <row> | "
                             + "pilot menu send <app> --selection-text <text> | --selection-files <paths>", flags: flags) { call throws(ControlError) in
            let args = call.arguments()
            guard let word = args.positional.first, ["search", "pick", "send"].contains(word) else {
                throw ControlError(.badValue, "pilot menu takes search, pick or send: pilot menu search <words>, pilot menu pick <words> <row>, pilot menu send <app> --selection-text <text>")
            }
            if word == "pick" { return try await Self.pick(Array(args.positional.dropFirst()), peer: call.peer) }
            let held = try Self.held(args)
            if word == "send" { return try await Self.send(args.positional.dropFirst().joined(separator: " "), held) }
            let query = args.positional.dropFirst().joined(separator: " ")
            let nav = try await Self.navigator(query, held: held)
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

    /// The selection `--selection-text` or `--selection-files` stands in for; nil without either.
    private static func held(_ args: ControlArguments) throws(ControlError) -> SelectionActions.Held? {
        if let text = args.value("selection-text") {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ControlError(.badValue, "--selection-text: some words") }
            return .text(text)
        }
        guard let paths = args.value("selection-files") else { return nil }
        let urls = paths.split(separator: ",").map { URL(filePath: String($0).trimmingCharacters(in: .whitespaces)) }
        guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ControlError(.badValue, "--selection-files: paths that exist, comma-separated")
        }
        return .files(urls)
    }

    /// `menu send <app>`: the command Send to an app would run for the selection given, and whether the app is one Send
    /// to lists for it; nothing is written or run.
    private static func send(_ word: String, _ held: SelectionActions.Held?) async throws(ControlError) -> JSONValue {
        guard let held else { throw ControlError(.badValue, "pilot menu send <app> --selection-text <text> | --selection-files <paths>") }
        guard !word.isEmpty, let app = SelectionActions.app(word) else { throw ControlError(.badValue, "no app \(word): a name, a bundle id or an .app path") }
        let listed = await Task.detached(priority: .userInitiated) { SelectionActions.receivers(held) }.value
        let plan = SelectionActions.plan(held, to: app, folder: SelectionActions.sendFolder())
        return .object(["app": .string(app.path), "listed": .bool(listed.contains { $0.standardizedFileURL == app.standardizedFileURL }),
                        "command": .array(plan.command.map(JSONValue.string)), "textFile": plan.textFile.map { .string($0.path) } ?? .null,
                        "ran": .bool(false)])
    }

    /// The navigator the menu would open with `query` typed at its root, over `held` when given.
    private static func navigator(_ query: String, held: SelectionActions.Held? = nil) async throws(ControlError) -> MenuNavigator {
        guard let engine = Engine.shared else { throw ControlError(.notReady, "the key engine is not up yet") }
        let scripts = ScriptCommand.find(), extensions = Extension.find().extensions
        await DockCalendar.shared.readCalls(now: .now) // As the menu's open reads it, the call to join (T5).
        let entries = PilotMenu.entries(engine, scripts: scripts, extensions: extensions)
        var nav = MenuNavigator(entries: entries, frecency: PilotMenu.shared.frecency ?? Frecency(), favourites: FavouriteBook.shared.rows,
                                aliases: AliasBook.shared.aliases, root: MenuRootSettings.shared.root)
        // As the menu's open and its `hist` search read them (T9): bookmarks while on (the read looks up the installed
        // browsers either way), history pages at `hist` (or the off row), and up to 3 in a plain search while on.
        let marks = await BrowserReader.shared.bookmarks(listed: Set(entries.map(\.target)))
        if BrowserSettings.shared.bookmarks { nav.provide(.bookmark, marks) }
        if let held {
            let commands = AICommandBook.shared.commands.map { (id: $0.id, title: $0.title) }
            nav.provide(.selection, SelectionActions.rows(held, buffer: [], commands: commands))
        }
        nav.query = query
        if let words = BrowserBookmarks.historyWords(query) {
            nav.provide(.history, await BrowserReader.shared.history(words, on: BrowserSettings.shared.history))
        } else if BrowserSettings.shared.history, let words = nav.searchHistoryWords {
            nav.provide(.history, BrowserBookmarks.searchPages(await BrowserReader.shared.history(words, on: true), words: words))
        }
        nav.provideSettings(query)
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
