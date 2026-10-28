import AppKit
import Testing
@testable import Clipboard

/// Paste as plain text from anywhere (card agent-bo-95423072): what is copied goes in without its formatting, and the
/// copy goes back afterwards. A private pasteboard, a recorded Cmd+V and a held put-back: nothing is posted or waited for.
@Suite("Clipboard plain paste")
@MainActor
struct PlainPasteTests {
    let database = TemporaryDatabase()
    let pasteboard = NSPasteboard.makePrivate()

    final class Recorder {
        var posts = 0
        var later: [() -> Void] = []
        var delays: [TimeInterval] = []
    }

    func plain(_ recorder: Recorder, store: ClipboardStore? = nil) -> PlainPaste {
        PlainPaste(pasteboard: pasteboard, store: store, post: { recorder.posts += 1 },
                   later: { recorder.delays.append($0); recorder.later.append($1) })
    }

    func copyRich() {
        pasteboard.clearContents()
        pasteboard.setString("bold words", forType: .string)
        pasteboard.setData(Data(#"{\rtf1 \b bold words}"#.utf8), forType: .rtf)
    }

    @Test("Rich text pastes as its string, transient, then the rich copy goes back, transient")
    func richText() {
        copyRich()
        let recorder = Recorder()
        #expect(plain(recorder).run() == 10)
        #expect(recorder.posts == 1)
        #expect(pasteboard.string(forType: .string) == "bold words")
        #expect(pasteboard.data(forType: .rtf) == nil)
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil) == nil)
        #expect(recorder.delays == [PasteBack.after])
        recorder.later.forEach { $0() }
        #expect(pasteboard.data(forType: .rtf) == Data(#"{\rtf1 \b bold words}"#.utf8))
        #expect(pasteboard.string(forType: .string) == "bold words")
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil) == nil)
    }

    @Test("Two plain pastes inside the put-back's half second leave the rich copy, not the plain text, on the pasteboard (card agent-bo-95423072)")
    func twoQuickPastes() {
        copyRich()
        let recorder = Recorder()
        plain(recorder).run()
        plain(recorder).run()
        #expect(recorder.posts == 2)
        recorder.later.forEach { $0() }
        #expect(pasteboard.data(forType: .rtf) == Data(#"{\rtf1 \b bold words}"#.utf8))
        #expect(pasteboard.string(forType: .string) == "bold words")
    }

    @Test("A paste with a copy to leave puts that copy back, an ordinary copy the history keeps, in place of the old one")
    func thenCopy() {
        copyRich()
        var later: [() -> Void] = []
        PasteBack.paste("The fox.", to: pasteboard, thenCopy: "teh fox", post: {}, later: { later.append($1) })
        #expect(pasteboard.string(forType: .string) == "The fox.")
        later.forEach { $0() }
        #expect(pasteboard.string(forType: .string) == "teh fox" && pasteboard.data(forType: .rtf) == nil)
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil)?.text == "teh fox")
    }

    @Test("An app's Copy gives its selected text, and the user's copy goes back, transient, at once")
    func copySelection() async {
        copyRich()
        var posts = 0
        let text = await PasteBack.copySelection(from: pasteboard, post: {
            posts += 1
            pasteboard.clearContents()
            pasteboard.setString("teh fox jumpd", forType: .string)
        }, sleep: { _ in })
        #expect(text == "teh fox jumpd" && posts == 1)
        #expect(pasteboard.string(forType: .string) == "bold words" && pasteboard.data(forType: .rtf) != nil)
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil) == nil)
    }

    @Test("An app whose Copy writes nothing in time, or only blank text, has no selection; the user's copy stays")
    func copySelectionNothing() async {
        copyRich()
        var naps = 0
        #expect(await PasteBack.copySelection(from: pasteboard, post: {}, sleep: { _ in naps += 1 }) == nil)
        #expect(naps == 25 && pasteboard.string(forType: .string) == "bold words")
        #expect(await PasteBack.copySelection(from: pasteboard, post: {
            pasteboard.clearContents()
            pasteboard.setString(" \n", forType: .string)
        }, sleep: { _ in }) == nil)
        #expect(pasteboard.string(forType: .string) == "bold words")
    }

    @Test("An app that clears the pasteboard and writes a moment later is waited for once more")
    func copySelectionLate() async {
        pasteboard.clearContents()
        let text = await PasteBack.copySelection(from: pasteboard, post: { pasteboard.clearContents() }, sleep: { _ in
            if pasteboard.string(forType: .string) == nil { pasteboard.setString("late", forType: .string) }
        })
        #expect(text == "late")
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true, "nothing was on it, so nothing goes back")
    }

    @Test("A second plain paste of the same copy, put back transient, pastes plain again (Moody REJECT 2-6oGB5iPpc)")
    func twice() {
        copyRich()
        for _ in 0..<2 {
            let recorder = Recorder()
            #expect(plain(recorder).run() == 10)
            #expect(pasteboard.data(forType: .rtf) == nil)
            recorder.later.forEach { $0() }
            #expect(pasteboard.data(forType: .rtf) != nil)
        }
    }

    @Test("A plain paste during a paste in sequence pastes the pick plain, ends the sequence, and the pick goes back")
    func duringSequence() throws {
        let store = try ClipboardStore(path: database.path)
        let rich = ClipItem(kind: .richText, text: "bold words", contents: [["public.utf8-plain-text": Data("bold words".utf8),
                                                                            "public.rtf": Data(#"{\rtf1 \b bold words}"#.utf8)]], sourceApp: nil)
        try store.add(rich, at: Date(timeIntervalSince1970: 1_800_000_000))
        try store.add(ClipItem(kind: .text, text: "next", contents: [["public.utf8-plain-text": Data("next".utf8)]], sourceApp: nil),
                      at: Date(timeIntervalSince1970: 1_800_000_001))
        let picks = try store.recent().reversed()
        var steps: [() -> Void] = [], events: [PasteSequence.Event] = []
        let sequence = PasteSequence(pasteboard: pasteboard, after: { steps.append($1) }) { events.append($0) }
        try sequence.start(Array(picks), from: store)
        #expect(pasteboard.data(forType: .rtf) != nil)
        let recorder = Recorder()
        #expect(plain(recorder, store: store).run() == 10)
        #expect(pasteboard.data(forType: .rtf) == nil)
        sequence.pasted()   // the tap saw Pilot's Cmd+V
        steps.forEach { $0() }
        #expect(events.last == .ended)
        recorder.later.forEach { $0() }
        #expect(pasteboard.data(forType: .rtf) != nil)
        #expect(pasteboard.string(forType: .string) == "bold words")
    }

    @Test("Something copied between the paste and the put-back stays")
    func newerCopyStays() {
        copyRich()
        let recorder = Recorder()
        plain(recorder).run()
        pasteboard.copy("copied meanwhile")
        recorder.later.forEach { $0() }
        #expect(pasteboard.string(forType: .string) == "copied meanwhile")
        #expect(pasteboard.data(forType: .rtf) == nil)
    }

    @Test("An image pastes its recognised text; an image without text, a password and an empty pasteboard paste as they are")
    func asIs() async throws {
        let store = try ClipboardStore(path: database.path)
        let png = try pasteboard.copyPNG()
        let item = try #require(ClipboardCapture().capture(pasteboard, sourceApp: nil))
        let id = try store.add(item)
        try store.setRecognised(id, "Invoice 42")
        let recorder = Recorder()
        #expect(plain(recorder, store: store).run() == 10)
        #expect(pasteboard.string(forType: .string) == "Invoice 42")
        recorder.later.forEach { $0() }
        #expect(pasteboard.data(forType: .png) == png)

        try store.setRecognised(id, "")
        let untouched: [() -> Void] = [
            { _ = try? self.pasteboard.copyPNG() },
            { self.pasteboard.copy("hunter2", marking: [.init("org.nspasteboard.ConcealedType")]) },
            { self.pasteboard.clearContents() },
        ]
        for copy in untouched {
            copy()
            let count = pasteboard.changeCount
            let recorder = Recorder()
            #expect(plain(recorder, store: store).run() == nil)
            #expect(recorder.posts == 1)
            #expect(recorder.later.isEmpty)
            #expect(pasteboard.changeCount == count)
        }
    }
}
