import Foundation

/// How Pilot draws (story 137, ADR 0008, card agent-bo-95423180; Sven approved the styles and their order 2026-10-08):
/// Instrument (a graphite panel, one orange signal that means Hyper) and Toybox (chunky keycaps with an ink outline and a
/// solid bottom edge); Current, today's look before them, was removed 2026-10-11 (parked on parked/current-style-tiling-rice).
/// The style decides shape, type, spacing and depth; the theme decides every colour and whether it is dark or light (Sven,
/// 2026-10-09: no switch).
public enum PilotStyle: String, CaseIterable, Sendable, Codable {
    case instrument, toybox

    public var title: String { rawValue.capitalized }
    public var tagline: String {
        switch self {
        case .instrument: "Hairlines, mono numbers, one signal colour"
        case .toybox: "Chunky keycaps, candy colours"
        }
    }

    /// A saved pick: Current, removed 2026-10-11, and anything unknown read as Instrument, the default.
    public init(saved: String?) { self = saved.flatMap(Self.init(rawValue:)) ?? .instrument }

    /// One step up the type scale, 13 pt body to 14, for the app window and the Hyper+Space menu (C3, Sven 2026-10-10:
    /// "NOT HUGE just a bit bigger"): StyleSurface.scale hands it to those surfaces, whose tokens (StyleTokens.scaled) and
    /// faces (Ink) multiply every size, row and control by it, and the menu's panel grows with its rows (MenuPanelSize).
    /// 1 puts them back as they were.
    public static let scale = 14.0 / 13.0
}

/// One compatible palette memory for native style changes and the isolated public-boundary proof.
public struct ThemeStyleMemory: Codable, Sendable {
    public var choices: [String: ThemeNativePalette] = [:]
    public init() {}
    public mutating func select(from previous: String, to next: String, current: ThemeNativePalette) throws -> ThemeNativePalette {
        guard PilotStyle(rawValue: previous) != nil, PilotStyle(rawValue: next) != nil else { throw ThemeFailure("unknown style") }
        try current.validate()
        if current.compatible(with: previous) { choices[previous] = current }
        if let saved = choices[next]?.current, saved.compatible(with: next) { try saved.validate(); return saved }
        return current.compatible(with: next) ? current : .stock(PilotTheme.defaultID)
    }
}

/// One thing Pilot draws that a style restyles as a whole: each page of the app window, the window's own frame (its
/// sidebar), the Hyper+Space menu, the top bar's strip (its tooltips and edit mode too), the dropdowns and
/// popovers hung from a bar item in either bar (Pilot's dropdown, the readings', the clock's...), the hold overlay, the
/// clipboard panel, the notes panel, the AI chat, the HUDs (tips, alerts, prompts), onboarding, and an extension's
/// detail view in the menu's panel (card agent-bo-95423245). The strip and its popovers are two surfaces so each can be
/// restyled on its own (Instrument's strip before its popovers, card agent-bo-95423181, 2026-10-08).
public enum StyleSurface: Hashable, Sendable, CaseIterable {
    case page(AppPage), window, menu, topBar, barPopovers, overlay, clipboard, notes, quickAI, hud, onboarding, extensionDetail

    public static let allCases: [StyleSurface] = AppPage.allCases.map(StyleSurface.page)
        + [.window, .menu, .topBar, .barPopovers, .overlay, .clipboard, .notes, .quickAI, .hud, .onboarding, .extensionDetail]

    /// How much bigger the surface draws than its style's own sizes: the app window, its pages, the Hyper+Space menu and
    /// an extension's detail in it one step (PilotStyle.scale); the bar, the panels and the HUDs as they were.
    public var scale: Double {
        switch self {
        case .page, .window, .menu, .extensionDetail: PilotStyle.scale
        case .topBar, .barPopovers, .overlay, .clipboard, .notes, .quickAI, .hud, .onboarding: 1
        }
    }
}

