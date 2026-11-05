import AppKit
import PilotCore
import SwiftUI

/// The app's look (design round 4, card agent-bo-95422890): every colour reads the theme Look holds, so each surface
/// redraws on a pick or a package's Apply. Today's names map onto the theme's roles (background is the ground, raised
/// the surface tiles and cards sit on, selected the raised fill of chips and keys); the round 4
/// roles sit beside them. System text, keys and numbers mono, titles in the theme's display face.
@MainActor
enum Theme {
    private static var colors: ThemeColors { Look.shared.colors }
    static var theme: PilotTheme { Look.shared.theme }
    static var background: Color { colors.ground }
    static var sidebar: Color { colors.sidebar }
    /// Tiles, cards and rows: the theme's surface.
    static var raised: Color { colors.surface }
    /// Chips, key caps, segments and the selected sidebar row's fill: the theme's raised colour, at the raised layer's
    /// strength inside a see-through app window (Layered).
    static var selected: Color { Color(Layered(colour: colors.raised, role: .raised)) }
    /// Tiles, cards and rows on a block: the surface at the card layer's strength inside the app window, at the window
    /// material's surface strength elsewhere, as before Transparency.
    static var cardFill: Color {
        Color(Layered(colour: colors.surface, role: .card, elsewhere: Double(Look.shared.materialValues.surfaceAlpha) / 100))
    }
    static var line: Color { colors.line }
    static var line2: Color { colors.line2 }
    static var text: Color { colors.text }
    static var text2: Color { colors.text2 }
    static var muted: Color { colors.text3 }
    static var accent: Color { colors.accent }
    static var second: Color { colors.second }
    static var third: Color { colors.third }
    static var green: Color { colors.good }
    static var yellow: Color { colors.amber }
    static var red: Color { colors.problem }
    /// A bound key cap's face, at the raised strength inside a see-through app window.
    static var keyFill: Color { Color(Layered(colour: colors.keyFill, role: .raised)) }
    static var keyHighlight: Color { colors.keyHighlight }
    /// Graph `i` (0 CPU, 1 Memory, 2 Network, then round again).
    static func graph(_ i: Int) -> Color { colors.graphs[i % colors.graphs.count] }
    /// Binds' module colours: 0 Apps, 1 Windows, 2 Workspaces, 3 Captures, 4 System, 5 Pilot.
    static func module(_ i: Int) -> Color { colors.modules[i % colors.modules.count] }
    /// Clipboard tags' colours, ClipTag.colours of them: the theme's accents and states, then its graphs and text.
    static func tag(_ index: Int) -> Color {
        let colours = [accent, green, yellow, red, second, third, graph(2), text2]
        return colours[index % colours.count]
    }
    /// Text on an accent fill.
    static var onAccent: Color { colors.onAccent }
    /// `base` scaled by the theme's radius (Phosphor's sharp corners, Toybox's round ones).
    static func radius(_ base: CGFloat) -> CGFloat { base * theme.radius }
    /// `colour` at a role's `strength`; the colour itself when whole, so a solid window draws exactly today's colours.
    nonisolated static func layer(_ colour: Color, _ strength: Double) -> Color { strength < 1 ? colour.opacity(strength) : colour }

    /// A window's or panel's own ground over its material: whole when Solid, none over Glass, whose tint carries it.
    static func windowFill(_ colour: Color, panel: Bool = false, look: Look = .shared) -> Color {
        switch panel ? look.effectiveMaterial : look.windowMaterial {
        case .solid: return colour
        case .glass: return .clear
        }
    }

    static var windowBackground: NSColor { NSColor(background) }
    /// Dark or light with the theme, so system controls match it.
    static var appearance: NSAppearance? { appearance(.shared) }
    static func appearance(_ look: Look) -> NSAppearance? { NSAppearance(named: look.theme.dark ? .darkAqua : .aqua) }

    /// JetBrains Mono when installed (Sven has it), else the system monospace face, at the same size (Look.monoFont); the
    /// mono picked in Use fonts in over both (PilotFonts).
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        PilotFonts.shared.face(.mono, size, weight) ?? Font(Look.shared.monoFont(size: size, medium: weight != .regular))
    }

    /// The theme's display face at `size` points before its scale; use `.display(size)` to get its tracking too.
    static func display(_ size: CGFloat, face: DisplayFace? = nil) -> Font {
        let face = face ?? theme.face
        return Font(DisplayFaces.font(face, size: size * face.scale))
    }

    /// The display face's own tracking at `size` points, in points.
    static func displayTracking(_ size: CGFloat, face: DisplayFace? = nil) -> CGFloat {
        let face = face ?? theme.face
        return size * face.scale * face.tracking
    }

    /// A row's second line: small and muted.
    static let detail = Font.system(size: 12)
}

