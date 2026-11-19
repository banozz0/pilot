import Foundation

/// Tiling's Focused window as presets (spec pilot-ui-redesign T15, S1 B; Open question 10): Border and Dim other windows
/// each read Off, Soft, Strong or Custom. A preset is a view over today's keys, never stored: picking one writes them,
/// and Custom is whatever mix matches none, so it is only read.
public enum FocusPreset: String, CaseIterable, Sendable {
    case off, soft, strong, custom

    public var title: String { rawValue.capitalized }

    /// What `pilot set` answers for Custom: it is read, never picked.
    public static let customRefusal = "custom is read only: it reads custom once the rows match no preset; pick off, soft or strong"
}

/// The focused window's border: `look.windowBorder`, `look.windowBorderWidth`, `look.windowBorderColour`.
public struct BorderLook: Equatable, Sendable {
    public var on: Bool, width: Int, colour: ColourChoice

    public init(on: Bool, width: Int, colour: ColourChoice) {
        self.on = on; self.width = width; self.colour = colour
    }

    /// Soft is today's default border (2 pt, the theme's colour), Strong twice its width. Off sets the switch alone, so
    /// the width and colour picked stay for the next time it is on.
    public static func picked(_ preset: FocusPreset, from now: BorderLook) -> BorderLook? {
        switch preset {
        case .off: BorderLook(on: false, width: now.width, colour: now.colour)
        case .soft: BorderLook(on: true, width: WindowBorder.defaultWidth, colour: .theme)
        case .strong: BorderLook(on: true, width: 4, colour: .theme)
        case .custom: nil
        }
    }

    /// The preset these values make: Off while the switch is off, whatever the width and colour.
    public var preset: FocusPreset {
        guard on else { return .off }
        return [FocusPreset.soft, .strong].first { Self.picked($0, from: self) == self } ?? .custom
    }
}

/// Dim other windows (Defocus's look): `look.defocusStrength` (the blur) and `look.defocusDim` (the darkening). The shake
/// rows are its trigger, not its look, so no preset touches them.
public struct DimLook: Equatable, Sendable {
    public var blur: Int, dim: Int

    public init(blur: Int, dim: Int) { self.blur = blur; self.dim = dim }

    /// Off is both at 0 (Defocus has nothing to do), Soft today's default (blur 3, dim 18 %), Strong the heaviest blur
    /// with 40 % dim.
    public static func picked(_ preset: FocusPreset) -> DimLook? {
        switch preset {
        case .off: DimLook(blur: 0, dim: 0)
        case .soft: DimLook(blur: Defocus.defaultStrength, dim: Defocus.defaultDim)
        case .strong: DimLook(blur: Defocus.strengths.upperBound, dim: 40)
        case .custom: nil
        }
    }

    public var preset: FocusPreset {
        [FocusPreset.off, .soft, .strong].first { Self.picked($0) == self } ?? .custom
    }
}
