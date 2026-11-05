import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// The frame an export sits in (CP12; P70, Snapzy's background sidebar): a fill round the capture
/// (see-through, one colour, a gradient, a picture such as a wallpaper, or the capture itself), that picture sharp or
/// blurred four ways, padding, rounded corners, a shadow, and the export's shape (the padded capture, or 1:1, 4:3, 3:2,
/// 16:9, each wide or tall). Codable, so a saved preset keeps it whole.
public struct Backdrop: Equatable, Sendable, Codable {
    public enum Fill: Equatable, Sendable, Codable {
        /// Nothing behind the capture: the padding and the shadow on see-through pixels.
        case clear
        case colour(UInt32)
        /// From the top left to the bottom right.
        case gradient([UInt32])
        /// A picture file, filling the frame (cropped to cover it): a wallpaper.
        case image(String)
        /// The capture as taken, filling the frame; with a blur, CleanShot's and Xnapper's blurred background.
        case capture

        /// Whether it is a picture, the one kind a blur applies to.
        public var picture: Bool {
            switch self {
            case .image, .capture: true
            default: false
            }
        }
    }

    /// A picture fill's blur. The values are Snapzy's BlurredBackgroundEffect (BSD-3, Packaging/Snapzy-LICENSE.txt): its
    /// radius on a picture 1000 pixels on its longer side, so a blur looks the same in the preview and at any export size.
    public enum Blur: String, CaseIterable, Sendable, Codable {
        case off, soft, frosted, vivid, dim

        public var name: String { self == .off ? "Sharp" : rawValue.capitalized }
        public var radius: CGFloat { [0, 18, 30, 22, 24][index] }
        public var saturation: CGFloat { [1, 1, 0.85, 1.35, 0.9][index] }
        public var brightness: CGFloat { [0, 0, 0.06, 0.02, -0.06][index] }
        /// The wash laid over the blurred picture, as 0xRRGGBB and its opacity.
        public var tint: (rgb: UInt32, alpha: CGFloat) {
            switch self {
            case .off: (0xFFFFFF, 0)
            case .soft: (0xFFFFFF, 0.08)
            case .frosted: (0xFFFFFF, 0.28)
            case .vivid: (0xFF9F0A, 0.10)
            case .dim: (0x000000, 0.24)
            }
        }

        private var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    /// The export's shape: the padded capture as it is, or a fixed ratio the frame grows to.
    public enum Ratio: String, CaseIterable, Sendable, Codable {
        case auto, square = "1:1", fourThree = "4:3", threeTwo = "3:2", wide = "16:9"

        /// Width over height, wide; nil for auto.
        public var value: CGFloat? {
            switch self {
            case .auto: nil
            case .square: 1
            case .fourThree: 4.0 / 3
            case .threeTwo: 1.5
            case .wide: 16.0 / 9
            }
        }

        /// Its label, tall ones turned round: 4:3 becomes 3:4.
        public func name(portrait: Bool) -> String {
            guard portrait, self != .auto, self != .square else { return self == .auto ? "Auto" : rawValue }
            return rawValue.split(separator: ":").reversed().joined(separator: ":")
        }
    }

    public var fill: Fill
    public var blur: Blur
    /// Points round the capture, 0 to `maxPad`.
    public var pad: CGFloat
    /// The capture's corners, 0 to `maxRadius` points.
    public var radius: CGFloat
    /// The shadow under the capture, 0 (none) to 1.
    public var shadow: CGFloat
    public var ratio: Ratio
    /// A fixed ratio turned tall (3:4, 2:3, 9:16).
    public var portrait: Bool
    /// Auto balance (C2, Xnapper's): the fill is the capture's own edge colour, read from each capture it frames, so the
    /// capture seems to sit in the middle of one plain ground. `fill` holds the colour last read, for the preview.
    public var balance: Bool
    /// Sized for a place (C9): the export takes the place's shape, the frame grown round the capture as a ratio grows it,
    /// then the whole drawn at the place's pixels. Never stretched. Nil keeps `ratio` and the capture's own pixels.
    public var place: Place?

    /// Where an export goes, and the size each one shows an image at (2026 third-party size guides, not the platforms' own
    /// docs: SocialBee, digitalapplied.com, Constant Contact).
    public enum Place: String, CaseIterable, Sendable, Codable {
        case x, instagram, linkedin, youtube

        public var name: String {
            switch self {
            case .x: "X"
            case .instagram: "Instagram"
            case .linkedin: "LinkedIn"
            case .youtube: "YouTube"
            }
        }

