import AppKit
import PilotCore
import SwiftUI

// Instrument's parts (mockup A, pilot-redesign-A; ADR 0008; card agent-bo-95423181): a panel under a hairline header,
// key chips with the Hyper one in the signal colour, the three buttons, the switch, an eyebrow and a sparkline. Every
// colour, face and corner comes from the style's tokens, so the same parts draw dark and light.

/// A panel: its title, a muted note and what sits at the right on a 44 pt header over a hairline, then its content.
struct InstrumentPanel<Trailing: View, Content: View>: View {
    @Environment(\.style) private var style
    let title: String
    /// A line icon before the title (a settings page's block).
    var symbol: String?
    var note: String?
    /// Takes the height its row gives it, so panels side by side end level.
    var stretch = false
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One 44 pt line while it all fits whole; else what sits at the right takes a line of its own, never cut.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { heading; Spacer(minLength: 8); trailing.fixedSize() }
                    .padding(.horizontal, 18).frame(height: style.points(44))
                VStack(alignment: .leading, spacing: 10) {
                    heading
                    trailing.fixedSize()
                }
                .padding(.horizontal, 18).padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            InstrumentRule()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
        .styleSurface(\.card)
    }

    /// The title and its note, whole.
    private var heading: some View {
        HStack(spacing: 10) {
            if let symbol { Image(systemName: symbol).font(style.font(\.icon)).foregroundStyle(style.color(\.text3)).accessibilityHidden(true) }
            Text(title).styleText(\.title).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
            if let note { Text(note).styleText(\.body).foregroundStyle(style.color(\.text3)) }
        }
        .lineLimit(1).fixedSize()
    }
}

extension InstrumentPanel where Trailing == EmptyView {
    init(title: String, note: String? = nil, stretch: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title: title, note: note, stretch: stretch, trailing: { EmptyView() }, content: content)
    }
}

/// A hairline across, or down when `vertical`.
struct InstrumentRule: View {
    @Environment(\.style) private var style
    var vertical = false
    var role: KeyPath<StyleColors, Paint> = \.line
    /// Its length; the room it is given when nil.
    var length: CGFloat?
    var body: some View {
        if vertical { style.color(role).frame(width: 1, height: length) } else { style.color(role).frame(width: length, height: 1) }
    }
}

/// The small mono capitals over a group.
struct InstrumentEyebrow: View {
    @Environment(\.style) private var style
    let text: String
    var role: KeyPath<StyleColors, Paint> = \.text3
    var body: some View {
        Text(text).styleText(\.eyebrow).foregroundStyle(style.color(role)).lineLimit(1).fixedSize().accessibilityAddTraits(.isHeader)
    }
}

/// One key chip: the layer key's in the signal colour (Hyper), any other on the raised fill.
struct InstrumentKey: View {
    @Environment(\.style) private var style
    let text: String
    var hyper = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.chip, style: .continuous)
        // The mono face lacks the key signs: they are line icons, as the mockup draws them.
        InstrumentLegend(text: text)
            .foregroundStyle(style.color(hyper ? \.onHyper : \.text2))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 5).frame(minWidth: style.points(19), minHeight: style.points(19))
            .background(style.color(hyper ? \.hyper : \.raised), in: shape)
            .overlay { shape.strokeBorder(style.color(hyper ? \.accentLine : \.line2)) }
    }

    /// Each key sign's line icon.
    static let symbols = ["⇪": "capslock", "↵": "return", "⌃": "control", "⇧": "shift", "⌥": "option", "⌘": "command", "⌫": "delete.left", "⌦": "delete.right",
                          "←": "arrow.left", "→": "arrow.right", "↑": "arrow.up", "↓": "arrow.down"]
}

/// A bind's keys as chips: the layer key's, each modifier of a sublayer, then the key; a plain combo its own keys.
struct InstrumentKeys: View {
    /// Optional, so a panel without the engine (the clipboard, the overlay) draws chips with no layer key.
    @Environment(Engine.self) private var engine: Engine?
    let caps: [String]
    var hyper = true

