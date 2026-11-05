import PilotCore
import SwiftUI

/// What Edit widget offers to pick: Pilot's notes for a note setting, the actions a button may run for an actions
/// setting (each of a button's shape, Widget.isActionID, and one Pilot has), and Hyper+Space's rows for the Launcher's
/// menu setting; a render hands its own.
struct WidgetEditChoices {
    struct Pick: Hashable { let id: String, title: String, group: String }
    var notes: @MainActor () async -> [(id: String, title: String)]
    var actions: @MainActor () -> [Pick]
    var menu: @MainActor () -> [Pick] = { [] }

    @MainActor static let live = WidgetEditChoices(
        notes: { WidgetNotes.choices(await WidgetNotes.read(WidgetNotes.folder)) },
        actions: {
            // Binds' list, in its order, by its module titles, as the Rings picker offers it.
            (Engine.shared?.bindActions.filter { Widget.isActionID($0.id) } ?? [])
                .map { Pick(id: $0.id, title: $0.label, group: Abilities.title($0.module)) }
        },
        menu: { WidgetLauncher.choices() })
}

/// Edit widget (like macOS's): one placement's own settings, on the desktop or on Home, each kept for that placement
/// alone; a password stays the widget's, in the Keychain, shared by every copy. A desktop placement also picks the
/// workspace it shows on. Every widget picks its Layout: Auto (by its size) or one of the size classes, kept.
struct WidgetEditSheet: View {
    @Environment(\.ink) private var ink
    let widget: Widget
    let placement: Widget.Placement
    /// The workspaces it may be kept to, the one it is kept to among them (WidgetsPageModel.workspaces(keeping:)).
    let workspaces: [String]
    let choices: WidgetEditChoices
    /// What its actions setting, or the Launcher's menu setting (a widget has one or neither), may pick: read once, as
    /// the sheet shows (the menu's list reads every app), or handed in by a render.
    @State private var picks: [WidgetEditChoices.Pick]
    /// Its values, typed passwords (blank: unchanged) and workspace.
    let save: ([String: JSONValue], [String: String], String?) -> Void
    let cancel: () -> Void
    @State private var values: [String: JSONValue]
    @State private var passwords: [String: String] = [:]
    @State private var workspace: String?
    /// Its Layout: nil for Auto.
    @State private var layout: Widget.SizeClass?
    /// The note setting's choices: every note until the notes are read (`choices.notes`), unless handed in.
    @State private var notes: [(id: String, title: String)]

