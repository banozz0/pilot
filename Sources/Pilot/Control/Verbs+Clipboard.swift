import AppKit
import Clipboard
import PilotCore

/// What `pilot clip` reaches (CLI W11): the clipboard history the panel lists, through the store it reads. Sven's rule
/// (D2, 2026-10-11): a row's metadata reads freely; its text, its image and the text read from it only through
/// `clip show`, after Allow. Anything that puts an item where the caller can read it (copy, paste), opens it, deletes it
/// or searches its words asks too. Questions, answers and log lines name items by id, kind and app, never by content.
/// The tests hand in a throwaway history, a pasteboard of their own and fakes for the front app and Cmd+V.
@MainActor
final class ClipboardTools {
    lazy var history = ClipboardHistory.shared
    lazy var gate = AllowPrompt.gate
    /// Where copy and paste write: the Mac's pasteboard; a test's own named one.
    lazy var pasteboard = NSPasteboard.general
    /// Brings `--app` to the front before a paste, as `press` does.
    var front: @MainActor (String) async throws(ControlError) -> Void = ControlActions.bringToFront
    /// Cmd+V into the app in front, as the panel's Return sends it once the panel is gone.
    var post: @MainActor () -> Void = { Post.key(KeyCode.v, .cmd) }
    /// Paste one by one: the panel's own sequence, which the tap's Cmd+V reports drive.
    lazy var sequence: @MainActor ([StoredClip]) throws -> Void = { [unowned self] in try history.startSequence($0) }
    /// Open and Show in Finder, as the panel's Cmd+K list runs them.
    var opener: any ClipOpening = PilotOpener()
    /// Never record from takes installed apps only, as the page's app picker offers.
    var installed: @MainActor (String) -> Bool = { AppsModule.url(forBundle: $0) != nil }

    /// The history's store, or not-ready while it is not running, as the panel's tip says.
    func store() throws(ControlError) -> ClipboardStore {
        guard let store = history.store else { throw ControlError(.notReady, "Clipboard history is not running") }
        return store
    }

    /// A store call, its failure as bad-value.
    @discardableResult
    func attempt<T>(_ what: String, _ body: () throws -> T) throws(ControlError) -> T {
        do { return try body() } catch { throw ControlError(.badValue, "\(what): \(String(describing: error))") }
    }
}

