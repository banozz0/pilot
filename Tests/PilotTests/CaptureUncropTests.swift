import AppKit
import Clipboard
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Uncrop and backdrop marks (P77; export tests allowed, Sven Q807): what the capture editor's export holds once the
/// capture keeps the screen it was cut from, and that screen's file going with the capture.
@MainActor
@Suite("Capture uncrop")
struct CaptureUncropTests {
    static let blue: UInt32 = 0x3366CC, white: UInt32 = 0xFFFFFF
    /// The capture's place on the screen, in points.
    static let taken = CGRect(x: 60, y: 30, width: 80, height: 60)

    /// A 200 × 120 point screen at 2x: blue, the captured part white.
    static func screen() -> CGImage {
        let w = 400, h = 240
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: taken.minX * 2, y: CGFloat(h) - taken.maxY * 2, width: taken.width * 2, height: taken.height * 2))
        return ctx.makeImage()!
    }

    /// The editor on the capture cut from `screen()`, with that screen, as the editor opens after a capture.
    static func model() -> (EditorModel, CGImage) {
        let screen = screen(), pixels = CaptureSelection.pixels(taken, scale: 2, within: CGSize(width: screen.width, height: screen.height))
        let capture = screen.cropping(to: pixels)!
        return (EditorModel(image: capture, scale: 2, accent: 0x3CD2DB, dark: true, screen: CaptureGrab(image: screen, taken: pixels, scale: 2)), capture)
    }

    /// The pixel at (`x`, `y`) from the top left, as 0xRRGGBB.
    static func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> UInt32 { PixelGrid(image)?.rgb(x: x, y: y) ?? 0 }

    static func near(_ a: UInt32, _ b: UInt32) -> Bool {
        [16, 8, 0].allSatisfy { abs(Int(a >> $0 & 0xFF) - Int(b >> $0 & 0xFF)) <= 3 }
    }

    @Test("Dragging the crop's edge past the capture's brings the screen back, seam exact; As taken and Whole capture")
    func uncrop() async throws {
        let (m, capture) = Self.model()
        #expect(m.taken == Self.taken && m.document.size == CGSize(width: 200, height: 120))
        #expect(await m.export() === capture, "untouched, the export is the capture as taken")
        m.pick(.crop)
        #expect(m.cropEdit == Self.taken, "Crop opens on the capture's edges, so they can be pulled out")
        // The left edge's handle, 20 points out, past the capture's edge.
        m.begin(CGPoint(x: 60, y: 60)); m.drag(CGPoint(x: 50, y: 60)); m.end(CGPoint(x: 40, y: 60))
        m.applyCrop()
        #expect(m.document.crop == CGRect(x: 40, y: 30, width: 100, height: 60))
        let out = try #require(await m.export())
        #expect(out.width == 200 && out.height == 120)
        #expect(Self.near(Self.rgb(out, 0, 60), Self.blue) && Self.near(Self.rgb(out, 39, 60), Self.blue), "the screen is back")
        #expect(Self.near(Self.rgb(out, 40, 60), Self.white) && Self.near(Self.rgb(out, 199, 119), Self.white), "the capture from pixel 40 on")
        m.pick(.crop)
        m.clearCrop()
        #expect(try #require(await m.export()).width == 400, "Whole capture takes the whole screen")
        m.cropAsTaken()
        m.applyCrop()
        #expect(m.document.crop == nil)
        #expect(await m.export() === capture, "As taken: the capture again")
        // Redact reads all the part kept: once it leaves the capture, the screen, so an email in the uncropped strip is
        // covered (the capture's own read finds nothing here).
        let (r, _) = Self.model()
        r.readCapture = { [] }
        // Only the part kept of the screen is read: the email's box is a fraction of that part.
        var asked: [CGRect] = []
        r.readScreen = { part in
            asked.append(part)
            return [ReadLine(text: "a@b.co", box: CGRect(x: (41 - part.minX) / part.width, y: (50 - part.minY) / part.height,
                                                         width: 14 / part.width, height: 8 / part.height))]
        }
        r.pick(.crop)
        r.begin(CGPoint(x: 60, y: 60)); r.drag(CGPoint(x: 50, y: 60)); r.end(CGPoint(x: 40, y: 60))
        r.applyCrop()
        r.redactSensitive()
        await CaptureGrabTests.settle { !r.finding }
        #expect(r.document.marks.contains { if case .box(let b, _) = $0.kind { b.maxX < 60 } else { false } }, "the uncropped email is covered")
        #expect(asked == [r.document.area], "the screen read is the part kept, not the whole display")
    }

    @Test("A mark started on the backdrop exports on it and stays put as the capture grows; a capture mark moves with it")
    func backdropMarks() async throws {
        let (m, _) = Self.model()
        m.pick(.select)
        m.setBackdrop(Backdrop(fill: .colour(0x000000), pad: 40, radius: 0, shadow: 0))
        // The canvas is 160 × 140 points, the capture at (40, 40) in it: its top left is (20, -10) in the screen's points.
        #expect(m.canvasOrigin == CGPoint(x: 20, y: -10))
        m.pick(.rect); m.setSize(10)
        m.begin(CGPoint(x: 25, y: -5)); m.drag(CGPoint(x: 35, y: 5)); m.end(CGPoint(x: 45, y: 15))
        m.begin(CGPoint(x: 70, y: 40)); m.drag(CGPoint(x: 80, y: 50)); m.end(CGPoint(x: 90, y: 60))
        let marks = m.document.marks
        #expect(marks.map(\.layer) == [.backdrop, .capture])
        #expect(marks[0].kind == .rect(CGRect(x: 5, y: 5, width: 20, height: 20), filled: false), "kept in the canvas's points")
        let red = EditorModel.red
        let before = try #require(await m.export())
        #expect(before.width == 320 && before.height == 280)
        #expect(Self.near(Self.rgb(before, 10, 30), red), "the backdrop mark is on the backdrop")
        #expect(Self.near(Self.rgb(before, 100, 120), red), "the capture mark on the capture")
        // Uncropped 20 points left and 10 up: the canvas grows to 180 × 150.
        m.pick(.crop)
        m.begin(CGPoint(x: 40, y: 20)); m.drag(CGPoint(x: 100, y: 50)); m.end(CGPoint(x: 140, y: 90))
        m.applyCrop()
        let after = try #require(await m.export())
        #expect(after.width == 360 && after.height == 300)
        #expect(m.document.marks[0].kind == marks[0].kind)
        #expect(Self.near(Self.rgb(after, 10, 30), red), "the backdrop mark stayed put")
        #expect(Self.near(Self.rgb(after, 140, 140), red), "the capture mark moved 20 right and 10 down with the capture")
        #expect(Self.near(Self.rgb(after, 82, 82), Self.blue), "the screen uncropped into the spot")
    }

    @Test("The grab is held in memory until its thumbnail and editor close, let go when its capture goes to the Trash or is written over, and freed with them")
    func grabHeld() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-uncrop-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: testSuite())!
        let store = CaptureHistoryStore(file: folder.appending(path: "history.json"), defaults: defaults, settings: CaptureSettingsStore(defaults: defaults),
                                        trashItem: { try FileManager.default.removeItem(at: $0) })
        let grab = CaptureGrab(image: Self.screen(), taken: CGRect(x: 120, y: 60, width: 160, height: 120), scale: 2)
        let first = folder.appending(path: "Capture 1.png"), second = folder.appending(path: "Capture 2.png")
        for file in [first, second] {
            try Data([1]).write(to: file)
            store.keepGrab(grab, for: file)
            store.holdGrab(file)
        }
        #expect(store.grab(for: first)?.taken == grab.taken && store.grab(for: second) != nil)
        // The thumbnail and the editor of the first: the grab goes when the last of them closes.
        store.holdGrab(first)
        store.releaseGrab(first)
        #expect(store.grab(for: first) != nil, "the editor still holds it")
        store.releaseGrab(first)
        #expect(store.grab(for: first) == nil, "let go with its last holder")
        // The second, still held, goes with its capture.
        #expect(await store.trash([second]) == 1)
        #expect(store.grab(for: second) == nil, "let go with its capture")
        // A grab nobody took up is let go by the next one kept.
        let third = folder.appending(path: "Capture 3.png"), fourth = folder.appending(path: "Capture 4.png")
        store.keepGrab(grab, for: third)
        store.keepGrab(grab, for: fourth)
        #expect(store.grab(for: third) == nil && store.grab(for: fourth) != nil)
        // Done wrote over the fourth: its grab goes though it is held, so no editor opens on the older screen.
        store.holdGrab(fourth)
        store.forgetGrab(fourth)
        #expect(store.grab(for: fourth) == nil, "let go when its file is written over")

        // A closed editor and a dismissed thumbnail free their models and the screen. A weak CGImage zeroes once its last
        // holder goes, so the checks below can see the screen freed.
        weak var control: CGImage?
        autoreleasepool { let c = Self.screen(); control = c; _ = c.width }
        #expect(control == nil, "a weak CGImage zeroes")
        let file = folder.appending(path: "Capture 5.png")
        try Data([1]).write(to: file)
        weak var still: CGImage?, thumbnail: ThumbnailModel?, editor: EditorModel?
        let shown = (CaptureThumbnails.onScreen, CaptureEditor.onScreen)
        (CaptureThumbnails.onScreen, CaptureEditor.onScreen) = (false, false)
        autoreleasepool {
            // The capture cut from its screen, the screen kept, its thumbnail up and then opened in the editor, as after a
            // capture: the thumbnail goes, the editor holds the screen.
            let screen = Self.screen(), pixels = CaptureSelection.pixels(Self.taken, scale: 2, within: CGSize(width: screen.width, height: screen.height))
            still = screen
            CaptureHistoryStore.shared.keepGrab(CaptureGrab(image: screen, taken: pixels, scale: 2), for: file)
            let panel = CaptureThumbnails.show(screen.cropping(to: pixels)!, scale: 2, file: file, capture: .shared)
            thumbnail = panel.model
            panel.model.open()
            editor = CaptureEditor.model(file: file)
        }
        // Put back at once, never across the waits below, where another test may have set them.
        (CaptureThumbnails.onScreen, CaptureEditor.onScreen) = shown
        #expect(editor?.screen != nil && CaptureHistoryStore.shared.grab(for: file) != nil, "the editor opened on the screen")
        // Cancel, as the editor's own button sends it.
        editor?.finish(.cancel)
        await CaptureGrabTests.settle { !CaptureEditor.isOpen(file: file) && thumbnail == nil && editor == nil && still == nil }
        #expect(thumbnail == nil, "the dismissed thumbnail freed its model")
        #expect(!CaptureEditor.isOpen(file: file))
        #expect(editor == nil, "the closed editor freed its model")
        #expect(CaptureHistoryStore.shared.grab(for: file) == nil)
        #expect(still == nil, "and with it the screen")
    }
}
