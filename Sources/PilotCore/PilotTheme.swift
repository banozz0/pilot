import CoreGraphics
import Foundation
import ImageIO

/// A colour with its strength: 0xRRGGBB and an alpha from 0 to 1.
public struct Paint: Equatable, Sendable {
    public var rgb: UInt32
    public var alpha: Double
    public init(_ rgb: UInt32, _ alpha: Double = 1) { self.rgb = rgb; self.alpha = alpha }
}

/// A theme's display face (design round 4, pick 5): theme names, page titles, the greeting and a few headlines. Bundled in
/// Pilot.app's Resources/Fonts/<file>/<file>.ttf (OFL, licence beside it), never installed. `scale` multiplies every size
/// set in it, `tracking` is in em, `axes` are variation settings beyond weight (Fraunces' SOFT, Recursive's CASL).
public struct DisplayFace: Hashable, Sendable {
    public let family: String
    public let file: String
    public let weight: Int
    public let scale: Double
    public let tracking: Double
    public let italic: Bool
    public let axes: [String: Double]

    public init(family: String, file: String, weight: Int, scale: Double, tracking: Double, italic: Bool, axes: [String: Double]) {
        self.family = family; self.file = file; self.weight = weight; self.scale = scale; self.tracking = tracking
        self.italic = italic; self.axes = axes
    }

    /// The system's face, semibold, as the window's titles are.
    public static let system = DisplayFace(family: "", file: "", weight: 650, scale: 1, tracking: -0.02, italic: false, axes: [:])
    public var isSystem: Bool { file.isEmpty }
}

/// How a theme draws focus on a tile, card or key (the artifact's data-bt): Hyprland's gradient, a halo, a lit edge,
/// a woodblock's double rule, a sticker's offset shadow, a camera's corner brackets.
public enum FocusBorder: String, CaseIterable, Sendable {
    case gradient, glow, soft, lit, double, frost, offset, ink, brackets
}

/// The brightest part of a theme's own wallpaper, as the artifact measures contrast against it: `glow` at `amount` over
/// `base`.
public struct WallpaperSpot: Equatable, Sendable {
    public let glow: UInt32
    public let amount: Double
    public let base: UInt32
    public init(glow: UInt32, amount: Double, base: UInt32) { self.glow = glow; self.amount = amount; self.base = base }
    public var colour: [Double] { Contrast.mix(Contrast.rgb(glow), Contrast.rgb(base), amount) }
}

/// One of Pilot's themes (design round 4, artifact 5sh21HWjCjsWYAwWKTibcE, approved by Sven in chat 2026-10-06; card
/// agent-bo-95422890): every colour role of the artifact's TH table, its focus border, radius scale, display face and the
/// Omarchy palette it starts from, which Ghostty takes when the theme is picked (pick 8). Ten are designed whole (design
/// round 15 replaced round 4's twelve, Sven 2026-10-08).
public struct PilotTheme: Equatable, Sendable, Identifiable {
    public let id, name: String
    /// The short line under its name on a theme card.
    public let tagline: String
    /// The OmarchyTheme id it starts from.
    public let source: String
    public let dark: Bool
    /// `line` between things; `line2`, stronger, for edges and off switches.
    public let ground, sidebar, surface, raised, line, line2, text, text2, text3: UInt32
    public let second, third, good, amber, problem: UInt32
    public let accent: UInt32
    /// The three graph colours: CPU, Memory, Network.
    public let graphs: [UInt32]
    private let selectionOverride: Paint?
    private let onAccentOverride: UInt32?
    public let focus: FocusBorder
    /// Multiplies every corner radius.
    public let radius: Double
    public let face: DisplayFace
    public let wallpaper: WallpaperSpot

