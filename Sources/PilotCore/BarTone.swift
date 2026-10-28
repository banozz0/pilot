import CoreGraphics
import Foundation

/// How the top bar stays legible over any wallpaper, as macOS 26's menu bar does (Sven, Q254, 2026-10-17). Measured on
/// Sven's Mac against the wallpaper files (2026-10-17, his gumball and Chrome and Roses): the menu bar draws no band, no
/// halo and no gradient. Its glyphs are one pure ink, and each pixel of the wallpaper behind them is toned by how it
/// stands against that ink: one already at about 3.5 : 1 to white shows as it is, a brighter one is pulled down along
/// a curve, white wallpaper to 1.84 : 1, so the wallpaper's own picture stays and only its light spots dim. Pilot reads
/// the picture's file (WallpaperStrip.Grid), so it tones each cell under its bar by the same curve, as a mask over the
/// bar's ground: black under white ink, white under dark (the mirror, for a light theme; macOS's Light Mode unmeasured).
public struct BarTone: Equatable, Sendable {
    /// The bar's ink: white or near-black (Contrast.readableInk's pair), the theme's side.
    public let ink: UInt32
    /// The mask's share over each cell, 0 to 255, row by row, top first, the grid's size.
    public let alpha: [UInt8]
    public let width, height: Int
    /// A typical toned ground (the median cell), what the bar's readings' colours are made to read on.
    public let ground: UInt32

    public static let white: UInt32 = 0xFFFFFF, dark: UInt32 = 0x1A1A1A

    /// Black under white ink, white under dark.
    public var maskColour: UInt32 { ink == Self.white ? 0x000000 : 0xFFFFFF }

    /// macOS's curve: a cell's contrast with the ink in, the contrast it is toned to out (measured, see above); at
    /// 3.5 : 1 and past it a cell is left alone.
    static let curve: [(in: Double, out: Double)] = [(1.0, 1.84), (1.08, 2.02), (1.2, 2.24), (1.28, 2.32), (1.44, 2.59), (1.57, 2.72),
                                                     (1.8, 2.96), (2.0, 3.13), (2.2, 3.28), (2.46, 3.44), (2.8, 3.5), (3.5, 3.5)]

    /// The contrast a cell standing at `contrast` with the ink is toned to.
    public static func toned(_ contrast: Double) -> Double {
        guard contrast < 3.5 else { return contrast }
        guard let i = curve.firstIndex(where: { $0.in >= contrast }), i > 0 else { return curve[0].out }
        let (a, b) = (curve[i - 1], curve[i])
        return a.out + (b.out - a.out) * (contrast - a.in) / (b.in - a.in)
    }

    /// The tone of `grid` for the theme's ink side (`prefersWhite`), seen through Glass's `tint` at `share` when given;
    /// nil for an empty grid.
    public static func make(_ grid: WallpaperStrip.Grid, prefersWhite: Bool, tint: [Double]? = nil, share: Double = 0) -> BarTone? {
        guard grid.width > 0, grid.height > 0 else { return nil }
        let ink = prefersWhite ? white : dark, inkL = Contrast.luminance(Contrast.rgb(ink))
        var alpha = [UInt8](repeating: 0, count: grid.width * grid.height), after = [Double](repeating: 0, count: alpha.count)
        for i in alpha.indices {
            var cell = [Double(grid.rgb[i * 3]), Double(grid.rgb[i * 3 + 1]), Double(grid.rgb[i * 3 + 2])]
            if let tint { cell = Contrast.mix(tint, cell, share) }
            let l = Contrast.luminance(cell)
            // The luminance the curve asks for, then the mask's share that gets there: sRGB scales by (1 - a) under
            // black, so luminance by about its 2.2 power; under white, about the same in lightness.
            if prefersWhite {
                let want = 1.05 / toned(1.05 / (l + 0.05)) - 0.05
                let a = want < l ? 1 - pow(max(want, 0) / l, 1 / 2.2) : 0
                (alpha[i], after[i]) = (UInt8((a * 255).rounded()), min(l, want))
            } else {
                let want = toned((l + 0.05) / (inkL + 0.05)) * (inkL + 0.05) - 0.05
                let v = pow(l, 1 / 2.2), w = pow(min(want, 1), 1 / 2.2)
                let a = want > l && v < 1 ? (w - v) / (1 - v) : 0
                (alpha[i], after[i]) = (UInt8((a * 255).rounded()), max(l, want))
            }
        }
        // The median toned cell, as a grey of that luminance.
        let median = after.sorted()[after.count / 2], grey = pow(median, 1 / 2.2) * 255
        return BarTone(ink: ink, alpha: alpha, width: grid.width, height: grid.height, ground: Contrast.hex([grey, grey, grey]))
    }

    public init(ink: UInt32, alpha: [UInt8], width: Int, height: Int, ground: UInt32) {
        self.ink = ink; self.alpha = alpha; self.width = width; self.height = height; self.ground = ground
    }
}

extension Contrast {
    /// `colour` reading on `ground` at `floor`: its lightness moved away from the ground's in 2 % steps, hue and
    /// saturation kept, so a bar's amber, red and green stay apart on a light or a dark wallpaper. `lighter` says which
    /// way, the bar's ink's side; else whichever ink reads on the ground.
    public static func legible(_ colour: UInt32, on ground: UInt32, floor: Double = 3, lighter given: Bool? = nil) -> UInt32 {
        guard ratio(colour, ground) < floor else { return colour }
        let (h, s, l) = hsl(colour), lighter = given ?? (readableInk(on: ground) == 0xFFFFFF)
        var lightness = l, out = colour
        while ratio(out, ground) < floor, lighter ? lightness < 1 : lightness > 0 {
            lightness = max(0, min(1, lightness + (lighter ? 0.02 : -0.02)))
            out = rgb(h: h, s: s, l: lightness)
        }
        return out
    }

