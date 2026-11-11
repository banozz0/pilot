import Foundation
import PilotCore

extension ControlVerbs {
    /// The Binds page's lists (CLI W5): the bind presets, what holding Hyper shows (Binds › Overlay), and the macOS
    /// shortcuts a plain combo clashes with (Conflicts). `conflicts` reads and writes ShortcutConflicts; a test hands in
    /// one on a fake domain, so no test touches com.apple.symbolichotkeys.
    func registerBindCollections(_ app: ControlActions, conflicts: @escaping @Sendable @MainActor () -> ShortcutConflicts = { .shared }) {
        register(ControlCollection("presets", help: "Bind presets: each a default table plus the keys set in it. add makes one from scratch (or --copy of the active one, or --base pilot: Pilot default's keys alone) and switches to it; add --preset <id> --name renames one; remove deletes one, after Allow. pilot bind --preset switches.",
                                   fields: [.init("name", help: "the preset's name; a number is added when another has it"),
                                            .init("copy", help: "bare: start from the active preset's keys; left out: empty but the Pilot menu", required: false),
                                            .init("base", help: "start from this preset's default keys alone, none set by hand: pilot or empty", required: false),
                                            .init("preset", help: "an existing preset's id: rename it instead (not a built-in)", required: false)],
                                   rowKey: "id",
                                   asks: [.remove],
                                   list: { () throws(ControlError) in
            let store = try app.running().binds.store
            return .array(store.presets.map { Self.preset($0, store) })
        }, askerAdd: { args, _ throws(ControlError) in
            let binds = try app.running().binds
            let name = args.value("name")!
            if let id = args.value("preset") {
                let target = try Self.preset(id, in: binds.store)
                guard !target.isBuiltIn else { throw ControlError(.badValue, "\(target.title) is built in and keeps its name") }
                binds.renamePreset(target, to: name)
                return Self.preset(binds.store.preset(id: id) ?? target, binds.store)
            }
            if let word = args.value("base") {
                guard !args.has("copy") else { throw ControlError(.badRequest, "--base or --copy, not both") }
                let bases = binds.store.presets.filter(\.isBuiltIn).map(\.base.rawValue) + [BindStore.Base.empty.rawValue]
                guard let base = BindStore.Base(rawValue: word), binds.addPreset(named: name, base: base) else {
                    throw ControlError(.badValue, "no base \(word); bases: \(bases.joined(separator: ", "))")
                }
                return Self.preset(binds.store.preset, binds.store)
            }
            binds.addPreset(named: name, copying: args.has("copy") && args.value("copy") != "no")
            return Self.preset(binds.store.preset, binds.store)
        }, askerRemove: { args, peer throws(ControlError) in
            let binds = try app.running().binds
            let target = try Self.preset(args.word(0, "preset"), in: binds.store)
            guard !target.isBuiltIn else { throw ControlError(.badValue, "\(target.title) is built in and cannot be deleted") }
            // The page asks "Delete <name>?" first: its keys go with it.
            return try await app.gate.allow(.init("Delete bind preset \(target.title)", "its keys go with it"), peer: peer) { () throws(ControlError) in
                binds.deletePreset(target)
                guard binds.store.preset(id: target.id) == nil else { throw ControlError(.badValue, "\(target.title) was not deleted") }
                return .object(["deleted": .string(target.id), "active": .string(binds.store.preset.id)])
            }
        }))

        register(ControlCollection("overlay-picks", help: "Every Hyper bind the overlay can show, with whether it shows now (Binds › Overlay). add shows one and remove hides one, which turns the overlay to My own pick from what it shows; remove all starts an empty pick. pilot set overlayMode every shows all again.",
                                   fields: [.init("action", help: "a bind's action id, from this list")],
                                   rowKey: "action",
                                   list: { () throws(ControlError) in .array(try Self.overlayChoices(app.running()).map(Self.overlayRow)) },
                                   add: { args throws(ControlError) in try Self.showInOverlay(args.value("action")!, true, app.running()) },
                                   remove: { args throws(ControlError) in
            let engine = try app.running()
            let id = try args.word(0, "action")
            guard id != "all" else {
                engine.settings.pickOverlay([])
                return .object(["shown": .number(0), "mode": .string(engine.settings.overlayMode.rawValue)])
            }
            return try Self.showInOverlay(id, false, engine)
        }))

        register(ControlCollection("mouse", help: "Every mouse bind \(AppPlace(.mouse).path) shows (P58): its trigger (\"Mouse 4\" the plain press, \"Hyper+Mouse 4\" with Hyper held, \"Hyper+Mouse Scroll Up\"), the action it runs and the mouse a media key came from. remove frees one trigger, which does its own job again. pilot bind <action> \"Mouse 4\" sets one.",
                                   rowKey: "trigger",
                                   list: { () throws(ControlError) in
            let engine = try app.running()
            return .array(engine.binds.store.mouseBinds.map { Self.mouseRow($0.trigger, $0.bind, engine) })
        }, remove: { args throws(ControlError) in
            let engine = try app.running()
            let word = try args.word(0, "trigger")
            guard let held = engine.binds.store.mouseBinds.first(where: { $0.trigger.label.lowercased() == word.lowercased() }) else {
                throw ControlError(.badValue, "no mouse bind on \(word); pilot list mouse lists them")
            }
            engine.binds.setMouse(held.trigger, to: nil)
            return .object(["freed": .string(held.trigger.label), "action": .string(held.bind.action)])
        }))

        register(ControlCollection("key-swaps", help: "Binds › Swap keys (Q406): pairs of keys swapped while Pilot runs, each typing the other, with why one waits (a Hyper key in it, or another tool's mapping). add swaps two keys and remove frees a pair, each after Allow. Keys: \(SwapKey.allCases.map(\.rawValue).joined(separator: ", ")).",
                                   fields: [.init("keys", help: "two keys as first:second, e.g. capsLock:leftControl")],
                                   rowKey: "keys",
                                   asks: [.add, .remove],
                                   list: { () throws(ControlError) in
            let engine = try app.running()
            return .array(engine.settings.keySwaps.map { Self.swapRow($0, engine) })
        }, askerAdd: { args, peer throws(ControlError) in
            let engine = try app.running()
            let swap = try KeySwap.parsed(args.value("keys")!)
            let swaps = try KeySwap.adding(swap, to: engine.settings.keySwaps, layerKeys: engine.settings.layerKeys, foreign: engine.foreignMapping)
            return try await app.gate.allow(.init("Swap \(swap.label)", "each key types the other while Pilot runs"), peer: peer) { () throws(ControlError) in
                engine.settings.keySwaps = swaps
                return Self.swapRow(swap, engine)
            }
        }, askerRemove: { args, peer throws(ControlError) in
            let engine = try app.running()
            let word = try args.word(0, "keys")
            // Either order names the pair.
            guard let named = KeySwap(word: word), let swap = engine.settings.keySwaps.first(where: named.matches) else {
                throw ControlError(.badValue, "no swap \(word); pilot list key-swaps lists them")
            }
            return try await app.gate.allow(.init("Unswap \(swap.label)", "each key types itself again"), peer: peer) { () throws(ControlError) in
                engine.settings.keySwaps.removeAll { $0 == swap }
                return .object(["freed": .string(swap.word)])
            }
        }))

        registerRingCollection(app)

        register(ControlVerb("conflicts", help: "The macOS shortcuts a plain combo clashes with and the ones Pilot turned off; --off turns every clash off, --restore puts them all back, each after Allow. Edits macOS's private com.apple.symbolichotkeys.",
                             usage: "pilot conflicts [--off | --restore]",
                             flags: [.init("off", help: "turn off every macOS shortcut that clashes, backing each up first", takesValue: false),
                                     .init("restore", help: "put back every macOS shortcut Pilot turned off", takesValue: false)]) { call throws(ControlError) in
            let args = call.arguments()
            let binds = try app.running().binds, c = conflicts()
            if args.has("off") && args.has("restore") { throw ControlError(.badRequest, "--off or --restore, not both") }
            if args.has("off") {
                @MainActor func ask() -> ControlGate.Ask? {
                    let clashes = c.clashes(binds: binds.store.binds)
                    return clashes.isEmpty ? nil : .macShortcut("turn off " + Self.listed(clashes.map { "\($0.hotkey.name) (\($0.hotkey.key?.label ?? "?"))" }))
                }
                return try await app.gate.allow(ask(), peer: call.peer) { () throws(ControlError) in
                    do { try c.switchOff(binds: binds.store.binds) } catch { throw ControlError(.badValue, error.localizedDescription) }
                    return Self.conflicts(c, binds.store)
                }
            }
            if args.has("restore") {
                @MainActor func ask() -> ControlGate.Ask? {
                    c.hasBackup ? .macShortcut("put back " + Self.listed(c.turnedOff.map(SymbolicHotKeys.name))) : nil
                }
                return try await app.gate.allow(ask(), peer: call.peer) { () throws(ControlError) in
                    do { try c.restore() } catch { throw ControlError(.badValue, error.localizedDescription) }
                    return Self.conflicts(c, binds.store)
                }
            }
            return Self.conflicts(c, binds.store)
        })
    }

