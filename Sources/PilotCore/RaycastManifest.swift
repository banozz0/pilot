import Foundation

/// A Raycast-format extension (ADR 0017): a folder holding Raycast's `package.json` manifest and each command's built
/// JavaScript, `<name>.js` beside the manifest or in `dist/`, as Raycast's build writes it. Read as an Extension whose
/// commands run in pilot-ext-host (ExtensionRun.launch). T1 reads the id (`name`), title, description and the `view`
/// commands, each a list Pilot ranks, asked once per open; T3 the `no-view` commands, run as ADR 0010's are, and the
/// preferences, the extension's and each command's in one list, mapped onto Pilot's kinds (`preferences`). T11: a
/// command with `arguments` answers at Hyper+Space's root by its keyword, its name lowercased ("todo buy milk" fills its
/// first argument, as ADR 0010's keyword does; the host fills it from the run's input). T12: each `menu-bar` command is a
/// top-bar item, paced by its `interval` ("90s", "1m", "12h", "1d") held to 60 s to a day, 120 s without one; its command
/// is hidden from Hyper+Space, Binds and the Extensions page's list, and its host renders its MenuBarExtra as a bar line
/// for a tick or as the menu's rows while its popover is open.
public enum RaycastManifest {
    public static let name = "package.json"

    /// Whether `folder` is Raycast-format: a `package.json` and no `extension.json`, which always wins while both formats run.
    public static func holds(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appending(path: name).path) && !fm.fileExists(atPath: folder.appending(path: Extension.manifestName).path)
    }

    struct Manifest: Decodable {
        struct Command: Decodable {
            let name: String, title: String, mode: String, preferences: [Preference]?
            /// A `menu-bar` command's pace (T12); lenient, a wrong type reads as none.
            let interval: JSONValue?
            /// Lenient: only whether it lists any argument is read here; the host reads the rest.
            let arguments: JSONValue?
            var takesArguments: Bool { if case .array(let list)? = arguments { !list.isEmpty } else { false } }
        }
        /// A Raycast preference (developers.raycast.com, Manifest): its type one of Raycast's seven.
        struct Preference: Decodable {
            let name: String, type: String, title: String?, label: String?, description: String?, required: Bool?
            let `default`: JSONValue?, data: [Extension.Preference.Option]?
        }
        let name: String, title: String, commands: [Command], preferences: [Preference]?
        /// Lenient, as in extension.json: a wrong type reads as none.
        let description: JSONValue?, version: JSONValue?
    }

    /// Raycast's preference types as Pilot's (ADR 0017): `textfield` is text, `appPicker` an app, `directory` a folder;
    /// `password`, `checkbox`, `dropdown` and `file` keep their names. Any other type is the manifest's problem.
    static let kinds = ["textfield": "text", "appPicker": "app", "directory": "folder"]
        .merging(["password", "checkbox", "dropdown", "file"].map { ($0, $0) }) { old, _ in old }

    /// The extension's preferences, then each command's, as one list, as `getPreferenceValues()` answers them all: a
    /// name given twice keeps its first. Read and checked as an extension.json preference is, its title its `title`,
    /// else a checkbox's `label`, else its name.
    static func preferences(_ manifest: Manifest) throws -> [Extension.Preference] {
        var names = Set<String>()
        return try ((manifest.preferences ?? []) + manifest.commands.flatMap { $0.preferences ?? [] }).compactMap { p in
            guard names.insert(p.name).inserted else { return nil }
            guard let type = kinds[p.type] else { throw Extension.Problem.unknownPreferenceType(preference: p.name, type: p.type) }
            let title = [p.title, p.label].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? p.name
            return try Extension.Preference(Extension.Preference.Line(name: p.name, type: type, title: title, required: p.required,
                                                                      default: p.default, description: p.description, data: p.data))
        }
    }

    /// The extension folder a command's bundle belongs to: the bundle's own folder when it holds the manifest, else the
    /// one above (`dist/`), the only two places `bundle(_:in:)` finds one.
    static func folder(of bundle: URL) -> URL {
        let folder = bundle.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: folder.appending(path: name).path) ? folder : folder.deletingLastPathComponent()
    }

    /// The command file Raycast's build wrote for `command`, when it is a regular file inside `folder`.
    static func bundle(_ command: String, in folder: URL) -> URL? {
        let root = folder.standardizedFileURL.path
        for path in ["\(command).js", "dist/\(command).js"] {
            let url = folder.appending(path: path)
            var isFolder: ObjCBool = false
            guard url.standardizedFileURL.path.hasPrefix(root + "/"),
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { continue }
            return url
        }
        return nil
    }
}

extension Extension {
    /// The Raycast-format extension `folder` holds; throws its Problem when it is not one.
    init(raycast folder: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: folder.appending(path: RaycastManifest.name)) } catch { throw Problem.noManifest }
        let manifest: RaycastManifest.Manifest
        do { manifest = try JSONDecoder().decode(RaycastManifest.Manifest.self, from: data) }
        catch { throw Problem.unreadable("\(RaycastManifest.name) is not a Raycast manifest") }
        guard Self.isName(manifest.name) else { throw Problem.badID(manifest.name) }
        var names = Set<String>()
        commands = try manifest.commands.map { c in
            guard Self.isName(c.name) else { throw Problem.badCommandName(c.name) }
            guard names.insert(c.name).inserted else { throw Problem.duplicateCommand(c.name) }
            let mode: Mode
            switch c.mode {
            case "view", "menu-bar": mode = .list
            case "no-view": mode = .noView
            default: throw Problem.unknownMode(command: c.name, mode: c.mode)
            }
            guard let bundle = RaycastManifest.bundle(c.name, in: folder) else { throw Problem.missingProgram(command: c.name, run: "\(c.name).js") }
            let menuBar = c.mode == "menu-bar"
            return Command(id: CommandID(extension: manifest.name, command: c.name), title: c.title, icon: nil, mode: mode, filter: .pilot,
                           session: false, program: bundle, hidden: menuBar,
                           keyword: c.takesArguments && !menuBar ? Self.keyword(.string(c.name)) : nil, runtime: .raycast)
        }
        bars = zip(manifest.commands, commands).filter { $0.0.mode == "menu-bar" }.map { c, command in
            Surface(kind: .bar, command: command, every: Surface.raycastPace(c.interval))
        }
        guard !commands.isEmpty else { throw Problem.noCommands }
        id = manifest.name
        title = manifest.title
        icon = nil
        permissions = Permissions()
        preferences = try RaycastManifest.preferences(manifest)
        self.folder = folder
        version = if case .string(let v)? = manifest.version { v } else { nil }
        description = if case .string(let d)? = manifest.description { d.trimmingCharacters(in: .whitespacesAndNewlines) } else { "" }
        examples = []
        page = nil
        bar = bars.first
    }
}
