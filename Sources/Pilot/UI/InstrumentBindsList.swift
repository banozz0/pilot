import PilotCore
import SwiftUI

/// Binds › All actions in Instrument (Sven, 2026-11-27; the List button's list until then, card agent-bo-95423181), and
/// what a search on the keyboard lists: the page's bar with Binds' tabs, the search, the preset and New bind; the groups
/// as a filter; a panel per group (PilotCore's BindsPage.groups) whose rows open the bind editor on a click, a bound one's
/// Change and a Not bound one's Bind each with Reset where Sven set it; a search that finds nothing says so and how to
/// widen it; Reset all at the foot.
struct InstrumentBindsList: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    /// The window's search, followed while it changes.
    let seed: String
    /// The tab the bar marks: All actions, or nil (Keyboard) while the keyboard's search lists.
    let picked: AppSection?
    let go: (AppPlace) -> Void
    /// The group picked; nil for all.
    @State private var filter: String?
    @State private var search = ""
    @State private var editing: BindEditing?
    @State private var confirmingResetAll = false
    @State private var switchingTo: BindStore.Preset?
    @State private var refusal: String?
    @FocusState private var searching: Bool

    /// `filter`: the group picked as it opens (a render's).
    init(seed: String, picked: AppSection?, filter: String? = nil, go: @escaping (AppPlace) -> Void) {
        self.seed = seed
        self.picked = picked
        self.go = go
        _filter = State(initialValue: filter)
    }

    var body: some View {
        let store = engine.binds.store
        let groups = BindsPage.groups(store: store, actions: engine.bindActions, search: search)
        // A group that has since emptied lists everything again; a search spans every group.
        let pick = search.isEmpty ? filter.flatMap { f in groups.contains { $0.title == f } ? f : nil } : nil
        let shown = pick.map { p in groups.filter { $0.title == p } } ?? groups
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                InstrumentPageBar(title: "Binds") { tabs; Spacer(minLength: 8); controls(store) }
                VStack(alignment: .leading, spacing: 0) {
                    InstrumentPageBar(title: "Binds") { tabs; Spacer(minLength: 8) }
                    controls(store).padding(.horizontal, style.density.page).padding(.bottom, 12)
                }
            }
            InstrumentRule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if search.isEmpty { filters(groups.map(\.title), picked: pick) }
                    ForEach(shown) { group in
                        InstrumentPanel(title: group.title, note: "\(group.rows.count)") {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(group.rows.enumerated()), id: \.element.id) { i, row in
                                    if i > 0 { InstrumentRule() }
                                    self.row(row, unbound: group.unbound)
                                }
                            }
                        }
                    }
                    if shown.isEmpty { noMatch }
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
        // On each return visit too (page-switch-3: a kept page shown again appears no more).
        .onPageArrive { if seed.isEmpty { searching = true } }
        .bindsDialogs(editing: $editing, switchingTo: $switchingTo, confirmingResetAll: $confirmingResetAll, refusal: $refusal)
    }

    private var tabs: some View { BindsPartTabs(picked: picked, go: go).padding(.leading, 8) }

    private func controls(_ store: BindStore) -> some View {
        HStack(spacing: 8) {
            let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(style.font(\.icon)).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
                TextField("Search actions", text: $search, prompt: Text("Search actions…").foregroundStyle(style.color(\.text3)))
                    .textFieldStyle(.plain).styleText(\.body).foregroundStyle(style.color(\.text)).focused($searching)
            }
            .padding(.horizontal, 9).frame(width: 220, height: style.density.control)
            .background(style.color(\.raised), in: shape)
            .overlay { shape.strokeBorder(style.color(\.line)) }
            InstrumentSegments(options: store.presets.map { ($0, $0.title) },
                               selection: Binding(get: { store.preset }, set: { if $0 != store.preset { switchingTo = $0 } }))
                .accessibilityLabel("Preset")
            PresetMoreMenu()
            Button { editing = .init(action: nil) } label: { InstrumentKeyedLabel(title: "New bind", symbol: "plus") }
                .buttonStyle(InstrumentButtonStyle(kind: .primary))
        }
        .fixedSize()
    }

    /// All, or one group, as the module chips under the keyboard pick.
    private func filters(_ titles: [String], picked: String?) -> some View {
        Flow(spacing: 6, lineSpacing: 6) {
            ForEach(Array(([nil] + titles.map(Optional.some)).enumerated()), id: \.offset) { _, title in
                InstrumentChip(title: title ?? "All", on: title == picked) { filter = title }
            }
        }
    }

    /// One action: its keys, its name (with its group under Not bound, which does not name it), Reset where Sven set it,
    /// then Change, or Bind with no key; a click anywhere opens the bind editor, which takes the key.
    private func row(_ row: BindsPage.Row, unbound: Bool) -> some View {
        let module = BindsKeyboard.modules[BindsKeyboard.module(row.module)]
        let caption = unbound ? module + (row.custom ? " · yours" : "") : row.custom ? "Yours" : nil
        return HStack(spacing: 14) {
            keys(row.key).frame(minWidth: BindsList.keyColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).styleText(\.body).foregroundStyle(style.color(\.text)).fixedSize(horizontal: false, vertical: true)
                if let caption { Text(caption).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
                if let warning = row.warning { Text(warning).styleText(\.caption).foregroundStyle(style.color(\.accentText)).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if row.custom { Button("Reset") { reset(row.id) }.buttonStyle(InstrumentButtonStyle(kind: .ghost)) }
            Button(unbound ? "Bind" : "Change") { editing = .init(action: row.id) }.buttonStyle(InstrumentButtonStyle())
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .contentShape(.rect)
        .onTapGesture { editing = .init(action: row.id) }
    }

    /// A row's keys as chips, as the menu shows a bind's (InstrumentBindKeys), a modifier as its sign.
    @ViewBuilder private func keys(_ key: String?) -> some View {
        if let key {
            InstrumentBindKeys(label: key, layerKeys: engine.settings.layerKeys).fixedSize()
        } else {
            Text("No key").styleText(\.caption).foregroundStyle(style.color(\.text3))
        }
    }

    /// A search that found nothing: what was searched, and what a search reads.
    private var noMatch: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No action matches “\(search.trimmingCharacters(in: .whitespaces))”").styleText(\.title).foregroundStyle(style.color(\.text))
            Text("A search reads each action's name, its keys and its group. Clear it to see every action.")
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