extension ControlVerbs {
    /// `pilot clip …`, then the clipboard's two lists (Collections+Clipboard.swift).
    func registerClipboard(_ tools: ClipboardTools) {
        let words = ["list", "search", "show", "copy", "paste", "pin", "unpin", "delete", "clear", "tag", "untag", "tag-edit",
                     "rename", "edit", "split", "merge", "format", "open", "reveal"]
        let known: [String: [String]] = ["list": ["limit"], "search": ["limit"], "show": ["image"], "copy": ["plain"],
                                         "paste": ["app", "plain", "delete", "one-by-one"], "tag": ["tag"], "untag": ["tag"],
                                         "tag-edit": ["name", "colour"], "rename": ["title"], "edit": ["text"], "format": ["as"]]
        let formats = TextFormat.allCases.map(\.rawValue)
        let index = JSONValue.array(words.map(JSONValue.string))
        let detail: [String: String] = [
            "list": "pilot clip list [--limit N]: the history as the panel lists it, pins first, then by the Clipboard page's sort: kept (how many), reading (images whose text is not read yet) and the rows, 50 unless --limit. Rows carry metadata only.",
            "search": "pilot clip search <query…> [--limit N]: the panel's search. type:<kind>, app:<name or bundle id>, #<tag> and is:pinned filter freely; words search the items' text, so a query with words asks Allow first. Rows carry metadata only.",
            "show": "pilot clip show <id> [--image <path>]: one item whole after Allow: its text, its name, and an image's text read from it; --image saves an image as PNG at a new path (relative to where pilot runs).",
            "copy": "pilot clip copy <id…> [--plain]: puts the items on the pasteboard as one, as Cmd+C in the panel, after Allow (the pasteboard is readable). --plain: their text only.",
            "paste": "pilot clip paste <id…> --app <app> [--plain] [--delete] [--one-by-one]: brings the app to the front and pastes, after Allow. --delete takes them out of the history after; --one-by-one puts the first on and each Cmd+V the user presses gives the next.",
            "pin": "pilot clip pin|unpin <id…>: pins or unpins; pinned items stay past the history's limits and Clear history.",
            "delete": "pilot clip delete <id…>: takes items out of the history, after Allow.",
            "clear": "pilot clip clear: every unpinned item goes, after Allow; the pins stay.",
            "tag": "pilot clip tag|untag <id…> --tag <name>: tags the items (the tag is made when new) or takes the tag off; a tag goes with its last item.",
            "tag-edit": "pilot clip tag-edit <tag> [--name <new name>] [--colour 1-\(ClipTag.colours)]: renames or recolours a tag, as the Clipboard page's Tags do.",
            "rename": "pilot clip rename <id> --title <name>: the name the panel shows instead of the text; an empty one clears it.",
            "edit": "pilot clip edit <id> --text <text>: replaces a text item's text, as plain text, keeping its place, pin, tags and name.",
            "split": "pilot clip split <id>: one new item per non-empty line, on top; merge <id…> joins texts into one new item. Both answer the new rows.",
            "format": "pilot clip format <id…> --as <format>: \(formats.joined(separator: ", ")).",
            "open": "pilot clip open <id…>: opens a link or files as the panel's Open does, after Allow; reveal <id…> shows files in Finder.",
        ]
        let aliases = ["unpin": "pin", "untag": "tag", "merge": "split", "reveal": "open"]
        register(ControlVerb("clip", help: "The clipboard history: list and search (metadata), show one whole (asks Allow), copy, paste, pin, tag, rename, edit, format, delete and clear.",
                             usage: "pilot clip [list | search <query…> | show <id> | copy <id…> | paste <id…> --app <app> | pin <id…> | unpin <id…> | delete <id…> | clear | tag <id…> --tag <name> | untag <id…> --tag <name> | tag-edit <tag> | rename <id> --title <name> | edit <id> --text <text> | split <id> | merge <id…> | format <id…> --as <format> | open <id…> | reveal <id…>]",
                             flags: [.init("limit", help: "list and search: how many rows, 50 unless given"),
                                     .init("image", help: "show: save an image item as PNG at this new path"),
                                     .init("plain", help: "copy and paste: the text only", takesValue: false),
                                     .init("app", help: "paste: the app brought to the front and pasted into; required"),
                                     .init("delete", help: "paste: take the items out of the history after", takesValue: false),
                                     .init("one-by-one", help: "paste: each Cmd+V the user presses pastes the next", takesValue: false),
                                     .init("tag", help: "tag and untag: the tag's name"),
                                     .init("name", help: "tag-edit: the tag's new name"),
                                     .init("colour", help: "tag-edit: 1 to \(ClipTag.colours), as the page's colour menu numbers them"),
                                     .init("title", help: "rename: the item's name; empty clears it"),
                                     .init("text", help: "edit: the item's new text"),
                                     .init("as", help: "format: \(formats.joined(separator: ", "))")],
                             schema: {
                                 .object(["subcommands": index, "rowKey": .string("id"),
                                          "rows": .object(["id": .string("the item's id"), "kind": .string("text, richText, image, file, colour, link or email"),
                                                           "app": .string("the bundle id it was copied from, absent when unknown"),
                                                           "copied": .string("its last copy"), "firstCopied": .string("its first copy"),
                                                           "copies": .string("times copied"), "size": .string("bytes kept"), "pinned": .string("pinned"),
                                                           "tags": .string("its tags' names"), "readingText": .string("true: an image whose text is not read yet")]),
                                          "asks": .string("show, copy, paste, delete, clear, open, and search with words ask Allow"),
                                          "formats": .array(formats.map(JSONValue.string))])
                             },
                             index: { .object(["subcommands": index]) },
                             detail: { word in detail[aliases[word] ?? word] }) { call throws(ControlError) in
            let args = call.arguments()
            let word = args.positional.first ?? "list"
            guard words.contains(word) else { throw ControlError(.badValue, "no clip \(word); subcommands: \(words.joined(separator: ", "))") }
            if let refusal = ControlVerb.unknownFlag(args.flags, known: known[word] ?? [], in: "pilot clip \(word)") { throw refusal }
            let rest = Array(args.positional.dropFirst())
            switch word {
            case "list":
                guard rest.isEmpty else { throw ControlError(.badRequest, "pilot clip list takes no words; pilot clip search <query> searches") }
                return try await Self.list("", args, tools, peer: call.peer)
            case "search":
                guard !rest.isEmpty else { throw ControlError(.badRequest, "missing query") }
                return try await Self.list(rest.joined(separator: " "), args, tools, peer: call.peer)
            case "show": return try await Self.show(rest, args, cwd: call.cwd, tools, peer: call.peer)
            case "copy": return try await Self.copy(rest, plain: args.has("plain"), tools, peer: call.peer)
            case "paste": return try await Self.paste(rest, args, tools, peer: call.peer)
            case "pin", "unpin": return try Self.pin(rest, word == "pin", tools)
            case "delete": return try await Self.delete(rest, tools, peer: call.peer)
            case "clear": return try await Self.clear(tools, peer: call.peer)
            case "tag", "untag": return try Self.tag(rest, try args.required("tag"), on: word == "tag", tools)
            case "tag-edit": return try Self.editTag(rest, args, tools)
            case "rename": return try Self.rename(rest, try args.required("title"), tools)
            case "edit": return try Self.edit(rest, try args.required("text"), tools)
            case "split", "merge": return try Self.make(rest, word == "split" ? .split : .merge, tools)
            case "format":
                let name = try args.required("as")
                guard let format = TextFormat(rawValue: name) else { throw ControlError(.badValue, "--as: no format \(name); formats: \(formats.joined(separator: ", "))") }
                return try Self.format(rest, format, tools)
            default: return try await Self.open(rest, reveal: word == "reveal", tools, peer: call.peer)
            }
        })
        registerClipboardCollections(tools)
    }

