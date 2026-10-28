import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The capture editor's behaviour on its model (spec `capture.html` CP6, CP7), no window: the number keys pick tools,
/// a drag draws with the picked one, text is typed then kept, ⌘Z undoes, Escape asks twice when there are marks,
/// Return is Done, the select tool moves a mark and the slider resizes it, and the export is the crop's size.
@MainActor
@Suite("Capture editor")
struct CaptureEditorTests {
    static func model() -> EditorModel {
        EditorModel(image: CaptureGrabTests.image(400, 300), scale: 2, accent: 0x3CD2DB, dark: true)
    }

    /// 2x: white, with a blue button from (20, 10) to (60, 30) in points, top left origin.
    static func page() -> CGImage {
        let w = 200, h = 100
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 40, y: h - 60, width: 80, height: 40))
        return ctx.makeImage()!
    }

    @Test("1 to 9, 0, C and F pick tools; other letters are not the editor's")
    func keysPickTools() {
        let m = Self.model()
        #expect(m.key(.char("3")) && m.tool == .rect)
        #expect(m.key(.char("0")) && m.tool == .step)
        #expect(m.key(.char("c")) && m.tool == .crop)
        #expect(m.key(.char("f")) && m.tool == .spotlight)
        #expect(!m.key(.char("q")))
    }

    @Test("A drag draws with the picked tool in its colour, size and style; a click leaves no shape")
    func drag() {
        let m = Self.model()
        m.pick(.ellipse); m.setStyle(1); m.setColour(3); m.setSize(7)
        m.begin(CGPoint(x: 10, y: 10)); m.drag(CGPoint(x: 40, y: 30)); m.end(CGPoint(x: 60, y: 50))
        #expect(m.document.marks.count == 1)
        #expect(m.document.marks[0].kind == .ellipse(CGRect(x: 10, y: 10, width: 50, height: 40), filled: true))
        #expect(m.document.marks[0].colour == EditorModel.green && m.document.marks[0].size == 7)
        m.begin(CGPoint(x: 80, y: 80)); m.end(CGPoint(x: 81, y: 81))
        #expect(m.document.marks.count == 1, "a click is no shape")
    }

    @Test("Text is typed into its mark and kept on Return; an empty one is dropped; keys go to the field meanwhile")
    func text() {
        let m = Self.model()
        m.pick(.text)
        m.begin(CGPoint(x: 20, y: 40))
        #expect(m.typing != nil)
        #expect(!m.key(.char("3")), "a digit typed into the text, not a tool")
        m.typed = "Look here"
        #expect(m.key(.enter))
        #expect(m.typing == nil)
        guard case .text("Look here", _, _) = m.document.marks.first?.kind else { Issue.record("no text mark"); return }
        m.begin(CGPoint(x: 20, y: 80))
        _ = m.key(.escape)
        #expect(m.document.marks.count == 1, "the empty one went")
    }

    @Test("⌘Z undoes and ⌘⇧Z redoes")
    func undo() {
        let m = Self.model()
        m.pick(.step)
        m.begin(CGPoint(x: 10, y: 10)); m.end(CGPoint(x: 10, y: 10))
        #expect(m.document.marks.count == 1)
        #expect(m.key(.char("z", command: true)))
        #expect(m.document.marks.isEmpty)
        #expect(m.key(.char("z", command: true, shift: true)))
        #expect(m.document.marks.count == 1)
    }

    @Test("Escape cancels at once with no marks; with marks it warns first, then cancels")
    func escape() {
        var outcomes: [EditorModel.Outcome] = []
        let clean = Self.model()
        clean.finish = { outcomes.append($0) }
        _ = clean.key(.escape)
        #expect(outcomes == [.cancel])
        outcomes = []
        let marked = Self.model()
        marked.finish = { outcomes.append($0) }
        marked.pick(.step); marked.begin(.zero); marked.end(.zero)
        _ = marked.key(.escape)
        #expect(outcomes.isEmpty && marked.hint == "Press Esc again to throw away your marks")
        _ = marked.key(.escape)
        #expect(outcomes == [.cancel])
    }

    @Test("Return is Done, ⌘C copies and ⌘S saves a copy, each saying so")
    func outcomes() {
        var outcomes: [EditorModel.Outcome] = []
        let m = Self.model()
        m.finish = { outcomes.append($0) }
        _ = m.key(.char("c", command: true))
        #expect(m.hint == "Copied")
        _ = m.key(.char("s", command: true))
        #expect(m.hint == "Saved a copy")
        _ = m.key(.enter)
        #expect(outcomes == [.copy, .saveCopy, .done])
    }

    @Test("The select tool moves a mark, the slider resizes it, Delete removes it")
    func select() {
        let m = Self.model()
        m.pick(.rect)
        m.begin(CGPoint(x: 10, y: 10)); m.end(CGPoint(x: 50, y: 50))
        m.pick(.select)
        m.begin(CGPoint(x: 10, y: 30)); m.drag(CGPoint(x: 40, y: 40)); m.end(CGPoint(x: 50, y: 50))
        #expect(m.document.marks[0].kind == .rect(CGRect(x: 50, y: 30, width: 40, height: 40), filled: false))
        m.setSize(9)
        #expect(m.document.marks[0].size == 9)
        #expect(m.key(.delete))
        #expect(m.document.marks.isEmpty)
    }

    @Test("The export is the crop's size at the capture's pixels, and the capture itself when nothing changed")
    func export() async {
        let m = Self.model()
        let plain = await m.export()
        #expect(plain === m.image)
        m.pick(.crop)
        m.begin(CGPoint(x: 10, y: 20)); m.end(CGPoint(x: 110, y: 70))
        #expect(m.exportSize == CGSize(width: 200, height: 100))
        let cropped = await m.export()
        #expect(cropped?.width == 200 && cropped?.height == 100)
    }

    @Test("Saving a copy goes beside the capture as its name plus ' edited', never over a file")
    func copyName() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "editor-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Capture 2026-10-16 at 14.03.22.png")
        let png = Data("png".utf8)
        let first = PilotCapture.write(png, near: file, in: folder, suffix: " edited")
        let second = PilotCapture.write(png, near: file, in: folder, suffix: " edited")
        #expect(first?.lastPathComponent == "Capture 2026-10-16 at 14.03.22 edited.png")
        #expect(second?.lastPathComponent == "Capture 2026-10-16 at 14.03.22 edited 2.png")
    }

    @Test("The ruler: a click stamps the two lines across the colour under it; a drag stamps its own length")
    func ruler() async {
        let m = EditorModel(image: Self.page(), scale: 2, accent: 0x3CD2DB, dark: true)
        m.pick(.ruler)
        await CaptureGrabTests.settle { m.hover(CGPoint(x: 30, y: 20)); return !m.hovering.isEmpty }
        #expect(m.hovering.map(\Mark.kind) == [Mark.Kind.measure(from: CGPoint(x: 20, y: 20.25), to: CGPoint(x: 60, y: 20.25), points: false),
                                           .measure(from: CGPoint(x: 30.25, y: 10), to: CGPoint(x: 30.25, y: 30), points: false)])
        m.begin(CGPoint(x: 30, y: 20)); m.end(CGPoint(x: 30, y: 20))
        #expect(m.document.marks.count == 2)
        m.begin(CGPoint(x: 0, y: 40)); m.drag(CGPoint(x: 50, y: 40)); m.end(CGPoint(x: 90, y: 40))
        #expect(m.document.marks.last?.kind == Mark.Kind.measure(from: CGPoint(x: 0, y: 40), to: CGPoint(x: 90, y: 40), points: false))
    }

    @Test("The backdrop: picked with nothing selected, it pads the export, maps clicks through its preview, and comes off")
    func backdrop() {
        let m = Self.model()
        m.pick(.select)
        m.setBackdrop(Backdrop(fill: .gradient([0xF7B267, 0xF25F5C])))
        m.setBackdrop { $0.pad = 40 }
        #expect(m.document.backdrop?.fill == .gradient([0xF7B267, 0xF25F5C]) && m.document.backdrop?.pad == 40)
        #expect(m.exportSize == CGSize(width: 400 + 160, height: 300 + 160))
        let p = CGPoint(x: 37, y: 81)
        let back = m.capturePoint(m.canvasPoint(p))
        #expect(abs(back.x - p.x) < 0.001 && abs(back.y - p.y) < 0.001, "a click lands where it shows")
        #expect(m.preview.k < 1)
        m.setBackdrop { $0.ratio = .wide }
        #expect(m.exportSize == CGSize(width: 818, height: 460), "16:9 grows the canvas")
        let wide = m.capturePoint(m.canvasPoint(p))
        #expect(abs(wide.x - p.x) < 0.001 && abs(wide.y - p.y) < 0.001, "a click lands where it shows in a ratio")
        m.setBackdrop(nil)
        #expect(m.document.backdrop == nil && m.capturePoint(p) == p)
    }

    @Test("The editor opens at one size whatever the capture's shape, the capture fitted inside, never narrower than its tools (build 76)")
    func layout() {
        let tokens = StyleTokens.of(.instrument, theme: .designed[0])
        // A thin strip on Sven's 3440 × 1440 screen (visible 3440 × 1410) gets the same window as any capture.
        let open = EditorLayout.opening(room: CGSize(width: 3440, height: 1410), least: EditorLayout.least(panel: false))
        #expect(open.width == 1600 && abs(open.height - 987) < 0.01)
        let room = CGSize(width: open.width, height: open.height - EditorLayout.bar(tokens) - EditorLayout.foot(tokens) - 2)
        let inside = CGSize(width: room.width - 2 * EditorLayout.margin, height: room.height - 2 * EditorLayout.margin)
        #expect(EditorLayout.fit(CGSize(width: 1345, height: 380), inside: inside) == 1)
        #expect(EditorLayout.fit(CGSize(width: 3000, height: 1000), inside: inside) < 0.6)
        let laptop = CGSize(width: 1200, height: 800)
        #expect(EditorLayout.opening(room: laptop, least: EditorLayout.least(panel: false)) == CGSize(width: EditorLayout.minWidth, height: 640))
        #expect(EditorLayout.opening(room: laptop, least: EditorLayout.least(panel: true)).height == 720)
        // A dragged size wins, held to the screen.
        #expect(EditorLayout.opening(room: laptop, least: EditorLayout.least(panel: false), saved: CGSize(width: 1100, height: 900)) == CGSize(width: 1100, height: 760))
    }
}
