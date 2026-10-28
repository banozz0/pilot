import Foundation
import PilotCore

/// `pilot ext catalogue|get` (CLI W15): the Extensions page's Catalogue tab, read through the model it shares with the
/// menu's catalogue, so the page's card shows an install the command started. The page installs on one click; the
/// command asks Allow first, as `ext install` does, naming every file from the index the install checks each file
/// against, and the commands of the extension.json that check pins.
extension ControlVerbs {
    /// `ext catalogue [<query>] [--refresh]`: the entries the page shows for that search, each with its standing.
    static func catalogue(_ args: ControlArguments, _ tools: ExtensionTools) async throws(ControlError) -> JSONValue {
        let model = tools.catalogue
        try await Self.readCatalogue(model, refresh: args.has("refresh"))
        let query = args.positional.dropFirst().joined(separator: " ")
        let entries = model.entries(query)
        return .object(["count": .number(Double(entries.count)), "query": .string(query), "entries": .array(entries.map { entry in
            let standing = model.standing(of: entry)
            var o: [String: JSONValue] = [
                "id": .string(entry.id), "title": .string(entry.title), "version": .string(entry.version), "description": .string(entry.description),
                "examples": .array(entry.examples.map(JSONValue.string)), "requires": .array(entry.requires.map(JSONValue.string)),
                "commands": .array(entry.commands.map { .object(["name": .string($0.name), "title": .string($0.title), "mode": .string($0.mode.rawValue)]) }),
                "touches": .array(ExtensionsPage.permissions(entry.permissions, label: tools.label).map { .string($0.text) }),
                "standing": .string(standing.word), "button": .string(ExtensionCatalogue.button(entry, standing)),
                "files": .number(Double(entry.files.count)), "size": .number(Double(entry.size)),
            ]
            o["icon"] = entry.icon.map(JSONValue.string)
            o["needs"] = ExtensionCatalogue.needs(entry).map(JSONValue.string)
            o["installedVersion"] = model.installed[entry.id].flatMap { $0.version.map(JSONValue.string) }
            o["busy"] = model.busy[entry.id].map(JSONValue.string)
            o["failed"] = model.failures[entry.id].map(JSONValue.string)
            return .object(o)
        })])
    }

    /// `ext get <id>`: installs a catalogue entry, or updates the copy installed to its version, after Allow.
    static func getExtension(_ args: ControlArguments, _ tools: ExtensionTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let id = try args.word(1, "id")
        let model = tools.catalogue
        try await Self.readCatalogue(model, refresh: false)
        guard let entry = model.index?.entry(id) else { throw ControlError(.badValue, ExtensionCatalogue.Problem.notListed(id).reason + " pilot ext catalogue lists it.") }
        let had = model.installed[id]
        guard model.standing(of: entry) != .installed else {
            return .object(["installed": .string(id), "version": .string(entry.version), "changed": .bool(false)])
        }
        guard model.busy[id] == nil else { throw ControlError(.taken, "\(id) is \(model.busy[id]!.lowercased()) already") }
        // A folder named the id holding something else is refused before asking, as ext install refuses it.
        let folder = tools.extensions
        if let taken = await Task.detached(operation: { () -> String? in
            do { _ = try ExtensionCheck.replaced(id, in: folder); return nil } catch { return ExtensionCatalogue.Problem.reason(error) }
        }).value {
            throw ControlError(.badValue, taken + " Nothing asked.")
        }
        let commands = try await tools.pinnedCommands(entry)
        return try await tools.gate.allow(tools.catalogueAsk(entry, had, commands), peer: peer) { () throws(ControlError) in
            guard await model.install(entry) != nil else { throw ControlError(.taken, "\(id) is busy already") }
            if let why = model.failures[id] { throw ControlError(.badValue, "\(entry.title) was not \(had == nil ? "installed" : "updated"): \(why)") }
            log.notice("ext get: \(id, privacy: .public) \(entry.version, privacy: .public) from the catalogue, from the pilot command")
            guard let done = try? await tools.require(id) else {
                throw ControlError(.badValue, "\(id) was \(had == nil ? "installed" : "updated") but does not read back from Extensions; pilot ext broken says why")
            }
            var answer: [String: JSONValue] = ["installed": .string(id), "version": .string(done.version ?? "none"), "changed": .bool(true),
                                               "folder": .string(done.folder.path), "commands": .array(done.listed.map { .string($0.actionID) })]
            answer["updatedFrom"] = had.map { .string($0.version ?? "no version") }
            return .object(answer)
        }
    }

