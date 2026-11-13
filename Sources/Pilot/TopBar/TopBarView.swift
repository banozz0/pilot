import PilotCore
import SwiftUI

/// One screen's bar (cards agent-bo-95422850, 851, 910, 911 and 914): the bar items placed in the top bar on three sides,
/// each drawn in its style with its popover, the full strip high; any change to the items redraws it.
struct TopBarView: View {
    /// The tiler's monitor name for this bar's screen.
    let screen: String
    let sources: BarSources
    let store: BarItemsStore
    /// Final group geometry for the island windows.
    var reportIsland: ((TopBarSide, CGRect) -> Void)? = nil
    /// Where the bar drew each slot, for the overflow item.
    var frames = BarFrames.shared
    var recorder = Recorder.shared
    var wallpapers = BarWallpapers.shared
    var dictation = DictationOverlay.shared
    /// The items this bar holds readers for: the ones it shows, from appearing to going.
    @State private var held: Set<BarKind> = []

    var body: some View {
        let sides = store.settings.preview(.topBar).top ?? [:]
        let kinds = Set(sides.values.joined().flatMap(\.kinds))
        // Each slot is its own view, so a timer tick redraws the timer, not the bar.
        TopBarStrip(sides: sides, configuration: store.topBarConfiguration, look: Look.shared, background: store.background.shown(transparency: Look.shared.transparency), colour: store.colour, itemColours: store.itemColours,
                    wallpaper: wallpapers.strips[screen], foot: BarFoot(screen: screen, configuration: store.topBarConfiguration), reportIsland: reportIsland, report: { [frames, screen] in frames.report($2, side: $0, index: $1, on: screen) },
                    // Capture shows the recording's time itself, in place of the red-dot control; checked first, so the bar
                    // never follows the recorder then.
                    trailing: !kinds.contains(.capture) && recorder.isActive ? AnyView(RecordingControl(recorder: recorder)) : nil,
                    live: dictation.inBar ? AnyView(DictationBarItem(overlay: dictation)) : nil, liveSide: dictation.setup.barSide,
                    overflow: AnyView(TopBarOverflow(screen: screen, sides: sides, sources: sources, store: store, frames: frames))) {
            TopBarSlot(slot: $0, screen: screen, sources: sources, store: store)
        }
            // Here, not where the panel is made: the bar lives on, and a body follows the Look page's theme and style.
            .styled(.topBar)
            .pilotTheme()
            .onAppear { hold(kinds) }
            .onChange(of: kinds) { hold(kinds) }
            .onDisappear { hold([]) }
    }

    /// Holds the readers `kinds` need and releases the rest, so an item drawing nothing yet (a battery not read) still
    /// starts its reader.
    private func hold(_ kinds: Set<BarKind>) { sources.readings.hold(kinds, replacing: &held) }
}

/// One slot of the top bar: a bar drop's item draws its own lit item (TopBarDropItem); every other slot is TopBarSlotView.
struct TopBarSlot: View {
    let slot: BarSlot
    let screen: String
    let sources: BarSources
    let store: BarItemsStore
    var lights = BarDropLights.shared

    var body: some View {
        if case .item(let entry) = slot, entry.kind == .pill {
            TopBarPillItem(lights: lights)
        } else if case .item(let entry) = slot, entry.kind.drop != nil {
            TopBarDropItem(entry: entry, sources: sources, store: store, lights: lights)
        } else {
            TopBarSlotView(slot: slot, screen: screen, sources: sources, store: store)
        }
    }
}

/// The open bar drops as the top bar lights them (spec Bar drops T4): BarDrops tells it after every change, so an item
/// relights however its drop opened or closed (its click, its key, Escape, a click outside).
@MainActor @Observable
final class BarDropLights {
    static let shared = BarDropLights()

    private(set) var open: Set<BarDropKind> = []
    /// What a click on a drop's item does: toggles that drop. Tests fake it.
    @ObservationIgnored var toggle: @MainActor (BarDropKind) -> Void = { BarDropLights.toggleDrop($0) }

    init(open: Set<BarDropKind> = []) { self.open = open }

    /// Every bar's item for each drop, so a drop can open under the one on its own screen.
    @ObservationIgnored private var anchors: [BarDropKind: [ScreenAnchor.Box]] = [:]
    func register(_ box: ScreenAnchor.Box, for drop: BarDropKind) { anchors[drop, default: []].append(box) }
    func unregister(_ box: ScreenAnchor.Box, for drop: BarDropKind) { anchors[drop]?.removeAll { $0 === box } }

    /// The centre of each drop's item showing on `bar`: an item gone for room, a preview strip's, or one an island's
    /// window crops out does not count.
    func itemCentres(on bar: CGRect) -> [BarDropKind: CGFloat] {
        Dictionary(uniqueKeysWithValues: anchors.keys.compactMap { drop in shown(drop, on: bar).map { (drop, $0.frame.midX) } })
    }

    /// The view drawing `drop`'s item where it shows on `bar`, and its frame (BarDropPlacement.shown).
    private func shown(_ drop: BarDropKind, on bar: CGRect) -> (view: NSView, frame: CGRect)? {
        let drawn = (anchors[drop] ?? []).compactMap { box -> (view: NSView, frame: CGRect, window: CGRect)? in
            guard let view = box.view, let window = view.window, let frame = view.screenFrame else { return nil }
            return (view, frame, window.frame)
        }
        return BarDropPlacement.shown(drawn.map { ($0.frame, $0.window) }, on: bar).map { (drawn[$0].view, drawn[$0].frame) }
    }

    /// Where `drop` hangs when its item drawn by `box` is clicked (spec desktop-controls T5): that item's own screen, its
    /// bar, the item's centre; nil when the item is not on a bar now. Every display's bar registers its own item, so the
    /// click names its box: taking the first registered one opened the drop on the wrong display (build 2276).
    func spot(of drop: BarDropKind, from box: ScreenAnchor.Box) -> BarDrops.Spot? {
        guard let view = box.view, let screen = view.window?.screen, let item = view.screenFrame else { return nil }
        let bar = Screens.bars[screen.localizedName].map { TopBarGeometry.frame(screen: screen.frame, strip: $0) }
        return .init(screen: screen.frame, visible: screen.visibleFrame, bar: bar, items: [drop: item.midX], ground: Self.ground(view))
    }

    /// The flat foot of the bar window `drop`'s item stands on inside `bar` (its key opens it there too); nil when none.
    func ground(of drop: BarDropKind, on bar: CGRect) -> CGRect? { shown(drop, on: bar).flatMap { Self.ground($0.view) } }

    /// An item's bar window (an island, the floating strip or the whole bar) less its drawn rounded corners.
    private static func ground(_ view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        return PillPlacement.ground(window: window.frame, radius: window.contentView?.layer?.cornerRadius ?? 0)
    }

    /// The open pill drop's frame (screen points), for the bar's foot to leave a gap where it joins (BarFootGap).
    private(set) var pillDrop: CGRect?

