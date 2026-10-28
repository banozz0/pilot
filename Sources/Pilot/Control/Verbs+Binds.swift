import Foundation
import PilotCore

extension ControlVerbs {
    /// `bind`, `unbind`, `import` and `export`: the Binds page's changes on the store pilot://bind and Export and import
    /// change, answered with the bind as stored or the reason it was refused. What the page confirms asks Allow first.
    func registerBinds(_ app: ControlActions) {
        register(ControlVerb("bind", help: "Binds an action to a key under Hyper (--plain: a plain combo); --replace takes a taken key; --on turns on a switched-off bind; --reset puts its default back; --preset switches the preset. A mouse button binds as \"Mouse 4\" (Hyper + it; --plain: the plain press), the wheel as \"Mouse Scroll Up\" or \"Mouse Scroll Down\", under Hyper only; pilot export lists them under mouse. pilot help bind routes names the web page, menu, keystroke and shell ids.",
                             usage: "pilot bind <action> <key> [--mods shift,ctrl,alt,cmd] [--plain] [--replace] | pilot bind <action> --on | pilot bind <action|all> --reset | pilot bind --preset <preset>",
                             flags: [.init("mods", help: "shift, ctrl, alt, cmd, or one side: leftAlt, rightCmd, …"),
                                     .init("plain", help: "a plain combo, outside Hyper, which needs cmd, ctrl or alt; for a mouse button, its plain press", takesValue: false),
                                     .init("replace", help: "take the key from the action holding it, which is left with none", takesValue: false),
                                     .init("on", help: "turn on a bind an import switched off; asks Allow as running it does", takesValue: false),
                                     .init("reset", help: "put the default key back; all: every bind, after Allow", takesValue: false),
                                     .init("preset", help: "switch to this preset, after Allow; pilot list presets names them")],
                             schema: { .object(["presets": .array((Engine.shared?.binds.store.presets ?? []).map { .string($0.id) }),
                                                "routes": .array(Self.routes.map { .object(["id": .string($0.form), "does": .string($0.does)]) })]) },
                             detail: { word throws(ControlError) in
            word == "routes" ? (["Ids the editor's Does binds besides pilot actions' rows. Every drive. id but drive.menu: asks Allow, as does a link that is not http or https."]
                                + ControlVerb.columns(Self.routes.map { ($0.form, $0.does) }, prefix: "  ")).joined(separator: "\n") : nil
        }, plan: { [unowned self] call throws(ControlError) in try planBind(call, app) },
           inverse: { call throws(ControlError) in try Self.undoBind(call, app) }) { call throws(ControlError) in
            let args = call.arguments()
            let engine = try app.running()
            let binds = engine.binds
            if let name = args.value("preset") {
                let preset = try Self.preset(name, in: binds.store)
                // The page asks "Switch layouts?" first: every default key changes.
                return try await app.gate.allow(Self.switching(to: preset, binds.store), peer: call.peer) { () throws(ControlError) in
                    binds.use(preset)
                    return .object(["preset": .string(binds.store.preset.id), "binds": .number(Double(binds.store.binds.count))])
                }
            }
            let id = try args.word(0, "action")
            if args.has("reset"), id == "all" {
                return try await app.gate.allow(Self.resettingAll(binds.store), peer: call.peer) { () throws(ControlError) in
                    binds.resetAll()
                    return .object(["reset": .string("all"), "binds": .number(Double(binds.store.binds.count))])
                }
            }
            try Self.known(id, engine)
            if args.has("reset") {
                do throws(BindStore.BindError) { try binds.reset(id) } catch { throw Self.taken(error) }
                return Self.bound(id, binds.store)
            }
            if args.has("on") {
                // Turning on an imported shell or URL bind is allowing it, so it asks what a run of it asks.
                return try await app.gate.allow(app.ask(id), peer: call.peer) { () throws(ControlError) in
                    binds.enable(id)
                    return Self.bound(id, binds.store)
                }
            }
            if let mouse = try Self.mouseKey(args) {
                return try await app.gate.allow(app.ask(id), peer: call.peer) { () throws(ControlError) in
                    // A taken mouse trigger is refused as a taken key is; --replace takes it, its action left without it.
                    let other = try Self.mouseClash(mouse, for: id, binds.store, replace: args.has("replace"))
                    binds.setMouse(mouse, to: id)
                    return .object(["action": .string(id), "key": .string(mouse.label), "mouse": .bool(true),
                                    "left": other.map(JSONValue.string) ?? .null])
                }
            }
            let key = try Self.key(args, at: 1, plain: args.has("plain"))
            // A bind of a command, a keystroke or a URL to any scheme asks before it is written (ADR 0013).
            return try await app.gate.allow(app.ask(id), peer: call.peer) { () throws(ControlError) in
                guard args.has("replace") else {
                    do throws(BindStore.BindError) { try binds.set(id, to: key) } catch { throw Self.taken(error) }
                    return Self.bound(id, binds.store)
                }
                let other = binds.store.clash(key, for: id)
                binds.replace(id, with: key)
                guard case .object(var row) = Self.bound(id, binds.store) else { return .null }
                row["left"] = other.map(JSONValue.string) ?? .null
                return .object(row)
            }
        })
        register(ControlVerb("unbind", help: "Leaves an action with no key.", usage: "pilot unbind <action>", flags: [],
                             plan: { call throws(ControlError) in
            let id = try call.arguments().word(0, "action")
            let engine = try app.running()
            try Self.known(id, engine)
            return .init("Unbind \(Self.label(id, engine))", old: engine.binds.store.trigger(for: id)?.label ?? "none", new: "none")
        }, inverse: { call throws(ControlError) in
            .requests([Self.restoring(try call.arguments().word(0, "action"), try app.running().binds.store)])
        }) { call throws(ControlError) in
            let id = try call.arguments().word(0, "action")
            let engine = try app.running()
            try Self.known(id, engine)
            engine.clearKey(id)
            return Self.bound(id, engine.binds.store)
        })
        register(ControlVerb("import", help: "Previews a bind file or a pilot://import link; --apply applies it, --preset adds it as a new preset, each after Allow. A file is read from ~/Downloads or a temp folder only.",
                             usage: "pilot import <file|pilot://import?pack=…> [--apply | --preset [<name>]]",
                             flags: [.init("apply", help: "apply it to the active preset, after Allow", takesValue: false),
                                     .init("preset", help: "add the file's preset as a new one and switch to it, after Allow; a name for a file before presets")]) { call throws(ControlError) in
            let args = call.arguments()
            let (name, data) = try Self.bindFile(args.word(0, "file"), cwd: call.cwd)
            let binds = try app.running().binds
            let plan: BindStore.Import
            do { plan = try binds.store.plan(importing: data) } catch { throw ControlError(.badValue, "\(name) not read: it is not a bind file") }
            // Planned again after the Allow: binds changed while it was up change the question, which denies.
            @MainActor func planned() -> BindStore.Import? { try? binds.store.plan(importing: data) }
            if args.has("preset") {
                let presetName = args.value("preset") ?? (name as NSString).deletingPathExtension
                return try await app.gate.allow(.init("Add import as a preset", planned()?.summary(name: name) ?? "\(name), no longer readable"), peer: call.peer) { () throws(ControlError) in
                    do throws(BindStore.LoadError) { try binds.importPreset(data, name: presetName) } catch {
                        throw ControlError(.badValue, "\(name) not added as a preset: it is not a bind file")
                    }
                    return .object(["applied": .bool(true), "preset": Self.preset(binds.store.preset, binds.store), "summary": .string(plan.summary(name: name))])
                }
            }
            guard args.has("apply") else { return .object(["applied": .bool(false), "summary": .string(plan.summary(name: name))]) }
            return try await app.gate.allow(.applyImport(planned()?.summary(name: name) ?? "\(name), no longer readable"), peer: call.peer) { () throws(ControlError) in
                guard let plan = planned() else { throw ControlError(.badValue, "\(name) not read") }
                binds.apply(plan)
                return .object(["applied": .bool(true), "summary": .string(plan.summary(name: name))])
            }
        })
        register(ControlVerb("export", help: "The bind file Export… saves, every preset in it; --link gives the pilot://import link Copy link copies.",
                             usage: "pilot export [--link]",
                             flags: [.init("link", help: "the pilot://import link instead of the file", takesValue: false)]) { call throws(ControlError) in
            let json = try app.running().binds.store.json()
            if call.arguments().has("link") { return .object(["link": .string(BindStore.link(for: json).absoluteString)]) }
            do { return try JSONDecoder().decode(JSONValue.self, from: json) } catch { throw ControlError(.badValue, "the bind file did not encode") }
        })
    }

