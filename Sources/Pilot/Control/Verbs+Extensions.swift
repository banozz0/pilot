import Foundation
import PilotCore

/// What `pilot ext` reaches (AI helper T10): the templates in Pilot's Resources, the Extensions folder, the Trash and the
/// Allow gate. The tests hand in their own, so nothing lands in Sven's Extensions folder or his Trash.
@MainActor
final class ExtensionTools {
    var templates: URL? = Bundle.main.resourceURL.map { $0.appending(path: "ext-template") }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    var extensions = Extension.folder
    /// ExtensionData: what a remove leaves.
    var data = ExtensionStorage.dataFolder
    var trash: @Sendable (URL) throws -> Void = FileOps.trashNow
    var gate = AllowPrompt.gate
    /// Where a run's cache folder is made and where its passwords are kept (CLI W15).
    var cache = ExtensionStorage.cacheFolder
    var keychain: any ExtensionKeychain = SystemKeychain()
    /// Whether ext run, page and act read back an extension with a password set: only the sandbox host sets it, whose
    /// keychain is a throwaway file or none (KeychainItem.store); for a real run the refusal stands.
    var readsBackPasswords = false
    /// The catalogue the page and the menu read; a test's reads a fixture.
    var catalogue = ExtensionCatalogueModel.shared
    /// A Pilot action's label, for "Runs Pilot actions: …".
    var label: @Sendable (String) -> String? = { id in MainActor.assumeIsolated { Engine.shared?.registry.actions[id]?.label } }
    /// Opens extension `id`'s own page (true) or its card on the Extensions page.
    var open: (String, Bool) -> Void = { id, page in
        if page { AppWindowController.shared.openExtensionPage(id) } else { AppWindowController.shared.open(AppPlace(.extensions), extension: id) }
    }
    /// The folders `ext test` and `ext install` read without asking (Moody on T14): the temporary folders an agent works
    /// in and ~/Downloads. Any other folder is read only after Allow, since Pilot reads with Full Disk Access.
    var readable: [URL] = [FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first, FileManager.default.temporaryDirectory,
                           URL(fileURLWithPath: "/tmp")].compactMap { $0?.resolvingSymlinksInPath().standardizedFileURL }

