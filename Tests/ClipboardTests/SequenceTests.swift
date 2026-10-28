import AppKit
import Testing
@testable import Clipboard

/// Paste in sequence (card agent-bo-95423071): the picks go on the pasteboard one by one, each paste giving the next.
/// A private pasteboard and an injected scheduler, so nothing waits and the real clipboard is never touched.
@Suite("Clipboard paste in sequence")
@MainActor
struct SequenceTests {
    let database = TemporaryDatabase()
    let pasteboard = NSPasteboard.makePrivate()

    func item(_ text: String) -> ClipItem {
        ClipItem(kind: .text, text: text, contents: [["public.utf8-plain-text": Data(text.utf8)]], sourceApp: nil)
    }

    /// Three texts in the history, picked newest first: gamma, beta, alpha.
    func picks(_ store: ClipboardStore) throws -> [StoredClip] {
        for (index, text) in ["alpha", "beta", "gamma"].enumerated() {
            try store.add(item(text), at: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
        }
        return try store.recent()
    }

    @Test("Start writes the first pick, transient; each paste writes the next after the settle delay; after the last it is done")
    func pastesInOrder() throws {
        let store = try ClipboardStore(path: database.path)
        let scheduler = Scheduler()
        var events: [PasteSequence.Event] = []
        let sequence = PasteSequence(pasteboard: pasteboard, after: scheduler.after) { events.append($0) }
        try sequence.start(try picks(store), from: store)
        #expect(pasteboard.string(forType: .string) == "gamma")
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil) == nil)
        #expect(sequence.isRunning)

        sequence.pasted()
        #expect(pasteboard.string(forType: .string) == "gamma")  // not before the app has read it
        scheduler.flush()
        #expect(pasteboard.string(forType: .string) == "beta")
        #expect(scheduler.delays == [PasteSequence.settle])
        sequence.pasted()
        scheduler.flush()
        #expect(pasteboard.string(forType: .string) == "alpha")
        sequence.pasted()
        scheduler.flush()
        #expect(pasteboard.string(forType: .string) == "alpha")
        #expect(!sequence.isRunning)
        #expect(events == [.started(3), .next(2, of: 3), .next(3, of: 3), .done(3)])
        // Done: a paste now changes nothing.
        sequence.pasted()
        scheduler.flush()
        #expect(pasteboard.string(forType: .string) == "alpha")
    }

    @Test("Something else copied between pastes ends it without writing; a new start replaces a running one")
    func endsOnOtherCopy() throws {
        let store = try ClipboardStore(path: database.path)
        let scheduler = Scheduler()
        var events: [PasteSequence.Event] = []
        let sequence = PasteSequence(pasteboard: pasteboard, after: scheduler.after) { events.append($0) }
        let clips = try picks(store)
        try sequence.start(clips, from: store)
        pasteboard.copy("copied elsewhere")
        sequence.pasted()
        scheduler.flush()
        #expect(pasteboard.string(forType: .string) == "copied elsewhere")
        #expect(!sequence.isRunning)
        #expect(events == [.started(3), .ended])

        try sequence.start(clips, from: store)
        try sequence.start(Array(clips.suffix(2)), from: store)
        #expect(pasteboard.string(forType: .string) == "beta")
        sequence.pasted()
        scheduler.flush()
        #expect(pasteboard.string(forType: .string) == "alpha")

        // A pick deleted from the history before its turn ends the sequence there.
        try sequence.start(clips, from: store)
        try store.delete(clips[1].id)
        sequence.pasted()
        scheduler.flush()
        #expect(!sequence.isRunning)
        #expect(events.last == .ended)
    }

    @Test("Ctrl+Return is paste one by one; Cmd+K lists it with ⌃↵ for two or more targets only")
    func panelKeys() throws {
        #expect(PanelCommand(key: .return, control: true, searchEmpty: true) == .pasteInSequence)
        #expect(PanelCommand(key: .return, control: true, searchEmpty: false) == .pasteInSequence)
        #expect(PanelCommand(key: .return, searchEmpty: true) == .paste(plain: false))
        let store = try ClipboardStore(path: database.path)
        let clips = try picks(store)
        #expect(ClipAction.pasteInSequence.title == "Paste one by one")
        #expect(ClipAction.pasteInSequence.key == "⌃↵")
        #expect(ClipAction.available(for: clips).contains(.pasteInSequence))
        #expect(!ClipAction.available(for: [clips[0]]).contains(.pasteInSequence))
    }
}
