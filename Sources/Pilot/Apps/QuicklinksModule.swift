import AppKit
import Observation
import OSLog
import PilotCore

private let qlog = Logger(subsystem: "dev.banozz.pilot", category: "quicklinks")

/// Sven's quicklinks (card agent-bo-95423030), saved on every edit. A file that does not decode loads as no links and
/// is never saved over, so an edit can not wipe it.
@MainActor
@Observable
final class QuicklinkBook {
    static let shared = QuicklinkBook(store: .standard)

    var links: [Quicklink] { didSet { save() } }

    @ObservationIgnored private let store: QuicklinksStore
    @ObservationIgnored private let readable: Bool

    init(store: QuicklinksStore) {
        self.store = store
        do {
            links = try store.load()
            readable = true
        } catch {
            qlog.error("quicklinks: \(store.url.path, privacy: .public) unreadable, \(String(describing: error), privacy: .public)")
            links = []
            readable = false
        }
    }

    /// Saves `link` trimmed, over the link with its id or after the others; else the refusal, and nothing changes
    /// (Defaults › Quicklinks), as when the file did not read.
    func save(_ link: Quicklink) -> Quicklink.Refusal? {
        if let refusal = refusal(for: link) { return refusal }
        let link = link.trimmed
        if let i = links.firstIndex(where: { $0.id == link.id }) {
            if links[i] != link { links[i] = link }
        } else {
            links.append(link)
        }
        return nil
    }

    /// Why Save would refuse `link`, nil when it would save it; the editor shows the same line.
    func refusal(for link: Quicklink) -> Quicklink.Refusal? { readable ? link.refusal(among: links) : .unreadable }

    func link(_ id: UUID) -> Quicklink? { links.first { $0.id == id } }

    func remove(_ id: UUID) { links.removeAll { $0.id == id } }

    private func save() {
        guard readable else { return qlog.error("quicklinks: not saved over an unreadable file") }
        do { try store.save(links) } catch { qlog.error("quicklinks: not saved, \(error.localizedDescription, privacy: .public)") }
    }
}

/// `links.open:<id>` opens that quicklink, `links.open:<id>:<words>` with its {query} filled (the root's answer), in the
/// default browser. The link is read again as it runs, so an edit since is followed.
@MainActor
enum QuicklinksModule {
    static func dynamic(_ id: String, book: QuicklinkBook = .shared,
                        open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) -> Action? {
        guard let (linkID, query) = Quicklink.parse(id), let link = book.link(linkID) else { return nil }
        return Action(id: id, label: link.name, module: .apps) {
            guard let link = book.link(linkID) else { return HUD.tip("That quicklink is gone.") }
            guard let url = link.url(query: query ?? "") else { return HUD.tip("\(link.name) is not a link Pilot can open.") }
            qlog.notice("quicklink \(link.keyword, privacy: .public)")
            open(url)
        }
    }
}
