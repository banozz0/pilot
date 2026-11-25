import PilotCore
import SwiftUI

/// A page's colours and faces by the style it draws in (card agent-bo-95423182, ADR 0008): the style's role under
/// Instrument. A view takes it with `@Environment(\.ink) private var ink` and writes `ink.text`, and its structure
/// (cards, rows, chips) comes from the Kit.
@MainActor
struct Ink {
    let style: StyleTokens

    var isInstrument: Bool { style.kind == .instrument }

    var background: Color { style.color(\.canvas) }
    var sidebar: Color { style.color(\.sidebar) }
    /// Tiles, cards and rows: the theme's surface, a style's panel.
    var raised: Color { style.color(\.panel) }
    /// Chips, key caps and segments: the theme's raised colour, a style's cap.
    var selected: Color { style.color(\.raised) }
    /// A key cap's face: the theme's key fill, a style's key.
    var keyFill: Color { style.color(\.key) }
    var line: Color { style.color(\.line) }
    var line2: Color { style.color(\.line2) }
    /// A dashed spot's line.
    var line3: Color { style.color(\.line3) }
    var text: Color { style.color(\.text) }
    var text2: Color { style.color(\.text2) }
    var muted: Color { style.color(\.text3) }
    /// A row's second words: muted, or the ink on the sun at 72 % on a picked row.
    func rowQuiet(_ selected: Bool) -> Color { selected && !isInstrument ? onAccent.opacity(0.72) : muted }
    /// A row's lit part: `colour`, or the ink on the sun on a picked row (Instrument raises a picked row instead of filling
    /// it, so its colours stand).
    func rowLit(_ selected: Bool, _ colour: Color) -> Color { selected && !isInstrument ? onAccent : colour }
    /// A link's words ("Show all", "Settings"): the accent's ink, but Instrument's second text colour.
    var link: Color { isInstrument ? text2 : accentInk }
    /// A mark inside words (a quicklink's {query}, a config's key): `colour`, or Instrument's text colour, as its signal is
    /// never decoration (mockup A: Hyper, live and selected alone).
    func mark(_ colour: Color) -> Color { isInstrument ? text : colour }
    /// The accent as a fill (a bar, a dot, a selection).
    var accent: Color { style.color(\.accent) }
    /// The accent as words or a glyph on the page.
    var accentInk: Color { style.color(\.accentText) }
    var accentText: Color { style.color(\.accentText) }
    var onAccent: Color { style.color(\.onAccent) }
    var selection: Color { style.color(\.accentSoft) }
    var green: Color { style.color(\.good) }
    var yellow: Color { style.color(\.warn) }
    /// A warning as words or a glyph on a panel: a style's darker accent ink.
    var warnText: Color { style.color(\.accentText) }
    var red: Color { style.color(\.problem) }
    /// An action that ends something (a destructive button, its confirm): red in every style, Instrument's too, whose
    /// problem colour is otherwise its signal (SPEC story 165).
    var destructive: Color { isInstrument ? Theme.red : red }
    /// A window's or picture's edge.
    var windowLine: Color { style.color(\.outline) }
    /// The ink outline round a raised thing.
    var outline: Color { style.color(\.outline) }
    /// A card's or a picture's edge: a style's ink outline.
    var edge: Color { style.color(\.outline) }
    /// The width of a picked card's ring: Instrument's 1.5 pt signal ring.
    var pickedStroke: CGFloat { InstrumentBar.ring }

    /// A page column's side inset: a style's gutter level with its frame's title (Instrument's page inset under its
    /// toolbar's title).
    var pageInset: CGFloat { style.density.page }

    /// A hand-built page column's top inset: Instrument's under its toolbar's hairline (InstrumentPage's), else `other`.
    func pageTop(_ other: CGFloat) -> CGFloat { isInstrument ? style.density.padding : other }

    /// A corner: Instrument's `role`, else `other`.
    func corner(_ other: @autoclosure () -> CGFloat, _ role: KeyPath<StyleRadii, Double>) -> CGFloat {
        isInstrument ? style.radii[keyPath: role] : other()
    }

    /// A block's corner: a style's card.
    var blockRadius: CGFloat { style.radii.card }

    /// An outline's width: Instrument's hairline.
    var stroke: CGFloat { 1 }

    /// A block's own fill: a style's panel.
    var surface: Color { style.color(\.panel) }
    /// A well sunk into a card (a workspace's screen) and a tile raised in it (a window): Instrument's well and tile, as
    /// Home draws them.
    var well: Color { style.color(style.kind == .instrument ? \.well : \.sidebar) }
    var tile: Color { style.color(style.kind == .instrument ? \.tile : \.panel) }

    /// A module's colour (a part's squircle): the style's candy colour.
    func module(_ i: Int) -> Color { Color(style.colors.modules[i % style.colors.modules.count]) }
    /// A chart's line: the style's candy colours in Home's order (CPU, memory, disk, then heat).
    func graph(_ i: Int) -> Color { module([0, 1, 4, 2, 3, 5][i % 6]) }
    func tag(_ i: Int) -> Color { module([5, 2, 0, 3, 1, 4][i % 6]) }
    /// A small corner: Instrument's as drawn.
    func radius(_ base: CGFloat) -> CGFloat { base }

    // MARK: Faces

    /// The window's words: Geist under Instrument.
    func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let size = size * style.scale
        return Font(DisplayFaces.font(StyleTokens.geist(weight == .regular ? 400 : weight == .medium ? 500 : 600), size: size))
    }

    /// Ids, paths and numbers: the style's mono.
    func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let size = size * style.scale
        // Light weights for an extension's big figures (Q475, the Omarchy weather look): the variable face's 200 and 300.
        let wght = switch weight {
        case .ultraLight, .thin: 200
        case .light: 300
        case .regular: 400
        default: 500
        }
        return Font(DisplayFaces.font(StyleTokens.geistMono(wght), size: size))
    }

    /// A title or a big number: Geist under Instrument.
    func display(_ size: CGFloat) -> Font {
        let size = size * style.scale
        return Font(DisplayFaces.font(StyleTokens.geist(500), size: size))
    }

    func displayTracking(_ size: CGFloat) -> CGFloat {
        let size = size * style.scale
        return style.kind == .instrument ? -0.02 * size : 0
    }

    // MARK: Scale (C3)

    /// The system face at `size` points times the surface's scale: what `.system(size:)` draws, one step bigger in the
    /// app window and the menu (PilotStyle.scale), as it was everywhere else.
    func system(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size * style.scale, weight: weight) }
    /// Pilot's monospace face (Theme.mono) at `size` times the surface's scale.
    func themeMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { Theme.mono(size * style.scale, weight: weight) }
    /// A row's or a control's height, a glyph's box: `points` times the surface's scale, whole points.
    func points(_ points: CGFloat) -> CGFloat { style.points(points) }
}

extension EnvironmentValues {
    /// The style's colours and faces for a page body.
    @MainActor var ink: Ink { Ink(style: style) }
}

