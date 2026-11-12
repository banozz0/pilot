#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The cursor-and-wallpaper design round (Sven's Q109 "One cursor you shape" and Q110 "a simpler version first",
/// 2026-11-12): Look's Cursor as one cursor with its own controls and a live preview, three ways (A, B, C), and the
/// Wallpaper blocks simpler, three ways, beside today's, each in Tokyo Night and Porcelain. The variants are mock views
/// built here from Pilot's own kit and its real cursor art (`CursorArt` from `Packaging/Cursors`, 5x atlas) and effect
/// painter; nothing is applied or registered, and only the macOS tile reads this Mac (its arrow, as today's block draws
/// it). Opt-in like the other renders:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> PILOT_RESOURCES=Packaging swift test --filter CursorWallpaperRoundRenders`
/// (PILOT_RESOURCES lets today's Cursor tiles find their art.)
extension SharedLook {
@MainActor
@Suite("Cursor and wallpaper round renders")
struct CursorWallpaperRoundRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let packs = root.appending(path: "Packaging/ThemePacks")

    @Test("Cursor and wallpaper variants beside today's, dark and light", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let (look, base) = try LookRenders.setUp()
        let dir = base.deletingLastPathComponent().appending(path: "cursor-wallpaper-round")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let art = try #require(RoundArt(folder: Self.root.appending(path: "Packaging/Cursors")))
        defer { LookRenders.resetShared() }
        func still(_ name: String) throws -> NSImage { try #require(WallpaperScreen.thumbnail(Self.packs.appending(path: name), size: 320)) }
        let stills = RoundStills(wide: [try still("tokyo-night/wallpapers/tokyo-night-wide.png"), try still("catppuccin/wallpapers/catppuccin-wide.png"),
                                        try still("gruvbox/wallpapers/gruvbox-wide.png"), try still("dracula/wallpapers/dracula-wide.png")],
                                 tall: [try still("akane/wallpapers/akane-tall.png"), try still("jade/wallpapers/jade-tall.png")])
        // Two made-up screens: a wide main one and a portrait one beside it.
        let screens = [
            WallpaperScreen(id: 1, name: "Studio Display", portrait: false, detail: "tokyo-night-wide.png · 3 of 24", thumb: stills.wide[0],
                            next: stills.wide[1], nextName: "catppuccin-wide", displayUUID: "ROUND-A"),
            WallpaperScreen(id: 2, name: "Side screen", portrait: true, detail: "akane-tall.png · 1 of 6", thumb: stills.tall[0],
                            next: stills.tall[1], nextName: "jade-tall", displayUUID: "ROUND-B"),
        ]
        let page = LookRenders.page(1000), narrow = LookRenders.page(AppWindowController.minSize.width)
        let m = RoundCursor()

        for theme in ["tokyo-night", "porcelain"] {
            look.style = .instrument; look.themeID = theme; LookRenders.mirror(look, spot: nil)
            func shot(_ view: some View, _ name: String, width: CGFloat, height: CGFloat? = nil) throws {
                let framed = RoundPage(width: width) { view }
                try writeRender(framed.styled(.page(.look), look: look).pilotTheme(look: look).background(Theme.background),
                                to: dir.appending(path: "\(name)-\(theme).png"), wait: 0.8)
            }
            // Today: the front as it is (cursor on Quiet in Custom's colours, trail and halos on), and Wallpaper's two parts.
            let cursors = CursorSets.of(look), effects = CursorEffects.of(look)
            cursors.set = .quiet; cursors.colours = .custom; cursors.fill = .custom(m.fill); cursors.outline = .custom(m.outline)
            effects.trail = .thread; effects.ring = true; effects.ripple = true; effects.spotlight = false; effects.colour = .theme
            let wallpaper = WallpaperSettings(defaults: try #require(UserDefaults(suiteName: testSuite())))
            wallpaper.interval = 60   // as every variant shows it
            try writeRender(LookPage(look: look, wallpaper: wallpaper, cursors: cursors, effects: effects, screens: screens)
                                .environment(\.lookPreviewStill, stills.wide[0]).styled(.page(.look), look: look)
                                .frame(width: page, height: 2700, alignment: .top).pilotTheme(look: look).background(Theme.background),
                            to: dir.appending(path: "today-front-\(theme).png"), wait: 0.8)
            try shot(WallpaperBlock(settings: wallpaper, screens: screens, count: 24, workspaces: ["1", "2", "3"], part: .front), "wallpaper-today-front", width: 290 + 2 * 24)
            try shot(WallpaperBlock(settings: wallpaper, screens: screens, count: 24, workspaces: ["1", "2", "3"], part: .more), "wallpaper-today-folders", width: page)

            // Cursor variants at the window's first size and its least.
            let effect = CursorEffectColours.of(theme, colour: m.effect)
            for (width, tag) in [(page, ""), (narrow, "-760")] {
                let wide = width == page
                try shot(CursorA(art: art, m: m, theme: theme, effect: effect, wide: wide), "cursor-A\(tag)", width: width)
                try shot(CursorB(art: art, m: m, theme: theme, effect: effect, wide: wide), "cursor-B\(tag)", width: width)
                try shot(CursorC(art: art, m: m, theme: theme, effect: effect, wide: wide), "cursor-C\(tag)", width: width)
            }
            // Wallpaper variants: the front column (290 pt beside the preview) and the folders block.
            for v in ["A", "B", "C"] {
                try shot(WallpaperFront(variant: v, screens: screens, stills: stills), "wallpaper-\(v)-front", width: 290 + 2 * 24)
                try shot(WallpaperFolders(variant: v, stills: stills), "wallpaper-\(v)-folders", width: page)
            }
        }
        print("cursor wallpaper round: \(dir.path)")
    }
}
}

// MARK: - The round's state and art

/// The one cursor every variant shows, so the variants differ by layout alone: Quiet's shape at 1.5×, a gold fill and a
/// violet outline (the designer's Sun pair), Thread trail, Ring and Ripple on, effects in the theme's colour.
struct RoundCursor {
    var shape = CursorSetID.quiet
    var size = 1.5
    var colours = CursorColours.custom
    var fill: UInt32 = 0xFFC933
    var outline: UInt32 = 0x6B2FA8
    var trail = CursorTrail.thread
    var ring = true, ripple = true, spotlight = false
    var effect = ColourChoice.theme
}

/// The wallpaper pictures the mocks show, from the theme packs.
struct RoundStills { let wide: [NSImage]; let tall: [NSImage] }

/// The cursor art at 5x, each cursor's first frame in a palette, and the live preview drawn from it.
@MainActor
final class RoundArt {
    let folder: URL
    let catalogue: CursorCatalogue
    private var sheets: [CursorSetID: CursorArt.Sheet] = [:]
    static let scale = 5

