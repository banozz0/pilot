import Foundation

/// A list Pilot keeps (aliases, snippets, bar items, …), reached as `pilot list|add|remove <collection>`. Its adapter
/// reads and writes the live store the pages show; a list without `add` or `remove` is read-only.
public struct ControlCollection: Sendable {
    public typealias List = @Sendable @MainActor () async throws(ControlError) -> JSONValue
    public typealias Edit = @Sendable @MainActor (ControlArguments) async throws(ControlError) -> JSONValue
    /// An edit that is handed who asked as well, so one that asks the Allow gate can pass the asker on and the prompt
    /// names the program (ADR 0013). It does not ask the gate itself: the edit does.
    public typealias AskerEdit = @Sendable @MainActor (ControlArguments, ControlPeer?) async throws(ControlError) -> JSONValue

    /// A `--name value` that `add` takes.
    public struct Field: Sendable {
        public let name: String
        public let help: String
        public let required: Bool
        public init(_ name: String, help: String, required: Bool = true) { self.name = name; self.help = help; self.required = required }
    }

    /// An edit `pilot schema` can mark as waiting on the Allow gate.
    public enum Change: String, Sendable { case add, remove }

    public let name: String
    public let help: String
    /// Every flag `add` takes; any other is refused with unknown-flag.
    public let fields: [Field]
    /// The row field `remove`'s word names, e.g. keyword; nil when not declared.
    public let rowKey: String?
    /// The edits that wait on the Allow gate.
    public let asks: Set<Change>
    public let list: List
    /// Handed the words after the collection's name, every flag known and every required field already checked present.
    public let add: AskerEdit?
    /// Handed the words after the collection's name as they are: it may read flags of its own.
    public let remove: AskerEdit?

    public init(_ name: String, help: String, fields: [Field] = [], rowKey: String? = nil, list: @escaping List,
                add: Edit? = nil, remove: Edit? = nil) {
        func ignoringPeer(_ edit: @escaping Edit) -> AskerEdit { { args, _ throws(ControlError) in try await edit(args) } }
        self.init(name, help: help, fields: fields, rowKey: rowKey, asks: [], list: list,
                  askerAdd: add.map(ignoringPeer), askerRemove: remove.map(ignoringPeer))
    }

    /// `asks` defaults to the edits given here: an asker edit is the one that waits on the gate.
    public init(_ name: String, help: String, fields: [Field] = [], rowKey: String? = nil, asks: Set<Change>? = nil,
                list: @escaping List, askerAdd: AskerEdit?, askerRemove: AskerEdit?) {
        self.name = name; self.help = help; self.fields = fields; self.rowKey = rowKey; self.list = list; self.add = askerAdd; self.remove = askerRemove
        self.asks = asks ?? Set([askerAdd.map { _ in .add }, askerRemove.map { _ in .remove }].compactMap { $0 })
    }
}

extension ControlCollection {
    /// Its add or remove, or bad-value for a read-only list.
    fileprivate func edit(_ kind: KeyPath<ControlCollection, AskerEdit?>) throws(ControlError) -> AskerEdit {
        guard let edit = self[keyPath: kind] else { throw ControlError(.badValue, "\(name) is read-only") }
        return edit
    }
}

extension ControlVerbs {
    public func register(_ collection: ControlCollection) {
        precondition(collections[collection.name] == nil, "collection \(collection.name) registered twice")
        if collections.isEmpty { registerCollectionVerbs() }
        collections[collection.name] = collection
    }

    private func registerCollectionVerbs() {
        register(ControlVerb("list", help: "Lists a collection's rows, or every collection with none named.", usage: "pilot list [<collection>]",
                             flags: [], schema: { [unowned self] in collectionsSchema },
                             index: { [unowned self] in .object(["collections": .array(collections.keys.sorted().map(JSONValue.string))]) },
                             detail: { [unowned self] name throws(ControlError) in try collectionHelp("list", name) }) { [unowned self] call throws(ControlError) in
            guard !call.words.isEmpty else {
                return .array(sortedCollections.map { .object(["name": .string($0.name), "help": .string($0.help)]) })
            }
            return try await route(call).collection.list()
        })
        register(ControlVerb("add", help: "Adds a row to a collection; --plan collects it into pilot plan.", usage: "pilot add <collection> --field value … [--plan]",
                             detail: { [unowned self] name throws(ControlError) in try collectionHelp("add", name) },
                             plan: { [unowned self] call throws(ControlError) in
            let (collection, args) = try checkedAdd(call)
            guard !collection.asks.contains(.add) else { return nil }
            let fields = collection.fields.compactMap { f in args.value(f.name).map { "\(f.name) \($0)" } ?? (args.has(f.name) ? f.name : nil) }
            return .init("Add to \(collection.name)", old: "–", new: fields.joined(separator: ", "))
        }, inverse: { [unowned self] call throws(ControlError) in
            let (collection, args) = try checkedAdd(call)
            return try await undoAdd(collection, args)
        }) { [unowned self] call throws(ControlError) in
            let (collection, args) = try checkedAdd(call)
            return try await collection.edit(\.add)(args, call.peer)
        })
        register(ControlVerb("remove", help: "Removes a row from a collection; --plan collects it into pilot plan.", usage: "pilot remove <collection> <row> [--plan]",
                             detail: { [unowned self] name throws(ControlError) in try collectionHelp("remove", name) },
                             plan: { [unowned self] call throws(ControlError) in
            let (collection, args) = try route(call)
            _ = try collection.edit(\.remove)
            guard !collection.asks.contains(.remove) else { return nil }
            return .init("Remove from \(collection.name)", old: try args.word(0, collection.rowKey ?? "row"), new: "removed")
        }, inverse: { [unowned self] call throws(ControlError) in
            let (collection, args) = try route(call)
            return try await undoRemove(collection, try args.word(0, collection.rowKey ?? "row"))
        }) { [unowned self] call throws(ControlError) in
            let (collection, args) = try route(call)
            return try await collection.edit(\.remove)(args, call.peer)
        })
    }

