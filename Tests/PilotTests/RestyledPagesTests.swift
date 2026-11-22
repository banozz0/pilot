#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Workspaces, Install and Defaults on the kit (card agent-bo-95422897): each draws its body, its intro line under the
/// page's title. Drawn offscreen; by default each page is checked as pixels. Reading the words back with Vision stalls
/// the main thread for minutes under load (card agent-bo-95422962), so those tests run only with PILOT_LIVE=1.
@MainActor
@Suite("Restyled pages")
struct RestyledPagesTests {
    /// The words Vision reads on `page` (a Look of its own carries the theme).
    func words(_ page: some View) throws -> String {
        let (look, _) = LookPageTests().look()
        var text = ""
        try LookPageTests().hosted(page.frame(width: 1000, height: 900).pilotTheme(look: look)) { host in
            text = try recognisedText(in: try #require(snapshot(host, scale: 2))).map(\.text).joined(separator: "\n")
        }
        return text
    }

    /// The pixels of `page`, at 1x.
    func pixels(_ page: some View) throws -> Data {
        let (look, _) = LookPageTests().look()
        var data = Data()
        try LookPageTests().hosted(page.frame(width: 1000, height: 900).pilotTheme(look: look)) { host in
            let rep = try #require(snapshot(host))
            data = Data(bytes: try #require(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
        }
        return data
    }

    /// The page draws something: more than a flat fill.
    func expectBody(_ page: some View) throws {
        #expect(Set(try pixels(page)).count > 16, "a blank page")
    }

    @Test("Workspaces, Install and Open with each draw their body")
    func bodies() throws {
        try expectBody(Self.workspacesBody())
        try expectBody(CataloguePage())
        try expectBody(OpenWithPage())
    }

    /// Menu's Quicklinks and Aliases on files of the test's own, none of them Pilot.app's live ones.
    static func menuPage(_ section: AppSection) -> MenuPage {
        let links = QuicklinkBook(store: QuicklinksStore(url: FileManager.default.temporaryDirectory.appending(path: "pilot-links-\(UUID().uuidString)/quicklinks.json")))
        return MenuPage(section: section, aliases: AliasesListTests.book(), links: links)
    }

    static func workspacesBody() -> WorkspacesBody {
        let observers = EngineObservers()
        return WorkspacesBody(block: PilotBlockStore(tiler: observers.tiler), layouts: WorkspaceLayouts(observers: observers, defaults: LookTests.defaults()),
                              presets: WorkspacePresets(observers: observers))
    }

    /// The page shows `block` and its `intro`.
    func expectIntro(_ page: some View, block: String, intro: String) throws {
        let read = try words(page)
        #expect(read.contains(block) && read.contains(intro), "read: \(read)")
    }

    @Test("Workspaces draws one block per workspace under its intro", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func workspaces() throws {
        try expectIntro(Self.workspacesBody(), block: "Workspace 1", intro: WorkspacesBody.intro)
    }

    @Test("Install draws its search and What Pilot lists under its intro", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func install() throws {
        try expectIntro(CataloguePage(), block: AppSection.installLists.title, intro: CataloguePage.intro)
    }

    @Test("Open with draws Opens with under its intro", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func defaults() throws {
        try expectIntro(OpenWithPage(), block: "Opens with", intro: OpenWithPage.intro)
    }
}
#endif
