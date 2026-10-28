import AppKit
@testable import Pilot
import PilotCore
import Testing

/// A typed keyword becomes its snippet in the focused field (card agent-bo-95423044): the keyword's last key is kept
/// from the app, the rest erased, the text pasted through the pasteboard and Sven's copy put back after. A fake field
/// plays the app: it types what the tap passes and applies the keys Pilot posts; the pasteboard is a private one.
@MainActor
@Suite("Snippet expansion")
struct SnippetExpansionTests {
    /// A text field as an app runs one: characters typed at the caret, Delete, Cmd+V and Left.
    @MainActor
    final class Field {
        var text = "", caret = 0
        let pasteboard: NSPasteboard
        init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

        func type(_ s: String) {
            text.insert(contentsOf: s, at: text.index(text.startIndex, offsetBy: caret)); caret += s.count
        }

        func apply(_ events: [KeyEvent]) {
            for e in events where e.kind == .keyDown {
                switch e.keyCode {
                case KeyCode.delete:
                    text.remove(at: text.index(text.startIndex, offsetBy: caret - 1)); caret -= 1
                case KeyCode.v where e.flags & KeyEvent.cmdMask != 0: type(pasteboard.string(forType: .string) ?? "")
                case KeyCode.leftArrow: caret -= 1
                default: Issue.record("unexpected key \(e.keyCode)")
                }
            }
        }
    }

    @MainActor
    final class Rig {
        let pasteboard = NSPasteboard.withUniqueName()
        lazy var field = Field(pasteboard: pasteboard)
        var secure = false
        var restores: [@MainActor () -> Void] = []
        lazy var keywords = SnippetKeywords(isBlocked: { [unowned self] in secure }) { [unowned self] snippet, erasing in
            paster.paste(snippet, erasing: erasing)
        }
        lazy var paster = SnippetPaster(pasteboard: pasteboard, post: { [unowned self] in field.apply($0) },
                                        later: { [unowned self] _, body in restores.append(body) }, now: { Date(timeIntervalSince1970: 1_791_450_000) })

        init(_ snippets: [Snippet]) {
            keywords.set(snippets)
            pasteboard.clearContents()
            pasteboard.setString("what Sven copied", forType: .string)
        }

        /// Each character as a keyboard sends it: what the tap does not swallow reaches the field.
        func type(_ text: String) {
            for c in text where !keywords.typed(KeyEvent(kind: .keyDown, keyCode: 0), String(c)) { field.type(String(c)) }
        }

        func delete() {
            let down = KeyEvent(kind: .keyDown, keyCode: KeyCode.delete)
            if !keywords.typed(down, "\u{7F}") { field.apply([down]) }
        }

        func restore() { restores.forEach { $0() }; restores = [] }
    }

    static let commit = Snippet(name: "Commit", keyword: ";cm", text: "feat({cursor}): {clipboard}")

    @Test("Hyper+Space: the query cm lists the snippet, and Return pastes it into the field and puts the copy back")
    func fromMenu() throws {
        let rig = Rig([Self.commit])
        let url = FileManager.default.temporaryDirectory.appending(path: "snippets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try SnippetStore(url: url).save([Self.commit])
        let library = SnippetLibrary(store: SnippetStore(url: url), paster: rig.paster)
        var nav = MenuNavigator(entries: [])
        nav.query = "cm"
        nav.provide(.snippet, home: .snippets, MenuEntries.snippets(library.snippets, query: nav.query))
        let row = try #require(nav.rows.first)
        #expect(nav.handle(.return) == .run(row))
        guard case .snippet(let pick) = row.target else { Issue.record("not a snippet row"); return }
        rig.field.type("git ")
        library.paste(pick)
        #expect(rig.field.text == "git feat(): what Sven copied")
        rig.restore()
        #expect(rig.pasteboard.string(forType: .string) == "what Sven copied")
        rig.pasteboard.releaseGlobally()
    }

    @Test("The tap reads the characters a key event types, as the focused app would get them")
    func tapCharacters() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        var units = Array(";é".utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        #expect(HyperTap.characters(of: event) == ";é")
    }

    @Test("Typing ;cm in a field leaves the snippet, the caret at {cursor}, and the pasteboard as it was")
    func expands() {
        let rig = Rig([Self.commit])
        rig.type("git ;cm")
        #expect(rig.field.text == "git feat(): what Sven copied")
        #expect(rig.field.caret == "git feat(".count)
        rig.restore()
        #expect(rig.pasteboard.string(forType: .string) == "what Sven copied")
        rig.pasteboard.releaseGlobally()
    }

    @Test("The pasted snippet is marked transient, so clipboard history never keeps it")
    func transient() {
        let rig = Rig([Self.commit])
        rig.type(";cm")
        #expect(rig.pasteboard.types?.contains(.init("org.nspasteboard.TransientType")) == true)
        rig.pasteboard.releaseGlobally()
    }

    @Test("Something copied before the put-back stays: Pilot only puts back over its own paste")
    func copiedMeanwhile() {
        let rig = Rig([Self.commit])
        rig.type(";cm")
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("newer copy", forType: .string)
        rig.restore()
        #expect(rig.pasteboard.string(forType: .string) == "newer copy")
        rig.pasteboard.releaseGlobally()
    }

    @Test("Nothing expands while secure input is on: the keyword stays as typed")
    func secureInput() {
        let rig = Rig([Self.commit])
        rig.secure = true
        rig.type(";cm")
        #expect(rig.field.text == ";cm")
        #expect(rig.pasteboard.string(forType: .string) == "what Sven copied")
        rig.pasteboard.releaseGlobally()
    }

    @Test("A shortcut, an arrow or Return forgets what was typed; Delete takes back one character")
    func keysThatReset() {
        let rig = Rig([Self.commit])
        rig.type(";c")
        #expect(!rig.keywords.typed(KeyEvent(kind: .keyDown, keyCode: KeyCode.leftArrow), "\u{F702}"))
        rig.type("m")
        #expect(rig.field.text == ";cm")
        rig.type(" ;c")
        #expect(!rig.keywords.typed(KeyEvent(kind: .keyDown, keyCode: 0, flags: KeyEvent.cmdMask), "a"))
        rig.type("m")
        #expect(rig.field.text == ";cm ;cm")
        rig.type(" ;cx")
        rig.delete()
        rig.type("m")
        #expect(rig.field.text == ";cm ;cm feat(): what Sven copied")
        rig.pasteboard.releaseGlobally()
    }
}