    /// Reads BarDrops' open set; called by BarDrops after each change and after a click here.
    func refresh(_ drops: BarDrops = .shared) {
        let now = Set(BarDropKind.allCases.filter(drops.isOpen))
        if now != open { open = now }
        let pill = drops.window(.pill)?.frame
        if pill != pillDrop { pillDrop = pill }
    }

    /// Each item does what its key does: Ask AI's opens the chat as its action does (AIChatPanel.show: the idle reset, the
    /// route) or closes it; the terminal's toggles its drop as Hyper+T does (TerminalDrop.toggle: the shell's view, keyboard
    /// and all).
    static func toggleDrop(_ drop: BarDropKind, terminal: TerminalDrop = .shared) {
        switch drop {
        case .askAI:
            let chat = AIChatPanel.shared
            chat.isShown ? chat.hide() : chat.show()
        case .terminal:
            terminal.toggle()
        case .pill:
            PillDrop.shared.toggle()   // no item clicked: the focused display, as its key does (the pill's item names its own)
        }
        shared.refresh()
    }
}

/// A bar drop's item (spec Bar drops T4, design C's `>_ TERMINAL` and `✦ ASK AI`): its glyph and its name in spaced caps,
/// lit in the accent over an underline tab while its drop hangs under the bar; a click toggles the drop, a right-click
/// opens the item's menu as every item's does.
struct TopBarDropItem: View {
    @Environment(\.style) private var style
    let entry: BarEntry
    let sources: BarSources
    let store: BarItemsStore
    var lights = BarDropLights.shared
    @State private var anchor = ScreenAnchor.Box()

    var body: some View {
        if let drop = entry.kind.drop {
            let lit = lights.open.contains(drop)
            Button { lights.toggle(drop) } label: { label(lit) }
                .buttonStyle(.kitPress)
                .accessibilityLabel(entry.kind.title)
                .accessibilityAddTraits(lit ? .isSelected : [])
                .frame(maxHeight: .infinity)
                .toyIsland(entry.kind)
                .onAppear { lights.register(anchor, for: drop) }
                .onDisappear { lights.unregister(anchor, for: drop) }
        }
    }

    private func label(_ lit: Bool) -> some View {
        let ink = lit ? Theme.accent : BarMetrics.glyphInk(style)
        return HStack(spacing: 5) {
            Image(systemName: BarParts.dropSymbol(entry.kind)).font(.system(size: 11, weight: .semibold))
            if entry.style == .iconName {
                Text(entry.kind.title.uppercased()).font(font).tracking(0.8).lineLimit(1).fixedSize()
            }
        }
        .foregroundStyle(ink)
        .barTarget(BarTooltip.text(entry.kind, BarInputs()))
        .overlay(alignment: .bottom) {
            if lit { Capsule().fill(Theme.accent).frame(height: 2).padding(.horizontal, BarMetrics.inset).padding(.bottom, 2) }
        }
        .background(ScreenAnchor(box: anchor, rightClick: showMenu))
    }

    /// Instrument's small mono caps, as the C frames draw them; Toybox's own face.
    private var font: Font {
        style.kind == .toybox ? ToyBar.font.weight(.bold) : Theme.mono(10, weight: .semibold)
    }

    private func showMenu() {
        guard let view = anchor.view else { return }
        let kind = entry.kind
        BarMenu.show(sources.menu(kind, in: .topBar, store: store), under: view) { [sources, store] action in
            sources.perform(action, on: kind, store: store) {}
        }
    }
}

/// The top bar's three sides, in either Look, on one opaque strip (card
/// agent-bo-95423007: the menu bar reveals under the bar, and none of it may show through), whatever Look's Glass says:
/// the bar's own Background and Colour decide (BarItemsStore; Sven, 2026-10-10, who could not read it on Look's Glass).
/// Glass leaves the strip clear over the bar window's glass (TopBarWindows.applyLook). On a picked colour the bar's text
/// turns white or near-black, whichever reads (StyleTokens.inked); on Glass and Clear in Instrument it does so for the
/// wallpaper under it, its light spots toned down behind the items as the macOS menu bar does (BarTone; Sven, Q254). It draws the Strip (card agent-bo-95423013, design
/// JJPiA9o30SA direction A), Omarchy's: no boxes, mono type, a hairline before the status glyphs and a rule along its
/// foot; the app's menus fold before any status item goes. The Strip is the only style (SPEC story 116). The bar and
/// the Menu bar page's preview both draw it, so the preview is the bar. Short of room, TopBarRow keeps every item whole and apart (card agent-bo-95423006),
/// and what goes for room folds into the overflow item.
struct TopBarStrip<Slot: View>: View {
    @Environment(\.style) private var style
    let sides: [TopBarSide: [BarSlot]]
    var configuration: BarPresetConfiguration? = nil
    var look: Look? = nil
    var background = TopBarBackground.solid
    var colour = ColourChoice.theme
    var glassPreview = false
    /// Item colours (EnvironmentValues.barItemColours), the bar's switch.
    var itemColours = false
    /// The wallpaper under the bar (BarWallpapers), which a Glass or Clear bar inks and tones itself for; the Menu bar
    /// page's preview has none.
    var wallpaper: WallpaperStrip.Grid? = nil
    /// Where this bar sits on its screen, so its foot's line can open where the pill's drop joins it; the preview has none.
    var foot: BarFoot? = nil
    /// Where each slot is drawn, by its side and index in `sides`, in BarFrames' space: the strip's whole frame (card
    /// agent-bo-95423017).
    var reportIsland: ((TopBarSide, CGRect) -> Void)? = nil
    var report: ((TopBarSide, Int, CGRect) -> Void)? = nil
    /// Drawn after the right side's items while it is there: the recording's control (story 192, Q162).
    var trailing: AnyView? = nil
    /// Dictation's take (DictationBarItem), on `liveSide`: on the left just after Pilot's mark (first with no mark), so the
    /// left edge never moves; at the centre after its items, the group re-centred, never going for room; on the right
    /// first, before the status items, where it is the first to go on a crowded bar. Its words fold before any item goes.
    var live: AnyView? = nil
    var liveSide = TopBarSide.left
    /// Holds the slots that go for room, placed by TopBarRow only while any does (TopBarOverflow); the Menu bar page's
    /// preview has none.
    var overflow: AnyView? = nil
    /// The Menu bar page's preview: the centre island may leave the middle (TopBarRow.packed), and only the bar's ground
    /// is cut to its shape, so each piece's − above it shows whole (Sven on build 2372).
    var preview = false
    @ViewBuilder let slot: (BarSlot) -> Slot