extension View {
    /// Text in the theme's display face (theme names, page titles, the greeting), with the face's own tracking.
    func display(_ size: CGFloat, face: DisplayFace? = nil) -> some View {
        let face = face ?? Theme.theme.face
        return font(Theme.display(size, face: face)).tracking(Theme.displayTracking(size, face: face))
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    init(_ paint: Paint) { self.init(hex: paint.rgb, opacity: paint.alpha) }
    /// This colour as 0xRRGGBB in sRGB, rounded.
    var rgb: UInt32 {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return 0 }
        return Contrast.hex([c.redComponent, c.greenComponent, c.blueComponent].map { Double($0) * 255 })
    }
}

/// A rounded raised block; rows inside are split by hairlines.
struct Card<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View {
        let rows = VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { ink.line.frame(height: 1) }
                    row
                }
            }
        }
        // The style's block surface (Toybox's chunk).
        rows.frame(maxWidth: .infinity, alignment: .leading).styleSurface(\.card)
    }
}

/// One line of a card: content left, controls right, at least 38 pt high (times the surface's scale).
struct CardRow<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    /// The row's side padding, for what sits over it (This Mac's numbers).
    static var padding: CGFloat { 12 }
    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.horizontal, Self.padding).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: ink.points(38), alignment: .leading)
    }
}

/// A labelled group of cards: the small muted title above.
struct PageSection<Content: View>: View {
    let title: String
    /// One muted line under the title saying what the section shows.
    var note: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: title)
            if let note { FinePrint(text: note) }
            content
        }
    }
}

/// The small muted title over a group of cards; PageSection's, and the Binds page's pinned headings.
struct SectionTitle: View {
    @Environment(\.ink) private var ink
    let text: String
    var body: some View {
        Text(text).font(ink.ui(12, .medium)).foregroundStyle(ink.muted).padding(.leading, 2)
    }
}

/// An action's bind as a key cap, or when it has none a Set key chip that opens Binds' editor on it, as Abilities' Set
/// key does (Sven 2026-10-11). A default key another action holds says so before the chip (Build 56: Ask AI about
/// selected text had no key, Sound settings held Hyper+Ctrl+A, and only the log said it).
struct BindKey: View {
    @Environment(\.ink) private var ink
    /// None offscreen, where a page is drawn without an engine.
    @Environment(Engine.self) private var engine: Engine?
    let action: String
    var body: some View {
        if let key = engine?.binds.store.trigger(for: action)?.label { Kbd(text: key) } else {
            HStack(spacing: 8) {
                if let engine, let refused = engine.binds.store.refusal(for: action) {
                    Text(Self.taken(refused, engine: engine)).font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1)
                }
                Button { AppWindowController.shared.open(AppPlace(.binds), editBind: action) } label: { Chip(text: "Set key", symbol: "plus") }
                    .buttonStyle(.kitPress).help("Opens Binds' editor on it").accessibilityLabel("Set a key")
            }
        }
    }

    /// "Hyper+Ctrl+A is Sound settings' key".
    static func taken(_ refused: BindStore.Refusal, engine: Engine) -> String {
        "\(refused.trigger.label) is \(engine.action(refused.takenBy)?.label ?? refused.takenBy)'s key"
    }
}

/// A muted note under a card, as the mockup's fine print.
struct FinePrint: View {
    @Environment(\.ink) private var ink
    let text: String
    /// The muted ink when nil.
    var color: Color?
    var body: some View {
        Text(text).font(ink.ui(12)).foregroundStyle(color ?? ink.muted).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
    }
}

extension View {
    /// A text field as the mockup draws one: sunk into the page's background with a hairline edge.
    func pilotField() -> some View { modifier(PilotField()) }
}

