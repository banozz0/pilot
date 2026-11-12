import PilotCore
import SwiftUI
import UniformTypeIdentifiers

/// The bar tray (Sven, Q185, 2026-10-16), under the Menu bar page's strip: every item not on the bar the page shows, by
/// the page's groups (BarSettings.tray), extensions' own items among Extensions. A chip dragged onto the strip lands where
/// it drops; clicked (its +, or Space on it) it goes last on its side. An item dragged off the strip onto the tray leaves that
/// bar. The tray lights while a drag from the strip is over it.
struct BarTray: View {
    @Environment(\.ink) private var ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: BarItemsStore
    let placement: BarPlacement
    let extensions: [ExtensionBar.Item]
    @Binding var dragged: BarTrayItem?
    /// A drag from the strip is over the tray.
    @State private var over = false

    var body: some View {
        let sections = store.settings.tray(placement, extensions: extensions.map(\.id))
        let shape = RoundedRectangle(cornerRadius: ink.corner(10, \.control), style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Not on the bar").font(ink.ui(13, .semibold)).foregroundStyle(ink.text)
                Text(over ? "Drop to take it off the bar" : "Drag onto the bar above, or + to add at the end")
                    .font(ink.ui(12.5)).foregroundStyle(over ? ink.accentText : ink.muted).lineLimit(1)
                Spacer(minLength: 0)
            }
            if sections.isEmpty {
                Text("Everything is on the bar. Drag an item here to take it off.")
                    .font(ink.ui(12.5)).foregroundStyle(ink.muted).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            }
            ForEach(sections, id: \.group) { section in
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) { title(section.group).frame(width: 140, alignment: .leading); chips(section.items) }
                    VStack(alignment: .leading, spacing: 8) { title(section.group); chips(section.items) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { shape.fill(over ? ink.accent.opacity(0.1) : .clear) }
        .overlay { shape.strokeBorder(over ? ink.accent.opacity(0.7) : ink.line, style: StrokeStyle(lineWidth: 1, dash: over ? [4, 3] : [])) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: over)
        // The whole tray takes the drop, its clear ground too: without a shape only the chips and words did, so a drop
        // in the tray's empty room took nothing off (Sven on build 54).
        .contentShape(shape)
        .onDrop(of: [.plainText], delegate: Self.removal(store: store, placement: placement, dragged: dragged, animation: reduceMotion ? nil : Kit.change,
                                                         over: { over = $0 != nil && dragged.map(onStrip) == true }, finish: { dragged = nil }))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Not on the bar")
    }

    /// The tray's drop: an item on the strip leaves it (BarSettings.takeOff); anything else is refused.
    static func removal(store: BarItemsStore, placement: BarPlacement, dragged: BarTrayItem?, animation: Animation?,
                        over: @escaping (CGPoint?) -> Void, finish: @escaping () -> Void) -> TrayItemDrop<Bool> {
        TrayItemDrop(dragged: dragged, animation: animation, over: over, finish: finish) { [store, placement] item, _ in
            store.settings.onStrip(item, placement: placement) ? true : nil
        } apply: { [store, placement] item, _ in store.settings.takeOff(item, placement: placement) }
    }

    private func title(_ group: BarGroup) -> some View {
        Text(group.title).font(ink.ui(12.5, .medium)).foregroundStyle(ink.text2).lineLimit(1)
    }

    private func chips(_ items: [BarTrayItem]) -> some View {
        Flow(spacing: 8, lineSpacing: 8) {
            ForEach(items, id: \.self) { item in
                TrayChip(item: item, label: label(item), dragged: $dragged) {
                    withAnimation(reduceMotion ? nil : Kit.change) { _ = store.settings.drop(item, on: end(item), placement: placement) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func onStrip(_ item: BarTrayItem) -> Bool { store.settings.onStrip(item, placement: placement) }

    /// A click's place: last on the item's own side of the top bar, or last in the menu bar.
    private func end(_ item: BarTrayItem) -> BarStripDrop {
        guard placement != .menuBar else { return .menu(index: .max) }
        // One more divider goes on the first one's side.
        return .top(item.drawnKind.map { store.settings.entry($0).side } ?? .right, index: .max)
    }

    private func label(_ item: BarTrayItem) -> TrayChip.Label {
        let label = { (kind: BarKind) in TrayChip.Label(symbol: kind.symbol, emoji: nil, title: kind.title, colour: BarGroup.allCases.firstIndex(of: kind.group) ?? 0) }
        switch item {
        case .kind(let kind): return label(kind)
        case .divider: return label(.divider)
        case .extension(let id):
            let found = extensions.first { $0.id == id }
            return TrayChip.Label(symbol: nil, emoji: found?.icon ?? "🧩", title: found?.title ?? id, colour: BarGroup.allCases.firstIndex(of: .extensions) ?? 0)
        }
    }
}

/// One tray item: a + to add it, its symbol in its group's colour and its name, on a quiet pill that lifts under the
/// pointer (Sven on build 55: a + or − beside each item, not drag alone). The whole chip adds; the + says so.
struct TrayChip: View {
    struct Label {
        let symbol: String?, emoji: String?, title: String
        /// Its group's module colour, by the group's place in BarGroup.
        let colour: Int
    }

    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    @Environment(Engine.self) private var engine
    let item: BarTrayItem
    let label: Label
    @Binding var dragged: BarTrayItem?
    let add: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.corner(ink.radius(7), \.chip), style: .continuous)
        HStack(spacing: 8) {
            StripBadge(symbol: "plus", lit: hovered)
            if label.symbol == PilotMarkShape.symbol {
                InstrumentMark(size: 13).foregroundStyle(ink.module(label.colour)).frame(width: 16)
            } else if let symbol = label.symbol {
                Image(systemName: symbol).font(ink.ui(12.5, .medium)).foregroundStyle(ink.module(label.colour)).frame(width: 16)
            } else if let emoji = label.emoji {
                Text(emoji).font(ink.ui(13.5))
            }
            Text(label.title).font(ink.ui(13)).foregroundStyle(ink.text).lineLimit(1)
        }
        .fixedSize()
        .padding(.leading, 7).padding(.trailing, 12).frame(height: 32)
        .background(hovered ? ink.selected : ink.selected.opacity(0.55), in: shape)
        .overlay { shape.strokeBorder(hovered ? ink.line2 : ink.line) }
        .contentShape(shape)
        .onHover { hovered = $0 }
        .onTapGesture(perform: add)
        .onDrag {
            dragged = item
            return NSItemProvider(object: item.rawValue as NSString)
        } preview: {
            BarDragChip(kind: item.drawnKind ?? .extensions, slot: nil, screen: "", sources: engine.barSources, store: .shared,
                        extensionItem: label.emoji.map { ($0, label.title) })
                .environment(\.style, style)
        }
        .help("Drag onto the bar, or click to add it at the end")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.title)
        .accessibilityHint("Not on the bar. Activate to add it at the end.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { add() }
        .focusable()
        .onKeyPress(keys: [.space, .return]) { _ in add(); return .handled }
    }
}

/// A drop of a bar item on the page's strip or the tray. The item comes from the drag's own payload, checked against
/// the one the page saw start (`dragged`), so text dragged in from another app never lands; `target` says where the item
/// would land at a point (nil: not here), `apply` makes the change once the payload is read.
struct TrayItemDrop<Target: Sendable>: DropDelegate {
    let dragged: BarTrayItem?
    /// The change's animation, nil with Reduce motion.
    let animation: Animation?
    let over: (CGPoint?) -> Void
    /// The drag is over: the page forgets `dragged`, so a later drag from another app draws no marks.
    let finish: () -> Void
    let target: (BarTrayItem, CGPoint) -> Target?
    let apply: @MainActor @Sendable (BarTrayItem, Target) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragged != nil && info.hasItemsConforming(to: [.plainText]) }
    func dropEntered(info: DropInfo) { over(info.location) }
    func dropExited(info: DropInfo) { over(nil) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        over(info.location)
        guard let dragged, target(dragged, info.location) != nil else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        over(nil)
        defer { finish() }
        guard let dragged, let landing = target(dragged, info.location),
              let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let expected = dragged.rawValue, apply = apply, animation = animation
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String, raw == expected else { return }
            Task { @MainActor in withAnimation(animation) { apply(dragged, landing) } }
        }
        return true
    }
}

/// One piece of the Menu bar page's strip: an item as the bar draws it, untouchable under a clear layer that takes the
/// drag. A − at its corner takes it off (Sven on builds 54 and 55: never by drag alone, and shown, not only under the
/// pointer); its right-click menu moves it or takes it off; VoiceOver has the same as actions. Pilot's own piece stays put.
struct StripPiece<Content: View, Preview: View>: View {
    @Environment(\.style) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: BarTrayItem
    let title: String
    let pinned: Bool
    @Binding var dragged: BarTrayItem?
    let remove: () -> Void
    /// One place along the bar; nil where the piece has no place of its own (an extension's item).
    let step: ((Int) -> Void)?
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let content: () -> Content
    @State private var hovered = false
    /// The item draws nothing now (no mode on, no reading yet): no − floating over an empty spot.
    @State private var blank = false
    /// Drawn as under the pointer from the start: the renders' only way to show the lit −.
    var hoveredAtStart = false
    /// The page's style for the −, which sits on the page's desk above the bar, where the bar's own ink (dark on a light
    /// bar's colour) would not read; nil keeps the bar's.
    var pageStyle: StyleTokens?

    /// The piece drawn on a page in `style`, its − in that.
    func onPage(_ style: StyleTokens) -> Self {
        var piece = self
        piece.pageStyle = style
        return piece
    }

    var body: some View {
        content()
            .allowsHitTesting(false)
            .onAppear { if hoveredAtStart { hovered = true } }
            .overlay {
                if pinned {
                    Color.clear.contentShape(Rectangle()).help("\(title) is always on the bar")
                } else {
                    Color.clear.contentShape(Rectangle())
                        .help("Drag to move, or back to the tray to take it off")
                        .onDrag {
                            dragged = item
                            return NSItemProvider(object: item.rawValue as NSString)
                        } preview: { preview() }
                        .contextMenu {
                            if let step {
                                Button("Move left") { step(-1) }
                                Button("Move right") { step(1) }
                                Divider()
                            }
                            Button("Take off the bar", action: remove)
                        }
                }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width < 1 } action: { blank = $0 }
            .overlay(alignment: .topTrailing) {
                if !pinned, !blank {
                    Button(action: remove) { StripBadge(symbol: "minus", lit: hovered).environment(\.style, pageStyle ?? style) }
                        .buttonStyle(.kitPress)
                        .help("Take \(title) off the bar")
                        .accessibilityLabel("Take \(title) off the bar")
                        // Above the piece's corner, clear of its words and its neighbour's.
                        .offset(x: 12, y: -14)
                }
            }
            .onHover { on in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { hovered = on } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityHint(pinned ? "" : "On the bar. Actions move it or take it off.")
            .accessibilityActions {
                if !pinned {
                    if let step {
                        Button("Move left") { step(-1) }
                        Button("Move right") { step(1) }
                    }
                    Button("Take off the bar", action: remove)
                }
            }
    }
}

/// The + on a tray chip and the − on a strip piece: a small round button face, quiet until its item is under the pointer,
/// with a target bigger than its disc.
struct StripBadge: View {
    @Environment(\.ink) private var ink
    let symbol: String
    let lit: Bool

    var body: some View {
        Image(systemName: symbol).font(.system(size: 8, weight: .heavy))
            .foregroundStyle(lit ? ink.background : ink.text)
            .frame(width: 16, height: 16)
            .background(lit ? ink.text : ink.selected, in: Circle())
            .overlay { Circle().strokeBorder(lit ? .clear : ink.line2) }
            .frame(width: 20, height: 20)
            .contentShape(Circle())
            .accessibilityHidden(true)
    }
}
