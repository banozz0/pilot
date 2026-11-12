import PilotCore
import SwiftUI

/// Menu bar › Pill (spec desktop-controls T7), the Pilot menu's edit list's pattern: the pill's views in order, each
/// with up and down arrows, a switch that offers it as a tab and a dot that makes it the one the pill shows; then the
/// extensions whose bar items the Extensions view holds. The drop's tabs switch views too. A click here leaves an open
/// pill as it is: its drop follows each change.
struct PillEditor: View {
    @Environment(\.ink) private var ink
    var store: PillLayoutStore = .shared
    var extensionBar: ExtensionBar = .shared
    var bar: BarItemsStore = .shared
    /// The list's place on screen: a click in it leaves an open pill open (BarPanel.keepOpen).
    @State private var anchor = ScreenAnchor.Box()

    static let note = "What the pill on the top bar shows. Click the pill and pick a view at the top of its drop, or pick it here. The pill is a top bar item: drag Pill from the tray onto the bar."

    var body: some View {
        if bar.pillFirst.on { PillFirstPages(bar: bar, extensionBar: extensionBar) } else { views }
    }

    private var views: some View {
        let layout = store.layout
        return KitBlock(title: "Pill", symbol: "capsule", note: Self.note) {
            if layout != .standard {
                Button("Reset to default") { withAnimation(Kit.change) { store.reset() } }.buttonStyle(.pilot)
            }
        } content: {
            ForEach(Array(layout.order.enumerated()), id: \.element) { i, view in
                BlockRow(first: i == 0) { row(view, at: i, of: layout.order.count) }
            }
            BlockRow(first: false) { extensions(layout.extensions) }
        }
        .background { ScreenAnchor(box: anchor) }
        .onAppear { BarPanel.keepOpen(anchor, .drops) }
        .onDisappear { BarPanel.release(anchor) }
    }

    private func row(_ view: Pill.View, at i: Int, of count: Int) -> some View {
        let page = PillValues.Page(view), layout = store.layout
        let shown = !layout.hidden.contains(view), current = layout.current == view
        return HStack(spacing: 10) {
            Button { withAnimation(Kit.change) { try? store.select(view) } } label: {
                Image(systemName: current ? "largecircle.fill.circle" : "circle").font(ink.ui(13)).foregroundStyle(current ? ink.text : ink.muted)
            }
            .buttonStyle(.plain).disabled(!shown)
            .help(current ? "The pill shows \(page.title)" : "Show \(page.title) in the pill").accessibilityLabel("Show \(page.title) in the pill")
            Image(systemName: page.symbol).font(ink.ui(12.5)).frame(width: 18)
            Text(page.title).foregroundStyle(shown ? ink.text : ink.muted)
            Spacer()
            IconButton(symbol: "chevron.up", label: "Move \(page.title) up", size: 22, glyph: 11) { withAnimation(Kit.change) { store.move(view, to: i - 1) } }
                .disabled(i == 0).kitDimmed(i > 0)
            IconButton(symbol: "chevron.down", label: "Move \(page.title) down", size: 22, glyph: 11) { withAnimation(Kit.change) { store.move(view, to: i + 1) } }
                .disabled(i == count - 1).kitDimmed(i < count - 1)
            Toggle("Offer \(page.title)", isOn: Binding(get: { shown }, set: { on in withAnimation(Kit.change) { store.show(view, on) } }))
                .labelsHidden().toggleStyle(.pilotSwitch)
                .disabled(shown && layout.shown.count == 1).help(shown && layout.shown.count == 1 ? "One view always shows" : "")
        }
    }

    private func extensions(_ held: [String]) -> some View {
        ExtensionPicks(title: "In the Extensions view", held: held, bar: extensionBar) { id, on in store.hold(extension: id, on) }
    }
}

/// Menu bar › Pill on the pill-first bar (PillFirst, Q162, Q163): its pages in order, each with up and down arrows and a
/// minus; an extensions page lists the extensions it holds, up to three; Add page offers the kinds not shown yet and
/// another extensions page. Today's pill's views stay saved as they were, for the switch back.
struct PillFirstPages: View {
    @Environment(\.ink) private var ink
    let bar: BarItemsStore
    var extensionBar: ExtensionBar = .shared
    @State private var anchor = ScreenAnchor.Box()

    static let note = "The pill-first bar's pages. Click the pill, press its key or click the clock (Calendar); arrows and 1 to 9 switch pages. An extensions page holds up to three extensions."

