import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PilotCore

/// The top bar legible over any wallpaper, as the macOS menu bar is (Sven, Q254): each cell of the strip under the bar
/// toned by macOS's measured curve, the readings' colours keeping their hue and reading, and the strip read from the
/// picture where macOS places it.
@Suite("Bar tone")
struct BarToneTests {
    static func strip(_ rgb: UInt32, width: Int = 8) -> WallpaperStrip.Grid {
        let c = Contrast.rgb(rgb).map { UInt8($0) }
        return WallpaperStrip.Grid(width: width, height: 2, rgb: Array((0..<width * 2).map { _ in c }.joined()))
    }

    /// Sven's gumball wallpaper under his bar (2026-10-17).
    static let teal: UInt32 = 0x5BC0C9

    @Test("macOS's curve: a cell at 3.5:1 to white or better is left alone, a brighter one is pulled down, white to 1.84:1")
    func curve() {
        #expect(BarTone.toned(4.0) == 4.0 && BarTone.toned(3.5) == 3.5)
        #expect(BarTone.toned(1.0) == 1.84)
        #expect(abs(BarTone.toned(1.57) - 2.72) < 0.001)
        // Rising: a brighter cell never ends darker than a dimmer one.
        let outs = stride(from: 1.0, through: 3.5, by: 0.05).map(BarTone.toned)
        #expect(zip(outs, outs.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("Under white ink a dark cell keeps its colour (no band) and a white one is masked toward 1.84:1; the median ground follows")
    func tonesEachCell() throws {
        let dark = try #require(BarTone.make(Self.strip(0x202030), prefersWhite: true))
        #expect(dark.ink == BarTone.white && dark.alpha.allSatisfy { $0 == 0 })
        let light = try #require(BarTone.make(Self.strip(0xFFFFFF), prefersWhite: true))
        #expect(light.maskColour == 0x000000 && light.alpha.allSatisfy { $0 > 50 })
        let contrast = Contrast.ratio(BarTone.white, light.ground)
        #expect(abs(contrast - 1.84) < 0.15, "white toned to \(contrast):1")
        // A light theme mirrors it: dark ink, a white mask over a dark cell, none over a light one.
        let mirrored = try #require(BarTone.make(Self.strip(0x000000), prefersWhite: false))
        #expect(mirrored.ink == BarTone.dark && mirrored.maskColour == 0xFFFFFF && mirrored.alpha.allSatisfy { $0 > 0 })
        #expect(try #require(BarTone.make(Self.strip(0xF0F0F0), prefersWhite: false)).alpha.allSatisfy { $0 == 0 })
        #expect(BarTone.make(WallpaperStrip.Grid(width: 0, height: 0, rgb: []), prefersWhite: true) == nil)
    }

    @Test("Amber, red and green read at 3:1 on white, the toned teal and near-black, keep their hue and stay apart")
    func statusColours() throws {
        let void = try #require(PilotTheme.named("void"))
        let teal = try #require(BarTone.make(Self.strip(Self.teal), prefersWhite: true)).ground
        for ground in [teal, 0xFFFFFF, 0x1A1A1A] as [UInt32] {
            let made = [void.amber, void.problem, void.good].map { (Contrast.legible($0, on: ground), $0) }
            for (out, theme) in made {
                #expect(Contrast.ratio(out, ground) >= 3, "\(String(format: "%06X", out)) on \(String(format: "%06X", ground))")
                #expect(Self.hueGap(Contrast.hsl(out).h, Contrast.hsl(theme).h) < 6, "hue moved: \(String(format: "%06X → %06X", theme, out))")
            }
            let hues = made.map { Contrast.hsl($0.0).h }
            #expect(Self.hueGap(hues[0], hues[1]) > 20 && Self.hueGap(hues[1], hues[2]) > 20 && Self.hueGap(hues[0], hues[2]) > 20)
        }
        // A colour that reads already is left alone.
        #expect(Contrast.legible(0xFFFFFF, on: 0x000000) == 0xFFFFFF)
    }

    static func hueGap(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }

    @Test("Fill Screen crops a landscape picture's sides on a portrait screen and its top on a wide one; Fit leaves the fill colour above")
    func placement() {
        let picture = CGSize(width: 3440, height: 1440)
        let portrait = WallpaperStrip.rect(image: picture, screen: CGSize(width: 1080, height: 1920), placement: .init())
        #expect(portrait.minY == 0 && portrait.height == 1920 && portrait.minX < -1000)
        let fit = WallpaperStrip.rect(image: picture, screen: CGSize(width: 1080, height: 1920), placement: .init(clips: false))
        #expect(fit.width == 1080 && fit.minY > 700)
        // Fit on the portrait screen: the strip at the top is the fill colour.
        let pixels = [UInt8](repeating: 255, count: 344 * 144 * 4)
        let grid = WallpaperStrip.grid(pixels: pixels, width: 344, height: 144, screen: CGSize(width: 1080, height: 1920), strip: 30,
                                       placement: .init(clips: false, fill: [10, 20, 30]))
        #expect(grid.rgb == Array(repeating: [10, 20, 30] as [UInt8], count: grid.width * grid.height).joined().map { $0 })
    }

    @Test("A picture read from its file: the strip under the bar, not the picture below it, cell by cell")
    func readsTheFile() throws {
        // 200 x 100: the top 10 rows white on the left half and black on the right, the rest mid grey.
        let (w, h) = (200, 100)
        var bytes = [UInt8](repeating: 128, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let p = (y * w + x) * 4
            if y < 10 { let v: UInt8 = x < w / 2 ? 255 : 0; (bytes[p], bytes[p + 1], bytes[p + 2]) = (v, v, v) }
            bytes[p + 3] = 255
        } }
        let context = try #require(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bar-legibility-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        // A 2:1 screen shows it whole; the bar's 30 of 1000 points is the top 3 rows.
        let grid = try #require(WallpaperStrip.grid(url, screen: CGSize(width: 2000, height: 1000), strip: 30))
        #expect(grid.width == 1000 && grid.height == 15)
        let first = grid.rgb[0..<3], last = grid.rgb[(grid.width - 1) * 3..<grid.width * 3]
        #expect(first.allSatisfy { $0 > 240 } && last.allSatisfy { $0 < 15 }, "\(Array(first)) … \(Array(last))")
    }
}
