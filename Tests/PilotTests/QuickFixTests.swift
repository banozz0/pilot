import AppKit
import Clipboard
import PilotCore
import Testing
@testable import Pilot

/// Quick AI's fix in place (S3): Hyper+Ctrl+F and the right-click Fix with Pilot, through a fake runner, a fake
/// selection and a held paste-back step. Nothing is pasted, copied or shown for real.
@Suite("Quick fix")
@MainActor
struct QuickFixTests {
    nonisolated static let source = SelectedText(text: " teh fox\n", pid: 42, app: "TextEdit")

    /// What the flow did, in order.
    final class Record {
        var tips: [String] = [], pasted: [String] = [], originals: [String] = [], copied: [String] = []
        /// The selection each read gives, the last one repeating.
        var selections: [SelectedText?] = [QuickFixTests.source]
    }

    func fix(_ record: Record, answer: Result<String, QuickAI.Failure> = .success("The fox."), front: pid_t? = 42) -> QuickFix {
        let fix = QuickFix()
        let run: QuickFix.Runner = { _, _ throws(QuickAI.Failure) in try answer.get() }
        fix.route = { .success(run) }
        fix.selection = { record.selections.count > 1 ? record.selections.removeFirst() : record.selections.first ?? nil }
        fix.secureInput = { false }
        fix.frontmost = { front }
        fix.paste = { record.pasted.append($0); record.originals.append($1) }
        fix.copy = { record.copied.append($0) }
        fix.tip = { text, _ in record.tips.append(text) }
        return fix
    }

    @Test("A fix goes over the selection at once, inside its own whitespace, the original to go on the clipboard after the paste")
    func pastes() async {
        let record = Record()
        await fix(record).fix()
        #expect(record.pasted == [" The fox.\n"] && record.originals == [" teh fox\n"] && record.copied.isEmpty)
        #expect(record.tips == [QuickFix.working, QuickFix.fixed])
    }

    @Test("The selection changed, or another app came to the front, while Claude worked: the fix is copied, never pasted")
    func selectionChanged() async {
        let changed = Record()
        changed.selections = [Self.source, SelectedText(text: "other", pid: 42, app: "TextEdit")]
        await fix(changed).fix()
        #expect(changed.pasted.isEmpty && changed.copied == [" The fox.\n"] && changed.tips.last == QuickFix.copied)
        let moved = Record()
        await fix(moved, front: 7).fix()
        #expect(moved.pasted.isEmpty && moved.copied == [" The fox.\n"] && moved.tips.last == QuickFix.copied)
    }

    @Test("A failure, a missing claude or an unchanged answer says so and touches nothing")
    func failures() async {
        let failed = Record()
        await fix(failed, answer: .failure(.signedOut)).fix()
        #expect(failed.tips == [QuickFix.working, "Claude Code is not signed in"] && failed.pasted.isEmpty && failed.copied.isEmpty)
        let same = Record()
        await fix(same, answer: .success("teh fox")).fix()
        #expect(same.tips.last == QuickFix.unchanged && same.pasted.isEmpty && same.copied.isEmpty)
        let missing = Record(), quick = fix(missing)
        quick.route = { .failure(.missing) }
        await quick.fix()
        #expect(missing.tips == ["Claude Code is not installed"] && missing.pasted.isEmpty)
        let keyless = Record(), api = fix(keyless)
        api.route = { .failure(.noKey(.openAI)) }
        await api.fix()
        #expect(keyless.tips == ["No OpenAI API key set"] && keyless.pasted.isEmpty && keyless.copied.isEmpty)
    }

