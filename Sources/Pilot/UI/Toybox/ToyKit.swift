import Clipboard
import PilotCore
import SwiftUI

/// Toybox's parts (card agent-bo-95423182, mockup B: pilot-redesign-B/src/common.css): every raised thing is a keycap with
/// a 2 pt ink outline and a solid bottom edge, never a blur. Each part reads the style environment, so it is drawn only
/// inside a surface drawn in Toybox.
enum Toy {
    /// A module's colour and its soft fill, by BindsKeyboard.modules' order: Apps, Windows, Workspaces, Captures, System, Pilot.
    static func module(_ i: Int, _ style: StyleTokens) -> Color { Color(style.colors.modules[i % style.colors.modules.count]) }
    static func moduleSoft(_ i: Int, _ style: StyleTokens) -> Color { Color(style.colors.moduleSoft[i % style.colors.moduleSoft.count]) }
    /// A page's tile colour in the window's sidebar (AppPage's order); the clipboard panel's search tile too.
    static func pageTile(_ page: AppPage, _ style: StyleTokens) -> Color {
        // A page with no tile of its own draws quiet rather than indexing past the list.
        let tiles = style.colors.pageTiles, i = AppPage.allCases.firstIndex(of: page) ?? 0
        return Color(tiles.indices.contains(i) ? tiles[i] : style.colors.text2)
    }

    /// A copy's kind as a module: a link the Apps sky, an image the Windows grape, text the Workspaces mint, a file the
    /// Captures coral, an email or a colour the System pink (Home's clipboard card, the clipboard panel).
    static func module(of kind: ClipKind) -> Int {
        switch kind {
        case .link: 0
        case .image: 1
        case .text, .richText: 2
        case .file: 3
        case .email, .colour: 4
        }
    }

    /// A block with an outline and a solid bottom edge in the ink, drawn behind content padded by the same border.
    /// Toybox's bundled faces at the mockup's sizes between the type roles.
    @MainActor static func nunito(_ weight: Int, _ size: CGFloat) -> Font { Font(DisplayFaces.font(StyleTokens.nunito(weight), size: size)) }
    @MainActor static func fredoka(_ size: CGFloat) -> Font { Font(DisplayFaces.font(StyleTokens.fredoka(600), size: size)) }
    @MainActor static func mono(_ size: CGFloat) -> Font { Font(DisplayFaces.font(StyleTokens.jetBrainsMono(500), size: size)) }

    static func block(_ style: StyleTokens, fill: Color, radius: Double, outline: Double = 2, edge: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape.fill(style.color(\.outline))
            .overlay {
                RoundedRectangle(cornerRadius: max(radius - outline, 0), style: .continuous).fill(fill)
                    .padding(EdgeInsets(top: outline, leading: outline, bottom: edge, trailing: outline))
            }
    }
}

/// The keycap chip, the bind-shaped label used everywhere (`.kc`): 26 pt tall, an 8 pt corner, Nunito 800 at 12; a Hyper
/// cap is sun yellow with Hyper's arrow.
struct ToyKeycap: View {
    @Environment(\.style) private var style
    var label: String? = nil
    var symbol: String? = nil
    var hyper = false
    /// The menu's and Binds' bigger caps: the Selected card's Hyper + B, the launcher's Hyper + Return.
    var large = false
    /// Home's press rows' 24 pt caps (`.press .kc`).
    var small = false

    var body: some View {
        let fill = hyper ? style.color(\.hyper) : style.color(\.raised)
        let ink = hyper ? style.color(\.onHyper) : style.color(\.text)
        Group {
            if let symbol { Image(systemName: symbol).font(.system(size: large ? 15 : small ? 9.5 : 10.5, weight: .heavy)) }
            else if hyper && label == nil { Image(systemName: "arrowshape.up.fill").font(.system(size: large ? 15 : small ? 9.5 : 10, weight: .heavy)) }
            else { Text(label ?? "").font(Font(DisplayFaces.font(StyleTokens.nunito(800), size: large ? 17 : small ? 11.5 : 12))) }
        }
        .foregroundStyle(ink)
        .lineLimit(1)
        .padding(.horizontal, large ? 14 : small ? 4 : 7)
        .frame(minWidth: large ? 48 : small ? 20 : 26, minHeight: large ? 44 : small ? 18 : 26)
        .padding(EdgeInsets(top: 2, leading: 2, bottom: large ? 5 : 4, trailing: 2))
        .background(Toy.block(style, fill: fill, radius: large ? style.radii.key : small ? 7 : style.radii.chip, edge: large ? 5 : 4))
        .fixedSize()
    }
}

