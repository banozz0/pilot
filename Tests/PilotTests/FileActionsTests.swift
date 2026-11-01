import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The menu's file results (Sven, 2026-10-07): Move to Trash asks first, Open With… lists the apps that open the file,
/// Space previews it. Fakes throughout: nothing moves, opens or shows.
@MainActor
@Suite("File actions")
struct FileActionsTests {
    final class Record {
        var asked: [(title: String, detail: String)] = []
        var yes: (@MainActor () -> Void)?
        var trashed: [URL] = []
        var picked: (rows: [MenuEntry], title: String, then: @MainActor (MenuEntry) -> Void)?
        var opened: [([URL], URL)] = []
        var previewed: [URL] = []
    }

    final class FakeApps: OpeningApps {
        let record: Record
        init(_ record: Record) { self.record = record }
        func apps(toOpen url: URL) -> (suggested: [URL], others: [URL]) { ([URL(filePath: "/System/Applications/Preview.app")], [URL(filePath: "/Applications/Zen.app")]) }
        func open(_ urls: [URL], with app: URL) { record.opened.append((urls, app)) }
    }

    final class FakeQuickLook: QuickLooking {
        let record: Record
        init(_ record: Record) { self.record = record }
        func preview(_ url: URL) { record.previewed.append(url) }
    }

    @Test("Move to Trash asks with the file's name and path, and moves it only on yes")
    func trashAfterYes() {
        let record = Record()
        FileActions.trash("/Users/x/report.pdf", confirm: { title, detail, yes in record.asked.append((title, detail)); record.yes = yes },
                          trash: { record.trashed.append($0); return $0 })
        #expect(record.asked.map(\.title) == ["Move report.pdf to the Trash"])
        #expect(record.asked.map(\.detail) == ["/Users/x/report.pdf"])
        #expect(record.trashed.isEmpty, "nothing moves before the yes")
        record.yes?()
        #expect(record.trashed == [URL(filePath: "/Users/x/report.pdf")])
    }

    @Test("Open With… lists the apps that open the file, the default first, and opens it in the one picked")
    func openWith() throws {
        let record = Record()
        FileActions.openWith([URL(filePath: "/Users/x/report.pdf")], apps: FakeApps(record), pick: { record.picked = ($0, $1, $2) })
        let picked = try #require(record.picked)
        #expect(picked.title == "Open report.pdf with")
        #expect(picked.rows.map(\.title) == ["Preview", "Zen"])
        picked.then(picked.rows[1])
        #expect(record.opened.map(\.1) == [URL(filePath: "/Applications/Zen.app")])
        #expect(record.opened.map(\.0) == [[URL(filePath: "/Users/x/report.pdf")]])
    }

    @Test("The clipboard's Open With… (card agent-bo-95422994, G8): a link is named by its site, several copies by their count, and each opens in the app picked")
    func openWithFromClipboard() throws {
        let record = Record()
        let link = URL(string: "https://example.com/x")!
        FileActions.openWith([link], apps: FakeApps(record), pick: { record.picked = ($0, $1, $2) })
        #expect(record.picked?.title == "Open example.com with")
        let files = [URL(filePath: "/tmp/a.txt"), URL(filePath: "/tmp/b.txt")]
        FileActions.openWith(files, apps: FakeApps(record), pick: { record.picked = ($0, $1, $2) })
        let picked = try #require(record.picked)
        #expect(picked.title == "Open 2 items with")
        picked.then(picked.rows[0])
        #expect(record.opened.map(\.0) == [files])
        #expect(record.opened.map(\.1) == [URL(filePath: "/System/Applications/Preview.app")])
    }

    @Test("Space's preview goes to Quick Look with the file's URL")
    func preview() {
        let record = Record()
        FileActions.preview("/Users/x/report.pdf", quickLook: FakeQuickLook(record))
        #expect(record.previewed == [URL(filePath: "/Users/x/report.pdf")])
    }
}