    init(widget: Widget, placement: Widget.Placement, values: [String: JSONValue], workspaces: [String], choices: WidgetEditChoices,
         notes: [(id: String, title: String)]? = nil,
         save: @escaping ([String: JSONValue], [String: String], String?) -> Void, cancel: @escaping () -> Void) {
        self.widget = widget; self.placement = placement; self.workspaces = workspaces; self.choices = choices
        self.save = save; self.cancel = cancel
        _values = State(initialValue: values)
        _workspace = State(initialValue: placement.workspace)
        _layout = State(initialValue: widget.layout(of: placement))
        _notes = State(initialValue: notes ?? WidgetNotes.choices([]))
        _picks = State(initialValue: notes == nil ? [] : Self.picks(widget, choices))
        reads = notes == nil
    }
    private let reads: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(widget.icon)  \(WidgetAsks.shown(widget.title))").font(ink.ui(15, .semibold)).foregroundStyle(ink.text)
                Text(placement.onHome ? "On Home: these settings are this one's own." : "On the desktop: these settings are this one's own.")
                    .font(ink.ui(11.5)).foregroundStyle(ink.muted)
            }
            if !placement.onHome {
                field("Shows on") {
                    Picker("", selection: $workspace) {
                        Text("All workspaces").tag(String?.none)
                        ForEach(workspaces, id: \.self) {
                            Text("Workspace \($0)").tag(String?.some($0))
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if widget.offersLayout {
                field("Layout") {
                    Picker("", selection: $layout) {
                        Text("Auto: by its size").tag(Widget.SizeClass?.none)
                        ForEach(Widget.SizeClass.allCases, id: \.self) { Text($0.title).tag(Widget.SizeClass?.some($0)) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if widget.settings.isEmpty && !widget.offersLayout {
                Text("It has no settings of its own.").font(ink.ui(12)).foregroundStyle(ink.text2)
            }
            ForEach(widget.settings, id: \.name) { setting in field(setting.label) { editor(setting) } }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.pilot).keyboardShortcut(.cancelAction)
                Button("Save") {
                    var kept = values
                    if widget.offersLayout { kept[Widget.layoutName] = layout.map { .string($0.rawValue) } }
                    save(kept, passwords, workspace)
                }
                .buttonStyle(.pilotPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 440).pilotSheet()
        .task {
            guard reads else { return }
            picks = Self.picks(widget, choices)
            if widget.settings.contains(where: { $0.kind == .note }) { notes = await choices.notes() }
        }
    }

    private func field(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(ink.ui(12, .semibold)).foregroundStyle(ink.text)
            content()
        }
    }

    @ViewBuilder private func editor(_ field: Widget.Field) -> some View {
        let text = Binding(get: { values[field.name].flatMap(Self.text) ?? "" }, set: { values[field.name] = .string($0) })
        switch field.kind {
        case .text where widget.id == ReadyWidgets.folder: WidgetFolderField(field: field, text: text)
        case .text where widget.data == .markets(field.name): WidgetMarketsEditor(value: Binding(get: { values[field.name] }, set: { values[field.name] = $0 }))
        case .text, .colour: TextField(field.kind == .colour ? "#RRGGBB" : "", text: text).pilotField()
        case .number:
            TextField("", text: Binding(get: { text.wrappedValue }, set: { values[field.name] = Double($0).map(JSONValue.number) ?? .string($0) }))
                .pilotField()
        case .checkbox:
            Toggle("", isOn: Binding(get: { values[field.name] == .bool(true) }, set: { values[field.name] = .bool($0) })).labelsHidden()
        case .choice:
            Picker("", selection: text) { ForEach(field.choices, id: \.self) { Text($0).tag($0) } }.labelsHidden()
        case .password:
            SecureField("Saved in the Keychain; type to replace", text: Binding(get: { passwords[field.name] ?? "" }, set: { passwords[field.name] = $0 }))
                .pilotField().secureFieldTip()
            Text("Shared by every copy of this widget.").font(ink.ui(11)).foregroundStyle(ink.muted)
        case .note:
            // A note gone since keeps its place in the list, by its id, so saving never picks another.
            let listed = notes + (notes.contains { $0.id == text.wrappedValue } ? [] : [(text.wrappedValue, text.wrappedValue)])
            Picker("", selection: text) { ForEach(listed, id: \.id) { Text($0.title).tag($0.id) } }.labelsHidden().fixedSize()
        case .actions, .menu:
            let picked = Binding(get: { field.kind == .menu ? Widget.menuPicks(values[field.name]) : Widget.picks(values[field.name]) },
                                 set: { values[field.name] = .array($0.map(JSONValue.string)) })
            if field.kind == .menu { WidgetLauncherEditor(picks: picked, choices: picks) } else { WidgetActionsEditor(picks: picked, choices: picks) }
        }
    }

    private static func picks(_ widget: Widget, _ choices: WidgetEditChoices) -> [WidgetEditChoices.Pick] {
        widget.menuField != nil ? choices.menu() : widget.actionsField != nil ? choices.actions() : []
    }

    static func text(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): s
        case .number(let n): Int(exactly: n).map(String.init) ?? String(n)
        default: nil
        }
    }
}

/// An actions setting's buttons, in order: each its action's name, moved up or down or removed, and Add a button with
/// every action a button may run, by module. At most Widget.mostPicks.
struct WidgetActionsEditor: View {
    @Environment(\.ink) private var ink
    @Binding var picks: [String]
    let choices: [WidgetEditChoices.Pick]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetPicksList(picks: $picks, choices: choices, empty: "No buttons yet.", missing: "not in Pilot now")
            // Its groups in the list's own order.
            let left = choices.filter { !picks.contains($0.id) }
            let groups = left.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            Menu("Add a button") {
                ForEach(groups, id: \.self) { group in
                    Section(group) { ForEach(left.filter { $0.group == group }, id: \.id) { pick in Button(pick.title) { picks.append(pick.id) } } }
                }
            }
            .fixedSize().disabled(picks.count >= Widget.mostPicks)
            .help("Pilot actions a click may run: none that act on the Mac unasked, none that name an app, a site or a page")
        }
    }
}

