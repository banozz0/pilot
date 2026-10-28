import AppKit
import Testing
@testable import Clipboard

/// Actions on clipboard items (card agent-bo-95422784, ClipBook's item actions, no ClipBook code): formats, split,
/// merge, rename, edit, and open, reveal, copy path and save through a fake, so nothing opens for real.
@Suite("Clipboard actions")
struct ActionTests {
    let database = TemporaryDatabase()

    func item(_ text: String, kind: ClipKind = .text) -> ClipItem {
        ClipItem(kind: kind, text: text, contents: [["public.utf8-plain-text": Data(text.utf8)]], sourceApp: "com.apple.TextEdit")
    }

    func file(_ path: String) -> ClipItem {
        ClipItem(kind: .file, text: path, contents: [["public.file-url": Data(URL(fileURLWithPath: path).absoluteString.utf8)]],
                 sourceApp: "com.apple.finder")
    }

    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    @Test("Each format turns a known text into its expected form")
    func formats() {
        let text = "  hello WORLD. this is pilot!\n\n  second   line?  "
        #expect(TextFormat.lowercase.apply(text) == "  hello world. this is pilot!\n\n  second   line?  ")
        #expect(TextFormat.uppercase.apply(text) == "  HELLO WORLD. THIS IS PILOT!\n\n  SECOND   LINE?  ")
        #expect(TextFormat.capitaliseWords.apply("hello wORLD of pilot") == "Hello World Of Pilot")
        #expect(TextFormat.sentenceCase.apply("hello WORLD. this is pilot! second line? yes") == "Hello world. This is pilot! Second line? Yes")
        #expect(TextFormat.removeEmptyLines.apply("a\n\n  \nb\n") == "a\nb")
        #expect(TextFormat.stripWhitespace.apply(" a b\tc\nd ") == "abcd")
        #expect(TextFormat.trim.apply("\n  a b  \n") == "a b")
        #expect(TextFormat.allCases.count == 7)
    }

    @Test("Split adds one item per non-empty line on top, in line order, and keeps the original; merge joins picks in pick order")
    func splitAndMerge() throws {
        let store = try ClipboardStore(path: database.path)
        let original = try store.add(item("a\n\nb\n"), at: at(1))
        let parts = try store.split(original)
        let clips = try store.recent()
        #expect(clips.map(\.text) == ["a", "b", "a\n\nb\n"])
        #expect(clips.prefix(2).map(\.id) == parts)
        let x = try store.add(item("x"), at: at(5)), y = try store.add(item("y"), at: at(6))
        let merged = try store.merge([y, x])
        #expect(try store.recent().first.map { [$0.id, $0.text] as [AnyHashable] } == [merged, "y\nx"])
        #expect(try store.contents(of: merged) == [["public.utf8-plain-text": Data("y\nx".utf8)]])
    }

