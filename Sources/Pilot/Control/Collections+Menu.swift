import Foundation
import PilotCore

/// The objects the menu's collections edit: the ones the pages and the menu read, so an edit shows at once. Each is
/// reached on the first request, never at launch; a test sets its own before then.
@MainActor
final class MenuCollectionStores {
    lazy var aliases = AliasBook.shared
    lazy var quicklinks = QuicklinkBook.shared
    lazy var snippets = SnippetLibrary.shared
    lazy var favourites = FavouriteBook.shared
    lazy var reminders = ReminderScheduler.shared
    lazy var scriptsFolder = ScriptCommand.folder
    lazy var files = FileSearchSettings.shared
    lazy var menuRoot = MenuRootSettings.shared
    lazy var abilities = AbilitySettings.shared
    /// Whether an optional ability's app is on this Mac.
    lazy var has: (CatalogueEntry.Check) -> Bool = { [unowned self] in abilities.has($0) }
    lazy var engine: () -> Engine? = { Engine.shared }
    /// The menu, whose copy of the ranking a reset goes through.
    lazy var menu = PilotMenu.shared
}

extension ControlVerbs {
    /// The menu's lists as collections (AI helper T7, CLI W4): aliases, quicklinks, snippets, favourites, reminders, scripts,
    /// the never-index folders, the root's branches, the abilities and the ranking. Each row carries the word `remove` takes.
    func registerMenuCollections(_ s: MenuCollectionStores = MenuCollectionStores()) {
        register(ControlCollection("aliases", help: "Words typed at the Hyper+Space root that list one row first.",
                                   fields: [.init("alias", help: "lowercase letters and digits, e.g. cb"),
                                            .init("row", help: Self.rowHelp),
                                            .init("title", help: "the row's name on Launcher › Aliases; the key when left out", required: false)],
                                   rowKey: "alias", list: { .array(s.aliases.aliases.all.map { .object(Self.row($0)) }) },
                                   add: { args throws(ControlError) in
            let alias = args.value("alias")!, key = try Self.rowKey(args.value("row")!)
            if let refusal = s.aliases.set(alias, for: key, title: args.value("title") ?? key) {
                throw ControlError(.badValue, refusal == AliasBook.unreadable ? refusal : "--alias: \(refusal)")
            }
            return try Self.kept(s.aliases.aliases.all.first { $0.key == key }.map(Self.row), "alias", key)
        }, remove: { args throws(ControlError) in
            let alias = try Self.pick(s.aliases.aliases.all, args, "alias", known: \.alias) { word in { $0.alias == word || $0.key == word } }
            if let refusal = s.aliases.set("", for: alias.key, title: alias.title) { throw ControlError(.badValue, refusal) }
            return .object(Self.row(alias))
        }))

        register(ControlCollection("quicklinks", help: "Named URLs opened from Hyper+Space; {query} takes what is typed after the keyword.",
                                   fields: [.init("name", help: "the link's name"), .init("keyword", help: "lowercase letters and digits, e.g. gh"),
                                            .init("url", help: "https://…, {query} where the words go"), Self.idField("link", "its links.open:<id> action and binds")],
                                   rowKey: "keyword", list: { .array(s.quicklinks.links.map { .object(Self.row($0)) }) },
                                   add: { args throws(ControlError) in
            let id = try Self.editing(s.quicklinks.links, args, "quicklink", known: \.keyword)
            let link = Quicklink(id: id ?? UUID(), name: args.value("name")!, keyword: args.value("keyword")!, url: args.value("url")!)
            if let refusal = s.quicklinks.save(link) {
                throw ControlError(.badValue, refusal == .unreadable ? refusal.line : "--\(refusal.field): \(refusal.line)")
            }
            return try Self.kept(s.quicklinks.link(link.id).map(Self.row), "quicklink", link.name)
        }, remove: { args throws(ControlError) in
            let link = try Self.pick(s.quicklinks.links, args, "quicklink", known: \.keyword) { word in { $0.keyword == word || $0.id.matches(word) } }
            s.quicklinks.remove(link.id)
            return .object(Self.row(link))
        }))

        register(ControlCollection("snippets", help: "Saved text pasted by its keyword in any app or from Hyper+Space. Each row reads back its preview "
                                   + "(clipboard and argument as samples) and where its keyword expands: anywhere, word-start, menu-only, or never when a "
                                   + "snippet higher in the list has it (clashesWith).",
                                   fields: [.init("name", help: "the snippet's name"),
                                            .init("text", help: "what it pastes; {date}, {time}, {clipboard}, {argument}, {cursor} are filled in"),
                                            .init("keyword", help: "typed in any app to paste it, e.g. ;sig; none: Hyper+Space only", required: false),
                                            Self.idField("snippet", "its place in the list")],
                                   rowKey: "id", list: { Self.snippets(s.snippets) },
                                   add: { args throws(ControlError) in
            let id = try Self.editing(s.snippets.snippets, args, "snippet", known: \.name)
            let snippet = Snippet(id: id ?? UUID(), name: args.value("name")!, keyword: args.value("keyword") ?? "", text: args.value("text")!)
            // An edit keeps its place; a new one goes last. As the editor does, a clashing keyword is kept and warned
            // about: the snippet higher in the list expands.
            let editor = SnippetsEditor(library: s.snippets)
            if id == nil { s.snippets.snippets.append(snippet) } else { editor.edit(snippet.id) { $0 = snippet } }
            if let failed = s.snippets.failed { throw ControlError(.badValue, failed) }
            guard let kept = s.snippets.snippet(snippet.id) else { throw ControlError(.badValue, "the snippet \(snippet.name) was not kept; its file may not read") }
            var row = Self.row(kept, editor)
            if row["expands"] == .string("never"), case .string(let other) = row["clashesWith"] {
                row["warning"] = .string("\(other) has keyword \(snippet.keyword) too and expands instead")
            }
            return .object(row)
        }, remove: { args throws(ControlError) in
            // By id, or by name or keyword when one snippet alone has it.
            let snippet = try Self.pick(s.snippets.snippets, args, "snippet", known: \.name, id: \.id.uuidString) { word in
                { $0.name == word || $0.keyword == word || $0.id.matches(word) }
            }
            let row = Self.row(snippet, SnippetsEditor(library: s.snippets))
            s.snippets.snippets.removeAll { $0.id == snippet.id }
            if let failed = s.snippets.failed { throw ControlError(.badValue, failed) }
            return .object(row)
        }))

        register(ControlCollection("favourites", help: "Menu rows ranked first (Cmd+K › Add to favourites).",
                                   fields: [.init("row", help: Self.rowHelp)], rowKey: "row",
                                   list: { .array(s.favourites.rows.sorted().map { .object(["row": .string($0)]) }) },
                                   add: { args throws(ControlError) in
            let key = try Self.rowKey(args.value("row")!)
            if let refusal = s.favourites.set(key, true) { throw ControlError(.badValue, refusal) }
            return .object(["row": .string(key)])
        }, remove: { args throws(ControlError) in
            let key = try args.word(0, "row")
            guard s.favourites.rows.contains(key) else { throw Self.missing("favourite", key, s.favourites.rows.sorted()) }
            if let refusal = s.favourites.set(key, false) { throw ControlError(.badValue, refusal) }
            return .object(["row": .string(key)])
        }))

        register(ControlCollection("reminders", help: "Reminders shown as Pilot's tip when due, at most a day ahead.",
                                   fields: [.init("text", help: "what to show"), .init("in", help: "how long from now: 20m, 1h30m, 90s, 10 min")],
                                   rowKey: "id", list: { .array(s.reminders.list.upcoming.map { .object(Self.row($0)) }) },
                                   add: { args throws(ControlError) in
            let text = args.value("text")!.trimmingCharacters(in: .whitespacesAndNewlines), wait = args.value("in")!
            guard !text.isEmpty else { throw ControlError(.badValue, "--text: say what to show") }
            // The menu's own parser reads "<wait> <text>"; the text coming back whole means the wait was all wait.
            guard let parsed = Reminders.parse("\(wait) \(text)"), parsed.text == text else {
                throw ControlError(.badValue, "--in: \(wait) is not a wait like 20m, 1h30m or 90s, at most a day")
            }
            let before = Set(s.reminders.list.upcoming.map(\.id))
            s.reminders.add(text, in: parsed.seconds)
            return try Self.kept(s.reminders.list.upcoming.first { !before.contains($0.id) }.map(Self.row), "reminder", text)
        }, remove: { args throws(ControlError) in
            let upcoming = s.reminders.list.upcoming
            // By id, or by text when one reminder alone has it.
            let reminder = try Self.pick(upcoming, args, "reminder", known: \.id.uuidString) { word in
                { $0.id.matches(word) || ($0.text == word && upcoming.filter { $0.text == word }.count == 1) }
            }
            s.reminders.cancel(reminder.id)
            return .object(Self.row(reminder))
        }))

        register(ControlCollection("scripts", help: "Script commands in Pilot's Scripts folder, run as scripts.run:<file>; read-only here.",
                                   list: { .array(ScriptCommand.find(in: s.scriptsFolder).map { .object(Self.row($0)) }) }))

        register(ControlCollection("excluded-folders", help: "Folders the file index never walks, by name (node_modules) or in your home (~/Movies).",
                                   fields: [.init("folder", help: "a folder name, like node_modules, or one in your home, like ~/Movies")],
                                   rowKey: "folder", list: { .array(s.files.excluded.map { .object(["folder": .string($0)]) }) },
                                   add: { args throws(ControlError) in
            let typed = args.value("folder")!
            if let refusal = s.files.add(typed) { throw ControlError(.badValue, "--folder: \(refusal)") }
            return .object(["folder": .string(s.files.excluded.last ?? typed)])
        }, remove: { args throws(ControlError) in
            let entry = try Self.pick(s.files.excluded, args, "excluded folder", known: \.self) { word in
                { $0 == word || $0 == FileExclusions.entry(word, home: NSHomeDirectory()) }
            }
            s.files.remove(entry)
            return .object(["folder": .string(entry)])
        }))

        register(ControlCollection("menu-root", help: "The Hyper+Space root's branches in order, hidden ones too (shown false); remove hides one, "
                                   + "add shows or moves it, remove --reset puts back today's root.",
                                   fields: [.init("branch", help: "one of \(MenuBranch.top.map(\.rawValue).joined(separator: ", "))"),
                                            .init("at", help: "its place among the shown branches, 0 first; where it is when left out", required: false)],
                                   rowKey: "branch", list: { Self.branches(s.menuRoot.root) },
                                   add: { args throws(ControlError) in
            let branch = try Self.branch(args.value("branch")!)
            var root = s.menuRoot.root
            root.show(branch, true)
            if let at = args.value("at") {
                guard let index = Int(at), index >= 0 else { throw ControlError(.badValue, "--at: \(at) is not a place, 0 first") }
                // A place among the shown branches, as list numbers them; hidden ones keep theirs.
                let shown = root.shown().filter { $0 != branch }
                root.move(.branch(branch), before: shown.indices.contains(index) ? .branch(shown[index]) : nil)
            }
            if root != s.menuRoot.root { s.menuRoot.root = root }
            return .object(Self.row(branch, at: root.shown().firstIndex(of: branch)))
        }, remove: { args throws(ControlError) in
            if let refusal = ControlVerb.unknownFlag(args.flags, known: ["reset"], in: "pilot remove menu-root") { throw refusal }
            if args.flags.contains("reset") {
                s.menuRoot.reset()
                return Self.branches(s.menuRoot.root)
            }
            let branch = try Self.branch(try args.word(0, "branch"))
            guard s.menuRoot.root.isShown(branch) else { throw ControlError(.badValue, "\(branch.rawValue) is already hidden") }
            s.menuRoot.root.show(branch, false)
            return .object(Self.row(branch, at: nil))
        }))

        registerAbilities(s)

        register(ControlCollection("ranking", help: "Menu rows ranked by how often and how lately they were picked, best first; remove ranks one "
                                   + "as never picked (Cmd+K › Reset ranking).", rowKey: "row",
                                   list: { () throws(ControlError) in .array(try Self.picks(Self.readable(s.menu.frecency)).map { .object($0) }) },
                                   remove: { args throws(ControlError) in
            let key = try args.word(0, "row")
            guard try Self.readable(s.menu.frecency).picks[key] != nil else {
                throw ControlError(.badValue, "no ranked row \(key); pilot list ranking lists them")
            }
            let after: Frecency?
            do { after = try s.menu.resetRanking(key) } catch { throw ControlError(.badValue, "the ranking was not saved: \(error.localizedDescription)") }
            return .object(Self.picks(key, in: try Self.readable(after)))
        }))
    }

