import Foundation
import Observation
import OSLog
import PilotCore

private let aliasLog = Logger(subsystem: "dev.banozz.pilot", category: "aliases")

/// Sven's menu aliases (card agent-bo-95423037), read once and saved on every change; the menu reads them as it opens and
/// Defaults › Aliases edits them. A file that does not decode loads as no aliases and is never saved over: a change says so.
@MainActor
@Observable
final class AliasBook {
    static let shared = AliasBook(store: .standard, starters: Alias.starters)

    private(set) var aliases: Aliases

    @ObservationIgnored private let store: AliasesStore
    @ObservationIgnored private let readable: Bool

    static let unreadable = "Pilot can not read aliases.json, so it saves nothing over it; fix or move that file."

    /// `starters` are saved once when the store has no file yet.
    init(store: AliasesStore, starters: [Alias] = []) {
        self.store = store
        do {
            aliases = try store.load(starters: starters)
            readable = true
        } catch {
            aliasLog.error("aliases: \(store.url.path, privacy: .public) unreadable, \(String(describing: error), privacy: .public)")
            aliases = Aliases()
            readable = false
        }
    }

    /// Sets the row's alias and saves; an empty one removes it. Else the line saying why not, and nothing changes.
    func set(_ alias: String, for key: String, title: String) -> String? {
        guard readable else { return Self.unreadable }
        var changed = aliases
        if let refusal = changed.set(alias, for: key, title: title) { return refusal }
        guard changed != aliases else { return nil }
        do { try store.save(changed) } catch {
            aliasLog.error("aliases: not saved, \(error.localizedDescription, privacy: .public)")
            return "Pilot could not save aliases.json: \(error.localizedDescription)"
        }
        aliases = changed
        return nil
    }
}
