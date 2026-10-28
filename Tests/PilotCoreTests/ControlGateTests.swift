import Foundation
@testable import PilotCore
import Testing

/// The Allow gate (ADR 0013): which requests ask, and that only an Allow in time runs one, once. The deciders are
/// injected; no test shows the prompt.
@MainActor
@Suite("Control gate")
struct ControlGateTests {
    @Test("Every gated action id asks by its prefix, the rest as the request carries it, parsed or not", arguments: [
        ("drive.shell:rm -rf ~/tmp", "Run shell: rm -rf ~/tmp"),
        ("drive.shell:rm -rf ~/tmp --yes", "Run shell: rm -rf ~/tmp --yes"),
        ("drive.shell: ", "Run shell:  "),
        (#"drive.pick:{"list":"ls","run":"open $1"}"#, #"Run shell picker: {"list":"ls","run":"open $1"}"#),
        ("drive.pick:not json", "Run shell picker: not json"),
        ("drive.url:shottr://grab/window", "Open URL: shottr://grab/window"),
        ("drive.shortcut:Morning routine", "Run shortcut: Morning routine"),
        ("drive.key:shift+cmd+T", "Send keystroke: shift+cmd+T"),
        ("drive.key:not a key", "Send keystroke: not a key"),
        ("drive.bogus:anything", "Run: drive.bogus:anything"),
        ("scripts.run:backup.sh", "Run script: backup.sh"),
        (#"scripts.run:backup.sh/["--all"]"#, #"Run script: backup.sh/["--all"]"#),
        ("ext.todo.add", "Run extension command: todo.add, not found"),
        ("ext.broken", "Run extension command: broken, not found"),
        ("links.open:not-a-uuid", "Open quicklink: not-a-uuid, not found"),
        ("apps.web:pilot://run?id=drive.shell:x", "Open link: pilot://run?id=drive.shell:x"),
        ("apps.web:", "Open link: "),
        ("apps.url:com.apple.Safari:shortcuts://run-shortcut?name=x", "Open link: shortcuts://run-shortcut?name=x"),
        ("apps.url:no-colon", "Run: apps.url:no-colon"),
        ("apps.pastePlain", "Type the clipboard into the front app: apps.pastePlain"),
        ("system.shutDown", "Shut down the Mac: system.shutDown"),
        ("system.restart", "Restart the Mac: system.restart"),
        ("system.logOut", "Log out: system.logOut"),
    ])
    func gatedActions(_ id: String, _ question: String) {
        #expect(ControlGate.Ask.run(id)?.text == question)
    }

    @Test("A quicklink asks with its URL, query filled, whatever its scheme")
    func quicklinkAsks() {
        let search = Quicklink(name: "Search", keyword: "s", url: "https://example.com/?q={query}")
        let run = Quicklink(name: "Sneaky", keyword: "x", url: "pilot://run?id=drive.shell:rm")
        #expect(ControlGate.Ask.run("\(search.actionID):hello world", quicklinks: [search, run])?.text
                == "Open quicklink Search: https://example.com/?q=hello%20world")
        #expect(ControlGate.Ask.run(run.actionID, quicklinks: [search, run])?.text == "Open quicklink Sneaky: pilot://run?id=drive.shell:rm")
        #expect(BindStore.arrivesOff(search.actionID))
    }

    @Test("An extension command asks with its extension, its title and the program it runs")
    func extensionAsks() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/extension-catalogue/extensions")
        let extensions = Extension.find(in: folder).extensions
        let ask = try #require(ControlGate.Ask.run("ext.ports.kill-port", extensions: extensions))
        #expect(ask.title == "Run extension command Ports › Kill port")
        #expect(ask.detail == folder.appending(path: "ports/main.py").path(percentEncoded: false))
    }

    @Test("Plain actions run without asking", arguments: ["windows.snapLeft", "apps.open:com.mitchellh.ghostty",
                                                          "apps.web:https://linear.app", "apps.url:com.apple.Safari:http://x.dev",
                                                          "apps.private:company.thebrowser.Browser", "system.lock",
                                                          "drive.menu:com.apple.finder:File > New Finder Window"])
    func plainActions(_ id: String) {
        #expect(ControlGate.Ask.run(id) == nil)
    }

    @Test("The settings the pages confirm ask; any other setting does not")
    func settings() {
        for key in ["layerKey", "switch.on"] {
            #expect(ControlGate.Ask.set(key, to: "false")?.text == "Set \(key): false")
        }
        #expect(ControlGate.Ask.set("look.theme", to: "tokyo-night") == nil)
        #expect(ControlGate.Ask.set("quickTapEscape", to: "true") == nil)
    }

    @Test("An alias add does not ask; adding or removing software does")
    func collections() {
        #expect(ControlGate.Ask.add(to: "aliases", "gh") == nil)
        #expect(ControlGate.Ask.add(to: "quicklinks", "x") == nil)
        #expect(ControlGate.Ask.remove(from: "snippets", "sig") == nil)
        #expect(ControlGate.Ask.add(to: "packages", "obsidian")?.text == "Install package: obsidian")
        #expect(ControlGate.Ask.add(to: "webapps", "Linear")?.text == "Install web app: Linear")
        #expect(ControlGate.Ask.remove(from: "extensions", "demo")?.text == "Remove extension: demo")
    }

    @Test("Presses, applied imports and macOS shortcut changes always ask")
    func verbAsks() {
        #expect(ControlGate.Ask.press("ctrl+H", app: "Ghostty").text == "Press ctrl+H in: Ghostty")
        #expect(ControlGate.Ask.install(.extension, "~/demo").text == "Install extension: ~/demo")
        #expect(ControlGate.Ask.applyImport("3 binds, 1 switched off").text == "Apply import: 3 binds, 1 switched off")
        #expect(ControlGate.Ask.macShortcut("free ctrl+Space").text == "Change macOS shortcut: free ctrl+Space")
    }

