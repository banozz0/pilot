import AppKit
import PilotCore
import SwiftUI

// Design round 4's components (card agent-bo-95422891), section 5 of the approved artifact 5sh21HWjCjsWYAwWKTibcE, each
// drawn in the picked style (Instrument's and Toybox's own). Press scale 0.96, 150 ms on colour and position with no
// bounce. PilotSwitchStyle, Segments, Kbd, Chip and PilotButtonStyle are the kit's, so every page using them follows the
// style.

// MARK: - Layout and motion

enum Kit {
    /// 150 ms on colour and position, cubic-bezier(0.2, 0, 0, 1): the kit's one state change.
    static let change = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.15)
    /// A press: scale 0.96, ease out over 120 ms.
    static let press = Animation.easeOut(duration: 0.12)
    static let pressScale: CGFloat = 0.96
    /// A control that cannot be used now.
    static let disabledOpacity = 0.45
}

extension Binding {
    /// `base`'s value while it has one, else nil, in place of SwiftUI's `Binding($optional)`: that one force-unwraps on every
    /// read, so a view still holding it when the value goes nil, before its parent drops it, quits Pilot (Build 74). This one
    /// reads the last value instead and drops writes once nil.
    init?(unwrapping base: Binding<Value?>) {
        guard let last = base.wrappedValue else { return nil }
        self.init(get: { base.wrappedValue ?? last }, set: { if base.wrappedValue != nil { base.wrappedValue = $0 } })
    }
}

extension View {
    /// The light from above on a physical part: a hairline of `colour` along the top of `shape`'s edge.
    func litEdge(_ shape: some InsettableShape, _ colour: Color) -> some View {
        overlay(alignment: .top) { shape.strokeBorder(colour).mask(alignment: .top) { Rectangle().frame(height: 1.5) } }
    }

    /// A card's lit top hairline over a see-through window (a style's card highlight); none when nil.
    func litTop(_ shape: some InsettableShape, _ colour: Color?) -> some View {
        overlay(alignment: .top) { if let colour { Color.clear.litEdge(shape, colour) } }
    }

    /// Dims a kit control that is disabled.
    func kitDimmed(_ enabled: Bool) -> some View { opacity(enabled ? 1 : Kit.disabledOpacity) }

    /// A Menu's content: a Picker in it draws its rows as checkmark items, which any toggle style but the system's greys
    /// out, and the window gives every page its switch style (pilotWindowStyles).
    func menuRows() -> some View { toggleStyle(.automatic) }
}

// MARK: - Focus border

extension View {
    /// The theme's focus treatment on a block of corner radius `radius`, when `on`: Hyprland's gradient, a halo, a lit
    /// edge, a woodblock's double rule, frost, a sticker's offset shadow, an ink rule, or a camera's corner brackets.
    func focusBorder(_ style: FocusBorder? = nil, on: Bool, radius: CGFloat) -> some View {
        modifier(FocusBorderModifier(style: style, on: on, radius: radius))
    }
}

private struct FocusBorderModifier: ViewModifier {
    @Environment(\.style) private var picked
    let style: FocusBorder?
    let on: Bool
    let radius: CGFloat

    /// The content stays one view whatever the style, so a focus change never rebuilds it; only what lies over and
    /// under it changes. Instrument's focus is its picked ring alone, the signal at 1.5 pt (no theme effect).
    func body(content: Content) -> some View {
        if picked.kind == .instrument {
            content.overlay { if on { shape.strokeBorder(picked.color(\.accent), lineWidth: InstrumentBar.ring) } }
        } else {
            themed(content)
        }
    }

    /// Toybox's: the theme's focus treatment under and over the block.
    private func themed(_ content: Content) -> some View {
        let style = on ? (style ?? Theme.theme.focus) : nil
        return content
            .background { if let style { under(style) } }
            .overlay { if let style { over(style) } }
            .shadow(color: style == .lit ? Theme.accent.opacity(0.55) : .clear, radius: style == .lit ? 11 : 0, y: style == .lit ? 10 : 0)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    @ViewBuilder private func under(_ style: FocusBorder) -> some View {
        let a = Theme.accent
        switch style {
        case .glow: shape.inset(by: -3).fill(a.opacity(0.22))
        case .soft: shape.inset(by: -4).fill(a.opacity(0.17))
        case .offset: shape.fill(Theme.second).offset(x: 3, y: 3)
        case .ink: shape.fill(a.opacity(0.75)).offset(x: 3, y: 3)
        default: EmptyView()
        }
    }

    @ViewBuilder private func over(_ style: FocusBorder) -> some View {
        let a = Theme.accent
        switch style {
        case .gradient:
            shape.inset(by: -1).strokeBorder(LinearGradient(colors: [a, Theme.second], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
        case .glow, .soft, .offset: shape.strokeBorder(a)
        case .lit: shape.strokeBorder(a).litEdge(shape, .white.opacity(0.14))
        case .double: ZStack { shape.strokeBorder(a); shape.inset(by: -3).strokeBorder(a.opacity(0.55)) }
        case .frost: ZStack { shape.strokeBorder(a).litEdge(shape, .white.opacity(0.2)); shape.inset(by: -1).strokeBorder(a.opacity(0.3)) }
        case .ink: shape.strokeBorder(Theme.text)
        case .brackets: ZStack { shape.strokeBorder(Theme.line2); Brackets().stroke(a, lineWidth: 2).padding(-4) }
        }
    }
}

/// A camera's focus: four 11 pt corners.
private struct Brackets: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let n: CGFloat = 11
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x + dx * n, y: y + dy * 1))
            p.addLine(to: CGPoint(x: x + dx * 1, y: y + dy * 1))
            p.addLine(to: CGPoint(x: x + dx * 1, y: y + dy * n))
        }
        return p
    }
}

