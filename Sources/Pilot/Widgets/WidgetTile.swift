import Observation
import PilotCore
import SwiftUI

/// What one placement draws now, read by its tile.
@Observable @MainActor
final class WidgetTileModel {
    var title = ""
    var icon = "🧩"
    var blocks: [Extension.Block] = []
    /// Why there are no blocks: an error, its widget gone, a no-data widget's description; nil while blocks show.
    var message: String?
    /// A locked widget with nothing it may draw: its Trust to run card shows, listing what it asks for (Q680), the lines
    /// worked out once as it locks (they look its program up on the PATH).
    var locked: Widget? {
        didSet { asking = locked.map { WidgetAsks.asking($0) } ?? .init(); if (oldValue == nil) != (locked == nil) { clicksChanged() } }
    }
    private(set) var asking = WidgetAsks.Asking()
    /// Its page over the tile (a made-here or trusted HTML widget): whether it draws no background (see-through), nil
    /// with no page.
    var page: Bool? { didSet { if (oldValue == nil) != (page == nil) { clicksChanged() } } }
    /// A JSON widget's own buttons (Q697), and the ones picked in its Edit widget (the Launcher), each titled by its
    /// action's name: both drawn as one grid under its blocks, in the look kit's button tiles (WidgetPickGrid).
    var buttons: [Widget.Button] = []
    var picked: [Widget.Button] = []
    /// The Launcher's tiles, Hyper+Space rows picked in its Edit widget (WidgetLauncher), drawn as a grid of icon tiles.
    var tiles: [WidgetLauncher.Tile] = []
    /// The GitHub widget's calendar, drawn in place of blocks (WidgetGitHub).
    var contributions: WidgetGitHub.Shown?
    /// What plays, for the Now playing widget, which draws it in place of blocks (NowPlayingPanel).
    var nowPlaying: NowPlaying?
    /// The Folder widget's folder, list and place in it (WidgetFolder), drawn by its own view.
    var folder: WidgetFolderModel?
    /// The Markets widget's symbols and prices (WidgetMarkets), drawn by its own panel.
    var markets: MarketsBoard?
    /// The class its placement keeps (Edit widget's Layout), nil for Auto: the tile's size picks it (Widget.SizeClass).
    var layout: Widget.SizeClass?
    /// Whether its blocks may be pressed: it has buttons, or shows an extension's page, whose blocks carry its own.
    var presses = false { didSet { if oldValue != presses { clicksChanged() } } }
    /// A press on a button in its blocks: the desk decides whether it runs (WidgetDesk.press).
    @ObservationIgnored var press: (Extension.Item.Action) -> Void = { _ in }
    /// A press on one of the Launcher's tiles, by its row's key (WidgetDesk.launch).
    @ObservationIgnored var launch: (String) -> Void = { _ in }
    /// Told when the tile starts or stops taking clicks: the desk sets its panel's mouse.
    @ObservationIgnored var clicksChanged: () -> Void = {}

    /// Whether the tile takes clicks: the card's button, a page's links, a JSON widget's buttons. Any other blocks tile lets
    /// them through to the desktop.
    var takesClicks: Bool { locked != nil || page != nil || presses }

    /// Its buttons, declared then picked, as the grid draws them.
    var grid: [Widget.Button] { buttons + picked }

    func reset() { blocks = []; message = nil; locked = nil; page = nil; picked = []; tiles = []; markets = nil }

    /// What it shows of `widget` before any data, from `values` (its settings as a placement keeps them): title, its
    /// buttons, the ones picked in Edit widget and the Launcher's tiles; the desk's feed and the Widgets page's preview
    /// both start here.
    func show(_ widget: Widget, values: [String: JSONValue]) {
        title = widget.title; icon = widget.icon
        buttons = widget.buttons
        picked = widget.actionsField.map { WidgetDesk.picked(values[$0.name]) } ?? []
        tiles = widget.menuField.map { WidgetLauncher.tiles(values[$0.name]) } ?? []
    }
}

/// A placement's tile: its blocks, its Trust to run card, or its message under its title, on glass while Look › Glass is
/// on, else solid (Q590). Under a page the tile is the page's ground: glass when the page is see-through, solid when it
/// is not, so a page whose see-through failed never shows the desktop through it. Its blocks draw in the look kit's
/// panel (DeskKit), so a JSON widget sits in one family with the HTML desk widgets (Sven, build 4). Its size picks the
/// class the panel draws (Widget.SizeClass), held while a drag stays near a line; Edit widget's Layout keeps one instead.
struct WidgetTile: View {
    @Environment(\.ink) private var ink
    let model: WidgetTileModel
    /// Trust this widget on the card: opens the Widgets page on its question, never trusts in one click.
    var trust: (String) -> Void = { _ in }
    var look: Look = .shared
    /// The class its size gave last, which a size near a line keeps.
    @State private var held: Widget.SizeClass?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DeskKit.radius, style: .continuous)
        let glass = look.glass && model.page != false
        // Light: the clipboard panel's tint inside the glass, in place of the kit's veil over it.
        let tint = glass ? look.widgetLightTint : nil
        let kit = DeskKit(look.theme, veiled: tint == nil)
        GeometryReader { box in
            let size = model.layout ?? Widget.SizeClass(box.size, after: held)
            Group {
                if let locked = model.locked {
                    WidgetTrustCard(widget: locked, asking: model.asking) { trust(locked.id) }.padding(14)
                } else if model.page != nil {
                    Color.clear
                } else if let player = model.nowPlaying {
                    NowPlayingPanel(player: player, title: model.title, kit: kit, size: size)
                } else if let folder = model.folder {
                    WidgetFolderView(model: folder).environment(\.deskKit, kit).environment(\.widgetFit, WidgetFit(size: size, width: box.size.width))
                } else if let markets = model.markets {
                    WidgetMarketsPanel(board: markets).environment(\.deskKit, kit).environment(\.widgetFit, WidgetFit(size: size, width: box.size.width))
                } else {
                    DeskKitPanel(model: model).environment(\.deskKit, kit)
                        .environment(\.widgetFit, WidgetFit(size: size, width: box.size.width))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: size, initial: true) { if model.layout == nil { held = $1 } }
        }
        .background { if !glass { shape.fill(ink.raised) } }
        .modifier(TileGlass(on: glass, blur: look.glassBlur, tint: tint, shape: shape))
        .clipShape(shape)
    }
}