    var body: some View {
        let pages = bar.pillFirst.pages
        KitBlock(title: "Pill pages", symbol: "capsule", note: Self.note) {
            HStack(spacing: 8) {
                Menu("Add page") {
                    ForEach(PillFirst.Kind.allCases.filter { kind in kind != .extensions && !pages.contains { $0.kind == kind } }, id: \.self) { kind in
                        Button(kind.title) { change { $0.pages.append(.init(kind)) } }
                    }
                    Button("Extensions page") { change { $0.pages.append(.init(.extensions, title: Self.fresh(pages))) } }
                }
                .fixedSize()
                if pages != PillFirst.Page.standard {
                    Button("Reset to default") { change { $0.pages = PillFirst.Page.standard; $0.selected = 0 } }.buttonStyle(.pilot)
                }
            }
        } content: {
            ForEach(Array(pages.enumerated()), id: \.offset) { i, page in
                BlockRow(first: i == 0) { row(page, at: i, of: pages.count) }
                if page.kind == .extensions {
                    BlockRow(first: false) {
                        ExtensionPicks(title: "On \(page.title), up to \(PillFirst.Page.most)", held: page.extensions, bar: extensionBar) { id, on in hold(id, on, page: i) }
                    }
                }
            }
        }
        .background { ScreenAnchor(box: anchor) }
        .onAppear { BarPanel.keepOpen(anchor, .drops) }
        .onDisappear { BarPanel.release(anchor) }
    }

    private func row(_ page: PillFirst.Page, at i: Int, of count: Int) -> some View {
        let symbol = PillValues.Page(page.kind).symbol, current = bar.pillFirst.current == i
        return HStack(spacing: 10) {
            Button { change { $0.selected = i } } label: {
                Image(systemName: current ? "largecircle.fill.circle" : "circle").font(ink.ui(13)).foregroundStyle(current ? ink.text : ink.muted)
            }
            .buttonStyle(.plain).help(current ? "The pill shows \(page.title)" : "Show \(page.title) in the pill").accessibilityLabel("Show \(page.title) in the pill")
            Image(systemName: symbol).font(ink.ui(12.5)).frame(width: 18)
            Text(page.title).foregroundStyle(ink.text)
            Spacer()
            IconButton(symbol: "chevron.up", label: "Move \(page.title) up", size: 22, glyph: 11) { move(i, by: -1) }
                .disabled(i == 0).kitDimmed(i > 0)
            IconButton(symbol: "chevron.down", label: "Move \(page.title) down", size: 22, glyph: 11) { move(i, by: 1) }
                .disabled(i == count - 1).kitDimmed(i < count - 1)
            IconButton(symbol: "minus", label: "Take \(page.title) off", size: 22, glyph: 11) { change { $0.pages.remove(at: i); $0.selected = min($0.selected, $0.pages.count - 1) } }
                .disabled(count == 1).kitDimmed(count > 1).help(count == 1 ? "The pill keeps one page" : "")
        }
    }

    /// One change to the saved pages, animated; the store refuses it while the saved bar is malformed.
    private func change(_ edit: (inout PillFirst.Settings) -> Void) {
        var settings = bar.pillFirst
        edit(&settings)
        withAnimation(Kit.change) { bar.pillFirst = settings }
    }

    private func move(_ i: Int, by step: Int) {
        change { settings in
            let to = i + step
            guard settings.pages.indices.contains(to) else { return }
            let showing = settings.current
            settings.pages.swapAt(i, to)
            settings.selected = showing == i ? to : showing == to ? i : showing
        }
    }

    /// An extension on or off an extensions page; a fourth is refused with a tip.
    private func hold(_ id: String, _ on: Bool, page i: Int) {
        guard bar.pillFirst.pages.indices.contains(i) else { return }
        let held = bar.pillFirst.pages[i].extensions
        if on, held.count >= PillFirst.Page.most { return HUD.tip("A page holds up to \(PillFirst.Page.most) extensions: take one off first, or add another extensions page", seconds: 3) }
        change { $0.pages[i].extensions = on ? held + [id] : held.filter { $0 != id } }
    }

    /// A name for another extensions page: Extensions, then Extensions 2, 3 and on.
    static func fresh(_ pages: [PillFirst.Page]) -> String {
        let taken = Set(pages.filter { $0.kind == .extensions }.map(\.title))
        return (["Extensions"] + (2...99).map { "Extensions \($0)" }).first { !taken.contains($0) } ?? "More"
    }
}