        /// Its pixels: X's in-feed 16:9, Instagram's portrait feed 4:5, LinkedIn's shared image 1.91:1, a YouTube
        /// thumbnail's 16:9.
        public var pixels: CGSize {
            switch self {
            case .x: CGSize(width: 1600, height: 900)
            case .instagram: CGSize(width: 1080, height: 1350)
            case .linkedin: CGSize(width: 1200, height: 627)
            case .youtube: CGSize(width: 1280, height: 720)
            }
        }
    }

    public static let maxPad: CGFloat = 160
    public static let maxRadius: CGFloat = 40

    public init(fill: Fill, blur: Blur = .off, pad: CGFloat = 48, radius: CGFloat = 12, shadow: CGFloat = 0.5,
                ratio: Ratio = .auto, portrait: Bool = false, balance: Bool = false, place: Place? = nil) {
        self.fill = fill
        self.blur = blur
        self.pad = min(Self.maxPad, max(0, pad))
        self.radius = min(Self.maxRadius, max(0, radius))
        self.shadow = min(1, max(0, shadow))
        self.ratio = ratio
        self.portrait = portrait
        self.balance = balance
        self.place = place
    }

    private enum CodingKeys: String, CodingKey { case fill, blur, pad, radius, shadow, ratio, portrait, balance, place }

    /// A backdrop saved before a key existed (a preset, a video's edit) reads that key as its default, so no preset is lost.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fill: try c.decode(Fill.self, forKey: .fill), blur: try c.decode(Blur.self, forKey: .blur), pad: try c.decode(CGFloat.self, forKey: .pad),
                  radius: try c.decode(CGFloat.self, forKey: .radius), shadow: try c.decode(CGFloat.self, forKey: .shadow),
                  ratio: try c.decode(Ratio.self, forKey: .ratio), portrait: try c.decode(Bool.self, forKey: .portrait),
                  balance: try c.decodeIfPresent(Bool.self, forKey: .balance) ?? false, place: try c.decodeIfPresent(Place.self, forKey: .place))
    }

    /// The blur that shows: only a picture is blurred.
    public var shownBlur: Blur { fill.picture ? blur : .off }

    /// This backdrop for `image`: balanced, its fill the image's edge colour; anything else as it is.
    public func resolved(for image: CGImage?) -> Backdrop {
        guard balance, let image else { return self }
        return resolved(edge: MarkupRenderer.edgeColour(image))
    }

    /// Balanced, its fill `rgb` (the edge colour read already); anything else as it is.
    public func resolved(edge rgb: UInt32?) -> Backdrop {
        guard balance, let rgb else { return self }
        var b = self
        b.fill = .colour(rgb)
        b.blur = .off
        return b
    }

    /// The same look as `other`: equal, or both balanced and equal but for the edge colour each read.
    public func sameLook(_ other: Backdrop) -> Bool {
        guard balance, other.balance else { return self == other }
        var a = self, b = other
        (a.fill, a.blur, b.fill, b.blur) = (.clear, .off, .clear, .off)
        return a == b
    }

    /// The export's size in points for a part `area` big: the padding round it, then grown along one axis to the ratio,
    /// or to the place's shape (after Snapzy's AspectRatioOption.canvasSize, BSD-3).
    public func canvas(for area: CGSize) -> CGSize {
        let w = max(area.width, 1) + 2 * pad, h = max(area.height, 1) + 2 * pad
        let target: CGFloat
        if let place { target = place.pixels.width / place.pixels.height }
        else if let wide = ratio.value { target = portrait && ratio != .square ? 1 / wide : wide }
        else { return CGSize(width: w, height: h) }
        return w / h < target ? CGSize(width: (h * target).rounded(), height: h) : CGSize(width: w, height: (w / target).rounded())
    }

    /// The export's pixels for a part `area` points big at `scale`: the place's, else the canvas at the scale.
    public func pixels(for area: CGSize, scale: CGFloat) -> CGSize {
        if let place { return place.pixels }
        let c = canvas(for: area)
        return CGSize(width: (c.width * scale).rounded(), height: (c.height * scale).rounded())
    }

    /// Where the part sits in the canvas, in points from its top left: in the middle.
    public func spot(for area: CGSize) -> CGRect {
        let c = canvas(for: area)
        return CGRect(x: ((c.width - area.width) / 2).rounded(), y: ((c.height - area.height) / 2).rounded(), width: area.width, height: area.height)
    }
}

