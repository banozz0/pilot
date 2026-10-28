import AppKit
import PilotCore

/// Extensions (card agent-bo-95423242, ADR 0010): `ext.<id>.<command>` runs that command of the extension in Pilot's
/// Extensions folder (ExtensionRun) and shows what it said. Not in the registry, like script commands: the folder is read
/// again as the menu opens and as a command runs, so an extension added, edited or removed since is followed. Open
/// Extensions folder and Extension catalogue (ExtensionCatalogueMenu) are registered, so they bind and are found by search.
@MainActor
enum ExtensionsModule {
    static func register(into registry: inout ActionRegistry) {
        do {
            try registry.register(Action(id: "extensions.openFolder", label: "Open Extensions folder", module: .drive) {
                ScriptsModule.openFolder(Extension.folder)
            })
        } catch { dlog.error("extensions.openFolder: \(String(describing: error), privacy: .public)") }
        // The catalogue in the menu (2026-10-10): read from GitHub only as it opens.
        do {
            try registry.register(Action(id: ExtensionCatalogueMenu.actionID, label: ExtensionCatalogueMenu.title, module: .drive,
                                         keywords: "extensions install extension get update pomodoro store") {
                PilotMenu.shared.pick(live: ExtensionCatalogueMenu.title, source: ExtensionCatalogueMenu())
            })
        } catch { dlog.error("\(ExtensionCatalogueMenu.actionID, privacy: .public): \(String(describing: error), privacy: .public)") }
    }

    /// The action an `ext.` id names, labelled with its command's title (the id when it is gone); nil for any other id.
    static func dynamic(_ id: String, folder: URL = Extension.folder) -> Action? {
        guard Extension.command(inAction: id) != nil else { return nil }
        let label = Extension.command(inAction: id, in: Extension.find(in: folder).extensions)?.1.title ?? id
        return Action(id: id, label: label, module: .drive) { Task { await perform(id, in: folder) } }
    }

    /// Runs the command `id` names, read from `folder` now, handed its extension's preferences and folders from `storage`
    /// (card agent-bo-95423246): a no-view one through `run`, with the text a keyword's answer carries as its input, a
    /// list or detail one through `list`. A required preference
    /// unset runs nothing, says which, and opens the Extensions page at the extension (`settings`, card agent-bo-95423247).
    static func perform(_ id: String, in folder: URL, storage: ExtensionStorage = ExtensionStorage(),
                        run: (Extension.Command, ExtensionRun.Inputs, String?) async -> ExtensionRun.Outcome = {
                            await ExtensionRun.noView($0, input: $2, inputs: $1)
                        },
                        list: (Extension, Extension.Command, ExtensionRun.Inputs) -> Void = { openList($0, $1, inputs: $2) },
                        act: (Extension.Item.Action, Extension, ExtensionRun.Inputs) -> Void = { ExtensionActions.run($0, in: $1, inputs: $2) },
                        settings: (Extension) -> Void = { AppWindowController.shared.open(AppPlace(.extensions), extension: $0.id) },
                        hud: (String) -> Void = { HUD.tip($0) }) async {
        let extensions = await Task.detached { Extension.find(in: folder).extensions }.value
        guard let (ext, command) = Extension.command(inAction: id, in: extensions) else {
            return hud("No extension command \(id) in Extensions.")
        }
        guard let inputs = await inputs(for: ext, storage: storage, hud: hud, unset: settings) else { return }
        guard command.mode == .noView else { return list(ext, command, inputs) }
        show(await run(command, inputs, Extension.input(inAction: id)), of: command, in: ext, act: { act($0, ext, inputs) }, hud: hud)
    }

    /// Pilot's defaults every run message carries (Surfaces v2): Defaults › Folders › Repos and the terminal app's bundle
    /// id, so an extension follows Pilot's settings with no copy of its own; and the block types it draws, comma-separated
    /// (`blocks`, omarchy-ideas Q100), so an extension sends a hero to a Pilot that draws one and older blocks to one that
    /// does not; and the icon names it draws, comma-separated (`icons`, Q475), so an extension sends a hero's line glyph
    /// to a Pilot that draws one and its emoji to one that would print the name. Never a token or an environment variable.
    static var defaults: () -> [String: String] = {
        ["repos": PilotFolders.shared.repos, "terminal": terminal(), "blocks": Extension.Block.kinds.joined(separator: ","),
         "icons": Extension.Item.Action.icons.keys.sorted().joined(separator: ",")]
    }

    /// The terminal app's bundle id, looked up at most once a minute: the lookup asks LaunchServices on the main actor,
    /// and every bar round, page ask and run wants it.
    static func terminal(now: Date = Date()) -> String {
        if let read = terminalRead, now.timeIntervalSince(read.at) < 60 { return read.bundle }
        let bundle = AppsModule.resolved(.terminal)
        terminalRead = (bundle, now)
        return bundle
    }
    private static var terminalRead: (bundle: String, at: Date)?

