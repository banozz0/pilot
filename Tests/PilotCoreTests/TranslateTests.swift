import Foundation
import Testing
@testable import PilotCore

/// Translate (card agent-bo-95422773; Vicinae's Translate, rebuilt on Apple's on-device translation): the direction,
/// the rows, and the Translate branch. The translator is faked; nothing here reaches a network or a model.
@Suite("Translate")
struct TranslateTests {
    struct Fake: Translator {
        var answer: Result<String, TranslateFailure>
        func translate(_ text: String, from: String, to: String) async throws(TranslateFailure) -> String {
            try answer.get().replacingOccurrences(of: "{dir}", with: "\(from)>\(to)")
        }
    }

    /// Card agent-bo-95423002: "gutenmorgen" came out "Buenos días" under the old Spanish-or-else rule.
    @Test("English goes to Spanish; Spanish, German run together, or anything else goes to English")
    func direction() {
        #expect(Translate.direction(for: "¿dónde está la estación de tren?") == ("es", "en"))
        #expect(Translate.direction(for: "where is the train station") == ("en", "es"))
        #expect(Translate.direction(for: "où est la gare") == ("fr", "en"))
        #expect(Translate.direction(for: "gutenmorgen") == ("de", "en"))
    }

    @Test("The pair is a setting: your language takes every other one, and text already in it goes to the second")
    func pair() throws {
        let french = try #require(TranslatePair(home: "en", other: "fr"))
        #expect(Translate.direction(for: "where is the train station", pair: french) == ("en", "fr"))
        #expect(Translate.direction(for: "¿dónde está la estación de tren?", pair: french) == ("es", "en"))
        let german = try #require(TranslatePair(home: "de", other: "en"))
        #expect(Translate.direction(for: "where is the train station", pair: german) == ("en", "de"))
        #expect(TranslatePair(home: "en", other: "en") == nil, "a language never translates into itself")
        #expect(TranslatePair.standard == TranslatePair(home: "en", other: "es"))
        #expect(TranslatePair.languages.contains("de") && TranslatePair.languages.contains("es"))
        // Setup's two pickers: picking the other side's language swaps the two, so a pair never repeats one.
        #expect(TranslatePair.standard.with(home: "de") == TranslatePair(home: "de", other: "es"))
        #expect(TranslatePair.standard.with(home: "es") == TranslatePair(home: "es", other: "en"))
        #expect(TranslatePair.standard.with(other: "en") == TranslatePair(home: "es", other: "en"))
        #expect(TranslatePair.standard.with(other: "fr") == french)
        #expect(TranslatePair.languages.map(Translate.name).first == "Arabic", "the pickers list languages by name")
        #expect(TranslatePair.languages.map(Translate.name) == TranslatePair.languages.map(Translate.name).sorted())
    }

