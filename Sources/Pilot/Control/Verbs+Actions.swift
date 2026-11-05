import AppKit
import PilotCore
import WebApps

/// What the action verbs reach in the running app (AI helper T6): the engine, the Allow gate, the ids the menu offers,
/// the app in front and the app window. The tests hand in their own, so nothing of Sven's runs, comes forward or opens.
@MainActor
final class ControlActions {
    var engine: @MainActor () -> Engine? = { Engine.shared }
    var gate = AllowPrompt.gate
    /// The question running or binding `id` asks, its quicklink or extension read from the live stores.
    var ask: @MainActor (String) -> ControlGate.Ask? = { .running($0) }
    /// The ids the menu offers besides the registry (web apps, apps, scripts, extension commands, quicklinks, configs,
    /// outputs), then the bind editor's App action picks.
    var offered: @MainActor () -> [Listed] = ControlActions.menuOffers
    /// Brings `--app` to the front before a run or a press; throws when it is not running or does not come.
    var front: @MainActor (String) async throws(ControlError) -> Void = ControlActions.bringToFront
    var readback = RunReadback()
    /// `pilot open`: the app window on a place, as pilot://open opens it.
    var open: @MainActor (AppPlace, SetupSection?) -> Void = { AppWindowController.shared.open($0, setup: $1) }
    /// `pilot bug`: the browser on a link.
    var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// `pilot crash --reveal`: Finder on a file, selected.
    var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// `pilot crash` and `pilot bug`: the newest of Pilot's crash reports from the last week (CrashReports).
    var newestCrash: @Sendable () async -> CrashReports.Report? = { await Task.detached { CrashReports.newest() }.value }
    /// The extensions installed, read once per answer for what `actions --json` and `run` mark.
    var extensions: @MainActor () -> [Extension] = { Extension.find().extensions }
    /// System's switches as the menu reads them, by action id; each asks the system, so only a listing with system rows reads them.
    var switches: @MainActor () -> [String: Bool] = SystemModule.switchStates

    /// One row of `pilot actions`: a registered action, one the menu offers (an app, a script, …) or one only a bind names.
    struct Listed {
        let kind: String
        let info: BindsPage.ActionInfo
    }

    /// What a run leaves on Sven's screen for his hands: a menu branch, a picker, a panel, a window, or a capture he
    /// finishes.
    enum OnScreen: String, CaseIterable {
        case menu, picker, panel, window, capture
    }

    /// Registered actions that only put something on Sven's screen and wait on his hands, so a run answers dispatched with
    /// nothing done yet. Kept here, not on the modules' actions: a new one is added here too.
    static let onScreen: [String: OnScreen] = {
        var kinds: [String: OnScreen] = [
            "apps.launcher": .menu, "apps.appsMenu": .menu, "apps.update": .menu, "apps.clean": .menu, "system.menu": .menu, "captures.menu": .menu, "engine.sheet": .menu,
            "system.killProcess": .picker, "system.rotateDisplay": .picker, "system.bluetooth": .picker, "apps.emoji": .picker, "apps.lazygit": .picker,
            "apps.bitwardenFill": .picker, ExtensionCatalogueMenu.actionID: .picker,
            "apps.clipboard": .panel, "apps.clipboardOptionV": .panel, NotesPanel.toggleID: .panel, QuickAIActions.askID: .panel,
            AIChatPanel.chatID: .panel,
            "engine.openWindow": .window, "apps.webApp": .window, "apps.reports": .window, "apps.install": .window,
            "apps.bitwardenSearch": .window, "apps.bitwardenGenerator": .window, "system.soundSettings": .window,
            "system.bluetoothSettings": .window, "system.wifiSettings": .window, "system.displaySettings": .window,
            "system.focusSettings": .window, "system.translationLanguages": .window,
            "captures.area": .capture, "captures.scrolling": .capture, "captures.ocr": .capture, "captures.activeWindow": .capture,
            "captures.screenRecording": .capture, "captures.smartElement": .capture, "captures.subject": .capture,
            "captures.markup": .capture, "captures.pickColour": .capture, "captures.makeQR": .panel, "captures.readQR": .capture, "captures.readQRScreen": .capture,
        ]
        for kind in Feedback.Kind.allCases { kinds[kind.actionID] = .window }
        return kinds
    }()

