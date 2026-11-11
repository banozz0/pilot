import PilotCore
import SwiftUI

/// Menu bar › Pilot menu (spec desktop-controls T4), Launcher › Your menu's pattern (MenuRootBlock): the tall menu's
/// blocks in order, each with up and down arrows, a drag onto another row to move it there, a pin that keeps it above the
/// scroll, and a switch that shows it; Reset brings the first arrangement back. Status always shows, so it has no switch.
/// The optional blocks (sound, Wi-Fi and Bluetooth, brightness, now playing, the stats) start hidden. Instrument only:
/// Toybox keeps today's menu.
struct DropdownEditor: View {
    @Environment(\.ink) private var ink
    var store: DropdownLayoutStore = .shared
    var extensionBar: ExtensionBar = .shared
    /// The list's place on screen: a click in it leaves an open Pilot menu open, so each change shows there live.
    @State private var anchor = ScreenAnchor.Box()

    static let note = "What Pilot's menu shows under its item, in your order. Pinned blocks stay above the scroll on a short screen. Instrument only."

    var body: some View {
        let order = store.layout.order
        KitBlock(title: "Pilot menu", symbol: "menubar.rectangle", note: Self.note) {
            if store.layout != .standard {
                Button("Reset to default") { withAnimation(Kit.change) { store.reset() } }.buttonStyle(.pilot)
            }
        } content: {
            ForEach(Array(order.enumerated()), id: \.element) { i, block in
                BlockRow(first: i == 0) { row(block, at: i, of: order.count) }
                    .draggable(block.rawValue) { Text(block.title).padding(4) }
                    .dropDestination(for: String.self) { dropped, _ in
                        guard let moved = dropped.first.flatMap(Dropdown.Block.init(rawValue:)) else { return false }
                        withAnimation(Kit.change) { store.move(moved, to: i) }
                        return true
                    }
            }
            BlockRow(first: false) {
                ExtensionPicks(title: "In the Extensions card", held: store.layout.extensions, bar: extensionBar) { id, on in
                    store.hold(extension: id, on)
                }
            }
        }
        .background { ScreenAnchor(box: anchor) }
        .onAppear { BarPanel.keepOpen(anchor, .panel) }
        .onDisappear { BarPanel.release(anchor) }
    }

    private func row(_ block: Dropdown.Block, at i: Int, of count: Int) -> some View {
        let shown = !store.layout.hidden.contains(block), pinned = store.layout.pinned.contains(block)
        return HStack(spacing: 10) {
            GripDots().foregroundStyle(ink.muted).frame(width: 14).help("Drag to move")
            Image(systemName: block.symbol).font(ink.ui(12.5)).frame(width: 18)
            Text(block.title).foregroundStyle(shown ? ink.text : ink.muted)
            Spacer()
            IconButton(symbol: pinned ? "pin.fill" : "pin", label: pinned ? "Unpin \(block.title)" : "Pin \(block.title)", size: 22, glyph: 11) {
                withAnimation(Kit.change) { store.pin(block, !pinned) }
            }
            IconButton(symbol: "chevron.up", label: "Move \(block.title) up", size: 22, glyph: 11) { withAnimation(Kit.change) { store.move(block, to: i - 1) } }
                .disabled(i == 0).kitDimmed(i > 0)
            IconButton(symbol: "chevron.down", label: "Move \(block.title) down", size: 22, glyph: 11) { withAnimation(Kit.change) { store.move(block, to: i + 1) } }
                .disabled(i == count - 1).kitDimmed(i < count - 1)
            if block == .status {
                // Status carries every problem, so it always shows: the switch's place is kept empty.
                Color.clear.frame(width: 38, height: 1).help("Status always shows: a problem must lead the menu")
            } else {
                Toggle("Show \(block.title)", isOn: Binding(get: { shown }, set: { on in withAnimation(Kit.change) { store.show(block, on) } }))
                    .labelsHidden().toggleStyle(.pilotSwitch)
            }
        }
    }
}

/// The extensions with a bar item, each a switch that puts it in a surface's own list (the Pilot menu's Extensions card,
/// the pill's Extensions view), in the order switched on.
struct ExtensionPicks: View {
    @Environment(\.ink) private var ink
    let title: String
    let held: [String]
    var bar: ExtensionBar = .shared
    let set: (String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(ink.ui(12.5, .medium)).foregroundStyle(ink.text2)
            if bar.items.isEmpty {
                Text("No extension has a bar item yet.").font(ink.ui(12.5)).foregroundStyle(ink.muted)
            }
            ForEach(bar.items) { item in
                Toggle(isOn: Binding(get: { held.contains(item.id) }, set: { on in withAnimation(Kit.change) { set(item.id, on) } })) {
                    Text("\(item.icon ?? "🧩")  \(item.title)")
                }
                .toggleStyle(.pilotSwitchRow)
            }
        }
    }
}