    @Test("The question stays 60 s")
    func waitIsSixtySeconds() {
        #expect(ControlGate.wait == .seconds(60))
    }

    @Test("A real line break shows as ⏎ and a new line; typed backslashes double; bidi and invisible characters are written out")
    func visible() {
        // A typed backslash-n and a real line break read apart without colour.
        #expect(ControlGate.Ask.visible("echo \"done\nrm -rf ~ #\"") == "echo \"done⏎\nrm -rf ~ #\"")
        #expect(ControlGate.Ask.visible(#"echo done\n"#) == #"echo done\\n"#)
        #expect(ControlGate.Ask.visible("rm\u{202E}fdp.x ls\u{200B}\u{00A0}é🙂\t\r") == #"rm\u{202E}fdp.x ls\u{200B}\u{A0}é🙂\t\r"#)
        #expect(ControlGate.Ask.visible("\u{2066}\u{FEFF}\u{E0041}\u{7}⏎") == #"\u{2066}\u{FEFF}\u{E0041}\u{7}\u{23CE}"#)
    }

    @Test("A question past the longest shown, or with too many line breaks, is denied unasked, never cut")
    func tooLong() async {
        var asked = false
        let gate = ControlGate { _, _ in asked = true; return true }
        for long in [ControlGate.Ask("Run shell", String(repeating: "x", count: ControlGate.Ask.longest)),
                     ControlGate.Ask("Run shell", String(repeating: "x\n", count: ControlGate.Ask.mostLines + 1))] {
            let (runs, result) = await Self.run(gate, long)
            #expect(!asked && runs == 0)
            guard case .failure(let error) = result else { Issue.record("ran past the limit"); return }
            #expect(error.code == .denied && error.message.hasPrefix("not asked: the question"))
        }
        let fits = ControlGate.Ask("Run", String(repeating: "x", count: ControlGate.Ask.longest - 5))
        #expect(await Self.run(gate, fits).runs == 1)
    }

    @Test("What runs is what was shown: a quicklink changed while asking denies after the Allow and runs nothing")
    func changedWhileAsking() async {
        var link = Quicklink(name: "Docs", keyword: "d", url: "https://example.com")
        let id = link.actionID
        let gate = ControlGate { _, _ in link.url = "pilot://run?id=drive.shell:rm"; return true }
        var runs = 0
        do throws(ControlError) {
            try await gate.allow(.run(id, quicklinks: [link]), peer: nil) { () throws(ControlError) in runs += 1 }
            Issue.record("ran a changed quicklink")
        } catch {
            #expect(error.code == .denied && error.message == "changed while asking, so not run: Open quicklink Docs: https://example.com")
        }
        #expect(runs == 0)
    }

    /// The body's runs, and what the gate answered.
    static func run(_ gate: ControlGate, _ ask: ControlGate.Ask?) async -> (runs: Int, result: Result<String, ControlError>) {
        var runs = 0
        do throws(ControlError) {
            let value = try await gate.allow(ask, peer: ControlPeer(pid: getpid(), uid: getuid())) { () throws(ControlError) in
                runs += 1
                return "ran"
            }
            return (runs, .success(value))
        } catch {
            return (runs, .failure(error))
        }
    }

    static let shell = ControlGate.Ask.run("drive.shell:rm -rf ~/tmp")

    @Test("Allow runs the request once and asks again for the next")
    func allowRunsOnce() async {
        var asked: [ControlGate.Ask] = []
        let gate = ControlGate { ask, _ in asked.append(ask); return true }
        let first = await Self.run(gate, Self.shell)
        #expect(first.runs == 1 && first.result == .success("ran"))
        _ = await Self.run(gate, Self.shell)
        #expect(asked == [Self.shell, Self.shell])
    }

    @Test("Deny answers denied and runs nothing")
    func deny() async {
        let (runs, result) = await Self.run(ControlGate { _, _ in false }, Self.shell)
        #expect(runs == 0)
        #expect(result == .failure(ControlError(.denied, "not allowed: Run shell: rm -rf ~/tmp")))
    }

    @Test("No answer in time answers denied, runs nothing, and the prompt is cancelled")
    func noAnswer() async {
        var cancelled = false
        let gate = ControlGate(wait: .milliseconds(50)) { _, _ in
            try? await Task.sleep(for: .seconds(30))
            cancelled = Task.isCancelled
            return true
        }
        let (runs, result) = await Self.run(gate, Self.shell)
        #expect(runs == 0)
        guard case .failure(let error) = result else { Issue.record("ran without an answer"); return }
        #expect(error.code == .denied && error.message.hasPrefix("no answer in 0 s"))
        for _ in 0..<50 where !cancelled { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled)
    }

    @Test("An Allow after the deadline counts for nothing")
    func lateAllow() async {
        let gate = ControlGate(wait: .milliseconds(20)) { _, _ in
            // A prompt that ignores cancellation and answers Allow late.
            let late = Task { try? await Task.sleep(for: .milliseconds(60)); return true }
            return await late.value
        }
        let (runs, result) = await Self.run(gate, Self.shell)
        #expect(runs == 0 && (try? result.get()) == nil)
    }

    @Test("A request with nothing to ask runs without the decider")
    func noQuestion() async {
        var asked = false
        let (runs, result) = await Self.run(ControlGate { _, _ in asked = true; return false }, ControlGate.Ask.run("windows.snapLeft"))
        #expect(!asked && runs == 1 && result == .success("ran"))
    }
}