    /// Launcher › Abilities (story 155): every ability with what it does, and the optional ones More abilities adds or removes.
    private func registerAbilities(_ s: MenuCollectionStores) {
        register(ControlCollection("abilities", help: "Everything Pilot can do (Launcher › Abilities): each listed one with what it does and its key, "
                                   + "then the optional ones not listed yet (listed false), each driving one app on this Mac; add lists one, "
                                   + "remove takes back an added one that holds no key.",
                                   fields: [.init("id", help: "an optional ability's id, a row of list abilities with listed false")], rowKey: "id",
                                   list: { () throws(ControlError) in .array(try Self.abilities(s).map { .object($0) }) },
                                   add: { args throws(ControlError) in
            let id = args.value("id")!
            guard try Self.optional(id, s)["listed"] == .bool(false) else { throw ControlError(.badValue, "\(id) is listed already") }
            s.abilities.add(id)
            return try Self.ability(id, s)
        }, remove: { args throws(ControlError) in
            let id = try args.word(0, "ability")
            // As the page offers Remove: an added one that holds no key.
            if case .string(let key) = try Self.optional(id, s)["key"] {
                throw ControlError(.badValue, "\(id) holds \(key), so it stays listed; pilot unbind \(id) first")
            }
            guard s.abilities.added.contains(id) else { throw ControlError(.badValue, "\(id) is not added") }
            s.abilities.remove(id)
            return try Self.ability(id, s)
        }))
    }

