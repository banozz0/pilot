import Foundation
import PilotCore

extension ControlVerbs {
    /// The Ring menu's rings (P74) as Launcher › Rings edits them: list each ring with its eight wedges, groups inside groups;
    /// add sets one wedge, at any depth (`--child` a dotted path inside the group at `--place`), making the ring when it is
    /// new; remove deletes a ring, or empties `ring:place` or `ring:place.a.b`, after Allow, as deleting one takes the key
    /// and the button holds that open it. The Pilot ring and groups filled from the menu are not edited. Every change is
    /// saved at once, as the page saves it.
    func registerRingCollection(_ app: ControlActions) {
        register(ControlCollection("rings", help: "The Ring menu's rings in scroll order, each wedge north first, clockwise (P74). add sets one wedge "
                                   + "(--child a dotted path inside the group at --place, as deep as groups go) and makes the ring if it is new; "
                                   + "remove deletes a ring, or empties <ring>:<place> or <ring>:<place>.<a>.<b>. The Pilot ring follows the "
                                   + "Hyper+Space menu and is not edited. A ring opens with rings.open:<ring>: pilot bind it to a key, "
                                   + "or to \"Mouse 4 Hold\" --plain.",
                                   fields: [.init("ring", help: "the ring's id, from this list; a new id makes a ring"),
                                            .init("name", help: "the ring's name, for a new ring or a rename", required: false),
                                            .init("app", help: "a bundle id: the ring opens first while that app is in front; none for every app", required: false),
                                            .init("place", help: "0 to 7, north first, clockwise", required: false),
                                            .init("child", help: "inside the group at --place: 0 to 7, or a dotted path through groups, 2.5", required: false),
                                            .init("action", help: "an action id, from pilot actions; none that asks for typing", required: false),
                                            .init("kind", help: "action, switch or group", required: false),
                                            .init("label", help: "its name on the ring; the action's own when left out", required: false)],
                                   rowKey: "ring", asks: [.remove],
                                   list: { () throws(ControlError) in
            let engine = try app.running()
            return .array(engine.rings.store.rings.rings.map { Self.ringRow($0, engine) })
        }, askerAdd: { args, _ throws(ControlError) in
            let engine = try app.running()
            let store = engine.rings.store
            let id = try args.required("ring")
            var ring = store.rings.ring(id: id) ?? Ring(id: id, name: args.value("name") ?? id.capitalized, slices: [])
            guard !ring.menu || (!args.has("name") && !args.has("app") && args.value("place") == nil) else {
                throw ControlError(.badValue, "\(id) follows the Hyper+Space menu: its name, app and wedges are not edited")
            }
            if let name = args.value("name") { ring.name = name }
            if args.has("app") { ring.app = args.value("app").flatMap { $0.isEmpty || $0 == "none" ? nil : $0 } }
            guard args.value("place") != nil || !args.has("child") else { throw ControlError(.badValue, "--child needs --place") }
            if let word = args.value("place") {
                let path = try [Self.place(word, "--place")] + (args.value("child").map { word throws(ControlError) in try Self.path(word, "--child") } ?? [])
                try Self.throughGroups(ring, path)
                ring[path: path] = try Self.slice(args, engine)
            }
            let saved = ring
            store.change { $0.put(saved) }
            return Self.ringRow(saved, engine)
        }, askerRemove: { args, peer throws(ControlError) in
            let engine = try app.running()
            let store = engine.rings.store
            let word = try args.word(0, "ring, ring:place or ring:place.child")
            let parts = word.split(separator: ":", maxSplits: 1).map(String.init)
            guard var ring = store.rings.ring(id: parts[0]) else { throw ControlError(.badValue, "no ring \(parts[0]); pilot list rings lists them") }
            guard !ring.menu else { throw ControlError(.badValue, "\(ring.id) follows the Hyper+Space menu and is not deleted or edited") }
            guard parts.count == 2 else {
                let opens = Self.opens(ring, engine)
                return try await app.gate.allow(.init("Delete ring \(ring.name)", opens.isEmpty ? "its wedges go with it"
                                                      : "its wedges and what opens it go with it: \(opens.joined(separator: ", "))"),
                                                peer: peer) { () throws(ControlError) in
                    engine.deleteRing(ring.id)
                    return .object(["deleted": .string(ring.id), "unbound": .array(opens.map(JSONValue.string))])
                }
            }
            let path = try Self.path(parts[1], "place")
            try Self.throughGroups(ring, path)
            ring[path: path] = nil
            let saved = ring
            return try await app.gate.allow(.init("Empty \(saved.name) \(parts[1])", "the wedge is emptied"), peer: peer) { () throws(ControlError) in
                store.change { $0.put(saved) }
                return Self.ringRow(saved, engine)
            }
        }))
    }

