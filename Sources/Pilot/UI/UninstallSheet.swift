import PilotCore
import SwiftUI

/// General › Uninstall… (Sven, 2026-10-23, Q423, the approved mockup): everything Pilot put on disk, grouped,
/// each with its size, and Move to Trash for the ticked ones. Removing Pilot itself quits it.
struct UninstallSheet: View {
    @Environment(\.ink) private var ink
    @Environment(\.dismiss) private var dismiss
    @State var model: UninstallModel

    init(model: UninstallModel = UninstallModel()) { _model = State(initialValue: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Uninstall Pilot").font(ink.ui(16, .semibold))
            Text("Tick what to remove. Everything goes to the Trash.").font(ink.ui(12)).foregroundStyle(ink.muted).padding(.top, 4)
            if model.phase == .measuring {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(ink.muted) }
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ForEach(UninstallItem.Group.allCases, id: \.self) { group in
                    let rows = model.items.filter { $0.group == group }
                    if !rows.isEmpty {
                        PartHeading(text: group.title)
                        ForEach(rows) { item in
                            row(item)
                            if item.id != rows.last?.id { Divider().overlay(ink.line) }
                        }
                    }
                }
            }
            footer.padding(.top, 16)
        }
        .padding(18)
        .frame(width: 480)
        .task { await model.load() }
    }

    private func row(_ item: UninstallItem) -> some View {
        TickRow(title: item.title, detail: item.detail, size: RemoveList.size(item.bytes), ticked: model.ticked.contains(item.id)) {
            model.toggle(item.id)
        }
    }

    @ViewBuilder private var footer: some View {
        if case .failed(let failures) = model.phase {
            VStack(alignment: .leading, spacing: 8) {
                Text("These did not go to the Trash:").foregroundStyle(ink.red)
                ForEach(failures, id: \.self) { Text($0).font(ink.ui(11)).foregroundStyle(ink.muted).lineLimit(2) }
                HStack { Spacer(); Button("Done") { model.end { dismiss() } }.buttonStyle(.pilot).keyboardShortcut(.defaultAction) }
            }
        } else {
            HStack(spacing: 8) {
                Group {
                    if model.phase == .confirming {
                        Text(confirmation).foregroundStyle(ink.text)
                    } else {
                        Text("Frees ") + Text(RemoveList.size(model.total)).foregroundStyle(ink.text).fontWeight(.semibold)
                    }
                }
                .font(ink.ui(12)).foregroundStyle(ink.muted).frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { dismiss() }.buttonStyle(.pilot).keyboardShortcut(.cancelAction)
                Button(model.phase == .confirming ? "Yes, Move to Trash" : "Move to Trash") {
                    Task { await model.moveToTrash { dismiss() } }
                }
                .buttonStyle(PilotButtonStyle(primary: true, destructive: true))
                .disabled(model.chosen.isEmpty || model.phase == .working)
            }
        }
    }

    /// The once-only ask: what goes that does not come back by itself, and what Pilot does after.
    private var confirmation: String {
        let chosen = model.chosen
        if chosen.contains(where: { $0.group == .pilot }) { return "Pilot goes to the Trash and quits. Sure?" }
        let lost = chosen.filter(\.asks).map { $0.title.lowercased() }.joined(separator: ", ")
        return chosen.contains(where: \.relaunches) ? "Removes \(lost); Pilot opens again after. Sure?" : "Removes \(lost). Sure?"
    }
}

/// A ticked list's row (Uninstall Pilot, an app's leftovers): its tick, title, detail and size; a click anywhere ticks it.
struct TickRow: View {
    @Environment(\.ink) private var ink
    let title: String, detail: String?, size: String
    let ticked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { ticked }, set: { _ in toggle() })).toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).font(ink.ui(11)).foregroundStyle(ink.muted) }
            }
            Spacer()
            Text(size).font(ink.ui(12).monospacedDigit()).foregroundStyle(ink.muted)
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
    }
}