    /// An optional ability's row as the page shows it, else why add or remove cannot take it.
    private static func optional(_ id: String, _ s: MenuCollectionStores) throws(ControlError) -> [String: JSONValue] {
        guard let row = try abilities(s).first(where: { $0["id"] == .string(id) }) else { throw unknownAbility(id, s) }
        guard Abilities.optional[id] != nil else { throw ControlError(.badValue, "\(id) ships with Pilot and is always listed") }
        return row
    }

    /// The rows Launcher › Abilities shows: the listed groups, typed first, then More abilities; an optional ability whose app
    /// is not on this Mac shows in neither, as on the page.
    private static func abilities(_ s: MenuCollectionStores) throws(ControlError) -> [[String: JSONValue]] {
        guard let engine = s.engine() else { throw ControlError(.notReady, "Pilot's key engine is not running") }
        let store = engine.binds.store, all = engine.allBindActions
        let listed = { (id: String) in Abilities.isListed(id, bound: store.trigger(for: id) != nil, added: s.abilities.added, has: s.has) }
        let groups = Abilities.groups(actions: all.filter { listed($0.id) }, store: store, menu: AppsModule.menuID)
        return groups.flatMap { group in group.abilities.map { row($0, group: group.title, listed: true) } }
            + Abilities.addable(actions: all, listed: listed, has: s.has).map { row($0, group: "More abilities", listed: false) }
    }

