import Foundation
import CoreGraphics

/// Portable suggestions name a built-in preset. Personal geometry and items never travel in a pack.
public enum BarPreset: String, Codable, CaseIterable, Sendable {
    /// Pills (Sven, 2026-11-12, Q177, after a Waybar picture): each slot on its own pill, the Group one pill for all it
    /// holds; beside Three islands, which makes one island per side.
    case floatingStrip, threeIslands, pills
    public var title: String {
        switch self {
        case .floatingStrip: "Floating strip"
        case .threeIslands: "Three islands"
        case .pills: "Pills"
        }
    }
    public var configuration: BarPresetConfiguration { .init(preset: self) }
    /// Draws an island per side (Three islands) or per slot (Pills), each its own window, rather than one strip.
    public var islands: Bool { self != .floatingStrip }
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

    /// Each preset's own defaults (Sven, 2026-11-12, on the bar look round: the floating strip "a bit too big", Three
    /// islands as it is). For Pills `height` is a pill's, `padding` the room inside one, `radius` its corners.
    public init(preset: BarPreset = .floatingStrip) {
        self.preset = preset
        switch preset {
        case .threeIslands: break
        case .floatingStrip: (height, horizontalMargin, topMargin, spacing, padding, radius, border) = (30, 10, 6, 4, 6, 9, 1)
        case .pills: (height, horizontalMargin, topMargin, spacing, padding, radius, border) = (28, 10, 6, 6, 6, 14, 1.5)
        }
    }

    /// What the top bar's row lays out by (TopBarRow): Pills keep their `padding` inside each pill, never round a side.
    public var row: BarPresetConfiguration {
        var row = self
        if preset == .pills { row.padding = 0 }
        return row
    }

    /// The floating strip's defaults before 2026-11-12, every preset's then: a bar saved at exactly these was never
    /// adjusted, so it moves to the new defaults once (BarItemsStore); one adjusted keeps its own.
    public static let firstDefaults: BarPresetConfiguration = {
        var c = BarPresetConfiguration(preset: .threeIslands)
        c.preset = .floatingStrip
        return c
    }()
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
