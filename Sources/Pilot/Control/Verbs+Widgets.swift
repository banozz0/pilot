import Foundation
import PilotCore

/// What `pilot widget` and the `widgets` collection reach (ADR 0016): the widget store, the desk and the Allow gate. No
/// verb here writes a widget's trust: only Pilot's own surfaces do, so no agent call raises one.
@MainActor
final class WidgetTools {
    var store = WidgetStore.live
    var desk = WidgetDesk.shared
    var gate = AllowPrompt.gate
    /// The folders `widget check` reads without asking, as `ext test` does: the temporary folders and ~/Downloads, besides
    /// the Widgets folder itself. Any other is read only after Allow, since Pilot reads with Full Disk Access.
    var readable: [URL] = [FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first, FileManager.default.temporaryDirectory,
                           URL(fileURLWithPath: "/tmp")].compactMap { $0?.resolvingSymlinksInPath().standardizedFileURL }

    /// Every Ask detail here is raw: AllowPrompt.thing escapes it once, as the card and the Trust sheet escape theirs.
    func readAsk(_ source: URL, to action: String = "check it as a widget") -> ControlGate.Ask? {
        let real = source.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let roots = readable + [store.widgets.resolvingSymlinksInPath().standardizedFileURL]
        guard !roots.contains(where: { real.starts(with: $0.pathComponents) }) else { return nil }
        let kind = source.pathExtension.lowercased() == "zip" ? ".zip" : "folder"
        return ControlGate.Ask("Read \(kind)", "Pilot reads \(source.path) to \(action); only a summary comes back")
    }

    /// A check's one run: where it runs and what it is handed, then the program the runner will start, resolved as it
    /// resolves it, and its arguments, numbered, last (WidgetAsks); nil when its program is not there to run. The lines
    /// are the Ask's own, so the prompt escapes each once and keeps the breaks between them.
    static func runAsk(_ widget: Widget, outside source: URL?) -> ControlGate.Ask? {
        guard let command = WidgetAsks.command(widget), !command.missing else { return nil }
        let asking = WidgetAsks.asking(widget)
        // The rows as every question shows them: the header, then each word a row marked №n (WidgetAsks.Asking).
        let words = (asking.header.map { [$0] } ?? []) + asking.rows
        let limit = "stopped after \(Int(Widget.timeout.inSeconds)) s with everything it started"
        guard let source else {
            return ControlGate.Ask("Run widget", lines: ["run the command of \(widget.id) (\(widget.title)) once, as you, in \(widget.folder.path)",
                                                        "its saved settings and passwords on stdin, \(limit)"] + words)
        }
        return ControlGate.Ask("Test widget", lines: ["run the command of \(widget.id) (\(widget.title)) once, as you, from a copy of \(source.path), HOME in a temporary folder",
                                                     "only its settings' defaults on stdin, no saved settings or passwords, \(limit)"] + words)
    }

    /// A path a question names as it is: unchanged by escaping (no line break or hidden character) and with no №, so it
    /// can draw no line or row of its own. Test, Install and Import refuse one that is not.
    static func isShowable(_ url: URL) -> Bool { Widget.isPlain(url.path) && !url.path.contains("№") }

    /// Install's (made here) or Import's (locked) question: what comes from where, then everything Trust this widget
    /// lists. Kept short, so a widget at the format's widest fits the prompt with a path of about 100 characters.
    static func installAsk(_ widget: Widget, from source: URL, locked: Bool, replaces: Bool, inherits: String?) -> ControlGate.Ask {
        ControlGate.Ask(locked ? "Import widget" : "Install widget", lines: [
            "\(widget.id) (\(widget.title)) from \(source.path)" + (replaces ? ", replacing the one installed" : ""),
            locked ? "Locked until you trust it; it asks to:" : "Made here, full power; it asks to:",
        ] + WidgetAsks.lines(widget) + (inherits.map { [$0] } ?? []))
    }

    /// Placing a widget that will run (a command or a page it may load) asks first, with everything Trust this widget
    /// lists; one fed only by readings, or locked (its card shows), asks nothing.
    /// `values`: the placement's own, as it will save them (Widget.own): its actions setting's picks are the buttons the
    /// question names, not the widget's default.
    func placeAsk(_ id: String, values: [String: JSONValue]? = nil) -> ControlGate.Ask? {
        guard let widget = store.widget(id), WidgetAsks.runsOnShow(widget), store.trust(of: widget).runs else { return nil }
        let picks = widget.actionsField.flatMap { values?[$0.name] }.map(Widget.picks)
        return ControlGate.Ask("Place widget", lines: ["\(widget.id) (\(widget.title)) on the desktop, where it runs whenever it shows:"]
            + WidgetAsks.lines(widget, picks: picks))
    }
}