/// A bind as keycaps: Hyper's cap, then each key, `+` between them only where the mockup spells it out (`plus`).
struct ToyKeys: View {
    var keys: [String]
    var hyper = true
    var plus = false
    var large = false
    var small = false

    var body: some View {
        HStack(spacing: plus ? 8 : 4) {
            if hyper { ToyKeycap(label: large ? "Hyper" : nil, hyper: true, large: large, small: small) }
            ForEach(Array(keys.enumerated()), id: \.offset) { i, key in
                if plus && (hyper || i > 0) { ToyPlus() }
                ToyKeycap(label: key, large: large, small: small)
            }
        }
    }
}

private struct ToyPlus: View {
    @Environment(\.style) private var style
    var body: some View { Text("+").font(Font(DisplayFaces.font(StyleTokens.nunito(800), size: 14))).foregroundStyle(style.color(\.text3)) }
}

/// A coloured square holding a glyph in the ink (`.nav .tile`): the sidebar's pages, a clipboard kind, a launcher row.
struct ToyTile: View {
    @Environment(\.style) private var style
    let symbol: String
    let color: Color
    var size: CGFloat = 28
    /// A name's first letter in place of the symbol (KitTile's).
    var letter: String? = nil

    var body: some View {
        Group {
            if let letter { Text(letter).font(Toy.fredoka(size * 0.5)) }
            else if symbol == PilotMarkShape.symbol { InstrumentMark(size: size * 0.55) }
            else { Image(systemName: symbol).font(.system(size: size * 0.55, weight: .bold)) }
        }
            .foregroundStyle(style.color(\.outline))
            .frame(width: size, height: size)
            .background(color, in: .rect(cornerRadius: size * 0.32, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: size * 0.32, style: .continuous).strokeBorder(style.color(\.outline), lineWidth: 2) }
    }
}

/// The Pilot logo, where the mockup had Capsy (Sven, 2026-10-08): a sun keycap with Pilot's four-box mark.
struct PilotMark: View {
    @Environment(\.style) private var style
    var size: CGFloat = 40

    var body: some View {
        let edge = max(3, size * 0.09)
        InstrumentMark(size: size * 0.46, accent: false)
            .foregroundStyle(style.color(\.onAccent))
            .frame(width: size - 4, height: size - 2 - edge)
            .padding(EdgeInsets(top: 2, leading: 2, bottom: edge, trailing: 2))
            .background(Toy.block(style, fill: style.color(\.accent), radius: size * 0.3, edge: edge))
            .accessibilityLabel("Pilot")
    }
}

/// A card (`.chunk`): the panel colour, 22 pt corner, 2 pt outline and a 5 pt edge, a Fredoka title with an optional
/// trailing part, then the content.
struct ToyCard<Trailing: View, Content: View>: View {
    @Environment(\.style) private var style
    var title: String?
    var fill: KeyPath<StyleColors, Paint> = \.panel
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).styleText(\.title).foregroundStyle(style.color(\.text)).lineLimit(1)
                    Spacer(minLength: 8)
                    trailing
                }
            }
            content
        }
        .padding(style.density.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .styleSurface(\.card, fill: fill)
    }
}

extension ToyCard where Trailing == EmptyView {
    init(title: String?, fill: KeyPath<StyleColors, Paint> = \.panel, @ViewBuilder content: () -> Content) {
        self.init(title: title, fill: fill, trailing: { EmptyView() }, content: content)
    }
}

/// A flat well: a fill in a rounded square with the 2 pt ink outline and no edge (`.clip`, `.gauge`, a search field).
private struct ToyWell: ViewModifier {
    @Environment(\.style) private var style
    let fill: KeyPath<StyleColors, Paint>
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background(style.color(fill), in: shape).overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
    }
}

extension View {
    /// A list row's keycap room (2 pt round, a 4 pt edge below), a sun keycap behind it while it is the current one: the
    /// clipboard panel's rows and choices, the dropdown's rows.
    func toySunRow(_ on: Bool, radius: CGFloat, style: StyleTokens) -> some View {
        padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
            .background { if on { Toy.block(style, fill: style.color(\.accent), radius: radius, edge: 4) } }
    }

    /// Draws this on a Toybox well of `fill`.
    func toyWell(_ fill: KeyPath<StyleColors, Paint> = \.sunken, radius: CGFloat) -> some View { modifier(ToyWell(fill: fill, radius: radius)) }
}

