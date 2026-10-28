import AppKit
@testable import Clipboard
import Foundation
import PilotCore
import Testing
@testable import Pilot

extension SharedLook {
/// The clipboard panel's selected row always scrolls whole into view, its Pinned or Recent heading with it (card
/// agent-bo-95422986; the menu's same defect, fixed at 2086da9). The real panel and view on a throwaway store, hidden.
@MainActor
@Suite("Clipboard panel scroll", .serialized)
struct ClipboardScrollTests {
    @Test("Arrow Down past the pinned rows onto the one Recent row, the last, shows that row whole; Arrow Up back shows Pinned's heading")
    func recentRowShows() throws {
        testApp()
        let store = try ClipboardStore(path: FileManager.default.temporaryDirectory.appending(path: "pilot-clip-scroll-\(UUID().uuidString).sqlite"))
        var pinned: [Int64] = []
        for i in 0..<20 {
            let text = "pinned \(i)"
            pinned.append(try store.add(ClipItem(kind: .text, text: text, contents: [["public.utf8-plain-text": Data(text.utf8)]], sourceApp: nil),
                                        at: Date(timeIntervalSince1970: 1_800_000_000 + Double(i))))
        }
        try store.setPinned(pinned, true)
        try store.add(ClipItem(kind: .text, text: "recent", contents: [["public.utf8-plain-text": Data("recent".utf8)]], sourceApp: nil),
                      at: Date(timeIntervalSince1970: 1_800_000_100))
        let model = PanelModel(store: store)
        #expect(model.rows.last?.text == "recent" && model.rows.count == 21)
        // A pointer that never moves, as MenuScrollTests.panel's: the default reads the real one, which a test must not follow.
        let panel = PanelTestSupport.hide(HUD.makePanel(ClipboardPanelView(model: model, returnCopies: false, pointer: PointerTrack { .zero }),
                                                        surface: .clipboard))
        defer { panel.orderOut(nil) }
        panel.orderFront(nil)
        PanelTestSupport.pump()
        for _ in 1..<model.rows.count {
            model.move(1)
            PanelTestSupport.pump(0.1)
        }
        PanelTestSupport.pump()
        #expect(model.cursor == model.rows.count - 1)
        // The row list is the panel's tallest scroll: the tabs are one line, the preview shorter.
        let scroll = try #require(MenuScrollTests.scrollViews(in: panel.contentView).max { $0.frame.height < $1.frame.height })
        // Waited for, not pumped a fixed while: a loaded run starves the scroll past pump's quiet turns (full runs, 2026-10-11).
        #expect(AliasesListTests.until(within: 10) { MenuScrollTests.bottomGap(scroll) <= 12 }, "The selected row ends \(MenuScrollTests.bottomGap(scroll)) pt below the list's edge")
        for _ in 1..<model.rows.count {
            model.move(-1)
            PanelTestSupport.pump(0.1)
        }
        #expect(AliasesListTests.until(within: 10) { AliasesListTests.fromTop(scroll) <= 12 },
                "Back on the first row, the Pinned heading stays \(AliasesListTests.fromTop(scroll)) pt above the edge")
    }
}
}