    var body: some View {
        // Toybox's islands (ToyBar) stand on its canvas, apart, with no hairline or rule. Instrument's (InstrumentBar) draws
        // a hairline between the bar's groups, its caption face and the rule along its foot.
        let islands = configuration?.preset.islands == true
        let toybox = style.kind == .toybox, instrument = style.kind == .instrument
        // Pills: each slot its own pill (BarPill), the sides' grounds left out; Toybox's slots are pills already.
        let pills = configuration?.preset == .pills, pilled = pills && !toybox
        let rules = instrument ? sides.mapValues(InstrumentBar.hairlines(before:)) : [:]
        let placed = live?.layoutValue(key: TopBarRow.Side.self, value: liveSide).layoutValue(key: TopBarRow.Folds.self, value: true)
        // On the left it follows the mark: placed first only where there is none.
        let first = liveSide == .right || liveSide == .left && !sides.values.contains { $0.contains { $0.kinds.contains(.pilot) } }
        let ground = TopBarColour.ground(colour, style: style)
        let (inked, tone): (StyleTokens, TopBarColour.Toned?) = if let look {
            TopBarColour.ink(colour, style: style, background: background, wallpaper: wallpaper, look: look)
        } else { (TopBarColour.tokens(colour, style: style, background: background), nil) }
        TopBarRow(spacing: configuration?.spacing ?? (toybox ? ToyBar.spacing : InstrumentBar.spacing), gap: 12, islands: islands ? configuration?.row : nil, packed: preview) {
            if islands, let configuration {
                ForEach(TopBarSide.allCases, id: \.self) { side in
                    GeometryReader { proxy in
                        // A zero final width draws no fill or stroke, including when every saved item is hidden. A Pills
                        // side draws nothing: its pills are its ground.
                        if !pills, proxy.size.width > 0, proxy.size.height > 0 {
                            islandGround(ground: ground, tone: tone)
                                .background { if glassPreview, background == .glass { BarGlassGround(colour: colour) } }
                                .clipShape(.rect(cornerRadius: configuration.radius))
                                .overlay {
                                    RoundedRectangle(cornerRadius: configuration.radius).strokeBorder(style.color(\.line), lineWidth: configuration.border)
                                        .footGap(foot, at: proxy.frame(in: .named(BarFrames.space)).minX)
                                }
                        }
                    }
                    .allowsHitTesting(false)
                    .reported(reportIsland.map { report in { report(side, $0) } })
                    .layoutValue(key: TopBarRow.Ground.self, value: side)
                }
            }
            if let placed, first { placed }
            ForEach(TopBarSide.allCases, id: \.self) { side in
                ForEach(Array((sides[side] ?? []).enumerated()), id: \.offset) { index, item in
                    let ruled = rules[side]?.contains(index) == true
                    slot(item)
                        .modifier(BarPill(configuration: pilled ? configuration : nil, background: background, colour: colour, look: look))
                        .instrumentRuleBefore(ruled && !islands, gap: InstrumentBar.spacing)
                        .reported(report.map { report in { report(side, index, $0) } })
                        .layoutValue(key: TopBarRow.Side.self, value: side)
                        .layoutValue(key: TopBarRow.Folds.self, value: item.kind.folds)
                    if let placed, liveSide == .left, item.kinds.contains(.pilot) { placed }
                }
            }
            if let placed, liveSide == .centre { placed }
            if let trailing { trailing.layoutValue(key: TopBarRow.Side.self, value: .right) }
            if let overflow { overflow.layoutValue(key: TopBarRow.Overflow.self, value: true) }
        }
        .environment(\.inTopBar, true)
        .environment(\.barItemColours, itemColours)
        .environment(\.barGround, tone.map { ($0.tone.ground, inked.dark) })
        .inked(inked)
        .font(toybox ? ToyBar.font : style.font(\.caption))
        .padding(.horizontal, islands ? 0 : configuration?.padding ?? 6).padding(.vertical, islands || toybox ? 0 : 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named(BarFrames.space))
        .background {
            // The preview cuts only its ground to the bar's shape (BarClip cuts the bar's whole).
            if !islands { islandGround(ground: ground, tone: tone).modifier(BarClip(radius: configuration?.radius ?? 0, on: preview)) }
        }
        // One rule along the Strip's foot on a solid bar; none on Glass, whose own edge is the line there (Sven, 2026-10-10:
        // the two drew a double line where the AI chat meets the bar).
        .overlay(alignment: .bottom) {
            if configuration == nil, background == .solid, instrument { InstrumentRule().style(inked).footGap(foot) }
        }
        .modifier(BarClip(radius: configuration?.radius ?? 0, on: !preview))
        .overlay {
            if let configuration, !islands {
                RoundedRectangle(cornerRadius: configuration.radius).strokeBorder(style.color(\.line), lineWidth: configuration.border)
                    .footGap(foot)
            }
        }
    }

    @ViewBuilder private func islandGround(ground: UInt32, tone: TopBarColour.Toned?) -> some View {
        if background == .solid { colour == .theme ? TopBarColour.themeGround(style) : Color(Paint(ground)) }
        else { TopBarColour.toneGround(tone, background: background) }
    }
}

/// A Pills slot's own pill (Sven, 2026-11-12, Q177, after a Waybar picture): the bar's colour (the theme's, or the picked
/// one) under it, its corners `radius`, a `border` ring in the accent's line colour, `padding` inside. Glass draws the
/// colour at Look's Transparency share (the window behind a Pills side shows no glass of its own), Clear only the ring.
/// Nil `configuration` leaves the slot as it is.
private struct BarPill: ViewModifier {
    @Environment(\.style) private var style
    let configuration: BarPresetConfiguration?
    let background: TopBarBackground
    let colour: ColourChoice
    let look: Look?

    func body(content: Content) -> some View {
        if let configuration {
            let shape = RoundedRectangle(cornerRadius: configuration.radius, style: .circular)
            let ground = Color(Paint(TopBarColour.ground(colour, style: style)))
            content
                .padding(.horizontal, configuration.padding)
                .frame(maxHeight: .infinity)
                .background {
                    switch background {
                    case .solid: shape.fill(colour == .theme ? TopBarColour.themeGround(style) : ground)
                    case .glass: shape.fill(ground.opacity(Double(look.map(TopBarColour.tintAlpha) ?? 55) / 100))
                    case .clear: shape.fill(TopBarColour.clearGround)
                    }
                }
                // Inset by half the ring, so it stays inside the pill: a continuous capsule's strokeBorder left stubs at
                // its ends offscreen (the bar look round).
                .overlay { shape.inset(by: configuration.border / 2).stroke(style.color(\.accentLine), lineWidth: configuration.border) }
        } else {
            content
        }
    }
}

/// Where a bar sits on its screen (screen points): the screen, and the left edge of the bar's row, which every island
/// window of it shares (TopBarIslandClip keeps the row's coordinates).
struct BarFoot: Equatable {
    var screen: CGRect
    var rowX: CGFloat

    @MainActor init?(screen name: String, configuration: BarPresetConfiguration?) {
        guard let screen = NSScreen.screens.first(where: { $0.localizedName == name }) else { return nil }
        self.screen = screen.frame
        rowX = BarPresetGeometry.frame(configuration, screen: screen.frame, strip: 0, notch: screen.safeAreaInsets.top).minX
    }
}

extension View {
    /// The bar's foot line (an island's border, the strip's, the solid bar's rule) with a gap where the open pill drop
    /// joins it, so bar and drop read as one shape (Sven on build 2276); `x` is this view's left edge in the row.
    @ViewBuilder func footGap(_ foot: BarFoot?, at x: CGFloat = 0) -> some View {
        if let foot { mask { BarFootGap(foot: foot, x: x) } } else { self }
    }
}