    @Test("A format or an edit replaces the item's text as plain text, keeping its place; a text that already exists folds into it")
    func setText() throws {
        let store = try ClipboardStore(path: database.path)
        let rich = try store.add(ClipItem(kind: .richText, text: "Bold", contents: [["public.utf8-plain-text": Data("Bold".utf8),
                                                                                     "public.rtf": Data(#"{\rtf1 \b Bold}"#.utf8)]], sourceApp: nil), at: at(1))
        try store.add(item("newer"), at: at(2))
        try store.setText(rich, to: TextFormat.uppercase.apply("Bold"))
        let clips = try store.recent()
        #expect(clips.map(\.text) == ["newer", "BOLD"])
        #expect(clips.last?.kind == .text)
        #expect(try store.contents(of: rich) == [["public.utf8-plain-text": Data("BOLD".utf8)]])
        // Editing it to a text another row has: one row stays, the edited one, with its place, and takes the other's
        // pin, tags and name.
        let newer = try #require(try store.recent().first { $0.text == "newer" }).id
        try store.setPinned(newer, true)
        try store.tag([newer], with: "keep")
        try store.rename(newer, to: "Named")
        try store.setText(rich, to: "newer")
        let left = try store.recent()
        #expect(left.map(\.id) == [rich])
        #expect(left.first?.pinned == true && left.first?.tags.map(\.name) == ["keep"] && left.first?.title == "Named")
    }

    @Test("Rename sets a title the row shows and the search finds; clearing it shows the text again")
    func rename() throws {
        let store = try ClipboardStore(path: database.path)
        let id = try store.add(item("ssh -i key host"), at: at(1))
        try store.rename(id, to: "Server login")
        #expect(try store.recent().first?.title == "Server login")
        #expect(try store.search(ClipQuery("server"), appName: { _ in nil }).map(\.id) == [id])
        #expect(try store.search(ClipQuery("host"), appName: { _ in nil }).map(\.id) == [id])
        try store.rename(id, to: "  ")
        #expect(try store.recent().first?.title == "ssh -i key host")
    }

    @Test("Version 1 and 2 files open with every row and take titles")
    func migrates() throws {
        for write in [TagTests.writeVersion1, SortTests.writeVersion2] {
            let file = TemporaryDatabase()
            try write(file.path)
            let store = try ClipboardStore(path: file.path)
            #expect(try store.recent().map(\.text) == ["", "old copy"])
            #expect(try store.contents(of: 1).first?.count == 2)
            try store.rename(1, to: "named")
            #expect(try store.recent().last?.title == "named")
            #expect(try TagTests.userVersion(at: file.path) == Int32(ClipboardStore.migrations.count))
        }
    }

    final class FakeOpener: ClipOpening {
        var calls: [String] = []
        func open(_ url: URL) { calls.append("open \(url.absoluteString)") }
        func reveal(_ urls: [URL]) { calls.append("reveal \(urls.map(\.path).joined(separator: ","))") }
        func copy(_ text: String, tip: String) { calls.append("copy \(text) · \(tip)") }
        func saveImage(_ data: Data, named name: String) { calls.append("save \(name) \(data.count)") }
        func openWith(_ urls: [URL]) { calls.append("open with \(urls.map(\.absoluteString).joined(separator: ","))") }
    }

    @Test("Open With… sits after Open for a link or files and hands every URL to the opener's app picker (card agent-bo-95422994, G8)")
    @MainActor func openWith() throws {
        let store = try ClipboardStore(path: database.path)
        try store.add(item("https://example.com/x"), at: at(1))
        try store.add(file("/tmp/c.txt"), at: at(2))
        let clips = try store.recent()
        let link = try #require(clips.first { $0.kind == .link }), file = try #require(clips.first { $0.kind == .file })
        #expect(ClipAction.openWith.title == "Open With…")
        let actions = ClipAction.available(for: [file])
        #expect(actions.firstIndex(of: .openWith) == actions.firstIndex(of: .open).map { $0 + 1 })
        #expect(ClipAction.available(for: [link]).contains(.openWith))
        #expect(!ClipAction.available(for: [StoredClip(id: 9, kind: .text, text: "plain", sourceApp: nil, copiedAt: .now, pinned: false)])
            .contains(.openWith))
        let fake = FakeOpener()
        try ClipActions(store: store, opener: fake).run(.openWith, on: [link, file])
        #expect(fake.calls == ["open with https://example.com/x,file:///tmp/c.txt"])
    }

    @Test("Open, reveal, copy path and save go to the opener for a link, files and an image; nothing opens for real")
    @MainActor func opener() throws {
        let store = try ClipboardStore(path: database.path)
        try store.add(item("https://example.com/x"), at: at(1))
        try store.add(file("/tmp/a b.txt"), at: at(2))
        try store.add(file("/tmp/c.txt"), at: at(3))
        try store.add(ClipItem(kind: .image, text: "", contents: [["public.png": Data([1, 2, 3])]], sourceApp: nil), at: at(4))
        let clips = try store.recent()
        let link = try #require(clips.first { $0.kind == .link }), image = try #require(clips.first { $0.kind == .image })
        let files = clips.filter { $0.kind == .file }
        let fake = FakeOpener()
        let actions = ClipActions(store: store, opener: fake)
        try actions.run(.open, on: [link])
        try actions.run(.open, on: files)
        try actions.run(.reveal, on: files)
        try actions.run(.copyPath, on: files)
        try actions.run(.saveImage, on: [image])
        #expect(fake.calls == ["open https://example.com/x", "open file:///tmp/c.txt", "open file:///tmp/a%20b.txt",
                               "reveal /tmp/c.txt,/tmp/a b.txt", "copy /tmp/c.txt\n/tmp/a b.txt · Path copied", "save Clipboard image.png 3"])
    }

    @Test("The list offers only what fits: link, file, image, text, and several picks")
    func available() {
        func clip(_ kind: ClipKind, _ text: String) -> StoredClip {
            StoredClip(id: 1, kind: kind, text: text, sourceApp: nil, copiedAt: .now, pinned: false)
        }
        #expect(ClipAction.available(for: [clip(.link, "https://a.b")]).contains(.open))
        #expect(!ClipAction.available(for: [clip(.text, "plain")]).contains(.open))
        #expect(Set(ClipAction.available(for: [clip(.file, "/a")])).isSuperset(of: [.open, .reveal, .copyPath]))
        #expect(ClipAction.available(for: [clip(.image, "")]).contains(.saveImage))
        #expect(!ClipAction.available(for: [clip(.image, "")]).contains(.format(.uppercase)))
        let text = ClipAction.available(for: [clip(.text, "one\ntwo")])
        #expect(text.contains(.split) && text.contains(.format(.trim)) && text.contains(.rename) && text.contains(.edit))
        #expect(!ClipAction.available(for: [clip(.text, "one line")]).contains(.split))
        #expect(!ClipAction.available(for: [clip(.text, "a"), clip(.text, "b")]).contains(.edit))
        let two = ClipAction.available(for: [clip(.text, "a"), clip(.text, "b")])
        #expect(two.contains(.merge) && !two.contains(.rename) && two.first == .pasteAndDelete)
    }

    @Test("Cmd+K opens the action list; Option+Return pastes and deletes; Return, Cmd+Return (pick, since 659e7475) and Shift+Return are unchanged")
    func keys() {
        #expect(PanelCommand(key: .character("k"), command: true, searchEmpty: false) == .actions)
        #expect(PanelCommand(key: .character("k"), command: true, prompting: true, searchEmpty: false) == .dismiss)
        #expect(PanelCommand(key: .return, option: true, searchEmpty: true) == .pasteAndDelete(plain: false))
        #expect(PanelCommand(key: .return, option: true, shift: true, searchEmpty: true) == .pasteAndDelete(plain: true))
        #expect(PanelCommand(key: .return, searchEmpty: true) == .paste(plain: false))
        #expect(PanelCommand(key: .return, command: true, searchEmpty: true) == .togglePick)
        #expect(PanelCommand(key: .return, shift: true, searchEmpty: true) == .paste(plain: true))
        #expect(PanelCommand(key: .return, prompting: true, searchEmpty: true) == .confirm)
        // In the Edit text editor Return and the arrows edit the text; Cmd+Return saves, Escape leaves.
        #expect(PanelCommand(key: .return, prompting: true, editing: true, searchEmpty: true) == nil)
        #expect(PanelCommand(key: .down, prompting: true, editing: true, searchEmpty: true) == nil)
        #expect(PanelCommand(key: .return, command: true, prompting: true, editing: true, searchEmpty: true) == .confirm)
        #expect(PanelCommand(key: .escape, prompting: true, editing: true, searchEmpty: true) == .dismiss)
    }

    @Test("Paste and delete writes the copy marked transient, so the history does not keep it again")
    @MainActor func pasteAndDeleteIsTransient() {
        let pasteboard = NSPasteboard.makePrivate()
        PanelRows.write([PanelRows.Paste(contents: [["public.utf8-plain-text": Data("x".utf8)]], text: "x")], plain: false,
                        forget: true, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "x")
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil) == nil)
    }
}
