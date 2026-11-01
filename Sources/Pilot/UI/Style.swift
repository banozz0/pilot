import AppKit
import PilotCore
import SwiftUI

/// The style seam (story 137, ADR 0008, card agent-bo-95423180): every surface's root says which surface it is with
/// `styled(_:)`, which puts the picked style into the environment. A view reads `@Environment(\.style)`'s tokens for colours
/// and faces and draws its type with `styleText` and its raised blocks with `styleSurface`.
extension StyleTokens {
    func color(_ role: KeyPath<StyleColors, Paint>) -> Color { Color(colors[keyPath: role]) }

    /// A row's or a control's height drawn by hand: `points` times the surface's scale (C3), whole points.
    func points(_ points: CGFloat) -> CGFloat { (points * scale).rounded() }

    /// Toybox's bundled faces (Toy.nunito, fredoka, mono) at `size` times the surface's scale (C3): one step bigger in the
    /// window, its pages and the menu, as they were on the panels, the bar and the HUDs.
    @MainActor func toyNunito(_ weight: Int, _ size: CGFloat) -> Font { Toy.nunito(weight, size * scale) }
    @MainActor func toyFredoka(_ size: CGFloat) -> Font { Toy.fredoka(size * scale) }
    @MainActor func toyMono(_ size: CGFloat, bold: Bool = false) -> Font {
        Font(DisplayFaces.font(StyleTokens.jetBrainsMono(bold ? 700 : 500), size: size * scale))
    }

    /// The role's face at its size: the system's, the theme's display face, the picked monospace family or a bundled face.
    @MainActor
    func font(_ role: KeyPath<StyleTypography, TypeRole>) -> Font { Self.font(type[keyPath: role]) }

    /// The role's face at `size` instead of its own (the top bar's readouts, a chip's smaller digits).
    @MainActor
    func font(_ role: KeyPath<StyleTypography, TypeRole>, size: Double) -> Font {
        var role = type[keyPath: role]
        role.size = size * scale
        return Self.font(role)
    }

    @MainActor
    private static func font(_ role: TypeRole) -> Font {
        let size = CGFloat(role.size)
        switch role.face {
        case .system(let weight): return .system(size: size, weight: Font.Weight(css: weight))
        case .bundled(let face): return Font(DisplayFaces.font(face, size: size))
        }
    }

    /// The role's face at its size as AppKit's, for measuring text as `font(_:)` draws it.
    @MainActor
    static func nsFont(_ role: TypeRole) -> NSFont {
        let size = CGFloat(role.size)
        switch role.face {
        case .system(let weight): return .systemFont(ofSize: size, weight: NSFont.Weight(css: weight))
        case .bundled(let face): return DisplayFaces.font(face, size: size)
        }
    }

    /// The role's tracking in points.
    func tracking(_ role: KeyPath<StyleTypography, TypeRole>) -> CGFloat {
        let role = type[keyPath: role]
        return role.size * role.tracking
    }

    /// Instrument in the default theme: what a view sees before any styled(_:) above it.
    static let unstyled = StyleTokens.of(.instrument, theme: .standard)
}

extension EnvironmentValues {
    /// The style this part of a surface draws in; styled(_:) sets it.
    @Entry var style = StyleTokens.unstyled
    /// The app window's layers (Transparency, round 15) under its frame and pages, which styled(_:) hands down; nil on
    /// the bar, the panels and anything floating, so the theme's layered roles (Theme) stay whole there.
    @Entry var windowLayers: Layers? = nil
    /// The glass's tint behind a panel's face (Glass everywhere, Sven 2026-10-19, Q356): set by styled(_:) on the
    /// Hyper+Space menu, clipboard history and quick notes while Look's Glass is on; nil elsewhere, solid.
    @Entry var glassFace: NSColor? = nil
}

extension NSFont.Weight {
    /// A CSS weight, 100 to 900, as the system face's nearest.
    init(css: Int) {
        self = switch css {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }
}

extension Font.Weight {
    /// A CSS weight, 100 to 900, as the system face's nearest.
    init(css: Int) {
        self = switch css {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }
}

extension View {
    /// This view is `surface`: it draws in the picked style and follows a new pick at once.
    func styled(_ surface: StyleSurface, look: Look = .shared) -> some View {
        modifier(Styled(surface: surface, look: look))
    }

    /// Draws what is under it in `tokens`: the style environment, and the system controls dark or light with it.
    func style(_ tokens: StyleTokens) -> some View {
        environment(\.style, tokens).environment(\.colorScheme, tokens.dark ? .dark : .light)
    }