    /// What opens `ring`: its key and each mouse button's hold, by label.
    @MainActor private static func opens(_ ring: Ring, _ engine: Engine) -> [String] {
        let store = engine.binds.store
        return (store.trigger(for: ring.openID).map { [$0.label] } ?? [])
            + store.mouseBinds.filter { $0.bind.action == ring.openID }.map(\.trigger.label)
    }

    private static func place(_ word: String, _ name: String) throws(ControlError) -> Int {
        guard let n = Int(word), (0..<Ring.places).contains(n) else { throw ControlError(.badValue, "\(name): \(word) is not 0 to 7") }
        return n
    }

    /// `2` or `2.5.1`: places, each inside the group at the one before.
    private static func path(_ word: String, _ name: String) throws(ControlError) -> [Int] {
        var path: [Int] = []
        for part in word.split(separator: ".", omittingEmptySubsequences: false) { path.append(try place(String(part), name)) }
        return path
    }

    /// Every place on the way to the last of `path` holds a group written by hand.
    private static func throughGroups(_ ring: Ring, _ path: [Int]) throws(ControlError) {
        for end in path.indices.dropLast() {
            let at = Array(path.prefix(end + 1))
            guard let s = ring[path: at], s.isGroup, s.branch == nil else {
                throw ControlError(.badValue, "\(ring.id):\(at.map(String.init).joined(separator: ".")) is no group written by hand; add --kind group there first")
            }
        }
    }

    /// The wedge `add` names: nil to empty it (no --action, no group), a group, or an action no typing needs.
    @MainActor private static func slice(_ args: ControlArguments, _ engine: Engine) throws(ControlError) -> RingSlice? {
        let kind = try args.value("kind").map { word throws(ControlError) in
            guard let k = RingSlice.Kind(rawValue: word) else { throw ControlError(.badValue, "--kind: \(word) is not action, switch or group") }
            return k
        } ?? .action
        if kind == .group { return .group(args.value("label") ?? "Group", []) }
        guard let id = args.value("action") else { return nil }
        guard engine.action(id) != nil else { throw ControlError(.unknownAction, "no action \(id); pilot actions lists them") }
        guard !Rings.needsTyping(id) else { throw ControlError(.badValue, "\(id) asks for typing, which a ring cannot take") }
        return RingSlice(id, kind: kind, label: args.value("label"))
    }

    /// One ring as `pilot list rings` shows it: its wedges by place, a group's eight inside it, and what opens it.
    @MainActor private static func ringRow(_ ring: Ring, _ engine: Engine) -> JSONValue {
        func slice(_ s: RingSlice?, _ place: Int) -> JSONValue {
            guard let s else { return .null }
            var o: [String: JSONValue] = ["place": .number(Double(place)), "kind": .string(s.kind.rawValue)]
            o["action"] = s.action.map(JSONValue.string)
            o["label"] = .string(s.label ?? s.action.flatMap { engine.action($0)?.label } ?? s.action ?? "Group")
            o["branch"] = s.branch.map(JSONValue.string)
            if let inside = s.slices { o["slices"] = .array(inside.enumerated().map { slice($1, $0) }) }
            return .object(o)
        }
        let held = engine.binds.store.mouseBinds.filter { $0.bind.action == ring.openID }.map { JSONValue.string($0.trigger.label) }
        return .object(["ring": .string(ring.id), "name": .string(ring.name), "app": ring.app.map(JSONValue.string) ?? .null, "menu": .bool(ring.menu),
                        "opens": .string(ring.openID), "key": engine.binds.store.trigger(for: ring.openID).map { .string($0.label) } ?? .null,
                        "held": .array(held), "slices": .array(ring.slices.enumerated().map { slice($1, $0) })])
    }
}

extension SettingsSchema {
    /// Launcher › Rings' three settings (P74), through the rings' store as the page writes them.
    func registerRings(_ store: RingStore) {
        let standard = Rings.standard
        register([
            .int("rings.holdAfter", "Hold after, in ms: a mouse button bound to a ring opens it once held this long", page: "menu",
                 range: Rings.holdRange, standard: standard.holdAfter,
                 read: { store.rings.holdAfter }, write: { ms in store.change { $0.holdAfter = ms } }),
            .bool("rings.flickRuns", "Flick and let go runs it", page: "menu", standard: standard.flickRuns,
                  read: { store.rings.flickRuns }, write: { on in store.change { $0.flickRuns = on } }),
            .bool("rings.hideNames", "Hide names on the ring", page: "menu", standard: standard.hideNames,
                  read: { store.rings.hideNames }, write: { on in store.change { $0.hideNames = on } }),
        ])
    }
}