    /// What running `id` leaves on Sven's screen for his hands, nil when it finishes on its own: a listed action, a drive
    /// picker, or an extension command with a list or detail view.
    /// `extensions` is read only for an extension command's id.
    static func opens(_ id: String, extensions: @autoclosure () -> [Extension]) -> OnScreen? {
        if let kind = onScreen[id] { return kind }
        if id.hasPrefix("drive.pick:") { return .picker }
        guard id.hasPrefix(Extension.prefix), let (_, command) = Extension.command(inAction: id, in: extensions()) else { return nil }
        return command.mode == .noView ? nil : .panel
    }

    func running() throws(ControlError) -> Engine {
        guard let engine = engine() else { throw ControlError(.notReady, "Pilot's key engine is not running yet") }
        return engine
    }

    /// Registered actions, then what the menu offers, then the rest the binds name; each id once.
    func listed(_ engine: Engine) -> [Listed] {
        let all = engine.allBindActions
        let registered = all.filter { engine.registry.actions[$0.id] != nil }.map { Listed(kind: "action", info: $0) }
        let bound = all.filter { engine.registry.actions[$0.id] == nil }.map { Listed(kind: "bound", info: $0) }
        var seen = Set<String>()
        return (registered + offered() + bound).filter { seen.insert($0.info.id).inserted }
    }

    /// The action sources MenuPanel.entries reads as the menu opens, keep the two in step (its install rows are not
    /// actions); then the bind editor's App action picks, which the menu does not list.
    static func menuOffers() -> [Listed] {
        func rows(_ kind: String, _ infos: [BindsPage.ActionInfo]) -> [Listed] { infos.map { Listed(kind: kind, info: $0) } }
        let apps = Module.apps.rawValue
        return rows("webApp", WebAppDirectory.list().compactMap { w in AppsModule.webID(w.url.absoluteString).map { .init(id: $0, label: w.name, module: apps) } })
            + rows("app", AppsModule.installedApps().map { .init(id: AppsModule.openID(bundle: $0.bundle), label: $0.name, module: apps) })
            + rows("script", ScriptCommand.actions([], with: ScriptCommand.find()))
            + rows("extension", Extension.actions([], with: Extension.find().extensions))
            + rows("quicklink", QuicklinkBook.shared.links.map { .init(id: $0.actionID, label: $0.name, module: apps) })
            + rows("config", DeveloperPages.on ? ConfigsModule.menuRows() : [])
            + rows("output", SystemModule.outputRows())
            + rows("appAction", catalogueRows())
    }

    /// The bind editor's App action picks: the drive catalogue's checked actions for the apps installed here.
    static func catalogueRows() -> [BindsPage.ActionInfo] {
        DriveModule.catalogue.apps.filter { AppsModule.isInstalled($0.bundle) }.flatMap { app in
            app.actions.map { .init(id: $0.route, label: DriveModule.catalogue.label(for: $0.route) ?? $0.label, module: Module.drive.rawValue) }
        }
    }

    /// pilot://run's `app=` without blocking the main thread: activates the app and waits up to a second for it to be in front.
    static func bringToFront(_ name: String) async throws(ControlError) {
        guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name || $0.bundleIdentifier == name }) else {
            throw ControlError(.badValue, "\(name) is not running, so nothing ran")
        }
        target.activate()
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw ControlError(.timeout, "\(name) did not come to the front, so nothing ran")
    }
}