    // MARK: Reading

    /// A row's metadata (D2): never its text, its name or the text read from it.
    static func clipRow(_ clip: StoredClip) -> [String: JSONValue] {
        var row: [String: JSONValue] = ["id": .number(Double(clip.id)), "kind": .string(clip.kind.rawValue),
                                        "copied": .string(clip.copiedAt.ISO8601Format()), "firstCopied": .string(clip.firstCopiedAt.ISO8601Format()),
                                        "copies": .number(Double(clip.copyCount)), "size": .number(Double(clip.size)), "pinned": .bool(clip.pinned),
                                        "tags": .array(clip.tags.map { .string($0.name) })]
        row["app"] = clip.sourceApp.map(JSONValue.string)
        row["expires"] = clip.expiresAt.map { .string($0.ISO8601Format()) }
        if clip.isReadingText { row["readingText"] = .bool(true) }
        return row
    }

    static func clipRows(_ clips: [StoredClip]) -> JSONValue { .array(clips.map { .object(clipRow($0)) }) }

    static func idArray(_ ids: [Int64]) -> JSONValue { .array(ids.map { .number(Double($0)) }) }

    /// Items named the way the Allow prompt shows them, and a denial answers: id, kind, app, when; never content.
    static func describe(_ clips: [StoredClip]) -> String {
        clips.map { clip in
            "#\(clip.id) \(clip.kind.label.lowercased())" + (clip.sourceApp.map { " from \(AppsModule.displayName($0))" } ?? "")
                + ", copied \(clip.copiedAt.formatted(date: .abbreviated, time: .shortened))"
        }.joined(separator: "; ")
    }