    /// `pilot bind`'s dry run: the change each form makes, refused as the bind itself would be (an unknown action or
    /// preset, a key taken without --replace, here or by an earlier row of the plan), with the question it asks today.
    private func planBind(_ call: ControlCall, _ app: ControlActions) throws(ControlError) -> ControlPlan.Draft {
        let args = call.arguments()
        let engine = try app.running()
        let store = engine.binds.store
        if let name = args.value("preset") {
            let preset = try Self.preset(name, in: store)
            return .init("Switch bind preset", old: store.preset.title, new: preset.title, asks: Self.switching(to: preset, store))
        }
        let id = try args.word(0, "action")
        if args.has("reset"), id == "all" {
            return .init("Reset every bind", old: "the keys set by hand", new: "\(store.preset.title)'s defaults", asks: Self.resettingAll(store))
        }
        try Self.known(id, engine)
        let label = Self.label(id, engine), old = store.trigger(for: id)?.label ?? "none"
        if args.has("reset") {
            let key = store.defaultTrigger(for: id)
            if let key, let other = planned(key, for: id) ?? store.clash(key, for: id) { throw Self.taken(.triggerTaken(key, by: other)) }
            return .init("Reset \(label)", old: old, new: key?.label ?? "none", key: key?.label, free: key.map { _ in true })
        }
        if args.has("on") { return .init("Turn on \(label)", old: "off", new: "on", asks: app.ask(id)) }
        if let mouse = try Self.mouseKey(args) {
            if let other = planned(mouse, for: id) { throw ControlError(.taken, "\(mouse.label) is planned for \(other) already; pick another key") }
            let other = try Self.mouseClash(mouse, for: id, store, replace: args.has("replace"))
            // A mouse trigger runs one action; the action may hold other triggers, so the change reads as the trigger's.
            return .init("Bind \(mouse.label)", old: other ?? "nothing", new: label, key: mouse.label, free: other == nil, asks: app.ask(id))
        }
        let key = try Self.key(args, at: 1, plain: args.has("plain"))
        if let other = planned(key, for: id) { throw ControlError(.taken, "\(key.label) is planned for \(other) already; pick another key") }
        let other = store.clash(key, for: id)
        if let other, !args.has("replace") { throw Self.taken(.triggerTaken(key, by: other)) }
        return .init("Bind \(label)", old: old, new: key.label + (other.map { ", taking it from \($0)" } ?? ""), key: key.label,
                     free: other == nil, asks: app.ask(id))
    }