/// A style's colour roles, the union of both mockups' custom properties (Instrument's src/common.css and Toybox's); a
/// role one mockup has no word for is named where it is set.
public struct StyleColors: Equatable, Sendable {
    /// The window's ground, Calm's sidebar, a panel or card, a key cap or chip, a well sunk into the ground.
    public var canvas, sidebar, panel, raised, sunken: Paint
    /// Hairlines, faint to strong; `outline` is Toybox's ink edge and solid bottom edge.
    public var line, line2, line3, outline: Paint
    public var text, text2, text3, text4: Paint
    /// The one signal colour; its text on a soft fill, the ink on it, its soft fill, its line, Toybox's darker edge under it.
    public var accent, accentText, onAccent, accentSoft, accentLine, accentEdge: Paint
    /// Instrument's primary button: the text colour as a fill.
    public var inverse, onInverse: Paint
    /// A Hyper key cap's fill and its label: Toybox's solid sun cap, the others' soft accent with accent text.
    public var hyper, onHyper: Paint
    public var good, warn, problem: Paint
    /// The line round an app icon or a picture, a sheet's dimming, a bound key's cap and a free one's, and the hairline
    /// round a free key on Binds' keyboard.
    public var imageOutline, scrim, key, keyFree, keyRing: Paint
    /// A switch's knob; a well sunk into a panel (Home's workspace screens) and a tile raised in it (a window); a chart's
    /// bars where none is lit.
    public var knob, well, tile, bar: Paint
    /// Binds' module colours and their soft fills: Apps, Windows, Workspaces, Captures, System, Pilot.
    public var modules, moduleSoft: [Paint]
    /// A bound key's fill on Binds' keyboard by its module, in `modules`' order, and the ink on it, strong and second
    /// (Q252: bound keys always stand out by their group's colour).
    public var groups: [Paint]
    public var onGroup, onGroup2: Paint
    /// Each app window page's tile in the window's sidebar, in AppPage's order.
    public var pageTiles: [Paint]
    /// Binds' keyboard case, the frame its keys sit in: Toybox's grape case, Instrument's panel.
    public var board: Paint
}

/// Where a type role's face comes from.
public enum StyleFace: Equatable, Sendable {
    /// The system face at a CSS weight (400 regular to 900 black).
    case system(Int)
    /// A face bundled in Pilot.app's Resources/Fonts (OFL), at its own weight.
    case bundled(DisplayFace)
}

/// One type role: face, size in points, tracking in em, and whether it is set in capitals.
public struct TypeRole: Equatable, Sendable {
    public var face: StyleFace
    public var size: Double
    public var tracking: Double
    public var uppercase: Bool
    public init(face: StyleFace, size: Double, tracking: Double = 0, uppercase: Bool = false) {
        self.face = face; self.size = size; self.tracking = tracking; self.uppercase = uppercase
    }
}

/// A style's type roles: body text, its strong weight, a row's second line, the smallest words (a window's title on a
/// workspace screen, a kind beside a copy), a panel's title, a page's title, the big readouts and greeting, numbers and
/// ids, the small capitals over a group, a key cap's label, a line icon leading a row (a sidebar page, a search field),
/// what is typed into the Hyper+Space menu's search, a menu row's title, a bind's short name on Binds' keyboard, and the
/// top bar's small capitals beside a reading, its strong words (the app in front), its clock and countdown, and its glyphs
/// (Instrument's bar reads them; Toybox's bar keeps ToyBar's own faces, the same values).
public struct StyleTypography: Equatable, Sendable {
    public var body, strong, caption, small, title, pageTitle, display, mono, eyebrow, key, icon, search, row, keyName: TypeRole
    public var barLabel, barStrong, barTime, barIcon: TypeRole
}

/// Corner radii in points: buttons and fields, key caps, small chips, cards and panels, the menu and popovers, Binds'
/// keyboard case.
public struct StyleRadii: Equatable, Sendable {
    public var control, key, chip, card, pop, board: Double
}

/// A soft shadow: its colour, blur radius (half the CSS blur) and drop.
public struct StyleShadow: Equatable, Sendable {
    public var color: Paint
    public var radius, y: Double
}

