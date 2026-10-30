import Foundation

extension MenuEntries {
    /// Apps bring their own commands to the menu (P38, Sven Q289): each drive catalogue action of an app on this Mac is a
    /// Command row, "Calendar: New Event", wearing its app's icon badged with its `symbol`. Its target is the action the
    /// route names, so Return runs it, Cmd+K binds it and `pilot run` takes its id. A route `entries` already lists (a bound
    /// one, in Keybindings) turns into a command where it stands, never listed twice, its app's name among its words when its
    /// title lacks it. Pilot's own action an app names (Music's Play or pause, the media key) stays Pilot's row, never the
    /// app's (Q552). Adding an app is a catalogue entry.
    public static func commands(_ entries: [MenuEntry], catalogue: DriveCatalogue, installed: Set<String>) -> [MenuEntry] {
        func command(_ row: MenuEntry, _ app: DriveCatalogue.App, _ entry: DriveCatalogue.Entry) -> MenuEntry {
            var row = row
            row.ownKind = .command
            row.app = app.bundle
            row.subtitle = app.name
            row.icon = entry.symbol.map { .glyph($0, .neutral) }
            if !row.title.hasPrefix(app.name + ": ") { row.keywords = [row.keywords, app.name].compactMap(\.self).joined(separator: " ") }
            return row
        }
        var listed = Set<String>()
        let marked = entries.map { row -> MenuEntry in
            guard case .action(let id) = row.target, !DriveCatalogue.ownAction(id), let found = catalogue.app(for: id) else { return row }
            listed.insert(id)
            return command(row, found.app, found.entry)
        }
        let added = catalogue.apps.filter { installed.contains($0.bundle) }.flatMap { app in
            app.actions.filter { !listed.contains($0.route) && !DriveCatalogue.ownAction($0.route) }.map { entry in
                command(MenuEntry(title: "\(app.name): \(entry.label)", target: .action(entry.route), detailIsKey: true), app, entry)
            }
        }
        return marked + added
    }
}