    /// `path` against the caller's folder.
    static func folder(_ path: String, cwd: String?) -> URL {
        URL(fileURLWithPath: path, relativeTo: cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }).standardizedFileURL
    }

    /// Whether `url` is the Extensions folder or inside it, by file identity. Its deepest existing folder is resolved
    /// whole first, since a URL's resource values describe a symlink itself, never what it points to, and a link into a
    /// subfolder leads up through the folders it points into, not the ones it sits in. Then each folder up that real path
    /// is compared with the Extensions folder itself, so a firmlink (/System/Volumes/Data/…) or another spelling of a
    /// name is the same folder, as the volume sees it. No Extensions folder yet holds nothing.
    func holds(_ url: URL) -> Bool {
        func identity(_ u: URL) -> (any NSObjectProtocol)? {
            (try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? any NSObjectProtocol
        }
        guard let root = identity(extensions) else { return false }
        var folder = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" { folder.deleteLastPathComponent() }
        folder = folder.resolvingSymlinksInPath()
        while true {
            if let id = identity(folder), id.isEqual(root) { return true }
            guard folder.path != "/" else { return false }
            folder.deleteLastPathComponent()
        }
    }

    func installed(_ id: String) -> Extension? { Extension.find(in: extensions).extensions.first { $0.id == id } }

    /// The commands as their action ids with the file each runs, a hidden one marked: what runs as Sven once it is in.
    /// Raw, as `named` is: the question escapes each of its lines once (AllowPromptView.thing).
    static func commands(_ ext: Extension) -> String {
        ext.commands.map { "\($0.actionID) (\($0.mode.rawValue)\($0.hidden ? ", hidden" : "")) runs \(program($0, in: ext))" }
            .joined(separator: ", ")
    }

    /// The file `command` runs, by its path inside its extension's folder.
    static func program(_ command: Extension.Command, in ext: Extension) -> String {
        String(command.program.standardizedFileURL.path.dropFirst(ext.folder.standardizedFileURL.path.count + 1))
    }

    static func named(_ ext: Extension) -> String { "\(ext.id) (\(ext.title)\(ext.version.map { " \($0)" } ?? ""))" }

    /// `named` as a question's replaces line shows an installed copy: its title cut to 80 Unicode scalars, its version to 64, title and
    /// version with every control or hidden scalar written out (ControlGate.Ask.visible), since a folder installed from
    /// GitHub wrote them.
    static func shown(_ ext: Extension) -> String {
        let title = String(String.UnicodeScalarView(ext.title.unicodeScalars.prefix(80)))
        let version = ext.version.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(64))) }
        return "\(ext.id) (\(oneLine(title))\(version.map { " \(oneLine($0))" } ?? ""))"
    }

    // A summary's words (ControlGate.Ask.summed), raw, as the prompt escapes them once, each line kept one line. Pilot
    // speaks in them: an extension is named by its id, which the check holds to a-z, 0-9 and hyphens, and a version only
    // when it reads as one, never by its own title (review 1); and whatever the caller or the extension names, a path or
    // a file, comes last on its line, after a colon, so none of Pilot's words follow it.

    /// "weather 1.3.0": the id, then the version when it reads as one.
    static func titled(_ id: String, _ version: String?) -> String { id + (checked(version).map { " \($0)" } ?? "") }

    /// `version` when it reads as one (digits and dots), else nil.
    static func checked(_ version: String?) -> String? { version.flatMap { ExtensionCatalogue.Version($0) == nil ? nil : $0 } }

    /// "Runs its own program as you: main.py", or each command once for a test; up to three files named, then "…".
    static func runs(_ programs: [String], commands: Int, once: Bool = false) -> String {
        let what = once ? "each of its \(commands) command\(commands == 1 ? "" : "s") once" : programs.isEmpty
            ? "its \(commands) command\(commands == 1 ? "" : "s")" : "its own program\(programs.count == 1 ? "" : "s")"
        guard !programs.isEmpty else { return "Runs \(what) as you" }
        return "Runs \(what) as you: " + programs.prefix(3).joined(separator: ", ") + (programs.count > 3 ? ", …" : "")
    }

    /// What an install does to the copies in, before where it comes from.
    static func trashes(_ copies: Int) -> String {
        copies == 1 ? "The installed copy goes to the Trash, its data and settings stay."
            : "The \(copies) installed copies go to the Trash, their data and settings stay."
    }

    /// The install's question: the folder it was read from, every file it copies (the files commands run and every executable first, then
    /// the rest, which a program may still read or import), what runs, and the folders it sends to the Trash, those read
    /// again after Allow. A question too long to show whole is denied unasked by the gate, never cut. The files are
    /// `entry`'s, read from the staged copy `ext` was read from, so a source changed after the question changes nothing.
    func installAsk(_ ext: Extension, _ entry: ExtensionCatalogue.Entry, from source: URL) -> ControlGate.Ask {
        let runs = Dictionary(grouping: ext.commands) { Self.program($0, in: ext) }
        let programs = entry.files.filter { runs[$0.path] != nil || $0.executable }.map { file in
            file.path + (runs[file.path].map { " (runs \($0.map(\.name).joined(separator: ", ")))" } ?? " (executable)")
        }
        let others = entry.files.filter { runs[$0.path] == nil && !$0.executable }.map(\.path)
        let (replaces, headline, fromLine) = replacing(ext.id, ext.version, from: "From the folder: \(source.path)")
        // Every program the whole names, the ones commands run and every other executable.
        let named = entry.files.filter { runs[$0.path] != nil || $0.executable }.map(\.path)
        // A line each, raw: the question escapes each once and keeps it one line, a break typed in a title or a path only
        // marked ⏎ (AllowPromptView.thing), so none starts a line of its own.
        return ControlGate.Ask.install(.extension, lines: [
            "\(Self.named(ext)) from \(source.path)",
            "into \(extensions.appending(path: ext.id).path)",
            "programs: \(programs.joined(separator: ", "))",
            "other files: \(others.isEmpty ? "none" : others.joined(separator: ", ")); \(entry.files.count) files in all, \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))",
            "commands, run as you: \(Self.commands(ext))",
            replaces,
        ]).summed(headline, [Self.runs(named, commands: ext.commands.count), fromLine])
    }

    /// What an install of `id` replaces, in the question's words: the whole's line, the headline, and the summary's
    /// line ending in `from`.
    func replacing(_ id: String, _ newVersion: String?, from: String) -> (replaces: String, headline: String, fromLine: String) {
        let version = Self.checked(newVersion) ?? "this copy"
        do {
            let old = try ExtensionCheck.replaced(id, in: extensions)
            let replaces = old.isEmpty ? "replaces nothing: no extension \(id) is installed" : "replaces " + old.map { folder in
                ((try? Extension(folder: folder)).map(Self.shown) ?? id) + " at " + folder.path
            }.joined(separator: " and ") + ", which go\(old.count == 1 ? "es" : "") to the Trash; its data and settings stay"
            // A folder says what it likes about itself, so a copy in is only ever replaced, never "updated"; the one copy's
            // version is named, two or more are only counted.
            let was = old.count == 1 ? (try? Extension(folder: old[0]))?.version : nil
            return (replaces, old.isEmpty ? "Install extension \(Self.titled(id, newVersion))?" : "Replace extension \(Self.titled(id, was)) with \(version)?",
                    old.isEmpty ? from : "\(Self.trashes(old.count)) \(from)")
        } catch {
            return (ExtensionCatalogue.Problem.reason(error), "Replace what is in place of extension \(id) with \(version)?",
                    "Its place in Extensions holds something else; Show details says what. \(from)")
        }
    }

    /// A GitHub install's question (ADR 0017, T6), asked once its folder is fetched and before anything is downloaded or
    /// built: where it comes from, its commands and preferences, what is downloaded after Allow and how each is checked,
    /// and what it replaces. Past what the prompt shows whole (ControlGate.Ask.longest), the commands, preferences and
    /// packages are counted instead of named, so a big extension is still asked; one still too long (long folder paths)
    /// is denied unasked, as any question is. Every remote word it shows is held to a rule by the host and again by
    /// GitHubInstall.fetch before this is asked: the id and command names (the id rule), the modes (Raycast's three), the
    /// preference names (a letter, then letters, digits, _ and -), the tree (40 hex digits), each package's key, real name
    /// and version (npm's); the version only when it reads as one (`checked`). The title is the one free text: at most 80
    /// Unicode scalars, last on its line, escaped here with ControlGate.Ask.visible so the question's text (which the
    /// gate's denials and the pilot command repeat) never carries a control code; an installed copy's title on the
    /// replaces line likewise (`shown`).
    func githubAsk(_ plan: GitHubInstall.Plan, tools: URL, whole: Bool = true) -> (ask: ControlGate.Ask, whole: Bool) {
        let modes = Dictionary(grouping: plan.commands, by: \.mode).sorted { $0.key < $1.key }.map { "\($0.value.count) \($0.key)" }
        let commands = whole ? plan.commands.map { "ext.\(plan.id).\($0.name) (\($0.mode))" }.joined(separator: ", ")
            : "\(plan.commands.count) (\(modes.joined(separator: ", ")))"
        let preferences = whole ? (plan.preferences.isEmpty ? "none" : plan.preferences.joined(separator: ", ")) : "\(plan.preferences.count)"
        let esbuild = plan.esbuild == "reuse" ? "esbuild \(plan.esbuildVersion) is already in \(tools.path), reused"
            : "esbuild \(plan.esbuildVersion) (\(ByteCountFormatter.string(fromByteCount: Int64(plan.esbuildBytes), countStyle: .file)), checked by its pinned sha512) into \(tools.path)"
        let packages = "\(plan.packages.count) package\(plan.packages.count == 1 ? "" : "s"), each checked by its lockfile's sha512, no install script run"
            + (whole && !plan.packages.isEmpty ? ": " + plan.packages.map { package in
                let place = package.key.dropFirst("node_modules/".count), alias = place.components(separatedBy: "/node_modules/").last ?? ""
                return "\(place)@\(package.version)" + (alias == package.name ? "" : " (\(package.name))")
            }.joined(separator: ", ") : "")
        let (replaces, headline, fromLine) = replacing(plan.id, plan.version, from: "From GitHub: \(plan.source)")
        let ask = ControlGate.Ask.install(.extension, lines: [
            "\(Self.titled(plan.id, plan.version)) from \(plan.source), tree \(plan.tree.prefix(12)), its title: \(oneLine(plan.title))",
            "into \(extensions.appending(path: plan.id).path)",
            "commands, run as you in Pilot's extension host: \(commands)",
            "preferences: \(preferences)",
            "fetched to ask this: \(plan.files) files, \(ByteCountFormatter.string(fromByteCount: Int64(plan.bytes), countStyle: .file)) from GitHub, each checked by its git blob hash",
            "downloads from registry.npmjs.org after Allow: \(esbuild); \(packages)",
            "built with esbuild on this Mac, then checked as an extension; the temporary folder goes after",
            replaces,
        ]).summed(headline, ["Runs its \(plan.commands.count) command\(plan.commands.count == 1 ? "" : "s") as you, built on this Mac. \(fromLine)",
                             "Downloads \(plan.esbuild == "reuse" ? "" : "esbuild and ")\(plan.packages.count) package\(plan.packages.count == 1 ? "" : "s") from registry.npmjs.org, each hash checked"])
        let shown = ask.text + "\n" + headline
        guard whole, shown.unicodeScalars.count > ControlGate.Ask.longest || shown.unicodeScalars.count { $0 == "\n" } > ControlGate.Ask.mostLines else { return (ask, whole) }
        return githubAsk(plan, tools: tools, whole: false)
    }

    /// Read again after Allow: an extension changed or gone while asking denies.
    func removeAsk(_ id: String) -> ControlGate.Ask {
        guard let ext = installed(id) else { return .remove(.extension, "\(id), not installed") }
        return ControlGate.Ask.remove(.extension, lines: [
            "\(Self.named(ext)) at \(ext.folder.path) goes to the Trash",
            "commands that go with it: \(Self.commands(ext))",
            "its data and settings stay in \(data.appending(path: id).path)",
        ]).summed("Remove extension \(Self.titled(ext.id, ext.version))?",
                        ["It goes to the Trash with its \(ext.commands.count) command\(ext.commands.count == 1 ? "" : "s"); its data and settings stay"])
    }

    /// The question reading `folder` asks before the check reads it, nil inside `readable`. The folder is compared with
    /// every link resolved, so a link in the temporary folder to elsewhere asks.
    func readAsk(_ folder: URL) -> ControlGate.Ask? {
        let real = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard !readable.contains(where: { real.starts(with: $0.pathComponents) }) else { return nil }
        return ControlGate.Ask("Read folder", "Pilot reads \(folder.path) to check it as an extension; only the check's summary comes back")
    }

    /// `folder` read into a temporary copy once Pilot may read it (Moody on W15): its path resolved once, asked about
    /// unless inside `readable`, and the copy made from that resolved path, which skips every link inside. The path must
    /// still resolve to itself after the copy, so a folder swapped for a link while it was read is refused. Bad-value
    /// says why a folder does not stage, `verb` naming what did not happen.
    func stage(_ folder: URL, peer: ControlPeer?, verb: String) async throws(ControlError) -> ExtensionCheck.Staged {
        let real = folder.resolvingSymlinksInPath().standardizedFileURL
        try await gate.allow(readAsk(real), peer: peer) { () throws(ControlError) in }
        let staged: ExtensionCheck.Staged
        do { staged = try await ExtensionCheck.stage(real) } catch {
            throw ControlError(.badValue, "\(folder.path) not \(verb): \(ExtensionCatalogue.Problem.reason(error)) Nothing asked.")
        }
        guard real.resolvingSymlinksInPath().standardizedFileURL == real else {
            staged.remove()
            throw ControlError(.denied, "\(folder.path) changed while it was read, so it was not \(verb)")
        }
        return staged
    }

    /// `ext test`'s question: each command runs once as Sven, so it asks as a script does.
    static func testAsk(_ ext: Extension, from source: URL) -> ControlGate.Ask {
        let programs = Array(Set(ext.commands.map { program($0, in: ext) })).sorted()
        return ControlGate.Ask("Test extension", lines: [
            "run each command of \(named(ext)) once, as you, from a copy of \(source.path), HOME in a temporary folder",
            "commands: \(commands(ext))",
        ]).summed("Test extension \(titled(ext.id, ext.version))?",
                        [runs(programs, commands: ext.commands.count, once: true),
                         "HOME in a temporary folder, from a copy of the folder: \(source.path)"])
    }
}

