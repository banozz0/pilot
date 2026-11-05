import PilotCore
import SwiftUI

// Home's block layouts (story 167, Sven 2026-10-10 on build 22: "every new addition should become optimised to fit in the
// home screen, have different variants of how all widgets can look"; P91: the desktop widgets' four classes): what an
// extension's Wide card keeps, and the Strip and Square every block draws alike through the Kit, from its one figure.

/// What a block's smaller sizes keep of an extension's page.
enum HomeVariant {
    /// A Wide card: a page of usage cards keeps just their meters (`usage`); else the page's first stats or meter block
    /// and at most `rows` rows of its first list, or its first buttons when it has no list; a page with none of them keeps
    /// its first block.
    static func medium(_ blocks: [Extension.Block], rows: Int = 3) -> [Extension.Block] {
        let cards = usage(blocks)
        if !cards.isEmpty { return cards }
        let flat = flattened(blocks)
        var kept: [Extension.Block] = []
        if let figures = flat.first(where: { if case .stats = $0 { true } else if case .meter = $0 { true } else { false } }) { kept.append(figures) }
        if let list = flat.first(where: { if case .list = $0 { true } else { false } }), case .list(let title, let items, _) = list {
            kept.append(.list(title: title, items: Array(items.prefix(rows))))
        } else if let buttons = flat.first(where: { if case .buttons = $0 { true } else { false } }) {
            kept.append(buttons)
        }
        return kept.isEmpty ? Array(flat.prefix(1)) : kept
    }

    /// The page's usage cards, cut to their meters: each top-level section holding a meter and no list (AI usage's
    /// Claude and Codex), so Home shows just the usage lines, each under its card's head, at every size; the status rows,
    /// links and buttons stay on the page (Sven on 1.0.2: "ai usage should show just usage lines"). A section with a list
    /// (Now playing's track) is no usage card.
    static func usage(_ blocks: [Extension.Block]) -> [Extension.Block] {
        blocks.compactMap { block in
            guard case .section(let title, let subtitle, let aside, let asideNote, let inner, let icon, let help) = block,
                  !inner.contains(where: { if case .list = $0 { true } else { false } }) else { return nil }
            let meters = inner.filter { if case .meter = $0 { true } else { false } }
            return meters.isEmpty ? nil
                : .section(title: title, subtitle: subtitle, aside: aside, asideNote: asideNote, blocks: meters, icon: icon, help: help)
        }
    }

    /// A Strip's or Square's figure: the first stat, else the first meter's value; its label under it.
    static func figure(_ blocks: [Extension.Block]) -> (value: String, label: String, tone: Extension.Tone?)? {
        for block in flattened(blocks) {
            switch block {
            case .stats(let stats): if let stat = stats.first { return (stat.value, stat.label, stat.tone) }
            case .meter(let meter): return (meter.value ?? "\(Int(meter.percent.rounded())) %", meter.label, meter.tone)
            default: continue
            }
        }
        return nil
    }

    /// The rows of the page's first list, which a small card folds; none on a page of usage cards, whose small card is
    /// its usage lines too.
    static func list(_ blocks: [Extension.Block]) -> [Extension.Item]? {
        guard usage(blocks).isEmpty else { return nil }
        for block in flattened(blocks) { if case .list(_, let items, _) = block { return items } }
        return nil
    }

    /// What a block of usage cards can show, most first (T34, Sven 2026-11-04: "ai usage in home shows alot of free space
    /// rather then more usage bars"): every card in full, then every card small (the bar popover's rows), then small
    /// without notes, then each card's first meters down to one; only then fewer cards. Every provider stays as long as
    /// one meter each fits. A small card needs less width, so a block sets more of them across.
    static func usageFits(_ cards: [Extension.Block]) -> [(cards: [Extension.Block], compact: Bool)] {
        let most = cards.map { meters(of: $0).count }.max() ?? 0
        var fits: [(cards: [Extension.Block], compact: Bool)] = [(cards, false), (cards, true)]
        for keep in stride(from: most, through: 1, by: -1) { fits.append((cards.map { cut($0, to: keep) }, true)) }
        let ones = cards.map { cut($0, to: 1) }
        for count in stride(from: ones.count - 1, through: 1, by: -1) { fits.append((Array(ones.prefix(count)), true)) }
        return fits
    }

