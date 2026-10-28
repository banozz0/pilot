import AppKit
import PilotCore
import Testing
@testable import Pilot

/// The selection box's read, replace and undo (spec ai-selected-text T2) through a fake world: Accessibility first, the
/// app's own Paste only when its write did not take, a copy instead once the app or its selection moved, the original
/// kept in the history. Nothing touches another app or the real clipboard.
@Suite("Selection edit")
@MainActor
struct SelectionEditTests {
    nonisolated static let notes = SelectionEdit.App(pid: 42, name: "Notes", bundleID: "com.apple.Notes")

    /// What the edit did, in order.
    final class Record {
        var front: SelectionEdit.App? = SelectionEditTests.notes
        var axSelected: String? = "teh fox"
        var writes: [String] = [], pastes: [String] = [], kept: [String] = [], copied: [String] = [], steps: [String] = []
        var writeTakes = true, pasteTakes = true, focused = true, menuText: String? = "teh fox"
        /// The selection each read after the first gives (a write that half took changes it).
        var afterWrite: String?
    }

    nonisolated static func ax(writable: Bool = true) -> SelectionTarget {
        SelectionTarget(text: "teh fox", pid: 42, app: "Notes", bundleID: "com.apple.Notes",
                        element: AXUIElementCreateApplication(42), range: CFRange(location: 10, length: 7), writable: writable)
    }

    nonisolated static let menu = SelectionTarget(text: "teh fox", pid: 42, app: "Notes", bundleID: "com.apple.Notes")

    func edit(_ r: Record) -> SelectionEdit {
        let edit = SelectionEdit()
        edit.world.front = { r.front }
        edit.world.focused = { nil }
        edit.world.menuCopy = { _ in r.steps.append("copy"); return r.menuText.map(SelectionEdit.MenuCopy.copied) ?? .nothing }
        edit.world.own = { nil }
        edit.world.selected = { _ in r.axSelected }
        edit.world.stillFocused = { _ in r.focused }
        edit.world.write = { _, text in
            r.writes.append(text)
            if let after = r.afterWrite { r.axSelected = after }
            return r.writeTakes
        }
        edit.world.menuPaste = { _, text in r.pastes.append(text); return r.pasteTakes }
        edit.world.menuUndo = { _ in r.steps.append("undo"); return true }
        edit.world.restore = { _ in r.steps.append("restore"); return true }
        edit.world.keep = { text, _ in r.kept.append(text) }
        edit.world.copy = { r.copied.append($0) }
        return edit
    }

    @Test("Accessibility's write goes first and keeps the original in the history; no paste")
    func accessibility() async {
        let r = Record()
        guard case .replaced(let done) = await edit(r).replace(Self.ax(), with: "The fox.") else { Issue.record("not replaced"); return }
        #expect(done.route == .accessibility && r.writes == ["The fox."] && r.pastes.isEmpty && r.kept == ["teh fox"] && r.copied.isEmpty)
    }

    @Test("A write that did not take falls through to the app's Paste; a read-only element goes straight there")
    func fallback() async {
        let r = Record()
        r.writeTakes = false
        guard case .replaced(let done) = await edit(r).replace(Self.ax(), with: "The fox.") else { Issue.record("not replaced"); return }
        #expect(done.route == .menu && r.pastes == ["The fox."] && r.kept == ["teh fox"])
        let readOnly = Record()
        _ = await edit(readOnly).replace(Self.ax(writable: false), with: "The fox.")
        #expect(readOnly.writes.isEmpty && readOnly.pastes == ["The fox."])
    }

    @Test("Text that came through Copy is copied again and checked before Paste")
    func menuRoute() async {
        let r = Record()
        guard case .replaced = await edit(r).replace(Self.menu, with: "The fox.") else { Issue.record("not replaced"); return }
        #expect(r.steps == ["copy"] && r.pastes == ["The fox."])
        let moved = Record()
        moved.menuText = "something else"
        guard case .copied = await edit(moved).replace(Self.menu, with: "The fox.") else { Issue.record("pasted over a moved selection"); return }
        #expect(moved.pastes.isEmpty && moved.copied == ["The fox."] && moved.kept.isEmpty)
    }

    @Test("Another app in front, or a selection that moved, copies the answer and writes nothing")
    func copies() async {
        let away = Record()
        away.front = SelectionEdit.App(pid: 7, name: "Safari", bundleID: nil)
        guard case .copied = await edit(away).replace(Self.ax(), with: "The fox.") else { Issue.record("wrote into another app"); return }
        #expect(away.writes.isEmpty && away.pastes.isEmpty && away.copied == ["The fox."])
        let moved = Record()
        moved.axSelected = "teh"
        guard case .copied = await edit(moved).replace(Self.ax(), with: "The fox.") else { Issue.record("wrote over a moved selection"); return }
        #expect(moved.writes.isEmpty && moved.pastes.isEmpty)
    }