/// An editor's picks, in order: each its name, moved up or down or removed; one Pilot no longer has says so.
struct WidgetPicksList: View {
    @Environment(\.ink) private var ink
    @Binding var picks: [String]
    let choices: [WidgetEditChoices.Pick]
    let empty: String, missing: String

    var body: some View {
        let titles = Dictionary(choices.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 4) {
            if picks.isEmpty { Text(empty).font(ink.ui(12)).foregroundStyle(ink.muted) }
            ForEach(Array(picks.enumerated()), id: \.element) { i, id in
                HStack(spacing: 6) {
                    Text(titles[id] ?? id).font(ink.ui(12.5)).foregroundStyle(titles[id] == nil ? ink.muted : ink.text).lineLimit(1)
                    if titles[id] == nil { Text(missing).font(ink.ui(11)).foregroundStyle(ink.muted) }
                    Spacer(minLength: 6)
                    Button { picks.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0).help("Move up")
                    Button { picks.swapAt(i, i + 1) } label: { Image(systemName: "chevron.down") }.disabled(i == picks.count - 1).help("Move down")
                    Button { picks.remove(at: i) } label: { Image(systemName: "xmark") }.help("Remove")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

/// The Launcher's tiles, in order: each its row's name, moved up or down or removed; then a search over every row
/// Hyper+Space lists (apps, actions, app commands, extension commands, its menus), a click adding one. At most
/// Widget.mostMenuPicks.
struct WidgetLauncherEditor: View {
    @Environment(\.ink) private var ink
    @Binding var picks: [String]
    let choices: [WidgetEditChoices.Pick]
    @State private var query = ""

    var body: some View {
        // The binding's picks parsed once a draw, not once a row.
        let taken = Set(picks), full = taken.count >= Widget.mostMenuPicks
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.vertical) {
                WidgetPicksList(picks: $picks, choices: choices, empty: "No tiles yet.", missing: "not in Hyper+Space now")
            }
            .frame(maxHeight: 150).fixedSize(horizontal: false, vertical: true)
            TextField("Add a tile: search apps, actions, menus", text: $query).pilotField()
                .disabled(full)
            let found = Self.found(choices.filter { !taken.contains($0.id) }, query)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(found, id: \.id) { pick in
                        Button { picks.append(pick.id); query = "" } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle").foregroundStyle(ink.muted)
                                Text(pick.title).font(ink.ui(12.5)).foregroundStyle(ink.text).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(pick.group).font(ink.ui(11)).foregroundStyle(ink.muted).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless).disabled(full)
                    }
                    if found.isEmpty { Text("Nothing in Hyper+Space matches.").font(ink.ui(12)).foregroundStyle(ink.muted) }
                }
            }
            .frame(height: 140)
        }
    }

    /// The rows the search finds by title or group as Pilot's other lists filter (FuzzyRanker.Filter: as typed, else a
    /// typo away), the menu's order kept; every row before typing; the first 200.
    static func found(_ choices: [WidgetEditChoices.Pick], _ query: String) -> [WidgetEditChoices.Pick] {
        Array(FuzzyRanker.Filter(query).filter(choices) { [$0.title, $0.group] }.prefix(200))
    }
}
