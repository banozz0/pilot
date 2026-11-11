import PilotCore
import SwiftUI

/// Binds' list in Instrument (card agent-bo-95423181): what a search and Show as list open, the same list as Toybox's
/// (PilotCore's BindsPage.sections) in Instrument's parts: the page's bar with back to the
/// keyboard, the search, the preset and Add bind; the layers as a filter; a panel per layer whose rows edit on a click,
/// each with Reset where Sven set it; a search that finds nothing says so and how to widen it; Reset all at the foot.
struct InstrumentBindsList: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    /// The Plain combos list: that section alone, no preset or filter.
    let only: BindsPage.Tab?
    /// The window's search, followed while it changes.
    let seed: String
    /// Back to the keyboard; nil while the window's search lists.
    let back: (() -> Void)?
    @State private var filter: BindsPage.Tab?
    @State private var search = ""
    @State private var editing: BindEditing?
    @State private var confirmingResetAll = false
    @State private var switchingTo: BindStore.Preset?
    @State private var refusal: String?
    @FocusState private var searching: Bool

    var body: some View {
        let actions = engine.bindActions, store = engine.binds.store
        let (layers, sections) = BindsList.list(engine.binds.store, actions: actions, only: only, filter: filter, search: search)
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                InstrumentPageBar(title: only == .plain ? AppSection.plainCombos.title : "Binds") { backButton; Spacer(minLength: 8); controls(store) }
                VStack(alignment: .leading, spacing: 0) {
                    InstrumentPageBar(title: only == .plain ? AppSection.plainCombos.title : "Binds") { backButton; Spacer(minLength: 8) }
                    controls(store).padding(.horizontal, style.density.page).padding(.bottom, 12)
                }
            }
            InstrumentRule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // A search spans every layer, so the filter waits out of sight.
                    if only == nil && search.isEmpty { filters(layers) }
                    ForEach(sections) { section in
                        InstrumentPanel(title: section.tab.title, note: "\(section.rows.count)") {
                            VStack(alignment: .leading, spacing: 0) {
                                if let note = section.tab.explanation {
                                    Text(note).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 18).padding(.top, 12)
                                }
                                if section.rows.isEmpty {
                                    Text("None yet").styleText(\.body).foregroundStyle(style.color(\.text3)).padding(18)
                                }
                                ForEach(Array(section.rows.enumerated()), id: \.element.id) { i, row in
                                    if i > 0 { InstrumentRule() }
                                    self.row(row, tab: section.tab)
                                }
                            }
                        }
                    }
                    if sections.isEmpty { noMatch }
                    HStack {
                        if let refusal { Text(refusal).styleText(\.caption).foregroundStyle(style.color(\.accentText)) }
                        Spacer()
                        Button("Reset all to defaults…") { confirmingResetAll = true }.buttonStyle(InstrumentButtonStyle(kind: .ghost))
                    }
                }
                .padding(.horizontal, style.density.page).padding(.vertical, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.windowFill(style.color(\.canvas)))
        .onChange(of: seed, initial: true) { search = seed }
        .onAppear { if seed.isEmpty { searching = true } }
        .bindsDialogs(editing: $editing, switchingTo: $switchingTo, confirmingResetAll: $confirmingResetAll, refusal: $refusal)
    }

    @ViewBuilder private var backButton: some View {
        if let back {
            Button(action: back) { InstrumentKeyedLabel(title: "Keyboard", symbol: "chevron.left") }.buttonStyle(InstrumentButtonStyle(kind: .ghost))
        }
    }

    private func controls(_ store: BindStore) -> some View {
        HStack(spacing: 8) {
            let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(style.font(\.icon)).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
                TextField("Search binds", text: $search, prompt: Text("Search binds…").foregroundStyle(style.color(\.text3)))
                    .textFieldStyle(.plain).styleText(\.body).foregroundStyle(style.color(\.text)).focused($searching)
            }
            .padding(.horizontal, 9).frame(width: 220, height: style.density.control)
            .background(style.color(\.raised), in: shape)
            .overlay { shape.strokeBorder(style.color(\.line)) }
            if only == nil {
                InstrumentSegments(options: store.presets.map { ($0, $0.title) },
                                   selection: Binding(get: { store.preset }, set: { if $0 != store.preset { switchingTo = $0 } }))
                    .accessibilityLabel("Preset")
                PresetMoreMenu()
            }
            Button { editing = .init(action: nil) } label: { InstrumentKeyedLabel(title: "New bind", symbol: "plus") }
                .buttonStyle(InstrumentButtonStyle(kind: .primary))
        }
        .fixedSize()
    }

    /// All, or one layer that has binds, as the module chips under the keyboard pick.
    private func filters(_ tabs: [BindsPage.Tab]) -> some View {
        Flow(spacing: 6, lineSpacing: 6) {
            ForEach(Array(([nil] + tabs.map(Optional.some)).enumerated()), id: \.offset) { _, tab in
                InstrumentChip(title: tab.map(\.title) ?? "All", on: tab == filter) { filter = tab }
            }
        }
    }

    /// One bind: its keys, its name with its module, Reset where Sven set it, Edit; a click anywhere edits it.
    private func row(_ row: BindsPage.Row, tab: BindsPage.Tab) -> some View {
        HStack(spacing: 14) {
            keys(row.key, hyper: tab.keysAlone).frame(minWidth: tab.keysAlone ? 96 : BindsList.keyColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).styleText(\.body).foregroundStyle(style.color(\.text)).fixedSize(horizontal: false, vertical: true)
                Text(BindsKeyboard.modules[BindsKeyboard.module(row.module)] + (row.custom ? " · yours" : ""))
                    .styleText(\.caption).foregroundStyle(style.color(\.text3))
                if let warning = row.warning { Text(warning).styleText(\.caption).foregroundStyle(style.color(\.accentText)).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if row.custom { Button("Reset") { reset(row.id) }.buttonStyle(InstrumentButtonStyle(kind: .ghost)) }
            Button("Edit") { editing = .init(action: row.id) }.buttonStyle(InstrumentButtonStyle())
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .contentShape(.rect)
        .onTapGesture { editing = .init(action: row.id) }
    }

    /// A row's keys as chips, as the menu shows a bind's (InstrumentBindKeys): the layer key's where the heading names the
    /// layer, then each part of the trigger, a modifier as its sign.
    @ViewBuilder private func keys(_ key: String?, hyper: Bool) -> some View {
        if let key {
            InstrumentBindKeys(label: hyper && !key.hasPrefix("Hyper") ? "Hyper+" + key : key, layerKeys: engine.settings.layerKeys).fixedSize()
        } else {
            Text("No key").styleText(\.caption).foregroundStyle(style.color(\.text3))
        }
    }

    /// A search that found nothing: what was searched, and what a search reads.
    private var noMatch: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No bind matches “\(search.trimmingCharacters(in: .whitespaces))”").styleText(\.title).foregroundStyle(style.color(\.text))
            Text("A search reads each bind's name, its keys and its module. Clear it to see every layer.")
                .styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
            if !search.isEmpty {
                Button { search = "" } label: { InstrumentKeyedLabel(title: "Clear search", symbol: "xmark") }
                    .buttonStyle(InstrumentButtonStyle()).padding(.top, 6)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .styleSurface(\.card)
    }

    private func reset(_ action: String) {
        do { try engine.binds.reset(action); refusal = nil } catch { refusal = BindsPage.refusal(error, actions: engine.bindActions) }
    }
}