/// The mask: all of the line, less the open pill drop's span along its foot. Only this view reads the drop, so opening
/// it redraws no item; with the pill closed it is one plain rectangle.
private struct BarFootGap: View {
    let foot: BarFoot
    let x: CGFloat
    var lights = BarDropLights.shared

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Rectangle()
                if let drop = lights.pillDrop, foot.screen.contains(CGPoint(x: drop.midX, y: drop.maxY - 1)) {
                    Rectangle().frame(width: drop.width, height: 4)
                        .offset(x: drop.minX - foot.rowX - x, y: proxy.size.height - 4)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
        }
    }
}

/// The top bar's colour (Sven, 2026-10-10): what the strip draws (TopBarStrip), the glass is tinted with
/// (TopBarWindows.applyLook) and the slots' ink is made for.
@MainActor
enum TopBarColour {
    /// The bar's colour as 0xRRGGBB: the picked one, else the theme's bar colour (themeGround's).
    static func ground(_ colour: ColourChoice, style: StyleTokens) -> UInt32 {
        colour.resolved(style.colors.canvas.rgb)
    }

    /// The tokens the bar's slots draw in on `colour`: the style's own on the theme's colour; on a picked one, inked for it.
    /// Toybox's islands carry their own grounds, so its ink stays whatever the bar's colour.
    static func tokens(_ colour: ColourChoice, style: StyleTokens) -> StyleTokens {
        colour == .theme || style.kind == .toybox ? style : style.inked(on: ground(colour, style: style))
    }

    /// The same for a bar on `background`: a Clear bar shows no colour, so its text is the style's own.
    static func tokens(_ colour: ColourChoice, style: StyleTokens, background: TopBarBackground) -> StyleTokens {
        background == .clear ? style : tokens(colour, style: style)
    }

    /// A bar's tone over the wallpaper (BarTone) and the mask that draws it.
    struct Toned {
        let tone: BarTone
        let mask: CGImage
    }

    /// The tokens a bar on `background` draws in, and how it tones the `wallpaper` under it: the theme's ink side at
    /// full strength over the toned strip while it reads it; as above otherwise. The strip and the bar's window
    /// (applyLook) both take it.
    static func ink(_ colour: ColourChoice, style: StyleTokens, background: TopBarBackground, wallpaper: WallpaperStrip.Grid?,
                    look: Look) -> (tokens: StyleTokens, tone: Toned?) {
        guard let toned = tone(wallpaper, background: background, colour: colour, style: style, look: look) else {
            return (tokens(colour, style: style, background: background), nil)
        }
        return (style.inked(on: toned.tone.ground, ink: toned.tone.ink, full: true), toned)
    }

    /// How a Glass or Clear bar tones the wallpaper `strip` under it, as the macOS menu bar does (Sven, Q254): Glass
    /// sees it through its tint at Look's Transparency, Clear as it is. Nil on Solid, in Toybox (every slot is an
    /// opaque island in its own ink, ToyIsland) and while the strip is not read, which leaves the bar as before. Made
    /// once per strip, side and tint, never per draw.
    static func tone(_ strip: WallpaperStrip.Grid?, background: TopBarBackground, colour: ColourChoice, style: StyleTokens,
                     look: Look) -> Toned? {
        guard background != .solid, style.kind != .toybox, let strip else { return nil }
        let tint = background == .glass ? Contrast.rgb(ground(colour, style: style)) : nil, share = Double(tintAlpha(look)) / 100
        let key = ToneKey(strip: strip, white: style.dark, tint: tint, share: tint == nil ? 0 : share)
        if let made = made.first(where: { $0.key == key }) { return made.toned }
        guard let tone = BarTone.make(strip, prefersWhite: key.white, tint: tint, share: key.share), let mask = mask(tone) else { return nil }
        made = [(key, Toned(tone: tone, mask: mask))] + made.prefix(3)
        return made[0].toned
    }

    private struct ToneKey: Equatable {
        let strip: WallpaperStrip.Grid, white: Bool, tint: [Double]?, share: Double
    }
    /// The last few tones made: a bar per screen, each drawn by its strip and its window.
    private static var made: [(key: ToneKey, toned: Toned)] = []

    /// The tone's mask as an image, its colour at each cell's share.
    private static func mask(_ tone: BarTone) -> CGImage? {
        let c = tone.maskColour == 0 ? 0.0 : 1.0
        var bytes = [UInt8](repeating: 0, count: tone.alpha.count * 4)
        for (i, a) in tone.alpha.enumerated() {
            let v = UInt8((Double(a) * c).rounded())   // premultiplied
            (bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], bytes[i * 4 + 3]) = (v, v, v, a)
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: tone.width, height: tone.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tone.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// What a Glass or Clear strip draws under its items: the tone's mask, stretched smooth over the bar, while the
    /// wallpaper is read; on Clear always over clearGround, so the gaps between glyphs still take the click.
    @ViewBuilder static func toneGround(_ toned: Toned?, background: TopBarBackground) -> some View {
        ZStack {
            if background == .clear { clearGround }
            if let toned { Image(decorative: toned.mask, scale: 1).resizable().interpolation(.high) }
        }
    }

    /// A Clear bar's ground: no tint the eye sees, yet not quite nothing, since the window server sends a click on a
    /// wholly see-through pixel of a window to the one under it, and the gaps between the bar's glyphs would click
    /// through to the desktop.
    static let clearGround = Color.black.opacity(0.01)

    /// The theme's bar colour: the style's canvas.
    static func themeGround(_ style: StyleTokens) -> Color { style.color(\.canvas) }

    /// The glass's tint on a Glass bar: its colour at Look's Transparency, whether Look's own Glass is on or not.
    static func tint(_ colour: ColourChoice, style: StyleTokens, look: Look) -> NSColor {
        look.glassTint(Color(Paint(ground(colour, style: style))), alpha: tintAlpha(look))
    }

    /// The glass's tint's share in percent at Look's Transparency, over its whole range (Sven, Q714): whole at 0 %, where
    /// the bar goes solid (TopBarBackground.shown), 55 % at the default 33 % as before, down to the window ground's least
    /// (42 %) at 100 %, in a line between each. 50 % is 52, 77 % 46.
    static func tintAlpha(_ look: Look) -> Int { tintAlpha(transparency: look.transparency) }
    static func tintAlpha(transparency: Int) -> Int {
        let t = Double(min(100, max(0, transparency))), standard = 33.0
        let atStandard = MaterialValues.glassShare * 100, least = Layers(transparency: 100).ground * 100
        let share = t <= standard ? 100 + (atStandard - 100) * t / standard : atStandard + (least - atStandard) * (t - standard) / (100 - standard)
        return Int(share.rounded())
    }
}

/// The top bar's measures (design JJPiA9o30SA direction A).
@MainActor
enum BarMetrics {
    /// A target's room each side of its ink, which takes the pointer.
    static let inset: CGFloat = 8
    /// A workspace number's: the numbers sit closer than items.
    static let numberInset: CGFloat = 7
    /// Every glyph: one size, one weight.
    static let glyph = Font.system(size: 13, weight: .regular)
    /// Every word and number: the Strip's mono face at 12.
    static let font = Theme.mono(12, weight: .medium)
    /// The time chip's fill, the accent at this share over the ground, edged.
    static let chip = 0.2
    /// Every glyph's colour in `style`'s ink (the bar's, inked for its colour): its quieter text2.
    static func glyphInk(_ style: StyleTokens) -> Color {
        style.color(\.text2)
    }
}

/// The bar cut to its shape, items and all; off in the Menu bar page's preview, where the pieces' − sit above it.
private struct BarClip: ViewModifier {
    let radius: Double
    let on: Bool