    /// One ability's row after an edit; one no longer shown (its app gone) reads back as not listed.
    private static func ability(_ id: String, _ s: MenuCollectionStores) throws(ControlError) -> JSONValue {
        .object(try abilities(s).first { $0["id"] == .string(id) } ?? ["id": .string(id), "listed": .bool(false)])
    }

    private static func unknownAbility(_ id: String, _ s: MenuCollectionStores) -> ControlError {
        guard let need = Abilities.optional[id], !s.has(need) else {
            return ControlError(.unknownAction, "no ability \(id); pilot list abilities lists them")
        }
        return ControlError(.badValue, "\(id) drives an app that is not on this Mac, so it is not offered")
    }

    private static func row(_ a: Abilities.Ability, group: String, listed: Bool) -> [String: JSONValue] {
        var row: [String: JSONValue] = ["id": .string(a.id), "name": .string(a.name), "what": .string(a.what), "group": .string(group),
                                        "listed": .bool(listed), "optional": .bool(Abilities.optional[a.id] != nil), "canTry": .bool(a.canTry)]
        row["key"] = a.key.map(JSONValue.string)
        row["action"] = a.action.map(JSONValue.string)
        row["typing"] = a.typing.map(JSONValue.string)
        return row
    }

    /// The root's branches, hidden ones too, in Sven's order; `at` counts the shown ones, as add's --at does.
    private static func branches(_ root: MenuRoot) -> JSONValue {
        let shown = root.shown()
        return .array(root.arranged().map { .object(row($0, at: shown.firstIndex(of: $0))) })
    }

