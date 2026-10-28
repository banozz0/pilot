#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Defaults › Aliases (card agent-bo-95423037): the row the menu's Set alias asked for opens the editor once, in view,
/// and the cards' words. Each book lives in a temporary folder no test writes to unless it sets an alias.
@MainActor
@Suite("Aliases list")
struct AliasesListTests {
    /// A book on a file in a temporary folder that does not exist until an alias is set.
    static func book() -> AliasBook {
        AliasBook(store: AliasesStore(url: FileManager.default.temporaryDirectory.appending(path: "pilot-aliases-\(UUID().uuidString)/aliases.json")))
    }

    /// Runs the run loop until `done` holds, `within` seconds at most; whether it held.
    @discardableResult
    static func until(within seconds: Double = 2, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return done()
    }

    @Test("The menu's ask opens the editor once and brings it into view, as the page appears and while it shows")
    func asksOpenTheEditorInView() throws {
        let book = Self.book()
        let model = AppWindowModel(defaults: UserDefaults(suiteName: testSuite())!)
        model.editAlias = Alias(key: "action:apps.webApp", alias: "", title: "Make a web app")
        let asked = Binding { model.editAlias } set: { model.editAlias = $0 }
        let page = ScrollViewReader { page in KitPage { Color.clear.frame(height: 2400); AliasesList(book: book, asked: asked, page: page) } }
        try LookPageTests().hosted(page.pilotTheme(look: .shared)) { host in
            let scroll = try #require(SharedLook.MenuScrollTests.scrollViews(in: host).first)
            #expect(model.editAlias == nil, "the list did not take the ask as it appeared")
            #expect(Self.until { Self.fromTop(scroll) > 1500 }, "the page did not scroll to the editor: visible \(scroll.documentVisibleRect)")
            // Scrolled back to the top, an ask while the page shows brings the editor back.
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            #expect(Self.fromTop(scroll) == 0)
            model.editAlias = Alias(key: "app:com.apple.Safari", alias: "", title: "Safari")
            #expect(Self.until { model.editAlias == nil }, "the list did not take an ask while it showed")
            #expect(Self.until { Self.fromTop(scroll) > 1500 }, "an ask while the page showed did not scroll: visible \(scroll.documentVisibleRect)")
        }
        #expect(book.aliases.all.isEmpty, "opening the editor saved something")
    }

    /// How far down the page `scroll` shows.
    static func fromTop(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return 0 }
        let visible = scroll.documentVisibleRect
        return document.isFlipped ? visible.minY - document.bounds.minY : document.bounds.maxY - visible.maxY
    }

    @Test("A card names the row's kind as the root search does, from its key")
    func kindWords() {
        #expect(Alias(key: "app:com.apple.Safari", alias: "sf", title: "Safari").kindWord == "App")
        #expect(Alias(key: "action:apps.webApp", alias: "wa", title: "Make a web app").kindWord == "Action")
        #expect(Alias(key: "package:cask:zed", alias: "z", title: "Zed").kindWord == "Package")
        #expect(Alias(key: "branch:install", alias: "in", title: "Install").kindWord == "Menu")
        #expect(Alias(key: "file:/tmp/a.txt", alias: "a", title: "a.txt").kindWord == nil)
        #expect(Alias(key: "pilot", alias: "p", title: "Pilot").kindWord == nil)
    }

    @Test("The field suggests the title's initials, or a one-word title's first two letters, as an alias takes them")
    func suggestions() {
        #expect(Alias.suggestion(for: "Make a web app") == "mawa")
        #expect(Alias.suggestion(for: "Web app picker") == "wap")
        #expect(Alias.suggestion(for: "Safari") == "sa")
        #expect(Alias.suggestion(for: "Visual Studio Code") == "vsc")
        #expect(Alias.suggestion(for: "Zoom.us") == "zu")
        #expect(Alias.suggestion(for: "Café") == "ca")
        #expect(Alias.suggestion(for: "…") == "wp")
    }

    @Test("The cards list by alias, as a keymap reads")
    func sorted() {
        let aliases = [Alias(key: "a", alias: "wa", title: "Make a web app"), Alias(key: "b", alias: "gh", title: "Ghostty"),
                       Alias(key: "c", alias: "g2", title: "Two")]
        #expect(AliasesList.sorted(aliases).map(\.alias) == ["g2", "gh", "wa"])
    }

    @Test("Every card makes room for the longest alias up to six letters, so the titles start on one edge")
    func slot() {
        #expect(AliasesList.slot([]) == "")
        #expect(AliasesList.slot([Alias(key: "a", alias: "z", title: "Zed"), Alias(key: "b", alias: "sys", title: "System")]) == "sys")
        #expect(AliasesList.slot([Alias(key: "a", alias: "z", title: "Zed"), Alias(key: "b", alias: "clipboard", title: "Clipboard")]) == "clipbo")
    }
}
#endif