    var body: some View {
        HStack(spacing: 3) {
            if hyper { InstrumentKey(text: (engine?.settings.layerKeys ?? [.capsLock]).symbol, hyper: true) }
            ForEach(Array(caps.enumerated()), id: \.offset) { InstrumentKey(text: $1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(((hyper ? ["Hyper"] : []) + caps).joined(separator: " "))
    }
}

extension InstrumentKeys {
    /// A trigger's chips: a Hyper bind's modifiers one chip each, then its key ("↵" for Return, "Esc", "⌫"); a plain
    /// combo as one chip.
    init(trigger: Key) {
        if trigger.hyper { self.init(caps: HomeKeys.caps(trigger, space: "Space")) } else { self.init(caps: [trigger.label], hyper: false) }
    }
}

/// Instrument's buttons: raised on a hairline ring, primary in the text colour as a fill, ghost bare; 28 pt high,
/// pressed at 0.96.
struct InstrumentButtonStyle: ButtonStyle {
    /// `destructive`: the one red fill, a confirm that ends something (SPEC story 165).
    enum Kind { case raised, primary, ghost, destructive }
    var kind = Kind.raised

    func makeBody(configuration: Configuration) -> some View {
        Face(kind: kind, label: configuration.label, pressed: configuration.isPressed)
    }

    private struct Face<Label: View>: View {
        @Environment(\.style) private var style
        @Environment(\.isEnabled) private var isEnabled
        let kind: Kind
        let label: Label
        let pressed: Bool

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
            let (ink, fill): (Color, Color?) = switch kind {
            case .raised: (style.color(\.text), style.color(\.raised))
            case .primary: (style.color(\.onInverse), style.color(\.inverse))
            case .ghost: (style.color(\.text2), nil)
            case .destructive: (style.color(\.onAccent), Ink(style: style).destructive)
            }
            label.styleText(\.strong).lineLimit(1).fixedSize()
                .foregroundStyle(ink)
                .padding(.horizontal, kind == .ghost ? 8 : 11).frame(height: style.density.control)
                .background { if let fill { shape.fill(fill) } }
                .overlay { if kind == .raised { shape.strokeBorder(style.color(\.line2)) } }
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(pressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.12), value: pressed)
        }
    }
}

/// A button's words with its keys after them.
struct InstrumentKeyedLabel: View {
    @Environment(\.style) private var style
    let title: String
    var symbol: String?
    var trigger: Key?
    var body: some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(.system(size: style.type.caption.size, weight: .medium)).accessibilityHidden(true) }
            Text(title)
            if let trigger { InstrumentKeys(trigger: trigger) }
        }
    }
}

/// The Hyper key's switch in Instrument: a 28 by 16 track, the signal colour while on; any other switch (`lit` false)
/// the second text colour, so the signal keeps its one meaning.
struct InstrumentSwitchStyle: ToggleStyle {
    var lit = true

    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, lit: lit) }

    private struct Face: View {
        @Environment(\.style) private var style
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ToggleStyleConfiguration
        let lit: Bool

        var body: some View {
            InstrumentSwitchFace(isOn: configuration.isOn, lit: lit)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isOn)
                .contentShape(.rect)
                .onTapGesture { configuration.isOn.toggle() }
                .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

/// A filter chip: its words and, when given, its count in mono; picked, the inverse fill, else a hairline capsule (Binds'
/// modules and the list's layers).
struct InstrumentChip: View {
    @Environment(\.style) private var style
    let title: String
    var count: Int?
    let on: Bool
    /// A colour square before the title: what it stands for elsewhere (a module's keys on Binds' board).
    var swatch: Color?
    let pick: () -> Void

    var body: some View {
        Button(action: pick) { InstrumentChipFace(title: title, count: count.map(String.init), on: on, swatch: swatch).contentShape(.capsule) }
            .buttonStyle(.plain)
            .accessibilityLabel(count.map { "\(title), \($0) binds" } ?? title)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A chip's face (InstrumentChip's, and the Kit's Chip in Instrument, which has no status colours): its glyph, words and
/// mono count; picked, the inverse fill, else a hairline capsule; an × that takes it out.
struct InstrumentChipFace: View {
    @Environment(\.style) private var style
    let title: String
    var count: String?
    var on = false
    var symbol: String?
    var swatch: Color?
    var remove: (() -> Void)?
    var height: CGFloat = 26

    var body: some View {
        HStack(spacing: 6) {
            if let swatch { RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(swatch).frame(width: 9, height: 9).accessibilityHidden(true) }
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(style.color(on ? \.onInverse : \.text2)) }
            Text(title).styleText(\.caption).foregroundStyle(style.color(on ? \.onInverse : \.text2))
            if let count { Text(count).styleText(\.key).foregroundStyle(style.color(on ? \.onInverse : \.text3)).opacity(on ? 0.6 : 1) }
            if let remove {
                IconButton(symbol: "xmark", label: "Remove \(title)", size: 16, glyph: 8.5, action: remove).padding(.leading, -2).padding(.trailing, -6)
            }
        }
        .padding(.horizontal, 10).frame(height: height)
        .background { if on { Capsule().fill(style.color(\.inverse)) } }
        .overlay { if !on { Capsule().strokeBorder(style.color(\.line)) } }
    }
}

/// Choices on a sunk track, the picked one raised on a hairline ring (a merged page's parts, the menu's kinds).
struct InstrumentSegments<Value: Hashable>: View {
    @Environment(\.style) private var style
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var height: CGFloat = 24
    /// The words of a choice not picked; the picked one's are strong.
    var role: KeyPath<StyleTypography, TypeRole> = \.body
    var ink: KeyPath<StyleColors, Paint> = \.text2
    /// Less air either side of each choice, for a bar too narrow for the usual (C3: Menu's five tabs at 760 pt).
    var tight = false
    /// The choice full keyboard access has on; ← → move it, Space picks it (P36, design q267 A).
    @FocusState private var focused: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title).styleText(on ? \.strong : role).foregroundStyle(style.color(on ? \.text : ink))
                        .padding(.horizontal, tight ? 6 : height > 22 ? 10 : 8).frame(height: height)
                        .instrumentRaised(on, fill: \.panel, radius: style.radii.control - 2)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focused($focused, equals: option.value)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard let at = options.firstIndex(where: { $0.value == focused }) else { return .ignored }
            let next = at + (press.key == .leftArrow ? -1 : 1)
            if options.indices.contains(next) { focused = options[next].value }
            return .handled
        }
        .padding(2)
        .instrumentWell()
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// A well sunk into a panel on a hairline ring: a code block, a copy's text, a segmented track.
    func instrumentWell(radius: Double? = nil) -> some View { modifier(InstrumentWell(radius: radius)) }

    /// A list's current row: raised on its hairline ring, the signal's tick in its inset (the menu's, the clipboard's,
    /// the notes list's highlight).
    func instrumentPicked(_ on: Bool) -> some View {
        instrumentRaised(on).overlay(alignment: .leading) { if on { InstrumentTick().padding(.leading, 4) } }
    }

    /// Raised on a hairline ring while `on`: a picked row, action or choice.
    func instrumentRaised(_ on: Bool, fill: KeyPath<StyleColors, Paint> = \.raised, radius: Double? = nil) -> some View {
        modifier(InstrumentRaised(on: on, fill: fill, radius: radius))
    }
}

