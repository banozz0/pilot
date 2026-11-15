import Foundation

/// Look's one Material (Sven, 2026-11-15, W77: "either everything is glass, solid or clear while still keeping option to
/// change everything alone"): Glass, Solid or Clear sets every surface's own setting at once; Custom is what it reads once
/// one of them was changed on its own. Read from the surfaces each time, never stored, so it cannot drift from them.
public enum LookMaterial: String, CaseIterable, Sendable {
    case glass, solid, clear, custom

    public var title: String { rawValue.capitalized }

    /// The switches every surface follows: the top bar's Background (its dropdowns, drops and notification cards
    /// follow it), the dock's style, and Look's Glass and Blur (Pilot's window and panels, and the desktop widgets).
    public struct Surfaces: Equatable, Sendable {
        public var bar: TopBarBackground, dock: TopBarBackground, glass: Bool
        /// Look's Blur: Full is regular glass, Light clear glass. Nil in a pick leaves it, as Solid does (no glass to blur).
        public var blur: GlassBlur?

        public init(bar: TopBarBackground, dock: TopBarBackground, glass: Bool, blur: GlassBlur?) {
            self.bar = bar; self.dock = dock; self.glass = glass; self.blur = blur
        }

        /// Whether the stored switches `stored` wear this pick: a nil blur takes any.
        func worn(by stored: Surfaces) -> Bool {
            bar == stored.bar && dock == stored.dock && glass == stored.glass && (blur == nil || blur == stored.blur)
        }
    }

    /// What picking it sets; nil for Custom, which is only read. Glass puts Pilot's windows, panels and widgets on
    /// regular glass (Blur Full), Clear on clear glass (Blur Light: less frosting, more wallpaper, the tint lifted until
    /// body text reads; Sven on build 2587, where Clear drew as Glass on his windows).
    public var surfaces: Surfaces? {
        switch self {
        case .glass: Surfaces(bar: .glass, dock: .glass, glass: true, blur: .full)
        case .solid: Surfaces(bar: .solid, dock: .solid, glass: false, blur: nil)
        case .clear: Surfaces(bar: .clear, dock: .clear, glass: true, blur: .light)
        case .custom: nil
        }
    }

    /// The material `surfaces` add up to: the pick that sets them all so, else Custom.
    public init(_ surfaces: Surfaces) {
        self = Self.allCases.first { $0.surfaces?.worn(by: surfaces) == true } ?? .custom
    }
}
