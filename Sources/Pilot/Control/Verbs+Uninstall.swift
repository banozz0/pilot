import Foundation
import PilotCore

extension ControlVerbs {
    /// `pilot uninstall --list` (Q423): what General › Uninstall… lists, with sizes, read off the main actor.
    /// Read-only: moving anything to the Trash stays in the panel, under Sven's hands.
    func registerUninstall(measure: @escaping @Sendable () -> [UninstallItem] = { Uninstall.measured() }) {
        register(ControlVerb("uninstall", help: "Everything Pilot put on this Mac, grouped, with sizes; removing it is Pilot › Uninstall… only.",
                             usage: "pilot uninstall --list",
                             flags: [.init("list", help: "lists what the Uninstall panel would offer and how big each is", takesValue: false)]) { call throws(ControlError) in
            guard call.arguments().has("list") else {
                throw ControlError(.badValue, "pilot uninstall only lists (--list); moving to the Trash is Pilot › Uninstall…")
            }
            let items = await Task.detached { measure() }.value
            let home = NSHomeDirectory()
            return .object([
                "frees": .string(RemoveList.size(items.filter(\.tickedFirst).reduce(0) { $0 + $1.bytes })),
                "items": .array(items.map { item in
                    .object(["group": .string(item.group.title), "id": .string(item.id), "title": .string(item.title),
                             "detail": item.detail.map(JSONValue.string) ?? .null, "size": .string(RemoveList.size(item.bytes)),
                             "bytes": .number(Double(item.bytes)), "ticked": .bool(item.tickedFirst),
                             "paths": .array((item.urls + item.measured).map { .string(AppConfigs.tilde($0.path(percentEncoded: false), home: home)) })])
                }),
            ])
        })
    }
}
