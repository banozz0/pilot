import Foundation
import Synchronization
import Testing
@testable import PilotCore

/// AI binds (spec ai-binds T1): the words go to a runner with the apps and Pilot's actions, and only an answer Pilot's own
/// parsers accept comes back. Every runner here is a fake with a canned answer; the one real call waits for PILOT_LIVE=1.
@Suite("Bind AI")
struct BindAITests {
    static let catalogue = try! DriveCatalogue(json: Data(contentsOf: DriveCatalogueTests.shipped))
    static let sources = BindSearch.Sources(
        apps: [("Google Chrome", "com.google.Chrome"), ("Safari", "com.apple.Safari"), ("Ghostty", "com.mitchellh.ghostty"),
               ("Notes", "com.apple.Notes")],
        browsers: [("Google Chrome", "com.google.Chrome"), ("Safari", "com.apple.Safari")],
        actions: [.init(id: "windows.close", label: "Close window", module: "windows"),
                  // Bound ones the engine lists among its actions: never sent.
                  .init(id: "scripts.run:zebra-deploy.sh", label: "Zebra deploy", module: "drive"),
                  .init(id: "drive.shell:rsync ~/Vault nas:/walrus", label: "Shell: rsync", module: "drive")],
        catalogue: catalogue,
        scripts: [.init(id: "scripts.run:zebra-deploy.sh", label: "Zebra deploy", module: "drive")],
        extensions: [.init(id: "ext.okapi.focus", label: "Okapi focus", module: "drive")],
        quicklinks: BindSearch.quicklinks([Quicklink(name: "Narwhal search", keyword: "nw", url: "https://narwhal.example/?q={query}")]),
        configs: [.init(id: "configs.edit:quokka", label: "Quokka config", module: "apps")],
        shortcuts: ["Lemur routine"])

    /// The job a fake runner was handed.
    final class Sent: Sendable { let job = Mutex<QuickAI.Job?>(nil) }

    /// A runner that answers `answer` and keeps the job it was handed.
    static func fake(_ answer: String, sent: Sent? = nil) -> QuickAI.Runner {
        { job, _ in sent?.job.withLock { $0 = job }; return answer }
    }