/// How a raised thing stands off what is under it: Toybox's `outline` (points, in the outline colour) and solid bottom
/// `edge` (points below the face, the same colour), Instrument's hairline `ring` and soft `shadows`; a lit top
/// `highlight` hairline over a see-through window (StyleTokens.seeThrough).
public struct StyleDepth: Equatable, Sendable {
    public var outline: Double
    public var edge: Double
    public var ring: Paint?
    public var shadows: [StyleShadow]
    public var highlight: Paint?
    public init(outline: Double = 0, edge: Double = 0, ring: Paint? = nil, shadows: [StyleShadow] = [], highlight: Paint? = nil) {
        self.outline = outline; self.edge = edge; self.ring = ring; self.shadows = shadows; self.highlight = highlight
    }
}

/// Depth by what is raised: cards and panels, buttons and fields, key caps and chips, the menu and popovers, Binds'
/// keyboard case and the keys on it (deeper than a chip's, ADR 0008).
public struct StyleDepths: Equatable, Sendable {
    public var card, control, key, pop, board, boardKey: StyleDepth
}

/// Spacing in points: a list row's and a control's height, the gap between blocks, a block's inner padding, the page's.
public struct StyleDensity: Equatable, Sendable {
    public var row, control, gap, padding, page: Double
}

/// Everything a restyled surface draws from: one style in one theme, dark or light as the theme is.
/// The tokens live in one shared box: a view holding them (`@Environment(\.style)` keeps its value inline) copies one
/// reference, not a hundred-odd fields, and its compiled copy and destroy code shrinks with it (about 13 KB a view type,
/// 2026-10-16).
public struct StyleTokens: Equatable, Sendable {
    private final class Box: Sendable {
        let kind: PilotStyle
        let dark: Bool
        let colors: StyleColors
        let type: StyleTypography
        let radii: StyleRadii
        let depth: StyleDepths
        let density: StyleDensity
        init(kind: PilotStyle, dark: Bool, colors: StyleColors, type: StyleTypography, radii: StyleRadii, depth: StyleDepths,
             density: StyleDensity) {
            self.kind = kind; self.dark = dark; self.colors = colors; self.type = type; self.radii = radii; self.depth = depth
            self.density = density
        }
    }
    private let box: Box

    init(kind: PilotStyle, dark: Bool, colors: StyleColors, type: StyleTypography, radii: StyleRadii, depth: StyleDepths,
         density: StyleDensity) {
        box = Box(kind: kind, dark: dark, colors: colors, type: type, radii: radii, depth: depth, density: density)
    }

    /// Which style these are; a restyled view branches on it only where the two new styles really differ.
    public var kind: PilotStyle { box.kind }
    public var dark: Bool { box.dark }
    public var colors: StyleColors { box.colors }
    public var type: StyleTypography { box.type }
    public var radii: StyleRadii { box.radii }
    public var depth: StyleDepths { box.depth }
    public var density: StyleDensity { box.density }

    public static func == (a: StyleTokens, b: StyleTokens) -> Bool {
        a.scale == b.scale && a.inked == b.inked && (a.box === b.box || (a.kind == b.kind && a.dark == b.dark && a.colors == b.colors
            && a.type == b.type && a.radii == b.radii && a.depth == b.depth && a.density == b.density))
    }

    /// What every size here was multiplied by (scaled(_:)): 1 as a style is drawn, PilotStyle.scale in the app window and
    /// the menu; Ink's faces take it too, so a view's own point sizes grow with the tokens.
    public internal(set) var scale: Double = 1
    /// Recoloured for a bar colour the theme did not pick (inked(on:)): a view that keeps the theme's own colours (Theme)
    /// takes these instead.
    public internal(set) var inked = false

    /// These tokens with `type` in place of their own, at the same scale: the Hyper+Space menu's Classic face, JetBrains
    /// Mono in every role (menu Rail and Classic T8).
    public func retyped(_ type: StyleTypography) -> StyleTokens {
        var tokens = StyleTokens(kind: kind, dark: dark, colors: colors, type: type, radii: radii, depth: depth, density: density)
        tokens.scale = scale
        tokens.inked = inked
        return tokens
    }

