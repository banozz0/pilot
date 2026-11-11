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
    /// The list's place on screen: a click in it leaves an open pill open (BarPanel.keepOpen).
    @State private var anchor = ScreenAnchor.Box()

    static let note = "What the pill on the top bar shows. Click the pill and pick a view at the top of its drop, or pick it here. The pill is a top bar item: drag Pill from the tray onto the bar."

    var body: some View {
        let layout = store.layout
        KitBlock(title: "Pill", symbol: "capsule", note: Self.note) {
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