    init?(folder: URL) {
        guard let catalogue = CursorCatalogue.load(folder) else { return nil }
        (self.folder, self.catalogue) = (folder, catalogue)
    }

    func palette(_ set: CursorSetID, _ m: RoundCursor, theme: String, colours: CursorColours? = nil) -> [String: String] {
        catalogue.sets[set.rawValue]?.palette(colours ?? m.colours, theme: theme,
                                              custom: CursorCustom(set: set, fill: .custom(m.fill), outline: .custom(m.outline))) ?? [:]
    }

    /// `name`'s first frame of `set` at 5x (160 px for 32 pt) and its hotspot in points.
    func cursor(_ set: CursorSetID, _ name: String, palette: [String: String]) -> (image: CGImage, hotspot: CGPoint)? {
        if sheets[set] == nil { sheets[set] = CursorArt.sheet(folder, set: set.rawValue, scale: Self.scale) }
        guard let sheet = sheets[set], let c = catalogue.sets[set.rawValue]?.cursors[name],
              let image = CursorArt.image(sheet, colours: c.colours(palette), row: c.row, px: catalogue.canvasPoints * Self.scale) else { return nil }
        return (image, CGPoint(x: c.hotspot[0], y: c.hotspot[1]))
    }

    /// The preview: a light window and a dark one side by side, the arrow at `m.size` with its trail, ring and a ripple
    /// crossing both, and `others` along the foot. Drawn at 2x; `size` in points.
    func stage(_ m: RoundCursor, theme: String, effect: CursorEffectColours, size: CGSize, others: [String] = ["ibeam", "pointing-hand", "busy"], tall: Bool = false) -> CGImage? {
        let s: CGFloat = 2, (w, h) = (size.width, size.height)
        guard let ctx = CGContext(data: nil, width: Int(w * s), height: Int(h * s), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: s, y: s)
        ctx.interpolationQuality = .high
        // The light window (the designer's weak-pair ground) and a dark one.
        // Tall: light above, dark below; else light left, dark right.
        ctx.setFillColor(CursorArt.colour(0xEEF1F5)); ctx.fill(tall ? CGRect(x: 0, y: h / 2, width: w, height: h / 2) : CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CursorArt.colour(0x14161C)); ctx.fill(tall ? CGRect(x: 0, y: 0, width: w, height: h / 2) : CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        // The arrow sits just past the seam; its trail sweeps in from the light side (y up, as the painter draws).
        let pointer = tall ? CGPoint(x: w * 0.62, y: h * 0.47) : CGPoint(x: w * 0.58, y: h * 0.62)
        let start = tall ? CGPoint(x: w * 0.12, y: h * 0.80) : CGPoint(x: w * 0.14, y: pointer.y - 10)
        var state = CursorEffectState()
        state.trail = m.trail; state.ring = m.ring; state.ripple = m.ripple
        let n = 25, length = m.trail.length
        state.samples = (0..<n).map { i in
            let k = CGFloat(i) / CGFloat(n - 1)
            return .init(point: CGPoint(x: start.x + (pointer.x - start.x) * k, y: start.y + (pointer.y - start.y) * k + 14 * sin(k * .pi)), time: 1 - length * (1 - Double(k)))
        }
        state.pointer = pointer
        state.ringFade.go(1, 0, instant: true)
        // Each other cursor along the foot (tall: the dark half); the ripple spreads from the hand's click.
        let spots = others.indices.map { i in tall ? CGPoint(x: w * (0.18 + 0.30 * CGFloat(i)), y: h * 0.22)
                                                   : CGPoint(x: w * (0.12 + 0.27 * CGFloat(i)), y: h * 0.32) }
        if m.ripple, let hand = others.firstIndex(of: "pointing-hand") {
            state.ripples = [.init(point: spots[hand], time: 1 - 0.15, right: false)]
        }
        // The ring at the size proposed with Size: it grows with the cursor (today it stays 17 pt).
        CursorEffectPainter.draw(state, effect, now: 1, ring: false, in: ctx)
        if m.ring { CursorEffectPainter.ring(radius: CursorEffectPainter.ringRadius * m.size, level: 1, effect, at: pointer, in: ctx) }
        let palette = palette(m.shape, m, theme: theme)
        func put(_ name: String, at p: CGPoint) {
            guard let c = cursor(m.shape, name, palette: palette) else { return }
            let side = 32 * m.size
            // The hotspot is from the canvas's top left; the context counts up from the bottom.
            ctx.draw(c.image, in: CGRect(x: p.x - c.hotspot.x * m.size, y: p.y - side + c.hotspot.y * m.size, width: side, height: side))
        }
        put("arrow", at: pointer)
        for (i, name) in others.enumerated() { put(name, at: spots[i]) }
        return ctx.makeImage()
    }
}

// MARK: - Shared pieces

/// A variant on a page of `width`, inset as Look's page insets its blocks.
struct RoundPage<Content: View>: View {
    @Environment(\.ink) private var ink
    let width: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, ink.pageInset).padding(.vertical, 14)
            .frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row's label and its ⓘ.
struct RoundLabel: View {
    let title: String
    var info: String? = "x"
    var body: some View {
        HStack(spacing: 5) { Text(title).fixedSize(); if let info { InfoMark(text: info) } }
    }
}

/// A colour well with its title and hex, as Look's wells.
struct RoundWell: View {
    @Environment(\.ink) private var ink
    let title: String
    let rgb: UInt32
    var body: some View {
        HStack(spacing: 6) {
            if !title.isEmpty { Text(title).foregroundStyle(ink.text2).fixedSize() }
            ColorPicker(title, selection: .constant(Color(hex: rgb)), supportsOpacity: false).labelsHidden()
            Text(ColourAnswer.hex(rgb)).font(ink.mono(11.5)).foregroundStyle(ink.text2).fixedSize()
        }
    }
}

/// Fill against outline, with Q817's warning under 2:1.
struct RoundContrast: View {
    @Environment(\.ink) private var ink
    let m: RoundCursor
    var body: some View {
        let ratio = Contrast.ratio(m.fill, m.outline), weak = ratio < CursorCustom.weakRatio
        Text("Fill and outline \(String(format: "%.1f", ratio)):1 · " + (weak ? "under 2:1, the shape may not read on every window. Your colours stay." : "reads on light and dark windows."))
            .font(ink.ui(12)).foregroundStyle(weak ? ink.yellow : ink.muted).fixedSize(horizontal: false, vertical: true)
    }
}

/// The switch that replaces today's macOS tile and Restore: on, Pilot draws the cursor; off, macOS's comes back.
struct RoundPilotSwitch: View {
    @Environment(\.ink) private var ink
    var body: some View {
        HStack(spacing: 8) {
            Text("Pilot draws it").font(ink.ui(12)).foregroundStyle(ink.text2)
            Toggle("Pilot draws the cursor", isOn: .constant(true)).toggleStyle(.pilotSwitch).labelsHidden()
        }
    }
}

struct RoundSwitchRow: View {
    let title: String
    let on: Bool
    var first = false
    var body: some View {
        BlockRow(first: first) {
            RoundLabel(title: title).frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: .constant(on)).toggleStyle(.pilotSwitch).labelsHidden()
        }
    }
}

extension CursorSetID {
    static let shapes: [CursorSetID] = [.quiet, .toybox, .duo, .classic]
}

// MARK: - Cursor A: the preview beside the controls

/// A · Stage and inspector: the preview as a square stage on the left, every control a row on the right.
struct CursorA: View {
    @Environment(\.ink) private var ink
    let art: RoundArt
    let m: RoundCursor
    let theme: String
    let effect: CursorEffectColours
    let wide: Bool

