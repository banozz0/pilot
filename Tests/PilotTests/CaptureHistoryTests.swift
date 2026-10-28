import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Delay, repeat last area and recent captures (spec `capture.html` CP10): the Capture branch lists the ten newest
/// captures as file rows that Return opens in the editor; Hyper+Alt+S takes the last area again on its display; a
/// delayed capture counts down, then shows the overlay, and its key again cancels the count.
@MainActor
@Suite("Capture history")
struct CaptureHistoryTests {
    static func capture(told: @escaping @MainActor (String) -> Void = { _ in }, delivered: @escaping @MainActor (CGImage) -> Void = { _ in }) -> PilotCapture {
        let defaults = UserDefaults(suiteName: testSuite())!
        let capture = PilotCapture(grabber: CaptureGrabTests.FakeGrabber(grabs: [CaptureGrabTests.grab]), store: CaptureSettingsStore(defaults: defaults),
                                   defaults: defaults, deliver: { image, _ in delivered(image) }, tell: { text, _ in told(text) })
        capture.overlaysVisible = false
        capture.grabTimeout = .seconds(600)
        capture.delayStep = .milliseconds(10)
        return capture
    }

    @Test("The Capture branch lists the ten newest captures, pictures only, as file rows outside the root search")
    func rows() {
        let now = Date()
        let listed = (0..<14).map { i in
            CaptureFiles.Listed(url: URL(filePath: "/tmp/caps/Capture \(i).png"), kind: i == 3 ? .recording : .capture,
                                date: now.addingTimeInterval(-Double(i) * 60), bytes: 10)
        }
        let rows = CaptureFiles.menuRows(listed, now: now)
        #expect(rows.count == 10)
        #expect(rows.first?.title == "Capture 0" && rows.first?.target == .file("/tmp/caps/Capture 0.png"))
        #expect(!rows.contains { $0.title == "Capture 3" }, "a recording is not listed")
        #expect(rows.allSatisfy { $0.home == .capture && !$0.inSearch })
    }

    @Test("Return on a capture in Pilot's folder opens the editor; any other file opens as before")
    func opensInEditor() {
        let folder = CaptureSettingsStore.shared.folder(.capture).path(percentEncoded: false)
        #expect(CapturesModule.isCapture(folder + "Capture 2026-10-16 at 14.03.22.png"))
        #expect(!CapturesModule.isCapture(folder + "notes.txt"))
        #expect(!CapturesModule.isCapture("/tmp/elsewhere/Capture.png"))
    }

    @Test("Hyper+Alt+S takes the last area again on its display, with no overlay; before any, it says how to make one")
    func repeatArea() async {
        var told: [String] = [], images: [CGImage] = []
        let capture = Self.capture(told: { told.append($0) }, delivered: { images.append($0) })
        capture.run(.repeatArea)
        #expect(told == ["No area captured yet: drag one with Hyper+S first."])
        capture.run(.area)
        await CaptureGrabTests.settle { capture.overlay != nil }
        capture.overlay?.close(.area(CaptureGrabTests.grab, CGRect(x: 10, y: 20, width: 50, height: 30)))
        #expect(capture.lastArea == LastArea(display: 1, rect: CGRect(x: 10, y: 20, width: 50, height: 30)))
        capture.run(.repeatArea)
        await CaptureGrabTests.settle { images.count == 2 }
        #expect(images.map(\.width) == [100, 100] && images.map(\.height) == [60, 60])
        #expect(capture.overlay == nil)
    }

    @Test("A delayed capture counts down, then shows the overlay; its key again cancels the count")
    func delayed() async {
        var told: [String] = []
        let capture = Self.capture(told: { told.append($0) })
        capture.run(.delayed)
        await CaptureGrabTests.settle { capture.overlay != nil }
        #expect(told == ["Capturing in 3…", "Capturing in 2…", "Capturing in 1…"])
        capture.overlay?.close()
        told = []
        capture.delayStep = .seconds(30)
        capture.run(.delayed)
        capture.run(.delayed)
        #expect(told == ["Capturing in 3…", "Capture cancelled."])
        #expect(capture.counting == nil)
    }

    @Test("The delay, auto-scroll, desktop icons and thumbnail place read and write as pilot get and set do")
    func setting() async throws {
        let store = CaptureSettingsStore(defaults: UserDefaults(suiteName: testSuite())!)
        let schema = SettingsSchema()
        schema.registerCaptures(store)
        #expect(try schema.get("capture.delay") == .string("3"))
        _ = try await schema.setting("capture.delay").apply(.string("10"))
        #expect(store.settings.delay == 10)
        #expect(try schema.get("capture.autoScroll") == .bool(true), "Pilot scrolls for you unless Sven turns it off")
        _ = try await schema.setting("capture.autoScroll").apply(.bool(false))
        #expect(!store.settings.autoScroll)
        #expect(try schema.get("capture.hideDesktopIcons") == .bool(false))
        _ = try await schema.setting("capture.hideDesktopIcons").apply(.bool(true))
        #expect(store.settings.hideDesktopIcons)
        #expect(try schema.get("capture.thumbnailPlace") == .string("bottomRight"))
        _ = try await schema.setting("capture.thumbnailPlace").apply(.string("middle"))
        #expect(store.settings.thumbnailPlace == .middle)
    }
}
