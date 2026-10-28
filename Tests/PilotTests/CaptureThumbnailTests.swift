import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// After a capture (build 54): a thumbnail by default, at most four stacked, gone on its own unless the pointer is on it;
/// a click opens the editor; one editor a capture at most, however often it is asked for. Nothing is put on Sven's
/// screen: the panels are made, never ordered front.
@MainActor
@Suite("Capture thumbnails", .serialized)
struct CaptureThumbnailTests {
    static let image = CaptureGrabTests.image(400, 300)

    @Test("A capture goes to a thumbnail by default, the editor or the copy alone as After capture says; only Copy only tips")
    func routing() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "thumbs-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: testSuite())!
        let store = CaptureSettingsStore(defaults: defaults)
        store.settings.capturesFolder = folder.path
        var told: [String] = [], after: [CaptureSettings.AfterCapture] = []
        let capture = PilotCapture(grabber: CaptureGrabTests.FakeGrabber(grabs: [CaptureGrabTests.grab]), store: store, defaults: defaults,
                                   tell: { text, _ in told.append(text) })
        capture.pasteboard = NSPasteboard(name: NSPasteboard.Name("pilot.tests.thumbs.\(UUID().uuidString)"))
        capture.afterCapture = { _, _, file, choice in after.append(choice); #expect(file != nil) }
        for choice in CaptureSettings.AfterCapture.allCases {
            store.settings.afterCapture = choice
            await capture.saveAndEdit(Self.image, scale: 2)
        }
        #expect(after == [.thumbnail, .editor, .copy])
        #expect(told.count == 1 && told[0].hasPrefix("Copied, and saved"), "the thumbnail and the editor say it themselves")
    }

    @Test("Asked twice for the same capture, the editor opens once; another capture gets its own")
    func oneEditor() {
        CaptureEditor.onScreen = false
        defer { CaptureEditor.closeAll(); CaptureEditor.onScreen = true }
        let file = URL(filePath: "/tmp/caps/Capture a.png"), other = URL(filePath: "/tmp/caps/Capture b.png")
        CaptureEditor.show(Self.image, scale: 2, file: file, capture: .shared)
        CaptureEditor.show(Self.image, scale: 2, file: file, capture: .shared)
        #expect(CaptureEditor.openCount == 1)
        CaptureEditor.show(Self.image, scale: 2, file: other, capture: .shared)
        #expect(CaptureEditor.openCount == 2)
    }

    @Test("At most four thumbnails stack; a click opens the capture's editor and the thumbnail goes")
    func stack() {
        CaptureThumbnails.onScreen = false
        CaptureEditor.onScreen = false
        defer { CaptureThumbnails.shown.forEach(CaptureThumbnails.dismiss); CaptureEditor.closeAll(); CaptureThumbnails.onScreen = true; CaptureEditor.onScreen = true }
        let panels = (0..<5).map { i in CaptureThumbnails.show(Self.image, scale: 2, file: URL(filePath: "/tmp/caps/\(i).png"), capture: .shared) }
        #expect(CaptureThumbnails.shown.count == 4 && !CaptureThumbnails.shown.contains { $0 === panels[0] }, "the oldest went")
        panels[4].model.open()
        #expect(CaptureEditor.openCount == 1 && CaptureThumbnails.shown.count == 3)
        panels[3].model.open()
        panels[3].model.open()
        #expect(CaptureEditor.openCount == 2, "the same capture's editor is not opened twice")
    }

    static func key(_ c: String, command: Bool = true, code: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? .command : [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code)!
    }

