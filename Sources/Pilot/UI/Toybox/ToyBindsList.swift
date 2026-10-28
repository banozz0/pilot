import PilotCore
import SwiftUI

/// Binds' list in Toybox (card agent-bo-95423182): what Find and Show as list open, the same list as Instrument's
/// (PilotCore's BindsPage.sections) in the style's parts: back to the keyboard, the preset, the search, Add bind; the layer
/// filter; a card per layer whose rows edit on a click, each with Reset where Sven set it; Reset all at the foot.
struct ToyBindsList: View {
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
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { title; Spacer(minLength: 12); controls(store) }
                VStack(alignment: .leading, spacing: 12) { title; controls(store) }
            }
            // A search spans every layer, so the filter waits out of sight.
            if only == nil && search.isEmpty { filters(layers) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        ToyCard(title: section.tab.title) {
                            Text("\(section.rows.count)").font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2)).monospacedDigit()
                        } content: {
                            if let note = section.tab.explanation {
                                Text(note).font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                            }
                            if section.rows.isEmpty { Text("None yet").font(style.toyNunito(700, 14)).foregroundStyle(style.color(\.text3)) }
                            VStack(spacing: 0) {
                                ForEach(Array(section.rows.enumerated()), id: \.element.id) { i, row in
                                    if i > 0 { style.color(\.line).frame(height: 1) }
                                    self.row(row, tab: section.tab)
                                }
                            }
                        }
                    }
                    if sections.isEmpty {
                        Text("No bind matches “\(search.trimmingCharacters(in: .whitespaces))”.").font(style.toyNunito(700, 14)).foregroundStyle(style.color(\.text2))
                    }
                }
                .padding(.bottom, 8)
            }
            HStack {
                if let refusal { Text(refusal).font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.problem)) }
                Spacer()
                Button("Reset all to defaults…") { confirmingResetAll = true }.buttonStyle(.pilotDestructive)
            }
        }
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(style.color(\.canvas))
        .onChange(of: seed, initial: true) { search = seed }
        .onAppear { if seed.isEmpty { searching = true } }
        .bindsDialogs(editing: $editing, switchingTo: $switchingTo, confirmingResetAll: $confirmingResetAll, refusal: $refusal)
    }

    private var title: some View {
        HStack(spacing: 12) {
            if let back {
                Button(action: back) { Label("Keyboard", systemImage: "chevron.left") }.buttonStyle(ToyBindsButton(small: true))
            }
            Text(only == .plain ? "Plain combos" : "Binds").styleText(\.pageTitle).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
        }
        .fixedSize()
    }

    private func controls(_ store: BindStore) -> some View {
        HStack(spacing: 10) {
            if only == nil {
                ToySegments(selection: Binding(get: { store.preset }, set: { if $0 != store.preset { switchingTo = $0 } }),
                            options: store.presets.map { ($0, $0.title) }, label: "Layout")
                PresetMoreMenu()
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .bold)).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
                TextField("Search binds", text: $search, prompt: Text("Search binds…").foregroundStyle(style.color(\.text3)))
                    .textFieldStyle(.plain).font(style.toyNunito(700, 14)).foregroundStyle(style.color(\.text))
                    .focused($searching)
            }
            .padding(.horizontal, 12).frame(width: 220, height: 34)
            .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
            .background(Toy.block(style, fill: style.color(\.panel), radius: style.radii.control, edge: 4))
            Button { editing = .init(action: nil) } label: { Label("Add bind", systemImage: "plus") }.buttonStyle(.pilotPrimary)
        }
        .fixedSize()
    }

    /// All, or one layer that has binds.
    private func filters(_ tabs: [BindsPage.Tab]) -> some View {
        Flow(spacing: 8, lineSpacing: 8) {
            ForEach(Array(([nil] + tabs.map(Optional.some)).enumerated()), id: \.offset) { _, tab in
                let on = tab == filter
                Button { filter = tab } label: {
                    Text(tab.map { $0.title } ?? "All").font(style.toyNunito(800, 13.5))
                        .foregroundStyle(on ? style.color(\.onAccent) : style.color(\.text))
                        .padding(.horizontal, 12).frame(height: 32 - 6)
                        .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
                        .background(Toy.block(style, fill: on ? style.color(\.accent) : style.color(\.panel), radius: 11, edge: 4))
                }
                .buttonStyle(.kitPress)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    /// One bind: its keys, its name with its module, Reset where Sven set it, Edit; a click anywhere edits it.
    private func row(_ row: BindsPage.Row, tab: BindsPage.Tab) -> some View {
        let module = BindsKeyboard.module(row.module)
        return HStack(spacing: 14) {
            keys(row.key, hyper: tab.keysAlone).frame(minWidth: tab.keysAlone ? 96 : BindsList.keyColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.label).font(style.toyNunito(800, 14)).foregroundStyle(style.color(\.text))
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Toy.module(module, style))
                        .overlay { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(style.color(\.outline), lineWidth: 1.5) }
                        .frame(width: 10, height: 10)
                    Text(BindsKeyboard.modules[module] + (row.custom ? " · yours" : "")).font(style.toyNunito(700, 12)).foregroundStyle(style.color(\.text2))
                }
                if let warning = row.warning { Text(warning).font(style.toyNunito(700, 12)).foregroundStyle(style.color(\.text2)) }
            }
            Spacer(minLength: 8)
            if row.custom { Button("Reset") { reset(row.id) }.buttonStyle(ToyBindsButton(small: true)) }
            Button("Edit") { editing = .init(action: row.id) }.buttonStyle(ToyBindsButton(small: true))
        }
        .padding(.vertical, 9)
        .contentShape(.rect)
        .onTapGesture { editing = .init(action: row.id) }
    }

    /// A row's keys as keycaps: Hyper's where the heading names the layer, then each part of the trigger.
    private func keys(_ key: String?, hyper: Bool) -> some View {
        Group {
            if let parts = key?.split(separator: "+").map(String.init) {
                ToyKeys(keys: parts.filter { $0 != "Hyper" }, hyper: hyper || parts.contains("Hyper"))
            } else {
                Text("No key").font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text3))
            }
        }
        .fixedSize()
    }

    private func reset(_ action: String) {
        do { try engine.binds.reset(action); refusal = nil } catch { refusal = BindsPage.refusal(error, actions: engine.bindActions) }
    }
}