/// A field in the style: Toybox's sunk well with the ink outline, else today's.
private struct PilotField: ViewModifier {
    @Environment(\.style) private var style
    func body(content: Content) -> some View {
        if style.kind == .toybox {
            content.textFieldStyle(.plain).font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .toyWell(radius: 10)
        } else if style.kind == .instrument {
            content.textFieldStyle(.plain).font(style.font(\.body)).foregroundStyle(style.color(\.text))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .instrumentWell()
        } else { content.currentPilotField() }
    }
}

extension View {
    fileprivate func currentPilotField() -> some View { modifier(CurrentPilotField()) }
}

extension View {
    /// Under a password field of Pilot's own, while it has the keyboard: the one line that says why Hyper waits (T48,
    /// Sven Q836). Goes after the field's own look, so the line sits under the well, never in it.
    func secureFieldTip() -> some View { modifier(SecureFieldTip()) }
}

extension EnvironmentValues {
    /// Draws the tip as if the field had the keyboard: a render's, as an offscreen window never takes focus.
    @Entry var showsSecureFieldTip = false
}

/// macOS turns secure input on while a password field has the keyboard, and the tap is blind until it goes off
/// (SecureInputMonitor): the field says so itself, as the monitor's HUD tip skips Pilot's own fields.
private struct SecureFieldTip: ViewModifier {
    @Environment(\.showsSecureFieldTip) private var forced
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content.focused($focused)
            if focused || forced { SecureFieldTipLine() }
        }
    }
}

/// The tip's line, for a field that already tracks its own focus (an extension's secret setting).
struct SecureFieldTipLine: View {
    var body: some View {
        FinePrint(text: "macOS turns key taps off while a password field has the keyboard, so Hyper waits until you leave the field.")
    }
}

private struct CurrentPilotField: ViewModifier {
    @Environment(\.ink) private var ink
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(ink.system(12.5))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.background, in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2) }
    }
}

extension View {
    /// Pilot's look for everything under it: the theme's text and accent, 13 pt system text, dark or light with the theme
    /// whatever the Mac's appearance. The app window, onboarding, the sheets and the panels all start from it.
    func pilotTheme(look: Look = .shared) -> some View {
        foregroundStyle(Theme.text)
            .tint(Theme.accent)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .environment(\.colorScheme, look.theme.dark ? .dark : .light)
    }

    /// Every page's switches and buttons are the window's (card agent-bo-95422728); a page may still pick another. A Menu
    /// under it takes the system's switches back (menuRows).
    func pilotWindowStyles() -> some View { toggleStyle(.pilotSwitchRow).buttonStyle(.pilot) }

    /// A sheet over the window (the bind editor, a new web app): its grouped form on Tokyo Night with the window's
    /// switches. The form's rows stay the system's, which a custom background cannot reach, and its buttons stay the
    /// system's so Save keeps the default button's look.
    func pilotSheet() -> some View {
        toggleStyle(.pilotSwitchRow)
            .buttonStyle(.automatic)
            .pilotTheme()
            .background(Theme.background)
    }
}

/// The page body every page shares: padded, top to bottom, scrolling when the window is short; Instrument's level with
/// its toolbar's inset.
struct PageBody<Content: View>: View {
    @Environment(\.style) private var style
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View {
        if style.kind == .instrument { InstrumentPage(spacing: style.density.gap * 2) { content } } else { toybox }
    }

    private var toybox: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                // Toybox's column sits level with the frame's title, 32 in (ToyPage).
                .padding(.horizontal, ink.pageInset).padding(.top, 10).padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A row's title with an optional muted line under it.
struct TitledText: View {
    @Environment(\.ink) private var ink
    /// Styled when it needs to be, such as the clipboard panel's row with its search matches lit.
    let title: Text
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            title
            if let detail { Text(detail).font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

extension TitledText {
    init(title: String, detail: String? = nil) { self.init(title: Text(title), detail: detail) }
}

/// `colour` at a layer's strength where styled(_:) hands the app window's layers down (Transparency, round 15), at
/// `elsewhere` on the bar, the panels and anything floating, so the see-through stays inside the window.
private nonisolated struct Layered: ShapeStyle, Hashable {
    let colour: Color
    enum Role { case card, well, raised }
    let role: Role
    var elsewhere = 1.0

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let strength = environment.windowLayers.map { l in
            switch role {
            case .card: l.card
            case .well: l.well
            case .raised: l.raised
            }
        }
        return Theme.layer(colour, strength ?? elsewhere).resolve(in: environment)
    }
}
