import PilotCore
import SwiftUI

/// Update & Clean's list of what Clean would remove (W89): Mole's file list part by part, each part with its total and a
/// tick for all or none of it, its rows (path, size, tick) shown once it is opened, and one button that moves only the
/// ticked rows to the Trash. Every row starts ticked, as Mole's clean took them all. A row that does not move says why,
/// and the rest go on.
struct CleanListBlock: View {
    @Environment(\.ink) private var ink
    let list: CleanList
    var home = CleanModule.home
    /// Moves the ticked rows; nil when the kept list ran out.
    let clean: (Set<String>) async -> CleanOutcome?
    /// Rows the user unticked.
    @State var unticked: Set<String> = []
    /// Parts opened to show their rows.
    @State var opened: Set<String> = []
    @State var phase = Phase.ready

    enum Phase: Equatable { case ready, confirming, working, done(CleanOutcome?) }

    private var ticked: [CleanList.Row] { list.rows.filter { !unticked.contains($0.id) } }

    var body: some View {
        KitBlock(title: "What Clean would remove", symbol: "sparkles",
                 note: "Mole's list, part by part. Only the ticked rows go to the Trash; the rest stay.") {
            Text(RemoveList.size(CleanList.bytes(ticked))).font(ink.ui(12, .semibold).monospacedDigit()).foregroundStyle(ink.text)
        } content: {
            VStack(spacing: 0) {
                if list.rows.isEmpty {
                    BlockRow(first: true) { Text("Mole listed nothing to remove.").font(ink.ui(12)).foregroundStyle(ink.muted) }
                }
                ForEach(Array(list.parts.enumerated()), id: \.element.id) { i, part in
                    BlockRow(first: i == 0) { heading(part) }
                    if opened.contains(part.id) {
                        ForEach(part.rows) { row in
                            TickRow(title: AppConfigs.tilde(row.path, home: home), detail: row.count > 1 ? "\(row.count) items" : nil,
                                    size: row.size, ticked: !unticked.contains(row.id)) { flip([row.id]) }
                                .padding(.leading, 26)
                        }
                    }
                }
                BlockRow { foot }
            }
        }
    }

    /// A part's tick (all, none, or some), its opener, name, count and total.
    private func heading(_ part: CleanList.Part) -> some View {
        let ids = part.rows.map(\.id), off = ids.filter(unticked.contains).count
        let symbol = off == 0 ? "checkmark.square.fill" : off == ids.count ? "square" : "minus.square.fill"
        let open = opened.contains(part.id)
        return HStack(spacing: 10) {
            Button { flip(ids, all: off > 0) } label: {
                Image(systemName: symbol).font(ink.ui(14)).foregroundStyle(off == ids.count ? ink.muted : ink.text)
            }
            .buttonStyle(.plain).accessibilityLabel("Tick all of \(part.name)")
            Button { if open { opened.remove(part.id) } else { opened.insert(part.id) } } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(ink.ui(10, .semibold)).foregroundStyle(ink.muted).frame(width: 10)
                    Text(part.name).font(ink.ui(13, .semibold)).foregroundStyle(ink.text)
                    Text("\(ids.count - off) of \(ids.count) ticked").font(ink.ui(11.5)).foregroundStyle(ink.muted)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Text(RemoveList.size(part.bytes)).font(ink.ui(12).monospacedDigit()).foregroundStyle(ink.muted)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var foot: some View {
        if case .done(let outcome) = phase {
            VStack(alignment: .leading, spacing: 6) {
                Text(outcome?.summary ?? "The list ran out; scan again.").font(ink.ui(12.5, .semibold)).foregroundStyle(ink.text)
                ForEach(outcome?.failed ?? [], id: \.row.id) { failure in
                    Text("\(AppConfigs.tilde(failure.row.path, home: home)): \(failure.why)").font(ink.ui(11.5)).foregroundStyle(ink.red).lineLimit(2)
                }
                HStack {
                    Text("The Trash keeps them until it is emptied.").font(ink.ui(11.5)).foregroundStyle(ink.muted)
                    Spacer()
                    Button("Done") { phase = .ready }.buttonStyle(.pilot)
                }
            }
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 8) {
                let n = ticked.count
                Text(phase == .confirming ? "Moves \(n) ticked to the Trash. Sure?" : "\(n) of \(list.rows.count) ticked")
                    .font(ink.ui(12)).foregroundStyle(phase == .confirming ? ink.text : ink.muted)
                Spacer()
                if phase == .confirming { Button("Cancel") { phase = .ready }.buttonStyle(.pilot) }
                Button(phase == .confirming ? "Yes, Move to Trash" : "Move ticked to Trash") {
                    guard phase == .confirming else { return phase = .confirming }
                    phase = .working
                    let ids = Set(ticked.map(\.id))
                    Task { phase = .done(await clean(ids)) }
                }
                .buttonStyle(PilotButtonStyle(primary: true, destructive: true))
                .disabled(ticked.isEmpty || phase == .working)
            }
            .padding(.vertical, 8)
        }
    }

    /// Ticks `ids` when `all`, else flips each one.
    private func flip(_ ids: [String], all: Bool? = nil) {
        guard phase != .working else { return }
        if phase == .confirming { phase = .ready }
        for id in ids {
            let on = all ?? unticked.contains(id)
            if on { unticked.remove(id) } else { unticked.insert(id) }
        }
    }
}
