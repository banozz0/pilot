#if DEBUG
import AppKit
import ImageIO
import PilotCore
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Pilot

/// The backdrop panel (P70, after Snapzy's background sidebar) open in the real capture editor, in three backdrops (the
/// accent's wash with a saved preset, a wallpaper blurred at 16:9, the capture itself frosted with a deep shadow), the
/// second one's export as Copy and Save write it, and the after-capture thumbnail's one 4:3 card for a wide, a tall and
/// a thin strip of a capture, at rest and hovered; Instrument (Tokyo Night, Folio) and Toybox (toybox-night, toybox).
/// Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter BackdropPanelRenders`
extension SharedLook {
@MainActor
@Suite("Backdrop panel renders")
struct BackdropPanelRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The backdrop panel and the thumbnail card render in Instrument and Toybox, dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("backdrop-panel")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let walls = try Self.wallpapers(in: out.appendingPathComponent("wallpapers"))
        let library = BackdropLibrary.shared
        library.setWallpapersNow(walls)
        let capture = try #require(CaptureFixture.image())

        for pass in CaptureEditorRenders.passes {
            look.style = pass.style
            look.themeID = pass.theme
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            func model() -> EditorModel {
                let m = EditorModel(image: capture, scale: 2, accent: tokens.colors.accent.rgb, dark: tokens.dark, ground: tokens.colors.canvas.rgb)
                m.panelOpen = true
                return m
            }
            let wash = model()
            wash.setBackdrop { _ in }
            for p in library.presets { library.deletePreset(p.id) }
            library.savePreset(try #require(wash.backdrop))
            let wall = model()
            wall.setBackdrop(Backdrop(fill: .image(walls[1].path), blur: .soft, pad: 64, radius: 14, shadow: 0.6, ratio: .wide))
            wall.loadPictureNow()
            let frosted = model()
            frosted.setBackdrop(Backdrop(fill: .capture, blur: .frosted, pad: 72, radius: 24, shadow: 0.9))
            frosted.loadPictureNow()

            for (name, m) in [("1-wash-preset", wash), ("2-wallpaper-blurred-16x9", wall), ("3-capture-frosted", frosted)] {
                let size = EditorLayout.window(m.size, fit: 1, tokens: tokens, panel: true)
                let rep = try CaptureEditorRenders.draw(CaptureEditorView(model: m), tokens: tokens, size: size, scale: 2)
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("P-\(name)-\(pass.tag).png"))
            }
            if pass.tag == "instrument-dark" {
                // The export as Copy, Save and Drag hand it on: the backdrop in it.
                let flat = try #require(MarkupRenderer.flatten(capture, wall.document, scale: 2))
                #expect(abs(CGFloat(flat.width) / CGFloat(flat.height) - 16.0 / 9) < 0.01, "the export is 16:9")
                try Self.write(flat, to: out.appendingPathComponent("E-export-wallpaper-16x9.png"))
            }

            // The thumbnail's card: one size whatever the capture's shape, hovered with every button inside it.
            let shapes: [(String, CGSize)] = [("wide", CGSize(width: 1440, height: 900)), ("tall", CGSize(width: 420, height: 900)), ("strip", CGSize(width: 1400, height: 90))]
            for (shape, pt) in shapes {
                let image = try #require(Self.crop(capture, to: pt))
                for hovered in [false, true] {
                    let thumb = ThumbnailModel(image: image, scale: 2, file: nil)
                    thumb.hovered = hovered
                    thumb.stopClock()
                    let card = ThumbnailStack.size(thumb.size)
                    let rep = try CaptureEditorRenders.draw(ThumbnailView(model: thumb).padding(12).background(Color(hex: 0x3B6FD8)),
                                                           tokens: tokens, size: CGSize(width: card.width + 24, height: card.height + 24), scale: 2)
                    try #require(rep.representation(using: .png, properties: [:]))
                        .write(to: out.appendingPathComponent("T-\(shape)\(hovered ? "-hover" : "")-\(pass.tag).png"))
                }
            }
        }
    }

    /// Three made-up wallpapers: soft diagonal blends with a bright spot, as photos of sky and sea would read small.
    static func wallpapers(in folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sets: [[UInt32]] = [[0x1B3A8C, 0x4F8DF5, 0xDCE9FF], [0x0E4D64, 0x2A9D8F, 0xE9C46A], [0x3D1E6D, 0xC0487A, 0xFFB38A]]
        return try sets.enumerated().map { i, colours in
            let ctx = try #require(CGContext(data: nil, width: 960, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            MarkupRenderer.paint(.gradient(colours), in: CGRect(x: 0, y: 0, width: 960, height: 600), ctx)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.35))
            ctx.fillEllipse(in: CGRect(x: 180 + i * 220, y: 260, width: 300, height: 180))
            let url = folder.appendingPathComponent("Wallpaper \(i + 1).png")
            try write(try #require(ctx.makeImage()), to: url)
            return url
        }
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// The fixture page's top left, `size` points of it (at 2x), the rest white, as a capture of that shape would be.
    static func crop(_ page: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width * 2), h = Int(size.height * 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(page, in: CGRect(x: 0, y: h - page.height, width: page.width, height: page.height))
        return ctx.makeImage()
    }
}
}
#endif
