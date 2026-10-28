import AppKit
import PilotCore
import Testing
@testable import Pilot

/// The chat bubble on the selection (Sven Q217, Q218): a chip rewrites in one shot and its answer waits on Replace; typed
/// words ask about the selection, which rides in the message; Re-prompt puts the instruction back; Escape closes and the
/// conversation goes. Fake runners, a fake edit world and a held panel; nothing reaches another app.
@Suite("Selection box")
@MainActor
struct SelectionBoxTests {
    nonisolated static let notes = SelectionEdit.App(pid: 42, name: "Notes", bundleID: "com.apple.Notes")
    nonisolated static let target = SelectionTarget(text: "  teh fox ", pid: 42, app: "Notes", bundleID: "com.apple.Notes",
                                                    element: AXUIElementCreateApplication(42), range: CFRange(location: 0, length: 10), writable: true)

    @MainActor final class Record {
        var jobs: [QuickAI.Job] = [], asked: [AIChat.Request] = [], tips: [String] = [], writes: [String] = [], copied: [String] = []
        var shown = 0, hidden = 0
        var undo: HUD.TipAction?
        var keyReached: (@MainActor () -> Void)?, watching = false
        var secure = false
        var selection: SelectionTarget? = SelectionBoxTests.target
    }

    func box(_ r: Record, answer: Result<String, QuickAI.Failure> = .success("The fox."), reply: String = "A fox.") -> SelectionBox {
        let box = SelectionBox()
        let run: QuickAI.Runner = { job, _ throws(QuickAI.Failure) in
            await MainActor.run { r.jobs.append(job) }
            return try answer.get()
        }
        let chat: AIChat.Runner = { request, _ throws(QuickAI.Failure) in
            await MainActor.run { r.asked.append(request) }
            return AIChat.Reply(reply)
        }
        box.route = { .success(run) }
        box.chatRoute = { .success(chat) }
        let edit = SelectionEdit()
        edit.world.front = { Self.notes }
        edit.world.focused = { r.selection }
        edit.world.menuCopy = { _ in .nothing }
        edit.world.selected = { $0.text }
        edit.world.stillFocused = { _ in true }
        edit.world.write = { _, text in r.writes.append(text); return true }
        edit.world.keep = { _, _ in }
        edit.world.copy = { r.copied.append($0) }
        box.edit = edit
        box.secureInput = { r.secure }
        box.tip = { text, _, action in r.tips.append(text); if action != nil { r.undo = action } }
        box.present = { _, _ in r.shown += 1 }
        box.dismiss = { _ in r.hidden += 1 }
        box.watchKeys = { reached in r.keyReached = reached; r.watching = true; return { r.watching = false } }
        return box
    }

    func opened(_ r: Record, answer: Result<String, QuickAI.Failure> = .success("The fox.")) async -> SelectionBox {
        let b = box(r, answer: answer)
        b.open()
        for _ in 0..<100 where r.shown == 0 && r.tips.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        return b
    }