// MARK: - The look kit, drawn natively

/// The look kit's tokens (Packaging/widgets/kit/pilot-kit.css) from the theme's colours, as a desk widget's page gets
/// them (WidgetWebView.theme): the HTML widgets never see the style, so neither do these. Its faces are the ones the
/// pages' WebKit draws: `ui-monospace` (SF Mono) for the kit's mono, the system face for its sans.
struct DeskKit: Sendable {
    static let radius: CGFloat = 18
    let dark: Bool
    let text, text2, text3, accent, good, amber, problem, line2: Color
    /// `--pk-veil`: the panel over the glass or the solid tile, the ground at 58 % on a dark theme, the surface at 66 %
    /// on a light one; clear on Light's glass, which is tinted instead (Look.widgetLightTint).
    let veil: Color
    /// `--pk-edge`, the panel's inset edge and the rows' hairlines; `--pk-track`, a meter's track.
    var edge: Color { text.opacity(0.09) }
    var track: Color { text.opacity(0.11) }

    init(_ theme: PilotTheme, veiled: Bool = true) {
        func c(_ rgb: UInt32) -> Color {
            Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
        }
        dark = theme.dark
        // Off the veil (Light's glass) the faintest text steps up one, as the clipboard's does on glass (StyleTokens.seeThrough).
        text = c(theme.text); text2 = c(theme.text2); text3 = c(veiled ? theme.text3 : theme.text2); accent = c(theme.accent)
        good = c(theme.good); amber = c(theme.amber); problem = c(theme.problem); line2 = c(theme.line2)
        veil = !veiled ? .clear : theme.dark ? c(theme.ground).opacity(0.58) : c(theme.surface).opacity(0.66)
    }

    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }

    /// A Pilot action's glyph on a button tile: its own in Hyper+Space's table, else a widget's usual picks' (the table
    /// leaves them to their module, which would put one glyph on every Launcher tile), else its module's.
    @MainActor static func symbol(forAction id: String) -> String {
        if let own = MenuEntry.actionSymbol(id) { return own }
        if id.hasPrefix(WidgetNotes.openPrefix) { return "note.text" }
        return picks[id] ?? MenuEntry.symbol(forAction: id)
    }

    private static let picks = ["apps.clean": "sparkles", "apps.update": "arrow.down.circle", "apps.install": "shippingbox",
                                "notes.toggle": "square.and.pencil"]

    /// A tone's colour: `.is-good`, `.is-warn`, `.is-alert`.
    func tone(_ tone: Extension.Tone?, else plain: Color) -> Color {
        switch tone { case .fine: good; case .warn: amber; case .alert: problem; case nil: plain }
    }
}

extension EnvironmentValues {
    /// The kit a widget tile's panel draws in, set by WidgetTile from Look's theme.
    @Entry var deskKit = DeskKit(.standard)
    /// The class a widget tile draws and its width, set by WidgetTile.
    @Entry var widgetFit = WidgetFit(size: .large, width: 0)
}

/// What a tile's panel lays out by: its class, and its width for a Wide list's columns.
struct WidgetFit: Equatable {
    let size: Widget.SizeClass, width: CGFloat
}

/// `.pk`: the kit's panel, its header, then the blocks, then the buttons grid, on the veil inside a hairline edge. A Strip
/// is one line instead (DeskKitStrip), its buttons and tiles as glyphs at its end; a Square's buttons and tiles are
/// glyphs too. Blocks the kit has no part for draw as they do in every class.
struct DeskKitPanel: View {
    @Environment(\.deskKit) private var kit
    @Environment(\.widgetFit) private var fit
    let model: WidgetTileModel