    func body(content: Content) -> some View {
        if on { content.clipShape(.rect(cornerRadius: radius)) } else { content }
    }
}

private extension View {
    /// The bar's slots in `tokens` when its text was inked for its colour; as they are otherwise.
    @ViewBuilder func inked(_ tokens: StyleTokens) -> some View {
        if tokens.inked { style(tokens) } else { self }
    }
}

/// The top bar's row: the left side against the leading edge, the right against the trailing edge, the centre centred
/// while it clears both, every item at its own width. Short of room the centre first moves to the middle of the clear gap;
/// then an item that folds (the app's menus, card agent-bo-95423016; then dictation's words at the centre) gives room down
/// to its least, the width it takes offered none; then whole items go, the right side's innermost first (as a crowded menu bar hides its leftmost status
/// items), then the left side's innermost; the centre (the clock) always stays. A Layout cannot hide a subview, so what
/// goes is placed `offstage`, wholly outside the row, for the window or the caller's clip to hide (TrailingRow's way too).
/// While anything goes, the overflow item (Sven on build 52: no limit on what the bar holds) takes its room just inside
/// the right side and lists what went, so the bar stays one line and nothing on it is ever out of reach.
struct TopBarRow: Layout {
    /// The side a subview is on.
    struct Side: LayoutValueKey { static let defaultValue = TopBarSide.left }
    /// A subview that shrinks before any item goes.
    struct Folds: LayoutValueKey { static let defaultValue = false }
    /// The overflow item: on no side, placed only while an item goes.
    struct Overflow: LayoutValueKey { static let defaultValue = false }
    /// A non-interactive island fill/stroke, placed from the very same final plan as its items.
    struct Ground: LayoutValueKey { static let defaultValue: TopBarSide? = nil }

    /// Where each item starts in the row (nil for one that goes) and how wide it is placed.
    struct Plan {
        var x: [TopBarSide: [CGFloat?]]
        var width: [TopBarSide: [CGFloat]]
        /// Where the overflow item starts; nil while nothing goes.
        var more: CGFloat? = nil
        var moreWidth: CGFloat = 0
        var groups: [TopBarSide: CGRect] = [:]

        func hit(at point: CGPoint) -> TopBarSide? {
            TopBarSide.allCases.first { BarPresetGeometry.hit(point, in: groups[$0]) }
        }
    }

