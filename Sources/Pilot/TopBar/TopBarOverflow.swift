import PilotCore
import SwiftUI

/// The top bar's overflow item (Sven on build 52: no limit on how many items the bar holds): a chevron just inside the right
/// side while TopBarRow puts any slot off the row for room, the way a crowded menu bar's hidden items fold behind one
/// control rather than shrinking past reading. A click hangs the gone slots under it, each drawn and working as on the bar.
/// Its size never changes, so what it lists never moves the row.
struct TopBarOverflow: View {
    @Environment(\.style) private var style
    let screen: String
    let sides: [TopBarSide: [BarSlot]]
    let sources: BarSources
    let store: BarItemsStore
    let frames: BarFrames
    @State private var anchor = ScreenAnchor.Box()

    var body: some View {
        let gone = frames.gone(on: screen, in: sides)
        Button { show(gone) } label: {
            Image(systemName: "chevron.right.2").font(.system(size: 11, weight: .semibold)).foregroundStyle(BarInk(style: style).text2)
                .barTarget(gone.count == 1 ? "1 more item" : "\(gone.count) more items")
                .background(ScreenAnchor(box: anchor))
        }
        .buttonStyle(.kitPress)
        .accessibilityLabel("More items")
        .frame(maxHeight: .infinity)
        .toyIsland(.group)
    }

    private func show(_ gone: [BarSlot]) {
        guard !gone.isEmpty else { return }
        BarPanel.shared.toggle(Self.id, under: anchor.view, AnyView(TopBarOverflowList(slots: gone, screen: screen, sources: sources, store: store)))
    }

    /// The overflow's panel id with BarPanel: no item's kinds, so it toggles apart from every item's.
    static let id: [BarKind] = []
}

/// The gone slots in the overflow's popover, one row each: its name, then the slot as the bar draws it, which takes its
/// click, right-click and scroll there as on the bar.
private struct TopBarOverflowList: View {
    @Environment(\.style) private var style
    let slots: [BarSlot]
    let screen: String
    let sources: BarSources
    let store: BarItemsStore

    /// The row's name: an extension's own slot is named by its extension (spec pilot-1.1 T50).
    private func title(_ slot: BarSlot) -> String {
        guard case .extension(let id) = slot.item else { return slot.kind.title }
        return sources.extensionBar.items.first { $0.id == id }?.title ?? slot.kind.title
    }

    var body: some View {
        let ink = BarInk(style: style)
        KitPopover(width: 300) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                    HStack(spacing: 12) {
                        Text(title(slot)).font(ink.detail).foregroundStyle(ink.muted).lineLimit(1)
                        Spacer(minLength: 8)
                        TopBarSlot(slot: slot, screen: screen, sources: sources, store: store)
                            .environment(\.inTopBar, true)
                            .font(style.kind == .toybox ? ToyBar.font : style.font(\.caption))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(height: 28)
                }
            }
        }
    }
}