    /// How many usage cards a block `width` wide sets side by side: one per 240 pt of its content (170 pt small), at
    /// most one per card.
    static func across(_ count: Int, width: CGFloat, compact: Bool) -> Int {
        guard width.isFinite else { return 1 }
        return max(1, min(count, Int((width - 32) / (compact ? 170 : 240))))
    }

    private static func meters(of card: Extension.Block) -> [Extension.Block] {
        guard case .section(_, _, _, _, let inner, _, _) = card else { return [] }
        return inner.filter { if case .meter = $0 { true } else { false } }
    }

    /// A usage card with its first `keep` meters, their notes left out.
    private static func cut(_ card: Extension.Block, to keep: Int) -> Extension.Block {
        guard case .section(let title, let subtitle, let aside, let asideNote, _, let icon, let help) = card else { return card }
        let kept = meters(of: card).prefix(keep).map { block -> Extension.Block in
            guard case .meter(let m) = block else { return block }
            return .meter(.init(label: m.label, percent: m.percent, tone: m.tone, resetsAt: m.resetsAt, mark: m.mark, value: m.value,
                                markTone: m.markTone, help: m.help ?? m.note))
        }
        return .section(title: title, subtitle: subtitle, aside: aside, asideNote: asideNote, blocks: kept, icon: icon, help: help)
    }

    /// The blocks with each section's own in its place.
    static func flattened(_ blocks: [Extension.Block]) -> [Extension.Block] {
        blocks.flatMap { block -> [Extension.Block] in
            if case .section(_, _, _, _, let inner, _, _) = block { flattened(inner) } else { [block] }
        }
    }
}

extension HomeLayout.Block {
    /// The page a block's Strip or Square opens.
    var place: AppPlace {
        switch self {
        case .workspaces: AppPlace(.workspaces)
        case .keyboard: AppPlace(.binds)
        case .mostUsed: AppPlace(.activity)
        case .greeting, .pilot: AppPlace(.general)
        case .thisMac: AppPlace(.stats)
        case .clipboard: AppPlace(.clipboard)
        case .quickActions: AppPlace(.menu)
        }
    }
}

/// What a block's Strip and Square show: its symbol or emoji, its title, and one figure with its label.
struct HomeGlance {
    var symbol: String?
    var emoji: String?
    let title: String
    var value: String?
    var label: String?
    var tone: Color?
}

/// Reads a block's glance and hands it on: a built-in block's from the engine, an extension's from its bar item's text or
/// its page's first figure. An extension block asks its page on the page's pace while the window shows, as its card does.
private struct GlanceReader<Content: View>: View {
    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink
    let id: String
    let parts: HomeParts
    @ViewBuilder let content: (HomeGlance) -> Content

    var body: some View {
        if let block = HomeLayout.Block(rawValue: id) {
            content(builtIn(block))
        } else if let widget = parts.widget(id) {
            content(HomeGlance(emoji: widget.model.icon, title: widget.title))
        } else if let ext = HomeLayout.extensionID(id) {
            let model = parts.pageModel(ext)
            let link = parts.pages.first { $0.id == ext }
            let figure = model.blocks.flatMap(HomeVariant.figure)
            let bar = parts.sources.barText(ext)
            content(HomeGlance(emoji: link?.icon ?? "🧩", title: link?.title ?? ext, value: bar ?? figure?.value ?? (model.problem == nil ? nil : "!"),
                               label: bar == nil ? figure?.label : nil, tone: figure.map { ink.tone($0.tone, else: ink.text) }))
                .asksPage(model, onScreen: parts.onScreen)
        }
    }

