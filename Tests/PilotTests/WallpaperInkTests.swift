#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// The top bar legible over any wallpaper, as the macOS menu bar is (Sven, Q254): on Glass and Clear the bar reads the
/// wallpaper strip under it (BarWallpapers), keeps the theme's ink at full strength and tones each spot of the
/// wallpaper behind it by macOS's measured curve (BarTone). Liquid Glass draws nothing offscreen, so the renders lay
/// the wallpaper under the bar (and Glass's tint) by hand, as TopBarLookTests.overWallpaper does. With PILOT_RENDER_DIR
/// and CFFIXED_USER_HOME set, Sven's bar and a row of readings at their levels are written before and after over a busy
/// pink and light wallpaper (PILOT_RENDER_WALLPAPER's picture, else a made one), Glass and Clear, Instrument and Toybox:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-ink PILOT_RENDER_DIR=/tmp/pilot-renders-ink swift test --filter WallpaperInkTests`
@MainActor
@Suite("Wallpaper ink", .serialized)
struct WallpaperInkTests {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// A white wallpaper, Sven's gumball teal (2026-10-17) and a black one, as BarWallpapers reads them.
    static let wallpapers: [(String, UInt32)] = [("white", 0xF4F4F4), ("teal", 0x5BC0C9), ("black", 0x0E0E11)]
    static func strip(_ rgb: UInt32) -> WallpaperStrip.Grid {
        let c = Contrast.rgb(rgb).map { UInt8($0) }
        return WallpaperStrip.Grid(width: 720, height: 15, rgb: Array((0..<720 * 15).map { _ in c }.joined()))
    }

