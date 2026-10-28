import CoreGraphics

/// A pinned capture's zoom and see-through (spec `capture.html` CP9): it floats over every window at its own size,
/// the scroll wheel zooms it from 10 to 400 %, and O steps its opacity through 100, 75 and 50 %.
public struct PinState: Equatable, Sendable {
    public static let zooms: ClosedRange<CGFloat> = 0.1...4
    public static let opacities: [CGFloat] = [1, 0.75, 0.5]

    /// The capture's own size in points.
    public let size: CGSize
    public private(set) var zoom: CGFloat = 1
    public private(set) var opacity: CGFloat = 1

    public init(size: CGSize) { self.size = size }

    /// The window's size now, never under 40 points a side.
    public var frame: CGSize {
        CGSize(width: max(40, (size.width * zoom).rounded()), height: max(40, (size.height * zoom).rounded()))
    }

    /// A scroll of `dy` lines: up grows it, down shrinks it, 10 % a line, within 10 to 400 %.
    public mutating func scrolled(_ dy: CGFloat) {
        guard dy != 0 else { return }
        zoom = min(Self.zooms.upperBound, max(Self.zooms.lowerBound, zoom * (dy > 0 ? 1.1 : 1 / 1.1)))
        if abs(zoom - 1) < 0.04 { zoom = 1 }
    }

    public mutating func actualSize() { zoom = 1 }

    public mutating func nextOpacity() {
        let i = Self.opacities.firstIndex(of: opacity) ?? 0
        opacity = Self.opacities[(i + 1) % Self.opacities.count]
    }

    public mutating func setOpacity(_ value: CGFloat) { opacity = Self.opacities.contains(value) ? value : 1 }
}