    var body: some View {
        let strip = fit.size == .strip && (model.blocks.isEmpty || DeskKitBlocks.draws(model.blocks))
        Group {
            if let shown = model.contributions { DeskKitContributions(shown: shown) } else
            if strip {
                HStack(spacing: 10) {
                    if model.blocks.isEmpty {
                        if model.tiles.isEmpty && model.grid.isEmpty { DeskKitHead(title: model.title, meta: nil).fixedSize() }
                        if let message = model.message { Text(message).font(kit.sans(12)).foregroundStyle(kit.text2).lineLimit(1) }
                    } else {
                        DeskKitStrip(title: model.title, blocks: model.blocks, act: model.press)
                    }
                    if !model.grid.isEmpty { Spacer(minLength: 0); WidgetPickGrid(buttons: model.grid, press: model.press, glyphs: true, row: true).fixedSize() }
                    if !model.tiles.isEmpty {
                        ScrollView(.horizontal) { WidgetLaunchGrid(tiles: model.tiles, launch: model.launch, glyphs: true, row: true) }.scrollIndicators(.never)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    DeskKitHead(title: model.title, meta: meta)
                    if model.blocks.isEmpty {
                        if let message = model.message {
                            Text(message).font(kit.sans(12)).foregroundStyle(kit.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    } else if DeskKitBlocks.draws(model.blocks) {
                        DeskKitBlocks(blocks: model.blocks, act: model.press)
                    } else {
                        // Blocks the kit has no part for (an extension page's sections, chats, inputs, asks): Pilot's own.
                        ExtensionBlocksView(blocks: model.blocks, compact: true, act: model.press)
                    }
                    if !model.grid.isEmpty {
                        // Under blocks the buttons sit at the panel's foot, as the kit's `.pk-foot` does.
                        if !model.blocks.isEmpty { Spacer(minLength: 0) }
                        WidgetPickGrid(buttons: model.grid, press: model.press, glyphs: fit.size == .square)
                    }
                    // More tiles than its size holds scroll under its header.
                    if !model.tiles.isEmpty {
                        ScrollView(.vertical) { WidgetLaunchGrid(tiles: model.tiles, launch: model.launch, glyphs: fit.size == .square) }.scrollIndicators(.never)
                    }
                }
            }
        }
        .padding(.top, strip ? 8 : 12).padding(.bottom, strip ? 8 : 14).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: strip ? .leading : .topLeading)
        .background(kit.veil)
        .overlay(RoundedRectangle(cornerRadius: DeskKit.radius, style: .continuous).strokeBorder(kit.edge, lineWidth: 1))
    }

    /// `.pk-meta`: how many rows a list widget shows.
    private var meta: String? {
        guard model.blocks.count == 1, case .list(_, let items, _) = model.blocks[0], !items.isEmpty else { return nil }
        return "\(items.count)"
    }
}

/// `.pk-head`: the title in small capitals, its meta at the right.
struct DeskKitHead: View {
    @Environment(\.deskKit) private var kit
    let title: String, meta: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title.uppercased()).font(kit.mono(9.5, .medium)).foregroundStyle(kit.text2).truncationMode(.tail)
                .accessibilityAddTraits(.isHeader).accessibilityLabel(title)
            Spacer(minLength: 0)
            if let meta { Text(meta.uppercased()).font(kit.mono(9.5)).foregroundStyle(kit.text3).layoutPriority(1) }
        }
        .tracking(0.855).lineLimit(1)
    }
}

/// A JSON widget's blocks in the kit's parts: a meter a `.pk-gauge`, a hero a `.pk-hero` over its `.pk-sub`, stats a
/// `.pk-stats`, a list `.pk-row`s, markdown the kit's words, a note a quiet line (or `.pk-empty` alone), buttons tiles.
/// A list or markdown takes the room left and scrolls past it, fading at its foot while there is more (`.pk-grow`).
/// By class (Strip is DeskKitStrip's): Large draws them as they always drew. Wide puts a hero beside what follows it,
/// a long list in two columns, and leaves the meters' notes out when there are more than two. Square draws meters as
/// rings, a hero alone and centred, and a list's titles without their asides.
struct DeskKitBlocks: View {
    @Environment(\.deskKit) private var kit
    @Environment(\.widgetFit) private var fit
    let blocks: [Extension.Block]
    let act: (Extension.Item.Action) -> Void

    /// Whether the kit has a part for every block, with nothing that asks first, an inline button, a badge, a picture or a
    /// second action (the ⋯ menu): those stay Pilot's own blocks, which handle them.
    static func draws(_ blocks: [Extension.Block]) -> Bool {
        blocks.allSatisfy { block in
            switch block {
            case .stats, .meter, .hero, .markdown, .note: true
            case .buttons(let actions): actions.allSatisfy { Extension.Asking($0) == nil }
            case .list(_, let items, let reorder):
                reorder == nil && items.allSatisfy { item in
                    item.actions.count <= 1 && item.inline.isEmpty && item.badges.isEmpty && item.image == nil
                        && item.actions.allSatisfy { Extension.Asking($0) == nil }
                }
            default: false
            }
        }
    }