extension ControlVerbs {
    static let extSubcommands: [(name: String, usage: String, help: String)] = [
        ("new", "ext new <id> [--mode <mode>] [--title <title>] [--dir <folder>]", "Makes an extension folder from a template, outside Pilot's Extensions folder."),
        ("test", "ext test [<folder>] [--check]", "Checks a folder as an extension, then runs each command once after Allow; --check only checks. A folder outside the temporary folders and ~/Downloads is read only after Allow."),
        ("install", "ext install <folder> | ext install github:<owner>/<repo>/<folder>", "Copies a checked folder into Pilot's Extensions folder after Allow. A Raycast extension's GitHub folder is fetched (each file checked by its git blob hash) and asked about, then built on this Mac without Node: esbuild downloaded once into Tools and the lockfile's packages from the npm registry, each checked by its sha512, no install script run."),
        ("remove", "ext remove <id>", "Moves an installed extension to the Trash after Allow; its data and settings stay."),
        ("show", "ext show <id>", "An installed extension's card: version, description, examples, what it says it touches, commands, the preferences it still needs."),
        ("broken", "ext broken", "The folders in Extensions that do not read as extensions, each with why."),
        ("open", "ext open <id> [--card]", "Opens its own page in Pilot's window, or its card on the Extensions page."),
        ("run", "ext run <action> [--query <text>] [--input <text>]", "Runs a command once after Allow and answers what it printed (none of its actions performed); nothing is read back while a password preference is set."),
        ("page", "ext page <id>", "Asks its page command once after Allow and answers its blocks, as its page and Home block show them; nothing is read back while a password preference is set."),
        ("act", "ext act <id> <action> [--input <text>] [--answer <text>] [--alt] | ext act <id> <row> [--command <name>] | ext act <id> --handler <id> [--command <name>] [--then <row>|escape]", "Presses one of its page's actions after Allow, named as ext page shows it (a button, a row or row/action, a link, row/Move up, an input box's action): runs its command and answers what it said and the page after. --input is an input box's text, --alt its Option+Return, --answer what the action asks. An open, copy, paste, Pilot action, timer or alert is answered, not performed. A Raycast-format extension, which has no page, presses a row's callback (row or row/action, as ext run shows it, or --handler by its id) in its first view, or --command's, with its host kept open: it answers the rows before and after; --then presses again in the view the first press left, escape going back a view."),
        ("gaps", "ext gaps [<id>]", "The Raycast APIs a Raycast-format extension used that Pilot lacks (ADR 0017), as its runs recorded them: each with how many runs used it, when last and from which commands, the most used first; every such extension without an id."),
        ("catalogue", "ext catalogue [<query>] [--refresh]", "Pilot's extension catalogue, searched, each entry with install, update or installed; --refresh reads it again."),
        ("get", "ext get <id>", "Installs a catalogue extension, or updates the installed one to the catalogue's version, after Allow."),
        ("publish", "ext publish <id>", "Sends an installed extension to the catalogue as a pull request, from the clone set in extensions.catalogueClone, after Allow; a debug build sends from a fork on your GitHub account when you cannot push to the catalogue's repo."),
    ]

