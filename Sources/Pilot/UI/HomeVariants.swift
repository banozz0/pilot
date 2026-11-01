import PilotCore
import SwiftUI

// Home's block sizes (story 167, Sven 2026-10-10 on build 22: "every new addition should become optimised to fit in the home
// screen, have different variants of how all widgets can look, some maybe can even look closed with just a tab with icon
// and just show their info on hover"): what a medium extension card keeps, and the icon tab every style
// draws through the Kit, its one figure; an icon's hover shows the block's small card.

/// What a block's smaller sizes keep of an extension's page.
enum HomeVariant {
    /// A medium card: a page of usage cards keeps just their meters (`usage`); else the page's first stats or meter block
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
    /// Claude and Codex), so Home shows just the usage lines, each under its card's head; the status rows, links and
    /// buttons stay on the page (Sven on 1.0.2: "ai usage should show just usage lines"). A section with a list (Now
    /// playing's track) is no usage card.
    static func usage(_ blocks: [Extension.Block]) -> [Extension.Block] {
        blocks.compactMap { block in
            guard case .section(let title, let subtitle, let aside, let asideNote, let inner, let icon, let help) = block,
                  !inner.contains(where: { if case .list = $0 { true } else { false } }) else { return nil }
            let meters = inner.filter { if case .meter = $0 { true } else { false } }
            return meters.isEmpty ? nil
                : .section(title: title, subtitle: subtitle, aside: aside, asideNote: asideNote, blocks: meters, icon: icon, help: help)
        }
    }

    /// An icon tab's figure: the first stat, else the first meter's value; its label under it.
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

    /// The blocks with each section's own in its place.
    static func flattened(_ blocks: [Extension.Block]) -> [Extension.Block] {
        blocks.flatMap { block -> [Extension.Block] in
            if case .section(_, _, _, _, let inner, _, _) = block { flattened(inner) } else { [block] }
        }
    }
}

extension HomeLayout.Block {
    /// The page a block's icon tab opens.
    var place: AppPlace {
        switch self {
        case .workspaces: AppPlace(.workspaces)
        case .keyboard: AppPlace(.binds)
        case .mostUsed: AppPlace(.activity)
        case .pilot: AppPlace(.general)
        case .thisMac: AppPlace(.stats)
        case .clipboard: AppPlace(.clipboard)
        case .quickActions: AppPlace(.menu)
        }
    }
}

/// A block's large or medium form that every style draws alike: an extension's page, and Workspaces and the keyboard
/// medium (a strip, a small board); nil leaves the block to its style.
struct HomeSharedBlock: View {
    private enum Form { case page(String), widget(HomeWidget), strip, board }
    private let form: Form
    private let parts: HomeParts

    init?(id: String, parts: HomeParts) {
        let medium = parts.size(id) != .large
        switch HomeLayout.Block(rawValue: id) {
        case nil:
            if let ext = HomeLayout.extensionID(id) { form = .page(ext) }
            else if let widget = parts.widget(id) { form = .widget(widget) }
            else { return nil }
        case .workspaces where medium: form = .strip
        case .keyboard where medium: form = .board
        default: return nil
        }
        self.parts = parts
    }

    var body: some View {
        switch form {
        case .page(let ext): HomeExtensionBlock(id: ext, parts: parts)
        case .widget(let widget): HomeWidgetBlock(widget: widget, parts: parts)
        case .strip: HomeWorkspaceStrip(parts: parts)
        case .board: HomeMiniBoard(parts: parts)
        }
    }
}

/// What a block's icon tab shows: its symbol or emoji, its title, one figure with its label, and the short figure its
/// badge carries.
struct HomeGlance {
    var symbol: String?
    var emoji: String?
    let title: String
    var value: String?
    var label: String?
    var tone: Color?
    /// An icon tab's badge: the figure while it is short.
    var badge: String? { value.flatMap { $0.count <= 4 ? $0 : nil } }
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

/// Opens what an icon tab stands for: an extension's page, a block's page.
@MainActor
private func openFull(_ id: String, parts: HomeParts) {
    if let block = HomeLayout.Block(rawValue: id) { parts.go(block.place) } else if let ext = HomeLayout.extensionID(id) { parts.openExtension(ext) }
    else if HomeLayout.widgetID(id) != nil { parts.go(AppPlace(.widgets)) }
}

/// A block closed to a tab in the column: its symbol and its figure as a badge; resting on it shows the block's small
/// card, a click opens its page.
struct HomeIconTab<Medium: View>: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    let id: String
    let parts: HomeParts
    @ViewBuilder let medium: Medium
    @State private var overTab = false
    @State private var overCard = false
    @State private var showing = false