    var body: some View {
        // The first list or markdown grows; one note alone is an empty state that fills the panel.
        let grows = blocks.firstIndex { if case .list = $0 { true } else if case .markdown = $0 { true } else { false } }
        let meters = blocks.compactMap { if case .meter(let meter) = $0 { meter } else { nil } }
        let hero: Extension.Block.Hero? = if case .hero(let hero) = blocks.first { hero } else { nil }
        let square = fit.size == .square
        VStack(alignment: .leading, spacing: 10) {
            if blocks.count == 1, case .note(let note) = blocks[0] {
                empty(note)
            } else if square, let hero {
                heroView(hero, centred: true)
            } else if square, !meters.isEmpty {
                rings(meters)
                ForEach(blocks.indices, id: \.self) { i in if case .meter = blocks[i] {} else { block(blocks[i]) } }
            } else if fit.size == .wide, let hero, blocks.count > 1 {
                HStack(alignment: .top, spacing: 16) {
                    heroView(hero).fixedSize()
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(blocks.indices.dropFirst(), id: \.self) { i in
                            if i == grows { DeskKitGrow { block(blocks[i]) } } else { block(blocks[i]) }
                        }
                    }
                }
            } else {
                ForEach(blocks.indices, id: \.self) { i in
                    if i > 0, Self.ruled(blocks[i - 1]) { kit.edge.frame(height: 1).accessibilityHidden(true) }
                    if i == grows { DeskKitGrow { block(blocks[i]) } } else { block(blocks[i]) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: grows == nil && !(square && (hero != nil || !meters.isEmpty)) ? nil : .infinity, alignment: .topLeading)
    }

    /// A Square's meters: rings two to a row, each its figure inside and its label under, as big as the room allows.
    private func rings(_ meters: [Extension.Block.Meter]) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(stride(from: 0, to: meters.count, by: 2)), id: \.self) { i in
                HStack(spacing: 8) {
                    ForEach(i..<min(i + 2, meters.count), id: \.self) { DeskKitRing(meter: meters[$0]) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `.pk-rule` under a hero, as the desk clock draws one.
    static func ruled(_ above: Extension.Block) -> Bool { if case .hero = above { true } else { false } }

    @ViewBuilder private func block(_ block: Extension.Block) -> some View {
        switch block {
        case .meter(let meter): gauge(meter, notes: fit.size != .wide || blocks.count { if case .meter = $0 { true } else { false } } <= 2)
        case .hero(let hero): heroView(hero)
        case .stats(let stats): statsRow(stats)
        case .list(let title, let items, _): list(title, items)
        case .markdown(let text): DeskKitMarkdown(text: text)
        case .note(let note): noteLine(note)
        case .buttons(let actions):
            DeskKitTiles(count: actions.count) { i in
                DeskKitTile(symbol: Self.symbol(actions[i]), title: actions[i].label) { act(actions[i]) }
            }
        default: EmptyView()
        }
    }

    /// An action's glyph: its own icon, a Pilot action's as Hyper+Space shows it, else an arrow out.
    static func symbol(_ action: Extension.Item.Action) -> String {
        if let icon = action.icon, let symbol = Extension.Item.Action.icons[icon] { return symbol }
        if case .pilot(let id) = action.kind { return DeskKit.symbol(forAction: id) }
        return "arrow.up.forward"
    }

    /// `.pk-gauge`: the label in small capitals, a thin track, the figure; the note and the countdown under the track.
    private func gauge(_ meter: Extension.Block.Meter, notes: Bool) -> some View {
        let value = meter.value ?? "\(Int(meter.percent.rounded()))%"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(meter.label.uppercased()).font(kit.mono(9.5)).tracking(0.76).foregroundStyle(kit.text3)
                    .lineLimit(1).frame(width: 54, alignment: .leading)
                DeskKitMeter(percent: meter.percent, fill: kit.tone(meter.tone, else: kit.text2), mark: meter.mark,
                               markColour: meter.markTone == .alert ? kit.problem : kit.tone(meter.markTone, else: kit.text))
                Text(value).font(kit.mono(11.5)).monospacedDigit().foregroundStyle(kit.text).lineLimit(1)
                    .frame(minWidth: 34, alignment: .trailing).fixedSize()
            }
            if notes, meter.note != nil || meter.resetsAt != nil {
                HStack(spacing: 8) {
                    if let note = meter.note { Text(note) }
                    Spacer(minLength: 0)
                    if let resetsAt = meter.resetsAt {
                        TimelineView(.everyMinute) { context in Text(Extension.Block.Meter.countdown(to: resetsAt, now: context.date)) }
                    }
                }
                .font(kit.mono(10)).foregroundStyle(kit.text3).lineLimit(1)
                .padding(.leading, 64)
            }
        }
        .help(meter.help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityValue(meter.value ?? "\(Int(meter.percent.rounded())) percent")
    }

    /// `.pk-hero`: the figure big and light, its unit raised, its glyph before it; its place a `.pk-sub` under it and its
    /// stats a `.pk-stats` row. The place never sits beside the figure, so a long date never squeezes the time.
    /// Centred (a Square's), it stands alone in the middle of the panel, its stats left out.
    private func heroView(_ hero: Extension.Block.Hero, centred: Bool = false) -> some View {
        VStack(alignment: centred ? .center : .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                if let glyph = hero.glyph { ExtensionGlyph(glyph: glyph, size: 30).foregroundStyle(kit.text2) }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(hero.value).font(kit.mono(38, .light)).tracking(-1.14).monospacedDigit()
                        .foregroundStyle(kit.tone(hero.tone, else: kit.text))
                    if let unit = hero.unit { Text(unit).font(kit.mono(16)).foregroundStyle(kit.text2) }
                }
                .lineLimit(1).minimumScaleFactor(0.5)
            }
            if let place = hero.place { Text(place).font(kit.mono(10.5)).foregroundStyle(kit.text3).lineLimit(centred ? 2 : 1).multilineTextAlignment(centred ? .center : .leading) }
            if !hero.stats.isEmpty, !centred { statsRow(hero.stats).padding(.top, 6) }
        }
        .frame(maxWidth: centred ? .infinity : nil, maxHeight: centred ? .infinity : nil)
        .accessibilityElement(children: .combine)
    }

    /// `.pk-stats`: figures side by side, each its label in small capitals over its value.
    private func statsRow(_ stats: [Extension.Block.Stat]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(stats.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stats[i].label.uppercased()).font(kit.mono(9)).tracking(0.81).foregroundStyle(kit.text3)
                    Text(stats[i].value).font(kit.mono(15)).monospacedDigit().foregroundStyle(kit.tone(stats[i].tone, else: kit.text))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// `.pk-list`: a `.pk-group` heading, then rows on hairlines, each its mark, its title in the sans and its subtitle
    /// (a note's date) as a dim `.pk-aside`; a press runs its one action.
    private func list(_ title: String?, _ items: [Extension.Item]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title.uppercased()).font(kit.mono(9)).tracking(0.81).foregroundStyle(kit.text3).padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            if items.isEmpty { Text("Nothing here.").font(kit.sans(12.5)).foregroundStyle(kit.text3).padding(.vertical, 5) }
            // A Wide tile with room for two rows side by side fills its first column, then its second.
            if fit.size == .wide, fit.width >= 360, items.count > 3 {
                let half = (items.count + 1) / 2
                HStack(alignment: .top, spacing: 16) {
                    rows(Array(items[..<half]))
                    rows(Array(items[half...]))
                }
            } else {
                rows(items)
            }
        }
    }