    /// Between two items of a side.
    var spacing: CGFloat
    /// The least room between two sides.
    var gap: CGFloat
    var islands: BarPresetConfiguration? = nil
    /// The Menu bar page's preview: an island bar's centre may leave the middle for the room between the sides, as the
    /// Strip's does, so the preview's bar is no wider than its items need (StripRoom). The bar keeps it on the middle.
    var packed = false
    /// How far left of the row a subview that goes is placed.
    static let offstage: CGFloat = 10_000

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // The bar and the preview both propose a size; only an unsized proposal measures.
        if let width = proposal.width, let height = proposal.height { return CGSize(width: width, height: height) }
        let height = proposal.height ?? subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? natural(measure(subviews, height: height).widths), height: height)
    }

    /// The least room where nothing goes and nothing folds, by `arrange`'s own rules (the Menu bar page's preview, Sven on
    /// build 2363: every item, whatever the window): the sides a gap apart, each island padded, and an island bar's centre
    /// on the middle unless packed, so it needs as much room each side of it as the wider side takes.
    func natural(_ widths: [TopBarSide: [CGFloat]]) -> CGFloat {
        let padding = CGFloat(islands?.padding ?? 0)
        func padded(_ s: TopBarSide) -> CGFloat { let w = side(widths[s] ?? []); return w > 0 ? w + 2 * padding : 0 }
        let (l, c, r) = (padded(.left), padded(.centre), padded(.right))
        if islands != nil, !packed, c > 0 { return (c + 2 * max(l > 0 ? l + gap : 0, r > 0 ? r + gap : 0)).rounded(.up) }
        let drawn = [l, c, r].filter { $0 > 0 }
        return (drawn.reduce(0, +) + gap * CGFloat(max(0, drawn.count - 1))).rounded(.up)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = measure(subviews, height: bounds.height)
        let plan = arrange(measured.widths, least: measured.least, room: bounds.width, more: measured.more, height: bounds.height)
        var next: [TopBarSide: Int] = [:]
        for subview in subviews {
            if let side = subview[Ground.self] {
                let rect = plan.groups[side] ?? CGRect(x: -Self.offstage, y: 0, width: 0, height: 0)
                subview.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(rect.size))
                continue
            }
            if subview[Overflow.self] {
                let x = plan.more.map { bounds.minX + $0 } ?? bounds.minX - Self.offstage - measured.more
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: plan.moreWidth, height: bounds.height))
                continue
            }
            let side = subview[Side.self], index = next[side, default: 0]
            next[side] = index + 1
            let width = plan.width[side]![index], x = plan.x[side]![index]
            subview.place(at: CGPoint(x: x.map { bounds.minX + $0 } ?? bounds.minX - Self.offstage - width, y: bounds.midY),
                          anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }

    /// Each side's items' widths at `height`, in order, the least each takes (a folding item's offered no width) and the
    /// overflow item's width.
    private func measure(_ subviews: Subviews, height: CGFloat) -> (widths: [TopBarSide: [CGFloat]], least: [TopBarSide: [CGFloat]], more: CGFloat) {
        var widths: [TopBarSide: [CGFloat]] = [:], least: [TopBarSide: [CGFloat]] = [:], more: CGFloat = 0
        for subview in subviews where subview[Ground.self] == nil {
            let side = subview[Side.self], width = subview.sizeThatFits(ProposedViewSize(width: nil, height: height)).width
            if subview[Overflow.self] { more = width; continue }
            widths[side, default: []].append(width)
            least[side, default: []].append(subview[Folds.self] ? min(width, subview.sizeThatFits(ProposedViewSize(width: 0, height: height)).width) : width)
        }
        return (widths, least, more)
    }

    /// Where each item starts in a row `room` wide (nil for one that goes) and its width; `least` gives each item's least
    /// (an item missing from it, or all of them, does not shrink). While an item drawing something goes, the overflow
    /// item, `more` wide, sits first on the right side; none (0) leaves the row as it was.
    func arrange(_ widths: [TopBarSide: [CGFloat]], least: [TopBarSide: [CGFloat]] = [:], room: CGFloat, more: CGFloat = 0, height: CGFloat = 0) -> Plan {
        let island = islands != nil, onMiddle = island && !packed
        let padding: CGFloat = island ? min(CGFloat(islands!.padding), max(0, (room - min(room, more)) / 2)) : 0
        let measuredMore = island ? min(more, max(0, room - 2 * padding)) : more
        func padded(_ width: CGFloat) -> CGFloat { width > 0 ? width + 2 * padding : 0 }
        let left = widths[.left] ?? [], centre = widths[.centre] ?? [], right = widths[.right] ?? []
        var keptLeft = left.count, keptRight = right.count, keptCentre = centre.count
        var sized = widths
        // The centre's width, less what a folding item there gave.
        func c() -> CGFloat { padded(side(sized[.centre, default: []][kept(.centre)])) }
        func kept(_ s: TopBarSide) -> Range<Int> {
            switch s {
            case .left: 0..<keptLeft
            case .centre: 0..<keptCentre
            case .right: (right.count - keptRight)..<right.count
            }
        }
        // Whether an item drawing something goes, so the overflow item shows.
        func overflows() -> Bool {
            measuredMore > 0 && (left[keptLeft...].contains { $0 > 0 } || right[..<(right.count - keptRight)].contains { $0 > 0 } || island && centre[keptCentre...].contains { $0 > 0 })
        }
        // The right side's width, the overflow item first in it while it shows.
        func rightSide() -> CGFloat {
            let r = side(sized[.right, default: []][kept(.right)])
            return padded(overflows() ? measuredMore + (r > 0 ? spacing + r : 0) : r)
        }
        // The centre's least and most x, clear of both sides; with no centre (the Menu's) the sides are one gap apart.
        func span() -> (lo: CGFloat, hi: CGFloat) {
            let l = padded(side(sized[.left, default: []][kept(.left)])), r = rightSide()
            if onMiddle {
                if c() > 0 { return (max(l > 0 ? l + gap : 0, r > 0 ? r + gap : 0), (room - c()) / 2) }
                return (l + (l > 0 && r > 0 ? gap : 0), room - r)
            }
            return (l > 0 ? l + gap : 0, room - c() - (r > 0 ? r + (c() > 0 ? gap : 0) : 0))
        }
        // The kept items that fold give what the row is short, each down to its least.
        func fold() {
            sized = widths
            let (lo, hi) = span()
            var short = lo - hi
            for s in [TopBarSide.left, .right, .centre] {
                for i in kept(s) where short > 0 {
                    let give = min(short, sized[s]![i] - (least[s]?[i] ?? sized[s]![i]))
                    sized[s]![i] -= give
                    short -= give
                }
            }
        }
        fold()
        // Still short: the right side gives an item, then the left; the folding items take back what that frees.
        while keptLeft + keptRight + (island ? keptCentre : 0) > 0, case let (lo, hi) = span(), lo > hi {
            if keptRight > 0 { keptRight -= 1 } else if keptLeft > 0 { keptLeft -= 1 } else { keptCentre -= 1 }
            fold()
        }
        // Centred on the row while that clears both sides, else in the middle of the room between them, so it never reads
        // as one of a side's items.
        let (lo, hi) = span(), centred = (room - c()) / 2
        let centreX = onMiddle ? centred : (lo...max(lo, hi)).contains(centred) ? centred : max(lo, (lo + hi) / 2)
        var x: [TopBarSide: [CGFloat?]] = [:]
        let more = overflows() ? room - rightSide() + padding : nil
        for (s, start) in [(TopBarSide.left, padding), (.centre, centreX + padding), (.right, room - padding - side(sized[.right, default: []][kept(.right)]))] {
            let all = sized[s] ?? [], keep = kept(s)
            var at = start
            x[s] = all.indices.map { i in
                guard keep.contains(i), !island || all[i] > 0 else { return nil }
                defer { at += all[i] > 0 ? all[i] + spacing : 0 }
                return at
            }
        }
        var plan = Plan(x: x, width: sized, more: more, moreWidth: measuredMore)
        if island {
            for s in TopBarSide.allCases {
                var spans = (x[s] ?? []).enumerated().compactMap { i, at -> CGRect? in
                    guard let at, sized[s]![i] > 0 else { return nil }
                    return CGRect(x: at, y: 0, width: sized[s]![i], height: height)
                }
                if s == .right, let at = more { spans.append(CGRect(x: at, y: 0, width: measuredMore, height: height)) }
                if let first = spans.first {
                    plan.groups[s] = spans.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -padding, dy: 0)
                }
            }
        }
        return plan
    }

    /// A side's width: its items that draw something, `spacing` apart; nothing when none draws.
    private func side(_ widths: some Collection<CGFloat>) -> CGFloat {
        let drawn = widths.filter { $0 > 0 }
        return drawn.isEmpty ? 0 : drawn.reduce(0, +) + spacing * CGFloat(drawn.count - 1)
    }
}

private extension View {
    /// Hands `report` the view's frame in BarFrames' space as it changes; without one it tracks nothing (the Menu bar
    /// page's preview).
    @ViewBuilder func reported(_ report: ((CGRect) -> Void)?) -> some View {
        if let report { onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BarFrames.space)) } action: { report($0) } } else { self }
    }
}

/// The tiler's workspaces: the one this screen shows marked, the focused one strongest; a click goes there. The with app
/// style adds each workspace's first app, the icons style (top bar only) its apps' icons (WorkspaceAppIcons).
struct TopBarWorkspacesView: View {
    @Environment(\.inTopBar) private var inTopBar
    @Environment(\.style) private var tokens
    let screen: String
    let tiler: TilerService
    /// The numbers, with app or icons.
    var style = BarStyle.numbers

