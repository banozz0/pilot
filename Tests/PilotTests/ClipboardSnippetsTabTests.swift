import AppKit
@testable import Clipboard
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The clipboard panel's Snippets tab (Sven, 2026-10-08): the saved snippets in the panel, on a throwaway store and a
/// list given here; nothing touches the real clipboard or snippets.json.
@MainActor
@Suite("Clipboard panel Snippets tab", .serialized)
final class ClipboardSnippetsTabTests {
    let database = FileManager.default.temporaryDirectory.appending(path: "pilot-clip-snippets-\(UUID().uuidString).sqlite")
    let saved = [Snippet(name: "Signature", keyword: ";sig", text: "Best,\nSven"),
                 Snippet(name: "Greeting", keyword: ";hi", text: "Hi {argument}!"),
                 Snippet(name: "Address", keyword: "", text: "1 Main St")]

    deinit {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: database.path + suffix) }
    }

    func model(_ snippets: [Snippet]? = nil) throws -> PanelModel {
        let store = try ClipboardStore(path: database)
        try store.add(ClipItem(kind: .text, text: "copied", contents: [["public.utf8-plain-text": Data("copied".utf8)]], sourceApp: nil))
        let list = snippets ?? saved
        return PanelModel(store: store, snippets: { list })
    }

    @Test("The Snippets tab lists every snippet in the editor's order and no copy; the search finds a name, keyword or text")
    func lists() throws {
        let model = try self.model()
        #expect(!model.showsSnippets)
        model.tab = .kind(.snippet)
        #expect(model.showsSnippets && model.rows.isEmpty)
        #expect(model.snippetRows.map(\.name) == ["Signature", "Greeting", "Address"])
        #expect(model.selectedSnippet?.name == "Signature")
        model.query = "main"
        #expect(model.snippetRows.map(\.name) == ["Address"])
        model.query = ";HI"
        #expect(model.snippetRows.map(\.name) == ["Greeting"])
        model.query = "nothing like it"
        #expect(model.snippetRows.isEmpty && model.selectedSnippet == nil)
    }

    @Test("type:snippet on All lists the snippets as the tab does, its other words searching them")
    func typed() throws {
        let model = try self.model()
        model.query = "type:snippet sven"
        #expect(model.showsSnippets && model.rows.isEmpty)
        #expect(model.snippetRows.map(\.name) == ["Signature"])
        model.query = ""
        #expect(!model.showsSnippets && model.rows.map(\.text) == ["copied"])
    }

    @Test("Arrows and the pointer move the cursor over the snippets; a click pastes; pin, pick and tag do nothing there")
    func cursor() throws {
        let model = try self.model()
        var commands: [PanelCommand] = []
        model.run = { commands.append($0) }
        model.tab = .kind(.snippet)
        model.move(1)
        #expect(model.selectedSnippet?.name == "Greeting")
        model.move(5)
        #expect(model.selectedSnippet?.name == "Address")
        model.hover(at: 0)
        #expect(model.selectedSnippet?.name == "Signature")
        model.click(at: 1, returnCopies: true)
        #expect(model.selectedSnippet?.name == "Greeting" && commands == [.paste(plain: false)])
        model.click(at: 2, returnCopies: false, command: true)
        #expect(commands.count == 1 && model.pickCount == 0)
        model.extend(1); model.pickAll(); model.togglePick()
        #expect(model.pickCount == 0)
        model.open(.tag)
        #expect(model.prompt == nil)
    }

    @Test("Cmd+K on the Snippets tab offers Paste and Edit snippets; each runs its command")
    func actions() throws {
        let model = try self.model()
        var commands: [PanelCommand] = []
        model.run = { commands.append($0) }
        model.tab = .kind(.snippet)
        model.open(.actions)
        #expect(model.prompt == .actions)
        #expect(model.actionRows.map(\.title) == ["Paste", "Edit snippets"])
        model.type("edit")
        #expect(model.actionRows.map(\.key) == ["⌘E"])
        #expect(!model.confirm())
        #expect(commands == [.editSnippets] && model.prompt == nil)
        model.open(.actions)
        #expect(!model.confirm())
        #expect(commands == [.editSnippets, .paste(plain: false)])
    }

    @Test("No snippets: Cmd+K still offers Edit snippets, nothing to paste")
    func none() throws {
        let model = try self.model([])
        model.tab = .kind(.snippet)
        #expect(model.snippetRows.isEmpty)
        model.open(.actions)
        #expect(model.actionRows.map(\.title) == ["Edit snippets"])
    }
}