extension ControlVerbs {
    /// `actions`, `run` and `press`, then the binds and pages families over the same app.
    func registerActions(_ app: ControlActions) {
        let modules = Module.allCases.map(\.rawValue), moduleNames = JSONValue.array(modules.map(JSONValue.string))
        register(ControlVerb("actions", help: "Every action Pilot can run or bind, with its key; --find or --module narrows it, --json gives rows.",
                             usage: "pilot actions [--find \"<words>\"] [--module <module>] [--json]",
                             flags: [.init("find", help: "the actions whose id or label holds any of these words, as \"capture display float\""),
                                     .init("module", help: "one module: \(modules.joined(separator: ", "))"),
                                     .init("json", help: "rows: id, label, module, kind, key, and the marks below", takesValue: false)],
                             schema: {
                                 .object(["modules": moduleNames,
                                          "rows": .object([
                                              "kind": .string("action, bound (only a bind names it), what the menu offers (webApp, app, script, extension, quicklink, config, output), or appAction (the bind editor's App action picks)"),
                                              "key": .string("its key, absent when unbound"), "off": .string("true: an import switched it off; run does nothing"),
                                              "asks": .string("the Allow question run and bind ask, absent when they ask none"),
                                              "opens": .string("what run leaves on the user's screen for their hands: \(ControlActions.OnScreen.allCases.map(\.rawValue).joined(separator: ", ")); absent when it finishes on its own"),
                                              "on": .string("a System switch's state as the menu reads it; absent when the Mac cannot say"),
                                              "notAdded": .string("true: an optional ability not added; Binds and the menu leave it out until Launcher › Abilities adds it"),
                                          ])])
                             },
                             index: { .object(["modules": moduleNames]) }) { call throws(ControlError) in
            let args = call.arguments()
            let module = args.value("module")
            if let module, Module(rawValue: module) == nil {
                throw ControlError(.unknownModule, "no module \(module); modules: \(modules.joined(separator: ", "))")
            }
            let engine = try app.running()
            // Any word, not every word, as the menu's search holds it: one search finds the actions for each job the user named.
            let words = (args.value("find") ?? "").split(separator: " ").map { FuzzyRanker.Filter(String($0)) }
            let rows = app.listed(engine).filter { row in
                (module == nil || row.info.module == module)
                    && (words.isEmpty || words.contains { $0.holds([row.info.id, row.info.label, row.info.keywords ?? ""]) })
            }
            let store = engine.binds.store
            guard args.has("json") else {
                let width = rows.map(\.info.id.count).max() ?? 0
                return .string(rows.map { row in
                    let key = store.trigger(for: row.info.id)?.label ?? "–"
                    return "\(row.info.id.padding(toLength: width + 2, withPad: " ", startingAt: 0))\(key)  \(row.info.label)"
                }.joined(separator: "\n"))
            }
            let links = QuicklinkBook.shared.links, extensions = app.extensions()
            let on = rows.contains { $0.info.module == Module.system.rawValue } ? app.switches() : [:]
            return .array(rows.map { row in
                let id = row.info.id
                var entry: [String: JSONValue] = ["id": .string(id), "label": .string(row.info.label),
                                                  "module": .string(row.info.module), "kind": .string(row.kind)]
                entry["key"] = store.trigger(for: id).map { .string($0.label) }
                if store.isDisabled(id) { entry["off"] = .bool(true) }
                entry["asks"] = ControlGate.Ask.run(id, quicklinks: links, extensions: extensions).map { .string($0.text) }
                entry["opens"] = ControlActions.opens(id, extensions: extensions).map { .string($0.rawValue) }
                entry["on"] = on[id].map(JSONValue.bool)
                if !engine.isListed(id) { entry["notAdded"] = .bool(true) }
                return .object(entry)
            })
        })
        register(ControlVerb("run", help: "Runs an action by id and answers with the tips it raised in about a second.",
                             usage: "pilot run <action> [--app <app>]",
                             flags: [.init("app", help: "an app, by name or bundle id, brought to the front first")],
                             detail: { id throws(ControlError) in
                                 guard let action = app.engine()?.action(id) else { return nil }
                                 return ["\(id): \(action.label)", app.ask(id).map { "asks Allow: \($0.text)" },
                                         ControlActions.opens(id, extensions: app.extensions()).map { "opens a \($0.rawValue) on the user's screen; the rest needs their hands" },
                                         RunReadback.withheld(id)].compactMap { $0 }.joined(separator: "\n")
                             }) { call throws(ControlError) in
            let args = call.arguments()
            let id = try args.word(0, "action")
            let engine = try app.running()
            guard let action = engine.action(id) else { throw ControlError(.unknownAction, "no action \(id); pilot actions lists them") }
            return try await app.gate.allow(app.ask(id), peer: call.peer) { () throws(ControlError) in
                if let name = args.value("app") { try await app.front(name) }
                log.notice("run: \(LinkToken.redact(id), privacy: .public), from the pilot command")
                let withheld = RunReadback.withheld(id)
                var tips: [String] = []
                if withheld == nil { tips = await app.readback.watch { action.run() } } else { action.run() }
                let off = engine.binds.store.isDisabled(id) ? "\(id) is switched off, so nothing ran; turn it on in Binds › Export and import (pilot open binds)" : nil
                var answer: [String: JSONValue] = ["dispatched": .string(id), "hud": tips.isEmpty ? .null : .string(tips.joined(separator: "\n")),
                                                   "error": off.map(JSONValue.string) ?? .null]
                answer["opens"] = ControlActions.opens(id, extensions: app.extensions()).map { .string($0.rawValue) }
                answer["withheld"] = withheld.map(JSONValue.string)
                return .object(answer)
            }
        })
        register(ControlVerb("press", help: "Presses a key with the layer key into an app, as a keyboard would, after Allow.",
                             usage: "pilot press <key> --app <app> [--mods shift,ctrl,alt,cmd]",
                             flags: [.init("app", help: "the app the key goes into, brought to the front first; required"),
                                     .init("mods", help: "shift, ctrl, alt and cmd, or leftAlt, rightCmd and the like for one side")]) { call throws(ControlError) in
            let args = call.arguments()
            let key = try Self.key(args, at: 0, plain: false)
            guard let name = args.value("app") else { throw ControlError(.badRequest, "pilot press needs --app, so the key never lands in the wrong window") }
            let engine = try app.running()
            return try await app.gate.allow(.press(key.label, app: name), peer: call.peer) { () throws(ControlError) in
                try await app.front(name)
                guard let token = try? LinkToken.standard.value() else { throw ControlError(.badValue, "the link token could not be read") }
                // pilot://press's own path, on the first layer key in use; its app is already in front, so it does not wait
                // on the main thread for it.
                let layer = engine.settings.layerKeys.primary.pressWord
                let sides: [(String, Modifiers, Modifiers)] = [("shift", .leftShift, .rightShift), ("ctrl", .leftCtrl, .rightCtrl),
                                                               ("alt", .leftAlt, .rightAlt), ("cmd", .leftCmd, .rightCmd)]
                let held = sides.compactMap { name, left, right -> URLQueryItem? in
                    let side: String? = switch (key.modifiers.isSuperset(of: left), key.modifiers.isSuperset(of: right)) {
                    case (true, true): "1"
                    case (true, false): "left"
                    case (false, true): "right"
                    case (false, false): nil
                    }
                    return side.map { URLQueryItem(name: name, value: $0) }
                }
                var link = URLComponents(string: "pilot://press")!
                link.queryItems = [URLQueryItem(name: "layer", value: layer), URLQueryItem(name: "key", value: KeyNames.name(for: key.keyCode)),
                                   URLQueryItem(name: "token", value: token)] + held
                engine.testPress(link.url!)
                return .object(["pressed": .string(key.label), "app": .string(name)])
            }
        })
        registerBinds(app)
        registerPages(app)
        registerBugReport(app)
        registerCrashReport(app)
    }

