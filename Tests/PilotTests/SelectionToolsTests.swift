import AppKit
import PilotCore
import Testing
@testable import Pilot

/// The selection pill (Sven Q213 to Q216): Hyper held, a left drag and the release show it; a click, a plain drag, a
/// skipped app or Hyper moving windows do not. A button reads the selection only when pressed. Mouse events made here
/// go straight to the handler; no tap is installed and nothing reaches another app.
@Suite("Selection tools")
@MainActor
struct SelectionToolsTests {
    @MainActor final class Record {
        var shown: [CGPoint] = [], hidden = 0, tips: [String] = [], copied: [String] = [], translated: [String] = [], layerUses = 0
        var inPanel = false
        var textPanel: NSWindow?
        var menu: SelectionEdit.MenuCopy = .nothing
        var selection: SelectionTarget? = SelectionBoxTests.target
        var secure = false
    }

    func tools(_ r: Record, front: String = "com.apple.Notes") -> SelectionTools {
        let tools = SelectionTools(defaults: UserDefaults(suiteName: testSuite())!)
        tools.front = { front }
        tools.ownPanel = { _ in r.inPanel ? .selection : r.textPanel.map { .text($0) } }
        tools.useLayer = { r.layerUses += 1 }
        tools.present = { _, point in r.shown.append(point) }
        tools.dismiss = { _ in r.hidden += 1 }
        tools.tip = { r.tips.append($0) }
        tools.translate = { r.translated.append($0) }
        tools.secureInput = { r.secure }
        let edit = SelectionEdit()
        edit.world.front = { SelectionBoxTests.notes }
        edit.world.focused = { r.selection }
        edit.world.menuCopy = { _ in r.menu }
        edit.world.copy = { r.copied.append($0) }
        tools.edit = edit
        return tools
    }