    /// The model's JSON answer naming `id`.
    static func answer(_ id: String, reason: String = "") -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["id": id, "reason": reason]), encoding: .utf8)!
    }

    static func suggest(_ answer: String, _ text: String = "open YouTube in Chrome",
                        handles: (String) -> Bool = { _ in false }) async throws -> BindAI.Suggestion {
        try await BindAI.suggest(text, in: sources, handles: handles, runner: fake(answer))
    }

    static func id(_ s: BindAI.Suggestion) -> String? { if case .row(let row) = s { row.id } else { nil } }

    @Test("open YouTube in Chrome comes back as Chrome on youtube.com, the card in Pilot's words, the words sent as a bind job")
    func youtubeInChrome() async throws {
        let sent = Sent()
        let got = try await BindAI.suggest("open YouTube in Chrome", in: Self.sources, handles: { _ in false },
                                           runner: Self.fake(#"{"id": "apps.url:com.google.Chrome:https://youtube.com", "reason": "YouTube in Chrome"}"#, sent: sent))
        guard case .row(let row) = got else { Issue.record("no card: \(got)"); return }
        #expect(row.id == "apps.url:com.google.Chrome:https://youtube.com")
        #expect(row.title == "Open youtube.com in Google Chrome")
        #expect(row.bundle == "com.google.Chrome")
        let job = try #require(sent.job.withLock { $0 })
        guard case .bind(let input) = job else { Issue.record("not a bind job: \(job)"); return }
        #expect(input.hasPrefix("Request: open YouTube in Chrome\n"))
        #expect(job.prompt(at: .current) == BindAI.prompt)
    }

    @Test("A shell open of a page in a browser, a page or an app becomes that action, never shell (Q125)",
          arguments: [(#"open -a "Google Chrome" https://youtube.com"#, "apps.url:com.google.Chrome:https://youtube.com"),
                      (#"open -a 'google chrome.app' youtube.com"#, "apps.url:com.google.Chrome:https://youtube.com"),
                      ("open -b com.apple.Safari https://youtube.com", "apps.url:com.apple.Safari:https://youtube.com"),
                      ("open https://youtube.com", "apps.web:https://youtube.com"),
                      ("open -a Notes", "apps.open:com.apple.Notes")])
    func shellOpenIsReal(command: String, id: String) async throws {
        #expect(Self.id(try await Self.suggest(Self.answer("drive.shell:" + command))) == id)
    }

    @Test("A shell command no real action covers lands in the Shell form, in full")
    func shellForm() async throws {
        let command = #"osascript -e 'tell application "Finder" to empty trash'"#
        #expect(try await Self.suggest(Self.answer("drive.shell:" + command), "empty the trash") == .form(.shell(command)))
        // An open with more than a page or an app, or of an app not on this Mac, stays a command to read.
        for open in ["open -g ~/Downloads", "open -a Invented https://youtube.com"] {
            #expect(try await Self.suggest(Self.answer("drive.shell:" + open)) == .form(.shell(open)))
        }
    }

    @Test("Invented apps and browsers, pages that are not https and private windows are refused",
          arguments: ["apps.open:com.fake.Invented", "apps.url:com.fake.Browser:https://youtube.com",
                      "apps.url:com.apple.Notes:https://youtube.com", "apps.web:http://youtube.com", "apps.web:javascript:alert(1)",
                      "apps.web:youtube", "apps.private:com.apple.Safari", "drive.menu:com.fake.App:File > New",
                      "drive.shortcut:Lemur routine", "drive.key:cmd+nosuchkey", "windows.explode", "scripts.run:zebra-deploy.sh"])
    func refused(id: String) async throws {
        let got = try await Self.suggest(Self.answer(id))
        guard case .none = got else { Issue.record("\(id) gave \(got)"); return }
    }

    @Test("A bare host is read as https; Pilot actions and the catalogue's routes are cards; menu items and keys are forms")
    func shapes() async throws {
        #expect(Self.id(try await Self.suggest(Self.answer("apps.url:com.google.Chrome:youtube.com")))
                == "apps.url:com.google.Chrome:https://youtube.com")
        #expect(Self.id(try await Self.suggest(Self.answer("windows.close"))) == "windows.close")
        let quick = "drive.menu:com.mitchellh.ghostty:View > Quick Terminal"
        #expect(Self.id(try await Self.suggest(Self.answer(quick))) == quick)
        #expect(try await Self.suggest(Self.answer("drive.menu:com.apple.Notes:File > New Folder"))
                == .form(.menu(bundle: "com.apple.Notes", path: ["File", "New Folder"])))
        #expect(try await Self.suggest(Self.answer("drive.key:cmd+shift+t")) == .form(.keystroke(Key(spelling: "cmd+shift+t")!)))
    }

    @Test("An App URL needs an app that opens it, and is never a web page")
    func appURL() async throws {
        let answer = Self.answer("drive.url:shottr://grab/area")
        #expect(Self.id(try await Self.suggest(answer, handles: { $0 == "shottr://grab/area" })) == "drive.url:shottr://grab/area")
        guard case .none = try await Self.suggest(answer) else { Issue.record("no app opens it"); return }
        guard case .none = try await Self.suggest(Self.answer("drive.url:https://youtube.com"), handles: { _ in true }) else {
            Issue.record("http is a website"); return
        }
    }

    @Test("Null is no bind with the model's reason, clipped to 80; a fenced answer parses; prose alone is no bind")
    func answers() async throws {
        #expect(try await Self.suggest(#"{"id": null, "reason": "A key cannot make coffee"}"#) == .none("A key cannot make coffee"))
        let long = String(repeating: "x", count: 120)
        #expect(try await Self.suggest(#"{"id": null, "reason": "\#(long)"}"#) == .none(String(long.prefix(80))))
        let fenced = "Here it is:\n```json\n{\"id\": \"apps.open:com.apple.Notes\", \"reason\": \"a {brace}\"}\n```"
        #expect(Self.id(try await Self.suggest(fenced)) == "apps.open:com.apple.Notes")
        guard case .none = try await Self.suggest("I would open Chrome.") else { Issue.record("prose is no bind"); return }
    }

    @Test("Only the words, the apps, the browsers and Pilot's own actions are sent: no script, link, config, extension, Shortcut or bound command")
    func privacy() {
        let input = BindAI.input("open youtube in chrome", Self.sources)
        for name in ["zebra", "Zebra", "narwhal", "Narwhal", "quokka", "Quokka", "okapi", "Okapi", "Lemur", "walrus", "rsync"] {
            #expect(!input.contains(name), "\(name) was sent")
        }
        for sent in ["Google Chrome — com.google.Chrome", "windows.close — Close window", "drive.menu:com.mitchellh.ghostty:View > Quick Terminal"] {
            #expect(input.contains(sent))
        }
        // The catalogue's routes for apps not on this Mac stay out.
        #expect(!input.contains("com.openai.chat"))
    }

    @Test("The prompt ranks a page in the named browser first and shell last")
    func ranking() throws {
        let p = BindAI.prompt
        let browser = try #require(p.range(of: "a website in the browser the request names"))
        let shell = try #require(p.range(of: "A shell command is a last resort"))
        #expect(browser.lowerBound < shell.lowerBound)
        #expect(BindAI.shapes.split(separator: "\n").first?.contains("apps.url:") == true)
        #expect(BindAI.shapes.split(separator: "\n").last?.contains("drive.shell:") == true)
        let args = QuickAI.arguments(for: .bind("Request: secret words"))
        #expect(args.firstIndex(of: "--system-prompt").map { args[$0 + 1] } == BindAI.prompt)
        #expect(!args.contains { $0.contains("secret words") })
    }

    @Test("A streamed answer is taken once it holds a whole object, without waiting for the run to end")
    func early() async throws {
        let answer = #"{"id": "apps.url:com.google.Chrome:https://youtube.com", "reason": "r"}"#
        // Streamed in pieces, then a run that would take a minute more to exit, past suggest's 30 s clock. Taken early, the
        // run is stopped mid-wait: that, not a wall-clock bound (missed at load 60-80 in Build 65), shows no wait for its end.
        let stopped = Mutex(false)
        let slowExit: QuickAI.Runner = { _, text in
            text("Here: "); text(String(answer.prefix(20))); text(String(answer.dropFirst(20)))
            do { try await Task.sleep(for: .seconds(60)) } catch { stopped.withLock { $0 = true } }
            return answer
        }
        let got = try await BindAI.suggest("open YouTube in Chrome", in: Self.sources, handles: { _ in false }, runner: slowExit)
        #expect(Self.id(got) == "apps.url:com.google.Chrome:https://youtube.com")
        #expect(stopped.withLock { $0 }, "the answer came only as the run ended")
        // A runner that streams nothing still answers with what it returns.
        #expect(Self.id(try await Self.suggest(answer)) == "apps.url:com.google.Chrome:https://youtube.com")
    }

    @Test("A slow answer stops as timed out; the runner's failure comes through")
    func failures() async {
        let slow: QuickAI.Runner = { _, _ in try? await Task.sleep(for: .seconds(5)); return "{}" }
        await #expect(throws: QuickAI.Failure.timedOut) {
            try await BindAI.suggest("x", in: Self.sources, handles: { _ in false }, timeout: .milliseconds(100), runner: slow)
        }
        await #expect(throws: QuickAI.Failure.signedOut) {
            try await BindAI.suggest("x", in: Self.sources, handles: { _ in false }, runner: { _, _ throws(QuickAI.Failure) in throw .signedOut })
        }
    }
}