private struct InstrumentWell: ViewModifier {
    @Environment(\.style) private var style
    let radius: Double?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? style.radii.control, style: .continuous)
        content.background(style.color(\.sunken), in: shape).overlay { shape.strokeBorder(style.color(\.line)) }
    }
}

private struct InstrumentRaised: ViewModifier {
    @Environment(\.style) private var style
    let on: Bool
    let fill: KeyPath<StyleColors, Paint>
    let radius: Double?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? style.radii.control, style: .continuous)
        content
            .background { if on { shape.fill(style.color(fill)) } }
            .overlay { if on { shape.strokeBorder(style.color(\.line2)) } }
    }
}

/// A switch's face, 28 by 16: on, the signal colour, or the second text colour where the switch is not Hyper's (`lit`
/// false, the menu's System rows), so the signal keeps its one meaning.
struct InstrumentSwitchFace: View {
    @Environment(\.style) private var style
    let isOn: Bool
    var lit = true

    var body: some View {
        Capsule().fill(style.color(isOn ? (lit ? \.accent : \.text2) : \.line3))
            .frame(width: 28, height: 16)
            .overlay(alignment: isOn ? .trailing : .leading) {
                // On the grey track the knob takes the panel's colour, so it reads in dark too.
                Circle().fill(style.color(isOn && !lit ? \.panel : \.knob)).frame(width: 12, height: 12).padding(2)
            }
    }
}

/// A reading's last minutes as a line in the third text colour, its newest point a dot in the signal colour (live).
struct InstrumentSpark: View {
    @Environment(\.style) private var style
    let values: [Double]

