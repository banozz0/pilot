import Foundation
import PilotCore
import WebApps

/// What Install's catalogue, its search and Remove reach (CLI W16): the shipped catalogue, every source's search, and
/// Remove's list (Homebrew, each npm tree, apps Homebrew did not install, web apps). A test hands in its own entries,
/// search, rows, terminal, Trash and pages, so nothing installs, nothing goes to the Trash and no browser opens.
@MainActor
final class ControlInstall {
    var gate = AllowPrompt.gate
    var entries: @MainActor () -> [CatalogueEntry] = { InstallModule.catalogue }
    var isInstalled: @MainActor (CatalogueEntry) -> Bool = InstallModule.isInstalled
    /// The helpers installed, by id (Helper.installed).
    var helpers: @MainActor () -> Set<String> = { Helper.installed() }
    /// Recommend apps: the catalogue is the recommendations, so with it off Install shows none.
    var recommend: @MainActor () -> Bool = { Recommendations.shared.show }
    var search: @Sendable (String) async -> (query: InstallSearch.Query, groups: [InstallSearch.Group])? = { await InstallSearcher.search($0) }
    var removeRows: @Sendable () async -> [RemoveRow]? = { await InstallModule.removeRows() }
    var measure: @Sendable ([RemoveRow]) async -> [RemoveRow] = { await InstallModule.measure($0) }
    /// The visible terminal Install runs its command in.
    var run: InstallModule.Run = InstallModule.visibleRun
    var trash: @MainActor (URL) throws -> URL = WebAppDirectory.trash
    /// Remove's leftovers: where they are looked for, and the Trash they go to (a test run's throwaway one).
    var library = AppLeftovers.library
    var leftoversTrash: FileOps.Trash = FileOps.systemTrash
    /// An app's running copies: one that runs is refused, as the menu's Remove quits it first.
    var running: RemoveApp.Running = RemoveApp.running
    /// A vendor's or a search result's page: the App Store's in the App Store, anything else in Zen.
    var open: @MainActor (URL) -> Void = InstallModule.openPage
    var webApps = WebAppStamper.applicationsFolder

    /// Remove's rows the last list read, which `remove removable` acts on while fresh, as the menu's Return acts on
    /// the rows it shows.
    var removable: (rows: [RemoveRow], at: Date)?
    static let keepRows: TimeInterval = 600

    /// Install's confirm step stood in for by the gate, which has asked by the time this runs.
    static let confirmed: InstallModule.Confirm = { _, _, go in go() }

    /// Remove's rows, read now (about 2 s) and kept; nil Homebrew's list could not be read.
    func readRemovable(measured: Bool) async throws(ControlError) -> [RemoveRow] {
        guard let read = await removeRows() else { throw ControlError(.notReady, "Homebrew's installed list could not be read; ask again to retry") }
        let rows = RemoveList.sorted(measured ? await measure(read) : read, .pilotFirst)
        removable = (rows, .now)
        return rows
    }
}

extension ControlVerbs {
    /// Install › Catalogue and Remove as collections, and `install` for search and pick (CLI W16). Every install and
    /// remove waits on the Allow gate, which stands in for Install's confirm step; a command then runs in Install's
    /// visible terminal as Return there runs it. A vendor's https page opens with nothing asked, as a web link does.
    func registerInstall(_ s: ControlInstall) {
        register(ControlCollection("catalogue", help: "Install's catalogue: every app and tool Pilot offers, by category, each with how it installs and whether it is installed. None while Recommend apps is off (recommendations.show), as the page; pilot install pick <key> installs one.",
                                   rowKey: "key", list: {
            guard s.recommend() else { return .array([]) }
            return .array(s.entries().map { .object(Self.row($0, installed: s.isInstalled($0))) })
        }))

        register(ControlCollection("removable", help: "Remove's list: Homebrew's formulae and casks, each npm tree's global tools, apps Homebrew did not install and web apps, Pilot's installs first, with size and last used (reads up to a minute). remove asks Allow, then runs the command in a terminal or moves the app to the Trash.",
                                   rowKey: "key", list: { () throws(ControlError) in
            .array(try await s.readRemovable(measured: true).map { .object(Self.row($0)) })
        }, askerAdd: nil, askerRemove: { args, peer throws(ControlError) in
            try await Self.remove(try args.word(0, "row key; pilot list removable lists them"), s, peer: peer)
        }))

        register(ControlCollection("helpers", help: "The tools other features run (Install › Command-line tools): Homebrew, Mole, mas, npm and cargo, each with what it unlocks, whether it is installed and how it installs; pilot install helper <id> installs one.",
                                   rowKey: "id", list: {
            let installed = s.helpers()
            return .array(Helper.all.map { h in
                .object(["id": .string(h.id), "name": .string(h.name), "installed": .bool(installed.contains(h.id)), "unlocks": .string(h.unlocks),
                         "how": .string(h.how), "command": .string(h.install)])
            })
        }))

        registerInstallVerb(s)
    }