/// A backdrop saved under a name (Snapzy's canvas presets): the panel's Presets row.
public struct BackdropPreset: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var backdrop: Backdrop

    public init(id: UUID = UUID(), name: String, backdrop: Backdrop) {
        self.id = id
        self.name = name
        self.backdrop = backdrop
    }

    /// "Preset 1", "Preset 2": the first number no preset has.
    public static func nextName(_ presets: [BackdropPreset]) -> String {
        let taken = Set(presets.map(\.name) + looks.map(\.name))
        return (1...).lazy.map { "Preset \($0)" }.first { !taken.contains($0) }!
    }

    /// Pilot's own looks (C1), first in the Looks row, one click each; fixed ids, so Every capture (C11) can name one.
    /// Colours and gradients only: nothing to ship or read from disk.
    public static let looks: [BackdropPreset] = [
        look(1, "Sunset", Backdrop(fill: .gradient([0xF7B267, 0xF25F5C, 0x8E44AD]), pad: 64, radius: 14, shadow: 0.6)),
        look(2, "Ocean", Backdrop(fill: .gradient([0x5B8DEF, 0x1E2A78]), pad: 56, radius: 12, shadow: 0.5)),
        look(3, "Mint", Backdrop(fill: .gradient([0x9BE7C4, 0x3BA7A0]), pad: 56, radius: 12, shadow: 0.45)),
        look(4, "Paper", Backdrop(fill: .colour(0xF4F1EA), pad: 40, radius: 10, shadow: 0.35)),
        look(5, "Night", Backdrop(fill: .gradient([0x2A3045, 0x0B0C10]), pad: 56, radius: 12, shadow: 0.7)),
        look(6, "Frosted", Backdrop(fill: .capture, blur: .frosted, pad: 64, radius: 14, shadow: 0.5)),
        look(7, "Balance", Backdrop(fill: .colour(0xFFFFFF), pad: 64, radius: 0, shadow: 0, balance: true)),
    ]

    private static func look(_ n: Int, _ name: String, _ backdrop: Backdrop) -> BackdropPreset {
        BackdropPreset(id: UUID(uuidString: String(format: "B0B0B0B0-0000-4000-8000-%012d", n))!, name: name, backdrop: backdrop)
    }

    /// Pilot's own look or a saved preset by id, else by name (any case), for Every capture and `pilot set`.
    public static func find(_ key: String, in presets: [BackdropPreset]) -> BackdropPreset? {
        let all = looks + presets
        return UUID(uuidString: key).flatMap { id in all.first { $0.id == id } }
            ?? all.first { $0.name.compare(key, options: .caseInsensitive) == .orderedSame }
    }
}

extension MarkupRenderer {
    /// `image` in its backdrop at the image's scale: the fill over the whole canvas, the shadow, then the image in its
    /// spot with its corners rounded, then `marks`, the backdrop's own (P77), in the canvas's points from its top left.
    /// `capture` is what a capture fill shows (the capture as taken), `image` itself when nil.
    /// A balanced backdrop takes `capture`'s edge colour; one sized for a place is drawn at the place's pixels.
    public static func framed(_ image: CGImage, _ backdrop: Backdrop, scale: CGFloat, capture: CGImage? = nil, marks: [Mark] = []) -> CGImage? {
        let backdrop = backdrop.resolved(for: capture ?? image)
        let area = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let canvas = backdrop.canvas(for: area), spot = backdrop.spot(for: area)
        let pixels = backdrop.pixels(for: area, scale: scale)
        // A place's pixels over the canvas's points: the same for both sides, the canvas having the place's shape.
        let scale = backdrop.place == nil ? scale : pixels.width / canvas.width
        let w = Int(pixels.width), h = Int(pixels.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let picture = backdrop.fill.picture ? backdropPicture(backdrop, capture: capture ?? image, side: max(w, h)) : nil
        // The spot in the context's bottom-left pixels.
        let drawn = backdrop.place == nil ? CGSize(width: image.width, height: image.height)
            : CGSize(width: (spot.width * scale).rounded(), height: (spot.height * scale).rounded())
        let place = CGRect(x: (spot.minX * scale).rounded(), y: CGFloat(h) - (spot.minY * scale).rounded() - drawn.height,
                           width: drawn.width, height: drawn.height)
        // `ground` leaves the context clipped to the spot: the backdrop's marks draw after it is let go.
        ctx.saveGState()
        ground(backdrop, in: ctx, spot: place, scale: scale, picture: picture)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: place)
        ctx.restoreGState()
        guard !marks.isEmpty else { return ctx.makeImage() }
        // The backdrop's marks never read the pixels under them (blur and redact stay on the capture).
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(marks, in: ctx, image: image, scale: scale, size: canvas)
        return ctx.makeImage()
    }