    /// Text in a style's type role: its face, size and tracking, in capitals where the role is.
    func styleText(_ role: KeyPath<StyleTypography, TypeRole>) -> some View { modifier(StyleText(role: role)) }

    /// A raised block in the style's depth recipe: its fill and corner, Toybox's ink outline and solid bottom edge (which
    /// take room inside the block, as a CSS border does), Instrument's hairline ring and soft shadows.
    func styleSurface(_ depth: KeyPath<StyleDepths, StyleDepth>, fill: KeyPath<StyleColors, Paint> = \.panel,
                      radius: KeyPath<StyleRadii, Double> = \.card, shadows: Bool = true) -> some View {
        modifier(StyleSurfaceBlock(depth: depth, fill: fill, radius: radius, shadows: shadows))
    }
}

private struct Styled: ViewModifier {
    let surface: StyleSurface
    let look: Look

    func body(content: Content) -> some View {
        // The window and its pages take its Transparency (round 15; only Instrument's tokens change).
        let tokens = StyleTokens.of(look.style, theme: look.theme)
        let layers = surface.layers(look)
        // The window, its pages and the menu one step bigger (C3, PilotStyle.scale), pilotTheme()'s 13 pt text with them.
        content.style((layers.map(tokens.seeThrough) ?? tokens).scaled(surface.scale))
            .transformEnvironment(\.font) { if surface.scale != 1 { $0 = .system(size: 13 * surface.scale) } }
            .environment(\.windowLayers, layers)
            .environment(\.glassFace, look.glassFace(surface) ? look.glassTint(on: surface) : nil)
    }
}

extension StyleSurface {
    /// The window's layers on the app window's frame and its pages, which Transparency reaches, and on the panels Glass
    /// reaches while it is on (Look.glassPanels, Q356); nil on the bar, the HUDs and the rest, which keep their own.
    @MainActor func layers(_ look: Look) -> Layers? {
        if case .page = self { return look.layers }
        return self == .window || look.glassFace(self) ? look.layers : nil
    }
}

extension View {
    /// Something floating over the window's content (a popover, a sheet, a popup): solid whatever the window's
    /// Transparency, as a panel is.
    func floating() -> some View { modifier(FloatingSurface()) }
}

struct FloatingSurface: ViewModifier {
    @Environment(\.style) private var style
    @Environment(\.windowLayers) private var layers

    func body(content: Content) -> some View {
        content.environment(\.windowLayers, nil).environment(\.glassFace, nil)
            .environment(\.style, Self.solid(style, layers: layers, look: .shared))
    }

    /// `style` without the window's see-through: Instrument's tokens made afresh (seeThrough is a post-process on them),
    /// any other as they are.
    static func solid(_ style: StyleTokens, layers: Layers?, look: Look) -> StyleTokens {
        guard style.kind == .instrument, layers != nil else { return style }
        return .of(.instrument, theme: look.theme)
    }
}

private struct StyleText: ViewModifier {
    @Environment(\.style) private var style
    let role: KeyPath<StyleTypography, TypeRole>

    func body(content: Content) -> some View {
        content.font(style.font(role)).tracking(style.tracking(role))
            .textCase(style.type[keyPath: role].uppercase ? .uppercase : nil)
    }
}

private struct StyleSurfaceBlock: ViewModifier {
    @Environment(\.style) private var style
    let depth: KeyPath<StyleDepths, StyleDepth>
    let fill: KeyPath<StyleColors, Paint>
    let radius: KeyPath<StyleRadii, Double>
    /// False draws the block without its depth's shadows (the menu's face).
    let shadows: Bool

    func body(content: Content) -> some View {
        let d = style.depth[keyPath: depth], r = style.radii[keyPath: radius]
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        let face = style.color(fill)
        let border = EdgeInsets(top: d.outline, leading: d.outline, bottom: d.edge, trailing: d.outline)
        return content
            .padding(border)
            .background {
                ZStack {
                    ForEach(Array((shadows ? d.shadows : []).enumerated()), id: \.offset) { _, s in
                        // A shadow with no blur is a solid edge: drawn as one, with no shadow pass.
                        if s.radius == 0 { shape.fill(Color(s.color)).offset(y: s.y) }
                        else { shape.fill(face).shadow(color: Color(s.color), radius: s.radius, y: s.y) }
                    }
                    if d.outline > 0 || d.edge > 0 { shape.fill(style.color(\.outline)) }
                    RoundedRectangle(cornerRadius: max(r - d.outline, 0), style: .continuous).fill(face).padding(border)
                }
            }
            .litTop(shape, d.highlight.map { Color($0) })
            .overlay { if let ring = d.ring { shape.strokeBorder(Color(ring), lineWidth: 1) } }
    }
}

/// A restyled panel's chrome (ADR 0008; the menu in Instrument, card agent-bo-95423181): its face in the style's panel
/// colour at the pop radius on the pop depth (Instrument's hairline ring and long soft shadow, Toybox's outline and
/// edge), its content clipped to it, in clear margins that hold the shadow. InstrumentMenu draws on it; HUD.makePanel
/// sizes a restyled surface's window for the margins.
enum PopSurface {
    /// The room the pop shadows reach past the face: each side its blur, the top its blur less its drop, the foot both.
    static func margins(_ tokens: StyleTokens) -> NSEdgeInsets {
        let shadows = tokens.depth.pop.shadows
        let side = shadows.map(\.radius).max() ?? 0
        return NSEdgeInsets(top: shadows.map { max(0, $0.radius - $0.y) }.max() ?? 0, left: side,
                            bottom: shadows.map { $0.radius + $0.y }.max() ?? 0, right: side)
    }