    @Test("Hovered, a thumbnail takes ⌘E edit, ⌘C copy, ⌘S save, ⌘W and Escape close; other keys pass; not hovered, it takes no keys (Q189)")
    func hoverKeys() {
        CaptureThumbnails.onScreen = false
        defer { CaptureThumbnails.shown.forEach(CaptureThumbnails.dismiss); CaptureThumbnails.onScreen = true }
        let panel = CaptureThumbnails.show(Self.image, scale: 2, file: nil, capture: .shared)
        var did: [String] = []
        panel.model.open = { did.append("edit") }
        panel.model.copy = { did.append("copy") }
        panel.model.saveAs = { did.append("save") }
        panel.model.close = { did.append("close") }
        #expect(!panel.canBecomeKey, "the pointer is not on it")
        panel.model.hovered = true
        #expect(panel.canBecomeKey)
        for (c, code) in [("e", UInt16(14)), ("c", 8), ("s", 1), ("w", 13)] { #expect(panel.perform(Self.key(c, code: code))) }
        #expect(panel.perform(Self.key("\u{1b}", command: false, code: 53)))
        #expect(!panel.perform(Self.key("x", code: 7)) && !panel.perform(Self.key("c", command: false, code: 8)))
        #expect(did == ["edit", "copy", "save", "close", "close"])
        #expect(panel.model.said == "Copied")
    }

    @Test("Edit the last capture (Hyper+Alt+E) opens the newest thumbnail's capture, else the newest file; with neither, nothing")
    func editLast() async throws {
        CaptureThumbnails.onScreen = false
        CaptureEditor.onScreen = false
        defer { CaptureThumbnails.reset(); CaptureEditor.closeAll(); CaptureThumbnails.onScreen = true; CaptureEditor.onScreen = true }
        CaptureThumbnails.reset()
        let folder = FileManager.default.temporaryDirectory.appending(path: "edit-last-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await !CapturesModule.editLast(in: folder), "no thumbnail, no file")
        let older = folder.appending(path: "Capture 2026-10-16 at 10.00.00.png"), newer = folder.appending(path: "Capture 2026-10-16 at 11.00.00.png")
        for file in [older, newer] { try #require(PilotCapture.png(Self.image, scale: 2)).write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: older.path)
        let thumbed = URL(filePath: "/tmp/caps/Capture t.png")
        CaptureThumbnails.show(Self.image, scale: 2, file: thumbed, capture: .shared)
        #expect(await CapturesModule.editLast(in: folder))
        #expect(CaptureThumbnails.shown.isEmpty && CaptureEditor.isOpen(file: thumbed), "the thumbnail's capture, and the thumbnail went")
        #expect(await CapturesModule.editLast(in: folder))
        #expect(CaptureEditor.openCount == 2 && CaptureEditor.isOpen(file: newer), "then the newest file")
    }

    @Test("The last thumbnail closed comes back once with Show the last thumbnail again; before any, nothing")
    func restore() {
        CaptureThumbnails.onScreen = false
        defer { CaptureThumbnails.shown.forEach(CaptureThumbnails.dismiss); CaptureThumbnails.onScreen = true }
        CaptureThumbnails.reset()
        #expect(!CaptureThumbnails.restore(), "nothing closed yet")
        let file = URL(filePath: "/tmp/caps/Capture r.png")
        let panel = CaptureThumbnails.show(Self.image, scale: 2, file: file, capture: .shared)
        panel.model.close()
        #expect(CaptureThumbnails.shown.isEmpty)
        #expect(CaptureThumbnails.restore())
        #expect(CaptureThumbnails.shown.count == 1 && CaptureThumbnails.shown[0].model.file == file && CaptureThumbnails.shown[0] !== panel)
        #expect(!CaptureThumbnails.restore(), "once")
    }

    @Test("A thumbnail goes on its own, but not while the pointer is on it; it goes soon after the pointer leaves")
    func clock() async {
        CaptureThumbnails.onScreen = false
        defer { CaptureThumbnails.shown.forEach(CaptureThumbnails.dismiss); CaptureThumbnails.onScreen = true }
        let panel = CaptureThumbnails.show(Self.image, scale: 2, file: nil, capture: .shared)
        panel.model.stay = .milliseconds(40)
        panel.model.leave = .milliseconds(40)
        panel.model.hovered = true
        try? await Task.sleep(for: .milliseconds(120))
        #expect(CaptureThumbnails.shown.contains { $0 === panel }, "kept while hovered")
        panel.model.hovered = false
        await CaptureGrabTests.settle { !CaptureThumbnails.shown.contains { $0 === panel } }
        #expect(!CaptureThumbnails.shown.contains { $0 === panel })
    }
}
