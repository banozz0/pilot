import AppKit
import Foundation
import ImageIO
import PilotCore
import Testing
@testable import Pilot

/// Pins (spec `capture.html` CP9) without putting one on Sven's screen: the newest capture is found with its scale from
/// its DPI, and a pin's size follows its zoom from its top left.
@MainActor
@Suite("Pins")
struct PinsTests {
    @Test("Pin the last capture finds the newest PNG and reads its scale from its DPI")
    func newest() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pins-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try #require(PilotCapture.png(CaptureGrabTests.image(10, 10), scale: 1))
        let new = try #require(PilotCapture.png(CaptureGrabTests.image(80, 40), scale: 2))
        try old.write(to: folder.appending(path: "Capture a.png"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: folder.appending(path: "Capture a.png").path)
        try new.write(to: folder.appending(path: "Capture b.png"))
        let found = try #require(Pins.newest(in: folder))
        #expect(found.0.width == 80 && found.1 == 2)
        #expect(Pins.newest(in: folder.appending(path: "none")) == nil)
    }

    @Test("A pin is the capture's size in points and zooms from its top left")
    func panel() {
        let panel = PinPanel(image: CaptureGrabTests.image(400, 200), state: PinState(size: CGSize(width: 200, height: 100)))
        defer { panel.close() }
        panel.setFrame(CGRect(x: -20_000, y: -20_000, width: 200, height: 100), display: false)
        var bigger = panel.state
        bigger.scrolled(1)
        panel.apply(bigger)
        #expect(panel.frame.size == CGSize(width: 220, height: 110))
        #expect(panel.frame.maxY == -19_900, "the top left stays put")
        var faint = panel.state
        faint.nextOpacity()
        panel.apply(faint)
        #expect(panel.alphaValue == 0.75)
    }
}