    private func rows(_ items: [Extension.Item]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                if i > 0 { kit.edge.frame(height: 1).accessibilityHidden(true) }
                DeskKitRow(item: items[i], aside: fit.size != .square, act: act)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// A note among other blocks: one quiet mono line, its glyph, its aside at the right.
    private func noteLine(_ note: Extension.Block.Note) -> some View {
        HStack(spacing: 6) {
            if let symbol = note.icon.flatMap({ Extension.Item.Action.icons[$0] }) {
                Image(systemName: symbol).font(.system(size: 10)).accessibilityHidden(true)
            }
            Text(note.text).lineLimit(2)
            Spacer(minLength: 6)
            if let aside = note.aside { Text(aside).lineLimit(1) }
        }
        .font(kit.mono(10.5)).foregroundStyle(kit.text3)
        .help(note.help ?? "")
        .accessibilityElement(children: .combine)
    }

    /// `.pk-empty`: a note alone, centred, its glyph over its words.
    private func empty(_ note: Extension.Block.Note) -> some View {
        VStack(spacing: 6) {
            Image(systemName: note.icon.flatMap { Extension.Item.Action.icons[$0] } ?? "circle.dashed")
                .font(.system(size: 18, weight: .light)).foregroundStyle(kit.text3).accessibilityHidden(true)
            Text(note.text).font(kit.sans(12.5, .medium)).foregroundStyle(kit.text2).multilineTextAlignment(.center)
            if let aside = note.aside { Text(aside).font(kit.mono(10.5)).foregroundStyle(kit.text3) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(note.help ?? "")
        .accessibilityElement(children: .combine)
    }
}

/// A Square's meter: a ring on the meter's track, filled to its share in its tone, its figure inside and its label under,
/// shortened past four letters (MEM, BAT).
private struct DeskKitRing: View {
    @Environment(\.deskKit) private var kit
    let meter: Extension.Block.Meter

    var body: some View {
        let share = min(max(meter.percent, 0), 100) / 100
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(kit.track, lineWidth: 4)
                Circle().trim(from: 0, to: share).stroke(kit.tone(meter.tone, else: kit.text2), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(meter.value ?? "\(Int(meter.percent.rounded()))%").font(kit.mono(11.5)).monospacedDigit().foregroundStyle(kit.text)
                    .lineLimit(1).minimumScaleFactor(0.6).padding(7)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(DeskKitStrip.short(meter.label)).font(kit.mono(9)).tracking(0.76).foregroundStyle(kit.text3).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(meter.help ?? meter.note ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meter.label)
        .accessibilityValue(meter.value ?? "\(Int(meter.percent.rounded())) percent")
    }
}

/// A Strip's one line: the title first when a list, words or a note lead it; then each block's line: a meter's or a
/// stat's label and figure, a hero's figure and place, a list's first row with how many follow (a press opens it), the
/// words' first line, a note's text.
struct DeskKitStrip: View {
    @Environment(\.deskKit) private var kit
    let title: String
    let blocks: [Extension.Block]
    let act: (Extension.Item.Action) -> Void

    /// A label in a strip or under a ring: four letters at most, a longer one its first three (MEM, BAT).
    static func short(_ label: String) -> String { (label.count > 4 ? String(label.prefix(3)) : label).uppercased() }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let first = blocks.first, Self.titled(first) { DeskKitHead(title: title, meta: nil).fixedSize() }
            ForEach(blocks.indices, id: \.self) { i in line(blocks[i]) }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func titled(_ block: Extension.Block) -> Bool {
        switch block { case .list, .markdown, .note: true; default: false }
    }

    @ViewBuilder private func line(_ block: Extension.Block) -> some View {
        switch block {
        case .meter(let meter): pair(meter.label, meter.value ?? "\(Int(meter.percent.rounded()))%", kit.tone(meter.tone, else: kit.text))
        case .stats(let stats): ForEach(stats.indices, id: \.self) { pair(stats[$0].label, stats[$0].value, kit.tone(stats[$0].tone, else: kit.text)) }
        case .hero(let hero):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(hero.value + (hero.unit ?? "")).font(kit.mono(22, .light)).monospacedDigit().foregroundStyle(kit.tone(hero.tone, else: kit.text))
                    .fixedSize()
                if let place = hero.place { Text(place).font(kit.mono(10.5)).foregroundStyle(kit.text3) }
            }
        case .list(_, let items, _):
            if let item = items.first {
                Button { item.actions.first.map(act) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title).font(kit.sans(12.5)).foregroundStyle(kit.text).truncationMode(.tail)
                        if let subtitle = item.subtitle { Text(subtitle).font(kit.mono(10)).foregroundStyle(kit.text3).truncationMode(.tail) }
                        if items.count > 1 { Text("+\(items.count - 1)").font(kit.mono(10)).foregroundStyle(kit.text3).fixedSize() }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain).disabled(item.actions.isEmpty).help(item.actions.first?.label ?? "")
            } else {
                Text("Nothing here.").font(kit.sans(12.5)).foregroundStyle(kit.text3)
            }
        case .markdown(let text):
            Text(Self.firstLine(text)).font(kit.sans(12.5)).foregroundStyle(kit.text).truncationMode(.tail)
        case .note(let note):
            HStack(spacing: 6) {
                if let symbol = note.icon.flatMap({ Extension.Item.Action.icons[$0] }) { Image(systemName: symbol).accessibilityHidden(true) }
                Text(note.text)
                if let aside = note.aside { Text(aside).foregroundStyle(kit.text3) }
            }
            .font(kit.mono(10.5)).foregroundStyle(kit.text2)
        default: EmptyView()
        }
    }

    /// A label in small capitals and its figure.
    private func pair(_ label: String, _ value: String, _ colour: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(Self.short(label)).font(kit.mono(9.5)).tracking(0.76).foregroundStyle(kit.text3)
            Text(value).font(kit.mono(13)).monospacedDigit().foregroundStyle(colour)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// The words' first heading, paragraph or item, as the kit's words draw it.
    static func firstLine(_ text: String) -> AttributedString {
        let type = ReadingType()
        for part in DetailBlock.split(text) {
            switch part {
            case .heading(_, let words), .paragraph(let words), .item(_, let words): return type.inline(words)
            default: continue
            }
        }
        return AttributedString("–")
    }
}

/// `.pk-grow` with `.pk-fade`: takes the room left and scrolls past it, its foot fading while there is more below.
private struct DeskKitGrow<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var more = false

    var body: some View {
        ScrollView(.vertical) { content.frame(maxWidth: .infinity, alignment: .leading) }
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y + g.containerSize.height < g.contentSize.height - 2 } action: { more = $1 }
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: more ? 0.82 : 1),
                                       .init(color: more ? .clear : .black, location: 1)], startPoint: .top, endPoint: .bottom)
            }
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// `.pk-meter`: a 4 pt track at the text's 11 %, its fill, and its mark a hairline tick a little taller.
struct DeskKitMeter: View {
    @Environment(\.deskKit) private var kit
    let percent: Double, fill: Color, mark: Double?, markColour: Color

