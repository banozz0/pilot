import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PilotCore

/// The capture editor's model and renderer (spec `capture.html` CP5, CP7): every tool flattens, undo and redo walk the
/// changes, step counters renumber after a delete, a blur touches only its rectangle, an erase fills with the
/// background, a spotlight darkens only outside it, and a crop exports exactly its size. Set PILOT_RENDER_DIR to see
/// the flattened tools.
@Suite("Markup")
struct MarkupTests {
    static let size = CGSize(width: 200, height: 120)

    /// A 2x capture, in points from the top: a grey band (0 to 20), white, then black stripes every 6 points (60 to 120).
    static func capture() -> CGImage {
        let w = 400, h = 240
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        for x in stride(from: 0, to: w, by: 12) { ctx.fill(CGRect(x: x, y: 0, width: 4, height: 120)) }
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 200, width: w, height: 40))
        return ctx.makeImage()!
    }

    /// The pixel at a point (top left, points) of a 2x image, as 0xRRGGBB.
    static func pixel(_ image: CGImage, _ p: CGPoint) -> UInt32 {
        var rgba = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let x = Int(p.x * 2), y = Int(p.y * 2)
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return UInt32(rgba[0]) << 16 | UInt32(rgba[1]) << 8 | UInt32(rgba[2])
    }

    static func every() -> [(String, Mark.Kind)] {
        [("arrow", .arrow(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 60), curved: true)),
         ("rect", .rect(CGRect(x: 30, y: 30, width: 60, height: 40), filled: true)),
         ("ellipse", .ellipse(CGRect(x: 100, y: 20, width: 60, height: 40), filled: false)),
         ("text", .text("Hello", at: CGPoint(x: 20, y: 80), pill: true)),
         ("pen", .pen([CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 30), CGPoint(x: 80, y: 15)])),
         ("highlight", .highlight([CGPoint(x: 20, y: 100), CGPoint(x: 160, y: 100)])),
         ("blur", .blur(CGRect(x: 40, y: 10, width: 60, height: 40), pixelate: false)),
         ("box", .box(CGRect(x: 120, y: 70, width: 40, height: 20), erase: false)),
         ("step", .step(1, at: CGPoint(x: 170, y: 30))),
         ("spotlight", .spotlight(CGRect(x: 50, y: 20, width: 80, height: 60)))]
    }

    @Test("Every tool flattens at 2x, at the capture's own size")
    func everyTool() throws {
        let out = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("markup") }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        for (name, kind) in Self.every() {
            var doc = MarkupDocument(size: Self.size)
            doc.add(kind, colour: 0xF0443A, size: 4)
            let flat = try #require(MarkupRenderer.flatten(Self.capture(), doc, scale: 2), "\(name)")
            #expect(flat.width == 400 && flat.height == 240, "\(name)")
            if let out, let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent("\(name).png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, flat, nil)
                CGImageDestinationFinalize(dest)
            }
        }
    }

    @Test("A rectangle's edge takes its colour")
    func rectColour() throws {
        var doc = MarkupDocument(size: Self.size)
        doc.add(.rect(CGRect(x: 100, y: 130 - 100, width: 60, height: 40), filled: false), colour: 0x2FB566, size: 6)
        let flat = try #require(MarkupRenderer.flatten(Self.capture(), doc, scale: 2))
        #expect(Self.pixel(flat, CGPoint(x: 100, y: 50)) == 0x2FB566)
    }

    @Test("A blur changes only its rectangle")
    func blurStaysInside() throws {
        let capture = Self.capture()
        var doc = MarkupDocument(size: Self.size)
        doc.add(.blur(CGRect(x: 30, y: 70, width: 60, height: 40), pixelate: false), colour: 0, size: 6)
        let flat = try #require(MarkupRenderer.flatten(capture, doc, scale: 2))
        #expect(Self.pixel(flat, CGPoint(x: 60.5, y: 90)) != Self.pixel(capture, CGPoint(x: 60.5, y: 90)), "inside: blurred")
        for p in [CGPoint(x: 24.5, y: 90), CGPoint(x: 96.5, y: 90), CGPoint(x: 60.5, y: 116), CGPoint(x: 60.5, y: 66)] {
            #expect(Self.pixel(flat, p) == Self.pixel(capture, p), "outside at \(p): untouched")
        }
    }

    @Test("Redact fills black; erase fills with the colour round its edge")
    func box() throws {
        var doc = MarkupDocument(size: Self.size)
        doc.add(.box(CGRect(x: 20, y: 4, width: 40, height: 12), erase: true), colour: 0, size: 1)
        doc.add(.box(CGRect(x: 120, y: 70, width: 40, height: 20), erase: false), colour: 0, size: 1)
        let flat = try #require(MarkupRenderer.flatten(Self.capture(), doc, scale: 2))
        #expect([0x808080, 0x7F7F7F].contains(Self.pixel(flat, CGPoint(x: 40, y: 10))))
        #expect(Self.pixel(flat, CGPoint(x: 140, y: 80)) == 0x111111)
    }

    @Test("A spotlight darkens outside its rectangle, never inside")
    func spotlight() throws {
        let capture = Self.capture()
        var doc = MarkupDocument(size: Self.size)
        doc.add(.spotlight(CGRect(x: 50, y: 60, width: 80, height: 30)), colour: 0, size: 5)
        let flat = try #require(MarkupRenderer.flatten(capture, doc, scale: 2))
        #expect(Self.pixel(flat, CGPoint(x: 90, y: 75)) == Self.pixel(capture, CGPoint(x: 90, y: 75)))
        #expect(Self.pixel(flat, CGPoint(x: 10, y: 75)) < Self.pixel(capture, CGPoint(x: 10, y: 75)))
    }

    @Test("A crop exports exactly its size, and undo gives the whole back")
    func crop() throws {
        var doc = MarkupDocument(size: Self.size)
        doc.setCrop(CGRect(x: 10.4, y: 20, width: 80, height: 50.2))
        #expect(doc.crop == CGRect(x: 10, y: 20, width: 81, height: 51))
        let flat = try #require(MarkupRenderer.flatten(Self.capture(), doc, scale: 2))
        #expect(flat.width == 162 && flat.height == 102)
        doc.undo()
        #expect(doc.crop == nil)
        doc.setCrop(CGRect(x: 0, y: 0, width: 2, height: 2))
        #expect(doc.crop == nil, "a crop under 4 points is none")
    }

    @Test("Undo and redo walk the changes; a new change clears redo")
    func undoRedo() {
        var doc = MarkupDocument(size: Self.size)
        let a = doc.add(.rect(CGRect(x: 0, y: 0, width: 10, height: 10), filled: false), colour: 1, size: 2)
        doc.update(a) { $0 = $0.moved(by: CGPoint(x: 5, y: 5)) }
        #expect(doc.marks[0].bounds.minX > 3)
        doc.undo()
        #expect(doc.marks[0].kind == .rect(CGRect(x: 0, y: 0, width: 10, height: 10), filled: false))
        doc.redo()
        #expect(doc.marks[0].kind == .rect(CGRect(x: 5, y: 5, width: 10, height: 10), filled: false))
        doc.undo()
        doc.undo()
        #expect(doc.marks.isEmpty && !doc.canUndo && doc.canRedo)
        doc.add(.step(0, at: .zero), colour: 1, size: 2)
        #expect(!doc.canRedo)
    }

    @Test("Steps number 1, 2, 3 in the order placed; deleting one renumbers the rest")
    func steps() {
        var doc = MarkupDocument(size: Self.size)
        #expect(doc.nextStep == 1)
        let one = doc.add(.step(0, at: CGPoint(x: 10, y: 10)), colour: 1, size: 4)
        doc.add(.arrow(from: .zero, to: CGPoint(x: 5, y: 5), curved: false), colour: 1, size: 4)
        doc.add(.step(0, at: CGPoint(x: 20, y: 10)), colour: 1, size: 4)
        doc.add(.step(0, at: CGPoint(x: 30, y: 10)), colour: 1, size: 4)
        func numbers() -> [Int] { doc.marks.compactMap { if case .step(let n, _) = $0.kind { n } else { nil } } }
        #expect(numbers() == [1, 2, 3])
        doc.delete(one)
        #expect(numbers() == [1, 2])
        #expect(doc.nextStep == 3)
    }

    @Test("The select tool finds the front mark under a point")
    func hit() {
        var doc = MarkupDocument(size: Self.size)
        doc.add(.rect(CGRect(x: 0, y: 0, width: 100, height: 100), filled: true), colour: 1, size: 2)
        let front = doc.add(.step(0, at: CGPoint(x: 50, y: 50)), colour: 1, size: 2)
        #expect(doc.mark(at: CGPoint(x: 50, y: 50))?.id == front)
        #expect(doc.mark(at: CGPoint(x: 150, y: 110)) == nil)
    }

    @Test("Keys pick tools: 1 to 9, 0 the step, C crop, F spotlight")
    func keys() {
        #expect(MarkTool.picked(by: "1") == .select && MarkTool.picked(by: "9") == .box && MarkTool.picked(by: "0") == .step)
        #expect(MarkTool.picked(by: "c") == .crop && MarkTool.picked(by: "F") == .spotlight && MarkTool.picked(by: "x") == nil)
        #expect(MarkTool.numbered.map(\.key) == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
    }
}
