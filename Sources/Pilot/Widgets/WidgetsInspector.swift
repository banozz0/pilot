import PilotCore
import SwiftUI

/// The picked widget under the map (Sven, 2026-11-15, Q252 B): its preview, where it shows and its own settings on the
/// page, each saved as it is set, then Remove. Settings with a picker of their own (the Launcher's
/// tiles, a note, a password, Markets' symbols, a folder) open Edit widget's sheet from their row.
struct WidgetsInspector: View {
    @Environment(\.ink) private var ink
    let model: WidgetsPageModel
    let placement: Widget.Placement
    let widget: Widget
    let previews: WidgetPreviews

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(widget.icon).font(.system(size: 17))
                Text(widget.title).font(ink.ui(15, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                WidgetsTrust(trust: model.trust[widget.id])
                Spacer(minLength: 6)
                Button("Remove") { model.remove(placement) }.buttonStyle(.pilot)
            }
            HStack(alignment: .top, spacing: 14) {
                preview.frame(width: 156)
                WidgetsSettingsRows(model: model, widget: widget, placement: placement)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let tile = previews.models[widget.id] {
            WidgetPreview(widget: widget, model: tile, shot: previews.shots[widget.id], height: 156)
        } else {
            WidgetPreview.ground(Look.shared.theme).frame(height: 156).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// A trust chip where trust says something: locked, made here or trusted; Pilot's own carry none.
struct WidgetsTrust: View {
    @Environment(\.ink) private var ink
    let trust: Widget.Trust?
    var body: some View {
        switch trust {
        case .locked?: Chip(text: "locked", color: ink.yellow, symbol: "lock.fill")
        case .madeHere?: Chip(text: "made here")
        case .trusted?: Chip(text: "trusted")
        default: EmptyView()
        }
    }
}

/// A placement's settings as rows: where it shows (the desktop's), its Layout, then each of its widget's settings.
struct WidgetsSettingsRows: View {
    @Environment(\.ink) private var ink
    let model: WidgetsPageModel
    let widget: Widget
    let placement: Widget.Placement

    var body: some View {
        let values = model.store.values(of: widget, placement: placement)
        VStack(alignment: .leading, spacing: 0) {
            BlockRow(first: true) {
                label("Shows on")
                Menu(placement.workspace.map { "Workspace \($0)" } ?? "All workspaces") {
                    Button("All workspaces") { model.show(placement, on: nil) }
                    Divider()
                    ForEach(model.workspaces(keeping: placement.workspace), id: \.self) { name in
                        Button("Workspace \(name)") { model.show(placement, on: name) }
                    }
                }
                .fixedSize().help("Where it shows: on every empty workspace, or on one only")
            }
            if widget.offersLayout {
                BlockRow {
                    label("Layout")
                    Picker("Layout", selection: Binding(get: { widget.layout(of: placement) }, set: { save(values, layout: $0) })) {
                        Text("Auto").tag(Widget.SizeClass?.none)
                        ForEach(Widget.SizeClass.allCases, id: \.self) { Text($0.title).tag(Widget.SizeClass?.some($0)) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            ForEach(widget.settings, id: \.name) { field in
                BlockRow {
                    label(field.label)
                    editor(field, values: values)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        HStack(spacing: 0) {
            Text(text).font(ink.ui(12.5)).foregroundStyle(ink.text).lineLimit(2)
            Spacer(minLength: 8)
        }
    }

    @ViewBuilder private func editor(_ field: Widget.Field, values: [String: JSONValue]) -> some View {
        let shown = values[field.name].flatMap(WidgetEditSheet.text) ?? ""
        switch field.kind {
        case .text where widget.id == ReadyWidgets.folder || widget.data == .markets(field.name):
            sheetButton(shown)
        case .text, .colour:
            WidgetsCommitField(initial: shown, prompt: field.kind == .colour ? "#RRGGBB" : "") { save(values, field.name, .string($0)) }
                .frame(maxWidth: 190).id("\(placement.id)-\(field.name)-\(shown)")
        case .number:
            WidgetsCommitField(initial: shown) { save(values, field.name, Double($0).map(JSONValue.number) ?? .string($0)) }
                .frame(maxWidth: 90).id("\(placement.id)-\(field.name)-\(shown)")
        case .checkbox:
            Toggle(field.label, isOn: Binding(get: { values[field.name] == .bool(true) }, set: { save(values, field.name, .bool($0)) }))
                .toggleStyle(.pilotSwitch).labelsHidden()
        case .choice:
            Picker(field.label, selection: Binding(get: { shown }, set: { save(values, field.name, .string($0)) })) {
                ForEach(field.choices, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .labelsHidden().fixedSize()
        case .password, .note, .actions, .menu:
            sheetButton(field.kind == .password ? "In the Keychain" : nil)
        }
    }

    /// A setting with a picker of its own: Edit widget's sheet, from its row.
    private func sheetButton(_ value: String?) -> some View {
        HStack(spacing: 8) {
            if let value, !value.isEmpty { Text(value).font(ink.ui(12)).foregroundStyle(ink.text2).lineLimit(1).truncationMode(.middle) }
            Button("Choose…") { model.editing = placement.id }.buttonStyle(.pilot)
        }
    }

    /// One setting changed: the placement's values with it, its Layout kept.
    private func save(_ values: [String: JSONValue], _ name: String, _ value: JSONValue) {
        var changed = values
        changed[name] = value
        save(changed, layout: widget.layout(of: placement))
    }

    private func save(_ values: [String: JSONValue], layout: Widget.SizeClass?) {
        var kept = values
        if widget.offersLayout { kept[Widget.layoutName] = layout.map { .string($0.rawValue) } }
        model.edit(placement, values: kept, passwords: [:], workspace: placement.workspace)
    }
}

/// A text setting saved when you press Return or leave the field, not on each key.
struct WidgetsCommitField: View {
    let initial: String
    var prompt = ""
    let commit: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(initial: String, prompt: String = "", commit: @escaping (String) -> Void) {
        self.initial = initial; self.prompt = prompt; self.commit = commit
        _text = State(initialValue: initial)
    }

    var body: some View {
        TextField(prompt, text: $text)
            .pilotField()
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, now in if !now { save() } }
    }

    private func save() { if text != initial { commit(text) } }
}
