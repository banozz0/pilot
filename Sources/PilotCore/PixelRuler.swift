import CoreGraphics

/// The pixel ruler (spec `capture.html` CP12): from a point, how far the colour under it runs left,
/// right, up and down before it changes, so the pointer over a button reads its width and height. The capture's pixels
/// are read once, as RGBA.
public struct PixelGrid: Sendable {
    public let width: Int, height: Int
    private let rgba: [UInt8]

    public init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        self.rgba = rgba
    }

    /// Pixel (x, y)'s colour as 0xRRGGBB (top left origin), nil off the image: the colour picker's.
    public func rgb(x: Int, y: Int) -> UInt32? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        return UInt32(rgba[i]) << 16 | UInt32(rgba[i + 1]) << 8 | UInt32(rgba[i + 2])
    }

    /// Whether two pixels look alike: every channel within `tolerance`.
    func same(_ a: Int, _ b: Int, tolerance: Int) -> Bool {
        (0..<3).allSatisfy { abs(Int(rgba[a * 4 + $0]) - Int(rgba[b * 4 + $0])) <= tolerance }
    }

    /// From pixel (x, y) (top left origin), the pixels like it to the left, right, above and below before the first unlike
    /// one or the edge; the point's own pixel is not counted.
    public func span(x: Int, y: Int, tolerance: Int = 10) -> (left: Int, right: Int, up: Int, down: Int) {
        guard x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0, 0) }
        let here = y * width + x
        func run(_ dx: Int, _ dy: Int) -> Int {
            var n = 0, px = x + dx, py = y + dy
            while px >= 0, py >= 0, px < width, py < height, same(here, py * width + px, tolerance: tolerance) {
                n += 1; px += dx; py += dy
            }
            return n
        }
        return (run(-1, 0), run(1, 0), run(0, -1), run(0, 1))
    }
}

public enum PixelRuler {
    /// The two lines the ruler shows at `point` (the capture's points), edge to edge across the colour under it: the
    /// horizontal one first. Ends are on pixel edges.
    public static func lines(_ grid: PixelGrid, at point: CGPoint, scale: CGFloat) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let x = Int(point.x * scale), y = Int(point.y * scale)
        let s = grid.span(x: x, y: y)
        let mid = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
        return (CGPoint(x: CGFloat(x - s.left) / scale, y: mid.y), CGPoint(x: CGFloat(x + s.right + 1) / scale, y: mid.y),
                CGPoint(x: mid.x, y: CGFloat(y - s.up) / scale), CGPoint(x: mid.x, y: CGFloat(y + s.down + 1) / scale))
    }

    /// A measure's label: its length in pixels, or in points.
    public static func label(_ a: CGPoint, _ b: CGPoint, scale: CGFloat, points: Bool) -> String {
        let length = hypot(b.x - a.x, b.y - a.y) * (points ? 1 : scale)
        return "\(Int(length.rounded())) \(points ? "pt" : "px")"
    }
}