/// A candy dot with the ink outline: a module's colour beside its eyebrow, coral beside a problem's.
struct ToyDot: View {
    @Environment(\.style) private var style
    let color: Color
    var size: CGFloat = 10
    var body: some View {
        Circle().fill(color).overlay { Circle().strokeBorder(style.color(\.outline), lineWidth: 1.5) }.frame(width: size, height: size)
    }
}

/// Small capitals over a group (`.eyebrow`).
struct ToyEyebrow: View {
    @Environment(\.style) private var style
    let text: String
    var body: some View { Text(text).styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).lineLimit(1) }
}

/// A Toybox button's face (`.btn`): 40 pt tall (32 small), 2 pt outline and a 4 pt edge; the primary one sun yellow.
struct ToyButtonFace: View {
    @Environment(\.style) private var style
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration
    var primary = false
    var destructive = false
    var ghost = false
    var small = false

    var body: some View {
        let fill = primary ? style.color(destructive ? \.problem : \.accent) : style.color(\.raised)
        let ink = primary ? style.color(\.onAccent) : destructive ? style.color(\.problem) : ghost ? style.color(\.text2) : style.color(\.text)
        let size: CGFloat = small ? 13 : 14
        configuration.label
            .font(Font(DisplayFaces.font(StyleTokens.nunito(800), size: size)))
            .tracking(size * 0.02)
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, ghost ? 8 : small ? 12 : 16)
            .frame(minHeight: (small ? 32 : 40) - 6)
            .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
            .background { if !ghost { Toy.block(style, fill: fill, radius: small ? 11 : style.radii.control, edge: 4) } }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? Kit.pressScale : 1)
            .animation(Kit.press, value: configuration.isPressed)
            .contentShape(.rect)
    }
}

/// A Toybox switch (`.toggle`): a mint track with an ink outline when on, the sunk well when off, a white knob outlined.
struct ToySwitchFace: View {
    @Environment(\.style) private var style
    let isOn: Bool
    var width: CGFloat = 44
    var height: CGFloat = 26

    var body: some View {
        let knob = height - 10
        Capsule().fill(isOn ? Toy.module(2, style) : style.color(\.sunken))
            .overlay { Capsule().strokeBorder(style.color(\.outline), lineWidth: 2) }
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(style.color(\.knob)).overlay { Circle().strokeBorder(style.color(\.outline), lineWidth: 2) }
                    .frame(width: knob, height: knob).padding(5)
            }
            .frame(width: width, height: height)
    }
}

/// A row of options in one well (`.seg`, the mockup's My binds | Omarchy): the picked one an inverted ink pill. Binds'
/// presets and a page's parts in the frame's header.
struct ToySegments<Value: Hashable>: View {
    @Environment(\.style) private var style
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    let label: String
    /// The choice full keyboard access has on; ← → move it, Space picks it (P36, as InstrumentSegments).
    @FocusState private var focused: Int?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].value == selection
                Button { withAnimation(Kit.change) { selection = options[i].value } } label: {
                    Text(options[i].title).font(style.toyNunito(800, 13.5))
                        .foregroundStyle(on ? style.color(\.onInverse) : style.color(\.text2)).lineLimit(1)
                        .padding(.horizontal, 13).frame(height: style.points(30))
                        .background { if on { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(style.color(\.inverse)) } }
                        .contentShape(.rect)
                }
                .buttonStyle(.kitPress)
                .focused($focused, equals: i)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard let at = focused else { return .ignored }
            let next = at + (press.key == .leftArrow ? -1 : 1)
            if options.indices.contains(next) { focused = next }
            return .handled
        }
        .padding(3)
        .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
        .background(Toy.block(style, fill: style.color(\.panel), radius: style.radii.control, edge: style.depth.control.edge))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A share as a chunky meter (`.meter`): a sunk track in the ink, the fill rounded with an ink edge. Home's disk, the
/// dropdown's Extras downloading.
struct ToyChunkyMeter: View {
    @Environment(\.style) private var style
    let share: Double
    let colour: Color

    var body: some View {
        GeometryReader { g in
            Capsule().fill(colour).overlay { Capsule().stroke(style.color(\.outline), lineWidth: 2) }
                .frame(width: max(14, g.size.width * min(max(share, 0), 1)))
        }
        .frame(height: 14)
        .background(style.color(\.panel), in: .capsule)
        .clipShape(.capsule)
        .overlay { Capsule().strokeBorder(style.color(\.outline), lineWidth: 2) }
    }
}
