import AppKit
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

    /// A stand-in running copy: quits on a normal quit only when `quits`, always on a force quit.
    @MainActor final class Copy: RunningCopy {
        var isTerminated = false, forced = false
        let quits: Bool
        init(quits: Bool) { self.quits = quits }
        func terminate() -> Bool { if quits { isTerminated = true }; return true }
        func forceTerminate() -> Bool { forced = true; isTerminated = true; return true }
    }

    /// An app bundle with only its Info.plist, in a folder of the test's own.
    static func fixtureApp(_ id: String) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appending(path: "remove-\(UUID().uuidString)/Fixture.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": "Fixture"], format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        return app
    }

    @Test("Remove on a running app asks to quit and remove it, quits it at the yes, and only then moves it; its leftovers are offered after (Q181)")
    func quitsFirst() async throws {
        let app = try Self.fixtureApp("dev.example.quitfixture"), copy = Copy(quits: true), record = Record()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        var offered: [String] = []
        RemoveApp.remove("Fixture", at: app, confirm: { title, command, yes in record.asked.append((title, command)); record.yes = yes },
                         trash: { record.trashed.append($0); return $0 }, running: { _ in copy.isTerminated ? [] : [copy] },
                         askForce: { _ in Issue.record("a copy that quits is never force quit"); return false },
                         leftovers: { offered.append($0.bundleID) })
        #expect(record.asked.map(\.title) == ["Quit and remove Fixture"])
        #expect(record.asked.map(\.command) == ["Quit Fixture, then move Fixture.app to the Trash"])
        record.yes?()
        for _ in 0..<100 where record.trashed.isEmpty || offered.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(copy.isTerminated && !copy.forced)
        #expect(record.trashed == [app])
        #expect(offered == ["dev.example.quitfixture"])
    }

    @Test("An app that won't quit is offered Force quit; no to it leaves the app running and where it was")
    func forceQuitRefused() async throws {
        let copy = Copy(quits: false)
        var asked = 0
        let quit = await RemoveApp.quit([copy], name: "Fixture", wait: .milliseconds(200)) { _ in asked += 1; return false }
        #expect(!quit && asked == 1 && !copy.isTerminated && !copy.forced)
    }

    /// HungAppFixture's main thread stops answering, so a normal quit never reaches it: the real NSRunningApplication
    /// path to Force quit.
    @Test("A hung app's normal quit times out, and Force quit's yes ends it")
    func forceQuitsAHungApp() async throws {
        let hung = Process(), out = Pipe()
        hung.executableURL = AXTimeoutTests.fixture
        hung.arguments = ["30"]
        hung.standardOutput = out
        try hung.run()
        defer { if hung.isRunning { hung.terminate() } }
        _ = out.fileHandleForReading.availableData   // "hung"
        let running = try #require(NSRunningApplication(processIdentifier: hung.processIdentifier))
        var asked = 0
        let quit = await RemoveApp.quit([running], name: "HungAppFixture", wait: .seconds(1)) { _ in asked += 1; return true }
        #expect(quit && asked == 1 && running.isTerminated)
    }
}