extension ControlVerbs {
    static let widgetSubcommands: [(name: String, usage: String, help: String)] = [
        ("check", "widget check <folder|id> [--no-run]",
         "Checks a widget: its files (no symlinks, nothing leaving its folder, the gallery's limits), its widget.json and its trust; then runs its command once under the 5 s limit, unless --no-run. An installed widget runs only when made here or trusted; a folder outside Pilot's Widgets folder runs from a copy after Allow."),
        ("new", "widget new <id> [--title <title>] [--html]",
         "Makes a widget folder <id> from a template in the current folder (never in Pilot's Widgets folder): a blocks widget fed by feed.sh, or with --html a page fed by the clock. It installs nothing and is trusted by nothing: pilot widget check, then pilot widget install."),
        ("install", "widget install <folder>",
         "Installs a folder you made as made here, with full power: after an Allow that shows everything it will run, its sites and its readings. A folder from elsewhere goes through import."),
        ("import", "widget import <folder|.zip>",
         "Installs a widget folder or .zip from elsewhere, locked: refused with a link, a path leaving it or past the gallery's limits; after Allow. It runs nothing and loads no page until you press Trust this widget on the Widgets page."),
    ]

    /// `pilot widget …` and the `widgets` collection: the desktop's placements, which the desk shows by the show rule.
    func registerWidgets(_ tools: WidgetTools) {
        let subcommands = Self.widgetSubcommands.map(\.name)
        register(ControlVerb("widget", help: "Checks desktop widgets; placements: pilot list widgets; state: pilot status --part widgets.",
                             usage: "pilot " + Self.widgetSubcommands.map(\.usage).joined(separator: " | "),
                             flags: [.init("no-run", help: "widget check: only check, run nothing", takesValue: false),
                                     .init("title", help: "widget new: its title"), .init("html", help: "widget new: a page, not blocks", takesValue: false)],
                             schema: { .object(["subcommands": .array(Self.widgetSubcommands.map { .object(["name": .string($0.name), "usage": .string("pilot " + $0.usage), "help": .string($0.help)]) }),
                                                "collections": .array([.string("widgets")])]) },
                             index: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             detail: { word throws(ControlError) in Self.widgetSubcommands.first { $0.name == word }.map { "pilot \($0.usage)\n\($0.help)" } }) { call throws(ControlError) in
            let args = call.arguments()
            switch try args.word(0, "subcommand: \(subcommands.joined(separator: ", "))") {
            case "check": return try await Self.checkWidget(args, tools, cwd: call.cwd, peer: call.peer)
            case "new": return try Self.newWidget(args, tools, cwd: call.cwd)
            case "install": return try await Self.installWidget(args, tools, cwd: call.cwd, peer: call.peer, locked: false)
            case "import": return try await Self.installWidget(args, tools, cwd: call.cwd, peer: call.peer, locked: true)
            case let other: throw ControlError(.badValue, "no widget \(other); subcommands: \(subcommands.joined(separator: ", "))")
            }
        })
        register(ControlCollection(
            "widgets", help: "The widgets on the desktop, each placement with its widget, screen (a display UUID; main when none), place as a fraction of the screen and size; a widget may be placed more than once. They show on an empty workspace or while Show desktop holds the windows out, on every workspace or on the one given; Hyper+drag moves one.",
            fields: [.init("widget", help: "an installed widget's id, or a ready one's: \(ReadyWidgets.ids.joined(separator: ", "))"), .init("screen", help: "a display's UUID (pilot status --part widgets lists them); the main display when left out", required: false),
                     .init("x", help: "the left edge, 0 to 1 of the screen's width", required: false), .init("y", help: "the top edge, 0 to 1 of the screen's height", required: false),
                     .init("workspace", help: "the one workspace it shows on, 1 to 9; the widget's own (its widget.json), else every workspace, when left out", required: false),
                     .init("values", help: "its own settings, as Edit widget keeps them: a JSON object by setting name (a password is never one; an actions setting's picks are kept only as a button may run them); \"layout\" is every widget's: auto (by its size, the default), strip, square, wide or large", required: false),
                     .init("home", help: "on puts it on Home, the first page of Pilot's window, instead, shown there at once; it runs only while Home draws it", required: false)],
            rowKey: "id", asks: [.add],
            list: { () throws(ControlError) in .array(tools.store.placements().map(Self.row)) },
            askerAdd: { args, peer throws(ControlError) in
                let id = try args.required("widget")
                guard let widget = tools.store.widget(id) else { throw ControlError(.badValue, "no widget \(id) is installed in \(tools.store.widgets.path)") }
                let workspace = args.value("workspace")
                if let workspace, !Workspaces.all.contains(workspace) { throw ControlError(.badValue, "--workspace must be 1 to 9") }
                // Every field is read before Allow, so a bad one is refused without asking.
                func fraction(_ name: String) throws(ControlError) -> Double? {
                    guard let text = args.value(name) else { return nil }
                    guard let value = Double(text), (0...1).contains(value) else { throw ControlError(.badValue, "--\(name) must be 0 to 1") }
                    return value
                }
                let (x, y) = (try fraction("x"), try fraction("y"))
                let home = try args.value("home").map { word throws(ControlError) in try ControlVerbs.onOff(word, "--home") } ?? false
                let values: [String: JSONValue]? = try args.value("values").flatMap { text throws(ControlError) in
                    guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)) else {
                        throw ControlError(.badValue, "--values must be a JSON object by setting name")
                    }
                    if widget.offersLayout, let layout = object[Widget.layoutName], !Widget.layoutWords.contains(layout.string ?? "") {
                        throw ControlError(.badValue, "--values: layout must be \(Widget.layoutWords.joined(separator: ", "))")
                    }
                    return widget.own(object)
                }
                // The Launcher's tiles run any Hyper+Space row on a click, past what a button may run: Edit widget picks them.
                if let field = widget.menuField, values?[field.name] != nil {
                    throw ControlError(.badValue, "--values: the \(widget.title)'s tiles are picked in its Edit widget, not from the command line")
                }
                // Its picks are named in the question, so they fit its room as the default must.
                if let field = widget.actionsField, let picked = values?[field.name], !widget.fits(picks: Widget.picks(picked)) {
                    throw ControlError(.badValue, "--values: its \(field.name) picks would make the Place question longer than it may be; pick fewer")
                }
                // A widget that will run as you asks Allow before it is placed; the gate builds the question again after
                // Allow and denies one that changed (ControlGate.allow).
                try await tools.gate.allow(tools.placeAsk(id, values: values), peer: peer) { () throws(ControlError) in }
                var placements = tools.store.placements()
                var placement = Widget.Placement.new(widget, after: placements.count, screen: args.value("screen"), x: x, y: y,
                                                     workspace: workspace, home: home)
                placement.values = values
                placements.append(placement)
                try Self.save(placements, tools)
                return Self.row(placement)
            },
            askerRemove: { args, _ throws(ControlError) in
                let id = try args.word(0, "id")
                var placements = tools.store.placements()
                guard let i = placements.firstIndex(where: { $0.id == id }) else { throw ControlError(.badValue, "no placement \(id); pilot list widgets lists them") }
                placements.remove(at: i)
                try Self.save(placements, tools)
                return .string(id)
            }))
    }

    private static func save(_ placements: [Widget.Placement], _ tools: WidgetTools) throws(ControlError) {
        do { try tools.store.save(placements) } catch { throw ControlError(.badValue, "not saved: \(error.localizedDescription)") }
        tools.desk.reload()
    }

    private static func row(_ p: Widget.Placement) -> JSONValue {
        .object(["id": .string(p.id), "widget": .string(p.widget), "screen": p.screen.map(JSONValue.string) ?? .string("main"),
                 "x": .number(p.x), "y": .number(p.y), "width": .number(p.width), "height": .number(p.height),
                 "workspace": p.workspace.map(JSONValue.string) ?? .string("all"), "home": .bool(p.onHome),
                 "values": .object(p.values ?? [:])])
    }

    /// `widget check`: the files, the manifest, the trust, then one run. Nothing it does raises a widget's trust.
    private static func checkWidget(_ args: ControlArguments, _ tools: WidgetTools, cwd: String?, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let word = try args.word(1, "folder or id")
        // Pilot's ready widgets live in code: their manifest is checked, and they run nothing of their own.
        if Widget.isReserved(word), let ready = ReadyWidgets.widget(word) {
            return .object(["id": .string(ready.id), "title": .string(ready.title), "draw": .string(ready.draw.rawValue),
                            "data": .string(ready.data.label), "trust": .string("Pilot's"), "problems": .array([]),
                            "buttons": .array(ready.buttons.map { .string($0.line) }),
                            // The Launcher's starting tiles are Hyper+Space rows' keys (menuPicks).
                            "picks": .array((ready.menuField.map { Widget.menuPicks($0.initial) } ?? Widget.picks(ready.actionsField?.initial)).map(JSONValue.string)),
                            "run": .object(["skipped": .string("nothing to run: Pilot feeds it \(ready.data.label)")]), "ok": .bool(true)])
        }
        let installed = !word.contains("/") && Widget.isID(word) ? tools.store.widget(word) : nil
        // Resolved once: the walk, the read and the copy all read the same real folder.
        let folder = installed?.folder ?? ExtensionTools.folder(word, cwd: cwd).resolvingSymlinksInPath().standardizedFileURL
        // Pilot's bundled desk widgets read from the app itself, as installed and trusted: nothing to ask before reading.
        let inside = installed.map(ReadyWidgets.isDesk) == true || tools.store.holds(folder)
        if !inside { try await tools.gate.allow(tools.readAsk(folder), peer: peer) { () throws(ControlError) in } }
        var answer: [String: JSONValue] = ["folder": .string(folder.path), "installed": .bool(inside)]
        let walked = await Task.detached { Widget.walk(folder) }.value
        var problems = walked.problems
        let widget: Widget?
        do { widget = try Widget(folder: folder) } catch {
            widget = nil
            problems += error.reasons.filter { !problems.contains($0) }
        }
        if let widget {
            if inside, widget.id != folder.lastPathComponent { problems.append("its folder is named \(folder.lastPathComponent) but its id is \(widget.id)") }
            answer["id"] = .string(widget.id); answer["title"] = .string(widget.title); answer["draw"] = .string(widget.draw.rawValue)
            answer["data"] = .string(widget.data.label); answer["hosts"] = .array(widget.hosts.map(JSONValue.string))
            answer["size"] = .object(["width": .number(widget.size.width), "height": .number(widget.size.height)])
            answer["settings"] = .array(widget.settings.map { .string("\($0.name) (\($0.kind.rawValue))") })
            answer["buttons"] = .array(widget.buttons.map { .string($0.line) })
            // An actions setting's default picks: the buttons it starts with, before Edit widget changes them.
            let picks = Widget.picks(widget.actionsField?.initial)
            if widget.actionsField != nil { answer["picks"] = .array(picks.map(JSONValue.string)) }
            // A button whose action Pilot has no run for runs nothing: said here (an extension not installed yet among them).
            if Engine.shared != nil {
                let missing = widget.buttons.filter { WidgetDesk.buttonAction($0.action) == nil }
                let unpicked = picks.filter { WidgetDesk.buttonAction($0) == nil }
                answer["missingActions"] = .array((missing.map(\.action) + unpicked).map(JSONValue.string))
                problems += missing.map { "its button \($0.title) runs \($0.action), which Pilot has no action for here" }
                problems += unpicked.map { "its actions setting starts with \($0), which Pilot has no action for here" }
            }
        }
        answer["files"] = .number(Double(walked.files.count))
        let trust = widget.map(tools.store.trust) ?? .locked
        answer["trust"] = inside ? .string(trust.rawValue) : .string("not installed")
        answer["problems"] = .array(problems.map(JSONValue.string))
        var passed = true
        if let widget, problems.isEmpty, !args.has("no-run"), case .command = widget.data {
            if inside, !trust.runs {
                // A locked widget's command never runs, not even for a check; the runner would refuse it too.
                answer["run"] = .object(["skipped": .string("locked: Trust this widget on the Widgets page first")])
            } else {
                let (run, ran) = inside ? try await installedRun(widget, tools, peer: peer) : (try await testRun(folder, tools, peer: peer), widget)
                var entry: [String: JSONValue] = ["answer": .string(run.answer.kind), "ms": .number(Double(Int(run.duration / .milliseconds(1))))]
                switch run.answer {
                case .blocks(let blocks): entry["blocks"] = .number(Double(blocks.count))
                // What a run made from a password is never read back, as `ext run` holds it back; the widget asked about is
                // the one that ran. An error answers Pilot's reason, never what the program printed, which the run's
                // passwords may be in.
                case .data(let data): entry["data"] = inside && ran.settings.contains { $0.kind == .password } ? .string("withheld: it has a password setting") : data
                case .error(let reason, _): entry["error"] = .string(reason); passed = false
                }
                answer["run"] = .object(entry)
            }
        } else if let widget, problems.isEmpty, !args.has("no-run"), case .extensionPage(let extID) = widget.data {
            // It shows an extension's page, asked as the Extensions page asks it: whether that page is there to show.
            let found = await Task.detached { Extension.find(in: Extension.folder).extensions.first { $0.id == extID } }.value
            answer["run"] = .object(["skipped": .string(found?.shownSurface == nil ? "it shows extension \(extID)'s page, which is not installed here"
                                                                                   : "it shows extension \(extID)'s page, installed: Pilot asks it while the widget shows")])
        } else if let widget, !args.has("no-run") {
            answer["run"] = .object(["skipped": .string(problems.isEmpty ? "nothing to run: data is \(widget.data.label)" : "it fails the check")])
        }
        answer["ok"] = .bool(problems.isEmpty && passed)
        return .object(answer)
    }

    /// An installed widget that runs (made here or trusted) runs once after Allow, as ADR 0013 holds every script run; the
    /// question is read again after Allow from the folder as it is then, and the widget run is that one.
    private static func installedRun(_ widget: Widget, _ tools: WidgetTools, peer: ControlPeer?) async throws(ControlError) -> (WidgetRunner.Run, Widget) {
        let id = widget.id
        guard WidgetTools.runAsk(widget, outside: nil) != nil else { return (notRunnable(widget), widget) }
        // Never nil, so the gate always asks: a widget that cannot be read or run by then still asks, and fails after.
        let ask = { tools.store.widget(id).flatMap { WidgetTools.runAsk($0, outside: nil) } ?? ControlGate.Ask("Run widget", "\(id), which cannot run now") }
        return try await tools.gate.allow(ask(), peer: peer) { () throws(ControlError) in
            guard let now = tools.store.widget(id) else { throw ControlError(.denied, "\(id) changed while asking, so nothing ran") }
            return (await WidgetRunner.run(now, store: tools.store), now)
        }
    }

    /// A folder outside the Widgets folder runs once from a copy (the files checked, asked about and run are the copy's)
    /// after an Allow naming the program it starts, with a store of its own: the id is the folder's claim, so no saved
    /// settings, Keychain password or HOME of Sven's reaches it.
    private static func testRun(_ folder: URL, _ tools: WidgetTools, peer: ControlPeer?) async throws(ControlError) -> WidgetRunner.Run {
        // The question names the folder as typed: one whose path escaping would change (a line break, a hidden
        // character) could draw lines of its own above Pilot's, so it is renamed first.
        guard WidgetTools.isShowable(folder) else {
            throw ControlError(.badValue, "\(ControlGate.Ask.visible(folder.lastPathComponent)): rename the folder without line breaks, hidden characters or № to test it; nothing ran")
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "pilot-widget-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged: Widget.Staged
        do { staged = try await Widget.stage(folder, into: scratch) } catch {
            throw ControlError(.badValue, "\(folder.path) did not copy, so nothing ran: \(error.description)")
        }
        guard let ask = WidgetTools.runAsk(staged.widget, outside: folder) else { return notRunnable(staged.widget) }
        let home = scratch.appending(path: "home", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        return try await tools.gate.allow(ask, peer: peer) { () throws(ControlError) in
            await WidgetRunner.run(staged.widget, store: WidgetStore(root: scratch, passwords: false), grant: .allowed, environment: environment)
        }
    }

    /// `widget new`: a template folder in the caller's folder, never in Widgets; it changes no trust.
    private static func newWidget(_ args: ControlArguments, _ tools: WidgetTools, cwd: String?) throws(ControlError) -> JSONValue {
        let id = try args.word(1, "id")
        guard Widget.isID(id), !ReadyWidgets.isReady(id) else {
            throw ControlError(.badValue, "\(id) is not an id: lowercase letters and digits joined by single hyphens, not starting \(Widget.reservedPrefix) or \(ReadyWidgets.deskPrefix)")
        }
        guard let cwd else { throw ControlError(.badRequest, "no current folder to make it in") }
        let here = URL(fileURLWithPath: cwd, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let widgets = tools.store.widgets.resolvingSymlinksInPath().standardizedFileURL
        guard !here.pathComponents.starts(with: widgets.pathComponents) else {
            throw ControlError(.badValue, "make it outside Pilot's Widgets folder, then pilot widget install it")
        }
        let title = args.value("title") ?? ScriptCommand.title(file: id)
        guard Widget.isTitle(title) else { throw ControlError(.badValue, "--title must be plain text of 1 to 60 characters, without №") }
        let folder = here.appending(path: id, directoryHint: .isDirectory)
        let kit: Bool
        do { kit = try WidgetTemplates.make(id: id, title: title, kind: args.has("html") ? .html : .blocks, in: folder) } catch {
            throw ControlError(.badValue, "not made: \(error.localizedDescription)")
        }
        return .object(["id": .string(id), "folder": .string(folder.path), "kit": .bool(kit),
                        "next": .string("edit it\(kit ? " on Pilot's look kit (read pilot-kit.css first)" : ""), then pilot widget check \(folder.path), then pilot widget install \(folder.path)")])
    }

    /// `widget install` (made here, full power) and `widget import` (locked): a .zip unpacked through its checks first,
    /// then the folder copied once into Pilot's own staging copy, which the question describes and which is what moves
    /// into Widgets (WidgetStore.importStaged), so nothing changed after Allow installs. Only an Allow writes made here,
    /// and its question lists everything Trust this widget does.
    private static func installWidget(_ args: ControlArguments, _ tools: WidgetTools, cwd: String?, peer: ControlPeer?, locked: Bool) async throws(ControlError) -> JSONValue {
        let source = ExtensionTools.folder(try args.word(1, locked ? "folder or .zip" : "folder"), cwd: cwd).resolvingSymlinksInPath().standardizedFileURL
        if !locked, source.pathExtension.lowercased() == "zip" { throw ControlError(.badValue, "a .zip is from elsewhere: pilot widget import it") }
        // The question names the source as typed, and reading it outside the temporary folders and ~/Downloads waits on
        // Allow, as `widget check` does: Pilot reads with Full Disk Access, and a refusal names files it found.
        guard WidgetTools.isShowable(source) else {
            throw ControlError(.badValue, "\(ControlGate.Ask.visible(source.lastPathComponent)): rename it without line breaks, hidden characters or № first; nothing read")
        }
        try await tools.gate.allow(tools.readAsk(source, to: locked ? "import it as a widget" : "install it as a widget"), peer: peer) { () throws(ControlError) in }
        let opened: WidgetStore.Unpacked
        do { opened = try await tools.store.open(source) } catch { throw ControlError(.badValue, "\(source.lastPathComponent) not imported: \(error.description)") }
        defer { opened.remove() }
        let folder = opened.folder
        if tools.store.holds(folder) { throw ControlError(.badValue, "it is already in Pilot's Widgets folder") }
        // Read once, into a copy of Pilot's own: the question is about the copy, and the copy is what installs, so a file
        // changed after Allow changes nothing.
        let scratch = FileManager.default.temporaryDirectory.appending(path: "pilot-widget-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged: Widget.Staged
        do { staged = try await Widget.stage(folder, into: scratch) } catch { throw ControlError(.badValue, "not installed: \(error.description)") }
        let widget = staged.widget
        guard !ReadyWidgets.isReady(widget.id) else { throw ControlError(.badValue, "not installed: \(widget.id) is one of Pilot's ready widgets' ids") }
        // What waits under its id, read off the main thread: the Keychain may make it wait.
        let store = tools.store
        let inherits = await Task.detached { store.inherits(widget) }.value
        let ask = WidgetTools.installAsk(widget, from: source, locked: locked, replaces: tools.store.widget(widget.id) != nil, inherits: inherits)
        let installed: Widget = try await tools.gate.allow(ask, peer: peer) { () throws(ControlError) in
            do {
                let installed = try tools.store.importStaged(staged, expecting: widget.id, trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
                if !locked { try tools.store.setTrust(.madeHere, for: installed) }
                return installed
            } catch {
                throw ControlError(.badValue, "not installed: \((error as? Widget.Problems)?.description ?? error.localizedDescription)")
            }
        }
        tools.desk.widgetChanged(installed.id)
        return .object(["id": .string(installed.id), "folder": .string(installed.folder.path), "trust": .string(tools.store.trust(of: installed).rawValue)])
    }

    /// A run that never started: its program is not an executable file where the runner looks.
    private static func notRunnable(_ widget: Widget) -> WidgetRunner.Run {
        let word = if case .command(let argv, _) = widget.data { argv[0] } else { "its command" }
        return WidgetRunner.Run(answer: .error("\(word) is not an executable file in the widget's folder or on its PATH"), trust: .locked, duration: .zero)
    }
}