    @Test("The pair is saved under two keys and read back; a missing or broken one is the standard pair")
    func pairSaved() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        #expect(TranslatePair(defaults: defaults) == .standard)
        let french = try #require(TranslatePair(home: "en", other: "fr"))
        french.save(to: defaults)
        #expect(TranslatePair(defaults: defaults) == french)
        defaults.set("en", forKey: TranslatePair.otherKey)
        #expect(TranslatePair(defaults: defaults) == .standard, "the same language twice is refused")
    }

    @Test("German typed run together reads German → English beside its translation")
    func germanRow() async {
        let rows = await Translate.rows(for: "gutenmorgen", with: Fake(answer: .success("good morning")))
        #expect(rows.first?.detail == "German → English · Return copies")
    }

    @Test("The answer is one row: the translation, which Return copies, with the direction beside it")
    func answer() async {
        let rows = await Translate.rows(for: "hola, ¿cómo estás?", with: Fake(answer: .success("hello {dir}")))
        #expect(rows.map(\.title) == ["hello es>en"])
        #expect(rows.first?.target == .copy("hello es>en"))
        #expect(rows.first?.detail == "Spanish → English · Return copies")
        #expect(rows.first?.home == .translate)
    }

    @Test("A language not downloaded offers the pane that downloads it; any other failure says so; one letter waits")
    func failures() async {
        let missing = await Translate.rows(for: "hola amigo", with: Fake(answer: .failure(.notInstalled)))
        #expect(missing.map(\.target) == [.action("system.translationLanguages")])
        #expect(missing.first?.title == "Download Spanish → English for translation")
        let failed = await Translate.rows(for: "hola amigo", with: Fake(answer: .failure(.failed)))
        #expect(failed.first?.title == "Could not translate this")
        #expect(await Translate.rows(for: "h", with: Fake(answer: .success("x"))).isEmpty)
    }

    @Test("The Translate branch sits in Trigger and lists its answer whatever was typed; Return runs the copy")
    func branch() {
        #expect(MenuLayout.rows[.trigger]?.contains(.branch(.translate)) == true)
        var nav = MenuNavigator(entries: [], branch: .translate)
        nav.query = "hola"
        // Translate.rows' answer, which matches nothing typed.
        let hello = MenuEntry(title: "hello", target: .copy("hello"), home: .translate, isAnswer: true)
        nav.provide(.answer, home: .translate, [hello])
        #expect(nav.rows.map(\.title) == ["hello"])
        #expect(nav.handle(.return) == .run(hello))
    }

    /// Card agent-bo-95422932: the root search translates "tr <text>" or "translate <text>" itself.
    @Test("The root translates what follows tr or translate, two characters or more; anything else is a search")
    func rootQuery() {
        #expect(Translate.query(for: "tr hola mundo") == "hola mundo")
        #expect(Translate.query(for: "Translate hola") == "hola")
        #expect(Translate.query(for: "TR  buenos días ") == "buenos días")
        for search in ["tr", "tr ", "tr h", "trello", "translation", "transmission", "hola"] {
            #expect(Translate.query(for: search) == nil, "\(search)")
        }
        #expect(Translate.query(for: "hola", in: .translate) == "hola", "inside Translate everything typed is the text")
        #expect(Translate.query(for: "tr hola", in: nil) == "hola")
        #expect(Translate.query(for: "tr hola", in: .apps) == nil, "no other branch translates")
        #expect(Translate.text(after: "tr ") == "", "the command typed, its text not yet")
        #expect(Translate.text(after: "tr") == nil)
    }

    @Test("At the root the translation is the first row, though its title matches nothing typed, and it is no pick")
    func rootAnswer() async throws {
        // Hola Travel matches both typed words, so it competes with the answer.
        let apps = ["Trello", "Transmission", "Hola Travel"].map { MenuEntry(title: $0, target: .app("com.example.\($0)"), home: .apps) }
        var nav = MenuNavigator(entries: apps)
        nav.query = "tr hola"
        #expect(nav.rows.first?.title == "Hola Travel", "before the answer arrives the matching app leads")
        let rows = await Translate.rows(for: "hola", with: Fake(answer: .success("hello")))
        let answer = try #require(rows.first)
        #expect(answer.isAnswer && answer.frecencyKey == nil)
        nav.provide(.answer, home: .translate, rows)
        #expect(nav.rows.first == answer)
        #expect(nav.handle(.return) == .run(answer), "the arriving answer takes the selection from the app")
        // Arrowed down onto the app before the answer came: the app stays selected.
        var moved = MenuNavigator(entries: apps + [MenuEntry(title: "Hola Transit", target: .app("com.example.transit"), home: .apps)])
        moved.query = "tr hola"
        _ = moved.handle(.down)
        let chosen = moved.selected
        moved.provide(.answer, home: .translate, rows)
        #expect(moved.selected == chosen)
        // The missing-language and failure rows open an action, yet are answers too: no pick either.
        for failure in [TranslateFailure.notInstalled, .failed] {
            let row = try #require(await Translate.rows(for: "hola", with: Fake(answer: .failure(failure))).first)
            #expect(row.target.key != nil && row.frecencyKey == nil)
        }
    }

    /// Holds every translation until released, and records what ran and how many ran at once.
    actor Gate: Translator {
        var texts: [String] = [], running = 0, mostAtOnce = 0, open = false
        private var held: [CheckedContinuation<Void, Never>] = []
        func translate(_ text: String, from: String, to: String) async throws(TranslateFailure) -> String {
            texts.append(text)
            running += 1
            mostAtOnce = max(mostAtOnce, running)
            if !open { await withCheckedContinuation { held.append($0) } }
            running -= 1
            return text.uppercased()
        }
        func release() { open = true; held.forEach { $0.resume() }; held = [] }
    }

    static func until(_ ready: () async -> Bool) async { while await !ready() { await Task.yield() } }

    /// Card agent-bo-95422979: Apple's engine runs one translation after another and a cancelled one runs to its end,
    /// so every text typed during a translation queued behind it (measured: 1932 ms behind one, 736 ms alone).
    @Test("One translation at a time: a text replaced while it waits is never translated, and only the newest answers")
    func latestWins() async {
        let gate = Gate()
        let runner = TranslateRunner(translator: gate)
        async let first = runner.rows(for: "one two", pair: .standard)
        await Self.until { await gate.texts.count == 1 }
        async let second = runner.rows(for: "two three", pair: .standard)
        await Self.until { await runner.generation == 2 }
        async let third = runner.rows(for: "three four", pair: .standard)
        await Self.until { await runner.generation == 3 }
        await gate.release()
        let answers = await [first, second, third]
        #expect(answers.map { $0?.map(\.title) } == [nil, nil, ["THREE FOUR"]])
        #expect(await gate.texts == ["one two", "three four"])
        #expect(await gate.mostAtOnce == 1)
    }

    /// Card agent-bo-95422979: the first translation in a process took 2937 ms and the next 178 to 940, whichever
    /// direction; warming as Translate opens pays that while Sven types.
    @Test("Warming translates one short word, and a text typed meanwhile waits its turn instead of running beside it")
    func warm() async {
        let gate = Gate()
        let runner = TranslateRunner(translator: gate)
        let warming = Task { await runner.warm() }
        await Self.until { await gate.texts.count == 1 }
        async let typed = runner.rows(for: "hello there", pair: .standard)
        await Self.until { await runner.generation == 1 }
        await runner.warm()
        await gate.release()
        await warming.value
        #expect(await typed?.map(\.title) == ["HELLO THERE"])
        #expect(await gate.texts == ["hola", "hello there"], "a second warm while one runs does nothing")
        #expect(await gate.mostAtOnce == 1)
    }
}