    public init(id: String, name: String, tagline: String, source: String, dark: Bool, ground: UInt32, sidebar: UInt32, surface: UInt32,
                raised: UInt32, line: UInt32, line2: UInt32, text: UInt32, text2: UInt32, text3: UInt32, accent: UInt32, second: UInt32,
                third: UInt32, good: UInt32, amber: UInt32, problem: UInt32, graphs: [UInt32], selection: Paint? = nil,
                onAccent: UInt32? = nil, focus: FocusBorder, radius: Double, face: DisplayFace, wallpaper: WallpaperSpot) {
        self.id = id; self.name = name; self.tagline = tagline; self.source = source; self.dark = dark
        self.ground = ground; self.sidebar = sidebar; self.surface = surface; self.raised = raised; self.line = line; self.line2 = line2
        self.text = text; self.text2 = text2; self.text3 = text3
        self.accent = accent; self.second = second; self.third = third; self.good = good; self.amber = amber; self.problem = problem
        self.graphs = graphs; selectionOverride = selection; onAccentOverride = onAccent; self.focus = focus; self.radius = radius; self.face = face
        self.wallpaper = wallpaper
    }

    /// A picked row or page: the accent at low strength, unless the theme sets its own (Toybox).
    public var selection: Paint { selectionOverride ?? Paint(accent, dark ? 0.16 : 0.14) }
    /// Text and icons on an accent fill.
    public var onAccent: UInt32 { onAccentOverride ?? ink(on: accent) }
    /// A glyph or words on a solid fill of `colour` (the accent, a Calm tile): the sidebar on a light colour in a dark
    /// theme, else white.
    public func ink(on colour: UInt32) -> UInt32 { dark && Contrast.luminance(Contrast.rgb(colour)) > 0.3 ? sidebar : 0xFFFFFF }
    /// A tile with no colour of its own (Plain text): on a dark theme the raised colour lifted 16 % toward white, else
    /// the second text.
    public var neutral: UInt32 { dark ? Contrast.hex(Contrast.mix([255, 255, 255], Contrast.rgb(raised), 0.16)) : text2 }
    /// The accent as text on a soft accent fill: itself on dark themes, deepened on light ones.
    public var accentText: UInt32 { dark ? accent : Contrast.hex(Contrast.mix(Contrast.rgb(accent), [0, 0, 0], 0.85)) }
    /// The hairline round a window or a panel.
    public var windowLine: Paint { dark ? Paint(0xFFFFFF, 0.09) : Paint(0x000000, 0.12) }
    /// A Calm key cap's face and its lit top edge.
    public var keyFill: UInt32 { dark ? Contrast.hex(Contrast.mix([255, 255, 255], Contrast.rgb(raised), 0.06)) : 0xFFFFFF }
    public var keyHighlight: Paint { dark ? Paint(0xFFFFFF, 0.07) : Paint(0xFFFFFF, 0.9) }
    /// Binds' module colours: Apps, Windows, Workspaces, Captures, System, Pilot.
    public var modules: [UInt32] { [accent, second, third, good, amber, problem] }

    /// A panel's corner: the panels' backdrop's (HUD.makePanel).
    public var panelRadius: Double { 18 * radius }

    /// A fresh install's theme, and every fallback's (Sven 2026-10-08: Lagoon, nearest round 4's Nightwatch).
    public static let defaultID = "lagoon"
    public static let standard = named(defaultID)!
    public static func named(_ id: String) -> PilotTheme? { designed.first { $0.id == id } }

    /// Round 4's themes, retired in round 15 (Sven 2026-10-08), each with the new theme closest to it.
    public static let retired = ["nightwatch": "lagoon", "ukiyo": "lagoon", "fjord": "lagoon", "teahouse": "phosphor",
                                 "understory": "phosphor", "crema": "garnet", "hearth": "dusk", "nocturne": "dusk",
                                 "boardwalk": "orchid", "graphite": "void", "paper": "workshop", "petal": "porcelain"]

    /// The theme a saved id means now: a designed one itself, a retired one its successor, anything else or nothing the
    /// default.
    public static func current(_ saved: String?) -> String {
        guard let saved else { return defaultID }
        return named(saved) != nil ? saved : retired[saved] ?? defaultID
    }