    var body: some View {
        KitBlock(title: "Cursor", symbol: "cursorarrow", note: nil) { RoundPilotSwitch() } content: {
            Group {
                if wide { HStack(alignment: .top, spacing: 18) { stage(250); controls } }
                else { VStack(alignment: .leading, spacing: 10) { stage(nil); controls } }
            }
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder private func stage(_ width: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let width {
                if let image = art.stage(m, theme: theme, effect: effect, size: CGSize(width: width, height: 330), tall: true) { framed(image) }
            } else {
                GeometryReader { g in
                    if let image = art.stage(m, theme: theme, effect: effect, size: CGSize(width: g.size.width, height: 150)) { framed(image) }
                }
                .frame(height: 150)
            }
            Text("Quiet at 1.5×, your colours, on a light and a dark window.").font(ink.ui(12)).foregroundStyle(ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width)
    }

    private func framed(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 2).clipShape(.rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ink.line) }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            BlockRow(first: true) {
                RoundLabel(title: "Shape"); Spacer()
                Segments(selection: .constant(m.shape), options: CursorSetID.shapes.map { ($0, $0.title) }, label: "Shape")
            }
            BlockRow {
                RoundLabel(title: "Size"); Spacer()
                Segments(selection: .constant(m.size), options: [(1.0, "1×"), (1.5, "1.5×"), (2.0, "2×"), (3.0, "3×")], label: "Size")
            }
            BlockRow {
                RoundLabel(title: "Colours"); Spacer()
                Segments(selection: .constant(m.colours), options: [(.theme, "Theme"), (.own, "Shape's own"), (.custom, "Custom")], label: "Colours")
            }
            BlockRow {
                Spacer()
                RoundWell(title: "Fill", rgb: m.fill); RoundWell(title: "Outline", rgb: m.outline)
                Button {} label: { Image(systemName: "arrow.left.arrow.right") }.buttonStyle(.pilot).accessibilityLabel("Swap fill and outline")
            }
            RoundContrast(m: m).frame(maxWidth: .infinity, alignment: .trailing).padding(.bottom, 8)
            BlockRow {
                RoundLabel(title: "Trail"); Spacer()
                Segments(selection: .constant(m.trail), options: CursorTrail.allCases.map { ($0, $0.title) }, label: "Trail")
            }
            BlockRow {
                RoundLabel(title: "Effect colour"); Spacer()
                ColourChoicePicker(choice: .constant(m.effect), theme: effect.effectRGB, label: "Effect colour")
            }
            RoundSwitchRow(title: "Ring", on: m.ring)
            RoundSwitchRow(title: "Ripple", on: m.ripple)
            RoundSwitchRow(title: "Spotlight", on: m.spotlight)
        }
    }
}