    private func builtIn(_ block: HomeLayout.Block) -> HomeGlance {
        var glance = HomeGlance(symbol: block.symbol, title: block.title)
        switch block {
        case .greeting:
            (glance.value, glance.label) = (HomeGreeting.hello(at: .now), Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        case .workspaces:
            let tiler = engine.observers.tiler
            (glance.value, glance.label) = tiler.focused.map { ($0, "workspace now") } ?? ("–", "tiling stopped")
        case .keyboard:
            (glance.value, glance.label) = ("\(parts.binds.taken)", "keys bound")
        case .mostUsed: (glance.value, glance.label) = ("\(engine.today.total(now: .now))", "presses today")
        case .pilot:
            let problems = parts.problems.count
            (glance.value, glance.label) = problems == 0 ? ("✓", "all clear") : ("\(problems)", problems == 1 ? "needs you" : "need you")
            if problems > 0 { glance.tone = ink.red }
        case .thisMac:
            (glance.value, glance.label) = (SystemSampler.shared.latestValues?.cpu.map { StatsFormat.percent($0) + "%" } ?? "–", "CPU")
        case .clipboard: (glance.value, glance.label) = (parts.copy.map { "\($0.count)" } ?? "0", "copies kept")
        case .quickActions: glance.label = "\(QuickAction.all.count) actions"
        }
        return glance
    }
}

/// Opens what a Strip or Square stands for: an extension's page, a block's page.
@MainActor
private func openFull(_ id: String, parts: HomeParts) {
    if let block = HomeLayout.Block(rawValue: id) { parts.go(block.place) } else if let ext = HomeLayout.extensionID(id) { parts.openExtension(ext) }
    else if HomeLayout.widgetID(id) != nil { parts.go(AppPlace(.widgets)) }
}

/// A block as a Strip, one line: its symbol, its title, and its figure with its label; a click opens its page (P91: what
/// today's icon tabs became).
struct HomeStripBlock: View {
    @Environment(\.ink) private var ink
    let id: String
    let parts: HomeParts

    var body: some View {
        GlanceReader(id: id, parts: parts) { glance in
            Button { openFull(id, parts: parts) } label: {
                HStack(spacing: 10) {
                    GlanceIcon(glance: glance, size: 24)
                    Text(glance.title).font(ink.ui(12.5, .medium)).foregroundStyle(ink.text).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 6)
                    if let value = glance.value {
                        Text(value).font(ink.mono(13, weight: .semibold)).monospacedDigit().foregroundStyle(glance.tone ?? ink.text).lineLimit(1)
                    }
                    if let label = glance.label { Text(label).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1) }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .blockSurface()
                .contentShape(.rect)
            }
            .buttonStyle(.kitPress)
            .accessibilityLabel([glance.title, glance.value, glance.label].compactMap(\.self).joined(separator: ", "))
            .help(glance.title)
        }
    }
}

/// A block as a Square: its figure big, its label and its title; a click opens its page.
struct HomeSquareBlock: View {
    @Environment(\.ink) private var ink
    let id: String
    let parts: HomeParts