    @Test("Pilot's own window: its text view's selection read directly, never Accessibility or Copy; Replace copies")
    func own() async {
        let r = Record()
        r.front = SelectionEdit.App(pid: getpid(), name: "Pilot", bundleID: "dev.banozz.pilot")
        let e = edit(r)
        var asked = 0
        e.world.focused = { asked += 1; return Self.ax() }
        e.world.own = { "my note" }
        let found = await e.capture()
        #expect(found?.text == "my note" && found?.pid == getpid() && found?.element == nil && asked == 0 && r.steps.isEmpty)
        e.world.own = { nil }
        #expect(await e.capture() == nil)
        guard let found, case .copied = await e.replace(found, with: "My note.") else { Issue.record("wrote into Pilot"); return }
        #expect(r.copied == ["My note."] && r.writes.isEmpty && r.pastes.isEmpty && r.steps.isEmpty)
    }

    @Test("An app with no Paste gets the answer copied")
    func noPaste() async {
        let r = Record()
        r.pasteTakes = false
        guard case .copied = await edit(r).replace(Self.menu, with: "The fox.") else { Issue.record("claimed a paste"); return }
        #expect(r.copied == ["The fox."] && r.kept.isEmpty)
    }

    @Test("Undo takes the way the text went in, and only while the app is in front")
    func undo() async {
        let r = Record()
        let e = edit(r)
        #expect(await e.undo(.init(target: Self.ax(), text: "The fox.", route: .accessibility)))
        #expect(await e.undo(.init(target: Self.menu, text: "The fox.", route: .menu)))
        #expect(r.steps == ["restore", "undo"])
        r.front = nil
        #expect(await !e.undo(.init(target: Self.menu, text: "The fox.", route: .menu)))
        #expect(r.steps == ["restore", "undo"])
    }

    @Test("Capture takes Accessibility's selection, else the front app's Copy; Pilot's own goes neither way")
    func capture() async {
        let r = Record()
        let e = edit(r)
        #expect(await e.capture()?.text == "teh fox" && r.steps == ["copy"])
        e.world.focused = { Self.ax() }
        #expect(await e.capture()?.element != nil && r.steps == ["copy"])
        e.world.focused = { nil }
        r.front = SelectionEdit.App(pid: getpid(), name: "Pilot", bundleID: nil)
        #expect(await e.capture() == nil && r.steps == ["copy"])
    }

    @Test("A write proves it took by the length it moved, else by the selection it left")
    func landed() {
        // Longer answer: the count must move by the difference.
        #expect(SelectionPrompt.landed(countBefore: 100, countAfter: 101, original: "teh fox", replacement: "The fox.", selectedAfter: ""))
        #expect(!SelectionPrompt.landed(countBefore: 100, countAfter: 100, original: "teh fox", replacement: "The fox.", selectedAfter: "teh fox"))
        // Same length: the selection must have changed.
        #expect(SelectionPrompt.landed(countBefore: 100, countAfter: 100, original: "teh", replacement: "the", selectedAfter: ""))
        #expect(!SelectionPrompt.landed(countBefore: 100, countAfter: 100, original: "teh", replacement: "the", selectedAfter: "teh"))
        // Nothing to read: taken as landed, so it is never pasted twice.
        #expect(SelectionPrompt.landed(countBefore: nil, countAfter: nil, original: "teh", replacement: "the", selectedAfter: nil))
        #expect(!SelectionPrompt.landed(countBefore: nil, countAfter: nil, original: "teh", replacement: "the", selectedAfter: "teh"))
    }

    @Test("Before the Paste fallback, an AX target must still have the keyboard and the original selection; else the answer is copied")
    func pasteGuard() async {
        let away = Record()
        away.writeTakes = false
        away.focused = false
        guard case .copied = await edit(away).replace(Self.ax(), with: "The fox.") else { Issue.record("pasted into another field"); return }
        #expect(away.writes == ["The fox."] && away.pastes.isEmpty && away.copied == ["The fox."] && away.kept.isEmpty)

        let half = Record()
        half.writeTakes = false
        half.afterWrite = ""
        guard case .copied = await edit(half).replace(Self.ax(), with: "The fox.") else { Issue.record("pasted over a half write"); return }
        #expect(half.pastes.isEmpty && half.copied == ["The fox."])

        let readOnly = Record()
        readOnly.focused = false
        guard case .copied = await edit(readOnly).replace(Self.ax(writable: false), with: "The fox.") else { Issue.record("pasted into another field"); return }
        #expect(readOnly.writes.isEmpty && readOnly.pastes.isEmpty)
    }
}