    /// What puts `pilot bind`'s change back, read just before it runs (pilot undo).
    private static func undoBind(_ call: ControlCall, _ app: ControlActions) throws(ControlError) -> ControlPlan.Undo {
        let args = call.arguments()
        let store = try app.running().binds.store
        if args.has("preset") { return .requests([ControlRequest(verb: "bind", args: ["--preset", store.preset.id])]) }
        let id = try args.word(0, "action")
        if args.has("reset") {
            guard id != "all" else { return .cannot("the keys set by hand are not kept") }
            return .requests(store.isCustom(id) ? [restoring(id, store)] : [])
        }
        if args.has("on") { return .cannot("a bind turned on cannot be turned off here") }
        if let mouse = try Self.mouseKey(args) {
            guard let other = store.action(for: mouse) else { return .requests([ControlRequest(verb: "remove", args: ["mouse", mouse.label])]) }
            return .requests([ControlRequest(verb: "bind", args: [other] + words(mouse) + ["--replace"])])
        }
        let key = try Self.key(args, at: 1, plain: args.has("plain"))
        // The holder gets its key back with --replace: its dry run runs before this action has let go of the key.
        let giveBack = store.clash(key, for: id).map { [ControlRequest(verb: "bind", args: [$0] + words(key) + ["--replace"])] } ?? []
        return .requests([restoring(id, store)] + giveBack)
    }

