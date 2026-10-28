import Foundation

/// A colour that is the theme's or one picked (Sven, 2026-10-10): the top bar's and the focused window's border. Saved
/// as its raw value, "theme" or "#RRGGBB".
public enum ColourChoice: Equatable, Sendable, RawRepresentable {
    case theme
    case custom(UInt32)

    public init?(rawValue: String) {
        if rawValue == "theme" { self = .theme; return }
        guard rawValue.count == 7, rawValue.hasPrefix("#"), let rgb = UInt32(rawValue.dropFirst(), radix: 16) else { return nil }
        self = .custom(rgb)
    }

    public var rawValue: String {
        switch self {
        case .theme: "theme"
        case .custom(let rgb): "#" + String(format: "%06X", rgb & 0xFFFFFF)
        }
    }

    /// The colour drawn: `theme`'s own when Theme.
    public func resolved(_ theme: UInt32) -> UInt32 {
        switch self {
        case .theme: theme
        case .custom(let rgb): rgb
        }
    }
}

extension Contrast {
    /// Text that reads on `ground`: white or near-black, whichever stands further from it. Unlike PilotTheme.ink(on:) and
    /// Theme.ink(on:), which follow the theme's darkness, this one follows only the ground's.
    public static func readableInk(on ground: UInt32) -> UInt32 {
        let white: UInt32 = 0xFFFFFF, dark: UInt32 = 0x1A1A1A
        return ratio(white, ground) >= ratio(dark, ground) ? white : dark
    }
}

extension StyleColors {
    /// These colours on a bar of a colour the theme did not pick, `ground`: every text role and hairline in the ink that
    /// reads on it (Contrast.ink), the quieter ones fainter; a raised pill the ink, faint; the inverse fill (Menu's current
    /// workspace) the ink with the ground on it; accent words the ink where the accent does not read. The theme's own roles stay for its own colour: they were made for it.
    /// `ink` overrides the one picked for the ground (BarTone's, the theme's side over the wallpaper); `full` draws the
    /// quieter roles near the ink's whole strength, as the macOS menu bar draws every glyph over its wallpaper.
    public func inked(on ground: UInt32, ink given: UInt32? = nil, full: Bool = false) -> StyleColors {
        let ink = given ?? Contrast.readableInk(on: ground)
        var inked = self
        (inked.text, inked.text2, inked.text3, inked.text4) = (Paint(ink), Paint(ink, full ? 1 : 0.85), Paint(ink, full ? 0.9 : 0.72), Paint(ink, full ? 0.9 : 0.72))
        (inked.line, inked.line2, inked.line3) = (Paint(ink, 0.18), Paint(ink, 0.28), Paint(ink, 0.28))
        (inked.raised, inked.inverse, inked.onInverse) = (Paint(ink, 0.18), Paint(ink), Paint(ground))
        // Accent words keep the accent where it reads on the colour (Instrument's timer), else take the ink.
        if Contrast.ratio(accentText.rgb, ground) < 4.5 { inked.accentText = Paint(ink) }
        return inked
    }
}

extension StyleTokens {
    /// These tokens on a bar of `ground` (StyleColors.inked), dark when their ink is white.
    public func inked(on ground: UInt32, ink given: UInt32? = nil, full: Bool = false) -> StyleTokens {
        let ink = given ?? Contrast.readableInk(on: ground)
        var tokens = StyleTokens(kind: kind, dark: ink == 0xFFFFFF, colors: colors.inked(on: ground, ink: ink, full: full), type: type, radii: radii,
                                 depth: depth, density: density)
        tokens.scale = scale
        tokens.inked = true
        return tokens
    }
}