    /// `pilot ext …`: make an extension from a template, check and run it, install it from a folder or Pilot's catalogue or
    /// take it out, read its card, set its preferences (the ext-prefs collection), read what its commands answer and press its
    /// page's actions. Install, remove, a test's runs, a run, a page and an act wait on Allow.
    func registerExtensions(_ tools: ExtensionTools) {
        let modes = ExtensionTemplate.allCases.map(\.rawValue), subcommands = Self.extSubcommands.map(\.name)
        register(ControlVerb("ext", help: "Makes, tests, installs (from a folder or the catalogue), shows, runs and removes extensions, and presses their pages' actions; what runs or installs asks first. Preferences: pilot list ext-prefs.",
                             usage: "pilot " + Self.extSubcommands.map(\.usage).joined(separator: " | "),
                             flags: [.init("mode", help: "ext new: \(modes.joined(separator: ", "))"), .init("title", help: "ext new: its title"),
                                     .init("dir", help: "ext new: the folder to make it in"), .init("check", help: "ext test: only check, run nothing", takesValue: false),
                                     .init("query", help: "ext run: a list's search"), .init("input", help: "ext run: the text handed to the command; ext act: an input box's text"),
                                     .init("answer", help: "ext act: the answer to what the action asks (text, a choice, or yes)"),
                                     .init("alt", help: "ext act: an input box's Option+Return action", takesValue: false),
                                     .init("command", help: "ext act: a Raycast-format extension's view to press in (its first by default)"),
                                     .init("handler", help: "ext act: a Raycast-format callback by its handler id, as ext run shows it"),
                                     .init("then", help: "ext act: a second press in the same Raycast-format host (a row, row/action, or escape)"),
                                     .init("card", help: "ext open: its card, not its page", takesValue: false),
                                     .init("refresh", help: "ext catalogue: read the catalogue again", takesValue: false)],
                             schema: { .object(["modes": .array(modes.map(JSONValue.string)), "subcommands": .array(Self.extSubcommands.map { .object(["name": .string($0.name), "usage": .string("pilot " + $0.usage), "help": .string($0.help)]) }),
                                                "collections": .array([.string("extensions"), .string("ext-prefs")])]) },
                             index: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             detail: { word throws(ControlError) in Self.extSubcommands.first { $0.name == word }.map { "pilot \($0.usage)\n\($0.help)" } }) { call throws(ControlError) in
            let args = call.arguments()
            switch try args.word(0, "subcommand: \(subcommands.joined(separator: ", "))") {
            case "new": return try Self.newExtension(args, tools, modes: modes, cwd: call.cwd)
            case "test": return try await Self.testExtension(args, tools, cwd: call.cwd, peer: call.peer)
            case "install": return try await Self.installExtension(args, tools, cwd: call.cwd, peer: call.peer)
            case "remove": return try await Self.removeExtension(args, tools, peer: call.peer)
            case "show": return try await Self.showExtension(args, tools)
            case "broken": return await Self.brokenExtensions(tools)
            case "open": return try await Self.openExtension(args, tools)
            case "run": return try await Self.runExtension(args, tools, peer: call.peer)
            case "page": return try await Self.pageExtension(args, tools, peer: call.peer)
            case "act": return try await Self.actExtension(args, tools, peer: call.peer)
            case "gaps": return try await Self.extensionGaps(args, tools)
            case "catalogue": return try await Self.catalogue(args, tools)
            case "get": return try await Self.getExtension(args, tools, peer: call.peer)
            case "publish":
                let id = try args.word(1, "id")
                guard let ext = tools.installed(id) else { throw ControlError(.badValue, "no extension \(id) is installed") }
                let plan = try await CataloguePublish.plan(.extensionPack(ext))
                return try await tools.gate.allow(plan.ask, peer: call.peer) { () throws(ControlError) in try await CataloguePublish.publish(plan) }
            case let other: throw ControlError(.badValue, "no ext \(other); subcommands: \(subcommands.joined(separator: ", "))")
            }
        })
        registerExtensionPrefs(tools)
    }