// MARK: - Cursor B: a preview strip, then four rows

/// B · Strip and four rows: the preview full width on top; Shape as small pictures; Size; Colours with the wells on
/// the same row; Effects folding Trail, the halos and their colour into one row.
struct CursorB: View {
    @Environment(\.ink) private var ink
    let art: RoundArt
    let m: RoundCursor
    let theme: String
    let effect: CursorEffectColours
    let wide: Bool

    var body: some View {
        KitBlock(title: "Cursor", symbol: "cursorarrow") { RoundPilotSwitch() } content: {
            GeometryReader { g in
                if let image = art.stage(m, theme: theme, effect: effect, size: CGSize(width: g.size.width, height: 132)) {
                    Image(decorative: image, scale: 2).clipShape(.rect(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ink.line) }
                }
            }
            .frame(height: 132).padding(.top, 10).padding(.bottom, 12)
            BlockRow(first: true) {
                RoundLabel(title: "Shape"); Spacer()
                HStack(spacing: 6) { ForEach(CursorSetID.shapes, id: \.self) { tile($0) } }
            }
            BlockRow {
                RoundLabel(title: "Size"); Spacer()
                Segments(selection: .constant(m.size), options: [(1.0, "Small"), (1.5, "Medium"), (2.0, "Large"), (3.0, "Huge")], label: "Size")
            }
            BlockRow {
                RoundLabel(title: "Colours"); Spacer()
                Segments(selection: .constant(m.colours), options: [(.theme, "Theme"), (.custom, "Custom")], label: "Colours")
                if wide { RoundWell(title: "", rgb: m.fill); RoundWell(title: "", rgb: m.outline) }
            }
            if !wide { BlockRow { Spacer(); RoundWell(title: "Fill", rgb: m.fill); RoundWell(title: "Outline", rgb: m.outline) } }
            RoundContrast(m: m).frame(maxWidth: .infinity, alignment: .trailing).padding(.bottom, 8)
            BlockRow {
                RoundLabel(title: "Effects"); Spacer()
                Segments(selection: .constant(m.trail), options: CursorTrail.allCases.map { ($0, $0 == .off ? "No trail" : $0.title) }, label: "Trail")
            }
            BlockRow {
                Text("Halos").font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize()
                Chip(text: "Ring", on: m.ring); Chip(text: "Ripple", on: m.ripple); Chip(text: "Spotlight", on: m.spotlight)
                Spacer()
                ColourChoicePicker(choice: .constant(m.effect), theme: effect.effectRGB, label: "Effect colour")
            }
        }
    }

