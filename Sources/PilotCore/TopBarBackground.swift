import Foundation

/// What the top bar stands on (Sven, 2026-10-10): its colour opaque, Glass with its colour as the glass's tint, or Clear,
/// nothing, its items straight on the wallpaper as on the macOS menu bar (Sven on build 60).
public enum TopBarBackground: String, CaseIterable, Sendable {
    case solid, glass, clear

    public var title: String { rawValue.capitalized }

    /// What a bar on this Background draws at Look's Transparency `transparency`: Glass goes Solid at 0 %, as the app
    /// window does (Sven, Q714).
    public func shown(transparency: Int) -> TopBarBackground { self == .glass && transparency <= 0 ? .solid : self }
}