    /// What pilot-ext-host's gap recorder wrote for one extension, ExtensionData/<id>/gaps.json (ADR 0017, T3).
    private struct GapFile: Decodable {
        struct Gap: Decodable { let count: Int?, last: String?, commands: [String]? }
        let gaps: [String: Gap]?
    }

    /// `ext gaps [<id>]`: the gaps an installed Raycast-format extension's runs recorded, most used first, then by name.
    /// Reads Pilot's own file, beside the extension's preferences, so nothing runs and nothing asks.
    private static func extensionGaps(_ args: ControlArguments, _ tools: ExtensionTools) async throws(ControlError) -> JSONValue {
        let id = args.positional.dropFirst().first
        let chosen = if let id { [try await tools.require(id)] } else {
            await tools.found().extensions.filter { $0.commands.contains { $0.runtime == .raycast } }
        }
        let answers: [JSONValue] = chosen.map { ext in
            let data = try? Data(contentsOf: tools.data.appending(path: "\(ext.id)/gaps.json"))
            let gaps = (data.flatMap { try? JSONDecoder().decode(GapFile.self, from: $0) }?.gaps ?? [:])
                .sorted { ($0.value.count ?? 0, $1.key) > ($1.value.count ?? 0, $0.key) }
            return .object(["extension": .string(ext.id), "gaps": .array(gaps.map { api, gap in
                var o: [String: JSONValue] = ["api": .string(api), "runs": .number(Double(gap.count ?? 0)),
                                              "commands": .array((gap.commands ?? []).map(JSONValue.string))]
                o["last"] = gap.last.map(JSONValue.string)
                return .object(o)
            })])
        }
        return id == nil ? .object(["extensions": .array(answers)]) : answers[0]
    }

