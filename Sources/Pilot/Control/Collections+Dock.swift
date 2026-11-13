import Foundation
import PilotCore

extension ControlVerbs {
    /// The dock (spec pilot-dock): `pilot dock` reads its switch, size, room and icons (the pins read from the macOS Dock,
    /// never written, then the running apps); `dock-widgets` lists, adds and removes its widgets, the top bar's items,
    /// extensions' items and groups by the bar tray's names.
    func registerDock(_ dock: @escaping @Sendable @MainActor () -> DockController? = { Engine.shared?.dock },
                      windows: @escaping @Sendable @MainActor () -> [AeroWindow] = { Engine.shared?.observers.tiler.windows ?? [] }) {
        func rows(_ widgets: [String]) -> JSONValue { .array(widgets.map { .object(["item": .string($0)]) }) }
        let up = { () throws(ControlError) -> DockController in
            guard let dock = dock() else { throw ControlError(.notReady, "Pilot's dock is not up yet; ask again in a moment") }
            return dock
        }
        register(ControlVerb("dock", help: "Pilot's dock: its switch (dock.on), size (dock.size), the auto-hide it saved from the macOS Dock, the room the tiler keeps for it, its widgets, and its icons: the macOS Dock's pins (read, never written), then the running apps, each with its windows and what a click does.",
                             usage: "pilot dock") { _ throws(ControlError) in
            // Read for the answer alone: the pill keeps what it shows.
            let dock = try up()
            let apps = DockController.apps(pins: dock.readPins(), running: DockController.runningApps(),
                                           byApp: Dictionary(grouping: windows(), by: \.bundleId), front: nil)
            return .object([
                "on": .bool(dock.isOn), "size": .string(dock.settings.size.rawValue),
                "savedAutohide": dock.state.savedAutohide.map(JSONValue.bool) ?? .null,
                "room": .array(dock.room.map { .object(["screen": .string($0.monitor), "height": .number(Double($0.height))]) }),
                "widgets": .array(dock.settings.widgets.map(JSONValue.string)),
                "problem": dock.problem.map(JSONValue.string) ?? .null,
                "apps": .array(apps.map { app in
                    .object(["name": .string(app.name), "bundleID": app.bundleID.map(JSONValue.string) ?? .null, "pinned": .bool(app.pinned),
                             "running": .bool(app.running), "windows": .number(Double(app.windows)), "dots": .number(Double(app.dots)),
                             "click": .string(app.click.rawValue)])
                }),
            ])
        })
        register(ControlCollection(
            "dock-widgets", help: "The dock's widgets, at most \(DockSettings.mostWidgets), in order: a built-in bar item drawn from its parts (cpu, memory, timer, clock, battery…), an extension's own bar item as extension:<id>, or a group as group (the Group) or group:<n>, which keeps the members the top bar gives it. Each draws as in the top bar and only while it has something to show.",
            fields: [.init("item", help: "a bar item, extension:<id>, group or group:<n>")],
            rowKey: "item",
            list: { rows(dock()?.settings.widgets ?? []) },
            add: { args throws(ControlError) in
                let dock = try up()
                do throws(DockWidgetError) { try dock.settings.add(args.value("item") ?? "") } catch { throw ControlError(.badValue, error.description) }
                return rows(dock.settings.widgets)
            },
            remove: { args throws(ControlError) in
                let dock = try up(), item = try args.word(0, "item")
                do throws(DockWidgetError) { try dock.settings.remove(item) } catch { throw ControlError(.badValue, error.description) }
                return rows(dock.settings.widgets)
            }))
    }
}