    /// These tokens with every type role's size, a row's and a control's height times `factor` (C3): the surface one
    /// step bigger, its colours, corners and depth as they were.
    public func scaled(_ factor: Double) -> StyleTokens {
        guard factor != 1 else { return self }
        var type = type
        for role: WritableKeyPath<StyleTypography, TypeRole> in [\.body, \.strong, \.caption, \.small, \.title, \.pageTitle, \.display, \.mono,
                                                                 \.eyebrow, \.key, \.icon, \.search, \.row, \.keyName, \.barLabel, \.barStrong,
                                                                 \.barTime, \.barIcon] {
            type[keyPath: role].size = (type[keyPath: role].size * factor * 2).rounded() / 2
        }
        var density = density
        (density.row, density.control) = ((density.row * factor).rounded(), (density.control * factor).rounded())
        var tokens = StyleTokens(kind: kind, dark: dark, colors: colors, type: type, radii: radii, depth: depth, density: density)
        tokens.scale = scale * factor
        tokens.inked = inked
        return tokens
    }

    /// `style`'s tokens in `theme`, dark or light as the theme is: Instrument's colours from it (instrumentColors),
    /// Toybox's too (the Toybox themes its mockup palette).
    public static func of(_ style: PilotStyle, theme: PilotTheme) -> StyleTokens {
        switch style {
        case .instrument: instrument(theme)
        case .toybox: toybox(theme: theme)
        }
    }

    // MARK: Faces

    /// A bundled face: its file is the family without spaces.
    static func face(_ family: String, _ weight: Int) -> DisplayFace {
        DisplayFace(family: family, file: family.replacing(" ", with: ""), weight: weight, scale: 1, tracking: 0, italic: false, axes: [:])
    }
    public static func geist(_ weight: Int) -> DisplayFace { face("Geist", weight) }
    public static func geistMono(_ weight: Int) -> DisplayFace { face("Geist Mono", weight) }
    public static func fredoka(_ weight: Int) -> DisplayFace { face("Fredoka", weight) }
    public static func nunito(_ weight: Int) -> DisplayFace { face("Nunito", weight) }
    public static func jetBrainsMono(_ weight: Int) -> DisplayFace { face("JetBrains Mono", weight) }
    /// The bundled files the styles draw with, one face each.
    public static let faces = [geist(400), geistMono(400), fredoka(600), nunito(600), jetBrainsMono(500)]

    // MARK: Instrument (mockup A: pilot-redesign-A/NOTES.md, src/common.css)