    private static func newExtension(_ args: ControlArguments, _ tools: ExtensionTools, modes: [String], cwd: String?) throws(ControlError) -> JSONValue {
        let id = try args.word(1, "id")
        let name = args.value("mode") ?? ExtensionTemplate.list.rawValue
        guard let mode = ExtensionTemplate(rawValue: name) else { throw ControlError(.badValue, "no mode \(name); modes: \(modes.joined(separator: ", "))") }
        guard let templates = tools.templates else { throw ControlError(.badValue, "this Pilot has no ext-template folder in its Resources") }
        let parent = ExtensionTools.folder(args.value("dir") ?? ".", cwd: cwd)
        // A folder made in Pilot's Extensions folder would be live at the next menu open with no Allow (ADR 0013).
        guard !tools.holds(parent.appending(path: id)) else {
            throw ControlError(.badValue, "\(parent.path) is in Pilot's Extensions folder; make it elsewhere, then pilot ext install it")
        }
        do {
            let made = try mode.make(id: id, title: args.value("title"), templates: templates, in: parent)
            return .object(["made": .string(made.path), "id": .string(id), "mode": .string(mode.rawValue),
                            "next": .string("pilot ext test \(made.path)")])
        } catch let problem as Extension.Problem {
            throw ControlError(.badValue, problem.reason)
        } catch {
            throw ControlError(.badValue, "\(parent.appending(path: id).path) not made: \(error.localizedDescription)")
        }
    }

