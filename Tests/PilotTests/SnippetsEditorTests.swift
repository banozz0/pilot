import Foundation
@testable import Pilot
import PilotCore
import SwiftUI
import Testing

/// The Snippets page's editor (card agent-bo-95423044), driven without a window on a library in a temp file: New and
/// Delete save at once and move the pick, a keyword another snippet has is a clash the higher one wins, and a
/// placeholder goes in at the caret.
@MainActor
@Suite("Snippets editor")
struct SnippetsEditorTests {
    static let commit = Snippet(name: "Commit message", keyword: ";cm", text: "feat({cursor}): {clipboard}")
    static let greeting = Snippet(name: "Greeting", keyword: ";hi", text: "Hi {argument},")
    static let fix = Snippet(name: "Fix", keyword: ";cm", text: "fix: {clipboard}")
    static let address = Snippet(name: "Address", keyword: "", text: "Alex Rivera\nValletta, Malta")

    /// A library on its own temp file, seeded with `snippets`.
    static func library(_ snippets: [Snippet] = []) throws -> (library: SnippetLibrary, store: SnippetStore) {
        let store = SnippetStore(url: FileManager.default.temporaryDirectory.appending(path: "pilot-snippets-\(UUID().uuidString).json"))
        try store.save(snippets)
        return (SnippetLibrary(store: store), store)
    }

    @Test("New snippet adds a row at the end, picks it and saves it")
    func add() throws {
        let (library, store) = try Self.library([Self.commit])
        defer { try? FileManager.default.removeItem(at: store.url) }
        let editor = SnippetsEditor(library: library)
        #expect(editor.selected == Self.commit.id)

        let id = editor.add()
        #expect(library.snippets.map(\.id) == [Self.commit.id, id])
        #expect(editor.selected == id && editor.current?.name == "New snippet" && editor.current?.keyword == "")
        #expect(try store.load().map(\.id) == [Self.commit.id, id])
    }

    @Test("New snippet in an empty library makes the first one and picks it")
    func addFirst() throws {
        let (library, store) = try Self.library()
        defer { try? FileManager.default.removeItem(at: store.url) }
        let editor = SnippetsEditor(library: library)
        #expect(editor.current == nil)
        let id = editor.add()
        #expect(editor.current?.id == id && library.snippets.count == 1)
    }

    @Test("Delete removes it and saves; the one after it is picked, else the one before, else none")
    func delete() throws {
        let (library, store) = try Self.library([Self.commit, Self.greeting, Self.fix])
        defer { try? FileManager.default.removeItem(at: store.url) }
        let editor = SnippetsEditor(library: library, selected: Self.greeting.id)

        editor.delete(Self.greeting.id)
        #expect(library.snippets.map(\.id) == [Self.commit.id, Self.fix.id])
        #expect(editor.selected == Self.fix.id)
        #expect(try store.load().map(\.id) == [Self.commit.id, Self.fix.id])

        editor.delete(Self.fix.id)
        #expect(editor.selected == Self.commit.id)
        // Deleting one not picked leaves the pick alone.
        editor.add()
        let picked = editor.selected
        editor.delete(Self.commit.id)
        #expect(editor.selected == picked)
        editor.delete(try #require(picked))
        #expect(library.snippets.isEmpty && editor.current == nil)
    }

    @Test("An edit saves the snippet; one that changes nothing writes nothing")
    func edit() throws {
        let (library, store) = try Self.library([Self.commit])
        defer { try? FileManager.default.removeItem(at: store.url) }
        let editor = SnippetsEditor(library: library)
        editor.edit(Self.commit.id) { $0.keyword = ";c" }
        #expect(try store.load().first?.keyword == ";c")
        let written = try FileManager.default.attributesOfItem(atPath: store.url.path)[.modificationDate] as? Date
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: store.url.path)
        editor.edit(Self.commit.id) { $0.keyword = ";c" }
        let after = try FileManager.default.attributesOfItem(atPath: store.url.path)[.modificationDate] as? Date
        #expect(written != nil && after == Date(timeIntervalSince1970: 0), "an edit that changed nothing saved the file")
    }

    @Test("A keyword another snippet has clashes and the higher one wins; no keyword is Hyper+Space only; a letter waits for a word's start")
    func keywordNotes() throws {
        let sig = Snippet(name: "", keyword: "sig", text: "— Sven")
        let (library, store) = try Self.library([Self.commit, Self.greeting, Self.fix, Self.address, sig])
        defer { try? FileManager.default.removeItem(at: store.url) }
        let editor = SnippetsEditor(library: library)
        #expect(editor.note(for: Self.commit) == .clash(other: "Fix", wins: true))
        #expect(editor.note(for: Self.fix) == .clash(other: "Commit message", wins: false))
        #expect(editor.note(for: Self.greeting) == .anywhere)
        #expect(editor.note(for: Self.address) == .menuOnly && editor.clash(for: Self.address) == nil)
        #expect(editor.note(for: sig) == .wordStart && SnippetsEditor.title(sig) == "Untitled")
    }

    @Test("A placeholder goes in at the caret, over a selection, or after the end when the text has no caret")
    func insert() {
        let text = "feat(): x"
        let caret = text.index(text.startIndex, offsetBy: 5)
        let atCaret = SnippetsEditor.inserting("{cursor}", into: text, at: TextSelection(insertionPoint: caret))
        #expect(atCaret.text == "feat({cursor}): x")
        #expect(atCaret.text[atCaret.caret...] == "): x")

        let x = text.index(before: text.endIndex)
        let over = SnippetsEditor.inserting("{clipboard}", into: text, at: TextSelection(range: x..<text.endIndex))
        #expect(over.text == "feat(): {clipboard}" && over.caret == over.text.endIndex)

        let none = SnippetsEditor.inserting("{date}", into: "Today ", at: nil)
        #expect(none.text == "Today {date}" && none.caret == none.text.endIndex)
    }

    @Test("The first line skips blank lines; the placeholders say what each becomes, the date and time as they paste")
    func lines() {
        #expect(Snippet.firstLine("\n  \n  Hi {argument},\nThanks") == "Hi {argument},")
        #expect(Snippet.firstLine("  ") == nil)
        let now = Date(timeIntervalSince1970: 1_791_450_000)
        let placeholders = SnippetsEditor.placeholders(now: now)
        #expect(placeholders.map(\.token) == ["{date}", "{time}", "{clipboard}", "{argument}", "{cursor}"])
        let date = Snippet(name: "", keyword: "", text: "{date}").expanded(now: now, clipboard: nil).text
        #expect(placeholders[0].line.hasSuffix(date))
    }
}
