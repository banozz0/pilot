import Foundation

/// An extension (card agent-bo-95423242, ADR 0010): a folder in Pilot's Extensions folder holding `extension.json`,
/// which names its id, title, emoji icon, runtime, the permissions it declares and its commands. Each command is a
/// Hyper+Space row and a bind, `ext.<id>.<command>`, run as a child process speaking JSON lines (ExtensionRun). The
/// permissions are shown, not enforced: a process extension runs as Sven, as a script command does.
public struct Extension: Equatable, Sendable {
    /// What a command shows: nothing but a HUD line (no-view), a list Pilot draws (list, card agent-bo-95423243), or a
    /// detail, markdown with facts beside it (detail, card agent-bo-95423245).
    public enum Mode: String, Equatable, Sendable { case noView = "no-view", list, detail }

    public struct Command: Equatable, Sendable {
        public let id: CommandID, title: String, icon: String?, mode: Mode
        /// Who narrows a list command's rows; Pilot for a no-view one, which has none.
        public let filter: Filter
        /// A list whose program stays running while its view is open, answering a query message per search
        /// (ExtensionSession, card agent-bo-95423245); it filters itself.
        public let session: Bool
        /// The executable it runs, inside its extension's folder.
        public let program: URL
        /// Not a Hyper+Space row, not listed on Binds or the Extensions page, never an `ext.` bind: only its own extension
        /// runs it, through a `run` action or a timer's `end` (`"hidden": true`).
        public let hidden: Bool
        /// A no-view command's word at the root (`"keyword": "todo"`, 2026-10-10): "todo buy milk" answers with a row
        /// whose Return runs it, the rest of the search its `input`. It reaches a hidden command too; nil when it has none.
        public let keyword: String?

        public var name: String { id.command }
        public var actionID: String { id.actionID }
    }

    /// What the extension says it touches, in its own words: hosts, the clipboard, file paths, Pilot action ids.
    public struct Permissions: Equatable, Sendable, Decodable {
        public var network: [String] = [], clipboard = false, files: [String] = [], actions: [String] = []

        public init(network: [String] = [], clipboard: Bool = false, files: [String] = [], actions: [String] = []) {
            self.network = network; self.clipboard = clipboard; self.files = files; self.actions = actions
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            network = try c.decodeIfPresent([String].self, forKey: .network) ?? []
            clipboard = try c.decodeIfPresent(Bool.self, forKey: .clipboard) ?? false
            files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
            actions = try c.decodeIfPresent([String].self, forKey: .actions) ?? []
        }

        private enum CodingKeys: String, CodingKey { case network, clipboard, files, actions }
    }

    /// A setting the extension declares (card agent-bo-95423246): its value, set on the Extensions page and kept by
    /// ExtensionStorage, reaches every run message by `name`. A checkbox's value is a boolean, every other type's a string.
    public struct Preference: Equatable, Sendable {
        /// What kind of field sets it: a dropdown's options carry the title shown and the value passed.
        public enum Kind: Equatable, Sendable { case text, password, checkbox, dropdown([Option]), app, file, folder }

        public struct Option: Equatable, Sendable, Decodable {
            public let title: String, value: String
            public init(title: String, value: String) { self.title = title; self.value = value }
        }

        public let name: String, title: String, kind: Kind, required: Bool, `default`: JSONValue?, description: String?

        public init(name: String, title: String, kind: Kind, required: Bool = false, default: JSONValue? = nil, description: String? = nil) {
            self.name = name; self.title = title; self.kind = kind; self.required = required; self.default = `default`
            self.description = description
        }

        /// What the manifest says, checked by `init(_:)`.
        struct Line: Decodable {
            let name: String, type: String, title: String, required: Bool?, `default`: JSONValue?, description: String?, data: [Option]?
        }