    /// Instrument's colours from the picked theme (coordinator's call for Sven, 2026-10-08: the style decides shape, type,
    /// spacing and depth, the theme decides colour everywhere), with the mockup's discipline: one signal, the theme's
    /// accent, for Hyper, live and selected alone; no status colours (good, warn and problem reuse it) and no module colour
    /// (every module the second text colour); Hyper's cap the accent soft; a bound key raised, a free one sunk. The
    /// sidebar is the theme's own when it has one a step off its ground, else a step darker (lighter on a light theme's
    /// paper, darker still) than the ground. On a ground too near black to darken (Void), the sidebar and the sunk well step toward white. Mockup A's graphite and orange is closest to the Graphite theme.
    public static func instrumentColors(_ t: PilotTheme) -> StyleColors {
        let dark = t.dark
        let p = { Paint($0) }
        /// `c` a step toward black (or `toward`) by `amount`.
        let step = { (c: UInt32, amount: Double, toward: UInt32) in Paint(Contrast.hex(Contrast.mix(Contrast.rgb(toward), Contrast.rgb(c), amount))) }
        let accent = p(t.accent), raised = p(t.raised), panel = p(t.surface), text2 = p(t.text2)
        // A ground too near black to darken visibly (Void's pure black) steps its sidebar and well a little toward white
        // instead, just enough to read (coordinator for Sven, 2026-10-08).
        let nearBlack = Contrast.rgb(t.ground).allSatisfy { $0 < 8 }
        let sidebar = t.sidebar != t.ground ? p(t.sidebar)
            : nearBlack ? step(t.ground, 0.02, 0xFFFFFF) : step(t.ground, dark ? 0.2 : 0.04, 0x000000)
        let sunken = nearBlack ? step(t.ground, 0.035, 0xFFFFFF) : step(t.ground, dark ? 0.25 : 0.04, 0x000000)
        let soft = Paint(t.accent, dark ? 0.13 : 0.09)
        return StyleColors(
            canvas: p(t.ground), sidebar: sidebar, panel: panel, raised: raised, sunken: sunken,
            line: p(t.line), line2: p(t.line2), line3: step(t.line2, 0.35, t.text3), outline: p(t.line2),
            text: p(t.text), text2: text2, text3: p(t.text3), text4: step(t.text3, 0.5, t.ground),
            accent: accent, accentText: p(t.accentText), onAccent: p(t.onAccent),
            accentSoft: soft, accentLine: Paint(t.accent, dark ? 0.6 : 0.55), accentEdge: accent,
            inverse: p(t.text), onInverse: p(t.ground), hyper: soft, onHyper: p(t.accentText),
            good: accent, warn: accent, problem: accent,
            imageOutline: t.windowLine, scrim: Paint(0x000000, dark ? 0.5 : 0.25),
            key: raised, keyFree: sunken, keyRing: p(dark ? t.line : t.line2),
            knob: Paint(0xFFFFFF), well: sunken, tile: dark ? raised : panel, bar: p(t.line2),
            modules: Array(repeating: text2, count: 6), moduleSoft: Array(repeating: raised, count: 6),
            // The 3D keyboard mockup's round 2 (--g-apps … --g-sys, oklch): Apps amber, Windows blue, Workspaces violet,
            // Captures red, System its media green, Pilot slate; fixed in every theme so white ink reads on the dark set
            // and ink on the light one (each at least 5.6:1), Void's near-white accent included.
            groups: (dark ? [0x9C5400, 0x2A669F, 0x6E519D, 0xAB4043, 0x2A7449, 0x466270]
                          : [0xF1C189, 0xA2CDF2, 0xCEBEEF, 0xF7B3B0, 0xA1DBB4, 0xC1D1D8]).map { Paint($0) },
            onGroup: Paint(dark ? 0xFFFFFF : 0x141415), onGroup2: Paint(dark ? 0xFFFFFF : 0x141415, dark ? 0.72 : 0.66),
            pageTiles: Array(repeating: text2, count: AppPage.allCases.count),
            // binds.html's keyboard sits on a .panel.
            board: panel)
    }

    /// Instrument in `theme`'s colours (instrumentColors), dark or light as the theme is; its type, corners, depth and
    /// density are mockup A's.
    private static func instrument(_ theme: PilotTheme) -> StyleTokens {
        let dark = theme.dark
        let line2 = Paint(theme.line2)
        let colors = instrumentColors(theme)
        let type = StyleTypography(
            body: TypeRole(face: .bundled(geist(400)), size: 13), strong: TypeRole(face: .bundled(geist(500)), size: 13),
            caption: TypeRole(face: .bundled(geist(400)), size: 12), small: TypeRole(face: .bundled(geist(400)), size: 11),
            title: TypeRole(face: .bundled(geist(600)), size: 13),
            pageTitle: TypeRole(face: .bundled(geist(600)), size: 15, tracking: -0.005),
            display: TypeRole(face: .bundled(geist(500)), size: 38, tracking: -0.03),
            mono: TypeRole(face: .bundled(geistMono(400)), size: 11.5),
            eyebrow: TypeRole(face: .bundled(geistMono(500)), size: 10.5, tracking: 0.08, uppercase: true),
            key: TypeRole(face: .bundled(geistMono(500)), size: 10.5),
            // Lucide's 15 px line icons at stroke 1.5 beside 13 px text, as SF Symbols' regular weight draws them.
            icon: TypeRole(face: .system(400), size: 13.5),
            // menu.html's .q .txt and .r .ttl.
            search: TypeRole(face: .bundled(geist(450)), size: 18, tracking: -0.01), row: TypeRole(face: .bundled(geist(500)), size: 13.5),
            // binds.html's .k .lb.
            keyName: TypeRole(face: .bundled(geist(500)), size: 10.5, tracking: -0.01),
            // topbar.html's .tb-rd em, .tb-app b, .tb-time b and .tb-focus b, and its 14 px lucide glyphs at stroke 1.75.
            barLabel: TypeRole(face: .bundled(geistMono(500)), size: 9.5, tracking: 0.06, uppercase: true),
            barStrong: TypeRole(face: .bundled(geist(600)), size: 12),
            barTime: TypeRole(face: .bundled(geistMono(500)), size: 12),
            barIcon: TypeRole(face: .system(400), size: 12.5))
        // --key-shadow; a light card adds a 1 px shadow under its ring. The mockup's --pop soft shadow is gone: no Pilot
        // pop-up casts a shadow (Sven on build 29), so a pop is its hairline ring alone.
        let depth = StyleDepths(
            card: StyleDepth(ring: colors.line, shadows: dark ? [] : [StyleShadow(color: Paint(0, 0.03), radius: 1, y: 1)]),
            control: StyleDepth(ring: line2),
            key: StyleDepth(ring: line2, shadows: [StyleShadow(color: Paint(0, dark ? 0.4 : 0.06), radius: 0, y: 1)]),
            pop: StyleDepth(ring: theme.windowLine),
            board: StyleDepth(ring: colors.line),
            boardKey: StyleDepth(ring: line2, shadows: [StyleShadow(color: Paint(0, dark ? 0.4 : 0.06), radius: 0, y: 1)]))
        return StyleTokens(kind: .instrument, dark: dark, colors: colors, type: type,
                           radii: StyleRadii(control: 6, key: 6, chip: 4, card: 10, pop: 14, board: 10), depth: depth,
                           density: StyleDensity(row: 30, control: 28, gap: 8, padding: 18, page: 28))
    }

