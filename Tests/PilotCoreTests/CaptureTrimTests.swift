import CoreGraphics
import Foundation
import Testing
@testable import PilotCore

/// Smart selection's snap (Sven Q189): a rough area trims to its content over a uniform background, and leaves alone
/// what it cannot read; a 5K frame snaps fast enough to run on the release.
@Suite("Capture trim")
struct CaptureTrimTests {
    /// A `size` image of `background` with `blocks` filled in `colour`, rects from the top left.
    static func image(_ size: CGSize, background: CGColor, blocks: [CGRect], colour: CGColor = CGColor(gray: 0.2, alpha: 1)) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(background)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(colour)
        for b in blocks { ctx.fill(CGRect(x: b.minX, y: size.height - b.maxY, width: b.width, height: b.height)) }
        return ctx.makeImage()!
    }

    static let white = CGColor(gray: 1, alpha: 1)

    /// The CPU time this thread spends in `body`: what the trim costs, which the wall clock overstates on a loaded Mac by
    /// the time other processes held the core (Build 65's full run: the 100 ms bound failed at load 60-80).
    static func cpuTime(_ body: () -> Void) -> Duration {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        body()
        return .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start))
    }

    @Test("A loose area round a block on white snaps to the block")
    func block() {
        let img = Self.image(CGSize(width: 400, height: 300), background: Self.white, blocks: [CGRect(x: 120, y: 80, width: 90, height: 40),
                                                                                               CGRect(x: 150, y: 140, width: 30, height: 20)])
        #expect(CaptureTrim.trim(img, pixels: CGRect(x: 60, y: 30, width: 300, height: 250)) == CGRect(x: 120, y: 80, width: 90, height: 80))
    }

    @Test("Anti-aliasing within the tolerance counts as background; a solid block edge stops the trim")
    func tolerance() {
        let img = Self.image(CGSize(width: 200, height: 200), background: CGColor(gray: 0.97, alpha: 1),
                             blocks: [CGRect(x: 40, y: 40, width: 120, height: 120)], colour: CGColor(gray: 0.95, alpha: 1))
        // 0.97 against 0.95 is 5 levels apart: all background, so the area stays as dragged.
        let rect = CGRect(x: 10, y: 10, width: 180, height: 180)
        #expect(CaptureTrim.trim(img, pixels: rect) == rect)
        let solid = Self.image(CGSize(width: 200, height: 200), background: Self.white, blocks: [CGRect(x: 40, y: 40, width: 120, height: 120)],
                               colour: CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        #expect(CaptureTrim.trim(solid, pixels: rect) == CGRect(x: 40, y: 40, width: 120, height: 120))
    }

    @Test("An area with no corner colour in common, or all one colour, is left as dragged")
    func untouched() {
        let flat = Self.image(CGSize(width: 100, height: 100), background: Self.white, blocks: [])
        #expect(CaptureTrim.trim(flat, pixels: CGRect(x: 10, y: 10, width: 50, height: 50)) == CGRect(x: 10, y: 10, width: 50, height: 50))
        // Content in three corners: no background to trim.
        let busy = Self.image(CGSize(width: 100, height: 100), background: Self.white,
                              blocks: [CGRect(x: 0, y: 0, width: 20, height: 20), CGRect(x: 80, y: 0, width: 20, height: 20), CGRect(x: 0, y: 80, width: 20, height: 20)])
        #expect(CaptureTrim.trim(busy, pixels: CGRect(x: 0, y: 0, width: 100, height: 100)) == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test("A whole 5K frame snaps to a small block in its middle, and to a full-height stripe, quickly")
    func fiveK() {
        let img = Self.image(CGSize(width: 5120, height: 2880), background: Self.white, blocks: [CGRect(x: 2500, y: 1400, width: 64, height: 32)])
        var out = CGRect.null
        let took = Self.cpuTime { out = CaptureTrim.trim(img, pixels: CGRect(x: 0, y: 0, width: 5120, height: 2880)) }
        print("capture trim 5K full frame, CPU: \(took)")
        #expect(out == CGRect(x: 2500, y: 1400, width: 64, height: 32))
        #expect(took < .milliseconds(100))
        // A full-height stripe keeps every row, so each row's margins are read pixel by pixel: the slow case.
        let stripe = Self.image(CGSize(width: 5120, height: 2880), background: Self.white, blocks: [CGRect(x: 2500, y: 0, width: 8, height: 2880)])
        let slow = Self.cpuTime { out = CaptureTrim.trim(stripe, pixels: CGRect(x: 0, y: 0, width: 5120, height: 2880)) }
        print("capture trim 5K full-height stripe, CPU: \(slow)")
        #expect(out == CGRect(x: 2500, y: 0, width: 8, height: 2880))
        #expect(slow < .milliseconds(1000))
    }
}