        init(_ line: Line) throws {
            let kind: Kind
            switch line.type {
            case "text": kind = .text
            case "password": kind = .password
            case "checkbox": kind = .checkbox
            case "dropdown":
                guard let options = line.data, !options.isEmpty else { throw Problem.noOptions(preference: line.name) }
                kind = .dropdown(options)
            case "app": kind = .app
            case "file": kind = .file
            case "folder": kind = .folder
            default: throw Problem.unknownPreferenceType(preference: line.name, type: line.type)
            }
            guard line.name.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil else { throw Problem.badPreferenceName(line.name) }
            self.init(name: line.name, title: line.title, kind: kind, required: line.required ?? false, default: line.default,
                      description: line.description)
            if let given = line.default, !fits(given) { throw Problem.badDefault(preference: line.name) }
        }

        /// The value a run gets from `saved`: it when it fits, else the default; a checkbox with neither is false, any
        /// other type has none.
        public func resolved(_ saved: JSONValue?) -> JSONValue? {
            saved.flatMap { fits($0) ? $0 : nil } ?? `default` ?? (kind == .checkbox ? .bool(false) : nil)
        }

        /// A required preference without `value`, an empty string counting as none: its commands do not run.
        public func isMissing(_ value: JSONValue?) -> Bool { required && (value == nil || value == .string("")) }

        /// Whether `value` is one this preference takes: a boolean for a checkbox, one of its options for a dropdown, a string otherwise.
        public func fits(_ value: JSONValue) -> Bool {
            switch (kind, value) {
            case (.checkbox, .bool): true
            case (.checkbox, _): false
            case (.dropdown(let options), .string(let s)): options.contains { $0.value == s }
            case (_, .string): true
            default: false
            }
        }
    }

    /// Why a folder is not an extension, said in the log and, later, on the Extensions page.
    public enum Problem: Error, Equatable, Sendable {
        case noManifest, unreadable(String), badID(String), unknownRuntime(String), noCommands, badCommandName(String),
             duplicateCommand(String), unknownMode(command: String, mode: String), missingProgram(command: String, run: String),
             duplicateID(String), unknownFilter(command: String, filter: String), sessionNeedsOwnList(command: String),
             unknownPreferenceType(preference: String, type: String), noOptions(preference: String), duplicatePreference(String),
             badPreferenceName(String), badDefault(preference: String), unknownSurfaceCommand(surface: String, command: String)

        public var reason: String {
            switch self {
            case .noManifest: "no extension.json"
            case .unreadable(let why): "extension.json does not read: \(why)"
            case .badID(let id): "id \"\(id)\" must be lowercase letters, digits and hyphens"
            case .unknownRuntime(let r): "runtime \"\(r)\" is not one Pilot runs (process)"
            case .noCommands: "no commands"
            case .badCommandName(let n): "command name \"\(n)\" must be lowercase letters, digits and hyphens"
            case .duplicateCommand(let n): "two commands named \"\(n)\""
            case .unknownMode(let command, let mode): "command \(command): mode \"\(mode)\" is not no-view, list or detail"
            case .missingProgram(let command, let run): "command \(command): \(run) is not an executable file in the folder"
            case .duplicateID(let id): "another folder already has id \"\(id)\""
            case .unknownFilter(let command, let filter): "command \(command): filter \"\(filter)\" is not pilot or self"
            case .sessionNeedsOwnList(let command): "command \(command): a session must be a list that filters itself"
            case .unknownPreferenceType(let name, let type):
                "preference \(name): type \"\(type)\" is not text, password, checkbox, dropdown, app, file or folder"
            case .noOptions(let name): "preference \(name): a dropdown needs data, its options"
            case .duplicatePreference(let name): "two preferences named \"\(name)\""
            case .badPreferenceName(let name): "preference name \"\(name)\" must be letters, digits, hyphens and underscores"
            case .badDefault(let name): "preference \(name): its default does not fit its type"
            case .unknownSurfaceCommand(let surface, let command): "surfaces.\(surface): it has no command \"\(command)\""
            }
        }
    }

    public static let prefix = "ext."
    /// ~/Library/Application Support/Pilot/Extensions
    public static let folder = PilotFolder.support.appending(path: "Extensions")
    public static let manifestName = "extension.json"

