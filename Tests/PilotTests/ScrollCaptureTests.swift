import AppKit
import CoreVideo
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The scrolling capture's session (spec `capture.html` CP11) with no stream: frames fed as the stream would feed them
/// stitch into one tall image, Hyper+D again ends it, the quiet after scrolling ends it, Cancel keeps nothing, and the
/// stream's padded rows are read without their padding.
@MainActor
@Suite("Scroll capture")
struct ScrollCaptureTests {
    static let width = 40, height = 60

    /// The made-up page's rows `range`, as BGRA, every row its own.
    static func frame(_ range: Range<Int>) -> [UInt8] {
        range.flatMap { r in (0..<(width * 4)).map { UInt8(truncatingIfNeeded: r &* 13 &+ $0 &* 5) } }
    }

    static func settle(until done: () -> Bool) async { await CaptureGrabTests.settle(until: done) }

    @Test("Hyper+D again ends it: the frames stitch into one image, delivered as a capture")
    func keyEnds() async {
        let grab = DisplayGrab(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 200), scale: 1, image: CaptureGrabTests.image(200, 200))
        var delivered: CGImage?
        let defaults = UserDefaults(suiteName: testSuite())!
        let capture = PilotCapture(grabber: CaptureGrabTests.FakeGrabber(grabs: [grab]), store: CaptureSettingsStore(defaults: defaults),
                                   defaults: defaults, deliver: { image, _ in delivered = image }, tell: { _, _ in })
        capture.overlaysVisible = false
        capture.run(.scroll)
        await Self.settle { capture.overlay != nil }
        capture.overlay?.close(.area(grab, CGRect(x: 20, y: 30, width: Double(Self.width), height: Double(Self.height))))
        let session = try? #require(capture.scrolling)
        #expect(session?.area == CGRect(x: 20, y: 30, width: 40, height: 60))
        session?.quiet = .seconds(60)
        for at in [0, 15, 35, 60] { session?.feed(Self.frame(at..<(at + Self.height))) }
        await Self.settle { session?.height == 120 }
        capture.run(.scroll)
        await Self.settle { delivered != nil }
        #expect(delivered?.width == Self.width)
        #expect(delivered?.height == 120)
        #expect(capture.scrolling == nil)
    }

    @Test("Three seconds without a new row end it on its own (here: 50 ms)")
    func quietEnds() async {
        var got: (CGImage?, String?)?
        let session = ScrollCapture(area: CGRect(x: 0, y: 0, width: 40, height: 60), display: 1, scale: 1) { got = ($0, $1) }
        session.quiet = .milliseconds(50)
        session.feed(Self.frame(0..<60))
        session.feed(Self.frame(20..<80))
        await Self.settle { got != nil }
        #expect(got?.0?.height == 80)
        #expect(!session.isRunning)
    }

    /// A session that scrolls for Sven over a made-up page `rows` tall, its posts answered with the next frame: the page
    /// moves by the step and stops at its ends, as a real page does.
    /// `gain`: how many rows the page moves per point asked, as the app scales a wheel step its own way.
    static func auto(rows: Int, from start: Int, upward: Bool, gain: Int = 1, got: @escaping (CGImage?) -> Void) -> (ScrollCapture, () -> [Int32]) {
        let session = ScrollCapture(area: CGRect(x: 0, y: 0, width: 40, height: 60), display: 1, scale: 1, auto: true, upward: upward) { image, _ in got(image) }
        session.watchInput = false
        session.settle = .milliseconds(15)
        session.quiet = .seconds(60)
        var at = start, posted: [Int32] = []
        session.post = { delta, _ in
            posted.append(delta)
            // A wheel turned down (negative) shows what is below.
            at = min(rows - height, max(0, at - Int(delta) * gain))
            session.feed(Self.frame(at..<(at + height)))
        }
        session.feed(Self.frame(at..<(at + height)))
        return (session, { posted })
    }

    @Test("Pilot scrolls the page itself to its end and stops when nothing more comes")
    func autoDown() async {
        var image: CGImage?
        let (session, posted) = Self.auto(rows: 200, from: 0, upward: false) { image = $0 }
        session.scrollForSven()
        await CaptureGrabTests.settle { image != nil }
        #expect(image?.height == 200)
        #expect(posted().allSatisfy { $0 < 0 })
        #expect(!session.isRunning)
    }

    @Test("A page that moves four times what each step asks (an app scaling the wheel) is still stitched whole (build 53)")
    func amplified() async {
        var image: CGImage?
        let (session, posted) = Self.auto(rows: 400, from: 0, upward: false, gain: 4) { image = $0 }
        session.scrollForSven()
        await CaptureGrabTests.settle { image != nil }
        #expect(image?.height == 400, "every part of the page, not one frame")
        #expect(posted().contains { $0 > 0 }, "a step that lost the overlap was undone")
    }

    @Test("A step goes out as small continuous pixel events, marked as Pilot's, adding up to the step")
    func events() {
        let events = ScrollCapture.scrollEvents(-100, at: CGPoint(x: 10, y: 20))
        #expect(events.count == 4)
        #expect(events.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }.reduce(0, +) == -100)
        #expect(events.allSatisfy { $0.getIntegerValueField(.scrollWheelEventIsContinuous) == 1 })
        #expect(events.allSatisfy { abs($0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) <= 30 })
        #expect(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == ScrollCapture.marker && $0.location == CGPoint(x: 10, y: 20) })
    }

    @Test("The pace aims at 40 % of the area from how far the page really moved, and halves after a lost step")
    func pace() {
        var pace = ScrollPace(area: 600, scale: 2)
        #expect(pace.step == 150)
        pace.moved(rows: 1200, for: 150)
        #expect(pace.step == 60, "the page moved 4 points a point: 240 points want 60")
        pace.missed()
        #expect(pace.step == 30)
        for _ in 0..<5 { pace.missed() }
        #expect(pace.lost)
    }

    @Test("Upward, from the middle of the page to its top, the result is the page the right way round")
    func autoUp() async {
        var image: CGImage?
        let (session, posted) = Self.auto(rows: 200, from: 140, upward: true) { image = $0 }
        session.scrollForSven()
        await CaptureGrabTests.settle { image != nil }
        #expect(image?.height == 200)
        #expect(posted().first.map { $0 > 0 } == true, "upward turns the wheel up")
    }

    @Test("The user's own scroll hands over: Pilot stops scrolling and the capture carries on")
    func handOver() async {
        let (session, posted) = Self.auto(rows: 2000, from: 0, upward: false) { _ in }
        session.settle = .milliseconds(30)
        session.scrollForSven()
        await CaptureGrabTests.settle { posted().count >= 2 }
        session.handOver()
        let count = posted().count
        try? await Task.sleep(for: .milliseconds(150))
        #expect(posted().count <= count + 1 && !session.scrolling && session.isRunning)
        session.cancel()
    }

    @Test("Cancel keeps nothing and says so")
    func cancel() async {
        var got: (CGImage?, String?)?
        let session = ScrollCapture(area: CGRect(x: 0, y: 0, width: 40, height: 60), display: 1, scale: 1) { got = ($0, $1) }
        session.feed(Self.frame(0..<60))
        await Self.settle { session.height == 60 }
        session.cancel()
        #expect(got?.0 == nil && got?.1 == "Scrolling capture cancelled.")
    }

    @Test("A pixel buffer's padded rows are read without the padding")
    func rows() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 10, 3, kCVPixelFormatType_32BGRA, [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let stride = CVPixelBufferGetBytesPerRow(pixels), base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<3 { for x in 0..<(10 * 4) { base[y * stride + x] = UInt8(y * 40 + x) } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(stride > 40, "the buffer has padding to skip")
        #expect(ScrollOutput.rows(pixels) == (0..<120).map { UInt8($0) })
    }

    @Test("The frame dump is off unless its defaults key is on; on, each frame is a PNG of its pixels and a line in log.txt")
    func frameDump() async throws {
        let defaults = UserDefaults(suiteName: testSuite())!
        let home = FileManager.default.temporaryDirectory.appending(path: "dump-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let area = CGRect(x: 0, y: 0, width: 4, height: 3)
        #expect(ScrollFrameDump.start(area: area, scale: 1, upward: false, defaults: defaults, home: home) == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Pictures").path), "off, nothing is made")
        defaults.set(true, forKey: ScrollFrameDump.key)
        let dump = try #require(ScrollFrameDump.start(area: area, scale: 1, upward: false, defaults: defaults, home: home))
        var pixels: [UInt8] = []
        for i in 0..<12 { pixels += [UInt8(i * 20), UInt8(i * 10), UInt8(255 - i * 20), 255] }
        dump.frame(pixels, width: 4, height: 3, result: "first, 3 px")
        dump.note("scroll -40")
        let png = dump.folder.appending(path: "0001.png"), logFile = dump.folder.appending(path: "log.txt")
        func logged() -> String { (try? String(contentsOf: logFile, encoding: .utf8)) ?? "" }
        await Self.settle { FileManager.default.fileExists(atPath: png.path) && logged().contains("scroll -40") }
        let image = try #require(Pins.load(png)?.0)
        let read = try #require(ScrollFrameDumpTests.bgra(image))
        #expect(read == pixels, "the PNG holds the frame's pixels")
        let log = logged()
        #expect(log.contains("frame 0001  first, 3 px") && log.contains("down"))
    }
}

enum ScrollFrameDumpTests {
    /// An image's pixels as BGRA, rows top first.
    static func bgra(_ image: CGImage) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? out : nil
    }
}