    /// The store and the items `words` name, in that order, each once; bad-value for a word that is no id or an id not in
    /// the history.
    static func picked(_ words: [String], _ tools: ClipboardTools, one: Bool = false) throws(ControlError) -> (ClipboardStore, [StoredClip]) {
        guard !words.isEmpty else { throw ControlError(.badRequest, "missing item id; pilot clip list lists them") }
        if one, words.count > 1 { throw ControlError(.badRequest, "one item id, not \(words.count)") }
        var ids: [Int64] = []
        for word in words {
            guard let id = Int64(word.hasPrefix("#") ? String(word.dropFirst()) : word) else { throw ControlError(.badValue, "\(word) is not an item id") }
            ids.append(id)
        }
        let store = try tools.store()
        let found = try tools.attempt("clipboard read") { try store.clips(ids) }
        guard found.count == Set(ids).count else {
            let known = Set(found.map(\.id))
            throw ControlError(.badValue, "no clipboard item \(ids.filter { !known.contains($0) }.map { "#\($0)" }.joined(separator: ", ")); pilot clip list lists them")
        }
        return (store, found)
    }

    /// The question asked about these items, read again from the store: one deleted or changed meanwhile denies.
    @MainActor static func ask(_ title: String, _ ids: [Int64], _ store: ClipboardStore, _ more: String = "") -> ControlGate.Ask {
        let clips = (try? store.clips(ids)) ?? []
        return ControlGate.Ask(title, (clips.count == ids.count ? describe(clips) : "items no longer in the history") + more)
    }

    /// The words a query searches the items' text by: ClipQuery's own, plus each `#name` no tag has, which it searches
    /// the text for.
    static func searchedWords(_ query: ClipQuery, _ typed: String, _ store: ClipboardStore) -> [String] {
        query.words + typed.split(whereSeparator: \.isWhitespace).map(String.init).filter { word in
            word.hasPrefix("#") && word.count > 1 && (try? store.tag(named: word)) == nil
        }
    }

    private static func list(_ typed: String, _ args: ControlArguments, _ tools: ClipboardTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let store = try tools.store()
        var limit = 50
        if let given = args.value("limit") {
            guard let n = Int(given), n > 0 else { throw ControlError(.outOfRange, "--limit takes a whole number above 0") }
            limit = n
        }
        let query = ClipQuery(typed, order: tools.history.settings.order)
        guard !query.snippets else { throw ControlError(.badValue, "snippets are a list of their own: pilot list snippets") }
        let words = searchedWords(query, typed, store)
        let ask = words.isEmpty ? nil : ControlGate.Ask("Search the clipboard history's text for", words.joined(separator: " "))
        return try await tools.gate.allow(ask, peer: peer) { () throws(ControlError) in
            let rows = PanelRows.ordered(try tools.attempt("clipboard search") { try store.search(query) })
            var answer: [String: JSONValue] = ["kept": .number(Double(try tools.attempt("clipboard read") { try store.counts().all })),
                                               "reading": .number(Double(try tools.attempt("clipboard read") { try store.unreadImageCount() })),
                                               "rows": clipRows(Array(rows.prefix(limit)))]
            if !typed.isEmpty { answer["matched"] = .number(Double(rows.count)) }
            return .object(answer)
        }
    }

    /// One item whole (D2's gated read): its text, its name, an image's text read from it, and with --image its picture
    /// saved as PNG at a new path.
    private static func show(_ words: [String], _ args: ControlArguments, cwd: String?, _ tools: ClipboardTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let (store, found) = try picked(words, tools, one: true)
        let clip = found[0]
        let file = args.value("image").map { URL(fileURLWithPath: $0, relativeTo: cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }).standardizedFileURL }
        if let file {
            guard clip.kind == .image else { throw ControlError(.badValue, "#\(clip.id) is not an image") }
            guard !FileManager.default.fileExists(atPath: file.path) else { throw ControlError(.badValue, "\(file.path) exists; give a new path") }
        }
        return try await tools.gate.allow(ask("Show clipboard item", [clip.id], store, file.map { "; save its image as \($0.path)" } ?? ""), peer: peer) { () throws(ControlError) in
            var answer = clipRow(clip)
            if !clip.text.isEmpty { answer["text"] = .string(clip.text) }
            answer["title"] = clip.customTitle.map(JSONValue.string)
            if clip.kind == .image { answer["recognised"] = clip.recognised.map(JSONValue.string) }
            if let file {
                // The store keeps a PNG where the copy had one; only a TIFF is converted.
                let data = try tools.attempt("clipboard image") { try store.image(of: clip.id) }
                guard let png = data.flatMap({ $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? $0 : NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) else {
                    throw ControlError(.badValue, "#\(clip.id) holds no picture")
                }
                do { try png.write(to: file, options: .withoutOverwriting) } catch {
                    throw ControlError(.badValue, "\(file.path) not saved: \(error.localizedDescription)")
                }
                answer["image"] = .string(file.path)
            }
            cliplog.notice("clip show #\(clip.id)\(file == nil ? "" : " with its image", privacy: .public), from the pilot command")
            return .object(answer)
        }
    }

    // MARK: Pasteboard

    private static func copy(_ words: [String], plain: Bool, _ tools: ClipboardTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let (store, clips) = try picked(words, tools), ids = clips.map(\.id)
        return try await tools.gate.allow(ask("Copy to the pasteboard", ids, store, plain ? "; as plain text" : ""), peer: peer) { () throws(ControlError) in
            try tools.attempt("clipboard copy") { try tools.history.write(clips, plain: plain, to: tools.pasteboard) }
            cliplog.notice("clip copy\(plain ? " plain" : "", privacy: .public) ids=\(ids), from the pilot command")
            return .object(["copied": idArray(ids), "plain": .bool(plain)])
        }
    }

    /// The panel's paste: the app brought to the front, the items written as one paste, then Cmd+V; or one by one.
    private static func paste(_ words: [String], _ args: ControlArguments, _ tools: ClipboardTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard let app = args.value("app") else { throw ControlError(.badRequest, "pilot clip paste needs --app, so the paste never lands in the wrong window") }
        let plain = args.has("plain"), delete = args.has("delete"), oneByOne = args.has("one-by-one")
        if oneByOne, plain || delete { throw ControlError(.badRequest, "--one-by-one pastes each as it was copied; leave out --plain and --delete") }
        let (store, clips) = try picked(words, tools), ids = clips.map(\.id)
        let sequence = oneByOne && ids.count > 1
        let how = [plain ? "as plain text" : nil, delete ? "then deleted from the history" : nil, sequence ? "one by one" : nil].compactMap { $0 }
        return try await tools.gate.allow(ask("Paste into \(app)", ids, store, how.isEmpty ? "" : "; " + how.joined(separator: ", ")), peer: peer) { () throws(ControlError) in
            try await tools.front(app)
            var steps: [PanelRows.Paste]?
            if sequence {
                try tools.attempt("clipboard sequence") { try tools.sequence(clips) }
            } else {
                steps = try tools.attempt("clipboard paste") {
                    try tools.history.write(clips, plain: plain, delete: delete, paste: true, to: tools.pasteboard)
                }
            }
            // The panel's own pause before Cmd+V; an image among several goes in steps, as the panel pastes them.
            try? await Task.sleep(for: .milliseconds(50))
            if let steps { PasteSteps(pasteboard: tools.pasteboard, post: tools.post).run(steps) } else { tools.post() }
            tools.history.changedFromControl()
            cliplog.notice("clip paste\(plain ? " plain" : "", privacy: .public)\(delete ? " and delete" : "", privacy: .public)\(sequence ? " one by one" : "", privacy: .public) ids=\(ids) into \(app, privacy: .public), from the pilot command")
            return .object(["pasted": idArray(ids), "app": .string(app), "plain": .bool(plain), "deleted": .bool(delete), "oneByOne": .bool(sequence)])
        }
    }

    // MARK: Editing

    /// After an edit: the panel shows it, and the rows answer as the store holds them now.
    private static func reread(_ ids: [Int64], _ store: ClipboardStore, _ tools: ClipboardTools) throws(ControlError) -> [StoredClip] {
        tools.history.changedFromControl()
        return try tools.attempt("clipboard read") { try store.clips(ids) }
    }

    private static func pin(_ words: [String], _ on: Bool, _ tools: ClipboardTools) throws(ControlError) -> JSONValue {
        let (store, clips) = try picked(words, tools), ids = clips.map(\.id)
        try tools.attempt("clipboard pin") { try store.setPinned(ids, on) }
        cliplog.notice("clip \(on ? "pin" : "unpin", privacy: .public) ids=\(ids), from the pilot command")
        return clipRows(try reread(ids, store, tools))
    }

    private static func delete(_ words: [String], _ tools: ClipboardTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let (store, clips) = try picked(words, tools), ids = clips.map(\.id)
        return try await tools.gate.allow(ask("Delete from the clipboard history", ids, store), peer: peer) { () throws(ControlError) in
            try tools.attempt("clipboard delete") { try store.delete(ids) }
            tools.history.changedFromControl()
            cliplog.notice("clip delete ids=\(ids), from the pilot command")
            return .object(["deleted": idArray(ids)])
        }
    }

    /// Clear history, as the page's button after its confirm: every unpinned item goes. Answers how many are kept: the pins.
    private static func clear(_ tools: ClipboardTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let store = try tools.store()
        @MainActor func ask() -> ControlGate.Ask? {
            let (all, pinned) = (try? store.counts()) ?? (0, 0)
            return all == pinned ? nil : ControlGate.Ask("Clear the clipboard history", "\(all - pinned) item\(all - pinned == 1 ? "" : "s") go; \(pinned) pinned stay")
        }
        return try await tools.gate.allow(ask(), peer: peer) { () throws(ControlError) in
            tools.history.clear()
            tools.history.changedFromControl()
            cliplog.notice("clip clear, from the pilot command")
            return .object(["kept": .number(Double(try tools.attempt("clipboard read") { try store.counts().all }))])
        }
    }

    static func clipTag(_ typed: String, _ store: ClipboardStore, _ tools: ClipboardTools) throws(ControlError) -> ClipTag {
        guard let tag = try tools.attempt("clipboard tags", { try store.tag(named: typed) }) else {
            throw ControlError(.badValue, "no tag \(typed); pilot list clipboard-tags lists them")
        }
        return tag
    }

    static func tagRow(_ tag: ClipTag) -> JSONValue { .object(["name": .string(tag.name), "colour": .number(Double(tag.colour + 1))]) }

    private static func tag(_ words: [String], _ name: String, on: Bool, _ tools: ClipboardTools) throws(ControlError) -> JSONValue {
        let (store, clips) = try picked(words, tools), ids = clips.map(\.id)
        if on {
            guard !ClipTag.name(name).isEmpty else { throw ControlError(.badValue, "--tag needs a name") }
            try tools.attempt("clipboard tag") { try store.tag(ids, with: name) }
        } else {
            let tag = try clipTag(name, store, tools)
            try tools.attempt("clipboard untag") { try store.untag(ids, from: tag.id) }
        }
        cliplog.notice("clip \(on ? "tag" : "untag", privacy: .public) ids=\(ids), from the pilot command")
        return clipRows(try reread(ids, store, tools))
    }

    /// The Clipboard page's Tags: a new name or colour, answered as stored (spaces as dashes).
    private static func editTag(_ words: [String], _ args: ControlArguments, _ tools: ClipboardTools) throws(ControlError) -> JSONValue {
        guard words.count == 1 else { throw ControlError(.badRequest, words.isEmpty ? "missing tag" : "one tag, not \(words.count)") }
        guard args.has("name") || args.has("colour") else { throw ControlError(.badRequest, "pilot clip tag-edit needs --name or --colour") }
        let store = try tools.store()
        var tag = try clipTag(words[0], store, tools)
        if args.has("name") {
            let name = ClipTag.name(try args.required("name"))
            guard !name.isEmpty else { throw ControlError(.badValue, "--name needs a name") }
            if let other = try tools.attempt("clipboard tags", { try store.tag(named: name) }), other.id != tag.id {
                throw ControlError(.taken, "a tag is named \(other.name) already")
            }
            tag.name = name
        }
        if args.has("colour") {
            let given = try args.required("colour")
            guard let n = Int(given), (1...ClipTag.colours).contains(n) else { throw ControlError(.outOfRange, "--colour takes 1 to \(ClipTag.colours)") }
            tag.colour = n - 1
        }
        try tools.attempt("clipboard tag") { try store.updateTag(tag) }
        tools.history.changedFromControl()
        return tagRow(try tools.attempt("clipboard tags") { try store.tag(named: tag.name) } ?? tag)
    }

    private static func rename(_ words: [String], _ title: String, _ tools: ClipboardTools) throws(ControlError) -> JSONValue {
        let (store, clips) = try picked(words, tools, one: true), id = clips[0].id
        try tools.attempt("clipboard rename") { try store.rename(id, to: title) }
        guard let clip = try reread([id], store, tools).first else { return .null }
        var row = clipRow(clip)
        row["title"] = clip.customTitle.map(JSONValue.string)
        return .object(row)
    }

    /// The panel's Cmd+K checks: an action runs only where its list offers it.
    private static func offered(_ action: ClipAction, _ clips: [StoredClip]) throws(ControlError) {
        guard ClipAction.available(for: clips).contains(action) else {
            throw ControlError(.badValue, "\(action.title) is not offered for \(describe(clips))")
        }
    }

    private static func edit(_ words: [String], _ text: String, _ tools: ClipboardTools) throws(ControlError) -> JSONValue {
        let (store, clips) = try picked(words, tools, one: true), id = clips[0].id
        try offered(.edit, clips)
        guard !text.isEmpty else { throw ControlError(.badValue, "--text needs text") }
        try tools.attempt("clipboard edit") { try store.setText(id, to: text) }
        cliplog.notice("clip edit #\(id), from the pilot command")
        return clipRows(try reread([id], store, tools))
    }

    private static func make(_ words: [String], _ action: ClipAction, _ tools: ClipboardTools) throws(ControlError) -> JSONValue {
        let (store, clips) = try picked(words, tools, one: action == .split)
        try offered(action, clips)
        let made = try tools.attempt("clipboard \(action.title)") { try ClipActions(store: store, opener: tools.opener).run(action, on: clips) }
        cliplog.notice("clip \(action == .split ? "split" : "merge", privacy: .public) ids=\(clips.map(\.id)) made=\(made), from the pilot command")
        return .object(["made": clipRows(try reread(made, store, tools))])
    }

    private static func format(_ words: [String], _ format: TextFormat, _ tools: ClipboardTools) throws(ControlError) -> JSONValue {
        let (store, clips) = try picked(words, tools), ids = clips.map(\.id)
        try offered(.format(format), clips)
        try tools.attempt("clipboard format") { try ClipActions(store: store, opener: tools.opener).run(.format(format), on: clips) }
        cliplog.notice("clip format \(format.rawValue, privacy: .public) ids=\(ids), from the pilot command")
        return clipRows(try reread(ids, store, tools))
    }

    /// Open asks (a link of any scheme, or files, opens outside Pilot); Show in Finder only shows.
    private static func open(_ words: [String], reveal: Bool, _ tools: ClipboardTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let (store, clips) = try picked(words, tools), ids = clips.map(\.id)
        let action: ClipAction = reveal ? .reveal : .open
        try offered(action, clips)
        return try await tools.gate.allow(reveal ? nil : ask("Open clipboard items", ids, store), peer: peer) { () throws(ControlError) in
            try tools.attempt("clipboard \(action.title)") { try ClipActions(store: store, opener: tools.opener).run(action, on: clips) }
            cliplog.notice("clip \(reveal ? "reveal" : "open", privacy: .public) ids=\(ids), from the pilot command")
            return .object([reveal ? "revealed" : "opened": idArray(ids)])
        }
    }
}
