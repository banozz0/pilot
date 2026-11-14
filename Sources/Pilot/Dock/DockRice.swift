import AppKit
import CoreImage
import PilotCore

/// The dock's rice look (Sven 2026-11-13, Q220 A over B and C, Q221, Q222; `~/pages/pilot-dock-rice.html`): icons
/// recoloured from the theme, and a spectrum along the screen's foot out from the pill to both edges.

/// Recolours an icon from the theme through Core Image: greyscale (CIColorControls); a light tile turned dark
/// (CIColorInvert) so every tile reads one way, as the reference's; the tile's grey stretched to the end (CIColorMatrix);
/// then the tile to `tile` and the glyph to `glyph` (CIFalseColor), the icon's own alpha kept (CIBlendWithAlphaMask).
/// One image per icon, colour pair and size, cached; a theme change makes new pairs, so the icons follow it. Measured on
/// an M4: 2.7 ms an icon, 33 ms once for the context (round 1's prototype).
@MainActor
enum DockTinter {
    static let context = CIContext(options: [.cacheIntermediates: false])
    /// One theme's icons at one size, and room for a theme change's while the old ones age out.
    private static let made: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 96
        return cache
    }()

    /// The theme's pair: the tile from the accent sunk into the ground, the glyph from the accent lifted toward the ink.
    /// A dark theme reads dark tiles and light glyphs, a light theme the other way round.
    static func ends(_ theme: PilotTheme) -> (tile: UInt32, glyph: UInt32) {
        (mix(theme.accent, theme.ground, 0.72), mix(theme.accent, theme.text, 0.3))
    }

    nonisolated static func rgb(_ hex: UInt32) -> [Double] { [Double(hex >> 16 & 0xFF), Double(hex >> 8 & 0xFF), Double(hex & 0xFF)] }

    nonisolated static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let x = rgb(a), y = rgb(b)
        let c = zip(x, y).map { UInt32(($0 * (1 - t) + $1 * t).rounded()) }
        return c[0] << 16 | c[1] << 8 | c[2]
    }

    static func ci(_ hex: UInt32) -> CIColor {
        let c = rgb(hex)
        return CIColor(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255)
    }

    /// `image` at `points` (drawn at 2x) in the pair `ends`; the image itself when Core Image cannot draw it.
    static func tinted(_ image: NSImage, key: String, ends: (tile: UInt32, glyph: UInt32), points: CGFloat) -> NSImage {
        let id = "\(key)|\(ends.tile)|\(ends.glyph)|\(Int(points))" as NSString
        if let hit = made.object(forKey: id) { return hit }
        let out = render(image, ends: ends, points: points) ?? image
        made.setObject(out, forKey: id)
        return out
    }

    /// The tile's luminance, 0 to 1: two patches inside its left and right edges, where most macOS tiles show their ground.
    static func luminance(_ source: CIImage) -> Double {
        let e = source.extent
        let patches = [CGRect(x: e.width * 0.13, y: e.height * 0.42, width: e.width * 0.05, height: e.height * 0.16),
                       CGRect(x: e.width * 0.82, y: e.height * 0.42, width: e.width * 0.05, height: e.height * 0.16)]
        var sum = 0.0, n = 0.0
        for patch in patches {
            let mean = source.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: patch)])
            var px = [Float](repeating: 0, count: 4)
            context.render(mean, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            guard px[3] > 0.05 else { continue }
            sum += Double((0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]) / px[3])
            n += 1
        }
        return n > 0 ? sum / n : 0
    }

    static func render(_ image: NSImage, ends: (tile: UInt32, glyph: UInt32), points: CGFloat) -> NSImage? {
        var rect = CGRect(x: 0, y: 0, width: points * 2, height: points * 2)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let source = CIImage(cgImage: cg)
        let lum = luminance(source)
        var grey = source.composited(over: CIImage(color: .black).cropped(to: source.extent))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.1])
        if lum > 0.5 { grey = grey.applyingFilter("CIColorInvert") }
        let tile = min(0.8, lum > 0.5 ? 1 - lum : lum), s = 1 / (1 - tile)
        let stretched = grey.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0), "inputBiasVector": CIVector(x: -tile * s, y: -tile * s, z: -tile * s, w: 0),
        ]).applyingFilter("CIColorClamp")
        let toned = stretched.applyingFilter("CIFalseColor", parameters: ["inputColor0": ci(ends.tile), "inputColor1": ci(ends.glyph)])
        let kept = toned.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: source])
        guard let done = context.createCGImage(kept, from: source.extent) else { return nil }
        return NSImage(cgImage: done, size: NSSize(width: points, height: points))
    }
}

/// The visualizer's bars as one path (look A): out from the pill's two ends to the screen's edges, 3 pt wide with 2 pt
/// gaps, flat tops, the bass nearest the pill and the highs at the edges, the left channel on the left. Silent (no
/// levels) a 2 pt line along the edge. y 0 is the screen's foot. CAShapeLayer fills it in the window (DockBarsWindow); a
/// render fills the same path.
enum DockBarsPath {
    static let bar: CGFloat = 3, gap: CGFloat = 2
    /// Room left between the pill's end and the first bar.
    static let clear: CGFloat = 8
    /// The silent line's height, and the least a playing bar shows.
    static let flat: CGFloat = 2

    /// Bars on each side for a screen `width` wide around a pill `pill` wide.
    static func perSide(width: CGFloat, pill: CGFloat) -> Int { max(0, Int((width / 2 - pill / 2 - clear - 4) / (bar + gap))) }

    /// `left` and `right` are each channel's levels, 0 to 1, bass first (DockSpectrum); nil is silence.
    static func path(width: CGFloat, pill: CGFloat, tallest: CGFloat, left: [Float]?, right: [Float]?) -> CGPath {
        let path = CGMutablePath()
        let n = perSide(width: width, pill: pill), cx = width / 2, inner = pill / 2 + clear, pitch = bar + gap
        guard n > 0 else { return path }
        for k in 0..<n {
            let t = Double(k) / Double(max(1, n - 1))
            let l = left.map { max(flat, CGFloat(DockSpectrum.sample($0, at: t)) * tallest) } ?? flat
            let r = right.map { max(flat, CGFloat(DockSpectrum.sample($0, at: t)) * tallest) } ?? flat
            path.addRect(CGRect(x: (cx - inner - CGFloat(k) * pitch - bar).rounded(), y: 0, width: bar, height: l.rounded()))
            path.addRect(CGRect(x: (cx + inner + CGFloat(k) * pitch).rounded(), y: 0, width: bar, height: r.rounded()))
        }
        return path
    }
}