    private static func readable(_ ranking: Frecency?) throws(ControlError) -> Frecency {
        guard let ranking else { throw ControlError(.badValue, "frecency.json does not read, so nothing ranks and it is left as it is") }
        return ranking
    }

    /// Every ranked row, best first.
    private static func picks(_ ranking: Frecency) -> [[String: JSONValue]] {
        let now = Date()
        return ranking.picks.keys.map { (key: $0, score: ranking.score($0, now: now)) }
            .sorted { ($1.score, $0.key) < ($0.score, $1.key) }.map { picks($0.key, in: ranking, now: now) }
    }

    private static func picks(_ key: String, in ranking: Frecency, now: Date = Date()) -> [String: JSONValue] {
        let times = ranking.picks[key] ?? []
        var row: [String: JSONValue] = ["row": .string(key), "picks": .number(Double(times.count)), "score": .number(Double(ranking.score(key, now: now)))]
        row["lastPicked"] = times.last.map { .string($0.ISO8601Format()) }
        return row
    }

    /// `add`'s --id: edits that row in place instead of adding one.
    private static func idField(_ kind: String, _ kept: String) -> ControlCollection.Field {
        .init("id", help: "an existing \(kind)'s id: edits it in place, keeping \(kept); a new \(kind) when left out", required: false)
    }

    /// The row `--id` names, which must be there already: an edit never makes up an id. Nil without --id.
    private static func editing<Row: Identifiable>(_ rows: [Row], _ args: ControlArguments, _ kind: String,
                                                   known: KeyPath<Row, String>) throws(ControlError) -> UUID? where Row.ID == UUID {
        guard let word = args.value("id") else { return nil }
        guard let row = rows.first(where: { $0.id.matches(word) }) else { throw missing(kind, word, rows.map { "\($0[keyPath: known]) (\($0.id.uuidString))" }) }
        return row.id
    }

    private static let rowHelp = "the menu row's key: action:<id>, app:<bundle id>, branch:<id>, …"

    /// A menu row's key (MenuEntry.Target.key): a kind of row that has one, a colon, then its id.
    private static func rowKey(_ key: String) throws(ControlError) -> String {
        let kinds = MenuEntry.Kind.allCases.filter { ![.window, .answer, .menuItem].contains($0) }.map(\.rawValue)
        guard let colon = key.firstIndex(of: ":"), kinds.contains(String(key[..<colon])), key.index(after: colon) < key.endIndex else {
            throw ControlError(.badValue, "--row: \(key) is not a menu row key; one starts with \(kinds.map { $0 + ":" }.joined(separator: ", "))")
        }
        return key
    }

    private static func branch(_ id: String) throws(ControlError) -> MenuBranch {
        guard let branch = MenuBranch.top.first(where: { $0.rawValue == id }) else {
            throw ControlError(.badValue, "--branch: no branch \(id); there are \(MenuBranch.top.map(\.rawValue).joined(separator: ", "))")
        }
        return branch
    }

    private static func row(_ a: Alias) -> [String: JSONValue] { ["alias": .string(a.alias), "row": .string(a.key), "title": .string(a.title)] }