    // MARK: Toybox (mockup B: pilot-redesign-B/NOTES.md, src/common.css)

    /// Depth from a 2 px ink outline and a solid bottom edge, never blur. Its hairlines are the ink at low strength (the
    /// rail's separator), its accent text the dark edge's sun so it reads on cream, its inverse the clock's ink pill.
    private static func toybox(dark: Bool) -> StyleTokens {
        let outline = Paint(dark ? 0x08070F : 0x221E35), text = Paint(dark ? 0xFFF4E2 : 0x221E35)
        let sun = Paint(0xFFC933), sunk = Paint(dark ? 0x1A1834 : 0xFFF0D6), text2 = Paint(dark ? 0xC2BBDB : 0x5F5A74)
        let moduleSoft = (dark ? [0x1E3A57, 0x312858, 0x173F38, 0x48262C, 0x46213D, 0x463A18]
                               : [0xD9F1FF, 0xECE5FF, 0xD4F7EA, 0xFFE2DD, 0xFFE2F2, 0xFFF0C4]).map { Paint($0) }
        let colors = StyleColors(
            canvas: Paint(dark ? 0x15132A : 0xFFF7EA), sidebar: sunk, panel: Paint(dark ? 0x221F3E : 0xFFFFFF),
            raised: Paint(dark ? 0x2B2850 : 0xFFFFFF), sunken: sunk,
            line: Paint(text.rgb, 0.12), line2: Paint(text.rgb, 0.18), line3: Paint(text.rgb, 0.3), outline: outline,
            text: text, text2: text2, text3: Paint(dark ? 0x8D86AD : 0x8F89A3), text4: Paint(dark ? 0x8D86AD : 0x8F89A3),
            accent: sun, accentText: dark ? sun : Paint(0xA87400), onAccent: Paint(0x221E35), accentSoft: Paint(dark ? 0x463A18 : 0xFFF0C4),
            accentLine: Paint(dark ? 0xA87400 : 0xD99A00), accentEdge: Paint(dark ? 0xA87400 : 0xD99A00),
            inverse: text, onInverse: Paint(dark ? 0x15132A : 0xFFFFFF), hyper: sun, onHyper: Paint(0x221E35),
            good: Paint(dark ? 0x46E0A6 : 0x1FAF7A), warn: sun, problem: Paint(0xFF7F6E),
            imageOutline: outline, scrim: dark ? Paint(0x05040E, 0.45) : Paint(0x221E35, 0.28),
            key: Paint(dark ? 0x2B2850 : 0xFFFFFF), keyFree: Paint(dark ? 0x1E1C3A : 0xFBF3E4), keyRing: outline,
            // common.css's .switch knob; the sunk surface and a key cap in it; the ink at low strength for bars.
            knob: Paint(0xFFFFFF), well: sunk, tile: Paint(dark ? 0x2B2850 : 0xFFFFFF), bar: Paint(text.rgb, 0.18),
            modules: [0x5BC0FF, 0xA98BFF, 0x3FD7A0, 0xFF7F6E, 0xFF79C0, 0xFFC933].map { Paint($0) },
            moduleSoft: moduleSoft,
            // ToyBoardKey's module soft fills with the text on them.
            groups: moduleSoft, onGroup: text, onGroup2: text2,
            // Each page's candy in AppPage's order, every page its own: the mockup's NAV colours where its page kept them
            // (C3 moved the pages: Home sun, Binds grape, Workspaces mint, Menu bar sky), then round the wheel; Snippets
            // salmon and Files sage came with the Tools group, Stats' blush after Activity (2026-10-10), Captures' rose after
            // Clipboard, Voice's periwinkle after AI (2026-10-16); Agent instructions' seafoam left with its page (2026-10-17); Update & Clean's
            // lime after Activity (2026-10-20); Widgets' slate last (2026-10-31); Repos' jade and Fonts' rose after Configs (2026-11-01);
            // Pilot menu's deep sky after Menu bar's (2026-11-12); Dock's cornflower between them (2026-11-13).
            pageTiles: [0xFFC933, 0xA98BFF, 0xFF79C0, 0x3FD7A0, 0x6FE3C1, 0x5BC0FF, 0x69B7FF, 0x4FA3E0, 0xD98CFF, 0xA5DC50, 0xF0567A, 0xC8F05A, 0xFFB3E6, 0x3CD2DB, 0xFF6F91,
                        0xFF8A65, 0xFFB347, 0xB0E0A0, 0x8EE3F0, 0x9FB4FF, 0xFF9F4A, 0x7B8CFF, 0xE0C46B, 0x7FD8A8, 0xF28CB1, 0xC9C4E4, 0xE3A86B, 0x96A9C8]
                .map { Paint($0) },
            // binds.html's .board: the Windows grape, a deep indigo in the dark.
            board: Paint(dark ? 0x3A3270 : 0xA98BFF))
        let type = StyleTypography(
            body: TypeRole(face: .bundled(nunito(600)), size: 14), strong: TypeRole(face: .bundled(nunito(800)), size: 14),
            caption: TypeRole(face: .bundled(nunito(700)), size: 12), small: TypeRole(face: .bundled(nunito(700)), size: 11.5),
            title: TypeRole(face: .bundled(fredoka(600)), size: 20, tracking: -0.005),
            pageTitle: TypeRole(face: .bundled(fredoka(600)), size: 34), display: TypeRole(face: .bundled(fredoka(600)), size: 44),
            mono: TypeRole(face: .bundled(jetBrainsMono(500)), size: 12),
            eyebrow: TypeRole(face: .bundled(nunito(800)), size: 11.5, tracking: 0.09, uppercase: true),
            key: TypeRole(face: .bundled(nunito(800)), size: 12), icon: TypeRole(face: .system(600), size: 16),
            // What ToyMenuSearch and ToyMenuRow draw (menu.html's .q, 30 px in the mockup, and .item .tx b).
            search: TypeRole(face: .bundled(fredoka(600)), size: 26), row: TypeRole(face: .bundled(nunito(800)), size: 14.5),
            // ToyBoardKey's names at their largest (ToyBoardFit.sizes).
            keyName: TypeRole(face: .bundled(nunito(800)), size: 11.5),
            // ToyBar's (ToyBarParts): a label, the island's words, the clock in Fredoka, its glyphs.
            barLabel: TypeRole(face: .bundled(nunito(800)), size: 9.5), barStrong: TypeRole(face: .bundled(nunito(800)), size: 12.5),
            barTime: TypeRole(face: .bundled(fredoka(600)), size: 14.5), barIcon: TypeRole(face: .system(700), size: 12))
        let depth = StyleDepths(card: StyleDepth(outline: 2, edge: 5), control: StyleDepth(outline: 2, edge: 4),
                                key: StyleDepth(outline: 2, edge: 4), pop: StyleDepth(outline: 2, edge: 7),
                                board: StyleDepth(outline: 2, edge: 7), boardKey: StyleDepth(outline: 2, edge: 5))
        return StyleTokens(kind: .toybox, dark: dark, colors: colors, type: type,
                           radii: StyleRadii(control: 14, key: 12, chip: 8, card: 22, pop: 22, board: 30), depth: depth,
                           density: StyleDensity(row: 40, control: 40, gap: 12, padding: 20, page: 28))
    }
    private static let toyboxDark = toybox(dark: true), toyboxLight = toybox(dark: false)