    /// The key named at `index` with `--mods`, under Hyper unless `plain`; a plain combo needs cmd, ctrl or alt.
    static func key(_ args: ControlArguments, at index: Int, plain: Bool) throws(ControlError) -> Key {
        let name = try args.word(index, "key")
        guard let code = KeyNames.code(for: name) else {
            throw ControlError(.badValue, "no key \(name); a letter, digit, F1–F12, space, return, tab, escape, left, right, up or down")
        }
        return Key(keyCode: code, modifiers: try mods(args, plain: plain), hyper: !plain)
    }

    /// `--mods`, comma, plus or space separated; a plain combo's must hold cmd, ctrl or alt.
    static func mods(_ args: ControlArguments, plain: Bool) throws(ControlError) -> Modifiers {
        let words = (args.value("mods") ?? "").split(whereSeparator: { ",+ ".contains($0) }).map(String.init)
        guard let modifiers = Modifiers(names: words) else {
            throw ControlError(.badValue, "--mods takes shift, ctrl, alt and cmd, or leftAlt, rightCmd and the like for one side")
        }
        guard !plain || !modifiers.isDisjoint(with: [.ctrl, .alt, .cmd]) else {
            throw ControlError(.badValue, "a plain combo needs cmd, ctrl or alt in --mods")
        }
        return modifiers
    }
}
