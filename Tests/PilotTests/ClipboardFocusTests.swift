import AppKit
import Clipboard
import Foundation
import Testing
@testable import Pilot

/// Card agent-bo-95422767: typing in the clipboard panel must reach its search field, as the menu's does (card
/// agent-bo-95422762). The real panel and view on a throwaway store, never drawn: alpha 0 and no mouse.
@MainActor
@Suite("Clipboard panel focus", .serialized, .pilotFocus)
struct ClipboardFocusTests {
    @Test("A clipboard panel whose search field lost the keyboard drops letters; the shared check hands it back, caret at the end")
    func lostFocus() throws {
        testApp()
        let store = try ClipboardStore(path: FileManager.default.temporaryDirectory.appending(path: "pilot-clip-focus-\(UUID().uuidString).sqlite"))
        let model = PanelModel(store: store)
        let panel = PanelTestSupport.hide(ClipboardHistory.makePanel(model, returnCopies: false))
        defer { panel.orderOut(nil) }
        panel.makeKeyAndOrderFront(nil)
        PanelTestSupport.pump()
        // Lane 1's live state: the panel is key, its first responder is not the search field, so kiwi never arrives.
        panel.makeFirstResponder(nil)
        PanelTestSupport.type("x", into: panel)
        #expect(model.query == "")
        #expect(HUD.focusSearch(in: panel) == .given)
        #expect(HUD.focusSearch(in: panel) == .had)
        PanelTestSupport.type("kiwi", into: panel)
        #expect(model.query == "kiwi")
        panel.makeFirstResponder(nil)
        #expect(HUD.focusSearch(in: panel) == .given)
        PanelTestSupport.type("s", into: panel)
        #expect(model.query == "kiwis")
    }

    @Test("Edit text: the editor takes the keyboard and the typing, and Cmd+Return's confirm saves it (card agent-bo-95422784)")
    func editor() throws {
        testApp()
        let store = try ClipboardStore(path: FileManager.default.temporaryDirectory.appending(path: "pilot-clip-edit-\(UUID().uuidString).sqlite"))
        try store.add(.plainText("line one\nline", sourceApp: nil))
        let model = PanelModel(store: store)
        let panel = PanelTestSupport.hide(ClipboardHistory.makePanel(model, returnCopies: false))
        defer { panel.orderOut(nil) }
        panel.makeKeyAndOrderFront(nil)
        PanelTestSupport.pump()
        model.open(.edit)
        PanelTestSupport.pump()
        let editor = try #require(panel.firstResponder as? NSTextView)
        #expect(!editor.isFieldEditor)
        editor.moveToEndOfDocument(nil)
        PanelTestSupport.type(" two", into: panel)
        #expect(model.promptText == "line one\nline two")
        #expect(model.query == "")
        _ = model.confirm()
        #expect(try store.recent().map(\.text) == ["line one\nline two"])
    }
}