    /// The ten designed themes in Sven's order: round 15's eight, dark first, then Toybox Night and Toybox. Lagoon is the
    /// default.
    /// The designed themes this style can wear.
    public static func designed(for style: String) -> [PilotTheme] {
        designed.filter { ThemeNativePalette.stock($0.id).compatible(with: style) }
    }

    public static let designed: [PilotTheme] = [
        // Design round 15 (artifact Eh93LMpjwRxNRWnc8VHN47, Sven 2026-10-08): eight new themes, dark first.
        PilotTheme(id: "orchid", name: "Orchid", tagline: "Violet after midnight", source: "catppuccin", dark: true,
                   ground: 0x0D0A16, sidebar: 0x09070F, surface: 0x15111F, raised: 0x1E1829, line: 0x231C30, line2: 0x352B48,
                   text: 0xEDE9F5, text2: 0xBDB5CF, text3: 0x877F9F, accent: 0xA77BFF, second: 0xFF4F8B, third: 0xFF9CC0,
                   good: 0x7BE0A8, amber: 0xF5B970, problem: 0xFF5C7A, graphs: [0xA77BFF, 0xFF4F8B, 0x7BE0A8],
                   onAccent: 0x09070F, focus: .glow, radius: 1.0,
                   face: DisplayFace(family: "Recursive", file: "Recursive", weight: 700, scale: 1, tracking: -0.01, italic: false, axes: ["CASL": 1]),
                   wallpaper: WallpaperSpot(glow: 0xA77BFF, amount: 0.35, base: 0x0D0A16)),
        PilotTheme(id: "lagoon", name: "Lagoon", tagline: "Cold light, deep water", source: "lumon", dark: true,
                   ground: 0x07101A, sidebar: 0x050B13, surface: 0x0C1724, raised: 0x13202F, line: 0x162636, line2: 0x22374C,
                   text: 0xE4EEF5, text2: 0xA8BBCB, text3: 0x74899B, accent: 0x2BC4F0, second: 0x22C7A9, third: 0xF59BBB,
                   good: 0x22C7A9, amber: 0xF0C06A, problem: 0xFF7A85, graphs: [0x2BC4F0, 0x22C7A9, 0xF59BBB],
                   focus: .soft, radius: 1.0,
                   face: DisplayFace(family: "Bricolage Grotesque", file: "BricolageGrotesque", weight: 700, scale: 1, tracking: -0.025, italic: false, axes: [:]),
                   wallpaper: WallpaperSpot(glow: 0x2BC4F0, amount: 0.3, base: 0x07101A)),
        PilotTheme(id: "void", name: "Void", tagline: "Only the glass", source: "vantablack", dark: true,
                   ground: 0x000000, sidebar: 0x050505, surface: 0x0C0C0C, raised: 0x161616, line: 0x1A1A1A, line2: 0x2A2A2A,
                   text: 0xF2F2F2, text2: 0xB0B0B0, text3: 0x808080, accent: 0xE8E8E8, second: 0x8D8D8D, third: 0xBDBDBD,
                   good: 0x9BE3B4, amber: 0xE5C07B, problem: 0xFF6B6B, graphs: [0xE8E8E8, 0x8D8D8D, 0x9BE3B4],
                   focus: .lit, radius: 0.8,
                   face: DisplayFace(family: "Unbounded", file: "Unbounded", weight: 600, scale: 0.8, tracking: -0.02, italic: false, axes: [:]),
                   wallpaper: WallpaperSpot(glow: 0xFFFFFF, amount: 0.15, base: 0x000000)),
        PilotTheme(id: "phosphor", name: "Phosphor", tagline: "Green on black glass", source: "hackerman", dark: true,
                   ground: 0x070A08, sidebar: 0x040605, surface: 0x0D120F, raised: 0x141B16, line: 0x18211B, line2: 0x26332A,
                   text: 0xE6F0E8, text2: 0xA9B8AD, text3: 0x77857A, accent: 0x3BEA5C, second: 0xE0A46E, third: 0x6FC3FF,
                   good: 0x7FE3A0, amber: 0xE6B450, problem: 0xFF6B6B, graphs: [0x3BEA5C, 0xE0A46E, 0x6FC3FF],
                   focus: .lit, radius: 0.7,
                   face: DisplayFace(family: "Recursive", file: "Recursive", weight: 700, scale: 0.94, tracking: -0.02, italic: false, axes: ["MONO": 1]),
                   wallpaper: WallpaperSpot(glow: 0x3BEA5C, amount: 0.2, base: 0x070A08)),
        PilotTheme(id: "garnet", name: "Garnet", tagline: "Velvet and wine", source: "ristretto", dark: true,
                   ground: 0x100A0E, sidebar: 0x0B070A, surface: 0x181015, raised: 0x22171E, line: 0x281A23, line2: 0x3B2733,
                   text: 0xF4E9EE, text2: 0xC9B5BF, text3: 0x937D88, accent: 0xFF4775, second: 0xB58CFF, third: 0xFFB3C6,
                   good: 0x86D9A8, amber: 0xF2B266, problem: 0xFF6B5E, graphs: [0xFF4775, 0xB58CFF, 0x86D9A8],
                   onAccent: 0x0B070A, focus: .glow, radius: 0.9,
                   face: DisplayFace(family: "Young Serif", file: "YoungSerif", weight: 400, scale: 1, tracking: -0.01, italic: false, axes: [:]),
                   wallpaper: WallpaperSpot(glow: 0xFF4775, amount: 0.3, base: 0x100A0E)),
        PilotTheme(id: "dusk", name: "Dusk", tagline: "The last light", source: "last-horizon", dark: true,
                   ground: 0x0E0C0D, sidebar: 0x0A0809, surface: 0x161314, raised: 0x1F1B1C, line: 0x241F21, line2: 0x372F31,
                   text: 0xEFE6E2, text2: 0xC4B6B0, text3: 0x8D817C, accent: 0xE3A48F, second: 0x9FB4C8, third: 0xA7C4A0,
                   good: 0xA7C4A0, amber: 0xE8C07D, problem: 0xE07A6F, graphs: [0xE3A48F, 0x9FB4C8, 0xA7C4A0],
                   focus: .soft, radius: 1.1,
                   face: DisplayFace(family: "Instrument Serif", file: "InstrumentSerif", weight: 400, scale: 1.3, tracking: 0, italic: true, axes: [:]),
                   wallpaper: WallpaperSpot(glow: 0xE3A48F, amount: 0.3, base: 0x0E0C0D)),
        PilotTheme(id: "porcelain", name: "Porcelain", tagline: "Cool white, cobalt ink", source: "catppuccin-latte", dark: false,
                   ground: 0xEEF1F5, sidebar: 0xE3E7EE, surface: 0xFFFFFF, raised: 0xF3F5F8, line: 0xDCE1E8, line2: 0xC3CAD4,
                   text: 0x161A22, text2: 0x434B58, text3: 0x616875, accent: 0x1E5EF5, second: 0x8839EF, third: 0x0B8FA6,
                   good: 0x237633, amber: 0x935A0C, problem: 0xCE0F38, graphs: [0x1E5EF5, 0x8839EF, 0x2F9E44],
                   focus: .soft, radius: 1.0,
                   face: DisplayFace(family: "Fraunces", file: "Fraunces", weight: 600, scale: 1.04, tracking: -0.01, italic: false, axes: ["SOFT": 100]),
                   wallpaper: WallpaperSpot(glow: 0x1E5EF5, amount: 0.12, base: 0xE3E7EE)),
        PilotTheme(id: "workshop", name: "Workshop", tagline: "Graphite and orange tape", source: "white", dark: false,
                   ground: 0xF5F5F3, sidebar: 0xEDEDEA, surface: 0xFFFFFF, raised: 0xF2F2EF, line: 0xE4E4E0, line2: 0xD0D0CB,
                   text: 0x141415, text2: 0x56565C, text3: 0x6B6B70, accent: 0xE04E0C, second: 0x3A6FD8, third: 0x7A7A80,
                   good: 0x237A46, amber: 0x8F6208, problem: 0xC7352A, graphs: [0xE04E0C, 0x3A6FD8, 0x2E9E5B],
                   onAccent: 0x141415, focus: .brackets, radius: 0.7,
                   face: DisplayFace(family: "Syne", file: "Syne", weight: 700, scale: 0.95, tracking: -0.01, italic: false, axes: [:]),
                   wallpaper: WallpaperSpot(glow: 0xE04E0C, amount: 0.12, base: 0xEDEDEA)),
        // Toybox's mockup palette as themes (Sven, 2026-10-08): the Toybox style draws them exactly (StyleTokens.toyboxMockup).
        // The ink, never white, sits on the sun.
        PilotTheme(id: "toybox-night", name: "Toybox Night", tagline: "The toybox after bedtime", source: "catppuccin", dark: true,
                   ground: 0x15132A, sidebar: 0x1A1834, surface: 0x221F3E, raised: 0x2B2850, line: 0x312E40, line2: 0x3F3C4B,
                   text: 0xFFF4E2, text2: 0xC2BBDB, text3: 0x9690B4, accent: 0xFFC933, second: 0xA98BFF, third: 0x3FD7A0,
                   good: 0x46E0A6, amber: 0xFF9F4A, problem: 0xFF7F6E, graphs: [0x5BC0FF, 0xA98BFF, 0x3FD7A0],
                   onAccent: 0x221E35, focus: .ink, radius: 1.3,
                   face: DisplayFace(family: "Fredoka", file: "Fredoka", weight: 600, scale: 1, tracking: 0, italic: false, axes: [:]),
                   wallpaper: WallpaperSpot(glow: 0xFFC933, amount: 0.18, base: 0x15132A)),
        PilotTheme(id: "toybox", name: "Toybox", tagline: "Chunky keycaps, candy colours", source: "catppuccin-latte", dark: false,
                   ground: 0xFFF7EA, sidebar: 0xFFF0D6, surface: 0xFFFFFF, raised: 0xFBF3E4, line: 0xE4DDD4, line2: 0xD7D0C9,
                   text: 0x221E35, text2: 0x5F5A74, text3: 0x706B7F, accent: 0xFFC933, second: 0xA98BFF, third: 0x3FD7A0,
                   good: 0x167C57, amber: 0x995F2C, problem: 0xAB554A, graphs: [0x5BC0FF, 0xA98BFF, 0x3FD7A0],
                   selection: Paint(0xFFC933, 0.3), onAccent: 0x221E35, focus: .ink, radius: 1.3,
                   face: DisplayFace(family: "Fredoka", file: "Fredoka", weight: 600, scale: 1, tracking: 0, italic: false, axes: [:]),
                   wallpaper: WallpaperSpot(glow: 0xFFC933, amount: 0.2, base: 0xFFF0D6)),
        PilotTheme(id: "cinder", name: "Cinder", tagline: "Banked coals, cold ash", source: "cinder", dark: true,
                   ground: 0x111213, sidebar: 0x0B0C0D, surface: 0x191A1C, raised: 0x222427, line: 0x292B2E, line2: 0x3B3E42,
                   text: 0xEEF0F2, text2: 0xBFC3C8, text3: 0x92969D, accent: 0xFF7A1F, second: 0x8FB6C9, third: 0xF0A3B0,
                   good: 0x9CCF8A, amber: 0xFFC15E, problem: 0xFF6A55, graphs: [0xFF7A1F, 0x8FB6C9, 0x9CCF8A],
                   focus: .glow, radius: 0.9,
                   face: DisplayFace(family: "Bricolage Grotesque", file: "BricolageGrotesque", weight: 700, scale: 1, tracking: -0.025, italic: false, axes: [:]),
                   wallpaper: WallpaperSpot(glow: 0xFF7A1F, amount: 0.28, base: 0x111213)),
        PilotTheme(id: "verdigris", name: "Verdigris", tagline: "Old copper, gone green", source: "verdigris", dark: true,
                   ground: 0x0A1716, sidebar: 0x071110, surface: 0x0F1F1D, raised: 0x162A27, line: 0x1A302D, line2: 0x284540,
                   text: 0xE6F0EC, text2: 0xA9C2BB, text3: 0x759489, accent: 0xE9A06F, second: 0x5CD6B5, third: 0xF0B8C4,
                   good: 0x8FDC8C, amber: 0xE8C878, problem: 0xFF7B6E, graphs: [0xE9A06F, 0x5CD6B5, 0x8FDC8C],
                   focus: .soft, radius: 1.0,
                   face: DisplayFace(family: "Syne", file: "Syne", weight: 700, scale: 0.95, tracking: -0.01, italic: false, axes: [:]),
                   wallpaper: WallpaperSpot(glow: 0x5CD6B5, amount: 0.22, base: 0x0A1716)),
        PilotTheme(id: "cyanotype", name: "Cyanotype", tagline: "Prussian blue, white lines", source: "cyanotype", dark: true,
                   ground: 0x0E2A4F, sidebar: 0x0A2140, surface: 0x13335C, raised: 0x1B3F6E, line: 0x234A7A, line2: 0x335E93,
                   text: 0xF2F6FB, text2: 0xC3D3E6, text3: 0xA3BAD4, accent: 0xFFE08A, second: 0x7FD4FF, third: 0xFFB3C1,
                   good: 0x7FE3B0, amber: 0xFFC66E, problem: 0xFF9C92, graphs: [0xFFE08A, 0x7FD4FF, 0x7FE3B0],
                   focus: .brackets, radius: 0.6,
                   face: DisplayFace(family: "Recursive", file: "Recursive", weight: 700, scale: 0.94, tracking: -0.02, italic: false, axes: ["MONO": 1]),
                   wallpaper: WallpaperSpot(glow: 0x7FD4FF, amount: 0.25, base: 0x0E2A4F)),
        PilotTheme(id: "folio", name: "Folio", tagline: "Cream stock, oxblood ink", source: "folio", dark: false,
                   ground: 0xF5EFE2, sidebar: 0xECE4D3, surface: 0xFFFBF2, raised: 0xF0E9DA, line: 0xE0D7C4, line2: 0xCBBFA8,
                   text: 0x231C15, text2: 0x564A3D, text3: 0x6A5D4E, accent: 0x8E1F2F, second: 0x2F5D8A, third: 0x7A3E8C,
                   good: 0x28703E, amber: 0x7F5C05, problem: 0xAF3808, graphs: [0x8E1F2F, 0x2F5D8A, 0x28703E],
                   focus: .double, radius: 0.85,
                   face: DisplayFace(family: "Young Serif", file: "YoungSerif", weight: 400, scale: 1, tracking: -0.01, italic: false, axes: [:]),
                   wallpaper: WallpaperSpot(glow: 0x8E1F2F, amount: 0.1, base: 0xECE4D3)),
        PilotTheme(id: "celadon", name: "Celadon", tagline: "Pale glaze, pine shadow", source: "celadon", dark: false,
                   ground: 0xE4EDE6, sidebar: 0xD8E3DB, surface: 0xF5FAF6, raised: 0xECF2ED, line: 0xCFDBD2, line2: 0xB4C4B9,
                   text: 0x14241D, text2: 0x3E5247, text3: 0x4F665A, accent: 0x0B6B57, second: 0x2A5FA8, third: 0x9A3A78,
                   good: 0x1B7239, amber: 0x7A5900, problem: 0xB8321F, graphs: [0x0B6B57, 0x2A5FA8, 0x1B7239],
                   focus: .soft, radius: 1.15,
                   face: DisplayFace(family: "Fraunces", file: "Fraunces", weight: 600, scale: 1.04, tracking: -0.01, italic: false, axes: ["SOFT": 100]),
                   wallpaper: WallpaperSpot(glow: 0x0B6B57, amount: 0.14, base: 0xD8E3DB)),
        PilotTheme(id: "wisteria", name: "Wisteria", tagline: "Pale lilac, plum ink", source: "wisteria", dark: false,
                   ground: 0xECE8F5, sidebar: 0xE1DBEF, surface: 0xFBF9FE, raised: 0xF2EEF9, line: 0xD9D2E8, line2: 0xBFB6D4,
                   text: 0x211A33, text2: 0x4C4363, text3: 0x635A7A, accent: 0x6B2FA8, second: 0xA82673, third: 0x166A71,
                   good: 0x1F6A3F, amber: 0x825900, problem: 0xB01F43, graphs: [0x6B2FA8, 0xA82673, 0x1F6A3F],
                   focus: .frost, radius: 1.2,
                   face: DisplayFace(family: "Instrument Serif", file: "InstrumentSerif", weight: 400, scale: 1.3, tracking: 0, italic: false, axes: [:]),
                   wallpaper: WallpaperSpot(glow: 0x6B2FA8, amount: 0.14, base: 0xE1DBEF)),
    ]
}