    /// What puts `id`'s key back as it is now: its preset's default when it was never set by hand, else its key, else none.
    private static func restoring(_ id: String, _ store: BindStore) -> ControlRequest {
        guard store.isCustom(id) else { return ControlRequest(verb: "bind", args: [id, "--reset"]) }
        guard let key = store.trigger(for: id) else { return ControlRequest(verb: "unbind", args: [id]) }
        return ControlRequest(verb: "bind", args: [id] + words(key))
    }

    /// `key` as bind's words, which `key(_:at:plain:)` reads back: "j --mods shift,ctrl", a plain combo with --plain.
    static func words(_ key: Key) -> [String] {
        [KeyNames.name(for: key.keyCode)] + (key.modifiers.isEmpty ? [] : ["--mods", key.modifiers.names.joined(separator: ",")]) + (key.hyper ? [] : ["--plain"])
    }

    /// `bind`'s key when it names a mouse button, its hold or the wheel (P51): under Hyper, --plain for a button's plain press. A media
    /// key or a key the mouse sends is caught in Binds › Mouse, which records the mouse it came from; nil for a keyboard key.
    static func mouseKey(_ args: ControlArguments) throws(ControlError) -> Key? {
        guard let code = KeyNames.code(for: try args.word(1, "key")), MouseKeys.isMouse(code) else { return nil }
        // A hold ("Mouse 4 Hold", P74) is never under Hyper.
        let key = Key(keyCode: code, hyper: !args.has("plain") && !MouseKeys.isHold(code))
        guard !MouseKeys.isSent(MouseKeys.plain(key).keyCode) else { throw ControlError(.badValue, "\(key.label) is caught in Binds › Mouse, which records the mouse that sends it") }
        guard !MouseKeys.isMainClick(MouseKeys.plain(key).keyCode) else {
            throw ControlError(.badValue, "Mouse 1 and Mouse 2 are the main clicks and are never bound; Hyper + drag moves and resizes windows with them")
        }
        guard MouseKeys.isTrigger(key) else { throw ControlError(.badValue, "the wheel binds under Hyper only; drop --plain") }
        return key
    }

    /// The other action holding a mouse trigger: refused unless `replace`, as a taken key is.
    private static func mouseClash(_ key: Key, for id: String, _ store: BindStore, replace: Bool) throws(ControlError) -> String? {
        guard let other = store.action(for: key), other != id else { return nil }
        if !replace { throw taken(.triggerTaken(key, by: other)) }
        return other
    }

    /// The action an earlier row of the plan binds `key` to, when it is not `id`.
    private func planned(_ key: Key, for id: String) -> String? {
        plan.changes.first { $0.key == key.label && $0.request.args.first != id }?.request.args.first
    }

    /// The question switching to `preset` asks, nil when it is the active one.
    private static func switching(to preset: BindStore.Preset, _ store: BindStore) -> ControlGate.Ask? {
        let left = store.preset
        return left.id == preset.id ? nil : .init("Switch bind preset to \(preset.title)", "every key changes to its; the keys set in \(left.title) stay with it")
    }

    private static func resettingAll(_ store: BindStore) -> ControlGate.Ask {
        .init("Reset every bind", "every key set goes back to the \(store.preset.title) preset's default")
    }

    /// An action's label as the menu names it, else its id.
    static func label(_ id: String, _ engine: Engine) -> String { engine.action(id)?.label ?? id }