    static func preset(_ id: String, in store: BindStore) throws(ControlError) -> BindStore.Preset {
        guard let preset = store.preset(id: id) else {
            throw ControlError(.unknownPreset, "no preset \(id); presets: \(store.presets.map(\.id).joined(separator: ", "))")
        }
        return preset
    }

    private static func overlayChoices(_ engine: Engine) -> [OverlayPage.Choice] {
        OverlayPage.choices(store: engine.binds.store, actions: engine.bindActions, shown: engine.overlayShown()).flatMap { g in g.choices }
    }

    private static func overlayRow(_ c: OverlayPage.Choice) -> JSONValue {
        .object(["action": .string(c.id), "label": .string(c.label), "key": .string(c.key), "shown": .bool(c.shown)])
    }

    /// One mouse bind as `pilot list mouse` shows it: the drawn button a media key or sent key sits on, and its mouse.
    private static func mouseRow(_ trigger: Key, _ bind: BindStore.MouseBind, _ engine: Engine) -> JSONValue {
        .object(["trigger": .string(trigger.label), "action": .string(bind.action),
                 "label": .string(Self.label(bind.action, engine)),
                 "button": bind.button.map { .number(Double($0)) } ?? .null, "mouse": bind.device.map { .string($0.name) } ?? .null])
    }

