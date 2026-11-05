import CoreGraphics

/// Combine images (P73): picked captures laid out in one picture, side by side at the first one's height or stacked at
/// its width, with a gap between. Adapted from Snapzy's CombineImagesLayout (BSD 3-Clause, © 2026 Trong Duong Duc;
/// Packaging/Snapzy-LICENSE.txt), its smart direction and free canvas left out.
public enum CombineLayout {
    public enum Direction: String, CaseIterable, Sendable {
        case sideBySide, stacked

        public var title: String { self == .sideBySide ? "Side by side" : "Stacked" }
    }

    /// The largest side a combined picture may have, the upscaler's (ImageScale's UpscaleTarget).
    public static let most: CGFloat = 16_384

    /// Each picture's frame in the combined one (top-left origin, pixels) and its size: every picture scaled to the first's
    /// height side by side, or to its width stacked, `gap` apart; a picture with no size is left out. When a side would
    /// pass `most`, everything shrinks by one factor until it fits.
    public static func layout(_ sizes: [CGSize], direction: Direction, gap: CGFloat) -> (frames: [CGRect], size: CGSize) {
        guard let first = sizes.first(where: { $0.width > 0 && $0.height > 0 }) else { return ([], .zero) }
        let gap = max(0, gap)
        var cursor: CGFloat = 0
        var frames: [CGRect] = []
        for size in sizes {
            guard size.width > 0, size.height > 0 else { frames.append(.zero); continue }
            let frame = switch direction {
            case .sideBySide: CGRect(x: cursor, y: 0, width: (size.width * first.height / size.height).rounded(), height: first.height)
            case .stacked: CGRect(x: 0, y: cursor, width: first.width, height: (size.height * first.width / size.width).rounded())
            }
            frames.append(frame)
            cursor += (direction == .sideBySide ? frame.width : frame.height) + gap
        }
        var total = frames.reduce(CGRect.null) { $1 == .zero ? $0 : $0.union($1) }.size
        let fit = min(1, most / max(total.width, total.height, 1))
        if fit < 1 {
            frames = frames.map { $0 == .zero ? $0 : CGRect(x: ($0.minX * fit).rounded(), y: ($0.minY * fit).rounded(),
                                                            width: ($0.width * fit).rounded(), height: ($0.height * fit).rounded()) }
            total = frames.reduce(CGRect.null) { $1 == .zero ? $0 : $0.union($1) }.size
        }
        return (frames, total)
    }

    /// `images` drawn into one picture by `layout`, gaps clear, in the first one's colour space (as Combine images draws):
    /// Add a capture's before and after (C8). Nil when none has a size.
    public static func draw(_ images: [CGImage], direction: Direction, gap: CGFloat) -> CGImage? {
        let (frames, size) = layout(images.map { CGSize(width: $0.width, height: $0.height) }, direction: direction, gap: gap)
        let space = images.first?.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard size.width >= 1, size.height >= 1,
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        for (image, frame) in zip(images, frames) where frame != .zero {
            ctx.draw(image, in: CGRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height))
        }
        return ctx.makeImage()
    }
}
