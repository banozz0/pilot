import Clipboard
import PilotCore

extension ControlVerbs {
    /// The Clipboard page's two lists (CLI W11): Never record from, written through the history as the page writes it,
    /// and the tags, whose delete asks Allow (the panel confirms it; the items stay). `pilot clip tag-edit` renames and
    /// recolours a tag; tagging an item makes one.
    func registerClipboardCollections(_ tools: ClipboardTools) {
        func ignored(_ edit: (inout [String]) -> Void) {
            var settings = tools.history.settings
            edit(&settings.ignoredApps)
            tools.history.apply(settings)
        }
        register(ControlCollection("clipboard-ignored", help: "Apps whose copies the clipboard history never keeps (the Clipboard page's Never record from). add takes an installed app's bundle id; remove takes one off.",
                                   fields: [.init("app", help: "an installed app's bundle id, e.g. com.bitwarden.desktop")],
                                   rowKey: "app",
                                   list: { .array(tools.history.settings.ignoredApps.map(Self.ignoredRow)) },
                                   add: { args throws(ControlError) in
            let app = args.value("app")!
            guard tools.installed(app) else { throw ControlError(.badValue, "--app: no app \(app) is installed; give an installed app's bundle id") }
            if !tools.history.settings.ignoredApps.contains(app) { ignored { $0.append(app) } }
            return Self.ignoredRow(app)
        }, remove: { args throws(ControlError) in
            let app = try args.word(0, "app")
            guard tools.history.settings.ignoredApps.contains(app) else {
                throw ControlError(.badValue, "\(app) is not on the list; pilot list clipboard-ignored lists it")
            }
            ignored { $0.removeAll { $0 == app } }
            return .object(["removed": .string(app), "apps": .array(tools.history.settings.ignoredApps.map(JSONValue.string))])
        }))

        register(ControlCollection("clipboard-tags", help: "The clipboard's tags, each name and colour (1 to \(ClipTag.colours)). remove deletes one after Allow; its items stay. pilot clip tag tags items, pilot clip tag-edit renames or recolours.",
                                   rowKey: "name", asks: [.remove],
                                   list: { () throws(ControlError) in
            let store = try tools.store()
            return .array(try tools.attempt("clipboard tags") { try store.tags() }.map(Self.tagRow))
        }, askerAdd: nil, askerRemove: { args, peer throws(ControlError) in
            let store = try tools.store()
            let tag = try Self.clipTag(args.word(0, "tag"), store, tools)
            @MainActor func ask() -> ControlGate.Ask {
                let still = ((try? store.tags()) ?? []).contains(tag)
                return ControlGate.Ask("Delete clipboard tag #\(tag.name)", still ? "every item loses it; the items stay" : "the tag is gone already")
            }
            return try await tools.gate.allow(ask(), peer: peer) { () throws(ControlError) in
                try tools.attempt("clipboard tag delete") { try store.deleteTag(tag.id) }
                tools.history.changedFromControl()
                cliplog.notice("clip tag delete \(tag.id), from the pilot command")
                return .object(["deleted": .string(tag.name), "tags": .array(try tools.attempt("clipboard tags") { try store.tags() }.map { .string($0.name) })])
            }
        }))
    }

    private static func ignoredRow(_ app: String) -> JSONValue {
        .object(["app": .string(app), "name": .string(AppsModule.displayName(app))])
    }
}