/// WCAG contrast, as the artifact computes it (its lum() and ratio()), on 0 to 255 channels.
public enum Contrast {
    public static func rgb(_ hex: UInt32) -> [Double] { [Double(hex >> 16 & 0xFF), Double(hex >> 8 & 0xFF), Double(hex & 0xFF)] }
    /// Hue in degrees, saturation and lightness from 0 to 1.
    public static func hsl(_ hex: UInt32) -> (h: Double, s: Double, l: Double) {
        let c = rgb(hex).map { $0 / 255 }, top = c.max()!, bottom = c.min()!, span = top - bottom
        let l = (top + bottom) / 2
        guard span > 0 else { return (0, 0, l) }
        let h = top == c[0] ? (c[1] - c[2]) / span : top == c[1] ? 2 + (c[2] - c[0]) / span : 4 + (c[0] - c[1]) / span
        return ((h * 60 + 360).truncatingRemainder(dividingBy: 360), span / (1 - abs(2 * l - 1)), l)
    }
    /// "#rrggbb" as 0xRRGGBB.
    public static func hex(_ colour: String) -> UInt32 { UInt32(colour.dropFirst(), radix: 16) ?? 0 }
    public static func hex(_ c: [Double]) -> UInt32 {
        c.reduce(0) { $0 << 8 | UInt32(max(0, min(255, $1.rounded()))) }
    }
    /// `a` at `amount` over `b`.
    public static func mix(_ a: [Double], _ b: [Double], _ amount: Double) -> [Double] {
        zip(a, b).map { $0 * amount + $1 * (1 - amount) }
    }
    public static func luminance(_ c: [Double]) -> Double {
        let f = { (v: Double) in let v = v / 255; return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2])
    }
    public static func ratio(_ a: [Double], _ b: [Double]) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double { ratio(rgb(a), rgb(b)) }

    /// `colour` as text on every one of `grounds`: unchanged at 4.5:1 or more, else moved toward `ink` in 5 % steps
    /// until it reads, so a light theme's pale accent darkens only as far as it must.
    public static func readable(_ colour: String, on grounds: [String], toward ink: String) -> String {
        let start = rgb(hex(colour)), target = rgb(hex(ink)), backs = grounds.map { luminance(rgb(hex($0))) }
        for step in 0...20 {
            let c = rgb(hex(mix(target, start, Double(step) / 20)))  // As written: rounded to whole channels.
            let l = luminance(c)
            if backs.allSatisfy({ (max(l, $0) + 0.05) / (min(l, $0) + 0.05) >= 4.5 }) { return step == 0 ? colour : String(format: "#%06X", hex(c)) }
        }
        return ink
    }
}