// MARK: - Blocks

/// One block of a page: Toybox's chunk or Instrument's panel.
struct Tile<Trailing: View, Content: View>: View {
    @Environment(\.style) private var style
    var title: String?
    var symbol: String?
    var focused = false
    /// Stretch to the row's height, so tiles side by side end together.
    var fill = false
    /// One muted line under the header saying what the tile is for.
    var note: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        switch style.kind {
        case .toybox: ToyBlock(title: title, note: note, fill: fill, trailing: { trailing }, content: { content })
        case .instrument: InstrumentBlock(title: title, symbol: symbol, note: note, fill: fill, trailing: { trailing }, content: { content })
        }
    }
}

extension View {
    /// A block's surface in the style: Toybox's chunk (ToyKitPage), Instrument's panel under its hairline ring.
    func blockSurface() -> some View { frame(maxWidth: .infinity, alignment: .leading).styleSurface(\.card) }
}

/// A link in the accent with its chevron: "Show all ⌄", "In the menu bar ›".
struct AccentLink: View {
    @Environment(\.ink) private var ink
    let title: String
    var chevron = "chevron.right"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) { Text(title); Image(systemName: chevron).font(ink.system(10, weight: .bold)) }
                // Instrument's signal means Hyper, live and selected alone: its link is in the second text colour.
                .font(ink.ui(12, .semibold)).foregroundStyle(ink.link)
        }
        .buttonStyle(.plain)
    }
}

extension Tile where Trailing == EmptyView {
    init(title: String? = nil, symbol: String? = nil, focused: Bool = false, fill: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, focused: focused, fill: fill, trailing: { EmptyView() }, content: content)
    }
}

/// The heading over a group of cards, with an optional link on the right.
struct CalmHeading<Trailing: View>: View {
    @Environment(\.style) private var style
    let title: String
    /// One muted line under the title saying what the group is for.
    var note: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        switch style.kind {
        case .toybox: ToyHeading(title: title, note: note) { trailing }
        case .instrument: InstrumentHeading(title: title, note: note) { trailing }
        }
    }
}

extension CalmHeading where Trailing == EmptyView {
    init(title: String, note: String? = nil) { self.init(title: title, note: note) { EmptyView() } }
}

/// A page's scroll in the style: its column under the page's title, its intro line first (Home and Look's spacing). The
/// intro is one line; what else it would say is `info`, an ⓘ at its end (simplify-pages T5).
struct KitPage<Content: View>: View {
    @Environment(\.style) private var style
    var intro: String?
    var info: String?
    var fills = false
    @ViewBuilder var content: Content

    var body: some View {
        switch style.kind {
        case .toybox: ToyPage(intro: intro, info: info, flow: true) { content }
        case .instrument: InstrumentPage(intro: intro, info: info, flow: true) { content }
        }
    }

    /// The least width of a page's column (PageFlow): a row's label stays close to its control, and Pilot's Hold Hyper row
    /// still fits (its label wraps to two lines at 460).
    static func column(_ kind: PilotStyle) -> CGFloat { kind == .toybox ? 500 : 460 }
}

/// A page's intro words, then its ⓘ when `info` says more: the one line every page opens on (simplify-pages T5).
struct IntroLine<Words: View>: View {
    var info: String?
    @ViewBuilder var words: Words

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            words
            if let info { InfoMark(text: info) }
        }
    }
}

/// A page's scroll whose content is at least the window's height (card agent-bo-95423003, Sven: "it should fill
/// screen"; card agent-bo-95423004: half the screen was empty), so its last block stretches to the foot; a page taller
/// than the window scrolls as before. `fills` false is a plain scroll.
struct FillScroll<Content: View>: View {
    var fills = true
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { g in
            ScrollView { content.frame(minHeight: fills ? g.size.height : nil, alignment: .top) }
        }
    }
}

