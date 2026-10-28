import CoreGraphics
import Foundation
import Testing
@testable import PilotCore

/// The pixel ruler and the backdrop (spec `capture.html` CP12): a point over a button reads its edges to the pixel; a
/// stamp's label is in pixels or points; a backdrop pads the export by its padding, fills round it and is one undo step.
@Suite("Pixel ruler and backdrop")
struct PixelRulerTests {
    /// 2x: white, with a blue button from (20, 10) to (60, 30) in points, top left origin.
    static func page() -> CGImage {
        let w = 200, h = 100
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 40, y: h - 60, width: 80, height: 40))
        return ctx.makeImage()!
    }

    @Test("Inside the button the ruler reads its edges, to the pixel")
    func edges() throws {
        let grid = try #require(PixelGrid(Self.page()))
        let (l, r, u, d) = PixelRuler.lines(grid, at: CGPoint(x: 30, y: 20), scale: 2)
        #expect(l.x == 20 && r.x == 60 && u.y == 10 && d.y == 30)
        #expect(PixelRuler.label(l, r, scale: 2, points: false) == "80 px")
        #expect(PixelRuler.label(u, d, scale: 2, points: true) == "20 pt")
        let s = grid.span(x: 0, y: 0)
        #expect(s.left == 0 && s.up == 0 && s.right == 199, "the white runs to the right edge from the corner")
    }

    @Test("A measure stamp flattens, and the ruler is on R")
    func stamp() throws {
        var doc = MarkupDocument(size: CGSize(width: 100, height: 50))
        doc.add(.measure(from: CGPoint(x: 20, y: 40), to: CGPoint(x: 60, y: 40), points: false), colour: 0xF0443A, size: 1)
        #expect(MarkupRenderer.flatten(Self.page(), doc, scale: 2) != nil)
        #expect(MarkTool.picked(by: "r") == .ruler && !MarkTool.ruler.sized)
    }

    @Test("A backdrop pads the export, fills round it and comes off with one undo")
    func backdrop() throws {
        var doc = MarkupDocument(size: CGSize(width: 100, height: 50))
        doc.setBackdrop(Backdrop(fill: .colour(0x2FB566), pad: 16, radius: 6, shadow: 0))
        let framed = try #require(MarkupRenderer.flatten(Self.page(), doc, scale: 2))
        #expect(framed.width == 200 + 2 * 32 && framed.height == 100 + 2 * 32)
        #expect(MarkupTests.pixel(framed, CGPoint(x: 2, y: 2)) == 0x2FB566, "the corner is the fill")
        doc.setCrop(CGRect(x: 10, y: 10, width: 40, height: 20))
        #expect(try #require(MarkupRenderer.flatten(Self.page(), doc, scale: 2)).width == 80 + 64)
        doc.undo(); doc.undo()
        #expect(doc.backdrop == nil && doc.crop == nil && !doc.edited)
    }
}