    /// What takes an added row out again: remove by its row key, when the row is new. One the add changed in place has
    /// no way back: its old fields are not kept.
    private func undoAdd(_ c: ControlCollection, _ args: ControlArguments) async throws(ControlError) -> ControlPlan.Undo {
        guard c.remove != nil, !c.asks.contains(.remove), let key = c.rowKey, let value = args.value(key) else {
            return .cannot("\(c.name) has no remove by a \(c.rowKey ?? "row") the add names")
        }
        if try await row(c, key, value) != nil { return .cannot("it changed the \(value) row that was there; its old fields are not kept") }
        return .requests([ControlRequest(verb: "remove", args: [c.name, value])])
    }

    /// What adds a removed row again: add with the row's own fields, when the list shows each one add needs. An `id` is
    /// one add makes, never takes back (it edits the row with that id), so it is left out and the row comes back anew.
    private func undoRemove(_ c: ControlCollection, _ word: String) async throws(ControlError) -> ControlPlan.Undo {
        guard c.add != nil, !c.asks.contains(.add), let key = c.rowKey, let row = try await row(c, key, word) else {
            return .cannot("\(c.name) cannot add the row back")
        }
        var args = [c.name]
        for field in c.fields where field.name != "id" {
            if let value = row[field.name].flatMap(ControlPlan.word) { args += ["--\(field.name)", value] }
            else if field.required { return .cannot("the \(word) row does not show its \(field.name)") }
        }
        return .requests([ControlRequest(verb: "add", args: args)])
    }

    /// The row of `c` whose `key` reads `value`.
    private func row(_ c: ControlCollection, _ key: String, _ value: String) async throws(ControlError) -> [String: JSONValue]? {
        guard case .array(let rows) = try await c.list() else { return nil }
        return rows.lazy.compactMap { if case .object(let o) = $0 { o } else { nil } }.first { $0[key].flatMap(ControlPlan.word) == value }
    }

    /// The collection add names and its words, every flag known and every required field present.
    private func checkedAdd(_ call: ControlCall) throws(ControlError) -> (collection: ControlCollection, args: ControlArguments) {
        let (collection, args) = try route(call)
        _ = try collection.edit(\.add)
        if let refusal = ControlVerb.unknownFlag(args.flags, known: collection.fields.map(\.name), in: "pilot add \(collection.name)") {
            throw refusal
        }
        if let missing = collection.fields.first(where: { $0.required && args.value($0.name) == nil }) {
            throw ControlError(.badValue, "\(collection.name) needs --\(missing.name): \(missing.help)")
        }
        return (collection, args)
    }

    /// The collection the first word names, and the words after it.
    private func route(_ call: ControlCall) throws(ControlError) -> (collection: ControlCollection, args: ControlArguments) {
        guard let name = call.words.first, !name.hasPrefix("--") else { throw ControlError(.badRequest, "missing collection") }
        return (try collection(name), ControlArguments(Array(call.words.dropFirst())))
    }

    private var sortedCollections: [ControlCollection] { collections.values.sorted { $0.name < $1.name } }

    private var collectionsSchema: JSONValue { .object(["collections": .array(sortedCollections.map(Self.entry))]) }

    /// One collection's entry in `pilot schema`.
    public func schema(collection name: String) throws(ControlError) -> JSONValue { Self.entry(try collection(name)) }

    private static func entry(_ c: ControlCollection) -> JSONValue {
        var entry: [String: JSONValue] = [
            "name": .string(c.name), "help": .string(c.help), "add": .bool(c.add != nil), "remove": .bool(c.remove != nil),
            "fields": .array(c.fields.map { .object(["name": .string($0.name), "help": .string($0.help), "required": .bool($0.required)]) }),
            "asks": .array(c.asks.map(\.rawValue).sorted().map(JSONValue.string))]
        entry["rowKey"] = c.rowKey.map(JSONValue.string)
        return .object(entry)
    }

    private func collection(_ name: String) throws(ControlError) -> ControlCollection {
        guard let collection = collections[name] else {
            throw ControlError(.unknownCollection, "no collection \(name); there are \(collections.keys.sorted().joined(separator: ", "))")
        }
        return collection
    }

    /// `pilot help list|add|remove <collection>`: the usage with the collection's own fields, its help, and whether
    /// the edit asks Allow first.
    func collectionHelp(_ verb: String, _ name: String) throws(ControlError) -> String {
        let collection = try collection(name)
        let asks = collection.asks.contains { $0.rawValue == verb } ? ["Asks Allow first."] : []
        switch verb {
        case "add":
            _ = try collection.edit(\.add)
            let flags = collection.fields.map { $0.required ? "--\($0.name) <…>" : "[--\($0.name) <…>]" }
            let lines = ControlVerb.columns(collection.fields.map { ($0.name, $0.help + ($0.required ? "" : " (optional)")) }, prefix: "  --")
            return ([(["pilot add", name] + flags).joined(separator: " "), collection.help] + lines + asks).joined(separator: "\n")
        case "remove":
            _ = try collection.edit(\.remove)
            return (["pilot remove \(name) <\(collection.rowKey ?? "row")>", collection.help] + asks).joined(separator: "\n")
        default:
            return "pilot list \(name)\n\(collection.help)"
        }
    }
}