/// The real model (PILOT_LIVE=1): Claude Haiku at low effort through the Claude Code CLI, its own time limit.
@Suite("Bind AI, live")
struct BindAILiveTests {
    @Test("Live: open youtube in chrome gives Chrome on a youtube.com https page", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"),
          .timeLimit(.minutes(2)))
    func youtube() async throws {
        var cli = try #require(ClaudeCLI.locate(path: ProcessInfo.processInfo.environment["PATH"]), "claude isn't installed")
        cli.model = "haiku"
        cli.effort = .low
        cli.timeout = .seconds(60)
        let input = BindAI.input("open youtube in chrome", BindAITests.sources)
        let start = ContinuousClock.now
        let got = try await BindAI.suggest("open youtube in chrome", in: BindAITests.sources, handles: { _ in false }, timeout: .seconds(60),
                                           runner: cli.run(_:text:))
        print("live bind: \(got) in \(ContinuousClock.now - start), stdin \(input.utf8.count) bytes")
        guard case .row(let row) = got else { Issue.record("no card: \(got)"); return }
        #expect(row.id.hasPrefix("apps.url:com.google.Chrome:https://"))
        guard case .url(_, let page)? = AppLink(id: row.id) else { Issue.record("not a page: \(row.id)"); return }
        #expect(URL(string: page)?.host?.hasSuffix("youtube.com") == true)
    }
}