    private static func testExtension(_ args: ControlArguments, _ tools: ExtensionTools, cwd: String?, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let folder = ExtensionTools.folder(args.positional.dropFirst().first ?? ".", cwd: cwd)
        // The check and the runs read a copy, never the folder again.
        let staged = try await tools.stage(folder, peer: peer, verb: "tested")
        defer { staged.remove() }
        guard let ext = staged.ext else {
            throw ControlError(.badValue, "\(folder.path) fails the check, so nothing ran:\n" + staged.problems.map { "- \($0)" }.joined(separator: "\n"))
        }
        var answer: [String: JSONValue] = ["extension": .string(ext.id), "folder": .string(folder.path), "check": .string("passed")]
        guard !args.has("check") else { return .object(answer) }
        // The commands asked about are the ones run.
        let runs = try await tools.gate.allow(ExtensionTools.testAsk(ext, from: staged.source), peer: peer) { () throws(ControlError) in await ExtensionCheck.runs(ext) }
        guard runs.allSatisfy(\.ok) else {
            throw ControlError(.badValue, "\(runs.count { !$0.ok }) of \(runs.count) runs failed:\n" + runs.map { run in
                "- \(run.command) (\(run.ranAs)): \(run.ok ? "ok" : run.why ?? "failed")\(run.first.isEmpty ? "" : "; first: \(run.first)")"
            }.joined(separator: "\n"))
        }
        answer["runs"] = .array(runs.map { run in
            var entry: [String: JSONValue] = ["command": .string(run.command), "as": .string(run.ranAs), "first": .string(run.first)]
            entry["why"] = run.why.map(JSONValue.string)
            return .object(entry)
        })
        return .object(answer)
    }

    private static func installExtension(_ args: ControlArguments, _ tools: ExtensionTools, cwd: String?, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        if let github = GitHubInstall(try args.word(1, "folder"), extensions: tools.extensions) {
            return try await installFromGitHub(github, tools, peer: peer)
        }
        let folder = ExtensionTools.folder(try args.word(1, "folder"), cwd: cwd)
        // Read once into a copy: the check, the question and the install all read the copy's bytes.
        let staged = try await tools.stage(folder, peer: peer, verb: "installed")
        defer { staged.remove() }
        guard let ext = staged.ext, let entry = staged.entry else {
            throw ControlError(.badValue, "\(folder.path) fails the check, so nothing was installed:\n" + staged.problems.map { "- \($0)" }.joined(separator: "\n"))
        }
        // A folder named the id holding something else is refused before asking, so Allow never starts an install bound to fail.
        do { _ = try ExtensionCheck.replaced(ext.id, in: tools.extensions) } catch {
            throw ControlError(.badValue, ExtensionCatalogue.Problem.reason(error) + " Nothing asked.")
        }
        return try await tools.gate.allow(tools.installAsk(ext, entry, from: folder), peer: peer) { () throws(ControlError) in
            let old = (try? ExtensionCheck.replaced(ext.id, in: tools.extensions)) ?? []
            let done: Extension
            do { done = try await ExtensionCheck.install(staged, extensions: tools.extensions, trash: tools.trash) }
            catch { throw ControlError(.badValue, ExtensionCatalogue.Problem.reason(error)) }
            log.notice("ext install: \(done.id, privacy: .public) from \(folder.path, privacy: .public), from the pilot command")
            return .object(["installed": .string(done.id), "folder": .string(done.folder.path),
                            "commands": .array(done.listed.map { .string($0.actionID) }),
                            "replaced": .array(old.map { .string($0.path) })])
        }
    }

