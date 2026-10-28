import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95423030 (audit gap 4): quicklinks with a {query}, `gh pilot` → GitHub's search for pilot. Nothing here
/// opens a URL.
@Suite("Quicklinks")
struct QuicklinksTests {
    private let gh = Quicklink(name: "GitHub", keyword: "gh", url: "https://github.com/search?q={query}")
    private let vercel = Quicklink(name: "Vercel dashboard", keyword: "vc", url: "https://vercel.com/dashboard")

    @Test("{query} is filled percent-encoded; a link without one opens as it is")
    func fill() {
        #expect(gh.url(query: "pilot app") == URL(string: "https://github.com/search?q=pilot%20app"))
        #expect(gh.url(query: "a&b=c#d") == URL(string: "https://github.com/search?q=a%26b%3Dc%23d"))
        #expect(gh.takesQuery && !vercel.takesQuery)
        #expect(vercel.url(query: "") == URL(string: "https://vercel.com/dashboard"))
        #expect(Quicklink(name: "x", keyword: "x", url: "not a url {query}").url(query: "a") == nil)
    }

    @Test("A link needs a name, a keyword of lowercase letters and digits no other link has, and a URL Pilot can open")
    func refusals() {
        let links = [gh, vercel]
        func refusal(_ name: String, _ keyword: String, _ url: String = "https://x.com") -> Quicklink.Refusal? {
            Quicklink(name: name, keyword: keyword, url: url).refusal(among: links)
        }
        #expect(refusal("", "x")?.field == .name)
        #expect(refusal("X", "")?.field == .keyword)
        for keyword in ["GH", "g h", "café", "a-b"] { #expect(refusal("X", keyword)?.line == "A keyword is lowercase letters and digits, with no spaces.") }
        #expect(refusal("X", "gh")?.line == "gh is taken by GitHub; pick another keyword.")
        #expect(refusal("X", "x", "x.com/search?q={query}")?.field == .url)
        #expect(refusal("X", "x2", "https://x.com/search?q={query}") == nil)
        #expect(gh.refusal(among: links) == nil, "a link keeps its own keyword")
        #expect(Quicklink(id: gh.id, name: " GitHub ", keyword: " gh ", url: " https://github.com ").trimmed
                    == Quicklink(id: gh.id, name: "GitHub", keyword: "gh", url: "https://github.com"))
    }

    @Test("A missing file gives the starter links, saved at once; the store keeps edits, an emptied list stays empty; a file that does not decode throws")
    func store() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = QuicklinksStore(url: dir.appendingPathComponent("quicklinks.json"))
        let shipped = try store.load()
        #expect(shipped == Quicklink.shipped && FileManager.default.fileExists(atPath: store.url.path))
        #expect(shipped.map(\.keyword) == ["g", "yt", "gh", "maps", "tr", "wiki"])
        #expect(Set(shipped.map(\.keyword)).count == shipped.count && Set(shipped.map(\.id)).count == shipped.count)
        #expect(shipped.allSatisfy { $0.takesQuery && $0.refusal(among: shipped) == nil })
        try store.save([])
        #expect(try store.load().isEmpty, "a user who removed every starter does not get them back")
        try store.save([vercel])
        #expect(try store.load() == [vercel])
        try Data("{".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test("Each link is a root search row found by its name or keyword; one taking a query fills the search on Return")
    func rows() {
        let rows = MenuEntries.quicklinks([gh, vercel])
        #expect(rows.map(\.title) == ["GitHub", "Vercel dashboard"])
        #expect(rows.map(\.target) == [.action("links.open:\(gh.id)"), .action("links.open:\(vercel.id)")])
        #expect(rows[0].keywords == "gh" && rows[0].home == nil && rows[0].inSearch)
        #expect(rows[0].fills == "gh " && rows[1].fills == nil)
        #expect(rows[0].icon == MenuIcon.quicklink)

        var nav = MenuNavigator(entries: rows)
        nav.query = "github"
        #expect(nav.selected?.title == "GitHub")
        #expect(nav.handle(.return) == .handled)
        #expect(nav.query == "gh ")
        nav.query = "vercel"
        #expect(nav.handle(.return) == .run(rows[1]))
    }

    @Test("Typing a keyword, a space and words answers with the filled link first; anything else answers nothing")
    func answer() {
        let rows = RootAnswers.entries(for: "gh pilot app", now: .now, links: [gh, vercel])
        #expect(rows.count == 1)
        #expect(rows.first?.isAnswer == true)
        #expect(rows.first?.title == "Search GitHub for \u{201C}pilot app\u{201D}")
        #expect(rows.first?.target == .action("links.open:\(gh.id):pilot app"))
        #expect(Quicklink.answers(for: "gh ", in: [gh]).isEmpty)
        #expect(Quicklink.answers(for: "ghx pilot", in: [gh]).isEmpty)
        #expect(Quicklink.answers(for: "vc pilot", in: [vercel]).isEmpty)
        #expect(Quicklink.answers(for: "GH pilot", in: [gh]).count == 1)
    }

    @Test("An action id names its link and query")
    func actionID() {
        #expect(Quicklink.parse("links.open:\(gh.id)")! == (gh.id, nil))
        #expect(Quicklink.parse("links.open:\(gh.id):a:b")! == (gh.id, "a:b"))
        #expect(Quicklink.parse("links.open:nope") == nil)
        #expect(Quicklink.parse("drive.url:x") == nil)
    }
}