    var body: some View {
        GlanceReader(id: id, parts: parts) { glance in
            Button { showing = false; openFull(id, parts: parts) } label: {
                GlanceIcon(glance: glance, size: 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blockSurface()
                    .frame(width: HomeLayout.Size.tab, height: HomeLayout.Size.tab)
                    .overlay(alignment: .topTrailing) {
                        if let badge = glance.badge {
                            Text(badge).font(ink.mono(10, weight: .semibold)).monospacedDigit().lineLimit(1)
                                .foregroundStyle(ink.onAccent).padding(.horizontal, 5).frame(minWidth: 18, minHeight: 16)
                                .background(glance.tone == ink.red ? ink.red : ink.accent, in: .capsule)
                                .offset(x: 6, y: -6)
                        }
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.kitPress)
            .onHover { overTab = $0 }
            .accessibilityLabel([glance.title, glance.value, glance.label].compactMap(\.self).joined(separator: ", "))
            .help(glance.title)
        }
        // Shows after a moment's rest and closes a beat after the mouse leaves both the tab and the card, as InfoMark's does.
        .task(id: overTab || overCard) {
            let want = overTab || overCard
            guard want != showing, (try? await Task.sleep(for: .milliseconds(want ? 350 : 150))) != nil else { return }
            showing = want
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            medium
                .frame(width: 360)
                .padding(10)
                .background(Theme.windowFill(style.color(\.canvas)))
                .onHover { overCard = $0 }
                .environment(\.homeBlockAsks, false)
                .floating()
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
    /// (homeBlockAsks: an icon tab's hover card, whose tab asks).
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

/// Workspaces as a medium card: a strip of the workspaces, each its name and its apps' icons, the one you are on lit; a
/// click goes there.
struct HomeWorkspaceStrip: View {
    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink
    let parts: HomeParts

    var body: some View {
        let tiler = engine.observers.tiler
        let cells = tiler.homeCells
        Tile(title: "Workspaces", symbol: HomeLayout.Block.workspaces.symbol, fill: true) {
            AccentLink(title: "Open") { parts.go(AppPlace(.workspaces)) }
        } content: {
            if tiler.focused == nil {
                FinePrint(text: "Tiling is stopped; your binds still work.")
            } else {
                // As many as fit the card's width.
                ViewThatFits(in: .horizontal) {
                    ForEach([8, 6, 5, 4, 3, 2], id: \.self) { count in
                        HStack(spacing: 6) { ForEach(Array(cells.prefix(count)), id: \.name) { cell(for: $0, tiler) } }
                    }
                }
            }
        }
    }

    private func cell(for workspace: OccupiedWorkspace, _ tiler: TilerService) -> some View {
        let on = workspace.name == tiler.focused
        return Button { tiler.go(workspace.name, from: "home") } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(workspace.name).font(ink.mono(13, weight: .semibold)).foregroundStyle(on ? ink.accentInk : ink.text)
                Group {
                    if workspace.apps.isEmpty { Text("empty").font(ink.ui(11)).foregroundStyle(ink.muted) }
                    else { CompactApps(names: Array(workspace.apps.prefix(3)), bundles: workspace.bundles, size: 16, spacing: 3) }
                }
                .frame(height: 16)
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .frame(minWidth: 66, maxWidth: .infinity, alignment: .leading)
            .background(on ? ink.selection : ink.well, in: .rect(cornerRadius: ink.radius(8), style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: ink.radius(8), style: .continuous).strokeBorder(on ? ink.accent : .clear, lineWidth: 1.5) }
            .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .help("Go to workspace \(workspace.name)")
        .accessibilityLabel("Workspace \(workspace.name)\(on ? ", here" : ""): \(workspace.apps.joined(separator: ", "))")
    }
}

/// The Hyper keyboard as a medium card: the board small, each bound key in its kind's colour with its letter, no names or
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
