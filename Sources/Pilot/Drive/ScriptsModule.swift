import AppKit
import PilotCore

/// Script commands (card agent-bo-95423029, audit gap 3): `scripts.run:<file name>` runs that file in Pilot's Scripts
/// folder through the drive shell route, in the mode its header names (ScriptCommand). Not in the registry, like
/// ConfigsModule's rows: the folder is read again as the menu opens and as a script runs, so a file added, edited or
/// removed since is followed. Open Scripts folder is registered, so it binds and is found by search.
@MainActor
enum ScriptsModule {
    static func register(into registry: inout ActionRegistry) {
        do { try registry.register(Action(id: "scripts.openFolder", label: "Open Scripts folder", module: .drive) { openFolder() }) }
        catch { dlog.error("scripts.openFolder: \(String(describing: error), privacy: .public)") }
    }

    /// The Scripts folder in Finder, made first when it is missing.
    static func openFolder(_ folder: URL = ScriptCommand.folder) {
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            return dlog.error("scripts folder: \(error.localizedDescription, privacy: .public)")
        }
        NSWorkspace.shared.open(folder)
    }

    /// The action a `scripts.run:` id names, with the values the root's answer put in it, labelled with its script's title
    /// (its file's name when the file is gone); nil for any other id.
    static func dynamic(_ id: String, folder: URL = ScriptCommand.folder) -> Action? {
        guard let file = ScriptCommand.file(inAction: id) else { return nil }
        let label = ScriptCommand.named(file, in: folder)?.title ?? ScriptCommand.title(file: file)
        let arguments = ScriptCommand.arguments(inAction: id)
        return Action(id: id, label: label, module: .drive) { Task { await perform(file, in: folder, arguments: arguments) } }
    }

    /// Runs `file` as its header says, `arguments` after its path (card agent-bo-95423048): silent and HUD through the
    /// drive shell route (a failure always says so, silent shows a last line only when one was printed), a fullOutput
    /// script in a visible terminal that waits for Return. A required argument missing (a bind, a link) asks for the
    /// words in Hyper+Space, its title typed, and runs nothing; a script taking a password runs nothing and says so.
    static func perform(_ file: String, in folder: URL, arguments: [String]? = nil,
                        ask: (String) -> Void = { PilotMenu.shared.open(typing: $0) },
                        shell: (String) async -> String? = { await DriveModule.shell($0) },
                        terminal: (String, String) -> Void = { VisibleTerminal.run($0, title: $1, onSuccess: VisibleRun.waitForReturn) },
                        hud: (String) -> Void = { HUD.tip($0) }) async {
        guard let script = ScriptCommand.named(file, in: folder) else { return hud("No script \(file) in Scripts.") }
        if script.takesPassword { return hud("\(script.title) takes a password; Pilot does not ask for one yet.") }
        let values = arguments ?? []
        if script.lacksArguments(values) { return ask("\(script.title) ") }
        let line = ScriptCommand.line(path: folder.appending(path: file).path, arguments: values)
        if script.mode == .terminal { return terminal(line, script.title) }
        guard let output = await shell(line) else { return hud("\(script.title) failed; Pilot's log says why.") }
        guard let line = script.mode == .hud ? ScriptCommand.hudLine(output, title: script.title) : ScriptCommand.lastLine(output) else { return }
        // The tip in the log, so a live check proves it without a screen; its words stay private, a script may print anything.
        dlog.notice("script \(file, privacy: .public): tip \(line, privacy: .private)")
        hud(line)
    }
}