    /// One shape in the colours picked, the picked one ringed in the accent.
    private func tile(_ set: CursorSetID) -> some View {
        let picked = set == m.shape
        let palette = art.palette(set, m, theme: theme)
        return VStack(spacing: 3) {
            if let c = art.cursor(set, "arrow", palette: palette) {
                Image(decorative: c.image, scale: 5).resizable().interpolation(set == .classic ? .none : .high).frame(width: 26, height: 26)
            }
            Text(set.title).font(ink.ui(11)).foregroundStyle(picked ? ink.text : ink.text2)
        }
        .frame(width: 62, height: 50)
        .background(RoundedRectangle(cornerRadius: 8).fill(ink.raised))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(picked ? ink.accent : ink.line, lineWidth: picked ? 2 : 1))
    }
}

// MARK: - Cursor C: start from a design, shape it, effects on their own

/// C · Start from, then shape: the four designs (and macOS) as starting points that set the shape and its own colours;
/// under them the cursor you shape from there, a small preview beside Shape, Size and the wells; the trail and halos
/// in a block of their own, More's Cursor effects.
struct CursorC: View {
    @Environment(\.ink) private var ink
    let art: RoundArt
    let m: RoundCursor
    let theme: String
    let effect: CursorEffectColours
    let wide: Bool