    var body: some View {
        GeometryReader { track in
            Capsule().fill(kit.track)
                .overlay(alignment: .leading) { Capsule().fill(fill).frame(width: track.size.width * min(max(percent, 0), 100) / 100) }
                .overlay(alignment: .leading) {
                    if let mark {
                        Capsule().fill(markColour).frame(width: 1.5, height: track.size.height + 6)
                            .offset(x: min(max(track.size.width * mark / 100 - 0.75, 0), track.size.width - 1.5))
                    }
                }
        }
        .frame(height: 4)
        .frame(minWidth: 24)
    }
}

/// `.pk-row`: its mark, its title in the sans, its subtitle as the dim aside; a press runs its action.
private struct DeskKitRow: View {
    @Environment(\.deskKit) private var kit
    let item: Extension.Item
    /// Its subtitle at the right: a Square leaves it out.
    var aside = true
    let act: (Extension.Item.Action) -> Void
    @State private var over = false

    var body: some View {
        Button { item.actions.first.map(act) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let icon = item.icon {
                    Group {
                        if icon == "📌" { Image(systemName: "pin").font(.system(size: 9.5)).foregroundStyle(kit.text3) }
                        else { Text(icon).font(.system(size: 11)) }
                    }
                    .frame(width: 14).accessibilityHidden(true)
                }
                Text(item.title).font(kit.sans(12.5)).foregroundStyle(kit.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if aside, let subtitle = item.subtitle { Text(subtitle).font(kit.mono(10)).foregroundStyle(kit.text3).lineLimit(1).fixedSize() }
            }
            .padding(.vertical, 5).padding(.horizontal, 4)
            .background { if over && !item.actions.isEmpty { RoundedRectangle(cornerRadius: 6).fill(kit.text.opacity(0.06)) } }
            .padding(.horizontal, -4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(item.actions.isEmpty)
        .onHover { over = $0 }
        .help(item.actions.first?.label ?? "")
        // Its one action on a right-click too, as Pilot's own rows offer it.
        .contextMenu { if let action = item.actions.first { Button(action.label) { act(action) } } }
        .accessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
    }
}

/// An extension's or a note's markdown in the kit's words: headings and paragraphs in the sans, list markers and code dim.
private struct DeskKitMarkdown: View {
    @Environment(\.deskKit) private var kit
    let text: String

    var body: some View {
        let parts = DetailBlock.split(text), type = ReadingType()
        VStack(alignment: .leading, spacing: 5) {
            ForEach(parts.indices, id: \.self) { i in
                switch parts[i] {
                case .heading(let level, let words):
                    Text(type.inline(words)).font(kit.sans(level <= 1 ? 14 : 13, .semibold)).foregroundStyle(kit.text)
                        .padding(.top, i == 0 ? 0 : 4).accessibilityAddTraits(.isHeader)
                case .paragraph(let words): Text(type.inline(words)).foregroundStyle(kit.text)
                case .item(let marker, let words):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(marker).font(kit.mono(11)).foregroundStyle(kit.text3)
                        Text(type.inline(words)).foregroundStyle(kit.text)
                    }
                case .rule: kit.edge.frame(height: 1)
                case .code(let code): Text(code).font(kit.mono(11)).foregroundStyle(kit.text2)
                }
            }
        }
        .font(kit.sans(12.5))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

/// The kit's buttons, as many to a row as the tile's width holds.
struct DeskKitTiles<Tile: View>: View {
    let count: Int
    @ViewBuilder let tile: (Int) -> Tile

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
            // By place: two buttons may run one action.
            ForEach(0..<count, id: \.self) { tile($0) }
        }
    }
}

/// A button tile, derived from the kit's parts (it has no button of its own): the action's glyph and its name on the
/// text's faint fill inside the kit's hairline edge; lighter under the pointer, pressed in to 0.96.
struct DeskKitTile: View {
    @Environment(\.deskKit) private var kit
    let symbol: String, title: String
    /// Its glyph alone (a Strip's or a Square's), its name in its tooltip.
    var glyph = false
    let press: () -> Void