    /// A catalogue entry as its card shows it: what it is, how it installs, the exact command when one runs, and the
    /// vendor page it was checked against.
    static func row(_ e: CatalogueEntry, installed: Bool) -> [String: JSONValue] {
        // How it arrives, as the card says it (CataloguePage.how).
        let via = e.method.package.map { $0.kind == .cask && e.category == "Fonts" ? "Homebrew font" : $0.via } ?? e.method.label
        var row: [String: JSONValue] = ["key": .string(e.key), "id": .string(e.id), "name": .string(e.name), "category": .string(e.category),
                                        "via": .string(via), "installed": .bool(installed), "vendor": .string(e.vendor),
                                        "checked": .string(e.checked)]
        switch e.method {
        case .package(let p): row["command"] = .string(p.install)
        case .script: row["command"] = e.method.scriptCommand.map(JSONValue.string)
        case .download(let page): row["page"] = .string(page)
        }
        return row
    }

    private static func row(_ r: RemoveRow) -> [String: JSONValue] {
        var row: [String: JSONValue] = ["key": .string(r.key), "name": .string(r.name), "category": .string(r.category.rawValue),
                                        "origin": .string(r.origin(home: NSHomeDirectory())), "pilot": .bool(r.pilot),
                                        "needed": .bool(r.needed), "appStore": .bool(r.appStore), "system": .bool(r.system)]
        row["app"] = r.app.map(JSONValue.string)
        row["lastUsed"] = r.lastUsed.map { .string($0.ISO8601Format()) }
        row["size"] = r.size.map { .number(Double($0)) }
        return row
    }

    /// Return on a Remove row: a package or an npm tool asks with its exact command, then runs it in the terminal; an
    /// app or a web app asks, then goes to the Trash, where Finder can put it back.
    private static func remove(_ key: String, _ s: ControlInstall, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let rows = if let kept = s.removable, Date.now.timeIntervalSince(kept.at) < ControlInstall.keepRows { kept.rows } else {
            try await s.readRemovable(measured: false)
        }
        guard let row = rows.first(where: { $0.key == key }) else {
            throw ControlError(.badValue, "nothing Remove lists has the key \(key); pilot list removable lists them")
        }
        guard !row.system else { throw ControlError(.badValue, "\(row.name) is part of macOS and can't be removed") }
        let location: URL, ask: ControlGate.Ask
        var open: [any RunningCopy] = []
        switch row.source {
        case .package(let p): return try await removeRun(row, p.remove, s, peer: peer)
        case .npm(let name, let prefix): return try await removeRun(row, "\(UpdateList.npm("uninstall", prefix: prefix)) \(name)", s, peer: peer)
        case .app(let path):
            location = URL(filePath: path)
            open = RemoveApp.copies(of: location, running: s.running)
            ask = ControlGate.Ask("Remove app", "\(row.name): \(open.isEmpty ? "" : "quit it, then ")move \(location.lastPathComponent) to the Trash")
        case .webApp(let id):
            guard let app = WebAppDirectory.list(in: s.webApps).first(where: { $0.bundleID == id }) else {
                throw ControlError(.badValue, "no web app \(id) any more; pilot list removable reads them again")
            }
            location = app.location
            ask = .remove(.webApp, "\(app.name): move \(location.lastPathComponent) to the Trash")
        }
        return try await s.gate.allow(ask, peer: peer) { () throws(ControlError) in
            // A normal quit only: Force quit loses unsaved work, so it stays the menu's, asked on screen.
            guard await RemoveApp.quit(open, name: row.name, askForce: { _ in false }) else {
                throw ControlError(.badValue, "\(row.name) did not quit, so it stays where it is; quit or force quit it, then remove again")
            }
            let trashed: URL
            do { trashed = try await AdminTrash.trash(location, plain: s.trash) }
            catch let cancelled as AdminTrash.Cancelled { throw ControlError(.denied, cancelled.localizedDescription) }
            catch { throw ControlError(.badValue, "\(row.name) could not go to the Trash: \(error.localizedDescription)") }
            s.removable?.rows.removeAll { $0.key == key }
            return .object(["key": .string(key), "name": .string(row.name), "trashed": .string(trashed.path(percentEncoded: false))])
        }
    }

    private static func removeRun(_ row: RemoveRow, _ command: String, _ s: ControlInstall, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        try await s.gate.allow(.remove(.package, command), peer: peer) { () throws(ControlError) in
            InstallModule.remove(row, confirm: ControlInstall.confirmed, run: s.run)
            // Gone once the command ends: the next list reads it so.
            s.removable = nil
            return .object(["key": .string(row.key), "name": .string(row.name), "ran": .string(command),
                            "note": .string("runs in a terminal window; pilot list removable reads it gone once the command ends")])
        }
    }
}
