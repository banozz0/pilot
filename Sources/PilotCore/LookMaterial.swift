import Foundation

/// Look's one Material (Sven, 2026-11-15, W77: "either everything is glass, solid or clear while still keeping option to
/// change everything alone"): Glass, Solid or Clear sets every surface's own setting at once; Custom is what it reads once
/// one of them was changed on its own. Read from the surfaces each time, never stored, so it cannot drift from them.
public enum LookMaterial: String, CaseIterable, Sendable {
    case glass, solid, clear, custom

    public var title: String { rawValue.capitalized }

    /// The three switches every surface follows: the top bar's Background (its dropdowns, drops and notification cards
    /// follow it), the dock's style, and Look's Glass (Pilot's window and panels, and the desktop widgets).
    public struct Surfaces: Equatable, Sendable {
        public var bar: TopBarBackground, dock: TopBarBackground, glass: Bool

        public init(bar: TopBarBackground, dock: TopBarBackground, glass: Bool) {
            self.bar = bar; self.dock = dock; self.glass = glass
        }
    }

    /// What picking it sets; nil for Custom, which is only read. Pilot's windows and panels have no Clear, so Clear turns
    /// their Glass on, as see-through as they go and still readable.
    public var surfaces: Surfaces? {
        switch self {
        case .glass: Surfaces(bar: .glass, dock: .glass, glass: true)
        case .solid: Surfaces(bar: .solid, dock: .solid, glass: false)
        case .clear: Surfaces(bar: .clear, dock: .clear, glass: true)
        case .custom: nil
        }
    }

    /// The material `surfaces` add up to: the pick that sets them all so, else Custom.
    public init(_ surfaces: Surfaces) {
        self = Self.allCases.first { $0.surfaces == surfaces } ?? .custom
    }
}