    var body: some View {
        let items = TopBarWorkspaces.items(occupied: tiler.occupied.map(\.name), focused: tiler.focused,
                                           visibleHere: tiler.perMonitor.first { $0.monitorName == screen }?.workspace)
        // The top bar's current one: the one this screen shows, else (no screen read yet) the focused one.
        let shownHere = items.contains(where: \.isShownHere)
        let occupied = Dictionary(tiler.occupied.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        // Instrument's: this screen's workspaces first, a hairline before those another display shows (InstrumentBar).
        let instrument = inTopBar && tokens.kind == .instrument
        let (ordered, elsewhere) = instrument
            ? InstrumentBar.displays(items, here: tiler.perMonitor.first { $0.monitorName == screen }?.monitorId,
                                     shown: tiler.perMonitor, monitors: tiler.workspaceMonitors)
            : (items, nil)
        HStack(spacing: instrument ? InstrumentBar.chipGap : !inTopBar || tokens.kind == .toybox ? 4 : 0) {
            ForEach(Array(ordered.enumerated()), id: \.element.name) { index, item in
                let workspace = occupied[item.name] ?? OccupiedWorkspace(name: item.name, apps: [])
                let app = style == .withApp ? workspace.apps.first : nil
                let name = Text(app.map { "\(item.name) \($0)" } ?? item.name)
                let current = shownHere ? item.isShownHere : item.isFocused
                let button = Button { tiler.go(item.name, from: "topbar") } label: {
                    if !inTopBar {
                        boxed(name, item, app: app)
                    } else if tokens.kind == .toybox {
                        ToyWorkspaceChip(label: BarParts.workspaceLabel(item.name, app: app), current: current, focused: item.isFocused,
                                         workspace: style == .icons ? workspace : nil)
                            .barTarget("Workspace \(item.name)", inset: 0)
                    } else if tokens.kind == .instrument {
                        InstrumentWorkspaceChip(label: BarParts.workspaceLabel(item.name, app: app), current: current, focused: item.isFocused,
                                                occupied: occupied[item.name] != nil, workspace: style == .icons ? workspace : nil)
                            .barHoverTarget("Workspace \(item.name)")
                            .frame(maxHeight: .infinity).contentShape(.rect)
                    } else if style == .icons {
                        island(name, item, current: current, workspace: workspace)
                    } else {
                        underlined(name, item, current: current)
                    }
                }
                .accessibilityLabel("Workspace \(item.name)")
                Group { if inTopBar { button.buttonStyle(.kitPress) } else { button.buttonStyle(.plain) } }
                    .instrumentRuleBefore(index == elsewhere, gap: InstrumentBar.chipGap)
            }
        }
        .padding(.horizontal, instrument ? InstrumentBar.chipGap : 0)
    }

    /// The Strip's number (design JJPiA9o30SA direction A): the current one in the text colour over a 2 pt underline,
    /// the accent while it has the focus.
    private func underlined(_ name: Text, _ item: TopBarWorkspaces.Item, current: Bool) -> some View {
        name.foregroundStyle(tokens.color(current ? \.text : \.text2))
            .frame(minWidth: 10)
            .padding(.horizontal, BarMetrics.numberInset).frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if current { Capsule().fill(item.isFocused ? Theme.accent : tokens.color(\.text3)).frame(width: 12, height: 2).padding(.bottom, 3) }
            }
            .barHoverTarget("Workspace \(item.name)")
    }

    /// The icons style's workspace (direction B's left island): its number, then its apps' icons; the current one on a
    /// raised pill ringed in the accent while it has the focus (muted while another screen has it), its icons at full
    /// strength.
    private func island(_ name: Text, _ item: TopBarWorkspaces.Item, current: Bool, workspace: OccupiedWorkspace) -> some View {
        let pill = RoundedRectangle(cornerRadius: Theme.radius(6), style: .continuous)
        return HStack(spacing: 6) {
            name.monospacedDigit().foregroundStyle(tokens.color(current ? \.text : \.text2))
            if !workspace.apps.isEmpty { WorkspaceAppIcons(workspace: workspace, lit: current) }
        }
        .padding(.horizontal, 7).frame(height: 22)
        .background { if current { pill.fill(tokens.inked ? tokens.color(\.raised) : Theme.selected) } }
        .overlay { if current { pill.strokeBorder(item.isFocused ? Theme.accent.opacity(0.7) : tokens.color(\.line2)) } }
        .barTarget("Workspace \(item.name)", inset: 3)
    }

    /// Design round 4's number, square-cornered in the menu bar's preview: 17 pt, the shown one filled.
    private func boxed(_ name: Text, _ item: TopBarWorkspaces.Item, app: String?) -> some View {
        name.font(Theme.mono(11, weight: .semibold))
            .padding(.horizontal, app == nil ? 0 : 5)
            .frame(minWidth: 17, minHeight: 17)
            .foregroundStyle(item.isShownHere ? Theme.onAccent : Theme.text.opacity(0.75))
            .background(item.isShownHere ? (item.isFocused ? Theme.accent : Theme.muted) : .clear, in: .rect(cornerRadius: Theme.radius(4)))
    }
}

/// Other apps' menu bar items, by app icon, its name on hover: one item is pressed by a click, several are a menu of
/// their names; the one button style puts every app's items in one menu. In the top bar the icons fold into a drawer
/// behind a chevron (card agent-bo-95423018, design JJPiA9o30SA's drawer shot); there and in the settings' preview each
/// app is its template glyph, tinted as the macOS menu bar tints it (MenuAppIcon). With Show exact menu bar items on, the
/// drawer shows each item as macOS draws it (MenuItemPictures), and a click opens its menu under it (MenuItemOpener).
struct TopBarMenuApps: View {
    @Environment(\.inTopBar) private var inTopBar
    @Environment(\.style) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let apps: MenuApps
    var oneButton = false
    @State private var anchor = ScreenAnchor.Box()

    var body: some View {
        // The apps are listed afresh as the pointer comes, so a click lands on what runs now.
        Group {
            if oneButton {
                menu
            } else if inTopBar {
                drawer(apps.drawer)
            } else {
                HStack(spacing: 8) {
                    ForEach(apps.list, id: \.app.pid) { entry in
                        MenuAppButton(apps: apps, entry: entry, label: MenuAppIcon(app: entry.app))
                    }
                }
            }
        }
        .onHover { if $0 { apps.hovered() } }
    }

    /// Every app's items in one native menu under the button, each app a section: a SwiftUI Menu in the bar's
    /// non-activating panel may not open, as the popovers' did not (97c8a4a1). A pick opens that item's menu under the
    /// button too (MenuApps.press), never at the item's own place in the macOS menu bar (Sven on build 82: Stash's menu
    /// opened far right, the macOS menu bar showing through the top bar).
    private var menu: some View {
        Button {
            guard let view = anchor.view else { return }
            BarMenu.show(sections: apps.list.map { entry in
                (entry.app.name, entry.items.map { item in (item.label, { _ = apps.press(item, under: (pid: entry.app.pid, view: view)) }) })
            }, under: view)
        } label: {
            let glyph = Image(systemName: "ellipsis.circle").foregroundStyle(BarMetrics.glyphInk(style))
            Group { if inTopBar { glyph.barTarget("Other apps") } else { glyph } }
                .contentShape(.rect).background(ScreenAnchor(box: anchor))
        }
        // Fixed across only: fixed down too, the button and the slot's right-click anchor behind it stood 15 pt in the
        // bar's 24, so a click at the screen's top edge missed both (Sven on build 82: no right-click menu).
        .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Other apps")
    }