    public let id: String, title: String, icon: String?, permissions: Permissions, preferences: [Preference], commands: [Command]
    public let folder: URL
    /// The manifest's `"version"`, read only by the extension catalogue to tell an update (2026-10-10); nil when it has
    /// none or it is not a string.
    public let version: String?
    /// What it is for in plain words, and one or two concrete uses ("Type prod, Return: an SSH session in Ghostty"), said
    /// on its Extensions card, the catalogue's and its Hyper+Space row (story 158); empty when the manifest says none.
    public let description: String, examples: [String]
    /// Its page in the app window and its top-bar item, each a command Pilot asks again on its pace (story 161); nil
    /// when the manifest declares none. The menu branch needs no declaring: every extension has one.
    public let page: Surface?, bar: Surface?

    /// At most this many examples are shown.
    public static let mostExamples = 2

    private struct Manifest: Decodable {
        struct Command: Decodable {
            let name: String, title: String, icon: String?, mode: String, run: String, filter: String?, session: Bool?, hidden: Bool?
            /// Lenient: anything but one word on a no-view command declares none.
            let keyword: JSONValue?
        }
        let id: String, title: String, icon: String?, runtime: String?, permissions: Permissions?, preferences: [Preference.Line]?
        let commands: [Command]
        /// Any JSON, so a number there never makes the folder unreadable.
        let version: JSONValue?
        /// Lenient too: a wrong type shows nothing rather than skipping the folder.
        let description: JSONValue?, examples: JSONValue?
        /// Lenient: a wrong type declares nothing; only a surface naming a command the extension lacks skips the folder.
        let surfaces: JSONValue?
    }

