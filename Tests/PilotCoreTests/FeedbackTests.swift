import Foundation
import PilotCore
import Testing

/// Send feedback (card agent-bo-95423195): a new GitHub issue on Pilot's repo, prefilled with the facts a fix needs and
/// nothing about the person.
@Suite("Feedback")
struct FeedbackTests {
    static let facts = Feedback.Facts(version: "0.1.0 · build 7", macOS: "Version 26.1 (Build 25B78)", model: "Mac16,10",
                                      layerKey: "Caps Lock", look: "Tiling Rice · Lagoon", tiler: "Pilot's tiler")

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test("A bug and an idea each open their own issue form on banozz0/pilot, its fields prefilled", arguments: Feedback.Kind.allCases)
    func newIssue(kind: Feedback.Kind) {
        let url = Feedback.url(kind, facts: Self.facts, userName: "sven")
        #expect(url.absoluteString.hasPrefix("https://github.com/banozz0/pilot/issues/new?"))
        let q = query(url)
        #expect(q["template"] == "\(kind.rawValue).yml")
        #expect(q["title"]?.isEmpty == false)
        #expect(q["mac"]?.isEmpty == false)
        // The form's own label applies for anyone; a labels parameter would only work for triagers.
        #expect(q["labels"] == nil && q["body"] == nil)
    }

    @Test("Each template has the field the link fills and the label it gives: bug, and enhancement for an idea",
          arguments: [(Feedback.Kind.bug, "bug"), (.idea, "enhancement")])
    func templates(kind: Feedback.Kind, label: String) throws {
        let forms = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../.github/ISSUE_TEMPLATE")
        let form = try String(contentsOf: forms.appending(path: "\(kind.rawValue).yml"), encoding: .utf8)
        #expect(form.contains("labels: [\(label)]"))
        #expect(form.contains("id: \(Feedback.field)\n"))
    }

    @Test("The Mac field carries every fact, and says logs are the person's to paste")
    func facts() {
        let body = query(Feedback.url(.bug, facts: Self.facts, userName: "sven"))["mac"] ?? ""
        for fact in ["0.1.0 · build 7", "Version 26.1 (Build 25B78)", "Mac16,10", "Caps Lock", "Tiling Rice · Lagoon", "Pilot's tiler"] {
            #expect(body.contains(fact), "missing \(fact)")
        }
        #expect(body.localizedCaseInsensitiveContains("paste"))
    }

    @Test("Every query value is percent-encoded: &, +, #, = and new lines survive the trip")
    func encoding() {
        let odd = Feedback.Facts(version: "1 & 2 + 3 # 4 = 5", macOS: "a\nb", model: "Mac16,10", layerKey: "⌥", look: "Calm · Tokyo Night",
                                 tiler: "Pilot's own")
        let url = Feedback.url(.idea, facts: odd, userName: "sven")
        let raw = url.query ?? ""
        for bad in ["+", "#", " ", "\n", "⌥"] { #expect(!raw.contains(bad), "unencoded \(bad.debugDescription)") }
        #expect(raw.components(separatedBy: "&").count == 3)
        let body = query(url)["mac"] ?? ""
        #expect(body.contains("1 & 2 + 3 # 4 = 5"))
        #expect(body.contains("a\nb"))
        #expect(body.contains("⌥"))
    }

    @Test("A fact far too long is cut, so the link stays under GitHub's length limit")
    func lengthCap() {
        let long = Feedback.Facts(version: String(repeating: "é", count: 20_000), macOS: "26.1", model: "Mac16,10", layerKey: "Caps Lock",
                                  look: "Calm", tiler: "Pilot's tiler")
        let url = Feedback.url(.bug, facts: long, userName: "sven")
        #expect(url.absoluteString.count <= Feedback.maxLength)
        // Every fact at its longest, in four-byte emoji: twelve characters each once encoded.
        let emoji = String(repeating: "🐛", count: 20_000)
        let worst = Feedback.Facts(version: emoji, macOS: emoji, model: emoji, layerKey: emoji, look: emoji, tiler: emoji)
        #expect(Feedback.url(.bug, facts: worst, userName: "sven").absoluteString.count <= Feedback.maxLength)
        #expect(query(url)["mac"]?.contains("Mac16,10") == true)
    }

    @Test("Neither the user name nor the home folder reaches the link, whichever fact carries it")
    func noUserName() {
        let leaky = Feedback.Facts(version: "0.1.0", macOS: "26.1", model: "Mac16,10", layerKey: "Caps Lock",
                                   look: "Calm · /Users/Sven/Themes/mine", tiler: "sven's tiler")
        let url = Feedback.url(.bug, facts: leaky, userName: "sven")
        let decoded = url.absoluteString.removingPercentEncoding ?? ""
        #expect(!decoded.localizedCaseInsensitiveContains("sven"))
        #expect(!decoded.contains("/Users/"))
    }

    @Test("Typing \"feedback\" in Hyper+Space offers Report a bug and Suggest an idea")
    func menuSearch() {
        let entries = MenuEntries.build(
            apps: [], actions: Feedback.Kind.allCases.map { .init(id: $0.actionID, label: $0.label, module: "engine", keywords: "feedback") },
            store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher", openID: { "apps.open:\($0)" }, running: [])
        var nav = MenuNavigator(entries: entries)
        nav.query = "feedback"
        // Ask AI and Search the web follow the best match (Q174, Q176): the two feedback rows lead the rest.
        let found = nav.rows.filter { !$0.isOffer }
        #expect(Array(found.prefix(2)).map(\.title).sorted() == ["Report a bug", "Suggest an idea"])
        #expect(Set(found.prefix(2).map(\.target)) == [.action("engine.reportBug"), .action("engine.suggestIdea")])
    }
}
