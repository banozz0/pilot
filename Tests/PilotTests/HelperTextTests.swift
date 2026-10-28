import AppKit
import Clipboard
import Foundation
import Testing
@testable import Pilot

/// The clipboard's image text read in pilot-text, the child that takes Vision's memory with it (story 142, 2026-10-11).
@Suite("Clipboard image text in pilot-text")
struct HelperTextTests {
    private final class Marker {}
    /// The PilotText binary SwiftPM built next to this test bundle.
    static let built = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(path: "PilotText").path

    @Test("Its box lines read back as the boxes written; a line that is not four numbers is skipped")
    func boxLines() {
        let boxes = [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05), CGRect(x: 0.15127950001936, y: 0.111296, width: 0.0291, height: 0.0228)]
        #expect(BoxLines.boxes(BoxLines.text(boxes)) == boxes)
        #expect(BoxLines.boxes("0.1 0.2 0.3 0.05\nnoise\n") == [boxes[0]])
        #expect(BoxLines.boxes("").isEmpty)
    }

    @Test("Without the helper in the bundle Vision reads in this process; a helper that fails reads no text")
    func fallbackAndFailure() async {
        #expect(HelperText.standard is VisionText)
        // A helper that exits non-zero gives no text and no boxes, and Pilot carries on.
        #expect(await HelperText(helper: "/usr/bin/false").text(in: Data([1, 2, 3])) == "")
        #expect(await HelperText(helper: "/usr/bin/false").boxes(of: ["x"], in: Data([1, 2, 3])).isEmpty)
    }

    /// Vision compiles its model on a new binary's first image (a minute or more), so this runs on request.
    @Test("The helper reads a rendered image's words and a searched word's box as Vision does",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_RENDER_OCR"] == "1"))
    func reads() async throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 160, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 160).fill()
        ("Pilot clipboard 42" as NSString).draw(at: NSPoint(x: 40, y: 50),
                                                withAttributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(FileManager.default.isExecutableFile(atPath: Self.built))
        let helper = HelperText(helper: Self.built)
        #expect(await helper.text(in: png) == "Pilot clipboard 42")
        let boxes = await helper.boxes(of: ["CLIP"], in: png)
        let box = try #require(boxes.first)
        #expect(boxes.count == 1)
        #expect(box.minX > 0.15 && box.maxX < 0.6 && box.minY > 0.1 && box.maxY < 0.9)
    }
}
