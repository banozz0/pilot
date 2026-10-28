import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95423030: quicklinks kept in a book Pilot saves on every edit, opened in the default browser from
/// Hyper+Space or a bind. Opening goes to a fake; nothing here opens a URL.
@MainActor
final class OpenedLinks { var urls: [URL] = [] }

@MainActor
@Suite("Quicklinks module")
struct QuicklinksModuleTests {
    private func store() -> QuicklinksStore {
        QuicklinksStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("pilot-links-\(UUID().uuidString)/quicklinks.json"))
    }

    @Test("The book starts with the shipped links and saves each edit")
    func book() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let book = QuicklinkBook(store: store)
        #expect(book.links == Quicklink.shipped)
        book.links.append(Quicklink(name: "Vercel", keyword: "vc", url: "https://vercel.com"))
        #expect(try store.load().last?.keyword == "vc")
        #expect(QuicklinkBook(store: store).links.count == Quicklink.shipped.count + 1)
    }

    @Test("Save refuses a keyword another link has and changes nothing; a valid link is saved trimmed, an edit in place")
    func save() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let book = QuicklinkBook(store: store)
        let refused = book.save(Quicklink(name: "GitHub issues", keyword: "gh", url: "https://github.com/issues?q={query}"))
        #expect(refused?.field == .keyword && refused?.line == "gh is taken by GitHub; pick another keyword.")
        #expect(book.links == Quicklink.shipped)
        let vercel = Quicklink(name: " Vercel ", keyword: "vc", url: "https://vercel.com/dashboard ")
        #expect(book.save(vercel) == nil)
        #expect(book.links.last == Quicklink(id: vercel.id, name: "Vercel", keyword: "vc", url: "https://vercel.com/dashboard"))
        #expect(try store.load().last?.keyword == "vc")
        var gh = try #require(book.links.first)
        gh.name = "GitHub search"
        #expect(book.save(gh) == nil, "a link keeps its own keyword")
        #expect(book.links.first?.name == "GitHub search" && book.links.count == Quicklink.shipped.count + 1)
    }

    @Test("A file that does not decode is never overwritten, and Save says why")
    func unreadable() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: store.url)
        let book = QuicklinkBook(store: store)
        #expect(book.links.isEmpty)
        book.links.append(Quicklink(name: "x", keyword: "x", url: "https://x.com"))
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "{")
        // Save says so instead of adding a link the next launch loses (Moody, Nq1swKUORHA).
        let refused = book.save(Quicklink(name: "y", keyword: "y", url: "https://y.com"))
        #expect(refused?.line == "Pilot can not read quicklinks.json, so it saves nothing over it; fix or move that file.")
        // The editor's line is the book's, so it shows this too (Moody, Nq1swKUORHA).
        #expect(book.refusal(for: Quicklink(name: "y", keyword: "y", url: "https://y.com")) == refused)
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "{")
    }

    @Test("A link's action opens it filled, an answer's with its words, in the default browser; an unknown id is no action")
    func open() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let book = QuicklinkBook(store: store), opened = OpenedLinks()
        let gh = try #require(book.links.first { $0.keyword == "gh" })
        let action = try #require(QuicklinksModule.dynamic(gh.actionID, book: book) { opened.urls.append($0) })
        #expect(action.label == "GitHub")
        action.run()
        try #require(QuicklinksModule.dynamic("\(gh.actionID):pilot app", book: book) { opened.urls.append($0) }).run()
        #expect(opened.urls == [URL(string: "https://github.com/search?q=")!, URL(string: "https://github.com/search?q=pilot%20app")!])
        #expect(QuicklinksModule.dynamic("links.open:\(UUID().uuidString)", book: book) { _ in } == nil)
        #expect(QuicklinksModule.dynamic("drive.url:https://x.com", book: book) { _ in } == nil)
    }

    @Test("A quicklink link needs the link token, and an imported bind of one arrives off")
    func linkGate() {
        #expect(BindStore.arrivesOff("links.open:\(Quicklink.shipped[0].id)"))
    }
}
