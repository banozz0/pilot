#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The top bar follows the Look and the bar style (Sven, 2026-10-10): Strip and Menu differ in Instrument too, the bar
/// stays solid under Look's Glass with its own Background and Colour deciding, its text reads on its colour, and the Menu
/// bar page opens on the bar it showed last. With PILOT_RENDER_DIR set the bar is written there in Light and Dark, Solid
/// and Glass, Theme and red, Strip and Menu, with Sven's other apps unfolded.
extension SharedLook {
@MainActor
@Suite("Top bar look", .serialized)
struct TopBarLookTests {
    /// Sven's menu bar apps as the drawer lists them, one item each.
    static func svensApps() -> MenuApps {
        let fake = MenuAppsTests.FakeExtras()
        let apps: [(String, String)] = [("Shottr", "cc.ffitch.shottr"), ("Tailscale", "io.tailscale.ipn.macsys"),
                                        ("Reminders MenuBar", "br.com.damascenorafael.reminders-menubar"), ("Wispr Flow", "com.electron.wispr-flow"),
                                        ("CodexBar", "com.steipete.codexbar"), ("Ghostex", "com.madda.ghostex.gpui"),
                                        ("Control Centre", "com.apple.controlcenter")]
        fake.apps = apps.enumerated().map { MenuExtrasApp(pid: pid_t(20 + $0.offset), name: $0.element.0, bundleId: $0.element.1) }
        fake.trees = Dictionary(uniqueKeysWithValues: fake.apps.map {
            ($0.pid, [MenuExtrasRaw(title: nil, description: $0.name, help: nil, handle: MenuItemHandle($0.name as NSString))])
        })
        return MenuAppsTests.make(fake)
    }

    /// Sven's bar in `style` on `background` in `colour`, each item's frame recorded, with Sven's other apps
    /// unfolded when given.
    static func bar(style: PilotStyle, background: TopBarBackground = .solid, colour: ColourChoice = .theme,
                    frames: StripStyleTests.Frames = .init(), apps: MenuApps? = nil) async throws -> (rep: NSBitmapImageRep, timer: ExtensionTimer) {
        let (store, sources, timer) = try StripStyleTests.svensBar(menuApps: apps ?? MenuApps())
        store.settings.set(.otherApps, on: apps != nil)
        (store.background, store.colour) = (background, colour)
        if let apps {
            await apps.refresh()
            if !apps.drawer.isOpen { apps.drawer.toggle() }
        }
        let view = StripStyleTests.strip(store, sources, width: 1440, frames: frames)
            .style(StyleTokens.of(style, theme: Look.shared.theme))
        return (try rendered(view, wait: 0.8), timer)
    }

    /// A red no theme has, for Custom.
    static let red: UInt32 = 0xC62828

