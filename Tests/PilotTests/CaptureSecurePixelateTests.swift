import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Secure pixelate (C10, T26; export tests allowed, Sven Q807): what the capture editor exports over a secret holds
/// nothing of it. Two captures alike but for the secret export the same bytes, through a lens, a capture-fill backdrop
/// and Text only too.
@MainActor
@Suite("Capture secure pixelate")
struct CaptureSecurePixelateTests {
    /// Where the secret sits, in points.
    static let secret = CGRect(x: 40, y: 30, width: 80, height: 24)

    /// A 200 × 120 point capture at 2x: white with a blue band, and the secret drawn in it from `seed`, as text-like
    /// strokes of its own colours.
    static func capture(_ seed: UInt64) -> CGImage {
        let w = 400, h = 240
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 40))
        var n = seed
        func next() -> CGFloat { n = n &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(n >> 40) / CGFloat(1 << 24) }
        let s = secret
        for i in 0..<24 {
            ctx.setFillColor(CGColor(srgbRed: next(), green: next(), blue: next(), alpha: 1))
            ctx.fill(CGRect(x: (s.minX + CGFloat(i) * 3.2) * 2, y: CGFloat(h) - s.maxY * 2 + next() * 8, width: 4, height: 20 + next() * 20))
        }
        return ctx.makeImage()!
    }

    /// The image's bytes as sRGB RGBA, for comparing two exports exactly.
    static func bytes(_ image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        out.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return out
    }

    /// `marks` done on an editor over `capture`, exported.
    static func export(_ capture: CGImage, _ marks: (EditorModel) -> Void) async -> CGImage? {
        let m = EditorModel(image: capture, scale: 2, accent: 0x3CD2DB, dark: true)
        marks(m)
        return await m.export()
    }

    static func pixelate(_ m: EditorModel, _ r: CGRect = secret.insetBy(dx: -0.3, dy: -0.3)) {
        m.pick(.blur); m.setStyle(1)
        m.begin(CGPoint(x: r.minX, y: r.minY)); m.end(CGPoint(x: r.maxX, y: r.maxY))
    }

    /// The magnifier over the secret, its lens then moved off it.
    static func magnify(_ m: EditorModel) {
        m.pick(.spotlight); m.setStyle(1)
        m.begin(CGPoint(x: secret.midX - 20, y: secret.midY - 20)); m.end(CGPoint(x: secret.midX + 20, y: secret.midY + 20))
        m.pick(.select)
        m.begin(CGPoint(x: secret.midX, y: secret.midY)); m.end(CGPoint(x: secret.midX + 50, y: secret.midY + 50))
    }

    @Test("Two different secrets under Pixelate export the same bytes: alone, under a lens either side of it, in a capture backdrop, under a blur")
    func secretsExportAlike() async throws {
        let a = Self.capture(1), b = Self.capture(2)
        // The test can tell the secrets apart: unmarked, the exports differ.
        let plainA = try #require(await Self.export(a) { _ in }), plainB = try #require(await Self.export(b) { _ in })
        #expect(Self.bytes(plainA) != Self.bytes(plainB))

        let cases: [(String, (EditorModel) -> Void)] = [
            ("pixelate", { Self.pixelate($0) }),
            ("lens after", { Self.pixelate($0); Self.magnify($0) }),
            ("lens before", { Self.magnify($0); Self.pixelate($0) }),
            ("capture backdrop", { Self.pixelate($0); $0.setBackdrop(Backdrop(fill: .capture, pad: 40)) }),
            ("blur over it", { m in
                Self.pixelate(m)
                m.pick(.blur); m.setStyle(0); m.setSize(1)
                let r = Self.secret.insetBy(dx: -20, dy: -10)
                m.begin(CGPoint(x: r.minX, y: r.minY)); m.end(CGPoint(x: r.maxX, y: r.maxY))
            }),
        ]
        for (name, marks) in cases {
            let exportA = try #require(await Self.export(a, marks)), exportB = try #require(await Self.export(b, marks))
            #expect(exportA.width == exportB.width && exportA.height == exportB.height)
            #expect(Self.bytes(exportA) == Self.bytes(exportB), "\(name): the export still tells the secrets apart")
        }
    }

    @Test("Text only's pixelate covers each line's whole pixels with the same noise whatever was under it")
    func textOnlyAlike() throws {
        let a = Self.capture(1), b = Self.capture(2)
        func flat(_ image: CGImage) -> CGImage? {
            var doc = MarkupDocument(size: CGSize(width: 200, height: 120))
            let line = Self.secret.insetBy(dx: 0.3, dy: 0.3)
            doc.add(.blurText(Self.secret.insetBy(dx: -6, dy: -6), boxes: [line], pixelate: true), colour: 0, size: 5)
            return MarkupRenderer.flatten(image, doc, scale: 2)
        }
        let fa = try #require(flat(a)), fb = try #require(flat(b))
        #expect(Self.bytes(fa) == Self.bytes(fb), "Text only: the export still tells the secrets apart")
    }
}