/// One block of a page: a titled block in the style.
struct KitBlock<Trailing: View, Content: View>: View {
    @Environment(\.style) private var style
    let title: String
    var symbol: String?
    var focused = false
    /// Stretch to the row's height (Tile's fill).
    var fill = false
    /// One muted line under the title saying what the block is for.
    var note: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        // A block flows into the page's columns (PageFlow) unless it is marked `.pageWide()`.
        Group {
            if style.kind == .toybox {
                ToyBlock(title: title, note: note, fill: fill, trailing: { trailing }, content: { content }).padding(.top, Toy.blockGap)
            } else {
                InstrumentBlock(title: title, symbol: symbol, note: note, fill: fill, trailing: { trailing }, content: { content })
                    .padding(.top, style.density.padding)
            }
        }
        .pageFlows()
    }
}

extension KitBlock where Trailing == EmptyView {
    init(title: String, symbol: String? = nil, focused: Bool = false, fill: Bool = false, note: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, focused: focused, fill: fill, note: note, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Page flow

/// A page's blocks in columns once it is wide enough (page density, Sven 2026-11-12: "settings in the pages that are too
/// wide for no reason and also empty spaces"): each block that flows (`pageFlows()`: KitBlock, unless `.pageWide()`; a More tab's blocks stay one stack) goes under
/// the shortest column, so short blocks sit side by side and no column keeps a hole beside its neighbour; anything else
/// (a header tile, a pair, a grid, a heading) takes the full width under all the columns above it. Columns are at least
/// `column` wide, so a label and its control stay close; under two columns' width the page is one column, as a VStack.
/// A Layout reads the width it is given, so it never measures itself into staying wide (GeneralPage's old trap).
struct PageFlow: Layout {
    /// The least width of a column, and the gap between columns.
    var column: CGFloat
    var gap: CGFloat
    /// Between one child and the next, as the VStack's spacing it replaces.
    var spacing: CGFloat = 0

    /// How many columns `width` holds.
    static func columns(_ width: CGFloat, column: CGFloat, gap: CGFloat) -> Int {
        max(1, Int((width + gap) / (column + gap)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: width, height: arrange(width, subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, frame) in arrange(bounds.width, subviews).frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                              proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let count = Self.columns(width, column: column, gap: gap)
        let flows = subviews.map { count > 1 && $0[PageFlowItem.self] && !$0[PageWideItem.self] }
        var frames: [CGRect] = []
        var top: CGFloat = 0
        var i = 0
        while i < subviews.count {
            let lead = i == 0 ? 0 : spacing
            guard flows[i] else {
                let size = subviews[i].sizeThatFits(ProposedViewSize(width: width, height: nil))
                frames.append(CGRect(x: 0, y: top + lead, width: min(width, size.width), height: size.height))
                top += lead + size.height
                i += 1
                continue
            }
            // A run of flowing blocks. Above a full-width child, a run shorter than the columns shares the width, so no
            // hole opens beside it mid-page (one block alone takes it all); the page's last run keeps the page's columns.
            var end = i
            while end < subviews.count && flows[end] { end += 1 }
            let columns = end < subviews.count ? min(count, end - i) : count
            let side = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            var feet = Array(repeating: top + lead, count: columns)
            for j in i..<end {
                // The shortest column, the leftmost of equals.
                let c = feet.indices.min { feet[$0] < feet[$1] }!
                let y = feet[c] + (feet[c] > top + lead ? spacing : 0)
                let height = subviews[j].sizeThatFits(ProposedViewSize(width: side, height: nil)).height
                frames.append(CGRect(x: CGFloat(c) * (side + gap), y: y, width: side, height: height))
                feet[c] = y + height
            }
            top = feet.max() ?? top
            i = end
        }
        return (frames, top)
    }
}

/// Whether a page child flows into PageFlow's columns (KitBlock's), and whether it is held at the page's width anyway.
private struct PageFlowItem: LayoutValueKey { static let defaultValue = false }
private struct PageWideItem: LayoutValueKey { static let defaultValue = false }

extension View {
    /// The child flows into the page's columns (PageFlow) rather than taking its full width.
    func pageFlows() -> some View { layoutValue(key: PageFlowItem.self, value: true) }
    /// A block that keeps the page's full width in PageFlow: a keyboard, a grid, two columns of its own.
    func pageWide() -> some View { layoutValue(key: PageWideItem.self, value: true) }
}

/// A row in a block under a rule (none over the first).
struct BlockRow<Content: View>: View {
    @Environment(\.style) private var style
    var first = false
    @ViewBuilder var content: Content

    var body: some View {
        if style.kind == .toybox {
            HStack(spacing: 12) { content }
                .frame(maxWidth: .infinity, minHeight: style.points(46), alignment: .leading)
                .overlay(alignment: .top) { if !first { Capsule().fill(style.color(\.line)).frame(height: 2) } }
        } else {
            HStack(spacing: 10) { content }
                .frame(maxWidth: .infinity, minHeight: style.points(40), alignment: .leading)
                .overlay(alignment: .top) { if !first { InstrumentRule() } }
        }
    }
}

/// A module's tile: Toybox's candy tile in `colour`, Instrument's app-icon tile.
struct Squircle: View {
    @Environment(\.style) private var style
    let symbol: String
    var colour = Theme.accent
    /// 30 pt, else 22.
    var big = true

    var body: some View {
        let s: CGFloat = big ? 30 : 22
        if style.kind == .toybox {
            ToyTile(symbol: symbol, color: colour, size: s)
        } else {
            InstrumentAppIcon(bundle: nil, symbol: symbol, size: s)
        }
    }
}

// MARK: - 1 Toggle

/// The window's switch (shadcn/ui Switch anatomy) in the style. `labelled` puts the label left and the switch right, as a settings row; `info` puts an ⓘ
/// after the label.
struct PilotSwitchStyle: ToggleStyle {
    var labelled = false
    var info: String?

    func makeBody(configuration: Configuration) -> some View {
        if labelled {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    configuration.label.contentShape(.rect).onTapGesture { configuration.isOn.toggle() }.accessibilityHidden(true)
                    if let info { InfoMark(text: info) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                KitSwitch(isOn: configuration.$isOn) { configuration.label }
            }
        } else {
            KitSwitch(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

private struct KitSwitch<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var isOn: Bool
    @ViewBuilder var label: Label

    @Environment(\.style) private var style

    var body: some View {
        Group {
            switch style.kind {
            case .toybox: ToySwitchFace(isOn: isOn)
            // Instrument's signal colour means Hyper: a page's switch is lit in the text colour.
            case .instrument: InstrumentSwitchFace(isOn: isOn, lit: false)
            }
        }
            .animation(Kit.change, value: isOn)
            .kitDimmed(isEnabled)
            .contentShape(.rect)
            .onTapGesture { if isEnabled { isOn.toggle() } }
            .accessibilityRepresentation { Toggle(isOn: $isOn) { label } }
    }
}

extension ToggleStyle where Self == PilotSwitchStyle {
    static var pilotSwitch: PilotSwitchStyle { PilotSwitchStyle() }
    /// The window's default: every Toggle on a page is a row with its switch on the right.
    static var pilotSwitchRow: PilotSwitchStyle { PilotSwitchStyle(labelled: true) }
    /// A switch row with an ⓘ saying what the setting does.
    static func pilotSwitchRow(info: String) -> PilotSwitchStyle { PilotSwitchStyle(labelled: true, info: info) }
}

// MARK: - 2 Slider

/// Strength, gaps (shadcn/ui Slider) in the style.
struct KitSlider: View {
    @Environment(\.style) private var style
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double = 0
    var label = ""
    var width: CGFloat? = nil

    var body: some View {
        let w = width ?? 170
        let x = (value - range.lowerBound) / (range.upperBound - range.lowerBound) * w
        ZStack(alignment: .leading) {
            if style.kind == .toybox {
                ToySliderFace(fraction: x / w, width: w)
            } else {
                InstrumentSliderFace(x: x, width: w)
            }
        }
        .frame(width: w, height: 22)
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            guard isEnabled else { return }
            var next = range.lowerBound + min(1, max(0, drag.location.x / w)) * (range.upperBound - range.lowerBound)
            if step > 0 { next = (next / step).rounded() * step }
            if next != value { value = next }
        })
        .kitDimmed(isEnabled)
        .accessibilityRepresentation { Slider(value: $value, in: range) { Text(label) } }
    }
}

// MARK: - 3 Segmented

/// One of a few, in the style's segmented control.
struct Segments<Value: Hashable>: View {
    @Environment(\.style) private var style
    @Environment(\.isEnabled) private var isEnabled
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    /// What VoiceOver calls the control.
    var label = ""

    var body: some View {
        switch style.kind {
        case .toybox: ToySegments(selection: $selection, options: options, label: label).kitDimmed(isEnabled)
        case .instrument:
            InstrumentSegments(options: options, selection: $selection).kitDimmed(isEnabled).fixedSize().accessibilityLabel(label)
        }
    }
}

// MARK: - 4 List row

/// A row of the menu, the clipboard or a list (cmdk item): the style marks the active row (KitRowBackground).
struct KitRow<Content: View>: View {
    @Environment(\.style) private var style
    var selected = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: style.points(42), alignment: .leading)
            .foregroundStyle(style.color(selected && style.kind == .toybox ? \.onAccent : \.text))
            .background(KitRowBackground(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row's selection: Toybox's sun block, Instrument's raised row.
struct KitRowBackground: View {
    @Environment(\.style) private var style
    let selected: Bool

    var body: some View {
        if !selected {
            Color.clear
        } else if style.kind == .toybox {
            Toy.block(style, fill: style.color(\.accent), radius: style.radii.control, edge: 2)
        } else {
            // A list's current row (InstrumentKit's instrumentPicked): raised on its hairline ring, the signal's tick.
            Color.clear.instrumentPicked(true)
        }
    }
}

/// The pointer over a panel (card agent-bo-95422994). The selection follows it, as in Spotlight's and Raycast's lists,
/// but only while it moves: a list the keys scroll, or that typing or arriving results rebuild, slides another row under
/// a still pointer, and SwiftUI tells that row it is hovered; it must not take the selection back. One per panel: the
/// panel's own hover (`tracksPointer`) and each row's note the pointer, so it is known wherever it last moved, over a
/// heading or a gap as over a row.
@MainActor
final class PointerTrack {
    private let location: @MainActor () -> CGPoint
    private var last: CGPoint
    private var moving = false
    /// The row the pointer put each list's selection on, by the list's name, until that list's change reads it.
    fileprivate var pointed: [String: Int] = [:]

    /// Made as the panel opens, from where the pointer is then: a panel shown under the pointer selects nothing until
    /// it moves. `location` is the pointer on the screen; a test passes its own.
    init(location: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }) {
        self.location = location
        last = location()
    }

    /// Notes where the pointer is, from any hover in the panel; true while one move's hovers are told. SwiftUI tells
    /// them at once inside the mouse event, the panel's before its rows', so the first to find the pointer somewhere new
    /// starts the move, and it ends as the run loop turns after the event, whichever hover came first. A hover told
    /// later for a row slid under the pointer finds it where it was.
    func moved() -> Bool {
        let now = location()
        guard now != last else { return moving }
        last = now
        if !moving { RunLoop.main.perform { [weak self] in MainActor.assumeIsolated { self?.moving = false } } }
        moving = true
        return true
    }
}

/// A list the pointer drives (cmdk's list), as one panel's view builds it: the panel's track, the list's name in it, its
/// selection read as it happens (nil while it has none), what a hover and a click on row `index` do, and what row
/// `index` coming into view does (a list that pages, GIPHY's).
struct PointerList {
    let track: PointerTrack
    let name: String
    let selection: () -> Int?
    let hover: (_ index: Int) -> Void
    let click: (_ index: Int) -> Void
    var shown: ((_ index: Int) -> Void)?
    /// The pointer is on row `index` (true) or left it (false), moving or not: what lies under it, which the selection
    /// may not be (the menu's Hyper + right-click, story 199).
    var under: ((_ index: Int, _ inside: Bool) -> Void)?
}

extension View {
    /// The panel's whole content notes the pointer moving over it (PointerTrack), so a row slid under a pointer that
    /// last moved over a heading, a gap or a list's inset finds it still.
    func tracksPointer(_ track: PointerTrack) -> some View {
        onContinuousHover { phase in if case .active = phase { _ = track.moved() } }
    }

    /// Row `index` of `list` (cmdk's item): the pointer moving onto it selects it, and a click anywhere across its width
    /// runs it, on release as a button does (dragged off first, nothing runs). The selected look stays the one cue,
    /// with no press of its own, and the row never takes the keyboard, so the panel's search field keeps typing. Put it
    /// on the row, never on its heading.
    func pointerRow(_ list: PointerList, _ index: Int) -> some View {
        Button { list.click(index) } label: { contentShape(.rect) }
            .buttonStyle(PointerRowStyle())
            .focusable(false)
            .onContinuousHover { phase in
                if case .active = phase { list.under?(index, true) } else { list.under?(index, false) }
                guard case .active = phase, list.track.moved(), list.selection() != index else { return }
                list.hover(index)
                if list.selection() == index { list.track.pointed[list.name] = index }
            }
            .onAppear { list.shown?(index) }
    }

    /// `scroll` brings `list`'s new selection into view, from `old` to `new`, unless the pointer put it there: that row
    /// is under the pointer, and cmdk scrolls only for the keys. Put it on a view every one of the list's changes
    /// reaches, scrolled or not, so each change reads what the pointer did once.
    func scrollsToSelection(_ list: PointerList, scroll: @escaping (_ old: Int?, _ new: Int?) -> Void) -> some View {
        onChange(of: list.selection()) { old, new in
            if list.track.pointed.removeValue(forKey: list.name) != new { scroll(old, new) }
        }
    }
}

/// A row's button draws the row alone: hover has already lit it, and the click runs it at once.
private struct PointerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

// MARK: - 5 Chip

/// A count or a filter (shadcn/ui Badge) in the style.
struct Chip: View {
    @Environment(\.style) private var style
    let text: String
    /// What the chip says by colour ("granted" green, "clashes" amber). None is a plain chip.
    var color: Color?
    /// A picked filter.
    var on = false
    /// A mono count or key after the text: "Conflicts 1", "Kind: Any ⌘1".
    var count: String?
    var symbol: String?
    /// A label on a card or its filter (mockup D: dotfiles, Not on this Mac).
    var tag = false
    /// An × after the text that takes the chip out (a focus preset's blocked site).
    var remove: (() -> Void)?

    var body: some View {
        if style.kind == .toybox {
            ToyPageChip(text: text, color: color, on: on, count: count, symbol: symbol, remove: remove)
        } else {
            InstrumentChipFace(title: text, count: count, on: on, symbol: symbol, remove: remove, height: 22).lineLimit(1).fixedSize()
        }
    }
}

// MARK: - 6 Key cap

/// A key cap for a bind or a hint, in the style.
struct Kbd: View {
    @Environment(\.style) private var style
    /// The layer key Instrument's Hyper chip shows; none offscreen, where a page is drawn without an engine.
    @Environment(Engine.self) private var engine: Engine?
    let text: String
    /// A panel foot's cap, 18 pt, so the foot keeps its one-line height.
    var small = false

    var body: some View {
        if style.kind == .toybox {
            // "Hyper+Shift+S" as Toybox's caps: Hyper's sun cap, then each key.
            let bind = ToyCaps.bind(text)
            if bind.keys.count + (bind.hyper ? 1 : 0) > 1 { ToyKeys(keys: bind.keys, hyper: bind.hyper, small: true) }
            else { ToyKeycap(label: text, small: true) }
        } else {
            // Instrument's chips: the layer key's sign lit in the signal colour (Hyper), each modifier its sign.
            InstrumentBindKeys(label: text, layerKeys: engine?.settings.layerKeys ?? [.capsLock])
        }
    }
}

/// A key on Binds' keyboard: its legend top left, and what it does as a colour (a dot top right); a free key is hollow,
/// Hyper's own key tinted, the picked key lit. Home's keyboard (card agent-bo-95422992) adds the bind's short name under
/// the legend, and the mouse's key lit.
struct BoardKey: View {
    enum State { case free, bound, picked, held }
    /// What a bind shows on its key: the app's own icon, else a symbol in the bind's colour.
    enum Glyph { case symbol(String), image(NSImage) }
    let legend: String
    var colour: Color?
    var state: State = .bound
    /// The bind's short name under the legend, at the size the whole board shares (Home's BoardFit picks it so every name
    /// fits).
    struct Name {
        let text: String
        let size: CGFloat
        /// How far the name may shrink to stay whole on its key: Binds' least board (card agent-bo-95423023); 1 elsewhere.
        var least: CGFloat = 1
    }
    /// Home's key: a smaller legend kept clear of the dot, the bind's short name under it when it has room.
    var detailed = false
    var name: Name?
    var glyph: Glyph?
    var hovered = false
    var height: CGFloat = 38
    /// ISO's Return on Binds' whole keyboard (card agent-bo-95423003): one key over two rows, narrower below.
    var notch: KeyShape.Notch?
    /// A small key on Binds' whole keyboard: tighter insets, and its mark a short line at the foot so the legend keeps the width.
    var narrow = false

    var body: some View {
        let r = Theme.radius(8)
        let shape = KeyShape(radius: r, notch: notch)
        Group {
            if !detailed {
                legendText(size: 11.5)
                    .padding(narrow ? 4 : 7).padding(.horizontal, narrow ? 0 : 1)
            } else {
                named
            }
        }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background {
                switch state {
                case .free: Color.clear
                case .held: shape.fill(Theme.accent.opacity(0.12)).background(shape.fill(Theme.keyFill))
                case .picked: shape.fill(Theme.keyFill).background(shape.fill(Theme.selected))
                case .bound: shape.fill(Theme.keyFill)
                }
            }
            .overlay { if hovered && state != .picked { shape.fill(Theme.text.opacity(0.06)).allowsHitTesting(false) } }
            .overlay {
                if state == .free { shape.strokeBorder(Theme.line) }
                else { Color.clear.litEdge(shape, Theme.keyHighlight) }
            }
            .overlay(alignment: narrow ? .bottomLeading : .topTrailing) {
                if let colour, state != .free {
                    // A narrow key has no room beside or under its legend for the dot: a short line at its foot.
                    if narrow { Capsule().fill(colour).frame(width: 10, height: 2).padding(.leading, 4 + (notch?.step ?? 0)).padding(.bottom, 2.5) }
                    else { Circle().fill(colour).frame(width: 6, height: 6).padding(7) }
                }
            }
            .shadow(color: state != .free ? Theme.line2 : .clear, radius: 0, y: 1)
            .shadow(color: state != .free ? .black.opacity(0.14) : .clear, radius: 1.5, y: 2)
            .focusBorder(on: state == .picked && notch == nil, radius: r)
            .overlay { if state == .picked && notch != nil { shape.strokeBorder(Theme.accent, lineWidth: 1.5) } }
    }

    private func legendText(size: CGFloat) -> some View {
        Text(legend)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(state == .free ? Theme.muted : state == .bound ? Theme.text2 : Theme.text)
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    /// The key's insets beside its legend and name.
    static let leadingInset: CGFloat = 5, trailingInset: CGFloat = 2

    /// The name's face: SF condensed, so a word such as "Passwords" sits whole on a key 45 pt wide.
    static func nameFont(_ size: CGFloat) -> Font { .system(size: size, weight: .medium).width(.condensed) }

    private static let nameTracking: CGFloat = -0.1

    /// Home's key: the legend along the top, the name at the foot (the dot sits top right), at the board's one size; the
    /// board picks a size every name fits.
    private var named: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 3) {
                legendText(size: 10.5)
                Spacer(minLength: 0)
            }
            // Clear of the dot, where there is one.
            .padding(.trailing, colour == nil || state == .free ? 0 : 11)
            Spacer(minLength: 2)
            if let name {
                Text(name.text)
                    .font(Self.nameFont(name.size)).tracking(Self.nameTracking)
                    .foregroundStyle(state == .free ? Theme.muted : Theme.text)
                    .lineLimit(1).minimumScaleFactor(name.least)
                    // ISO's Return: the name sits in the lower part, narrower on the left.
                    .padding(.leading, notch?.step ?? 0)
            }
        }
        .padding(.top, 5).padding(.leading, Self.leadingInset).padding(.trailing, Self.trailingInset).padding(.bottom, 6)
    }
}

// MARK: - 7 Stat tile, 8 Mini graph

/// One reading of This Mac: a ring with the value inside and the label under it (Stats' pie, Apple's rings).
struct StatReading: View {
    @Environment(\.ink) private var ink
    let label: String
    let value: String
    var unit = ""
    /// 0 to 1, the ring's fill.
    var fraction: Double
    var history: [Double] = []
    var colour = Theme.graph(0)
    /// The line's floor and ceiling; the ceiling a little over the highest point when nil.
    var range: (lowest: Double, highest: Double?) = (0, nil)

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(Theme.line, lineWidth: 4.5)
                Circle().trim(from: 0, to: min(1, max(0, fraction))).stroke(colour, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value).font(ink.themeMono(13, weight: .medium)).foregroundStyle(Theme.text)
            }
            .frame(width: 46, height: 46).padding(3)
            Text(label).font(ink.system(11.5)).foregroundStyle(Theme.text2)
        }
    }
}

/// A reading over time: a 1.5 pt line, joins rounded, a 24 % fade under it, no axes (Stats' line widget).
struct MiniGraph: View {
    let values: [Double]
    var colour = Theme.graph(0)
    var lowest: Double? = 0
    var highest: Double?
    var fill = true

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = highest ?? (values.max() ?? 1) * 1.08, bottom = lowest ?? (values.min() ?? 0)
            let span = top - bottom == 0 ? 1 : top - bottom
            let points = values.enumerated().map { i, v in
                CGPoint(x: Double(i) * size.width / Double(values.count - 1), y: size.height - 2 - (v - bottom) / span * (size.height - 4))
            }
            var line = Path()
            line.move(to: points[0])
            for (a, b) in zip(points, points.dropFirst()) {
                let mid = (a.x + b.x) / 2
                line.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
            }
            if fill {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [colour.opacity(0.24), colour.opacity(0)]),
                                                          startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            context.stroke(line, with: .color(colour), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 9 Search field

/// A page's search (cmdk input) in the style.
struct SearchBox: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding?

    var body: some View {
        if style.kind == .toybox {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(ink.system(15, weight: .bold)).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
                ZStack(alignment: .leading) {
                    if text.isEmpty { Text(prompt).foregroundStyle(style.color(\.text3)).allowsHitTesting(false) }
                    field.foregroundStyle(style.color(\.text))
                }
            }
            .font(style.toyNunito(700, 14.5))
            .padding(.horizontal, 14).frame(height: style.points(42))
            .toyWell(radius: style.radii.control)
        } else {
            // The sidebar's search (mockup A's .search): the glyph and prompt in the third text colour on the raised fill.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(style.font(\.icon)).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
                ZStack(alignment: .leading) {
                    if text.isEmpty { Text(prompt).foregroundStyle(style.color(\.text3)).allowsHitTesting(false) }
                    field.foregroundStyle(style.color(\.text))
                }
            }
            .font(style.font(\.body))
            .padding(.horizontal, 10).frame(height: style.points(32))
            .background(style.color(\.raised), in: searchShape)
            .overlay { searchShape.strokeBorder(style.color(\.line)) }
        }
    }