    /// Items as Sven's bar showed them black on red (2026-10-11), pictured by a fake capture with the drawer open: a tile
    /// and its count, a cloud and the temperature, a ghost with eyes and its count, a wheel, each in a black with the
    /// wallpaper's red in it and the readings a lighter grey; then a white item from a dark menu bar and a coloured logo.
    static func capturedApps() async -> MenuApps {
        let fake = MenuAppsTests.FakeExtras()
        fake.apps = ["Tile", "Weather", "Ghost", "Wheel", "Dark", "Logo"].enumerated().map { MenuExtrasApp(pid: pid_t(40 + $0.offset), name: $0.element, bundleId: nil) }
        fake.trees = Dictionary(uniqueKeysWithValues: fake.apps.enumerated().map { i, app in
            (app.pid, [MenuExtrasRaw(title: nil, description: app.name, help: nil, handle: MenuItemHandle(app.name as NSString),
                                     frame: CGRect(x: 1000 + 40 * i, y: 0, width: 36, height: 30))])
        })
        let context = CGContext(data: nil, width: 520, height: 60, bitsPerComponent: 8, bytesPerRow: 520 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let black = CGColor(red: 0.18, green: 0.04, blue: 0.04, alpha: 1), grey = CGColor(gray: 0.45, alpha: 1)
        func at(_ i: Int, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: CGFloat(80 * i) + x, y: y, width: w, height: h) }
        func fill(_ colour: CGColor, _ rect: CGRect, round: Bool = false) {
            context.setFillColor(colour)
            if round { context.fillEllipse(in: rect) } else { context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)); context.fillPath() }
        }
        fill(black, at(0, 6, 16, 28, 28)); fill(grey, at(0, 42, 18, 14, 24))
        fill(black, at(1, 4, 16, 32, 20), round: true); fill(grey, at(1, 42, 18, 28, 24))
        fill(black, at(2, 6, 14, 28, 32), round: true); fill(CGColor(gray: 0.95, alpha: 1), at(2, 12, 30, 6, 6), round: true)
        fill(CGColor(gray: 0.95, alpha: 1), at(2, 22, 30, 6, 6), round: true); fill(grey, at(2, 42, 18, 14, 24))
        context.setStrokeColor(black); context.setLineWidth(5); context.strokeEllipse(in: at(3, 10, 14, 32, 32))
        fill(CGColor(gray: 1, alpha: 1), at(4, 10, 14, 32, 32), round: true)
        fill(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1), at(5, 10, 14, 32, 32), round: true)
        let capture = MenuItemPicturesTests.FakeCapture()
        capture.bars = [CapturedBar(frame: CGRect(x: 1000, y: 0, width: 260, height: 30), image: context.makeImage()!)]
        let apps = MenuApps(reader: fake, ownPid: 13, pictures: MenuItemPictures(capturer: capture, ownPid: 13, isOn: { true }))
        apps.drawer.toggle()
        await apps.refresh()
        return apps
    }

    @Test("Other apps' pictured items draw in the bar's ink on a red Solid bar: no grey item stays black, the coloured logo keeps its orange (Sven, 2026-10-11)")
    func picturedItemsTakeTheInk() async throws {
        let look = Look.shared, saved = (look.theme.id, look.glass)
        defer { look.preview(saved.0); look.glass = saved.1 }
        look.glass = false
        // The light bar only for the render.
        let rendering = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] != nil
        for (themeName, theme, colourName, colour) in [("dark", "lagoon", "red", ColourChoice.custom(Self.red)), ("light", "porcelain", "theme", .theme)]
            where colourName == "red" || rendering {
            look.preview(theme)
            let apps = await Self.capturedApps()
            #expect(apps.list.allSatisfy { $0.items.allSatisfy { apps.pictures.picture($0) != nil } })
            let frames = StripStyleTests.Frames()
            let (rep, timer) = try await Self.bar(style: .instrument, background: .solid, colour: colour, frames: frames, apps: apps)
            timer.stop()
            try StripStyleTests.write(rep, "menu-item-ink/bar-\(themeName)-\(colourName)")
            guard colourName == "red" else { continue }
            // Only the drawer's items: Instrument's live workspace sets its number dark on the signal colour by design.
            let drawer = try #require(frames.placed["Other apps"])
            let scale = CGFloat(rep.pixelsWide) / 1440
            var dark = 0, orange = 0
            for y in 0..<rep.pixelsHigh {
                for x in Int(drawer.minX * scale)..<min(rep.pixelsWide, Int(drawer.maxX * scale)) {
                    let p = StripStyleTests.pixel(rep, x, y)
                    if p[0] < 70 && p[1] < 70 && p[2] < 70 { dark += 1 }
                    if p[0] > 220 && (100...160).contains(p[1]) && p[2] < 60 { orange += 1 }
                }
            }
            #expect(dark == 0, "\(dark) near-black pixels on the red bar")
            #expect(orange > 50, "the logo's orange: \(orange) pixels")
        }
    }

    @Test("In Instrument the Strip keeps the clock centred (Sven, 2026-10-10)")
    func instrumentCentresClock() async throws {
        let frames = StripStyleTests.Frames()
        let (_, timer) = try await Self.bar(style: .instrument, frames: frames)
        timer.stop()
        let clock = try #require(frames.placed["Clock"])
        #expect(abs(clock.midX - 720) < 120, "the clock at \(clock.midX) is not in the centre")
    }

    @Test("Under Look's Glass the bar stays solid by default, every pixel opaque, in Instrument; its own Glass clears the strip for the window's glass (Sven, 2026-10-10)")
    func solidUnderLooksGlass() async throws {
        let look = Look.shared, saved = look.glass
        defer { look.glass = saved }
        look.glass = true
        let style = PilotStyle.instrument
        for background in TopBarBackground.allCases {
            let (rep, timer) = try await Self.bar(style: style, background: background)
            timer.stop()
            let clear = StripStyleTests.resting(rep, bands: []).seeThrough, all = rep.pixelsWide * rep.pixelsHigh
            if background == .solid { #expect(clear == 0, "\(style) Solid under Look's Glass: \(clear) pixels see-through") } else { #expect(clear > all / 2, "\(style) \(background): \(clear) of \(all) pixels see-through") }
        }
    }

    @Test("The Strip's foot is one clean line on a solid bar and none on Glass, in Instrument (Sven, 2026-10-10: a double line under the bar)")
    func stripFoot() async throws {
        let style = PilotStyle.instrument
        for background in TopBarBackground.allCases {
            let (rep, timer) = try await Self.bar(style: style, background: background)
            timer.stop()
            let h = rep.pixelsHigh, ground = StripStyleTests.pixel(rep, rep.pixelsWide / 2, h - 5)
            // Every column's last point (two pixel rows at 2x) and the two points above it.
            var foot = Set<String>(), above = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                foot.insert(StripStyleTests.pixel(rep, x, h - 1).map(String.init).joined(separator: ","))
                foot.insert(StripStyleTests.pixel(rep, x, h - 2).map(String.init).joined(separator: ","))
                for y in (h - 6)...(h - 3) {
                    let p = StripStyleTests.pixel(rep, x, y)
                    if !StripStyleTests.near(p, ground) || p[3] != ground[3] { above += 1 }
                }
            }
            if background != .solid {
                // Clear's ground is 1% black, so a click lands on the bar: no line, nothing the eye sees.
                #expect(foot.allSatisfy { ($0.split(separator: ",").last.flatMap { Int($0) } ?? 255) <= 3 }, "\(style) \(background): the foot draws \(foot)")
            } else {
                #expect(foot.count == 1 && !StripStyleTests.near(StripStyleTests.pixel(rep, 3, h - 1), ground), "\(style) Solid: the foot is \(foot), not one line")
            }
            #expect(above == 0, "\(style) \(background): \(above) pixels off the ground just above the foot")
        }
    }

    @Test("A Clear bar shows no colour, so its text is the theme's own on any colour picked; its ground is all but nothing, yet not nothing (Sven on build 60)")
    func clearBar() async throws {
        let tokens = StyleTokens.of(.instrument, theme: try #require(PilotTheme.named("lagoon")))
        #expect(TopBarColour.tokens(.custom(0xFBFCFF), style: tokens, background: .clear) == tokens)
        #expect(TopBarColour.tokens(.custom(0xFBFCFF), style: tokens, background: .glass) == TopBarColour.tokens(.custom(0xFBFCFF), style: tokens))
        let (rep, timer) = try await Self.bar(style: .instrument, background: .clear, colour: .custom(Self.red))
        timer.stop()
        // A corner of the bar, past any item: no red, under 1% of black, but not wholly see-through (clicks land).
        let corner = StripStyleTests.pixel(rep, 2, rep.pixelsHigh / 2)
        #expect(corner[3] > 0 && corner[3] <= 3, "the Clear bar's ground is \(corner)")
    }

    @Test("Item colours starts on and is saved as it changes, read on the next start (Sven, Q251)")
    func itemColoursPersists() throws {
        let defaults = try MenuBarStatusItemsTests.defaults()
        let store = BarItemsStore(defaults: defaults) { [:] }
        #expect(store.itemColours)
        store.itemColours = false
        #expect(!BarItemsStore(defaults: defaults) { [:] }.itemColours)
    }

    @Test("The bar's Background and Colour start Solid and Theme, and are saved as they change and read on the next start")
    func backgroundPersists() throws {
        let defaults = try MenuBarStatusItemsTests.defaults()
        let store = BarItemsStore(defaults: defaults) { [:] }
        #expect(store.background == .solid)
        #expect(store.colour == .theme)
        (store.background, store.colour) = (.glass, .custom(Self.red))
        let again = BarItemsStore(defaults: defaults) { [:] }
        #expect(again.background == .glass)
        #expect(again.colour == .custom(Self.red))
        #expect(ColourChoice(rawValue: ColourChoice.custom(0x0A0B0C).rawValue) == .custom(0x0A0B0C))
        #expect(ColourChoice(rawValue: "theme") == .theme)
        #expect(ColourChoice(rawValue: "#12") == nil)
    }

    @Test("The bar's text keeps the theme's on the theme's colour, and on a picked one turns white or near-black, whichever reads better")
    func contrastRule() throws {
        for id in ["porcelain", "lagoon"] {
            let theme = try #require(PilotTheme.named(id))
            let style = PilotStyle.instrument
            let tokens = StyleTokens.of(style, theme: theme)
            // On the theme's own bar colour nothing changes.
            #expect(TopBarColour.tokens(.theme, style: tokens) == tokens, "\(id) \(style): inked on its own bar colour")
            for ground: UInt32 in [Self.red, 0xFFEB3B, 0xF5F5F5, 0x0D47A1, 0x111111, 0xFFFFFF] {
                let inked = tokens.colors.inked(on: ground), text = inked.text.rgb
                #expect(Contrast.ratio(inked.accentText.rgb, ground) >= 4.5, "\(id) \(style) accent words on #\(String(ground, radix: 16))")
                #expect(Contrast.ratio(text, ground) >= 4.5, "\(id) \(style) on #\(String(ground, radix: 16)): \(Contrast.ratio(text, ground))")
                // The Strip's glyphs (text3) as drawn over the ground stand 3:1 off it, a glyph's floor.
                let glyph = Contrast.mix(Contrast.rgb(inked.text3.rgb), Contrast.rgb(ground), inked.text3.alpha)
                #expect(Contrast.ratio(glyph, Contrast.rgb(ground)) >= 3, "\(id) \(style) glyphs on #\(String(ground, radix: 16)): \(Contrast.ratio(glyph, Contrast.rgb(ground)))")
            }
        }
        for ground: UInt32 in [Self.red, 0x808080, 0xFFEB3B, 0x0D47A1] {
            let ink = Contrast.readableInk(on: ground), other: UInt32 = ink == 0xFFFFFF ? 0x1A1A1A : 0xFFFFFF
            #expect(Contrast.ratio(ink, ground) >= Contrast.ratio(other, ground))
        }
    }

    @Test("On the solid bar the text and glyphs read: some pixel stands 4.5:1 off the ground, in Light and Dark, Theme and red, in Instrument")
    func solidBarReads() async throws {
        let look = Look.shared, saved = look.theme.id
        defer { look.preview(saved) }
        for theme in ["porcelain", "lagoon"] {
            look.preview(theme)
            let style = PilotStyle.instrument
            for colour in [ColourChoice.theme, .custom(Self.red)] {
                let (rep, timer) = try await Self.bar(style: style, colour: colour)
                timer.stop()
                let tokens = StyleTokens.of(style, theme: look.theme), ground = TopBarColour.ground(colour, style: tokens)
                #expect(StripStyleTests.near(StripStyleTests.pixel(rep, 1, 1), StripStyleTests.bytes(Color(Paint(ground))), 2), "\(theme) \(style) \(colour.rawValue): the bar is not its colour")
                let strongest = Self.strongest(rep, against: ground)
                #expect(strongest >= 4.5, "\(theme) \(style) \(colour.rawValue): the strongest ink is \(strongest):1")
            }
        }
    }

    /// The highest contrast any pixel of `rep` has with `ground`, up to 4.5:1: each colour once, every other pixel (the
    /// renders are at 2x).
    static func strongest(_ rep: NSBitmapImageRep, against ground: UInt32) -> Double {
        var seen = Set<UInt32>(), best = 1.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                let p = StripStyleTests.pixel(rep, x, y), rgb = UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2])
                guard seen.insert(rgb).inserted else { continue }
                best = max(best, Contrast.ratio(rgb, ground))
                if best >= 4.5 { return best }
            }
        }
        return best
    }

    @Test("The Menu bar page's Menu bar, Top bar or Both is saved as it changes and read on the next start (Sven, 2026-10-10)")
    func pagePlacementPersists() throws {
        let defaults = try MenuBarStatusItemsTests.defaults()
        let store = BarItemsStore(defaults: defaults) { [:] }
        #expect(store.pagePlacement == .menuBar)
        store.pagePlacement = .topBar
        #expect(BarItemsStore(defaults: defaults) { [:] }.pagePlacement == .topBar)
    }

    @Test("Renders: the user's bar with their other apps unfolded under Look's Glass, Solid and Glass, Theme and red, Light and Dark, in Instrument")
    func renders() async throws {
        guard ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] != nil else { return }
        let look = Look.shared, saved = (look.theme.id, look.glass)
        defer { look.preview(saved.0); look.glass = saved.1 }
        look.glass = true
        for (themeName, theme) in [("light", "porcelain"), ("dark", "lagoon")] {
            look.preview(theme)
            let style = PilotStyle.instrument
            for background in TopBarBackground.allCases {
                for (colourName, colour) in [("theme", ColourChoice.theme), ("red", .custom(Self.red))] {
                    let (rep, timer) = try await Self.bar(style: style, background: background, colour: colour, apps: Self.svensApps())
                    timer.stop()
                    let name = "topbar-look/\(style.rawValue)-\(themeName)-\(background.rawValue)-\(colourName)"
                    try StripStyleTests.write(background == .glass ? Self.overWallpaper(rep, style: style, colour: colour) : rep, name)
                }
            }
        }
    }

    /// A glass bar over a stand-in wallpaper under the tint the bar's window takes (TopBarWindows.applyLook): the glass's
    /// blur cannot draw offscreen, its tint and what shows through can.
    static func overWallpaper(_ rep: NSBitmapImageRep, style: PilotStyle, colour: ColourChoice) -> NSBitmapImageRep {
        let look = Look.shared
        let tint = TopBarColour.tint(colour, style: StyleTokens.of(style, theme: look.theme), look: look)
        return over(rep, tint: tint) { size in
            NSGradient(colors: [NSColor(red: 0.85, green: 0.25, blue: 0.6, alpha: 1), NSColor(red: 0.45, green: 0.2, blue: 0.75, alpha: 1)])!
                .draw(in: NSRect(origin: .zero, size: size), angle: 0)
        }
    }

    /// `rep` over what `backdrop` draws at its size, with the glass's `tint` between.
    static func over(_ rep: NSBitmapImageRep, tint: NSColor?, backdrop: (NSSize) -> Void) -> NSBitmapImageRep {
        let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        backdrop(size)
        if let tint {
            tint.setFill()
            NSRect(origin: .zero, size: size).fill(using: .sourceOver)
        }
        rep.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
}
}
#endif