    /// `ext`'s preferences and folders, read off the main thread, with Pilot's defaults; nil when a required preference is
    /// unset (said, then `unset` runs) or its folders can't be made (said, the reason in the log).
    static func inputs(for ext: Extension, storage: ExtensionStorage, hud: (String) -> Void,
                       unset: (Extension) -> Void = { _ in }) async -> ExtensionRun.Inputs? {
        do {
            var inputs = try await Task.detached { try storage.inputs(for: ext) }.value
            inputs.pilot = defaults()
            return inputs
        }
        catch let missing as ExtensionStorage.Unset {
            hud(missing.message(in: ext))
            unset(ext)
        }
        catch {
            dlog.error("extension: \(ext.id, privacy: .public) folders: \(error.localizedDescription, privacy: .public)")
            hud("\(ext.title) can't get its folders; Pilot's log says why.")
        }
        return nil
    }

    /// What a no-view run came to: its HUD line and sound, its actions run in the order printed, its error under its
    /// extension's title, or that it timed out or failed (the reason in the log only, since a program's stderr can hold
    /// anything). Its bar item is asked again now, so a count follows the change (Sven on build 23: to-do felt slow).
    /// `quiet`: a run Hyper+Space stays open for (an action's `stay`), whose list shows the change; its HUD line is left out.
    static func show(_ outcome: ExtensionRun.Outcome, of command: Extension.Command, in ext: Extension,
                     act: (Extension.Item.Action) -> Void, quiet: Bool = false, hud: (String) -> Void = { HUD.tip($0) },
                     play: (String) -> Void = ExtensionActions.play) {
        dlog.notice("extension: \(command.actionID, privacy: .public) ran")
        if ext.bar != nil { ExtensionBar.shared.ask(ext.id) }
        switch outcome {
        case .hud(let line, let sound):
            if quiet { return }
            hud(line ?? "\(command.title) ran")
            sound.map(play)
        case .actions(let actions, let dropped):
            if dropped > 0 {
                dlog.error("extension: \(command.actionID, privacy: .public) printed \(dropped) actions past \(ExtensionRun.mostActions), dropped")
            }
            actions.forEach(act)
        case .error(let text): hud("\(ext.title): \(text)")
        case .timedOut: hud("\(command.title) took longer than \(ExtensionRun.noViewTimeout.components.seconds) s and was stopped.")
        case .failed(let why):
            dlog.error("extension: \(command.actionID, privacy: .public) failed: \(why, privacy: .private)")
            hud("\(command.title) failed; Pilot's log says why.")
        }
    }

    /// A list or detail command's view in the menu's panel (cards agent-bo-95423243, 245), handed `context` by the row
    /// that pushed it.
    static func openList(_ ext: Extension, _ command: Extension.Command, inputs: ExtensionRun.Inputs, context: JSONValue? = nil) {
        dlog.notice("extension: \(command.actionID, privacy: .public) view opens")
        PilotMenu.shared.pick(live: command.title, source: ExtensionListSession(ext, command, inputs: inputs, context: context))
    }
}

/// What an extension row's action does (card agent-bo-95423244): open, copy, paste, push another command's list, run a
/// no-view command, show a HUD line with its sound, run a registered Pilot action, start or stop Pilot's timer
/// (ExtensionTimer), show Pilot's alert (ExtensionAlert), or ask Pilot's AI and hand its answer to a run (ExtensionAI).
@MainActor
enum ExtensionActions {
    /// Runs an action as an extension's, a run handing back its task (`run(_:in:inputs:)`); a view's spy.
    typealias Act = (Extension.Item.Action, Extension, ExtensionRun.Inputs) -> Task<Void, Never>?

    /// What follows an action in a view showing an extension: a run (`ran`, its task) changes what it shows, so `refresh`
    /// as it ends; a Pilot action says nothing when it ends, so 1.5 s later; anything else, nothing.
    static func followed(_ ran: Task<Void, Never>?, _ action: Extension.Item.Action, refresh: @escaping @MainActor () async -> Void) {
        switch action.kind {
        case .run, .ai: Task { await ran?.value; await refresh() }
        case .pilot: Task { try? await Task.sleep(for: .seconds(1.5)); await refresh() }
        default: break
        }
    }

    /// Plays a macOS alert sound by its name; the names were checked against Extension.sounds as the action decoded.
    nonisolated static func play(_ sound: String) { NSSound(named: sound)?.play() }