    private var searchShape: RoundedRectangle { RoundedRectangle(cornerRadius: style.radii.control + 1, style: .continuous) }

    @ViewBuilder private var field: some View {
        if let focused { TextField("", text: $text).textFieldStyle(.plain).focused(focused) }
        else { TextField("", text: $text).textFieldStyle(.plain) }
    }
}

// MARK: - 10 Button

/// The window's buttons (shadcn/ui Button), one filled per view for its main action, in the style.
struct PilotButtonStyle: ButtonStyle {
    var primary = false
    /// A quiet button whose words are red: it removes or clears something; with `primary`, filled red in every style.
    var destructive = false
    var soft = false
    /// Words only, no edge or fill: a footer's quiet action ("Remove preset").
    var ghost = false

    func makeBody(configuration: Configuration) -> some View {
        StyledKitButton(configuration: configuration, primary: primary, destructive: destructive, soft: soft, ghost: ghost)
    }
}

/// The button in the surface's style: Toybox's keycap face (ToyKit), else Instrument's.
private struct StyledKitButton: View {
    @Environment(\.style) private var style
    let configuration: ButtonStyleConfiguration
    let primary, destructive, soft, ghost: Bool

    var body: some View {
        if style.kind == .toybox {
            ToyButtonFace(configuration: configuration, primary: primary, destructive: destructive, ghost: ghost)
        } else {
            // One filled action per view, in the inverse, or red when it ends something; Instrument has no status colour,
            // so a quiet destructive one is raised.
            InstrumentButtonStyle(kind: primary ? destructive ? .destructive : .primary : ghost ? .ghost : .raised).makeBody(configuration: configuration)
        }
    }
}