/// The window's and the panels' material: Solid, or Glass (macOS 26's Liquid Glass), the Look page's Glass switch
/// (Sven, 2026-10-09: Tinted gone).
public enum WindowMaterial: String, CaseIterable, Sendable, Codable {
    case solid, glass
}

/// How much Glass blurs what is behind it, the Look page's Blur (Sven, 2026-11-01: "options for glass for transparency
/// and blur"): Full is Liquid Glass's regular style, the look until then; Light its clear style; Off no glass, the tint
/// alone over a sharp desktop. macOS gives Liquid Glass no blur radius, only these two styles.
public enum GlassBlur: String, CaseIterable, Sendable {
    case off, light, full

    public var title: String { rawValue.capitalized }
}

/// What a material at a strength means for a theme (the artifact's matVals()): how strong the window's ground is over
/// what is behind it, how strong tiles, cards and rows keep their own surface, and the body text's contrast on them.
/// The floor: surfaces stay at 72 % or more and rise in 2 % steps until body text reads at 4.5 : 1 against the
/// wallpaper's brightest spot; `raised` says the floor had to act. Increase contrast makes every surface solid.
public struct MaterialValues: Equatable, Sendable {
    /// Percent.
    public let windowAlpha, surfaceAlpha: Int
    public let contrast: Double
    public let raised: Bool