    /// The ids the bind editor's Does makes that `pilot actions` does not list.
    private static let routes: [(form: String, does: String)] = [
        ("apps.web:<url>", "opens a web page in the browser"),
        ("apps.url:<bundle id>:<url>", "opens a URL in that app"),
        ("drive.menu:<bundle id>:<Menu> > <Item>", "picks an app's menu item"),
        ("drive.key:<cmd+shift+t>", "sends a keystroke"),
        ("drive.url:<url>", "opens a URL of any scheme"),
        ("drive.shortcut:<name>", "runs a Shortcut"),
        ("drive.shell:<command>", "runs a shell command"),
        ("drive.pick:{\"title\":…,\"list\":<command>,\"run\":<command>}", "picks from the lines a command prints, then runs one"),
    ]

    /// An action Pilot can run, or one a bind still names (a deleted script's), so its key can be reset or cleared.
    private static func known(_ id: String, _ engine: Engine) throws(ControlError) {
        guard engine.action(id) != nil || engine.binds.store.actions.contains(id) else {
            throw ControlError(.unknownAction, "no action \(id); pilot actions lists them")
        }
    }

    /// The bind as the store holds it now.
    private static func bound(_ id: String, _ store: BindStore) -> JSONValue {
        .object(["action": .string(id), "key": store.trigger(for: id).map { .string($0.label) } ?? .null, "custom": .bool(store.isCustom(id)),
                 "off": .bool(store.isDisabled(id))])
    }

    /// One preset as `pilot list presets` shows it.
    static func preset(_ p: BindStore.Preset, _ store: BindStore) -> JSONValue {
        .object(["id": .string(p.id), "name": .string(p.name), "base": .string(p.base.rawValue), "builtIn": .bool(p.isBuiltIn),
                 "active": .bool(p.id == store.preset.id)])
    }

    private static func taken(_ error: BindStore.BindError) -> ControlError {
        switch error {
        case .triggerTaken(let key, by: let other):
            // unbind clears an action's key only; a mouse trigger is freed by its label.
            ControlError(.taken, "\(key.label) is taken by \(other); \(MouseKeys.isMouse(key.keyCode) ? "pilot remove mouse \"\(key.label)\"" : "pilot unbind \(other)") first, --replace, or pick another key")
        }
    }

    /// The folders a bind file is read from: Downloads and the temp folders, where a chat or a browser puts one. Pilot can
    /// read any file (Full Disk Access), so a path elsewhere is refused before it is looked at, alike whether it is there.
    private static var importFolders: [URL] {
        [FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first, FileManager.default.temporaryDirectory,
         URL(fileURLWithPath: "/tmp")].compactMap { $0?.resolvingSymlinksInPath().standardizedFileURL }
    }

    /// The largest bind file read; Sven's whole table is a few dozen KB.
    private static let largestBindFile = 1 << 20

    /// A pilot://import?pack= link, or a bind file by its path, relative to the caller's folder.
    private static func bindFile(_ source: String, cwd: String?) throws(ControlError) -> (name: String, data: Data) {
        if source.hasPrefix("pilot://") {
            guard let url = URL(string: source), let data = BindStore.pack(in: url) else {
                throw ControlError(.badValue, "a pilot://import link needs pack=")
            }
            return ("The link", data)
        }
        let file = URL(fileURLWithPath: source, relativeTo: cwd.map { URL(fileURLWithPath: $0, isDirectory: true) })
        let real = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard importFolders.contains(where: { real.starts(with: $0.pathComponents) && real.count > $0.pathComponents.count }) else {
            throw ControlError(.badValue, "\(file.path(percentEncoded: false)) not read: pilot import reads a bind file from ~/Downloads or a temp folder only; copy it there first")
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= largestBindFile, let data = try? Data(contentsOf: file) else {
            throw ControlError(.badValue, "\(file.path(percentEncoded: false)) not read")
        }
        return (file.lastPathComponent, data)
    }
}