    func settle(_ b: SelectionBox) async {
        for _ in 0..<200 where b.model.chat.running { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("A chip sends its instruction with the selection; the answer, fitted to it, waits on Replace, nothing written")
    func chip() async {
        let r = Record()
        let b = await opened(r)
        #expect(r.shown == 1 && b.isShown && !b.model.started && b.model.quote == "teh fox")
        let preset = SelectionPrompt.chips[2]
        b.send(preset)
        await settle(b)
        #expect(r.jobs == [.rewrite("  teh fox ", instruction: preset.instruction)])
        #expect(b.model.chat.turns.map(\.text) == ["Make concise", "  The fox. "] && b.model.replaces && r.writes.isEmpty)
    }

    @Test("Typed words ask about the selection: it rides in the message, the turn shows the words alone, no Replace bar")
    func question() async {
        let r = Record()
        let b = await opened(r)
        b.sendDraft()
        #expect(!b.model.started)
        b.model.chat.draft = " what is this? "
        b.sendDraft()
        await settle(b)
        #expect(r.jobs.isEmpty && r.asked.map(\.message) == [SelectionPrompt.ask("what is this?", about: "  teh fox ")])
        #expect(b.model.chat.turns.map(\.text) == ["what is this?", "A fox."] && b.model.chat.draft.isEmpty && !b.model.replaces)
        b.model.chat.draft = "and in French?"
        b.sendDraft()
        await settle(b)
        #expect(r.asked.count == 2 && r.asked[1].message.contains("<selected_text>\n  teh fox \n</selected_text>")
                && r.asked[1].history.map(\.text) == ["what is this?", "A fox."])
    }

    @Test("Re-prompt puts the instruction back in the input; sent, it runs again as a rewrite")
    func reprompt() async {
        let r = Record()
        let b = await opened(r)
        b.send(SelectionPrompt.chips[0])
        await settle(b)
        b.reprompt()
        #expect(b.model.chat.draft == SelectionPrompt.chips[0].instruction && b.model.reprompting)
        b.model.chat.draft = "Fix the spelling only."
        b.sendDraft()
        await settle(b)
        #expect(r.jobs.last == .rewrite("  teh fox ", instruction: "Fix the spelling only.") && r.asked.isEmpty)
        #expect(b.model.replaces && !b.model.reprompting && b.model.chat.turns.count == 4)
    }

    @Test("Replace (⌘Return) closes the bubble, puts the last answer over the selection, and the tip's Undo puts it back")
    func replace() async throws {
        let r = Record()
        let b = await opened(r)
        b.send(SelectionPrompt.chips[0])
        await settle(b)
        b.replace()
        #expect(r.hidden >= 1 && !b.isShown && b.model.chat.turns.isEmpty)
        for _ in 0..<200 where r.tips.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(r.writes == ["  The fox. "] && r.tips == [SelectionBox.replaced])
        var restored = false
        b.edit.world.restore = { _ in restored = true; return true }
        try #require(r.undo).run()
        for _ in 0..<200 where r.tips.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(restored && r.tips.last == SelectionBox.undone)
    }

    @Test("Copy puts the answer on the clipboard and writes nothing")
    func copy() async {
        let r = Record()
        let b = await opened(r)
        b.send(SelectionPrompt.more[0])
        await settle(b)
        b.copyAnswer()
        #expect(r.copied == ["  The fox. "] && r.writes.isEmpty && r.tips == [SelectionBox.copied] && !b.isShown)
    }

    @Test("A failure shows the provider's words; a password field or no selection opens nothing")
    func failures() async {
        let r = Record()
        let b = await opened(r, answer: .failure(.noKey(.openAI)))
        b.send(SelectionPrompt.chips[0])
        await settle(b)
        #expect(b.model.chat.state == .failed(.noKey(.openAI)) && b.model.answer == nil)
        b.replace()
        #expect(b.isShown && r.writes.isEmpty)

        let secure = Record()
        secure.secure = true
        _ = await opened(secure)
        #expect(secure.shown == 0 && secure.tips == [SelectionBox.password])
        let none = Record()
        none.selection = nil
        _ = await opened(none)
        #expect(none.shown == 0 && none.tips == [SelectionBox.nothingSelected])
    }

    @Test("Escape while running stops the run, closes, and the conversation goes")
    func escape() async {
        let r = Record()
        let b = await opened(r)
        let slow: QuickAI.Runner = { _, _ throws(QuickAI.Failure) in try? await Task.sleep(for: .seconds(5)); return "late" }
        b.route = { .success(slow) }
        b.send(SelectionPrompt.chips[0])
        b.close()
        #expect(!b.isShown && !b.model.chat.running && b.model.chat.turns.isEmpty && r.writes.isEmpty)
    }

    @Test("The box sits under the selection, above it at the screen's foot, near the top without one, always on screen")
    func placement() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900), size = CGSize(width: 680, height: 104)
        #expect(SelectionBox.frame(size: size, selection: CGRect(x: 200, y: 500, width: 80, height: 18), screen: screen).origin == CGPoint(x: 200, y: 388))
        #expect(SelectionBox.frame(size: size, selection: CGRect(x: 200, y: 60, width: 80, height: 18), screen: screen).origin == CGPoint(x: 200, y: 86))
        #expect(SelectionBox.frame(size: size, selection: CGRect(x: 1300, y: 500, width: 80, height: 18), screen: screen).maxX == 1432)
        let top = SelectionBox.frame(size: size, selection: nil, screen: screen)
        #expect(top.midX == 720 && top.maxY == 900 - 162)
    }

    @Test("The bubble is short until the first message, then tall for the turns")
    func height() {
        #expect(SelectionBox.height(started: false) == 214 && SelectionBox.height(started: true) == 460)
    }

    @Test("Ask AI about selected text is registered on Hyper+Ctrl+A, a key nothing else holds, and listed in Trigger")
    func action() {
        var registry = ActionRegistry()
        QuickAIActions.register(into: &registry)
        let key = Key("a", .ctrl)
        #expect(registry.actions["ai.selection"]?.label == "Ask AI about selected text" && registry.defaults["ai.selection"] == key)
        #expect(registry.defaults.filter { $0.value == key }.count == 1)
        #expect(!PilotDefault.binds.values.contains(key) && !MyBinds.extras.values.contains(key))
        let engine = Engine()
        #expect(engine.registry.defaults.filter { $0.value == key }.map(\.key) == ["ai.selection"])
        #expect(!Abilities.canTry("ai.selection"))
        #expect(engine.registry.actions[SelectionTools.id]?.label == "Selection tools" && engine.registry.defaults[SelectionTools.id] == nil)
    }

    @Test("Ask Pilot AI hands the pasteboard's text to the box and returns nothing; no text says so")
    func service() {
        var asked: [String] = []
        let services = PilotServices(ask: { asked.append($0) })
        let board = NSPasteboard(name: NSPasteboard.Name("dev.banozz.pilot.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        var error: NSString?
        board.clearContents()
        board.setString("teh fox", forType: .string)
        services.askText(board, userData: nil, error: &error)
        #expect(asked == ["teh fox"] && error == nil && board.string(forType: .string) == "teh fox")
        board.clearContents()
        board.setString(" \n", forType: .string)
        services.askText(board, userData: nil, error: &error)
        #expect(asked == ["teh fox"] && error == "No text selected")
    }

    @Test("The service's text takes Accessibility's target when it reads the same, else the front app's")
    func serviceTarget() async {
        let r = Record()
        let b = box(r)
        let ax = await b.edit.capture(given: "  teh fox ")
        #expect(ax?.element != nil)
        let menu = await b.edit.capture(given: "other words")
        #expect(menu?.element == nil && menu?.text == "other words" && menu?.pid == 42)
    }

    @Test("Info.plist offers Ask Pilot AI on selected text, sending plain text and taking none back")
    func plist() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let service = try #require((plist["NSServices"] as? [[String: Any]])?.first { $0["NSMessage"] as? String == "askText" })
        #expect((service["NSMenuItem"] as? [String: String])?["default"] == "Ask Pilot AI")
        #expect(service["NSPortName"] as? String == "Pilot" && service["NSRequiredContext"] != nil)
        #expect(service["NSSendTypes"] as? [String] == ["public.utf8-plain-text"] && service["NSReturnTypes"] == nil)
    }

    @Test("A key reaching the app after Replace takes Undo away; the tip's Undo then does nothing")
    func keyEndsUndo() async throws {
        let r = Record()
        let b = await opened(r)
        b.send(SelectionPrompt.chips[0])
        await settle(b)
        b.replace()
        for _ in 0..<200 where r.tips.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(b.undoable != nil && r.watching)
        var restored = false
        b.edit.world.restore = { _ in restored = true; return true }
        let key = try #require(r.keyReached)
        key()
        #expect(b.undoable == nil && !r.watching && r.tips == [SelectionBox.replaced, SelectionBox.replaced])
        try #require(r.undo).run()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!restored && r.tips.count == 2)
    }
}