    public static let floor = 4.5
    /// Glass's ground, as a share of the strength.
    public static let glassShare = 0.55
    /// The window's ground in percent over Glass at `strength`.
    public static func windowAlpha(strength: Int) -> Int { Int((Double(strength) * glassShare).rounded()) }

    /// `strength` from 40 to 100; `spot` the wallpaper's brightest colour (0 to 255), the theme's own when nil.
    public init(theme t: PilotTheme, material: WindowMaterial, strength: Int, spot: [Double]? = nil, increaseContrast: Bool = false) {
        let text = Contrast.rgb(t.text2), surface = Contrast.rgb(t.surface)
        guard material != .solid else {
            (windowAlpha, surfaceAlpha, contrast, raised) = (100, 100, Contrast.ratio(text, surface), false)
            return
        }
        let ma = Self.windowAlpha(strength: strength)
        windowAlpha = ma
        if increaseContrast {
            (surfaceAlpha, contrast, raised) = (100, Contrast.ratio(text, surface), false)
            return
        }
        let behind = Contrast.mix(Contrast.rgb(t.ground), spot ?? t.wallpaper.colour, Double(ma) / 100)
        var ms = 72, lifted = false
        var cr = Contrast.ratio(text, Contrast.mix(surface, behind, Double(ms) / 100))
        while cr < Self.floor && ms < 100 {
            ms += 2; lifted = true
            cr = Contrast.ratio(text, Contrast.mix(surface, behind, Double(ms) / 100))
        }
        (surfaceAlpha, contrast, raised) = (ms, cr, lifted)
    }
}