    /// `ext install github:<owner>/<repo>/<folder>` (ADR 0017, T6): the folder fetched and planned, asked about, then
    /// built and installed as a checked local folder. The workspace goes whatever happens: success, a refusal or a No.
    /// Answers every request made, with the host it went to and the check it passed.
    private static func installFromGitHub(_ github: GitHubInstall, _ tools: ExtensionTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        defer { github.remove() }
        func refused(_ error: any Error, _ what: String) -> ControlError {
            ControlError(.badValue, "github:\(oneLine(github.spec)) not \(what): \(oneLine(ExtensionCatalogue.Problem.reason(error)))")
        }
        let plan: GitHubInstall.Plan, fetched: [GitHubInstall.Fetched]
        do { (plan, fetched) = try await github.fetch() } catch { throw refused(error, "fetched, nothing asked") }
        do { _ = try ExtensionCheck.replaced(plan.id, in: tools.extensions) } catch {
            throw ControlError(.badValue, oneLine(ExtensionCatalogue.Problem.reason(error)) + " Nothing asked.")
        }
        // Built again after Allow, as the local route's is: an extension installed or removed under this id while asking
        // changes the question, and the gate then denies.
        return try await tools.gate.allow(tools.githubAsk(plan, tools: github.tools).ask, peer: peer) { () throws(ControlError) in
            let whole = tools.githubAsk(plan, tools: github.tools).whole
            // What the question named as replaced, the gate having just read it again; the build takes a while, so it is
            // read once more after it, and a difference installs nothing.
            let named: [URL]
            do { named = try ExtensionCheck.replaced(plan.id, in: tools.extensions) } catch { throw refused(error, "built, nothing installed") }
            let built: GitHubInstall.Built, more: [GitHubInstall.Fetched]
            do { (built, more) = try await github.build(plan) } catch { throw refused(error, "built, nothing installed") }
            let staged: ExtensionCheck.Staged
            do { staged = try await ExtensionCheck.stage(URL(filePath: built.folder)) } catch { throw refused(error, "installed") }
            defer { staged.remove() }
            guard let ext = staged.ext, staged.entry != nil, ext.id == plan.id else {
                throw ControlError(.badValue, "github:\(oneLine(github.spec)) built, but fails the check, so nothing was installed:\n"
                                   + (staged.problems.isEmpty ? ["it is not extension \(plan.id)"] : staged.problems).map { "- \(oneLine($0))" }.joined(separator: "\n"))
            }
            let old: [URL]
            do { old = try ExtensionCheck.replaced(ext.id, in: tools.extensions) } catch { throw refused(error, "installed") }
            guard old.map(\.standardizedFileURL.path) == named.map(\.standardizedFileURL.path) else {
                throw ControlError(.badValue, "github:\(oneLine(github.spec)) built, but what it replaces changed while building "
                                   + "(asked: \(named.isEmpty ? "nothing" : named.map(\.path).joined(separator: ", ")); now: "
                                   + "\(old.isEmpty ? "nothing" : old.map(\.path).joined(separator: ", "))), so nothing was installed")
            }
            let done: Extension
            do { done = try await ExtensionCheck.install(staged, extensions: tools.extensions, trash: tools.trash) } catch { throw refused(error, "installed") }
            log.notice("ext install: \(done.id, privacy: .public) from github:\(github.spec, privacy: .public), from the pilot command")
            return .object(["installed": .string(done.id), "folder": .string(done.folder.path), "from": .string(plan.source), "tree": .string(plan.tree),
                            "commands": .array(done.listed.map { .string($0.actionID) }), "replaced": .array(old.map { .string($0.path) }),
                            "question": .string(whole ? "whole" : "counted"),
                            "esbuild": .object(["was": .string(built.esbuild), "version": .string(built.esbuildVersion), "path": .string(built.esbuildPath)]),
                            "fetched": .array((fetched + more).map { f in
                                .object(["host": .string(f.host), "what": .string(oneLine(f.what)), "bytes": .number(Double(f.bytes)), "check": .string(f.check)])
                            })])
        }
    }

    private static func removeExtension(_ args: ControlArguments, _ tools: ExtensionTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let id = try args.word(1, "id")
        guard tools.installed(id) != nil else { throw ControlError(.badValue, "no extension \(id) is installed") }
        return try await tools.gate.allow(tools.removeAsk(id), peer: peer) { () throws(ControlError) in
            let title: String
            do { title = try ExtensionInstaller(extensions: tools.extensions, trash: tools.trash).remove(id) } catch {
                throw ControlError(.badValue, ExtensionCatalogue.Problem.reason(error))
            }
            log.notice("ext remove: \(id, privacy: .public), from the pilot command")
            return .object(["removed": .string(id), "title": .string(title),
                            "kept": .string(tools.data.appending(path: id).path)])
        }
    }
}

/// A remote word as one line of T6's output: ControlGate.Ask.visible, its written-out break (⏎ before a real new line) kept as
/// ⏎ alone, so a word never starts a line of the question, a refusal or the answer.
private func oneLine(_ text: String) -> String {
    ControlGate.Ask.visible(text).replacingOccurrences(of: "⏎\n", with: "⏎", options: .literal)
}