    /// 0xRRGGBB from hue in degrees, saturation and lightness from 0 to 1 (hsl's inverse).
    public static func rgb(h: Double, s: Double, l: Double) -> UInt32 {
        let c = (1 - abs(2 * l - 1)) * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let (r, g, b): (Double, Double, Double) = switch h {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        return hex([r, g, b].map { ($0 + m) * 255 })
    }
}

/// The wallpaper under a screen's bar, read from the picture's file (never the screen: no Screen Recording, ADR 0012),
/// placed as macOS places it, so the bar reads what it stands on. Read off the main thread, on a wallpaper, screen or
/// Space change, never per frame.
public enum WallpaperStrip {
    /// How the picture fills its screen: NSWorkspace's desktop image options, NSImageScaling's raw values.
    public struct Placement: Equatable, Sendable {
        public var scaling: Int
        public var clips: Bool
        /// What shows where the picture does not reach (0 to 255).
        public var fill: [Double]
        public init(scaling: Int = 3, clips: Bool = true, fill: [Double] = [0, 0, 0]) {
            self.scaling = scaling; self.clips = clips; self.fill = fill
        }
    }

    /// The wallpaper under a bar, `width` by `height` cells (sRGB, 3 bytes each, row by row, top first).
    public struct Grid: Equatable, Sendable {
        public let width, height: Int
        public let rgb: [UInt8]
        public init(width: Int, height: Int, rgb: [UInt8]) { self.width = width; self.height = height; self.rgb = rgb }
    }

    /// Screen points per cell: half the menu bar's own detail, which the mask's smoothing (TopBarColour.toneGround) hides.
    public static let cell = 2.0

    /// The strip `strip` points high along the top of a `screen`-sized screen, a cell every `cell` points; nil when the
    /// picture cannot be read.
    public static func grid(_ url: URL, screen: CGSize, strip: Double, placement: Placement = .init()) -> Grid? {
        guard let read = WallpaperBrightness.rgba(url, maxSize: 2048, always: true) else { return nil }
        return grid(pixels: read.bytes, width: read.width, height: read.height, screen: screen, strip: strip, placement: placement)
    }

    /// The same from RGBA pixels, top row first: each cell the mean of the pixels under it, the fill colour where the
    /// picture does not reach.
    static func grid(pixels: [UInt8], width w: Int, height h: Int, screen: CGSize, strip: Double, placement: Placement) -> Grid {
        let shown = rect(image: CGSize(width: w, height: h), screen: screen, placement: placement)
        let (cw, ch) = (max(1, Int((screen.width / cell).rounded())), max(1, Int((strip / cell).rounded())))
        let (bw, bh) = (screen.width / Double(cw), strip / Double(ch)), sx = Double(w) / shown.width, sy = Double(h) / shown.height
        var rgb = [UInt8](repeating: 0, count: cw * ch * 3)
        for cy in 0..<ch { for cx in 0..<cw {
            let box = CGRect(x: Double(cx) * bw, y: Double(cy) * bh, width: bw, height: bh).intersection(shown)
            var mean = placement.fill
            if !box.isNull, box.width > 0, box.height > 0 {
                let x0 = max(0, Int((box.minX - shown.minX) * sx)), x1 = min(w, max(x0 + 1, Int(((box.maxX - shown.minX) * sx).rounded(.up))))
                let y0 = max(0, Int((box.minY - shown.minY) * sy)), y1 = min(h, max(y0 + 1, Int(((box.maxY - shown.minY) * sy).rounded(.up))))
                var sum = [0.0, 0, 0], n = 0.0
                for y in y0..<y1 { for x in x0..<x1 {
                    let p = (y * w + x) * 4
                    sum[0] += Double(pixels[p]); sum[1] += Double(pixels[p + 1]); sum[2] += Double(pixels[p + 2]); n += 1
                } }
                if n > 0 { mean = sum.map { $0 / n } }
            }
            let o = (cy * cw + cx) * 3
            (rgb[o], rgb[o + 1], rgb[o + 2]) = (UInt8(mean[0].rounded()), UInt8(mean[1].rounded()), UInt8(mean[2].rounded()))
        } }
        return Grid(width: cw, height: ch, rgb: rgb)
    }

    /// Where a picture of `image`'s size shows on a `screen`-sized screen, top-left origin: Fill Screen (scale up or
    /// down, clipped), Fit to Screen (not clipped), Stretch (axes independently), Centre (none), as System Settings
    /// offers them.
    public static func rect(image: CGSize, screen: CGSize, placement: Placement) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: screen) }
        let fit = min(screen.width / image.width, screen.height / image.height)
        let fill = max(screen.width / image.width, screen.height / image.height)
        let scale: Double
        switch placement.scaling {
        case 1: return CGRect(origin: .zero, size: screen)
        case 2: scale = 1
        case 0: scale = min(1, fit)
        default: scale = placement.clips ? fill : fit
        }
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2, width: size.width, height: size.height)
    }
}