    func press(_ tools: SelectionTools, from: CGPoint, to: CGPoint) async {
        tools.handle(type: .leftMouseDown, event: CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)!)
        tools.handle(type: .leftMouseUp, event: CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)!)
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test("Hyper held and a drag shows the pill where the release was; a Hyper click or a plain drag shows none")
    func gesture() async {
        let r = Record()
        let t = tools(r)
        await press(t, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 104))
        #expect(r.shown.isEmpty)
        t.hyper(true)
        await press(t, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 102, y: 101))
        #expect(r.shown.isEmpty)
        await press(t, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 104))
        #expect(r.shown == [CGPoint(x: 220, y: Screens.primaryHeight - 104)] && t.isShown)
    }

    @Test("No pill in a terminal until it leaves the skip list, nor on Pilot's own panels; the press still uses Hyper, so no bind list")
    func skipped() async {
        let r = Record()
        let terminal = tools(r, front: "com.apple.Terminal")
        await press(terminal, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 100))
        #expect(r.layerUses == 0)
        terminal.hyper(true)
        await press(terminal, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 100))
        #expect(r.shown.isEmpty && r.layerUses == 1)
        r.inPanel = true
        let pilot = tools(r, front: "dev.banozz.pilot")
        pilot.hyper(true)
        await press(pilot, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 100))
        #expect(r.shown.isEmpty && r.layerUses == 2)
        r.inPanel = false
        await press(pilot, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 100))
        #expect(r.shown.count == 1)
        r.shown = []
        terminal.skipped = ["com.mitchellh.ghostty"]
        await press(terminal, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 100))
        #expect(r.shown.count == 1)
    }

    @Test("A press over a click-through overlay (window border, Defocus) passes to the app; the pill's panel takes it; Quick notes' is text")
    func overlays() {
        let point = CGPoint(x: 300, y: 300), around = CGRect(x: 0, y: 0, width: 800, height: 600)
        let border = WindowBorderPanel.overlay()
        border.setFrame(around, display: false)
        #expect(SelectionTools.ownPanel(border, at: point) == nil)
        let pill = KeyPanel(contentRect: around, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        pill.identifier = SelectionTools.panelID
        if case .selection = SelectionTools.ownPanel(pill, at: point) {} else { Issue.record("the pill's panel raises no pill") }
        #expect(SelectionTools.ownPanel(pill, at: CGPoint(x: 900, y: 300)) == nil)
        let notes = KeyPanel(contentRect: around, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        if case .text(let window) = SelectionTools.ownPanel(notes, at: point) { #expect(window === notes) } else { Issue.record("Quick notes vetoed") }
    }

    /// A panel of Pilot's holding a text view with `text` selected, never ordered in.
    func notesPanel(_ text: String, selected: NSRange) -> NSWindow {
        let panel = KeyPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let view = NSTextView(frame: panel.contentLayoutRect)
        view.string = text
        panel.contentView = view
        panel.makeFirstResponder(view)
        view.setSelectedRange(selected)
        return panel
    }

    @Test("Hyper+drag in Quick notes shows the pill and works on the note's selection, not the app in front (Build 63)")
    func quickNotes() async {
        let r = Record()
        r.selection = nil
        let panel = notesPanel("buy milk and eggs", selected: NSRange(location: 4, length: 4))
        r.textPanel = panel
        let t = tools(r, front: "com.madda.ghostex.host")
        t.hyper(true)
        await press(t, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 100))
        #expect(r.shown.count == 1)
        t.press(.copy)
        for _ in 0..<100 where r.tips.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(r.copied == ["milk"] && r.tips == [SelectionBox.copied])
        (panel.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: 0))
        r.selection = SelectionBoxTests.target
        await press(t, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 100))
        t.press(.copy)
        for _ in 0..<100 where r.tips.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(r.copied == ["milk"] && r.tips.last == SelectionBox.nothingSelected, "nothing selected in the note never reads the app behind it")
    }

    @Test("Copy reads the selection when pressed and copies it; a password field or no selection says so")
    func copy() async {
        let r = Record()
        let t = tools(r)
        t.showAtPointer()
        t.press(.copy)
        for _ in 0..<100 where r.tips.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(r.hidden == 1 && !t.isShown && r.copied == ["  teh fox "] && r.tips == [SelectionBox.copied])
        r.selection = nil
        t.press(.copy)
        for _ in 0..<100 where r.tips.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        r.secure = true
        t.press(.read)
        #expect(r.tips == [SelectionBox.copied, SelectionBox.nothingSelected, QuickFix.password] && r.copied.count == 1)
    }

    @Test("An app with no Copy to press (Ghostex's terminal) is named in the tip, never \"No text selected\"")
    func noCopy() async {
        let r = Record()
        r.selection = nil
        r.menu = .noCopy
        let t = tools(r)
        t.press(.copy)
        for _ in 0..<100 where r.tips.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        r.menu = .nothing
        t.press(.copy)
        for _ in 0..<100 where r.tips.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(r.tips == [SelectionEdit.noCopy("Notes"), SelectionBox.nothingSelected] && r.copied.isEmpty)
    }

    @Test("Translate hands the selection to the Pilot menu's Translate, never the AI bubble")
    func translate() async {
        let r = Record()
        let t = tools(r)
        t.press(.translate)
        for _ in 0..<100 where r.translated.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(r.translated == ["  teh fox "] && !SelectionBox.shared.isShown && r.tips.isEmpty)
    }

    @Test("The skip list is the terminals until set; `pilot set selection.pillSkip` takes bundle ids, comma-separated")
    func skipSetting() async throws {
        let tools = SelectionTools(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let schema = SettingsSchema(), verbs = ControlVerbs()
        schema.registerSelection(tools)
        verbs.registerSettings(schema) { _, _, _ in true }
        func ask(_ verb: String, _ args: String...) async -> ControlAnswer { await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil) }
        #expect(tools.skipped == SelectionPill.standardSkip)
        #expect(await ask("get", SelectionPill.skipKey).result == .string(SelectionPill.standardSkip.joined(separator: ",")))
        #expect(await ask("set", SelectionPill.skipKey, "com.apple.Terminal, dev.zed.Zed").ok)
        #expect(tools.skipped == ["com.apple.Terminal", "dev.zed.Zed"])
        #expect(await ask("get", SelectionPill.skipKey).result == .string("com.apple.Terminal,dev.zed.Zed"))
    }

    @Test("The pill sits centred over the release, under it at the screen's top, always on screen")
    func placement() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900), size = CGSize(width: 380, height: 36)
        #expect(SelectionTools.frame(size: size, at: CGPoint(x: 700, y: 400), screen: screen) == CGRect(x: 510, y: 412, width: 380, height: 36))
        #expect(SelectionTools.frame(size: size, at: CGPoint(x: 700, y: 880), screen: screen).maxY == 868)
        #expect(SelectionTools.frame(size: size, at: CGPoint(x: 10, y: 400), screen: screen).minX == 8)
    }
}
