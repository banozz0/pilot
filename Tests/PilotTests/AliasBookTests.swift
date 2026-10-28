import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95423037: the aliases the menu reads, saved on every change, never over a file that does not decode.
@MainActor
@Suite("Alias book")
struct AliasBookTests {
    private func store() -> AliasesStore {
        AliasesStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("pilot-aliases-\(UUID().uuidString)/aliases.json"))
    }

    @Test("A change is saved, a refused one changes nothing, and the next launch reads them")
    func saves() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let book = AliasBook(store: store)
        #expect(book.aliases.all.isEmpty)
        #expect(book.set("wp", for: "action:apps.webAppPicker", title: "Web app picker") == nil)
        #expect(book.set("wp", for: "app:com.apple.Safari", title: "Safari") == "wp is Web app picker's alias; pick another.")
        #expect(AliasBook(store: store).aliases.key(for: "wp") == "action:apps.webAppPicker")
        #expect(book.set("", for: "action:apps.webAppPicker", title: "Web app picker") == nil)
        #expect(try store.load().all.isEmpty)
    }

    @Test("A file that does not decode is never overwritten, and a change says why")
    func unreadable() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: store.url)
        let book = AliasBook(store: store)
        #expect(book.set("wp", for: "action:apps.webAppPicker", title: "Web app picker") == AliasBook.unreadable)
        #expect(book.aliases.all.isEmpty)
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "{")
    }
}