    var body: some View {
        Button(action: press) {
            if glyph {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(kit.text2).frame(width: 32, height: 28).accessibilityHidden(true)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(kit.text2).frame(width: 15).accessibilityHidden(true)
                    Text(title).font(kit.sans(11.5, .medium)).foregroundStyle(kit.text).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 32)
            }
        }
        .buttonStyle(DeskKitTileStyle(kit: kit))
        .accessibilityLabel(title)
    }
}

private struct DeskKitTileStyle: ButtonStyle {
    let kit: DeskKit
    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration, kit: kit)
    }

    private struct Tile: View {
        let configuration: Configuration, kit: DeskKit
        @State private var over = false
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            configuration.label
                .background(kit.text.opacity(configuration.isPressed ? 0.13 : over ? 0.10 : 0.06), in: shape)
                .overlay(shape.strokeBorder(kit.edge, lineWidth: 1))
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
                .onHover { over = $0 }
        }
    }
}

/// A JSON widget's buttons, its own and those picked in Edit widget (the Launcher): one grid, as many to a row as the
/// tile's width holds, each a kit tile with its action's glyph and title, a press handing its action to the desk
/// (WidgetDesk.press). Every widget draws its buttons this one way (ADR 0016).
struct WidgetPickGrid: View {
    let buttons: [Widget.Button]
    let press: (Extension.Item.Action) -> Void
    /// Glyphs alone (a Square's and a Strip's), in a grid, or with `row` in one line (a Strip's).
    var glyphs = false, row = false

    var body: some View {
        if row {
            HStack(spacing: 6) { ForEach(buttons.indices, id: \.self, content: tile) }
        } else if glyphs {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 6)], alignment: .leading, spacing: 6) { ForEach(buttons.indices, id: \.self, content: tile) }
        } else {
            DeskKitTiles(count: buttons.count, tile: tile)
        }
    }

    private func tile(_ i: Int) -> some View {
        let button = buttons[i]
        return DeskKitTile(symbol: DeskKit.symbol(forAction: button.action), title: button.title, glyph: glyphs) {
            press(Extension.Item.Action(kind: .pilot(button.action), title: button.title))
        }
        .help(glyphs ? "\(button.title): \(button.action)" : button.action)
    }
}

/// The Launcher's tiles: as many to a row as the tile's width holds, each the kit's tile with its row's icon over its
/// title, an app's own icon or the row's glyph, a press running the row as Hyper+Space does (WidgetLauncher.run). A
/// Square's are icons alone, a Strip's icons alone in one line (`row`), each titled in its tooltip.
struct WidgetLaunchGrid: View {
    @Environment(\.deskKit) private var kit
    let tiles: [WidgetLauncher.Tile]
    let launch: (String) -> Void
    var glyphs = false, row = false