    /// One swap as `pilot list key-swaps` shows it, with why it waits when it does.
    private static func swapRow(_ swap: KeySwap, _ engine: Engine) -> JSONValue {
        let problem = swap.problem(layerKeys: engine.settings.layerKeys, foreign: engine.foreignMapping)
        return .object(["keys": .string(swap.word), "label": .string(swap.label), "applied": .bool(Set(swap.entries).isSubset(of: engine.mappingWritten)),
                        "problem": problem.map(JSONValue.string) ?? .null])
    }

    /// Binds › Overlay's switch on one bind, answered with its row as the overlay now holds it.
    private static func showInOverlay(_ id: String, _ on: Bool, _ engine: Engine) throws(ControlError) -> JSONValue {
        guard overlayChoices(engine).contains(where: { $0.id == id }) else {
            throw ControlError(.unknownAction, "\(id) is not a Hyper bind the overlay shows; pilot list overlay-picks lists them")
        }
        engine.settings.showInOverlay(id, on, shown: engine.overlayShown())
        guard let row = overlayChoices(engine).first(where: { $0.id == id }) else { return .null }
        guard case .object(var o) = overlayRow(row) else { return .null }
        o["mode"] = .string(engine.settings.overlayMode.rawValue)
        return .object(o)
    }

    /// The Conflicts page as it reads now.
    private static func conflicts(_ c: ShortcutConflicts, _ store: BindStore) -> JSONValue {
        var answer: [String: JSONValue] = [
            "clashes": .array(c.clashes(binds: store.binds).map {
                .object(["id": .number(Double($0.hotkey.id)), "name": .string($0.hotkey.name),
                         "key": $0.hotkey.key.map { .string($0.label) } ?? .null, "action": .string($0.action)])
            }),
            "turnedOff": .array(c.turnedOff.map { .object(["id": .number(Double($0)), "name": .string(SymbolicHotKeys.name($0))]) }),
            "canPutBack": .bool(c.hasBackup)]
        answer["problem"] = c.problem.map(JSONValue.string)
        return .object(answer)
    }

    /// The first few names and how many more, so an Allow question stays short enough to show whole.
    private static func listed(_ names: [String]) -> String {
        let shown = names.prefix(6).joined(separator: ", ")
        return names.count > 6 ? "\(shown) and \(names.count - 6) more" : shown
    }
}