/// The brightest spot of a wallpaper image, read from a small thumbnail (as blurred as the window shows it); nil when the
/// image cannot be read, so the theme's own wallpaper stands in.
public enum WallpaperBrightness {
    public static func brightest(_ url: URL) -> [Double]? {
        pixels(url, maxSize: 16)?.map { [Double($0.0), Double($0.1), Double($0.2)] }
            .max { Contrast.luminance($0) < Contrast.luminance($1) }
    }

    /// The image's pixels as sRGB (r, g, b), from a thumbnail at most `maxSize` wide or high; nil when it cannot be read.
    static func pixels(_ url: URL, maxSize: Int) -> [(UInt8, UInt8, UInt8)]? {
        guard let bytes = rgba(url, maxSize: maxSize)?.bytes else { return nil }
        return stride(from: 0, to: bytes.count, by: 4).map { (bytes[$0], bytes[$0 + 1], bytes[$0 + 2]) }
    }

    /// The image as sRGB RGBA bytes, top row first, from a thumbnail at most `maxSize` wide or high, with its size; nil
    /// when it cannot be read. `always` makes the thumbnail from the image itself, never a file's own small one (whose
    /// framing may differ: WallpaperStrip places it on the screen).
    static func rgba(_ url: URL, maxSize: Int, always: Bool = false) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [always ? kCGImageSourceCreateThumbnailFromImageAlways
                                                                                   : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: maxSize] as CFDictionary)
        else { return nil }
        let (w, h) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (bytes, w, h)
    }
}
