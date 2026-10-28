import AppKit
import PilotCore

/// What `pilot config` and the `configs` and `instructions` collections reach (CLI W17): Configs and Configs › Agents,
/// read as the page reads them. Only files Pilot's own lists find are read, never a path the caller names.
/// The tests hand in a home folder, an editor and a Finder of their own, so Sven's files are never read and nothing opens.
@MainActor
final class ControlConfigs {
    var home: URL = ConfigsModule.home
    var editor: @MainActor () -> String = { EditorChoice.shared.app }
    var open: @MainActor (URL, String) -> Bool = AppsModule.open(_:in:)
    var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    /// The files a list finds, in the page's group order, and the known configs not on this Mac.
    func find(_ kind: ConfigsList.Kind) -> (found: [FoundConfig], missing: [AppConfig]) {
        let result = kind.find(home: home)
        return (ConfigGroup.allCases.flatMap { group in result.found.filter { $0.config.group == group } }, result.missing)
    }

    /// One card as the page shows it: name, group, path and real file written with ~, its chips, when it changed, and its
    /// first six lines with secret-looking values as dots.
    func row(_ found: FoundConfig, now: Date = .now) -> [String: JSONValue] {
        let config = found.config, real = found.real, modified = found.modified
        var head: [String] = []
        if case .text(let text, _) = AppConfigs.preview(real, cap: 4096) { head = AppConfigs.head(text, 6) }
        return ["id": .string(config.id), "name": .string(config.name), "group": .string(config.group.label), "present": .bool(true),
                "path": .string(AppConfigs.tilde(found.path.path, home: home.path)), "real": .string(AppConfigs.tilde(real.path, home: home.path)),
                "inDotfiles": .bool(FoundConfig.inDotfiles(real)), "generated": .bool(config.generated),
                "readOnly": .bool(config.readOnly),
                "modified": modified.map { .string($0.ISO8601Format()) } ?? .null,
                "changed": modified.map { .string(AppConfigs.changed($0, now: now)) } ?? .null,
                "head": .array(head.map(JSONValue.string))]
    }

    /// A known config not on this Mac, as Not on this Mac shows it, with the places Pilot looks for it.
    func missingRow(_ config: AppConfig) -> [String: JSONValue] {
        ["id": .string(config.id), "name": .string(config.name), "group": .string(config.group.label), "present": .bool(false),
         "paths": .array(config.paths.map { .string("~/" + $0) })]
    }

    func rows(_ kind: ConfigsList.Kind) -> JSONValue {
        let result = find(kind)
        return .array(result.found.map { .object(row($0)) } + result.missing.map { .object(missingRow($0)) })
    }

    /// The file an id names among the configs, then the instruction files; bad-value when no list has it or it is not here.
    func file(_ id: String) throws(ControlError) -> FoundConfig {
        for kind in [ConfigsList.Kind.configs, .instructions] {
            let result = find(kind)
            if let found = result.found.first(where: { $0.config.id == id }) { return found }
            if let config = result.missing.first(where: { $0.id == id }) {
                throw ControlError(.badValue, "no \(config.name) config on this Mac; Pilot looks for it at ~/\(config.paths[0])")
            }
        }
        throw ControlError(.badValue, "no config or instruction file \(id); pilot list configs and pilot list instructions list them")
    }

    /// The page's preview: the file's first 64 KB, ending on a line, secret-looking values as dots.
    func show(_ found: FoundConfig) throws(ControlError) -> [String: JSONValue] {
        var answer = row(found)
        switch AppConfigs.preview(found.real) {
        case .text(let text, let cut):
            answer["text"] = .string(text)
            answer["cut"] = .bool(cut)
            answer["hides"] = .bool(text.contains("••••••"))
            answer["cap"] = .number(Double(AppConfigs.previewCap))
        case .notText: throw ControlError(.badValue, "\(found.config.id) is not a text file")
        case .unreadable(let why): throw ControlError(.badValue, "could not read \(found.config.id): \(why)")
        }
        return answer
    }

    /// Open: the real file in the main editor, as the card's Open and `run configs.edit:<id>` do; Pilot's own files are
    /// read-only here, as on the page.
    func edit(_ found: FoundConfig) throws(ControlError) -> [String: JSONValue] {
        guard !found.config.readOnly else { throw ControlError(.badValue, "\(found.config.id) is Pilot's own file: show or reveal it, Pilot never opens it from Configs") }
        let editor = editor()
        guard open(found.real, editor) else { throw ControlError(.badValue, "the main editor is not installed; pick one on Default apps") }
        return ["id": .string(found.config.id), "opened": .bool(true), "real": .string(AppConfigs.tilde(found.real.path, home: home.path)),
                "editor": .string(AppsModule.appName(editor) ?? editor)]
    }
}

extension ControlVerbs {
    /// `pilot config show|open|reveal <id>` over a config or an instruction file, then the `configs` and `instructions`
    /// collections: Configs and Configs › Agents.
    func registerConfigs(_ app: ControlConfigs) {
        let words = ["show", "open", "reveal"]
        let index = JSONValue.array(words.map(JSONValue.string))
        let detail: [String: String] = [
            "show": "pilot config show <id>: the page's preview: the file's text up to \(AppConfigs.previewCap / 1024) KB (cut says it was cut), values of lines naming a token, secret, password or API key as dots (hides says some were).",
            "open": "pilot config open <id>: opens the real file in the main editor, as the card's Open does; not Pilot's own files (pilot-*), which are read-only.",
            "reveal": "pilot config reveal <id>: shows the real file in Finder, as the preview's Show in Finder does.",
        ]
        register(ControlVerb("config", help: "Previews a config or agent instruction file (secrets as dots), opens it in the main editor or shows it in Finder.",
                             usage: "pilot config [show <id> | open <id> | reveal <id>]", flags: [],
                             schema: {
                                 .object(["subcommands": index, "rowKey": .string("id"),
                                          "ids": .string("a row's id in pilot list configs or pilot list instructions")])
                             },
                             index: { .object(["subcommands": index]) },
                             detail: { detail[$0] }) { call throws(ControlError) in
            let args = call.arguments()
            let word = try args.word(0, "subcommand: \(words.joined(separator: ", "))")
            guard words.contains(word) else { throw ControlError(.badValue, "no config \(word); subcommands: \(words.joined(separator: ", "))") }
            let found = try app.file(try args.word(1, "id (pilot list configs or pilot list instructions lists them)"))
            switch word {
            case "show": return .object(try app.show(found))
            case "open": return .object(try app.edit(found))
            default:
                app.reveal(found.real)
                return .object(["id": .string(found.config.id), "revealed": .bool(true), "real": .string(AppConfigs.tilde(found.real.path, home: app.home.path))])
            }
        })
        registerConfigCollections(app)
    }
}