    @Test("Instrument on Glass and Clear keeps the theme's ink at full strength and tones only light wallpaper behind it; Toybox (opaque islands) and Solid are as before")
    func tonesForWallpaper() async throws {
        // Sven's theme as tokens, never previewed: Look's theme is shared with suites running beside this one.
        let look = Look.shared, void = try #require(PilotTheme.named("void"))
        let instrument = StyleTokens.of(.instrument, theme: void), toybox = StyleTokens.of(.toybox, theme: void)
        for background in [TopBarBackground.glass, .clear] {
            for (name, rgb) in Self.wallpapers {
                let (inked, made) = TopBarColour.ink(.theme, style: instrument, background: background, wallpaper: Self.strip(rgb), look: look)
                let tone = try #require(made).tone
                #expect(inked.inked && inked.dark && inked.colors.text2.alpha == 1, "\(background) \(name)")
                // Black is left as it is; white and Sven's teal are toned down, as macOS tones them.
                if background == .clear { #expect(tone.alpha.allSatisfy { $0 == 0 } == (name == "black"), "\(name): masked \(tone.alpha[0])") }
                #expect(TopBarColour.tone(Self.strip(rgb), background: background, colour: .theme, style: toybox, look: look) == nil)

                let (store, sources, timer) = try StripStyleTests.svensBar()
                (store.background, store.colour) = (background, .theme)
                let rep = try rendered(StripStyleTests.strip(store, sources, width: 1440, wallpaper: Self.strip(rgb)).style(instrument), wait: 0.8)
                timer.stop()
                let shown = TopBarLookTests.over(rep, tint: background == .glass ? Self.tint(instrument) : nil) { Self.fill($0, rgb) }
                // White glyphs on the toned ground: at least macOS's 1.84:1 on white, more elsewhere.
                let strongest = TopBarLookTests.strongest(shown, against: tone.ground)
                #expect(strongest >= 1.8, "\(background) over \(name): the strongest ink is \(strongest):1 on \(String(format: "%06X", tone.ground))")
            }
        }
        #expect(TopBarColour.tone(Self.strip(0xF4F4F4), background: .solid, colour: .theme, style: instrument, look: look) == nil)
    }

    @Test("Renders: the user's bar and readings at their levels over a busy pink and light wallpaper, before and after, Glass and Clear, Instrument and Toybox",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renders() async throws {
        let dir = try ClockRenders.dir("wallpaper-ink")
        let void = try #require(PilotTheme.named("void"))
        // A 3440 x 1440 screen under a 30-point bar, as Sven's.
        let screen = CGSize(width: 3440, height: 1440), strip = 30.0
        let picture = try Self.picture()
        let grid = try #require(WallpaperStrip.grid(picture, screen: screen, strip: strip))
        let image = try #require(NSImage(contentsOf: picture))
        let shown = WallpaperStrip.rect(image: image.size, screen: screen, placement: .init())
        for kind in [PilotStyle.instrument, .toybox] {
            let style = StyleTokens.of(kind, theme: void)
            for background in [TopBarBackground.glass, .clear] {
                var rows: [NSBitmapImageRep] = []
                for after in [false, true] {
                    let wallpaper = after ? grid : nil
                    let (store, sources, timer) = try StripStyleTests.svensBar()
                    (store.background, store.colour) = (background, .theme)
                    let bar = try rendered(StripStyleTests.strip(store, sources, width: screen.width, wallpaper: wallpaper).style(style), wait: 0.8)
                    timer.stop()
                    let slot = try #require(store.settings.preview(.topBar).top?[.right]?.first)
                    let readings = TopBarStrip(sides: [.left: [slot]], background: background, colour: .theme, itemColours: true, wallpaper: wallpaper) { _ in
                        BarPartsView(items: ItemColoursRenders.parts + ItemColoursRenders.parts)
                    }
                    .frame(width: screen.width, height: strip).pilotTheme().style(style)
                    let tint = background == .glass ? Self.tint(style) : nil
                    let backdrop = { (size: NSSize) in
                        let k = size.width / screen.width
                        image.draw(in: NSRect(x: shown.minX * k, y: size.height - shown.maxY * k, width: shown.width * k, height: shown.height * k))
                    }
                    rows += [TopBarLookTests.over(bar, tint: tint, backdrop: backdrop), TopBarLookTests.over(try rendered(readings), tint: tint, backdrop: backdrop)]
                }
                let file = dir.appendingPathComponent("\(kind.rawValue)-\(background.rawValue).png")
                try #require(Self.stacked(rows).representation(using: .png, properties: [:])).write(to: file)
            }
        }
    }

    /// PILOT_RENDER_WALLPAPER's picture, else a made busy one: magenta, a cream streak, white, lilac and plum bands.
    static func picture() throws -> URL {
        if let given = env["PILOT_RENDER_WALLPAPER"] { return URL(fileURLWithPath: given) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-ink-busy.png")
        let size = NSSize(width: 1720, height: 720)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let bands: [UInt32] = [0xE053A3, 0xD84FA0, 0xEAC3CA, 0xFFF4E0, 0xF2E6EE, 0xCDC9DB, 0x6C4E6D, 0x40416C, 0xE65AAE, 0xFFFFFF, 0xF6D8E6, 0xA96196]
        let w = size.width / CGFloat(bands.count)
        for (i, c) in bands.enumerated() {
            NSColor(Color(hex: c)).setFill()
            NSBezierPath(rect: NSRect(x: CGFloat(i) * w - 20, y: 0, width: w + 40, height: size.height)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    /// The tint a Glass bar's window takes (TopBarWindows.applyLook).
    static func tint(_ style: StyleTokens) -> NSColor { TopBarColour.tint(.theme, style: style, look: .shared) }

    /// One colour over the whole backdrop.
    static func fill(_ size: NSSize, _ c: UInt32) {
        NSColor(Color(hex: c)).setFill()
        NSRect(origin: .zero, size: size).fill()
    }

    /// `rows` top to bottom, 8 px apart on grey.
    static func stacked(_ rows: [NSBitmapImageRep]) -> NSBitmapImageRep {
        let width = rows.map(\.pixelsWide).max() ?? 1, gap = 8, height = rows.map(\.pixelsHigh).reduce(0, +) + gap * (rows.count - 1)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var top = height
        for row in rows {
            top -= row.pixelsHigh
            row.draw(in: NSRect(x: 0, y: top, width: row.pixelsWide, height: row.pixelsHigh))
            top -= gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
}
}
#endif
