import Foundation
import Testing
import PilotCore
@testable import Pilot
@testable import WebApps

/// Card agent-bo-95422979: an app Homebrew did not install goes to the Trash, where Finder can put it back, and only
/// after Sven's yes. Confirm and Trash are fakes; nothing here moves a file.
@MainActor
@Suite("Remove an app")
struct RemoveAppTests {
    @MainActor final class Record {
        var asked: [(title: String, command: String)] = [], trashed: [URL] = []
        var yes: (@MainActor () -> Void)?
    }

    @Test("Remove on an app asks first with what it will do, and moves the app to the Trash only on yes")
    func trashAfterYes() {
        let record = Record()
        InstallModule.remove(RemoveRow(source: .app(path: "/Applications/Notion.app"), name: "Notion", app: "/Applications/Notion.app"),
                             confirm: { title, command, yes in record.asked.append((title, command)); record.yes = yes },
                             trash: { record.trashed.append($0); return $0 })
        #expect(record.asked.map(\.title) == ["Remove Notion"])
        #expect(record.asked.map(\.command) == ["Move Notion.app to the Trash"])
        #expect(record.trashed.isEmpty, "nothing moves before the yes")
        record.yes?()
        #expect(record.trashed == [URL(filePath: "/Applications/Notion.app")])
    }

    @Test("Remove on Install › Web apps asks as the menu's Remove does, and trashes and refreshes only on yes (card agent-bo-95422994, G14)")
    func webAppPageAsks() throws {
        let record = Record()
        var refreshed = 0
        let app = InstalledWebApp(spec: try WebAppSpec(name: "X", url: "https://x.com"), bundleID: "dev.banozz.pilot.webapp.x-com",
                                  location: URL(filePath: "/Users/s/Applications/X.app"))
        InstallModule.remove(app, confirm: { title, command, yes in record.asked.append((title, command)); record.yes = yes },
                             trash: { record.trashed.append($0); return $0 }, then: { refreshed += 1 })
        #expect(record.asked.map(\.title) == ["Remove X"])
        #expect(record.asked.map(\.command) == ["Move X.app to the Trash"])
        #expect(record.trashed.isEmpty && refreshed == 0, "nothing moves before the yes")
        record.yes?()
        #expect(record.trashed == [app.location])
        #expect(refreshed == 1)
    }

    @Test("Remove finds the app bundles at the top of a folder, never a link or anything else")
    func bundles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "Notion.app/Contents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "Safari.app"), withDestinationURL: folder.appending(path: "Notion.app"))
        try Data().write(to: folder.appending(path: "notes.txt"))
        #expect(InstallModule.appBundles(in: [folder]).map { URL(filePath: $0).lastPathComponent } == ["Notion.app"])
    }

    @Test("Return on a pinned row asks to unpin with the exact command, and runs it only on yes")
    func unpinAfterYes() throws {
        let record = Record()
        var ran: [String] = []
        let beads = UpdateRow(item: .package(try #require(Package(.formula, "beads"))), from: "1.1.0", to: "1.3.1", pinned: true)
        InstallModule.unpin(beads, confirm: { title, command, yes in record.asked.append((title, command)); record.yes = yes },
                            run: { ran.append($0) })
        #expect(record.asked.map(\.title) == ["Unpin beads"])
        #expect(record.asked.map(\.command) == ["brew unpin beads"])
        #expect(ran.isEmpty, "nothing runs before the yes")
        record.yes?()
        #expect(ran == ["brew unpin beads"])
    }
}