    /// The window's size for a face of `size` with `margins` round it.
    static func window(_ size: CGSize, _ margins: NSEdgeInsets) -> CGSize {
        CGSize(width: size.width + margins.left + margins.right, height: size.height + margins.top + margins.bottom)
    }

    /// The face's rect in a window `frame` with `margins` round it (AppKit's coordinates, the foot at minY).
    static func face(_ frame: CGRect, _ margins: NSEdgeInsets) -> CGRect {
        CGRect(x: frame.minX + margins.left, y: frame.minY + margins.bottom,
               width: frame.width - margins.left - margins.right, height: frame.height - margins.top - margins.bottom)
    }
}

extension View {
    /// This panel's content on its style's pop face, in `margins` for its shadow (PopSurface.margins); without `shadows`,
    /// the face alone (the menu's).
    func popSurface(_ margins: NSEdgeInsets, shadows: Bool = true) -> some View { modifier(PopSurfaceFace(margins: margins, shadows: shadows)) }
}

private struct PopSurfaceFace: ViewModifier {
    @Environment(\.style) private var style
    @Environment(\.glassFace) private var glass
    let margins: NSEdgeInsets
    let shadows: Bool

    func body(content: Content) -> some View {
        let m = margins
        let insets = EdgeInsets(top: m.top, leading: m.left, bottom: m.bottom, trailing: m.right)
        // On Glass the face is the top bar's glass and nothing more (Sven, Q356): no fill, ring or shadow over it, the
        // glass's own edge its edge. It follows the face's frame, so Line's plate keeps it as it morphs.
        if let glass {
            let radius = style.radii.pop
            return AnyView(content.clipShape(.rect(cornerRadius: radius, style: .continuous))
                .background(GlassFace(tint: glass, cornerRadius: radius))
                .padding(insets))
        }
        // Clipped to the face inside the outline (Toybox's 2 pt ink; Instrument has none), so a fill reaching the edge
        // leaves no sliver of the panel colour in the corners.
        return AnyView(content.clipShape(.rect(cornerRadius: style.radii.pop - style.depth.pop.outline, style: .continuous))
            .styleSurface(\.pop, fill: \.panel, radius: \.pop, shadows: shadows)
            .padding(insets))
    }
}

/// The top bar's material as a SwiftUI background: an NSGlassEffectView in Look's Blur's style, tinted, at `cornerRadius`
/// (the same view MaterialBackdrop puts behind the window and the bar), or at Blur Off the tint alone. Offscreen the glass
/// draws a flat grey: Sven's screen proves it.
struct GlassFace: View {
    let tint: NSColor
    let cornerRadius: CGFloat

    var body: some View {
        if let style = Look.shared.glassBlur.effectStyle {
            GlassEffect(tint: tint, cornerRadius: cornerRadius, style: style)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color(nsColor: tint))
        }
    }
}

extension GlassBlur {
    /// The glass's style at this blur, nil at Off: AppKit's for MaterialBackdrop and GlassFace, SwiftUI's for the widgets.
    var effectStyle: NSGlassEffectView.Style? { self == .off ? nil : self == .light ? .clear : .regular }
    var glass: Glass? { self == .off ? nil : self == .light ? .clear : .regular }
}

private struct GlassEffect: NSViewRepresentable {
    let tint: NSColor
    let cornerRadius: CGFloat
    let style: NSGlassEffectView.Style

    func makeNSView(context: Context) -> NSGlassEffectView { NSGlassEffectView() }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        if view.tintColor != tint { view.tintColor = tint }
        if view.cornerRadius != cornerRadius { view.cornerRadius = cornerRadius }
        if view.style != style { view.style = style }
    }
}