    var body: some View {
        if row {
            HStack(spacing: 6) { ForEach(tiles, id: \.key, content: tile) }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: glyphs ? 40 : 62), spacing: glyphs ? 6 : 8)], alignment: .leading, spacing: glyphs ? 6 : 8) {
                // By place: a key is listed once (Widget.menuPicks).
                ForEach(tiles, id: \.key, content: tile)
            }
        }
    }

    private func tile(_ tile: WidgetLauncher.Tile) -> some View {
        let side: CGFloat = glyphs ? 24 : 28
        return Button { launch(tile.key) } label: {
            VStack(spacing: 5) {
                Group {
                    if let icon = tile.icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: side, height: side)
                    } else {
                        Image(systemName: tile.symbol).font(.system(size: glyphs ? 15 : 17)).foregroundStyle(kit.text2)
                    }
                }
                .frame(width: side, height: side).accessibilityHidden(true)
                if !glyphs {
                    // Two lines before it shortens: "Clean this Mac" whole in a 300-point Launcher.
                    Text(tile.title).font(kit.sans(10.5, .medium)).foregroundStyle(kit.text).lineLimit(2).multilineTextAlignment(.center)
                        .minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, glyphs ? 4 : 6).padding(.vertical, glyphs ? 6 : 8)
            // One height for every tile, a two-line title's, so a row lines up.
            .frame(minWidth: glyphs ? 40 : nil, maxWidth: row ? nil : .infinity, minHeight: glyphs ? 38 : 76, maxHeight: glyphs ? 38 : 76)
        }
        .buttonStyle(DeskKitTileStyle(kit: kit))
        .accessibilityLabel(tile.title)
        .help(tile.title)
    }
}

/// The Trust to run card (Q680): a locked widget's command, sites and readings in the words Trust this widget shows, with
/// the button that opens that question on the Widgets page.
struct WidgetTrustCard: View {
    @Environment(\.ink) private var ink
    let widget: Widget
    let asking: WidgetAsks.Asking
    let trust: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(widget.icon)  \(WidgetAsks.shown(widget.title))").font(.headline).foregroundStyle(ink.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "lock.fill").foregroundStyle(ink.muted).accessibilityLabel("Locked")
            }
            Text("Locked until you trust it. It asks to:").font(.caption).foregroundStyle(ink.text2)
            // Every line whole, scrolled when long: the card lists everything the widget asks for (ADR 0016).
            ScrollView(.vertical) { WidgetAskingView(asking: asking, font: .caption2) }
            Spacer(minLength: 0)
            Button("Trust this widget…", action: trust).buttonStyle(.pilot).controlSize(.small)
        }
    }
}

/// What a widget asks for, as the card and Trust this widget draw it: Pilot's lines, then the command's header and its
/// words, one a numbered row, so a long word wraps under its own number and never starts a line of its own.
struct WidgetAskingView: View {
    @Environment(\.ink) private var ink
    let asking: WidgetAsks.Asking
    var font: Font = .caption2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(asking.lines.enumerated()), id: \.offset) { _, line in
                Text(WidgetAsks.shown(line)).font(font).foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
            }
            if let header = asking.header {
                Text(WidgetAsks.shown(header)).font(font).foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(asking.words.enumerated()), id: \.offset) { i, word in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("№\(i + 1)").font(font.monospacedDigit()).foregroundStyle(ink.muted).frame(width: 30, alignment: .trailing)
                        Text(WidgetAsks.shown(word)).font(font.monospaced()).foregroundStyle(ink.text).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

struct TileGlass<S: Shape>: ViewModifier {
    let on: Bool, blur: GlassBlur
    var tint: Color?
    let shape: S
    func body(content: Content) -> some View {
        // Look's Blur: Full regular glass, Light clear, Off none.
        if on, let glass = blur.glass { content.glassEffect(glass.tint(tint), in: shape) } else { content }
    }
}

extension Look {
    /// Blur is Light where the clipboard panel is glass: a widget tile then draws that panel's tint.
    var widgetLightGlass: Bool { glassBlur == .light && glassFace(.clipboard) }

    /// A widget tile's tint on Light: the clipboard panel's (glassTint, Transparency's ground over the canvas), so the two
    /// read alike. A tile has no card under its words, so where that ground leaves body text under the 4.5 : 1 floor it
    /// lifts in 2 % steps. Nil on Full and Off and wherever the clipboard is solid: those keep the kit's veil.
    var widgetLightTint: Color? {
        guard widgetLightGlass else { return nil }
        let tint = glassTint(on: .clipboard)
        let canvas = Contrast.rgb(chromeTokens(.clipboard).colors.canvas.rgb), text = Contrast.rgb(theme.text2)
        let spot = wallpaperSpot ?? theme.wallpaper.colour
        var alpha = tint.alphaComponent
        while alpha < 1, Contrast.ratio(text, Contrast.mix(canvas, spot, alpha)) < MaterialValues.floor { alpha = min(1, alpha + 0.02) }
        return Color(nsColor: tint.withAlphaComponent(alpha))
    }
}