    /// Toybox's mockup palette, dark or light: the look Sven approved, and the shape every theme's Toybox keeps.
    public static func toyboxMockup(dark: Bool) -> StyleTokens { dark ? toyboxDark : toyboxLight }
    /// The themes that carry Toybox's mockup palette.
    public static let toyboxThemes: Set<String> = ["toybox", "toybox-night"]

    /// Toybox in `t` (Sven, 2026-10-08): the theme decides every colour and its dark or light, the style its shape, type,
    /// depth and spacing. The ink outline is the ground at a third in the dark, the text in the light; words on a fill
    /// stay readable (the accent deepened or lifted until it reads at 4.5:1 on a panel).
    static func toybox(theme t: PilotTheme) -> StyleTokens {
        let dark = t.dark, shape = toyboxMockup(dark: dark)
        // The Toybox themes are the mockup's palette: drawn exactly as approved.
        if toyboxThemes.contains(t.id) { return shape }
        func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 { Contrast.hex(Contrast.mix(Contrast.rgb(a), Contrast.rgb(b), amount)) }
        /// A colour's soft fill on a panel.
        func soft(_ c: UInt32) -> Paint { Paint(mix(c, t.surface, dark ? 0.24 : 0.2)) }
        var accentText = t.accent
        for _ in 0..<12 where Contrast.ratio(accentText, t.surface) < 4.5 { accentText = mix(accentText, dark ? 0xFFFFFF : 0x000000, 0.85) }
        let outline = Paint(dark ? mix(t.ground, 0x000000, 0.35) : t.text), text = Paint(t.text)
        let key = Paint(dark ? t.raised : t.surface), edge = Paint(mix(t.accent, 0x000000, 0.72))
        let modules = t.modules.map { Paint($0) }
        let colors = StyleColors(
            canvas: Paint(t.ground), sidebar: Paint(t.sidebar), panel: Paint(t.surface), raised: key, sunken: Paint(t.sidebar),
            line: Paint(t.text, 0.12), line2: Paint(t.text, 0.18), line3: Paint(t.text, 0.3), outline: outline,
            text: text, text2: Paint(t.text2), text3: Paint(t.text3), text4: Paint(t.text3),
            accent: Paint(t.accent), accentText: Paint(accentText), onAccent: Paint(t.onAccent),
            accentSoft: soft(t.accent), accentLine: edge, accentEdge: edge,
            inverse: text, onInverse: Paint(t.ground), hyper: Paint(t.accent), onHyper: Paint(t.onAccent),
            good: Paint(t.good), warn: Paint(t.amber), problem: Paint(t.problem),
            imageOutline: outline, scrim: dark ? Paint(0x000000, 0.45) : Paint(t.text, 0.28),
            key: key, keyFree: Paint(mix(t.ground, t.sidebar, 0.5)), keyRing: outline,
            knob: Paint(0xFFFFFF), well: Paint(t.sidebar), tile: key, bar: Paint(t.text, 0.18),
            modules: modules, moduleSoft: t.modules.map(soft), groups: t.modules.map(soft), onGroup: text, onGroup2: Paint(t.text2),
            pageTiles: AppPage.allCases.map { modules[$0.colour % modules.count] },
            // The Windows module (Toybox's grape case), sunk toward the ground in the dark.
            board: Paint(dark ? mix(t.second, t.ground, 0.45) : t.second))
        return StyleTokens(kind: .toybox, dark: dark, colors: colors, type: shape.type, radii: shape.radii, depth: shape.depth,
                           density: shape.density)
    }
}
