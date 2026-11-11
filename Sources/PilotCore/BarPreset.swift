import Foundation
import CoreGraphics

/// Portable suggestions name a built-in preset. Personal geometry and items never travel in a pack.
public enum BarPreset: String, Codable, CaseIterable, Sendable {
    case floatingStrip, threeIslands
    public var title: String { self == .floatingStrip ? "Floating strip" : "Three islands" }
    public var configuration: BarPresetConfiguration { .init(preset: self) }
}

/// Local geometry only; the existing BarSettings remains the sole owner of item/group order and placement.
public struct BarPresetConfiguration: Codable, Equatable, Sendable {
    public var preset: BarPreset
    public var height: Double = 36
    public var horizontalMargin: Double = 12
    public var topMargin: Double = 8
    public var spacing: Double = 8
    public var padding: Double = 8
    public var radius: Double = 10
    public var border: Double = 1

    public init(preset: BarPreset = .floatingStrip) { self.preset = preset }
    public static let ranges: [String: ClosedRange<Double>] = [
        "height": 24...80, "horizontalMargin": 0...160, "topMargin": 0...80,
        "spacing": 0...32, "padding": 0...32, "radius": 0...40, "border": 0...4,
    ]
    public func validate() throws {
        let values = ["height": height, "horizontalMargin": horizontalMargin, "topMargin": topMargin,
                      "spacing": spacing, "padding": padding, "radius": radius, "border": border]
        guard values.allSatisfy({ $0.value.isFinite && Self.ranges[$0.key]!.contains($0.value) }) else {
            throw ThemeFailure("bar geometry must be finite and within its declared ranges")
        }
    }

    /// Supplied screen geometry, no desktop lookup. A notched menu strip stays entirely above the floating bar.
    public func frame(screen: CGRect, notchHeight: Double = 0) -> CGRect {
        let margin = min(horizontalMargin, max(0, (screen.width - 1) / 2))
        let top = min(max(0, notchHeight) + topMargin, max(0, screen.height - 1))
        let h = min(height, max(1, screen.height - top))
        return CGRect(x: screen.minX + margin, y: screen.maxY - top - h,
                      width: max(1, screen.width - 2 * margin), height: h)
    }
}

/// Present wrapper + nil configuration means the pre-preset legacy bar; absent wrapper means no bound capability.
public struct ThemeBarPresetState: Codable, Equatable, Sendable {
    public var configuration: BarPresetConfiguration?
    public init(_ configuration: BarPresetConfiguration?) { self.configuration = configuration }
    public func validate() throws { try configuration?.validate() }
}
