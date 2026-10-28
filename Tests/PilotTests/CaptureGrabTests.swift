import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Pilot's own capture on a fake grabber (spec `capture.html` CP2): nothing asks Screen Recording or its state before a
/// press; a press without the grant explains and asks, then points at Privacy & Security; full screen hands the display
/// under the pointer on; a capture is copied and saved as a named PNG in the captures folder.
@MainActor
@Suite("Capture grab")
struct CaptureGrabTests {
    final class FakeGrabber: ScreenGrabbing, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        var granted = true
        /// A hung ScreenCaptureKit: displays() never answers in time.
        var hangs = false
        let grabs: [DisplayGrab]
        init(grabs: [DisplayGrab]) { self.grabs = grabs }
        private func note(_ call: String) { lock.withLock { _calls.append(call) } }
        func allowed() -> Bool { note("allowed"); return granted }
        func ask() { note("ask") }
        func displays() async throws -> [DisplayGrab] {
            note("displays")
            if hangs { try await Task.sleep(for: .seconds(30)) }
            return grabs
        }
        func windows() async throws -> [CaptureSelection.Window] { note("windows"); return [] }
        func window(_ id: UInt32, scale: CGFloat) async throws -> CGImage { note("window \(id)"); return grabs[0].image }
    }

    static func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    static let grab = DisplayGrab(id: 1, frame: CGRect(x: -100_000, y: -100_000, width: 200, height: 100), scale: 2, image: image(400, 200))

    func capture(_ grabber: FakeGrabber, folder: URL? = nil, told: @escaping @MainActor (String) -> Void = { _ in },
                 delivered: (@MainActor (CGImage, CGFloat) -> Void)? = nil) -> PilotCapture {
        let defaults = UserDefaults(suiteName: testSuite())!
        let store = CaptureSettingsStore(defaults: defaults)
        store.settings.capturesFolder = folder?.path
        let capture = PilotCapture(grabber: grabber, store: store, defaults: defaults, deliver: delivered,
                                   tell: { text, _ in told(text) })
        capture.pasteboard = NSPasteboard(name: NSPasteboard.Name("pilot.tests.capture.\(UUID().uuidString)"))
        capture.overlaysVisible = false
        // A loaded parallel run can hold the main actor for seconds: only the test about the timeout times out.
        capture.grabTimeout = .seconds(600)
        return capture
    }

    /// Waits for `done` for up to 6000 of the main actor's turns, 5 ms apart (30 s when idle). Counted in turns, not on
    /// the clock: a loaded full run's other main-actor suites (renders, hidden panels pumping the run loop) held the main
    /// actor for over 30 s, so the clock ran out before the work waited for had had a turn (OW P4, four yes processes).
    static func settle(until done: () -> Bool) async {
        for _ in 0..<6000 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("Nothing reads Screen Recording, its state or the screen until a key is pressed")
    func nothingBeforePress() {
        let grabber = FakeGrabber(grabs: [Self.grab])
        _ = capture(grabber)
        _ = CaptureSettingsStore(defaults: UserDefaults(suiteName: testSuite())!)
        #expect(grabber.calls.isEmpty)
    }

    @Test("Without the grant a press explains and offers Allow, then points at Privacy & Security; nothing is grabbed")
    func permission() {
        let grabber = FakeGrabber(grabs: [Self.grab])
        grabber.granted = false
        var lines: [String] = []
        var actions: [HUD.TipAction] = []
        let defaults = UserDefaults(suiteName: testSuite())!
        let capture = PilotCapture(grabber: grabber, store: CaptureSettingsStore(defaults: defaults), defaults: defaults,
                                   tell: { lines.append($0); if let a = $1 { actions.append(a) } })
        capture.run(.area)
        #expect(lines.last == "Captures need Screen Recording. Pilot captures only when you press a capture key.")
        #expect(actions.last?.title == "Allow…")
        actions.last?.run()
        #expect(grabber.calls == ["allowed", "ask"])
        capture.run(.area)
        #expect(lines.last?.hasPrefix("Screen Recording is off for Pilot.") == true)
        #expect(!grabber.calls.contains("displays"))
    }

    @Test("Full screen hands on the display's still at its scale, without an overlay")
    func fullScreen() async {
        let grabber = FakeGrabber(grabs: [Self.grab])
        var got: (CGImage, CGFloat)?
        let capture = capture(grabber, delivered: { got = ($0, $1) })
        capture.run(.fullScreen)
        await Self.settle { got != nil }
        #expect(got?.0.width == 400)
        #expect(got?.1 == 2)
        #expect(capture.overlay == nil)
        #expect(grabber.calls == ["allowed", "displays"])
    }

    @Test("A capture is copied as PNG and saved, named, at 144 dpi for a 2x display")
    func saved() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "capture-grab-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        var lines: [String] = []
        let capture = capture(FakeGrabber(grabs: [Self.grab]), folder: folder, told: { lines.append($0) })
        await capture.save(Self.image(400, 200), scale: 2)
        await capture.save(Self.image(400, 200), scale: 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 2, "two captures in one second: two files, never one written over")
        #expect(files.allSatisfy { $0.hasPrefix("Capture ") && $0.hasSuffix(".png") })
        #expect(capture.pasteboard.data(forType: .png) != nil)
        let source = try #require(CGImageSourceCreateWithURL(folder.appending(path: files[0]) as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyDPIWidth] as? Double == 144)
        #expect(lines.last?.hasPrefix("Copied, and saved to ") == true)
    }

    @Test("A second press while the overlay is up closes it, and the overlay reports once")
    func secondPressCloses() async {
        let grabber = FakeGrabber(grabs: [Self.grab])
        var told: [String] = []
        let capture = capture(grabber, told: { told.append($0) }, delivered: { _, _ in Issue.record("nothing should be delivered") })
        capture.run(.area)
        await Self.settle { capture.overlay != nil }
        let overlay = capture.overlay
        #expect(overlay?.displays.count == 1)
        capture.run(.area)
        #expect(capture.overlay == nil)
        overlay?.close()
        #expect(told.isEmpty)
        #expect(grabber.calls.filter { $0 == "displays" }.count == 1, "the second press only closed")
    }

    @Test("close() reports exactly once, however often it is called")
    func closeOnce() {
        var results = 0
        let overlay = CaptureOverlay(grabs: [Self.grab], windows: [], mode: .area, visible: false) { _ in results += 1 }
        overlay.show()
        overlay.close()
        overlay.close()
        #expect(results == 1)
    }

    @Test("Escape on the overlay's view reports close")
    func escapeKey() throws {
        var outcomes: [CaptureSelection.Outcome] = []
        let view = CaptureOverlayView(grab: Self.grab, selection: CaptureSelection(size: Self.grab.frame.size), accent: .red) { o, _ in outcomes.append(o) }
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        #expect(outcomes == [.close])
    }

    @Test("A hung grab gives the press up after the timeout, so the next press grabs again")
    func hungGrab() async {
        let grabber = FakeGrabber(grabs: [Self.grab])
        grabber.hangs = true
        var told: [String] = []
        let capture = capture(grabber, told: { told.append($0) })
        capture.grabTimeout = .milliseconds(50)
        capture.run(.fullScreen)
        await Self.settle { !told.isEmpty }
        #expect(told == ["The screen did not answer. Press again."])
        capture.run(.fullScreen)
        await Self.settle { grabber.calls.filter { $0 == "displays" }.count == 2 }
        #expect(grabber.calls.filter { $0 == "displays" }.count == 2)
    }

    @Test("A flat drag says nothing was captured instead of closing silently")
    func flatArea() async {
        let grabber = FakeGrabber(grabs: [Self.grab])
        var told: [String] = []
        let capture = capture(grabber, told: { told.append($0) }, delivered: { _, _ in Issue.record("nothing should be delivered") })
        capture.run(.area)
        await Self.settle { capture.overlay != nil }
        capture.overlay?.close(.area(Self.grab, CGRect(x: 10, y: 10, width: 80, height: 0)))
        #expect(told == ["Nothing captured: the area had no width or no height."])
    }

    @Test("The window that closed before its capture is named in plain words")
    func noWindowMessage() {
        #expect(GrabError.noWindow.localizedDescription == "That window closed before it was captured.")
    }

    @Test("Short paths name a folder in home without it")
    func shortPath() {
        #expect(PilotCapture.shortPath(URL(filePath: NSHomeDirectory() + "/Pictures/Pilot", directoryHint: .isDirectory)) == "Pictures/Pilot")
        #expect(PilotCapture.shortPath(URL(filePath: "/Volumes/Shots", directoryHint: .isDirectory)) == "/Volumes/Shots")
    }
}
