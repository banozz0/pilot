import Foundation

/// A Raycast-format extension (ADR 0017): a folder holding Raycast's `package.json` manifest and each command's built
/// JavaScript, `<name>.js` beside the manifest or in `dist/`, as Raycast's build writes it. Read as an Extension whose
/// commands run in pilot-ext-host (ExtensionRun.launch). T1 reads the id (`name`), title, description and the `view`
/// commands, each a list Pilot ranks, asked once per open. `no-view` commands (T3), preferences (T3), `menu-bar` commands
/// (T12), arguments (T11) and the `"pilot"` key (T13) come later; until then those commands are skipped.
public enum RaycastManifest {
    public static let name = "package.json"

    /// Whether `folder` is Raycast-format: a `package.json` and no `extension.json`, which always wins while both formats run.
    public static func holds(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appending(path: name).path) && !fm.fileExists(atPath: folder.appending(path: Extension.manifestName).path)
    }

    struct Manifest: Decodable {
        struct Command: Decodable { let name: String, title: String, mode: String }
        let name: String, title: String, commands: [Command]
        /// Lenient, as in extension.json: a wrong type reads as none.
        let description: JSONValue?, version: JSONValue?
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
        commands = try manifest.commands.compactMap { c in
            guard Self.isName(c.name) else { throw Problem.badCommandName(c.name) }
            guard names.insert(c.name).inserted else { throw Problem.duplicateCommand(c.name) }
            switch c.mode {
            case "view": break
            case "no-view", "menu-bar": return nil
            default: throw Problem.unknownMode(command: c.name, mode: c.mode)
            }
            guard let bundle = RaycastManifest.bundle(c.name, in: folder) else { throw Problem.missingProgram(command: c.name, run: "\(c.name).js") }
            return Command(id: CommandID(extension: manifest.name, command: c.name), title: c.title, icon: nil, mode: .list, filter: .pilot,
                           session: false, program: bundle, hidden: false, keyword: nil, runtime: .raycast)
        }
        guard !commands.isEmpty else { throw Problem.noCommands }
        id = manifest.name
        title = manifest.title
        icon = nil
        permissions = Permissions()
        preferences = []
        self.folder = folder
        version = if case .string(let v)? = manifest.version { v } else { nil }
        description = if case .string(let d)? = manifest.description { d.trimmingCharacters(in: .whitespacesAndNewlines) } else { "" }
        examples = []
        page = nil
        bar = nil
    }
}