    /// The backdrop without its capture, on all of `ctx`: the fill, the shadow under `spot` (bottom-left pixels), the spot
    /// cleared with its rounded corners and left clipped to, for the capture (or a video's frames, P71) to go in.
    public static func ground(_ backdrop: Backdrop, in ctx: CGContext, spot: CGRect, scale: CGFloat, picture: CGImage?) {
        paint(backdrop.fill, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height), ctx, picture: picture)
        let r = min(backdrop.radius * scale, min(spot.width, spot.height) / 2)
        let shape = CGPath(roundedRect: spot, cornerWidth: r, cornerHeight: r, transform: nil)
        if backdrop.shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale * backdrop.shadow), blur: (10 + 26 * backdrop.shadow) * scale,
                          color: cg(0, 0.55 * backdrop.shadow))
            ctx.addPath(shape)
            ctx.setFillColor(cg(0xFFFFFF))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.addPath(shape)
        ctx.clip()
        ctx.clear(spot)
    }

    /// A backdrop's fill over `rect` of a bottom-left space: nothing, one colour, a gradient from the top left, or
    /// `picture` (a picture fill's, from `backdropPicture`) scaled to cover it, its middle kept.
    public static func paint(_ fill: Backdrop.Fill, in rect: CGRect, _ ctx: CGContext, picture: CGImage? = nil) {
        switch fill {
        case .clear: return
        case .colour(let rgb): ctx.setFillColor(cg(rgb)); ctx.fill(rect)
        case .gradient(let colours):
            guard colours.count > 1 else { return paint(colours.first.map { .colour($0) } ?? .clear, in: rect, ctx) }
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours.map { cg($0) } as CFArray, locations: nil) else { return }
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
            ctx.restoreGState()
        case .image, .capture:
            guard let picture else { return }
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.interpolationQuality = .high
            ctx.draw(picture, in: cover(CGSize(width: picture.width, height: picture.height), rect))
            ctx.restoreGState()
        }
    }

    /// The rect a picture `size` big is drawn in to cover `rect`, centred, its aspect kept.
    public static func cover(_ size: CGSize, _ rect: CGRect) -> CGRect {
        let k = max(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
        let w = size.width * k, h = size.height * k
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// A picture fill's picture, at most `side` pixels on its longer side: the file read at that size (never decoded
    /// whole) or the capture scaled down; blurred, read at 1000 a side, blurred, its colour changed and washed with the
    /// blur's tint. Nil for a fill that is not a picture, or a file that cannot be read.
    public static func backdropPicture(_ backdrop: Backdrop, capture: CGImage, side: Int) -> CGImage? {
        let blur = backdrop.shownBlur, longest = blur == .off ? max(side, 16) : 1000
        let picture: CGImage? = switch backdrop.fill {
        case .image(let path): readPicture(URL(filePath: path), side: longest)
        case .capture: scaled(capture, side: longest)
        default: nil
        }
        guard let picture else { return nil }
        guard blur != .off else { return picture }
        let source = CIImage(cgImage: picture)
        let soft = source.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur.radius])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: blur.saturation, kCIInputBrightnessKey: blur.brightness])
            .cropped(to: source.extent)
        guard let blurred = context.createCGImage(soft, from: source.extent),
              let ctx = CGContext(data: nil, width: blurred.width, height: blurred.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let all = CGRect(x: 0, y: 0, width: blurred.width, height: blurred.height)
        ctx.draw(blurred, in: all)
        ctx.setFillColor(cg(blur.tint.rgb, blur.tint.alpha))
        ctx.fill(all)
        return ctx.makeImage()
    }

    /// The colour most of `image`'s outer edge has (C2), as 0xRRGGBB: erase's edge colour, read on a copy at most 256
    /// pixels a side so a 5K capture costs one small draw.
    public static func edgeColour(_ image: CGImage) -> UInt32 {
        let small = scaled(image, side: 256) ?? image
        return edgeColour(small, CGRect(x: 0, y: 0, width: small.width, height: small.height), scale: 1)
    }

    /// A picture file read at most `side` pixels on its longer side, turned upright.
    public static func readPicture(_ url: URL, side: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// `image` scaled down to at most `side` pixels on its longer side; itself when it is smaller.
    public static func scaled(_ image: CGImage, side: Int) -> CGImage? {
        let k = CGFloat(side) / CGFloat(max(image.width, image.height))
        guard k < 1 else { return image }
        let w = max(1, Int(CGFloat(image.width) * k)), h = max(1, Int(CGFloat(image.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
