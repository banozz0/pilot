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
