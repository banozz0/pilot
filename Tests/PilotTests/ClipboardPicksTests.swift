import AppKit
@testable import Clipboard
import Foundation
import Testing
@testable import Pilot

/// Card agent-bo-95422780: the panel's model with picks, on a throwaway store; nothing touches the real clipboard.
@MainActor
@Suite("Clipboard panel picks", .serialized)
final class ClipboardPicksTests {
    let database = FileManager.default.temporaryDirectory.appending(path: "pilot-clip-picks-\(UUID().uuidString).sqlite")

    deinit {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: database.path + suffix) }
    }

    func model(_ texts: [String]) throws -> (PanelModel, ClipboardStore) {
        let store = try ClipboardStore(path: database)
        // Added oldest first, so the panel lists them in the order given.
        for (i, text) in texts.reversed().enumerated() {
            try store.add(ClipItem(kind: .text, text: text, contents: [["public.utf8-plain-text": Data(text.utf8)]], sourceApp: nil),
                          at: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)))
        }
        return (PanelModel(store: store), store)
    }

    @Test("Shift+Down twice from a picks a, b, c; a plain Down keeps them, Escape clears them; typing clears them")
    func picks() throws {
        let (model, _) = try model(["a", "b", "c", "d"])
        model.extend(1)
        model.extend(1)
        #expect(model.targets.map(\.text) == ["a", "b", "c"])
        #expect(model.pickNumber(model.rows[1]) == 2)
        model.move(1)
        #expect(model.targets.map(\.text) == ["a", "b", "c"])
        model.clearPicks()
        #expect(model.targets.map(\.text) == ["d"])
        model.pickAll()
        #expect(model.targets.count == 4)
        model.query = "a"
        #expect(model.pickCount == 0)
        #expect(model.targets.map(\.text) == ["a"])
    }

    @Test("The search field writing back the same text (as it does when it takes focus) keeps the picks and the cursor")
    func sameQueryKeepsPicks() throws {
        let (model, _) = try model(["a", "b", "c"])
        model.extend(1)
        model.query = model.query
        #expect(model.pickCount == 2)
        #expect(model.cursor == 1)
    }

    @Test("With picks, Backspace deletes every pick and Cmd+P pins every pick")
    func deleteAndPinMany() throws {
        let (model, store) = try model(["a", "b", "c", "d"])
        model.extend(1)  // a, b
        model.togglePin()
        #expect(try store.recent().filter(\.pinned).map(\.text).sorted() == ["a", "b"])
        #expect(model.targets.map(\.text) == ["a", "b"])
        model.togglePin()
        #expect(try store.recent().filter(\.pinned).isEmpty)
        model.clearPicks()
        model.move(1)  // the cursor stayed on b, so c
        model.extend(1)  // c, d
        model.deleteSelected()
        #expect(try store.recent().map(\.text) == ["a", "b"])
        #expect(model.targets.map(\.text).count == 1)
    }

    @Test("The preview of several picks lists them in pick order, each by its first line with text")
    func preview() throws {
        let (model, _) = try model(["a", "\n\nb\nmore", "c"])
        model.move(2)
        model.extend(-1)
        #expect(model.picked?.map(PanelModel.line) == ["c", "b"])
        model.move(1)
        #expect(model.picked?.map(PanelModel.line) == ["c", "b"])
        model.clearPicks()
        #expect(model.picked == nil)
    }

    @Test("An image copy's thumbnail is made off the main thread at most 240 pixels a side; a text copy has none")
    func thumbnail() async throws {
        let store = try ClipboardStore(path: database)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try store.add(ClipItem(kind: .image, text: "", contents: [["public.png": try #require(rep.representation(using: .png, properties: [:]))]],
                               sourceApp: nil), at: Date(timeIntervalSince1970: 1_800_000_000))
        try store.add(ClipItem(kind: .text, text: "a", contents: [["public.utf8-plain-text": Data("a".utf8)]], sourceApp: nil),
                      at: Date(timeIntervalSince1970: 1_800_000_001))
        let model = PanelModel(store: store)
        let (text, image) = (model.rows[0], model.rows[1])
        #expect(model.thumbnail(text) == nil)
        #expect(model.thumbnail(image) == nil)
        for _ in 0..<200 where model.thumbnail(image) == nil { try await Task.sleep(for: .milliseconds(10)) }
        let made = try #require(model.thumbnail(image)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect((made.width, made.height) == (240, 120))
    }

    @Test("Cmd+T then a new name tags every pick; the same tag again on items that all have it untags them; the search is untouched")
    func tagging() throws {
        let (model, store) = try model(["a", "b", "c"])
        model.query = ""
        model.extend(1)  // a, b
        model.open(.tag)
        #expect(model.prompt == .tag)
        model.type("work")
        #expect(model.tagChoices == [.create("work")])
        _ = model.confirm()
        #expect(model.prompt == nil && model.query.isEmpty)
        #expect(try store.recent().filter { !$0.tags.isEmpty }.map(\.text) == ["a", "b"])
        #expect(model.pickCount == 2)

        model.open(.tag)
        let work = try #require(try store.tags().first)
        #expect(model.tagChoices.count == 1)
        #expect(model.sharedTagIDs == [work.id])
        _ = model.confirm()
        #expect(try store.recent().allSatisfy(\.tags.isEmpty))

        model.open(.tag)
        model.type("x")
        model.dismiss()
        // Untagged from its last items, the tag went (card agent-bo-95422986); Escape made none.
        #expect(try store.tags().isEmpty)
        #expect(model.prompt == nil)
    }

    final class NoOpener: ClipOpening {
        var calls = 0
        func open(_ url: URL) { calls += 1 }
        func openWith(_ urls: [URL]) { calls += 1 }
        func reveal(_ urls: [URL]) { calls += 1 }
        func copy(_ text: String, tip: String) { calls += 1 }
        func saveImage(_ data: Data, named name: String) { calls += 1 }
    }

    @Test("Cmd+K: typing narrows the list; Split picks the new lines; Rename names the row; Paste and delete goes back to the panel's owner")
    func actions() throws {
        let store = try ClipboardStore(path: database)
        try store.add(ClipItem(kind: .text, text: "one\ntwo", contents: [["public.utf8-plain-text": Data("one\ntwo".utf8)]], sourceApp: nil))
        let opener = NoOpener()
        let model = PanelModel(store: store, opener: opener)
        model.open(.actions)
        model.type("split")
        #expect(model.actionChoices == [.split])
        #expect(!model.confirm())
        #expect(model.prompt == nil)
        #expect(model.rows.map(\.text) == ["one", "two", "one\ntwo"])
        #expect(model.targets.map(\.text) == ["one", "two"])

        model.clearPicks()
        model.move(2)  // the original
        model.open(.actions)
        model.type("rename")
        _ = model.confirm()
        #expect(model.prompt == .rename)
        model.type("Two lines")
        _ = model.confirm()
        #expect(model.rows.last?.title == "Two lines")

        model.open(.actions)
        #expect(model.actionChoices.first == .pasteAndDelete)
        #expect(model.confirm())
        #expect(opener.calls == 0)
    }

    @Test("Cmd+K Paste one by one on several picks hands the panel's owner the paste-in-sequence command (card agent-bo-95423071)")
    func pasteOneByOne() throws {
        let (model, _) = try model(["a", "b", "c"])
        var commands: [PanelCommand] = []
        model.run = { commands.append($0) }
        model.extend(1)
        model.open(.actions)
        model.type("one by one")
        #expect(model.actionChoices == [.pasteInSequence])
        #expect(!model.confirm())
        #expect(commands == [.pasteInSequence])
        #expect(model.targets.map(\.text) == ["a", "b"])
    }

    @Test("Right from Snippets reaches each tag's tab, which lists only its copies; a tag made with Cmd+T gets a tab at once")
    func tagTabs() throws {
        let (first, store) = try model(["a", "b", "c"])
        _ = try store.tag([first.rows[0].id], with: "work")
        let model = PanelModel(store: store)
        #expect(model.tabs.count == 10 && model.tab == .kind(.all))
        for _ in 0..<9 { model.stepTab(1) }
        #expect(model.tab.label == "#work")
        #expect(model.rows.map(\.text) == ["a"])
        model.stepTab(1)
        #expect(model.tab == .kind(.all) && model.rows.count == 3)
        model.move(1)
        model.open(.tag)
        model.type("todo")
        _ = model.confirm()
        #expect(model.tabs.map(\.label).suffix(2) == ["#todo", "#work"])
    }

    @Test("Cmd+S and Cmd+Shift+S put the cursor on the new first row, keeping the picks (Sven: it went to a random spot)")
    func sortGoesToTop() throws {
        let (model, _) = try model(["a", "bbbb", "cc", "ddd"])
        model.extend(1)  // a, bbbb
        model.order = ClipOrder(sort: .size)
        #expect(model.rows.map(\.text) == ["bbbb", "ddd", "cc", "a"])
        #expect(model.cursor == 0)
        #expect(model.pickCount == 2)
        model.order = ClipOrder(sort: .size, reversed: true)
        #expect(model.selected?.text == "a")
    }

    @Test("Cmd+Return picks rows apart, numbered in pick order; plain arrows keep them; Cmd+Return again drops one; a plain click clears")
    func togglePicks() throws {
        let (model, _) = try model(["a", "b", "c", "d"])
        model.togglePick()     // a
        model.move(2)          // the cursor on c, a still picked
        model.togglePick()     // c
        #expect(model.targets.map(\.text) == ["a", "c"])
        #expect(model.pickNumber(model.rows[2]) == 2)
        model.move(1)
        model.togglePick()     // d
        model.move(-3)
        model.togglePick()     // a out
        #expect(model.targets.map(\.text) == ["c", "d"])
        #expect(model.pickNumber(model.rows[3]) == 2)
        model.click(at: 1, returnCopies: false, command: true)   // Cmd+click b in
        #expect(model.targets.map(\.text) == ["c", "d", "b"])
        #expect(model.cursor == 1)
        var ran: [PanelCommand] = []
        model.run = { ran.append($0) }
        model.click(at: 1, returnCopies: false, command: true)   // Cmd+click b out: nothing pastes
        #expect(ran.isEmpty)
        #expect(model.targets.map(\.text) == ["c", "d"])
        model.click(at: 0, returnCopies: false)                  // a plain click: the picks go, Return runs
        #expect(model.pickCount == 0)
        #expect(ran == [.paste(plain: false)])
    }

    @Test("Shift+arrow picks stay on a plain arrow, Cmd+Return adds the cursor row, a plain click clears them (Sven, 2026-10-21)")
    func shiftPicksStay() throws {
        let (model, _) = try model(["a", "b", "c", "d"])
        model.extend(1)        // a, b
        model.move(1)
        model.move(1)          // cursor on d, apart from the picks
        #expect(model.cursor == 3)
        #expect(model.targets.map(\.text) == ["a", "b"])
        model.togglePick()
        #expect(model.targets.map(\.text) == ["a", "b", "d"])
        model.togglePick()     // d out again
        #expect(model.targets.map(\.text) == ["a", "b"])
        model.click(at: 2, returnCopies: false)
        #expect(model.pickCount == 0)
    }
}