    /// The index read as the page reads it (kept ten minutes, read again with `refresh`), or not-ready with why it was not.
    private static func readCatalogue(_ model: ExtensionCatalogueModel, refresh: Bool) async throws(ControlError) {
        if refresh { await model.refresh() } else { await model.open() }
        if case .failed(let why) = model.load {
            throw ControlError(.notReady, "\(why) Try again: pilot ext catalogue --refresh")
        }
    }
}

extension ExtensionTools {
    /// A catalogue install's question, from the index entry the install checks every file against: where it comes from,
    /// the executable files and the rest, the commands, and what it replaces.
    /// The commands of the extension.json an install of `entry` pins, fetched now and held to the index's sha256 (Moody on
    /// W15), each as `ext.<id>.<name> (<mode>)`, a hidden one marked: what the question names is what installs. An index
    /// whose commands differ from that manifest's shown ones is refused before asking.
    func pinnedCommands(_ entry: ExtensionCatalogue.Entry) async throws(ControlError) -> [String] {
        func refused(_ why: String) -> ControlError { ControlError(.badValue, "\(entry.id) not installed: \(why) Nothing asked.") }
        guard let file = entry.files.first(where: { $0.path == Extension.manifestName }) else { throw refused("its catalogue entry lists no \(Extension.manifestName).") }
        let source = catalogue.installer.source
        let fetched = await Task.detached { () -> Result<Data, any Error> in
            await Result { try await source.fetch("extensions/\(entry.id)/\(file.path)", min(file.size, ExtensionCatalogue.fileLimit)) }
        }.value
        let data: Data
        switch fetched {
        case .success(let fetched): data = fetched
        case .failure(let error): throw ControlError(.notReady, ExtensionCatalogue.Problem.reason(error) + " Nothing asked.")
        }
        guard data.count == file.size, ExtensionCatalogue.sha256(data) == file.sha256 else { throw refused(ExtensionCatalogue.Problem.mismatch(path: file.path).reason) }
        guard case .object(let manifest)? = try? JSONDecoder().decode(JSONValue.self, from: data), case .array(let raw)? = manifest["commands"] else {
            throw refused("its \(Extension.manifestName) does not read.")
        }
        let pinned = raw.compactMap { command -> (name: String, title: String, mode: String, hidden: Bool)? in
            guard case .object(let c) = command, case .string(let name)? = c["name"], case .string(let title)? = c["title"], case .string(let mode)? = c["mode"] else { return nil }
            return (name, title, mode, c["hidden"] == .bool(true))
        }
        // The index lists the commands that show (the catalogue's build-index.py leaves hidden ones out); every one runs as Sven.
        guard pinned.count == raw.count, pinned.filter({ !$0.hidden }).map({ "\($0.name) \($0.title) \($0.mode)" }) == entry.commands.map({ "\($0.name) \($0.title) \($0.mode.rawValue)" }) else {
            throw refused("the catalogue's index lists other commands than its \(Extension.manifestName) declares.")
        }
        return pinned.map { "\(Extension.prefix)\(entry.id).\($0.name) (\($0.mode)\($0.hidden ? ", hidden" : ""))" }
    }

    func catalogueAsk(_ entry: ExtensionCatalogue.Entry, _ had: ExtensionCatalogue.Installed?, _ commands: [String]) -> ControlGate.Ask {
        let programs = entry.files.filter(\.executable).map { ControlGate.Ask.visible($0.path) }
        let others = entry.files.filter { !$0.executable }.map { ControlGate.Ask.visible($0.path) }
        let replaces = had.map { "updates \($0.version ?? "the copy") at \(ControlGate.Ask.visible($0.folder.path)) to \(entry.version), which goes to the Trash; its data and settings stay" }
            ?? "replaces nothing: no extension \(entry.id) is installed"
        return .install(.extension, """
            \(entry.id) (\(ControlGate.Ask.visible(entry.title)) \(ControlGate.Ask.visible(entry.version))) from Pilot's catalogue, github.com/\(ExtensionCatalogue.repo)
            into \(ControlGate.Ask.visible(extensions.appending(path: entry.id).path))
            programs: \(programs.isEmpty ? "none marked executable" : programs.joined(separator: ", "))
            other files: \(others.isEmpty ? "none" : others.joined(separator: ", ")); \(entry.files.count) files in all, \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
            commands, run as you: \(commands.joined(separator: ", "))
            \(replaces)
            """)
    }
}

extension ExtensionCatalogue.Standing {
    var word: String {
        switch self {
        case .install: "install"
        case .installed: "installed"
        case .update: "update"
        }
    }
}
