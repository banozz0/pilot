import AppKit
import Testing
@testable import Clipboard

extension MainLoopClock {
/// Return on picks with an image among them (Sven, build 36): one Cmd+V on a pasteboard of several items landed only
/// the image or only the text, so they go in steps, a Cmd+V each. A private pasteboard and a held scheduler.
@Suite("Clipboard paste in steps")
@MainActor
struct PasteStepsTests {
    let database = TemporaryDatabase()
    let pasteboard = NSPasteboard.makePrivate()
    let png = Data([0x89, 0x50, 0x4E, 0x47])

    /// The panel's rows, newest first: a, b, an image, c.
    func rows(_ store: ClipboardStore) throws -> [StoredClip] {
        let items = [text("c"), ClipItem(kind: .image, text: "", contents: [["public.png": png]], sourceApp: nil), text("b"), text("a")]
        for (index, item) in items.enumerated() { try store.add(item, at: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))) }
        return PanelRows.ordered(try store.recent())
    }

    func text(_ text: String) -> ClipItem {
        ClipItem(kind: .text, text: text, contents: [["public.utf8-plain-text": Data(text.utf8)]], sourceApp: nil)
    }

    /// What each step puts on: its text, or "image".
    func shown(_ steps: [PanelRows.Paste]?) -> [String]? {
        steps?.map { $0.text.isEmpty ? "image" : $0.text }
    }

    @Test("Shift+Down over a, b, the image and c pastes texts joined around the image, in pick order; Cmd+Return picks keep theirs")
    func selectionToSteps() throws {
        let store = try ClipboardStore(path: database.path)
        let rows = try rows(store)
        var selection = PanelSelection()
        for _ in 0..<3 { selection.extend(1, in: rows) }
        let extended = try PanelRows.pastes(selection.targets(in: rows), from: store, plain: false)
        #expect(shown(PanelRows.steps(extended)) == ["a\nb", "image", "c"])
        #expect(PanelRows.steps(extended)?[1].contents == [["public.png": png]])

        // Cmd+Return on c, the image, then a: pick order, not the panel's.
        var picked = PanelSelection()
        for index in [3, 2, 0] { picked.toggle(index, in: rows) }
        #expect(shown(PanelRows.steps(try PanelRows.pastes(picked.targets(in: rows), from: store, plain: false))) == ["c", "image", "a"])

        // Shift+Up from the image onto b: two picks ending on the image, the case Sven saw land only the image.
        var up = PanelSelection()
        up.move(2, in: rows)
        up.extend(-1, in: rows)
        #expect(shown(PanelRows.steps(try PanelRows.pastes(up.targets(in: rows), from: store, plain: false))) == ["image", "b"])
    }

    @Test("What one write lands whole takes no steps: one copy, texts, files; two images take two")
    func wholeOrSteps() {
        let string = NSPasteboard.PasteboardType.string.rawValue, fileURL = NSPasteboard.PasteboardType.fileURL.rawValue
        let a = PanelRows.Paste(contents: [[string: Data("a".utf8)]], text: "a")
        let image = PanelRows.Paste(contents: [["public.png": png]], text: "")
        let file = PanelRows.Paste(contents: [[fileURL: Data("file:///tmp/a".utf8)]], text: "/tmp/a")
        #expect(PanelRows.steps([image]) == nil)
        #expect(PanelRows.steps([a, a]) == nil)
        #expect(PanelRows.steps([file, file]) == nil)
        #expect(shown(PanelRows.steps([image, image])) == ["image", "image"])
        // A plain paste carries an image's read text as its text: joined, one write.
        #expect(PanelRows.steps([a, PanelRows.Paste(contents: image.contents, text: "read")]) == nil)
    }

    @Test("Each step goes on transient with its own Cmd+V after the last was read, then the user's copy goes back")
    func pastesEachThenPutsBack() throws {
        pasteboard.copy("his copy")
        let scheduler = Scheduler()
        var posts = 0
        let steps = try #require(PanelRows.steps([.init(contents: [["public.utf8-plain-text": Data("a".utf8)]], text: "a"),
                                                  .init(contents: [["public.png": png]], text: ""),
                                                  .init(contents: [["public.utf8-plain-text": Data("c".utf8)]], text: "c")]))
        PasteSteps(pasteboard: pasteboard, post: { posts += 1 }, later: scheduler.after).run(steps)
        #expect(pasteboard.string(forType: .string) == "a")
        #expect(posts == 1)
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil) == nil)
        scheduler.flush()
        #expect(pasteboard.data(forType: .png) == png)
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(posts == 2)
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil) == nil)
        scheduler.flush()
        #expect(pasteboard.string(forType: .string) == "c")
        #expect(posts == 3)
        scheduler.flush()
        #expect(pasteboard.string(forType: .string) == "his copy")
        #expect(posts == 3)
        // The image's read above asked for the next after `afterRead`; the wait for an app that never reads went first here.
        #expect(scheduler.delays == [PasteSequence.settle, PasteSteps.imageRead, PasteSteps.afterRead, PasteBack.after])
        #expect(scheduler.waiting.isEmpty)
    }

    @Test("Three images on the real clock, the app reading each 20 ms after its Cmd+V: the third pastes before the old fixed waits would have (Sven, build 46)")
    func threeImagesTimed() async throws {
        pasteboard.copy("his copy")
        let images = (0..<3).map { PanelRows.Paste(contents: [["public.png": png + Data([UInt8($0)])]], text: "") }
        let start = Date()
        var posts: [TimeInterval] = [], read: [Data] = []
        PasteSteps(pasteboard: pasteboard, post: { [pasteboard] in
            posts.append(Date().timeIntervalSince(start))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { read.append(pasteboard.data(forType: .png) ?? Data()) }
        }).run(try #require(PanelRows.steps(images)))
        for _ in 0..<300 where pasteboard.string(forType: .string) != "his copy" { try await Task.sleep(for: .milliseconds(10)) }
        let back = Date().timeIntervalSince(start)
        print("paste steps, 3 images: Cmd+V at \(posts.map { String(format: "%.2f s", $0) }), his copy back at \(String(format: "%.2f s", back))")
        #expect(read == images.map { $0.contents[0]["public.png"] })
        #expect(posts.count == 3)
        // The old path pasted the third at 2 s (a second's wait per image); measured 0.4 s, the bound left loose for a loaded run.
        #expect(try #require(posts.last) < 1.8)
    }

    @Test("Something copied between steps ends it there: no more pastes, and the new copy stays on")
    func stopsOnOtherCopy() {
        pasteboard.copy("his copy")
        let scheduler = Scheduler()
        var posts = 0
        PasteSteps(pasteboard: pasteboard, post: { posts += 1 }, later: scheduler.after)
            .run([.init(contents: [["public.png": png]], text: ""), .init(contents: [["public.utf8-plain-text": Data("c".utf8)]], text: "c")])
        pasteboard.copy("copied meanwhile")
        scheduler.flush()
        #expect(posts == 1)
        #expect(pasteboard.string(forType: .string) == "copied meanwhile")
        #expect(scheduler.waiting.isEmpty)
    }
}
}