    @Test("The selection comes from Accessibility when the app gives it, else from the app's own Copy in the app in front")
    func selection() async {
        var copies = 0
        let ax = await SelectedText.focused(accessibility: { Self.source }, copy: { copies += 1; return "x" }, front: { .current })
        #expect(ax == Self.source && copies == 0)
        let me = NSRunningApplication.current
        let copied = await SelectedText.focused(accessibility: { nil }, copy: { copies += 1; return "teh fox jumpd" }, front: { me })
        #expect(copied == SelectedText(text: "teh fox jumpd", pid: me.processIdentifier, app: me.localizedName ?? "the app") && copies == 1)
        #expect(await SelectedText.focused(accessibility: { nil }, copy: { nil }, front: { me }) == nil)
        #expect(await SelectedText.focused(accessibility: { nil }, copy: { Issue.record("copied with no app in front"); return "x" },
                                           front: { nil }) == nil)
    }

    @Test("Hyper+Ctrl+F with nothing selected, or in a password field, says so and runs nothing")
    func nothingSelected() async {
        let record = Record()
        record.selections = [nil]
        let quick = fix(record)
        quick.route = { Issue.record("looked for a route"); return .failure(.missing) }
        await quick.fix()
        #expect(record.tips == [QuickFix.nothingSelected])
        quick.secureInput = { true }
        quick.fixSelection()
        #expect(record.tips.last == QuickFix.password)
    }

    @Test("The service gets the fix back to return and the original goes on the clipboard; a failure returns nothing; tips wait for the answer")
    func service() async {
        let record = Record(), failed = Record()
        #expect(fix(record).fixForService(" teh fox\n") == " The fox.\n")
        #expect(fix(failed, answer: .failure(.timedOut)).fixForService("teh") == nil)
        #expect(record.copied == [" teh fox\n"] && record.pasted.isEmpty && failed.copied.isEmpty)
        #expect(record.tips.isEmpty && failed.tips.isEmpty)
        for _ in 0..<100 where failed.tips.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(record.tips == [QuickFix.fixed] && failed.tips == ["No answer in time"])
    }

    @Test("Fix with Pilot reads the text off its pasteboard and writes the fix back; no text or no fix leaves it and says why")
    func provider() {
        var asked: [String] = []
        let services = PilotServices(fix: { asked.append($0); return $0 == "teh" ? "the" : nil })
        let board = NSPasteboard(name: NSPasteboard.Name("dev.banozz.pilot.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        var error: NSString?
        board.clearContents()
        board.setString("teh", forType: .string)
        services.fixText(board, userData: nil, error: &error)
        #expect(board.string(forType: .string) == "the" && error == nil)
        board.clearContents()
        board.setString("  ", forType: .string)
        services.fixText(board, userData: nil, error: &error)
        #expect(error == "No text to fix")
        board.clearContents()
        board.setString("fine", forType: .string)
        error = nil
        services.fixText(board, userData: nil, error: &error)
        #expect(board.string(forType: .string) == "fine" && error == "Not fixed")
        #expect(asked == ["teh", "fine"])
    }

    @Test("Info.plist offers Fix with Pilot on selected text, taking and returning plain text, waiting as long as Claude may")
    func plist() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let service = try #require((plist["NSServices"] as? [[String: Any]])?.first { $0["NSMessage"] as? String == "fixText" })
        #expect((service["NSMenuItem"] as? [String: String])?["default"] == "Fix with Pilot")
        #expect(service["NSPortName"] as? String == "Pilot" && service["NSRequiredContext"] != nil)
        #expect(service["NSSendTypes"] as? [String] == ["public.utf8-plain-text"] && service["NSReturnTypes"] as? [String] == ["public.utf8-plain-text"])
        #expect(service["NSTimeout"] as? String == "120000")
    }

    @Test("Hyper+Space's Trigger lists Ask AI, Open AI chat, Fix selected text and Ask AI about selected text, so Quick AI shows with its binds")
    func trigger() throws {
        // In order, wherever they sit in the row (Read aloud follows them, story 190).
        let rows = MenuLayout.rows[.trigger] ?? []
        let ask = try #require(rows.firstIndex(of: .action(QuickAIActions.askID)))
        #expect(Array(rows[ask...].prefix(4)) == [.action(QuickAIActions.askID), .action(AIChatPanel.chatID), .action(QuickAIActions.fixID),
                                                  .action(QuickAIActions.selectionID)])
    }
}
