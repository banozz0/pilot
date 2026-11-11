import Foundation
@testable import PilotCore
import Testing

/// Snippets (card agent-bo-95423044, audit gap 2): saved text with a keyword, its placeholders filled when it is
/// pasted, and the typed keyword the tap watches for.
@Suite("Snippets")
struct SnippetsTests {
    static let malta = TimeZone(identifier: "Europe/Malta")!
    /// Thu 8 Oct 2026 09:05 in Malta.
    static let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = malta
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 9, minute: 5))!
    }()
    static let gb = Locale(identifier: "en_GB")

    static func fill(_ text: String, clipboard: String? = "copied", argument: String = "") -> SnippetText {
        Snippet(name: "t", keyword: ";t", text: text)
            .expanded(now: now, clipboard: clipboard, argument: argument, locale: gb, timeZone: malta)
    }

    @Test("{date} and {time} fill from the clock in the Mac's locale")
    func dateAndTime() {
        #expect(Self.fill("on {date} at {time}").text == "on 8 Oct 2026 at 09:05")
    }

    @Test("{clipboard} is the text on the pasteboard, nothing when it holds none")
    func clipboard() {
        #expect(Self.fill("> {clipboard}").text == "> copied")
        #expect(Self.fill("> {clipboard}", clipboard: nil).text == "> ")
    }

    @Test("{argument} is what was asked for, every time it appears")
    func argument() {
        #expect(Self.fill("Hi {argument}, thanks {argument}!", argument: "Ana").text == "Hi Ana, thanks Ana!")
        #expect(Snippet(name: "g", keyword: ";g", text: "Hi {argument}").needsArgument)
        #expect(!Snippet(name: "g", keyword: ";g", text: "Hi {clipboard}").needsArgument)
    }

    @Test("{cursor} is left out and the caret goes back to it: characters after it, counted as the eye sees them")
    func cursor() {
        let filled = Self.fill("feat({cursor}): 🚀 {date}")
        #expect(filled.text == "feat(): 🚀 8 Oct 2026")
        #expect(filled.caretBack == 15)
        #expect(Self.fill("done").caretBack == 0)
        // Only the first one counts; a second is dropped.
        #expect(Self.fill("a{cursor}b{cursor}c") == SnippetText(text: "abc", caretBack: 2))
    }

    @Test("An unknown brace stays as typed")
    func unknown() {
        #expect(Self.fill("{name} {}").text == "{name} {}")
    }

    @Test("The keyword typed expands at once, after a space or at the start, never inside a word")
    func typedKeyword() {
        var typing = SnippetTyping(keywords: [";cm", "sig", ";c"])
        #expect(type(&typing, "git ;c") == ";c")  // the shorter keyword is whole first
        typing = SnippetTyping(keywords: [";cm", "sig"])
        #expect(type(&typing, "git ;cm") == ";cm")
        #expect(type(&typing, "x;cm") == ";cm")  // a keyword that starts with punctuation starts its own word
        #expect(type(&typing, "design") == nil)  // "sig" inside a word
        #expect(type(&typing, " sig") == "sig")
        #expect(type(&typing, "sig") == "sig")  // the buffer starts empty after an expansion
    }

    @Test("Backspace takes the last character back; a reset forgets what was typed")
    func editing() {
        var typing = SnippetTyping(keywords: [";cm"])
        #expect(type(&typing, ";cx") == nil)
        typing.backspace()
        #expect(type(&typing, "m") == ";cm")
        #expect(type(&typing, ";c") == nil)
        typing.reset()
        #expect(type(&typing, "m") == nil)
    }

    @Test("Saved snippets read back identical; none before the first save")
    func store() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "snippets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SnippetStore(url: url)
        #expect(try store.load().isEmpty)
        let saved = [Snippet(name: "Commit", keyword: ";cm", text: "feat({cursor}): "),
                     Snippet(name: "Greeting", keyword: ";hi", text: "Hi {argument}")]
        try store.save(saved)
        #expect(try store.load() == saved)
    }

    static let commit = Snippet(name: "Commit", keyword: ";cm", text: "feat({cursor}): ")
    static let greet = Snippet(name: "Greeting", keyword: ";hi", text: "Hi {argument},\nthanks")

    @Test("Hyper+Space lists snippets under Trigger › Snippets and at the root search; Return pastes the one picked")
    func menu() {
        #expect(MenuLayout.rows[.trigger]?.contains(.branch(.snippets)) == true)
        var nav = MenuNavigator(entries: [])
        nav.query = "cm"
        nav.provide(.snippet, home: .snippets, MenuEntries.snippets([Self.commit, Self.greet], query: nav.query))
        let row = nav.rows.first
        #expect(row?.title == "Commit" && row?.detail == ";cm · feat({cursor}):")
        #expect(row?.kindWord == "Snippet" && row?.returnLabel == "Paste")
        #expect(nav.handle(.return) == .run(row!))
        #expect(row?.target == .snippet(.init(id: Self.commit.id)))
    }

    @Test("A snippet that needs an argument takes what is typed after its name or keyword and a space")
    func menuArgument() {
        func pick(_ query: String) -> SnippetPick? {
            MenuEntries.snippets([Self.commit, Self.greet], query: query).compactMap {
                if case .snippet(let pick) = $0.target, pick.id == Self.greet.id { pick } else { nil }
            }.first
        }
        #expect(pick("greeting Ana Maria")?.argument == "Ana Maria")
        #expect(pick(";hi Ana")?.argument == "Ana")
        #expect(pick("greet")?.argument == nil)
        // The name typed with nothing after it yet asks again, never pastes an empty argument.
        #expect(pick("Greeting ")?.argument == nil)
        #expect(pick("greeting   Ana")?.argument == "Ana")
        #expect(pick("")?.argument == nil)
        var nav = MenuNavigator(entries: [])
        nav.query = "Greeting Ana"
        nav.provide(.snippet, home: .snippets, MenuEntries.snippets([Self.commit, Self.greet], query: nav.query))
        #expect(nav.rows.first?.target == .snippet(.init(id: Self.greet.id, argument: "Ana")))
        #expect(nav.rows.first?.detail == ";hi · Hi Ana,")
    }

    @Test("Snippets is a page of its own (2026-10-10, was Clipboard's tab); a link, the old link and the search land on it")
    func page() {
        #expect(!AppPage.clipboard.tabs.contains { $0.title == "Snippets" })
        #expect(AppPlace.search("snippet") == [AppPlace(.snippets)])
        #expect(AppPlace.search("text expansion") == [AppPlace(.snippets)])
        #expect(AppPlace.linked(URL(string: "pilot://open?page=clipboard&tab=snippets")!) == AppPlace(.snippets))
    }

    private func type(_ typing: inout SnippetTyping, _ text: String) -> String? {
        var hit: String?
        for character in text { if let keyword = typing.type(String(character)) { hit = keyword } }
        return hit
    }
}
