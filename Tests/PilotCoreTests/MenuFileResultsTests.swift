import Foundation
import Testing
@testable import PilotCore

/// The file results view (Sven, 2026-10-07, "yes to file search idea"): Cmd+K on a file offers Open, Open With…, Show
/// in Finder, Copy path and Move to Trash; Space in the Files view previews the selected file. Pure, no GUI.
@Suite("Menu file results")
struct MenuFileResultsTests {
    static let report = MenuEntry(title: "report.pdf", target: .file("/Users/x/report.pdf"), subtitle: "~")

    func filesView() -> MenuNavigator {
        var nav = MenuNavigator(entries: [MenuEntry(title: "Reporter", target: .app("dev.banozz.test.reporter"), home: .apps)])
        nav.query = "report"
        while nav.selected?.target != .searchFiles { _ = nav.handle(.down) }
        _ = nav.handle(.return)
        nav.provide(.file, [Self.report])
        return nav
    }

    @Test("Cmd+K on a file: Open, Open With…, Convert to…, Show in Finder, Copy path, Move to Trash, then favourites and ranking")
    func fileActions() {
        #expect(RowAction.list(for: Self.report, favourite: false) == [.open, .openWith, .convert, .showInFinder, .copyPath, .trash, .favourite, .resetRanking])
        #expect(RowAction.openWith.title == "Open With…")
        #expect(RowAction.convert.title == "Convert to…")
        #expect(RowAction.trash.title == "Move to Trash…")
        var nav = filesView()
        _ = nav.handle(.commandK)
        while nav.actions?.selected != .row(.trash) { _ = nav.handle(.down) }
        #expect(nav.handle(.return) == .act(.trash, Self.report), "the panel asks before anything moves")
    }

    @Test("Space in the Files view previews the selected file; anywhere else it types a space")
    func spacePreviews() {
        var nav = filesView()
        #expect(nav.only == .file)
        #expect(nav.handle(.space) == .preview(Self.report))
        var all = MenuNavigator(entries: [MenuEntry(title: "Reporter", target: .app("dev.banozz.test.reporter"), home: .apps)])
        all.query = "report"
        #expect(all.handle(.space) == .ignored)
        var empty = filesView()
        empty.provide(.file, [])
        #expect(empty.handle(.space) == .ignored, "no file selected: the space goes to the search")
    }
}