    /// The chevron, then the apps while unfolded; the chevron sits on its raised pill while they show.
    private func drawer(_ drawer: MenuAppsDrawer) -> some View {
        let title = drawer.isOpen ? "Hide other apps" : "Show other apps"
        return HStack(spacing: 0) {
            Button {
                withAnimation(MenuAppsDrawer.animation) { drawer.toggle() }
                if drawer.isOpen { apps.opened() }
            } label: {
                Image(systemName: drawer.isOpen ? "chevron.right" : "chevron.left")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(BarMetrics.glyphInk(style))
                    .frame(minWidth: 11)
                    .barTarget(title)
                    .barHoverPill(drawer.isOpen)
            }
            .buttonStyle(.kitPress)
            .accessibilityLabel(title)
            if drawer.isOpen {
                ForEach(apps.list, id: \.app.pid) { entry in
                    Group {
                        // Each pictured item its own, as the macOS menu bar shows them; the rest behind the app's glyph, so
                        // one item macOS does not draw (Screen Mirroring while idle) no longer folds the app into its glyph.
                        let pictured = entry.items.compactMap { item in apps.pictures.picture(item).map { (item, $0) } }
                        ForEach(pictured, id: \.0.handle) { item, picture in
                            MenuAppButton(apps: apps, entry: MenuApps.Entry(app: entry.app, items: [item]),
                                          label: MenuItemPictureView(picture: picture).barTarget(item.label))
                        }
                        if pictured.count < entry.items.count {
                            let rest = MenuApps.Entry(app: entry.app, items: entry.items.filter { apps.pictures.picture($0) == nil })
                            MenuAppButton(apps: apps, entry: rest, label: MenuAppIcon(app: entry.app).barTarget(rest.tooltip))
                        }
                    }
                    .transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : -6)))
                }
            }
        }
        .onHover { drawer.pointer(inside: $0) }
    }
}

/// One app's button: its one item pressed by a click, or its several as a native menu of their names under it. A
/// right-click does the same, as on the macOS menu bar (Sven on build 60: it showed Pilot's own item menu); an
/// Option+right-click passes to the Other apps item's menu (ScreenAnchor.optionPasses). A SwiftUI
/// Menu drew its label's icon at the image's own size, a big tile, whatever frame it was given (Sven on build 21).
private struct MenuAppButton<Label: View>: View {
    let apps: MenuApps
    let entry: MenuApps.Entry
    let label: Label
    @Environment(\.inTopBar) private var inTopBar
    @State private var anchor = ScreenAnchor.Box()

    var body: some View {
        Button(action: open) { label.background(ScreenAnchor(box: anchor, rightClick: open, optionPasses: true)) }
        .buttonStyle(.plain)
        // In the bar the label is a bar target with its own tooltip: a .help too showed the name twice (Sven, 2026-10-10).
        .help(inTopBar ? "" : entry.tooltip)
        .accessibilityLabel(entry.app.name)
    }

    private func open() {
        // In the top bar the item's menu opens under this button (MenuApps.press).
        let under = inTopBar ? anchor.view.map { (pid: entry.app.pid, view: $0) } : nil
        guard entry.items.count > 1 else { apps.press(entry.items[0], under: under); return }
        guard let view = anchor.view else { return }
        BarMenu.show(entry.items.map { item in (item.label, { _ = apps.press(item, under: under) }) }, under: view)
    }
}

/// An item as macOS draws it, at its own size, made smaller only to fit the bar: a grey one as a template in the bar's
/// glyph colour, so it reads on any bar colour; a coloured one as it is while Item colours is on, else in that glyph
/// colour too.
struct MenuItemPictureView: View {
    @Environment(\.style) private var style
    @Environment(\.barItemColours) private var itemColours
    let picture: MenuItemPictures.Picture

    var body: some View {
        Image(nsImage: picture.image).renderingMode(picture.image.isTemplate || !itemColours ? .template : .original).resizable().interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: picture.image.size.width, maxHeight: picture.image.size.height)
            .foregroundStyle(BarMetrics.glyphInk(style))
    }
}

extension MenuApps.Entry {
    /// An app's tooltip: its one item's name, else the app's.
    var tooltip: String { items.count == 1 ? items[0].label : app.name }
}

/// The front app's menus in the top bar (card agent-bo-95423015): its own menu in bold, then the rest, as the macOS menu
/// bar draws them; a click opens that menu under its title (AppMenuTitle). Offered less room than all of them take, it shows the ones that fit and a
/// chevron holding the rest (card agent-bo-95423016), down to the app's own menu and the chevron; TopBarRow folds it so
/// before any status item goes.
struct TopBarAppMenus: View {
    @Environment(\.style) private var style
    let menus: AppMenus

    var body: some View {
        let list = menus.list
        ViewThatFits(in: .horizontal) {
            ForEach((1...max(list.count, 1)).reversed(), id: \.self) { shown in row(list, shown: shown) }
        }
    }

    private func row(_ list: [MenuApps.Item], shown: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(list.prefix(shown).enumerated()), id: \.offset) { index, menu in
                AppMenuTitle(menus: menus, target: .menu(menu)) {
                    // The bar's ink, never the window's label colour: on a bar inked for its colour or wallpaper the two differ.
                    Text(menu.label).font(font(index)).lineLimit(1).fixedSize().foregroundStyle(style.color(\.text))
                }
            }
            if shown < list.count {
                AppMenuTitle(menus: menus, target: .folded(Array(list.dropFirst(shown)))) {
                    Image(systemName: "chevron.right.2").font(.system(size: 11, weight: .semibold)).foregroundStyle(BarInk(style: style).text2)
                }
                .accessibilityLabel("More menus")
            }
        }
    }

    /// The bar's face (Toybox's Nunito, Instrument's Geist with the app's own menu strong); the macOS menu bar never shows
    /// this item.
    private func font(_ index: Int) -> Font {
        switch style.kind {
        case .instrument: style.font(index == 0 ? \.barStrong : \.caption)
        case .toybox:
            ToyBar.font.weight(index == 0 ? .bold : .medium)
        }
    }
}

/// One of the App menus' titles, or the chevron holding the folded ones: a click reads its menu off the main thread and
/// hangs it under the title as Pilot's own native menu (BarMenu), the title lit while it shows, wherever the title sits
/// in the bar.
private struct AppMenuTitle<Label: View>: View {
    enum Target {
        case menu(MenuApps.Item)
        /// The chevron's: each folded menu a submenu.
        case folded([MenuApps.Item])
    }

    let menus: AppMenus
    let target: Target
    @ViewBuilder let label: () -> Label
    @State private var anchor = ScreenAnchor.Box()
    @State private var open = false

    var body: some View {
        let more: Bool = if case .folded = target { true } else { false }
        Button { Task { await show() } } label: {
            label().barTarget(more ? "More menus" : nil).barHoverPill(open)
                .background(ScreenAnchor(box: anchor))
        }
        .buttonStyle(.kitPress)
    }

    private func show() async {
        guard !open else { return }
        open = true
        defer { open = false }
        switch target {
        case .menu(let menu):
            let nodes = await menus.items(of: menu)
            guard let view = anchor.view, !nodes.isEmpty else { return }
            BarMenu.show(appMenu: nodes, under: view) { menus.press($0, in: menu) }
        case .folded(let folded):
            // Every folded menu read at once, kept in the bar's order.
            let read = await withTaskGroup(of: (Int, [MenuItemNode]).self) { group in
                for (i, menu) in folded.enumerated() { group.addTask { (i, await menus.items(of: menu)) } }
                var read: [Int: [MenuItemNode]] = [:]
                for await (i, nodes) in group { read[i] = nodes }
                return read
            }
            guard let view = anchor.view else { return }
            BarMenu.show(appMenus: folded.enumerated().map { i, menu in (menu.label, read[i] ?? [], { menus.press($0, in: menu) }) }, under: view)
        }
    }
}