    var body: some View {
        KitBlock(title: "Cursor", symbol: "cursorarrow") {
            Button("Restore macOS's") {}.buttonStyle(.pilot)
        } content: {
            BlockRow(first: true) {
                if wide { RoundLabel(title: "Start from"); Spacer() }
                HStack(spacing: 6) {
                    macTile
                    ForEach(CursorSetID.shapes, id: \.self) { preset($0) }
                }
            }
            .padding(.vertical, wide ? 0 : 8)
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 14)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            layout {
                if let image = art.stage(m, theme: theme, effect: effect, size: CGSize(width: wide ? 200 : 460, height: 150), others: ["ibeam", "pointing-hand"]) {
                    Image(decorative: image, scale: 2).clipShape(.rect(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ink.line) }
                }
                VStack(spacing: 0) {
                    BlockRow(first: true) {
                        RoundLabel(title: "Shape"); Spacer()
                        Segments(selection: .constant(m.shape), options: CursorSetID.shapes.map { ($0, $0.title) }, label: "Shape")
                    }
                    BlockRow {
                        RoundLabel(title: "Size"); Spacer()
                        Segments(selection: .constant(m.size), options: [(1.0, "1×"), (1.5, "1.5×"), (2.0, "2×")], label: "Size")
                    }
                    BlockRow {
                        RoundLabel(title: "Colours"); Spacer()
                        RoundWell(title: "Fill", rgb: m.fill); RoundWell(title: "Outline", rgb: m.outline)
                    }
                    Text("From Quiet: size and colours changed. Start from Quiet again to undo.")
                        .font(ink.ui(12)).foregroundStyle(ink.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
            }
            .padding(.vertical, 10)
            .overlay(alignment: .top) { InstrumentRule() }
        }
        KitBlock(title: "Cursor effects", symbol: "sparkles", note: "The trail and halos, on Look's More tab.") {
            BlockRow(first: true) {
                RoundLabel(title: "Trail"); Spacer()
                Segments(selection: .constant(m.trail), options: CursorTrail.allCases.map { ($0, $0.title) }, label: "Trail")
            }
            BlockRow {
                RoundLabel(title: "Effect colour"); Spacer()
                ColourChoicePicker(choice: .constant(m.effect), theme: effect.effectRGB, label: "Effect colour")
            }
            RoundSwitchRow(title: "Ring", on: m.ring)
            RoundSwitchRow(title: "Ripple", on: m.ripple)
            RoundSwitchRow(title: "Spotlight", on: m.spotlight)
        }
    }

    private var macTile: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSCursor.arrow.image).resizable().scaledToFit().frame(width: 26, height: 26)
            Text("macOS").font(ink.ui(11)).foregroundStyle(ink.text2)
        }
        .frame(width: 58, height: 50)
        .background(RoundedRectangle(cornerRadius: 8).fill(ink.raised))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ink.line))
    }

    /// A design in its own colours; the one the cursor started from is ringed.
    private func preset(_ set: CursorSetID) -> some View {
        let from = set == m.shape
        let palette = art.palette(set, m, theme: theme, colours: .own)
        return VStack(spacing: 3) {
            if let c = art.cursor(set, "arrow", palette: palette) {
                Image(decorative: c.image, scale: 5).resizable().interpolation(set == .classic ? .none : .high).frame(width: 26, height: 26)
            }
            Text(set.title).font(ink.ui(11)).foregroundStyle(from ? ink.text : ink.text2)
        }
        .frame(width: 58, height: 50)
        .background(RoundedRectangle(cornerRadius: 8).fill(ink.raised))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(from ? ink.accent : ink.line, lineWidth: from ? 2 : 1))
    }
}