    private static func row(_ l: Quicklink) -> [String: JSONValue] {
        ["id": .string(l.id.uuidString), "name": .string(l.name), "keyword": .string(l.keyword), "url": .string(l.url), "action": .string(l.actionID)]
    }

    private static func snippets(_ library: SnippetLibrary) -> JSONValue {
        let editor = SnippetsEditor(library: library)
        return .array(library.snippets.map { .object(row($0, editor)) })
    }

    /// Its preview as the editor shows it, never the real pasteboard, and where its keyword expands (the editor's note).
    private static func row(_ s: Snippet, _ editor: SnippetsEditor) -> [String: JSONValue] {
        var row: [String: JSONValue] = ["id": .string(s.id.uuidString), "name": .string(s.name), "keyword": .string(s.keyword), "text": .string(s.text),
                                        "preview": .string(s.expanded(now: Date(), clipboard: SnippetsEditor.sampleClipboard,
                                                                      argument: SnippetsEditor.sampleArgument).text)]
        let expands: String
        switch editor.note(for: s) {
        case .menuOnly: expands = "menu-only"
        case .anywhere: expands = "anywhere"
        case .wordStart: expands = "word-start"
        case .clash(let other, let wins):
            row["clashesWith"] = .string(other)
            // The note keeps no kind for a clash: the one higher in the list expands as the editor's rule for its first character says.
            let first = s.keyword.first!
            expands = !wins ? "never" : first.isLetter || first.isNumber ? "word-start" : "anywhere"
        }
        row["expands"] = .string(expands)
        return row
    }

    private static func row(_ r: Reminder) -> [String: JSONValue] {
        ["id": .string(r.id.uuidString), "text": .string(r.text), "due": .string(r.due.ISO8601Format())]
    }

    private static func row(_ c: ScriptCommand) -> [String: JSONValue] {
        ["file": .string(c.file), "title": .string(c.title), "action": .string(c.actionID), "mode": .string("\(c.mode)"),
         "arguments": .number(Double(c.arguments.count))]
    }

    /// A branch; `at` is its place among the shown ones, none once hidden.
    private static func row(_ b: MenuBranch, at index: Int?) -> [String: JSONValue] {
        var row: [String: JSONValue] = ["branch": .string(b.rawValue), "title": .string(b.title), "shown": .bool(index != nil)]
        row["at"] = index.map { .number(Double($0)) }
        return row
    }

    /// The row `remove`'s first word names, else bad-value listing the ones there are by `known`. A word two rows answer
    /// to is refused, naming each by `id` (else `known`), rather than taking the first.
    private static func pick<Row>(_ rows: [Row], _ args: ControlArguments, _ kind: String, known: KeyPath<Row, String>,
                                  id: KeyPath<Row, String>? = nil, _ matching: (String) -> (Row) -> Bool) throws(ControlError) -> Row {
        let word = try args.word(0, kind)
        let hits = rows.filter(matching(word))
        if hits.count > 1 {
            throw ControlError(.badValue, "\(hits.count) \(kind)s answer to \(word); remove one by its id: \(hits.map { $0[keyPath: id ?? known] }.joined(separator: ", "))")
        }
        guard let row = hits.first else { throw missing(kind, word, rows.map { $0[keyPath: known] }) }
        return row
    }

    private static func missing(_ kind: String, _ word: String, _ known: [String]) -> ControlError {
        ControlError(.badValue, "no \(kind) \(word); there are \(known.isEmpty ? "none" : known.joined(separator: ", "))")
    }

    /// The row a store reads back after an add; none means it kept nothing without saying why (an unreadable file).
    private static func kept(_ row: [String: JSONValue]?, _ kind: String, _ name: String) throws(ControlError) -> JSONValue {
        guard let row else { throw ControlError(.badValue, "the \(kind) \(name) was not kept; its file may not read") }
        return .object(row)
    }
}

private extension UUID {
    /// A typed id, case ignored.
    func matches(_ word: String) -> Bool { uuidString == word.uppercased() }
}