    /// The extension `folder` holds; throws its Problem when it is not one.
    public init(folder: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: folder.appending(path: Self.manifestName)) } catch { throw Problem.noManifest }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: data) } catch { throw Problem.unreadable(Self.describe(error)) }
        guard Self.isName(manifest.id) else { throw Problem.badID(manifest.id) }
        if let runtime = manifest.runtime, runtime != "process" { throw Problem.unknownRuntime(runtime) }
        guard !manifest.commands.isEmpty else { throw Problem.noCommands }
        let icon = Self.emoji(manifest.icon)
        var names = Set<String>()
        commands = try manifest.commands.map { c in
            guard Self.isName(c.name) else { throw Problem.badCommandName(c.name) }
            guard names.insert(c.name).inserted else { throw Problem.duplicateCommand(c.name) }
            guard let mode = Mode(rawValue: c.mode) else { throw Problem.unknownMode(command: c.name, mode: c.mode) }
            guard let program = Self.program(c.run, in: folder) else { throw Problem.missingProgram(command: c.name, run: c.run) }
            let session = c.session ?? false
            guard let filter = Filter(rawValue: c.filter ?? (session ? Filter.program : .pilot).rawValue) else {
                throw Problem.unknownFilter(command: c.name, filter: c.filter ?? "")
            }
            guard !session || (mode == .list && filter == .program) else { throw Problem.sessionNeedsOwnList(command: c.name) }
            return Command(id: CommandID(extension: manifest.id, command: c.name), title: c.title, icon: Self.emoji(c.icon) ?? icon,
                           mode: mode, filter: filter, session: session, program: program, hidden: c.hidden ?? false,
                           keyword: mode == .noView ? Self.keyword(c.keyword) : nil)
        }
        id = manifest.id
        title = manifest.title
        self.icon = icon
        permissions = manifest.permissions ?? Permissions()
        var preferenceNames = Set<String>()
        preferences = try (manifest.preferences ?? []).map { line in
            guard preferenceNames.insert(line.name).inserted else { throw Problem.duplicatePreference(line.name) }
            return try Preference(line)
        }
        self.folder = folder
        version = if case .string(let v)? = manifest.version { v } else { nil }
        description = if case .string(let d)? = manifest.description { d.trimmingCharacters(in: .whitespacesAndNewlines) } else { "" }
        examples = Self.examples(manifest.examples)
        (page, bar) = try Self.surfaces(manifest.surfaces, commands: commands)
    }

    /// The manifest's or the catalogue's `examples`: its non-empty strings, at most `mostExamples`.
    static func examples(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return Array(items.compactMap { if case .string(let s) = $0, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { s } else { nil } }
            .prefix(mostExamples))
    }

    /// The manifest's `keyword`, lowercased, when it is one word of letters, digits and hyphens.
    static func keyword(_ value: JSONValue?) -> String? {
        guard case .string(let word)? = value, word.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9-]*/) != nil else { return nil }
        return word.lowercased()
    }

    /// A folder that is not an extension, by its name, and why.
    public struct Broken: Equatable, Sendable {
        public let folder: String, problem: Problem
        public init(folder: String, problem: Problem) { self.folder = folder; self.problem = problem }
    }

    public struct Found: Equatable, Sendable {
        public let extensions: [Extension], broken: [Broken]
        public init(extensions: [Extension], broken: [Broken]) { self.extensions = extensions; self.broken = broken }
    }

    /// The extensions in `folder` by title, read in folder-name order so the first of two with one id wins, and the
    /// folders that are not, hidden ones and loose files left out; none when it is missing.
    public static func find(in folder: URL = folder) -> Found {
        let folders = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: .skipsHiddenFiles)) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var extensions: [Extension] = [], broken: [Broken] = [], ids = Set<String>()
        for url in folders {
            let name = url.lastPathComponent
            do {
                // Named again: the listing's URL ends in "/", so it never equalled the folder named the same way.
                let ext = try Extension(folder: folder.appending(path: name))
                guard ids.insert(ext.id).inserted else { throw Problem.duplicateID(ext.id) }
                extensions.append(ext)
            } catch {
                broken.append(Broken(folder: name, problem: error as? Problem ?? .unreadable(describe(error))))
            }
        }
        return Found(extensions: extensions.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, broken: broken)
    }

    /// The extension and command an `ext.` id names.
    public struct CommandID: Equatable, Sendable {
        public let `extension`: String, command: String
        public init(extension: String, command: String) { self.extension = `extension`; self.command = command }

        public var actionID: String { Extension.prefix + `extension` + "." + command }

        /// The run of a keyword's answer: the id, a slash no name holds, then `input` as JSON, as a script's arguments.
        public func actionID(input: String) -> String {
            actionID + "/" + String(decoding: (try? JSONEncoder().encode(input)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
    }

    /// The extension and command `id` names, any input it carries left aside; nil for any other id.
    public static func command(inAction id: String) -> CommandID? {
        guard id.hasPrefix(prefix) else { return nil }
        let parts = id.dropFirst(prefix.count).prefix { $0 != "/" }.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ isName(String($0)) }) else { return nil }
        return CommandID(extension: String(parts[0]), command: String(parts[1]))
    }

    /// The text a keyword's answer carries (`actionID(input:)`); nil when it carries none (a bind, the plain row).
    public static func input(inAction id: String) -> String? {
        guard command(inAction: id) != nil, let slash = id.firstIndex(of: "/") else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(id[id.index(after: slash)...].utf8))
    }

    /// The command `id` names, as `command(_:in:)` finds it; for an id carrying input, the keyword command it names,
    /// hidden or not.
    public static func command(inAction id: String, in extensions: [Extension]) -> (Extension, Command)? {
        guard let named = command(inAction: id) else { return nil }
        guard input(inAction: id) != nil else { return command(named, in: extensions) }
        guard let ext = extensions.first(where: { $0.id == named.extension }),
              let command = ext.commands.first(where: { $0.id == named && $0.keyword != nil }) else { return nil }
        return (ext, command)
    }

    /// The root's answer to a keyword, a space and words ("todo buy milk", 2026-10-10): a row titled after its command
    /// and the words, Return running it with them as `input`. Read from the extensions the menu read as it opened, so
    /// typing runs nothing. The first extension, by title, with that keyword answers.
    public static func answers(for query: String, in extensions: [Extension]) -> [MenuEntry] {
        let search = query.drop(while: \.isWhitespace)
        guard let space = search.firstIndex(of: " ") else { return [] }
        let word = search[..<space].lowercased(), text = search[space...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        for ext in extensions {
            guard let command = ext.commands.first(where: { $0.keyword == word }) else { continue }
            return [MenuEntry(title: "\(command.title): \(text)", target: .action(command.id.actionID(input: text)), detail: ext.title,
                              isAnswer: true, icon: .command(emoji: command.icon))]
        }
        return []
    }

    /// Its no-view command `name`: what a run names.
    public func noView(_ name: String) -> Command? { commands.first { $0.name == name && $0.mode == .noView } }

    /// Its list or detail command `name`: what a push names.
    public func view(_ name: String) -> Command? { commands.first { $0.name == name && $0.mode != .noView } }

    /// Its commands a person sees and binds: every one but the hidden.
    public var listed: [Command] { commands.filter { !$0.hidden } }

    /// The command `id` names among `extensions`, with its extension; never a hidden one, which is no `ext.` action.
    public static func command(_ id: CommandID, in extensions: [Extension]) -> (Extension, Command)? {
        guard let ext = extensions.first(where: { $0.id == id.extension }), let command = ext.listed.first(where: { $0.id == id })
        else { return nil }
        return (ext, command)
    }

    /// What the menu lists: `actions` with every listed command among them, a bound one's info replaced by its own so it wears
    /// its icon and is found by its extension's title.
    public static func actions(_ actions: [BindsPage.ActionInfo], with extensions: [Extension]) -> [BindsPage.ActionInfo] {
        BindsPage.adding(extensions.flatMap(\.actionInfos), to: actions)
    }

    /// Its listed commands as menu and Binds rows: each wears its icon and is found by its extension's title.
    var actionInfos: [BindsPage.ActionInfo] {
        listed.map { BindsPage.ActionInfo(id: $0.actionID, label: $0.title, module: Module.drive.rawValue, icon: .command(emoji: $0.icon), keywords: title) }
    }

    /// Hyper+Space's Extensions branch (story 158): a sub-branch per extension with a listed command, titled after it,
    /// wearing its icon and saying what it is for; each holds its commands (`extras`, by sub-branch), then Browse
    /// catalogue closes the branch. An extension whose commands are all hidden has no sub-branch.
    public static func menu(_ extensions: [Extension], catalogue: String) -> (branches: [MenuBranch: [MenuEntry]], extras: [MenuBranch: [BindsPage.ActionInfo]]) {
        var extras: [MenuBranch: [BindsPage.ActionInfo]] = [:], rows: [MenuEntry] = []
        for ext in extensions {
            let sub = MenuLayout.extensionBranch(ext.title), commands = ext.actionInfos
            guard !commands.isEmpty, extras[sub] == nil else { continue }   // of two with one title, the first's
            var row = MenuEntry(title: ext.title, target: .branch(sub), home: .extensions, keywords: ext.id,
                                subtitle: ext.description.isEmpty ? nil : ext.description, icon: .command(emoji: ext.icon))
            row.extensionID = ext.id
            rows.append(row)
            extras[sub] = commands
        }
        // Found at the root by the catalogue action's own keywords.
        extras[.extensions] = [BindsPage.ActionInfo(id: catalogue, label: MenuLayout.browseCatalogue, module: Module.drive.rawValue)]
        return (rows.isEmpty ? [:] : [.extensions: rows], extras)
    }

    /// An id or a command name: lowercase letters, digits and hyphens, so `ext.<id>.<command>` splits one way.
    static func isName(_ s: String) -> Bool { s.wholeMatch(of: /[a-z0-9][a-z0-9-]*/) != nil }

    /// `icon` when it is one emoji, the only icon Pilot draws for now.
    private static func emoji(_ icon: String?) -> String? { icon.flatMap { ScriptCommand.isEmoji($0) ? $0 : nil } }

    /// `run` inside `folder` when it is an executable regular file there; nil when it is missing or leaves the folder.
    private static func program(_ run: String, in folder: URL) -> URL? {
        let root = folder.standardizedFileURL.path
        let url = folder.appending(path: run).standardizedFileURL
        var isFolder: ObjCBool = false
        guard !run.hasPrefix("/"), url.path.hasPrefix(root + "/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue,
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return folder.appending(path: run)
    }

    /// A decoding error in a line: what was missing or wrong, not Foundation's paragraph.
    private static func describe(_ error: any Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _)?: "\(key.stringValue) is missing"
        case .typeMismatch(_, let c)?, .valueNotFound(_, let c)?: "\(c.codingPath.map(\.stringValue).joined(separator: ".")) has the wrong type"
        case .dataCorrupted?: "not JSON"
        default: error.localizedDescription
        }
    }
}