// MARK: - Wallpaper

/// Wallpaper's front, in the 290 pt column beside Look's preview. A and C keep today's rows; B makes one Next for the Mac.
struct WallpaperFront: View {
    @Environment(\.ink) private var ink
    let variant: String
    let screens: [WallpaperScreen]
    let stills: RoundStills

    var body: some View {
        KitBlock(title: "Wallpaper", symbol: "photo.on.rectangle") {
            if variant == "B" {
                BlockRow(first: true) {
                    HStack(spacing: 4) {
                        thumb(stills.wide[1], portrait: false)
                        thumb(stills.tall[1], portrait: true)
                    }
                    .opacity(0.55)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Next on both screens").lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text("3 of 24 · shuffled").font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                BlockRow { Spacer(); buttons }
            } else {
                ForEach(Array(screens.enumerated()), id: \.element.id) { i, screen in
                    BlockRow(first: i == 0) {
                        if let next = screen.next { thumb(next, portrait: screen.portrait).opacity(0.45) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(screen.name).lineLimit(1)
                            Text(screen.detail).font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        buttons
                    }
                }
            }
            BlockRow {
                RoundLabel(title: "On its own").frame(maxWidth: .infinity, alignment: .leading)
                Picker("On its own", selection: .constant(60)) { ForEach(WallpaperCycle.intervals, id: \.self) { Text(WallpaperCycle.intervalName($0)).tag($0) } }
                    .labelsHidden().fixedSize()
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button {} label: { Image(systemName: "chevron.left") }.buttonStyle(.pilot)
        Button {} label: { Text("Next") }.buttonStyle(.pilot)
    }

    private func thumb(_ image: NSImage, portrait: Bool) -> some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            .frame(width: portrait ? 30 : 72, height: 44).clipShape(.rect(cornerRadius: ink.radius(4)))
            .overlay { RoundedRectangle(cornerRadius: ink.radius(4)).strokeBorder(ink.text.opacity(0.12)) }
    }
}

/// Wallpaper's folders block, three ways.
struct WallpaperFolders: View {
    @Environment(\.ink) private var ink
    let variant: String
    let stills: RoundStills

    var body: some View {
        switch variant {
        case "A": a
        case "B": b
        default: c
        }
    }

    // A · Same blocks, fewer rows: Images from, Own folders for, Shuffle, Next changes.
    private var a: some View {
        KitBlock(title: "Wallpaper folders", symbol: "photo.on.rectangle", note: "What Next wallpaper and Previous step through.") {
            BindKey(action: "system.nextWallpaper")
        } content: {
            BlockRow(first: true) { sources }
            BlockRow {
                RoundLabel(title: "Own folders for").frame(maxWidth: .infinity, alignment: .leading)
                Segments(selection: .constant("none"), options: [("none", "Nothing"), ("screen", "Each screen"), ("workspace", "Each workspace")], label: "Own folders for")
            }
            BlockRow {
                RoundLabel(title: "Shuffle").frame(maxWidth: .infinity, alignment: .leading)
                Button("Shuffle again") {}.buttonStyle(.pilot)
                Toggle("Shuffle", isOn: .constant(true)).toggleStyle(.pilotSwitch).labelsHidden()
            }
            BlockRow {
                RoundLabel(title: "Next changes").frame(maxWidth: .infinity, alignment: .leading)
                Segments(selection: .constant("front"), options: [("front", "Screen in front"), ("every", "Every screen")], label: "Next changes")
            }
        }
    }

    // B · Switches only: Images from, then each exception a switch.
    private var b: some View {
        KitBlock(title: "Wallpaper folders", symbol: "photo.on.rectangle", note: "What Next wallpaper and Previous step through.") {
            BindKey(action: "system.nextWallpaper")
        } content: {
            BlockRow(first: true) { sources }
            RoundSwitchRow(title: "Each screen its own folders", on: false)
            RoundSwitchRow(title: "Each workspace its own folders", on: false)
            RoundSwitchRow(title: "Shuffle", on: true)
        }
    }

    // C · Each folder says where it shows: a row per folder with its pictures, its count and a Shows on menu.
    private var c: some View {
        KitBlock(title: "Wallpaper folders", symbol: "photo.on.rectangle", note: "What Next wallpaper and Previous step through.") {
            HStack(spacing: 8) {
                Button("Browse as gallery") {}.buttonStyle(.pilot)
                Button("Add…") {}.buttonStyle(.pilot)
                BindKey(action: "system.nextWallpaper")
            }
        } content: {
            folder("~/Pictures/Wallpapers", "18 images", [stills.wide[0], stills.wide[2], stills.wide[3]], shows: "Every screen", first: true)
            folder("~/Pictures/Tokyo night", "4 images", [stills.wide[0], stills.wide[1]], shows: "Workspace 2")
            folder("~/Pictures/Tall", "6 images", [stills.tall[0], stills.tall[1]], shows: "Side screen")
            RoundSwitchRow(title: "Shuffle", on: true)
        }
    }

    private func folder(_ path: String, _ count: String, _ pictures: [NSImage], shows: String, first: Bool = false) -> some View {
        BlockRow(first: first) {
            HStack(spacing: -14) {
                ForEach(Array(pictures.enumerated()), id: \.offset) { _, p in
                    Image(nsImage: p).resizable().aspectRatio(contentMode: .fill).frame(width: 40, height: 28)
                        .clipShape(.rect(cornerRadius: ink.radius(4)))
                        .overlay { RoundedRectangle(cornerRadius: ink.radius(4)).strokeBorder(ink.raised, lineWidth: 1.5) }
                }
            }
            .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(path).lineLimit(1)
                Text(count).font(ink.ui(12)).foregroundStyle(ink.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Shows on").font(ink.ui(12)).foregroundStyle(ink.muted)
            Picker("Shows on", selection: .constant(shows)) {
                ForEach(["Every screen", "Studio Display", "Side screen", "Workspace 1", "Workspace 2", "Workspace 3"], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
            Button {} label: { Image(systemName: "xmark") }.buttonStyle(.pilotSoft).accessibilityLabel("Remove \(path)")
        }
        .padding(.vertical, 4)
    }

    /// Images from: the folders as chips, their count, Gallery and Add.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoundLabel(title: "Images from").frame(maxWidth: .infinity, alignment: .leading)
                Text("24 images").font(ink.ui(12)).foregroundStyle(ink.muted)
                Button("Browse as gallery") {}.buttonStyle(.pilot)
                Button("Add…") {}.buttonStyle(.pilot)
            }
            HStack(spacing: 6) {
                Chip(text: "~/Pictures/Wallpapers", symbol: "folder", tag: true) {}
                Chip(text: "~/Pictures/Tokyo night", symbol: "folder", tag: true) {}
            }
        }
        .padding(.vertical, 8)
    }
}
#endif
