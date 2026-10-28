import Foundation
import PilotCore

extension ControlVerbs {
    /// Open with's file kinds (CLI W16, D4: Sven 2026-10-11): the app each kind of file and link opens, read through
    /// DefaultAppsModel as the page reads it on appear, and set as a pick there sets it, after Allow, since it changes a
    /// macOS default. Read again on every request: nothing is read at launch.
    func registerDefaultApps(_ s: AppCollectionStores) {
        register(ControlCollection("default-apps", help: "The app each kind of file and link opens (Open with: web links, plain text and Markdown first, then All kinds); add sets one after Allow.",
                                   fields: [.init("kind", help: "a row's kind, e.g. web, public.plain-text, net.daringfireball.markdown"),
                                            .init("app", help: "a bundle id from that row's choices")],
                                   rowKey: "kind", asks: [.add],
                                   list: {
            let model = Self.defaultAppsModel(s)
            return .array(Self.kinds.map { .object(Self.row($0.kind, group: $0.group, model)) })
        }, askerAdd: { args, peer throws(ControlError) in
            let id = args.value("kind")!, app = args.value("app")!
            guard let (kind, group) = Self.kinds.first(where: { $0.kind.id == id }) else {
                throw ControlError(.badValue, "--kind: no kind \(id); pilot list default-apps lists them")
            }
            let model = Self.defaultAppsModel(s)
            guard let row = model.rows[kind.id], let choice = row.choices.first(where: { $0.bundle == app }) else {
                throw ControlError(.badValue, "--app: \(app) is not one of the apps that open \(kind.title); the row's choices are")
            }
            if row.current == app { return .object(Self.row(kind, group: group, model)) }
            // Read again once Allow is pressed: a default changed meanwhile denies.
            let ask = { () -> ControlGate.Ask in
                let now = kind.handlers.first.flatMap(s.defaultApps.current).map(s.defaultApps.name) ?? "none"
                return ControlGate.Ask("Set default app", "\(kind.title): \(now) → \(choice.name)\(kind.confirmNote.map { ". \($0)" } ?? "")")
            }
            return try await s.gate.allow(ask(), peer: peer) { () throws(ControlError) in
                await model.change(kind, to: app)
                return .object(Self.row(kind, group: group, model))
            }
        }, askerRemove: nil))
    }

    /// The kinds with a card of their own on the page (OpenWithPage.mainCards): web links, plain text, Markdown.
    private static let mainKinds = ["web", "public.plain-text", "net.daringfireball.markdown"]

    /// Every kind in the page's order: the main cards, then All kinds by group.
    private static let kinds: [(kind: FileKind, group: String)] = {
        let all = FileKinds.groups.flatMap { group in group.kinds.map { (kind: $0, group: group.name) } }
        return mainKinds.compactMap { id in all.first { $0.kind.id == id } } + all.filter { !mainKinds.contains($0.kind.id) }
    }()

    private static func defaultAppsModel(_ s: AppCollectionStores) -> DefaultAppsModel {
        let model = DefaultAppsModel(system: s.defaultApps, forget: s.forget)
        model.load()
        return model
    }

    /// A kind as its card or row shows it: the default now, the apps that open it, and why the last change did not take.
    private static func row(_ kind: FileKind, group: String, _ model: DefaultAppsModel) -> [String: JSONValue] {
        let shown = model.rows[kind.id]
        let choices = shown?.choices ?? []
        var row: [String: JSONValue] = ["kind": .string(kind.id), "name": .string(kind.title), "group": .string(group),
                                        "main": .bool(mainKinds.contains(kind.id)),
                                        "current": shown?.current.map(JSONValue.string) ?? .null,
                                        "choices": .array(choices.map { .object(["bundle": .string($0.bundle), "name": .string($0.name)]) })]
        row["covers"] = kind.detail.map(JSONValue.string)
        row["currentName"] = shown?.current.flatMap { c in choices.first { $0.bundle == c }?.name }.map(JSONValue.string)
        row["message"] = shown?.message.map(JSONValue.string)
        row["confirmNote"] = kind.confirmNote.map(JSONValue.string)
        return row
    }
}