    var body: some View {
        GeometryReader { g in
            let points = Self.points(values, in: g.size)
            ZStack(alignment: .topLeading) {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(style.color(\.text3), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                if let last = points.last {
                    Circle().fill(style.color(\.accent)).frame(width: 5, height: 5).position(last)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The values spread across `size`, lowest at the foot, 3 pt in from every edge.
    static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let low = values.min(), let high = values.max() else { return [] }
        let span = high - low
        return values.enumerated().map { i, v in
            CGPoint(x: 3 + CGFloat(i) / CGFloat(values.count - 1) * (size.width - 6),
                    y: size.height - 3 - (span > 0 ? CGFloat((v - low) / span) : 0.5) * (size.height - 6))
        }
    }
}

/// A share on a 3 pt track: the meter beside a most used bind, the disk's use.
struct InstrumentMeter: View {
    @Environment(\.style) private var style
    let share: Double
    /// The filled part's colour: the accent while it runs (onboarding's Set up).
    var fill: KeyPath<StyleColors, Paint> = \.text2

    var body: some View {
        Capsule().fill(style.color(\.line))
            .overlay(alignment: .leading) {
                GeometryReader { g in Capsule().fill(style.color(fill)).frame(width: max(3, g.size.width * min(max(share, 0), 1))) }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
    }
}

/// An app's own icon, else its symbol (or `letter`, a name's first) in the second text colour on the raised fill: the
/// Kit's coloured tiles too, as Instrument has no module colours.
struct InstrumentAppIcon: View {
    @Environment(\.style) private var style
    let bundle: String?
    var symbol = "app"
    let size: CGFloat
    var letter: String?

    var body: some View {
        if let icon = bundle.flatMap(AppsModule.icon(bundle:)) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Group {
                if let letter { Text(letter).font(Font(DisplayFaces.font(StyleTokens.geistMono(500), size: size * 0.42))) }
                else if symbol == PilotMarkShape.symbol { InstrumentMark(size: size * 0.55) }
                else { Image(systemName: symbol).font(.system(size: size * 0.55)) }
            }
            .foregroundStyle(style.color(\.text2))
            .instrumentTile(size)
        }
    }
}

extension View {
    /// A tile `size` square on the raised fill (InstrumentAppIcon's), for a glyph, a letter or an emoji.
    func instrumentTile(_ size: CGFloat) -> some View { modifier(InstrumentTileFace(size: size)) }
}

private struct InstrumentTileFace: ViewModifier {
    @Environment(\.style) private var style
    let size: CGFloat
    func body(content: Content) -> some View {
        content.frame(width: size, height: size)
            .background(style.color(\.raised), in: .rect(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A quiet chip on a hairline ring: the menu's branch and a picker's title, the clipboard prompt Sven is in.
struct InstrumentCrumb: View {
    @Environment(\.style) private var style
    var symbol: String?
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(style.font(\.caption)).accessibilityHidden(true) }
            Text(text).styleText(\.caption)
        }
        .foregroundStyle(style.color(\.text2)).lineLimit(1).fixedSize()
        .padding(.horizontal, 8).frame(height: style.points(24))
        .overlay { shape.strokeBorder(style.color(\.line2)) }
        .accessibilityElement(children: .combine)
    }
}

/// Pilot's mark, the app icon's four boxes (Packaging/AppIcon.icon): a 2×2 of rounded squares, the top-left filled in
/// the accent, the other three outlined in the foreground, in the top bars too (spec pilot-1-1 T28); `accent: false` draws it all
/// in its one colour.
struct InstrumentMark: View {
    @Environment(\.style) private var style
    var size: CGFloat = 15
    var accent = true

    var body: some View {
        ZStack {
            Path(PilotMarkShape.path(size, flipped: true, boxes: accent ? 1..<4 : 0..<4)).fill(style: FillStyle(eoFill: true))
            if accent { Path(PilotMarkShape.path(size, flipped: true, boxes: 0..<1)).fill(style.color(\.accent)) }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The mark's one geometry, drawn by InstrumentMark, Toybox's PilotMark and the macOS menu bar's picture.
enum PilotMarkShape {
    /// What `BarKind.symbol` names for Pilot: no SF Symbol has it, so a tile or chip given it draws the mark.
    static let symbol = "pilot.mark"

    /// The four boxes in a square `side` points wide, filled even-odd: the icon's proportions (boxes 248 apart 44 of
    /// 540, corner 58), each box on a half point so it stays crisp at 2x; `flipped` puts y down (SwiftUI). `boxes` picks
    /// which, the filled top-left first.
    static func path(_ side: CGFloat, flipped: Bool, boxes: Range<Int> = 0..<4) -> CGPath {
        let box = ((side * 248 / 540) * 2).rounded() / 2, gap = side - box * 2, corner = box * 58 / 248
        let line = max(1, ((side * 1.2 / 16) * 2).rounded() / 2)
        let top: CGFloat = flipped ? 0 : box + gap, bottom = box + gap - top
        let path = CGMutablePath()
        for (index, origin) in [CGPoint(x: 0, y: top), CGPoint(x: box + gap, y: top), CGPoint(x: 0, y: bottom), CGPoint(x: box + gap, y: bottom)].enumerated() where boxes.contains(index) {
            let rect = CGRect(origin: origin, size: CGSize(width: box, height: box))
            path.addRoundedRect(in: rect, cornerWidth: corner, cornerHeight: corner)
            if index > 0 {
                let inner = max(corner - line, 0)
                path.addRoundedRect(in: rect.insetBy(dx: line, dy: line), cornerWidth: inner, cornerHeight: inner)
            }
        }
        return path
    }
}

/// Attention in Instrument (mockup A's NOTES: no status colours, attention reuses the accent as a 2 px tick): before a
/// question that asks to remove something, or a run that failed.
struct InstrumentTick: View {
    @Environment(\.style) private var style
    var body: some View {
        Capsule().fill(style.color(\.accent)).frame(width: 2, height: 14).accessibilityHidden(true)
    }
}

/// Attention's line (mockup A's NOTES): the signal's tick before what went wrong or what to mind, in the caption face.
struct InstrumentAttention: View {
    @Environment(\.style) private var style
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            InstrumentTick().padding(.top, 1)
            Text(text).styleText(\.caption).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One key hint in a panel's foot (menu.html's .foot .a): the words, then the keys as chips; what Return does set
/// brighter.
struct InstrumentHint: View {
    @Environment(\.style) private var style
    let hint: KeyHint

    var body: some View {
        let primary = hint.key == "↵"
        HStack(spacing: 8) {
            Text(hint.label.prefix(1).uppercased() + hint.label.dropFirst()).styleText(primary ? \.strong : \.caption)
                .foregroundStyle(style.color(primary ? \.text : \.text2))
            HStack(spacing: 3) { ForEach(Array(Self.caps(hint.key).enumerated()), id: \.offset) { InstrumentKey(text: $1) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(hint.label) \(hint.key)")
    }

    /// A hint's keys as caps: each sign its own ("⌘K" is ⌘ and K, "← →" two arrows), a word whole ("Esc", "Tab").
    static func caps(_ key: String) -> [String] {
        // A range of digits ("1–9") is one cap.
        if key.contains("–") { return [key] }
        var caps: [String] = [], word = ""
        for c in key {
            if c.isLetter || c.isNumber { word.append(c); continue }
            if !word.isEmpty { caps.append(word); word = "" }
            if !c.isWhitespace { caps.append(String(c)) }
        }
        if !word.isEmpty { caps.append(word) }
        return caps
    }
}

/// A panel's foot (menu.html's .foot): Pilot's mark and `place` (where Sven is, what the panel holds), then what the
/// keys do. Short of room the place gives way to the mark, then the mark goes and the keys close up; the keys never go.
struct InstrumentFoot<Place: View>: View {
    @Environment(\.style) private var style
    let hints: [KeyHint]
    /// Words that are no key, before the keys and never given way: Activity's note (GIPHY's attribution is on its bar, T39).
    var note: String?
    @ViewBuilder var place: Place

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(place: true)
            line(place: false)
            line(place: false, mark: false, gap: 12)
            // More keys than one line holds (the clipboard's): two lines, right-aligned, never a key cut.
            HStack(alignment: .top, spacing: 0) {
                InstrumentMark(size: 13).foregroundStyle(style.color(\.text3)).padding(.top, 3)
                Spacer(minLength: 18)
                VStack(alignment: .trailing, spacing: 8) {
                    if let note { Text(note).foregroundStyle(style.color(\.text3)) }
                    let half = (hints.count + 1) / 2
                    hintLine(Array(hints.prefix(half)), gap: 14)
                    hintLine(Array(hints.dropFirst(half)), gap: 14)
                }
            }
            .styleText(\.caption).lineLimit(1).padding(.vertical, 11)
        }
        .padding(.leading, 18).padding(.trailing, 12).frame(minHeight: style.points(42))
        .overlay(alignment: .top) { InstrumentRule() }
    }

    private func hintLine(_ hints: [KeyHint], gap: CGFloat) -> some View {
        HStack(spacing: gap) { ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in InstrumentHint(hint: hint) } }
            .fixedSize()
    }

    private func line(place shown: Bool, mark: Bool = true, gap: CGFloat = 18) -> some View {
        HStack(spacing: 0) {
            if mark {
                HStack(spacing: 8) {
                    InstrumentMark(size: 13).foregroundStyle(style.color(\.text3))
                    if shown { place }
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 18)
            if let note { Text(note).foregroundStyle(style.color(\.text3)).fixedSize().padding(.trailing, gap) }
            hintLine(hints, gap: gap)
        }
        .styleText(\.caption).lineLimit(1)
    }
}
