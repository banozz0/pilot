import Testing
@testable import Pilot
@testable import PilotCore

/// What an empty menu says (card agent-bo-95422979): Translate with nothing typed said "Nothing matches.", which reads
/// as a failure before Sven has typed a word.
@Suite("Menu empty text")
@MainActor
struct MenuEmptyTextTests {
    func text(_ query: String, in branch: MenuBranch?) -> String {
        var nav = MenuNavigator(entries: [], branch: branch)
        nav.query = query
        return MenuModel(nav: nav).emptyText
    }

    @Test("Translate asks for text and says the language is detected; once there is text it says it is translating")
    func translate() {
        for typed in ["", "h"] {
            #expect(text(typed, in: .translate) == "Type to translate; the language is detected automatically.", "\(typed)")
        }
        #expect(text("hola", in: .translate) == "Translating…")
        #expect(text("zzzz", in: nil) == "Nothing matches.", "the root still says nothing matched")
    }

    @Test("Search packages asks for a name and names every source it searches")
    func packages() {
        #expect(text("", in: .homebrew) == "Type a name to search Homebrew, the App Store, GitHub, package tools and the web.")
    }
}