    /// Runs `action` as extension `id`'s, for the timer's end and buttons and the alert's buttons, which outlive the run
    /// that sent them: the extension is read from `folder` again now, with its preferences and folders, so a run or push
    /// finds its commands as they are. An extension gone or with a required preference unset runs nothing and says so.
    static func run(_ action: Extension.Item.Action, asExtension id: String, title: String, folder: URL = Extension.folder,
                    storage: ExtensionStorage = ExtensionStorage(),
                    act: (Extension.Item.Action, Extension, ExtensionRun.Inputs) -> Void = { ExtensionActions.run($0, in: $1, inputs: $2) },
                    hud: (String) -> Void = { HUD.tip($0) }) async {
        let found = await Task.detached { Extension.find(in: folder).extensions.first { $0.id == id } }.value
        guard let ext = found else { return hud("\(title) is no longer in Extensions.") }
        guard let inputs = await ExtensionsModule.inputs(for: ext, storage: storage, hud: hud) else { return }
        act(action, ext, inputs)
    }

    /// What picking `action` in an open view does: a push to one of the extension's list or detail commands stays in the
    /// panel, a run that asks first asks there (ExtensionAskSource), a run that stays runs with the panel open and its list
    /// asked again (To-do B); the rest run once it closes. `inputs` are the ones the view's own run was handed.
    static func pick(_ action: Extension.Item.Action, in ext: Extension, inputs: ExtensionRun.Inputs) -> MenuPick {
        if case .push(let name, let context) = action.kind, let command = ext.view(name) {
            return .push(command.title, ExtensionListSession(ext, command, inputs: inputs, context: context))
        }
        if let ask = action.ask { return .push(action.label, ExtensionAskSource(ask, action: action, in: ext, inputs: inputs)) }
        return answered(action, in: ext, inputs: inputs, back: false)
    }

    /// `action` with nothing left to ask: kept in the panel when it stays (`back`: out of the ask it answered first),
    /// else run once the panel closes.
    static func answered(_ action: Extension.Item.Action, in ext: Extension, inputs: ExtensionRun.Inputs, back: Bool) -> MenuPick {
        guard action.stay else { return .close { run(action, in: ext, inputs: inputs) } }
        return .keep(clear: action.clear, back: back) { run(action, in: ext, inputs: inputs, quiet: true) }
    }

    /// Runs `action` of `ext` with the panel closed, a run or push handed `inputs`. `isRegistered` says whether an id is
    /// the registry's, the only ones a Pilot action may run. A run hands back its task, which ends as the command does:
    /// the view showing it is asked again then (Sven on build 23: to-do felt slow).
    @discardableResult
    static func run(_ action: Extension.Item.Action, in ext: Extension, inputs: ExtensionRun.Inputs, quiet: Bool = false,
                    isRegistered: (String) -> Bool = { Engine.shared?.registry.actions[$0] != nil },
                    hud: (String) -> Void = { HUD.tip($0) }, play: (String) -> Void = ExtensionActions.play) -> Task<Void, Never>? {
        switch action.kind {
        case .open(let target):
            guard let url = ExtensionList.url(target) else { hud("Pilot can't open \(target)."); return nil }
            NSWorkspace.shared.open(url)
        case .copy(let text): SystemModule.copy(text)
        case .paste(let text): SnippetPaster().paste(text)
        case .hud(let text, let sound):
            hud(text)
            sound.map(play)
        case .timer(let timer): ExtensionTimer.shared.start(timer, extension: ext)
        case .alert(let alert): ExtensionAlert.show(alert, from: ext)
        case .pilot(let id):
            guard ExtensionList.allowsPilot(id, isRegistered: isRegistered) else {
                dlog.error("extension: \(ext.id, privacy: .public) asked for \(id, privacy: .public), refused")
                hud("\(ext.title) can't run \(id).")
                return nil
            }
            Engine.shared?.action(id)?.run()
        case .run(let name, let context):
            guard let command = ext.noView(name) else {
                hud("\(ext.title) has no command \(name) to run.")
                return nil
            }
            return Task {
                ExtensionsModule.show(await ExtensionRun.noView(command, context: context, input: action.input, inputs: inputs), of: command, in: ext,
                                      act: { run($0, in: ext, inputs: inputs) }, quiet: quiet)
            }
        case .push(let name, let context):
            guard let command = ext.view(name) else {
                hud("\(ext.title) has no view \(name) to show.")
                return nil
            }
            ExtensionsModule.openList(ext, command, inputs: inputs, context: context)
        case .ai(let task, let text, let then):
            // The provider is the AI page's; only the size is logged, never the text.
            dlog.notice("extension: \(ext.id, privacy: .public) asks AI about \(text.utf8.count) bytes")
            let runner = AISettings.shared.runner()
            return Task {
                let next = await ExtensionAI.ask(task, text, then: then, runner: runner)
                await run(next, in: ext, inputs: inputs, quiet: quiet)?.value
            }
        }
        return nil
    }
}