/// A quiet icon-only button, lit under the mouse: a popup's close ×, a tile's take out.
struct IconButton: View {
    @Environment(\.ink) private var ink
    let symbol: String
    let label: String
    var size: CGFloat = 26
    var glyph: CGFloat = 13
    /// The glyph's colour instead of muted (lit under the mouse): ink.destructive on an action that ends something.
    var tint: Color?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: glyph, weight: .medium))
                .foregroundStyle(tint ?? (hovered ? ink.text : ink.muted))
                .frame(width: size, height: size)
                .background(ink.text.opacity(hovered ? 0.08 : 0), in: .rect(cornerRadius: ink.radius(6)))
                .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .onHover { hovered = $0 }
        .animation(Kit.change, value: hovered)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A press and nothing else: scale 0.96 over 120 ms, for a button that draws itself (a theme card, a layout picture).
struct KitPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Kit.pressScale : 1)
            .animation(Kit.press, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == KitPressStyle {
    static var kitPress: KitPressStyle { KitPressStyle() }
}

extension ButtonStyle where Self == PilotButtonStyle {
    static var pilot: PilotButtonStyle { PilotButtonStyle() }
    static var pilotPrimary: PilotButtonStyle { PilotButtonStyle(primary: true) }
    static var pilotDestructive: PilotButtonStyle { PilotButtonStyle(destructive: true) }
    static var pilotSoft: PilotButtonStyle { PilotButtonStyle(soft: true) }
}

// MARK: - 11 Empty state

/// Nothing yet, in the style: a line, the keys that fix it and one action.
struct EmptyState: View {
    @Environment(\.style) private var style
    let title: String
    var line: String?
    var keys: [String] = []
    var action: (title: String, run: () -> Void)?

    var body: some View {
        if style.kind == .toybox {
            ToyEmpty(title: title, line: line, keys: keys, action: action)
        } else {
            InstrumentEmpty(title: title, line: line, keys: keys, action: action)
        }
    }
}

// MARK: - 12 Popover

/// What a menu-bar item opens (Radix Popover), in the style's pop face.
struct KitPopover<Content: View>: View {
    @Environment(\.style) private var style
    @Environment(\.popoverGlass) private var glass
    var width: CGFloat = 230
    /// The content's inset; 0 lets rules run edge to edge.
    var inset = PopoverMetrics.inset
    /// The arrow's room at the item; false for a popover that hangs off no item (the menu's Cmd+K actions).
    var arrow = true
    @ViewBuilder var content: Content

    var body: some View {
        switch style.kind {
        case .toybox: toybox
        case .instrument: instrument
        }
    }

    /// Instrument's (card agent-bo-95423181): the panel colour at the pop radius on the pop's hairline ring, opaque, no
    /// arrow (its room kept, so it hangs where the theme's would); the window's own shadow under it, Geist for the words,
    /// controls tinted in the text colour, as the signal means Hyper alone. On an extension's popover while Glass is on
    /// (popoverGlass, Q474) the face is the top bar's glass alone: no fill and no ring, the glass's edge its edge.
    private var instrument: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.pop, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) { content }
            .padding(inset)
            .frame(width: width, alignment: .leading)
            .font(style.font(\.body))
            .foregroundStyle(style.color(\.text))
            .tint(style.color(\.text2))
            .background {
                if let glass { GlassFace(tint: glass, cornerRadius: style.radii.pop) } else { shape.fill(style.color(\.panel)) }
            }
            .overlay { if glass == nil, let ring = style.depth.pop.ring { shape.strokeBorder(Color(ring)) } }
            .clipShape(shape)
            .padding(.top, arrow ? PopoverMetrics.arrowHeight : 0)
    }

    /// Toybox's (card agent-bo-95423182): the style's pop block in the panel colour, no blur and no arrow (its room kept,
    /// so it hangs where the theme's would), Nunito for the words.
    private var toybox: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(inset)
            .frame(width: width - 2 * style.depth.pop.outline, alignment: .leading)
            .font(style.toyNunito(700, 13))
            .foregroundStyle(style.color(\.text))
            .styleSurface(\.pop, fill: \.panel, radius: \.pop)
            .padding(.top, arrow ? PopoverMetrics.arrowHeight : 0)
    }
}
