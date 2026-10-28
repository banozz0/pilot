import AppKit
import Clipboard
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Reading a capture's text (spec `capture.html` CP8) on a fake reader: Hyper+X's area goes to the reader and its
/// lines onto the pasteboard, codes after the words; the tip says how many and the first; pilot-text's line format reads
/// back; and the editor's Read text shows what it found until another tool is picked.
@MainActor
@Suite("Capture text")
struct CaptureTextTests {
    struct FakeReader: LineReading {
        let lines: [ReadLine]
        func lines(in image: Data) async -> [ReadLine] { image.isEmpty ? [] : lines }
    }

    static let lines = [ReadLine(text: "Billing", box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)),
                        ReadLine(text: "https://pilot.example/qr", box: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2), code: true),
                        ReadLine(text: "$12 / month", box: CGRect(x: 0.1, y: 0.3, width: 0.25, height: 0.06))]

    @Test("pilot-text's lines read back as written")
    func format() {
        #expect(ReadLines.parse(ReadLines.json(Self.lines)) == Self.lines)
        #expect(ReadLines.parse("not json\n") == [])
    }

    @Test("Words are copied line by line, then each code; the tip names the count and the first line")
    func copied() {
        #expect(ReadLines.copied(Self.lines) == "Billing\n$12 / month\nhttps://pilot.example/qr")
        #expect(CaptureText.said(Self.lines) == "Copied 3 lines: “Billing”")
        #expect(CaptureText.said([Self.lines[1]]) == "Copied 1 code: “https://pilot.example/qr”")
        #expect(CaptureText.said([]) == "No text found.")
    }

    @Test("Hyper+X: the dragged area is read and its text goes on the pasteboard, nothing saved")
    func hyperX() async {
        var told: [String] = []
        let defaults = UserDefaults(suiteName: testSuite())!
        let capture = PilotCapture(grabber: CaptureGrabTests.FakeGrabber(grabs: [CaptureGrabTests.grab]), store: CaptureSettingsStore(defaults: defaults),
                                   defaults: defaults, deliver: { _, _ in Issue.record("a read saves nothing") }, tell: { text, _ in told.append(text) })
        capture.pasteboard = NSPasteboard(name: NSPasteboard.Name("pilot.tests.text.\(UUID().uuidString)"))
        capture.overlaysVisible = false
        capture.grabTimeout = .seconds(600)
        capture.reader = FakeReader(lines: Self.lines)
        capture.run(.ocr)
        await CaptureGrabTests.settle { capture.overlay != nil }
        capture.overlay?.close(.area(CaptureGrabTests.grab, CGRect(x: 10, y: 10, width: 100, height: 40)))
        await CaptureGrabTests.settle { !told.isEmpty }
        #expect(told == ["Copied 3 lines: “Billing”"])
        #expect(capture.pasteboard.string(forType: .string) == "Billing\n$12 / month\nhttps://pilot.example/qr")
    }

    @Test("The editor's Read text reads, shows the lines boxed, and stops showing them when a tool is picked")
    func editor() {
        let model = CaptureEditorTests.model()
        var asked = 0
        model.readText = { asked += 1 }
        model.pick(.crop)
        model.begin(CGPoint(x: 10, y: 20)); model.end(CGPoint(x: 110, y: 70))
        model.startReading()
        #expect(asked == 1 && model.reading == .reading)
        #expect(model.readArea == CGRect(x: 10, y: 20, width: 100, height: 50), "boxes land in the crop that was read")
        model.showRead(Self.lines)
        #expect(model.reading == .read(Self.lines))
        model.pick(.arrow)
        #expect(model.reading == nil)
        model.showRead(Self.lines)
        #expect(model.reading == nil, "a late answer after another tool shows nothing")
    }

    @Test("Make a QR code round-trips through Vision in memory; Read opens only web and mail links; too much text makes no code")
    func qrRoundTrip() async throws {
        let text = "https://pilot.example/qr?from=pilot"
        let image = try #require(QRCodes.image(text))
        let png = try #require(PilotCapture.png(image, scale: 1))
        let codes = await VisionText().lines(in: png).filter(\.code).map(\.text)
        #expect(codes == [text])
        #expect(QRCodes.image("") == nil)
        #expect(QRCodes.image(String(repeating: "a", count: QRCodes.capacity + 1)) == nil)
        #expect(QRCodes.link(text)?.host() == "pilot.example")
        #expect(QRCodes.link("mailto:sven@example.com") != nil)
        #expect(QRCodes.link("WIFI:S:Home;T:WPA;P:secret;;") == nil)
        #expect(QRCodes.link("x-apple.systempreferences:com.apple.LoginItems-Settings.extension") == nil, "a code never opens an app's scheme")
    }

    @Test("Read a QR code's screen pick opens Capture text's overlay")
    func qrArea() async {
        #expect(PilotCapture.purpose(.qr) == .ocr)
    }
}