    var body: some View {
        GlanceReader(id: id, parts: parts) { glance in
            Button { openFull(id, parts: parts) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        GlanceIcon(glance: glance, size: 22)
                        Text(glance.title).font(ink.ui(12, .medium)).foregroundStyle(ink.text2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(glance.value ?? "–").font(ink.display(30)).monospacedDigit().foregroundStyle(glance.tone ?? ink.text)
                        .lineLimit(1).minimumScaleFactor(0.4)
                    if let label = glance.label { Text(label).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(2) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .blockSurface()
                .contentShape(.rect)
            }
            .buttonStyle(.kitPress)
            .accessibilityLabel([glance.title, glance.value, glance.label].compactMap(\.self).joined(separator: ", "))
            .help(glance.title)
        }
    }
}

/// A glance's symbol or emoji on a well.
private struct GlanceIcon: View {
    @Environment(\.ink) private var ink
    let glance: HomeGlance
    let size: CGFloat

    var body: some View {
        Group {
            if let emoji = glance.emoji { Text(emoji).font(.system(size: size * 0.5)) }
            else if let symbol = glance.symbol { Image(systemName: symbol).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(ink.text2) }
        }
        .frame(width: size, height: size)
        .background(ink.well, in: .rect(cornerRadius: ink.radius(size * 0.28), style: .continuous))
        .accessibilityHidden(true)
    }
}

extension View {
    /// Asks an extension's page on its pace while the window shows, unless the place it is drawn in says not to
    /// (homeBlockAsks: a carried block's copy, whose block asks).
    func asksPage(_ model: ExtensionPageModel, onScreen: Bool) -> some View { modifier(AsksPage(model: model, onScreen: onScreen)) }
}

private struct AsksPage: ViewModifier {
    @Environment(\.homeBlockAsks) private var asks
    let model: ExtensionPageModel
    let onScreen: Bool

    func body(content: Content) -> some View {
        content.task(id: onScreen) {
            guard onScreen, asks else { return }
            await model.keepFresh()
        }
    }
}

/// The Hyper keyboard as a Square or Wide card: the board small, each bound key in its kind's colour with its letter, no names or
/// legend; a click on a key opens its bind, its name shows under the mouse.
struct HomeMiniBoard: View {
    @Environment(\.ink) private var ink
    let parts: HomeParts
    private static let keyHeight: CGFloat = 26, gap: CGFloat = 3

    var body: some View {
        let taken = parts.binds.taken, rows = BoardFit.rows(.whole)
        Tile(title: HomeLayout.Block.keyboard.title, symbol: HomeLayout.Block.keyboard.symbol, fill: true,
             note: "\(taken) bound · \(BindsKeyboard.codes.count - taken) free") {
            AccentLink(title: "All binds") { parts.go(AppPlace(.binds)) }
        } content: {
            GeometryReader { board in
                let units = BoardFit.units(.whole, width: board.size.width, gap: Self.gap)
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(rows.indices, id: \.self) { r in
                        HStack(spacing: Self.gap) {
                            ForEach(rows[r].indices, id: \.self) { c in key(rows[r][c].cap, width: units[r] * rows[r][c].width) }
                        }
                    }
                }
            }
            .frame(height: BoardFit(shape: .whole, size: nil).height(key: Self.keyHeight, gap: Self.gap))
        }
    }

    private func key(_ cap: BindsKeyboard.Cap, width: CGFloat) -> some View {
        let action = cap.code.flatMap { parts.binds.bound[$0]?.first }
        let colour = action.map { ink.module(parts.binds.module($0)) }
        let shape = RoundedRectangle(cornerRadius: ink.radius(4), style: .continuous)
        let label = Text(cap.isLayerKey ? "Hyper" : cap.legend.count > 1 ? "" : cap.legend)
            .font(ink.mono(9.5, weight: .medium)).foregroundStyle(colour == nil ? ink.muted : ink.text)
            .frame(width: max(0, width), height: Self.keyHeight)
            .background(cap.isLayerKey ? ink.accent.opacity(0.35) : colour?.opacity(0.32) ?? ink.well, in: shape)
            .overlay(alignment: .bottom) { if let colour { colour.frame(height: 2).padding(.horizontal, 3).padding(.bottom, 2) } }
        return Group {
            if let code = cap.code {
                Button { parts.openKey(code) } label: { label.contentShape(shape) }
                    .buttonStyle(.kitPress)
                    .help(action.map { "Hyper+\(cap.legend): \(parts.binds.names[code] ?? $0)" } ?? "Hyper+\(cap.legend) is free")
            } else {
                label
            }
        }
    }
}
