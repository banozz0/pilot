import Foundation

/// The resize panel's numbers (Q246): width and height in pixels, the aspect locked or not, the percent presets. Every
/// size stays between 1 and `limit` a side; with the aspect locked the other side follows, rounded.
public struct ResizeTarget: Equatable, Sendable {
    /// The size the panel opened on.
    public let originalWidth: Int, originalHeight: Int
    public private(set) var width: Int, height: Int
    public var locked = true

    /// A side no bigger than this: past it a 4x wallpaper's buffer passes a gigabyte.
    public static let limit = 16_384
    public static let presets = [25, 50, 75, 200]

    public init(width: Int, height: Int) {
        originalWidth = max(1, width)
        originalHeight = max(1, height)
        self.width = originalWidth
        self.height = originalHeight
    }

    private static func clamp(_ v: Double) -> Int { min(limit, max(1, Int(v.rounded()))) }

    public mutating func setWidth(_ w: Int) {
        width = Self.clamp(Double(w))
        if locked { height = Self.clamp(Double(width) * Double(originalHeight) / Double(originalWidth)) }
    }

    public mutating func setHeight(_ h: Int) {
        height = Self.clamp(Double(h))
        if locked { width = Self.clamp(Double(height) * Double(originalWidth) / Double(originalHeight)) }
    }

    /// A preset keeps the aspect whether locked or not.
    public mutating func setPercent(_ percent: Int) {
        width = Self.clamp(Double(originalWidth) * Double(percent) / 100)
        height = Self.clamp(Double(originalHeight) * Double(percent) / 100)
    }

    /// The preset the size is, nil for any other.
    public var percent: Int? {
        Self.presets.first { p in
            width == Self.clamp(Double(originalWidth) * Double(p) / 100) && height == Self.clamp(Double(originalHeight) * Double(p) / 100)
        }
    }

    public var changed: Bool { width != originalWidth || height != originalHeight }

    /// How much each side grows: another image under the same change (Finder's several files).
    public var factor: (x: Double, y: Double) { (Double(width) / Double(originalWidth), Double(height) / Double(originalHeight)) }

    /// `size` under the same factor, each side kept between 1 and the limit.
    public func applied(width w: Int, height h: Int) -> (width: Int, height: Int) {
        let f = factor
        return (Self.clamp(Double(w) * f.x), Self.clamp(Double(h) * f.y))
    }
}

/// The upscale panel's size (Sven, build 62): 2x, 3x or 4x, or a width or height typed with the aspect kept, never under
/// the image's own size nor past 4x or `ResizeTarget.limit` a side. The model runs 2x for a factor up to 2, else 4x, and a
/// size between is resampled down from that (Real-ESRGAN's own `--outscale`).
public struct UpscaleTarget: Equatable, Sendable {
    public static let presets = [2, 3, 4]
    public let originalWidth: Int, originalHeight: Int
    public private(set) var width: Int, height: Int

    public init(width: Int, height: Int, times: Int = 4) {
        originalWidth = max(1, width)
        originalHeight = max(1, height)
        self.width = originalWidth
        self.height = originalHeight
        setFactor(Double(times))
    }

    /// The biggest factor the limit allows, 4 at most.
    public var maxFactor: Double {
        min(4, Double(ResizeTarget.limit) / Double(originalWidth), Double(ResizeTarget.limit) / Double(originalHeight))
    }

    public mutating func setFactor(_ f: Double) {
        let f = min(maxFactor, max(1, f))
        width = max(1, Int((Double(originalWidth) * f).rounded()))
        height = max(1, Int((Double(originalHeight) * f).rounded()))
    }

    public mutating func setWidth(_ w: Int) { setFactor(Double(w) / Double(originalWidth)) }
    public mutating func setHeight(_ h: Int) { setFactor(Double(h) / Double(originalHeight)) }

    /// The preset the size is, nil for a typed one.
    public var times: Int? {
        Self.presets.first { width == originalWidth * $0 && height == originalHeight * $0 }
    }

    public var factor: Double { Double(width) / Double(originalWidth) }
    /// Whether it makes the image any bigger.
    public var grows: Bool { width > originalWidth || height > originalHeight }

    /// Another image's size under the same change (Finder's several files): the preset's factor, or the typed one.
    public func applied(width w: Int, height h: Int) -> (width: Int, height: Int) {
        var other = UpscaleTarget(width: w, height: h, times: 1)
        other.setFactor(times.map(Double.init) ?? factor)
        return (other.width, other.height)
    }

    /// The model's pass for a factor: 2 up to 2x, else 4.
    public static func pass(_ factor: Double) -> Int { factor <= 2 ? 2 : 4 }

    /// The result's name after its stem: " 3x" for a whole factor, " 2560x1440" for any other.
    public static func suffix(from w: Int, _ h: Int, to width: Int, _ height: Int) -> String {
        let k = width / max(1, w)
        return k * w == width && k * h == height ? " \(k)x" : " \(width)x\(height)"
    }
}
