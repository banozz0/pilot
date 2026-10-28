import AppKit
import PilotCore
import SwiftUI

/// Binds in Instrument (mockup A's binds.html, card agent-bo-95423181, ADR 0008): the page's bar with the six tabs and
/// their counts, Conflicts, the preset and New bind; the keyboard on its panel with the modules under it (each picks what
/// the board lights and the table lists) and how to see the overlay; the table of the module's binds with their keys,
/// route and today's presses; and the picked key's inspector: what it does, its route, today's presses, where else it
/// shows, its clash, Change key, Unbind and Reset, the tab's free keys and the key on every tab; the Cleaning block last
/// (KeyboardLockCard). Every act is BindsKeyboardPage's own (`Acts`), as Toybox's page uses them, so picking, binding,
/// clearing, presets and the list behave as in Toybox. Over 1100 pt the inspector stands beside the board and the table while the board there still
/// holds every name whole, else beside the table under a board across the page; narrower the three stack, the inspector
/// in two columns while it is 600 pt wide. The page scrolls; nothing in it scrolls on its own.
struct InstrumentBindsPage: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let binds: HomeBinds
    let key: Int64?
    @Binding var layer: BindsKeyboard.Layer
    let boards: KeyboardCaptions.Boards
    let refusal: String?
    let acts: BindsKeyboardPage.Acts
    /// The module the board lights and the table lists; nil for all six.
    @State var module: Int?
    @State private var width: CGFloat = 0
    @State private var clashes: [SymbolicHotKeys.Clash] = []

    /// The width from which the inspector may stand beside the board and the table, and its own.
    static let beside: CGFloat = 1100, inspector: CGFloat = 272

    /// Where the inspector stands: beside the board and the table, beside the table under a board across the page, or
    /// stacked under the board with the table under it.
    enum Arrangement { case beside, under, stacked }

    /// The arrangement on a page `width` wide and the board's keys' width in it: from 1100 pt the inspector beside the
    /// board while the narrower board there holds every name on the 75 % board, else under it.
    @MainActor static func arrangement(_ width: CGFloat, marks: InstrumentBoardFit.Marks, boards: KeyboardCaptions.Boards,
                                       style: StyleTokens) -> (Arrangement, board: CGFloat) {
        let across = width - 2 * side(width, style) - 2 * inset(width)
        guard width >= beside else { return (.stacked, across) }
        let narrower = across - inspector - 20
        let fit = InstrumentBoardFit.best(marks, boards: boards, width: narrower, measure: InstrumentBoardFit.measure(style.type.keyName))
        return fit.board == boards.compact ? (.beside, narrower) : (.under, across)
    }

    /// The table's width: the page less its sides, and beside the inspector, less it and the gap.
    private func tableWidth(_ arrangement: Arrangement) -> CGFloat {
        width - 2 * Self.side(width, style) - (arrangement == .stacked ? 0 : Self.inspector + 20)
    }

    /// The page's sides: the style's page margin, 16 pt on a page under 760 pt (the least window's), so the board keeps
    /// its room; the keyboard panel's inside likewise 20, or 12.
    static func side(_ width: CGFloat, _ style: StyleTokens) -> CGFloat { width < 760 ? 16 : style.density.page }
    static func inset(_ width: CGFloat) -> CGFloat { width < 760 ? 12 : 20 }

    var body: some View {
        let counts = tabCounts
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                InstrumentPageBar(title: "Binds", side: Self.side(width, style)) { HStack(spacing: 2) { layerButtons(counts) }.fixedSize().padding(.leading, 6); Spacer(minLength: 8); fittedControls }
                VStack(spacing: 0) {
                    InstrumentPageBar(title: "Binds", side: Self.side(width, style)) { Spacer(minLength: 8); fittedControls }
                    Flow(spacing: 2, lineSpacing: 4) { layerButtons(counts) }
                        .padding(.horizontal, Self.side(width, style)).padding(.bottom, 10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            InstrumentRule()
            let marks = InstrumentBoardFit.Marks(binds, boards: boards)
            switch Self.arrangement(width, marks: marks, boards: boards, style: style).0 {
            case .beside: beside(marks)
            case .under: under(marks)
            case .stacked: stacked(marks)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.windowFill(style.color(\.canvas)))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // ShortcutConflicts' clashes, read once per change of the binds, as the window's Conflicts count is.
        .task(id: engine.binds.store.binds) { clashes = ShortcutConflicts.shared.clashes(binds: engine.binds.store.binds) }
    }

    // MARK: Bar

    /// How many binds each tab holds, in one pass over the binds.
    private var tabCounts: [BindsKeyboard.Layer: Int] {
        var counts: [BindsKeyboard.Layer: Int] = [:]
        for key in engine.binds.store.binds.keys { for tab in BindsKeyboard.Layer.allCases where tab.tab.holds(key) { counts[tab, default: 0] += 1 } }
        return counts
    }

    /// The six tabs, each with its count, the picked one raised; under the bar on a narrow page, as many a line as fit.
    private func layerButtons(_ counts: [BindsKeyboard.Layer: Int]) -> some View {
        ForEach(BindsKeyboard.Layer.allCases, id: \.self) { layer in
            tabButton(layer, count: counts[layer] ?? 0)
        }
    }

    private func tabButton(_ which: BindsKeyboard.Layer, count: Int) -> some View {
        let on = layer == which
        let title = Self.title(which), sign = Self.signs[which]
        return Button { layer = which } label: {
            HStack(spacing: 7) {
                if let sign { Image(systemName: sign).font(style.font(\.key)).foregroundStyle(style.color(\.text3)) }
                Text(title).styleText(on ? \.strong : \.body).foregroundStyle(style.color(on ? \.text : \.text2))
                Text("\(count)").styleText(\.key).foregroundStyle(style.color(on ? \.accentText : \.text3))
            }
            .padding(.horizontal, 10).frame(height: style.density.control)
            .instrumentRaised(on)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) binds")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// A tab's name in the bar: Hyper, Shift, Ctrl, Alt, Shift Ctrl, Plain combos.
    static func title(_ tab: BindsKeyboard.Layer) -> String {
        tab == .plain ? "Plain combos" : tab == .hyper ? "Hyper" : String(tab.title.dropFirst(2))
    }

    /// The single modifiers' line signs, as the mockup's tabs wear them.
    static let signs: [BindsKeyboard.Layer: String] = [.shift: "shift", .ctrl: "control", .alt: "option"]

    /// The bar's buttons with their words, or, on a page too narrow for them (760 pt, one type step up), Abilities, Overlay
    /// and Conflicts as their glyphs, so the title and New bind keep their place.
    private var fittedControls: some View {
        ViewThatFits(in: .horizontal) {
            controls(compact: false)
            controls(compact: true)
        }
    }

    private func controls(compact: Bool) -> some View {
        let store = engine.binds.store
        return HStack(spacing: 8) {
            // This page draws its own bar; Abilities is Launcher › Abilities (C3), which this button opens.
            Button { acts.go(AppPlace(.abilities)) } label: { barLabel("Abilities", symbol: "sparkles", compact: compact) }
                .buttonStyle(InstrumentButtonStyle(kind: .ghost))
                .help("Everything Pilot can do, with what it does").accessibilityLabel("Abilities")
            Button { acts.go(AppPlace(.overlay)) } label: { barLabel("Overlay", symbol: "rectangle.grid.2x2", compact: compact) }
                .buttonStyle(InstrumentButtonStyle(kind: .ghost))
                .help("Pick what holding Hyper shows").accessibilityLabel("Overlay")
            Button { acts.go(AppPlace(.mouse)) } label: { barLabel("Mouse", symbol: "computermouse", compact: compact) }
                .buttonStyle(InstrumentButtonStyle(kind: .ghost))
                .help("Bind your mouse's extra buttons").accessibilityLabel("Mouse")
            // macOS shortcuts on a plain combo, and Pilot's defaults another action's key left without one.
            let count = clashes.count + store.refused.count
            Button { acts.go(AppPlace(.conflicts)) } label: {
                HStack(spacing: 6) {
                    barLabel("Conflicts", symbol: "exclamationmark.triangle", compact: compact)
                    Text("\(count)").styleText(\.key).foregroundStyle(style.color(\.text3))
                }
            }
            .accessibilityLabel("Conflicts, \(count)")
            .buttonStyle(InstrumentButtonStyle(kind: count == 0 ? .ghost : .raised))
            .help(count == 0 ? "No clashes" : "macOS shortcuts that clash with your plain combos, and actions whose default key another holds")
            Menu {
                PresetPicker(presets: store.presets, active: store.preset, pick: acts.switchTo)
                PresetMenuItems()
                Divider()
                Button("Show as list", action: acts.showList)
                Button("Import or export binds…") { acts.go(AppPlace(.exportImport)) }
                Button("Save keyboard map…") { BindsMapSave.run(engine: engine) }
                Divider()
                Button("Reset all to defaults…", role: .destructive, action: acts.resetAll)
            } label: {
                HStack(spacing: 7) {
                    Text("Preset · \(store.preset.title)")
                    Image(systemName: "chevron.up.chevron.down").font(style.font(\.key)).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
                }
            }
            .menuStyle(.button).buttonStyle(InstrumentButtonStyle()).menuIndicator(.hidden).fixedSize()
            Button { acts.edit(.init(action: nil)) } label: { InstrumentKeyedLabel(title: "New bind", symbol: "plus") }
                .buttonStyle(InstrumentButtonStyle(kind: .primary))
        }
        .fixedSize()
    }

    @ViewBuilder private func barLabel(_ title: String, symbol: String, compact: Bool) -> some View {
        if compact { Image(systemName: symbol).font(style.font(\.icon)) } else { Text(title) }
    }

    // MARK: Layouts

    /// The board and the table, the inspector beside them; the page scrolls when either runs past the window's foot, so
    /// nothing in the inspector is cut.
    private func beside(_ marks: InstrumentBoardFit.Marks) -> some View {
        FillScroll {
            PinnedBeside {
                VStack(spacing: 16) {
                    keyboard(marks)
                    table(rows(), .beside)
                    KeyboardLockCard(edit: acts.edit)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            } side: {
                sideInspector
            }
            .padding(.horizontal, Self.side(width, style)).padding(.vertical, Self.pinInset)
        }
    }

    /// The board across the page, the table and the inspector beside it under it; the page scrolls as beside.
    private func under(_ marks: InstrumentBoardFit.Marks) -> some View {
        FillScroll {
            VStack(spacing: 16) {
                keyboard(marks)
                PinnedBeside {
                    table(rows(), .under).frame(maxWidth: .infinity, alignment: .top)
                } side: {
                    sideInspector
                }
                KeyboardLockCard(edit: acts.edit)
            }
            .padding(.horizontal, Self.side(width, style)).padding(.vertical, Self.pinInset)
        }
    }

    /// The page's top and foot inset, which the pinned inspector keeps under the window's top as the page scrolls.
    static let pinInset: CGFloat = 20

    /// How far down its column the inspector rides (Moody, batch 3: beside the long table the column under it was a dead
    /// band): at its place while its column's top (`columnTop`, in the scroll view's space) is below the page's `inset`,
    /// then held `inset` under the window's top, never past the column's foot.
    static func pin(columnTop: CGFloat, column: CGFloat, inspector: CGFloat, inset: CGFloat) -> CGFloat {
        min(max(0, inset - columnTop), max(0, column - inspector))
    }

    /// The inspector in one column beside the table, as tall as what it says.
    private var sideInspector: some View {
        InstrumentBindsInspector(binds: binds, key: key, layer: layer, boards: boards, clashes: clashes, refusal: refusal, acts: acts,
                                 shape: .column)
            .frame(width: Self.inspector)
    }

    /// Narrower: the board, the inspector (in two columns while it is 600 pt wide), then the table, the page scrolling.
    private func stacked(_ marks: InstrumentBoardFit.Marks) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                keyboard(marks)
                InstrumentBindsInspector(binds: binds, key: key, layer: layer, boards: boards, clashes: clashes, refusal: refusal, acts: acts,
                                         shape: width - 2 * Self.side(width, style) >= 600 ? .columns : .column)
                table(rows(), .stacked)
                KeyboardLockCard(edit: acts.edit)
            }
            .padding(.horizontal, Self.side(width, style)).padding(.vertical, 20)
        }
    }

    // MARK: Keyboard

    private func keyboard(_ marks: InstrumentBoardFit.Marks) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            InstrumentBindsBoard(boards: boards, binds: binds, layerKeys: engine.settings.layerKeys, layer: layer, picked: key, marks: marks,
                                 module: module, pick: acts.pick, open: { acts.open($0, bound: binds.bound, layer: layer) }, tinted: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { modules; Spacer(minLength: 12); overlayHint }
                VStack(alignment: .leading, spacing: 10) { modules; overlayHint }
            }
        }
        .padding(.horizontal, Self.inset(width)).padding(.top, 18).padding(.bottom, 16)
        .styleSurface(\.board, fill: \.board, radius: \.board)
    }

    /// The modules on this tab as chips with their counts, All first; the picked one inverse. Each module's swatch is the
    /// colour its keys wear on the board: the board's legend.
    private var modules: some View {
        var counts = Array(repeating: 0, count: BindsKeyboard.modules.count)
        for actions in binds.bound.values { for action in actions where binds.infos[action] != nil { counts[binds.module(action)] += 1 } }
        let shown = counts.indices.filter { counts[$0] > 0 }
        return Flow(spacing: 6, lineSpacing: 6) {
            InstrumentChip(title: "All", count: counts.reduce(0, +), on: module == nil) { module = nil }
            ForEach(shown, id: \.self) { i in
                InstrumentChip(title: BindsKeyboard.modules[i], count: counts[i], on: module == i,
                               swatch: Color(style.colors.groups[i % style.colors.groups.count])) { module = module == i ? nil : i }
            }
        }
    }

    /// Hold the layer key for the overlay of this tab's binds.
    private var overlayHint: some View {
        HStack(spacing: 6) {
            Text("Hold")
            InstrumentKey(text: engine.settings.layerKeys.symbol, hyper: true)
            Text("for the overlay")
        }
        .styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize()
        .accessibilityElement(children: .combine)
    }

    // MARK: Table

    /// One bind on the tab: its key and action, its label, today's presses and its glyph (none where another row shows
    /// the same one: two rows sharing a glyph says nothing, HomeBinds.pictures' rule).
    struct Row {
        let code: Int64, action: String, label: String, today: Int
        var glyph: BoardKey.Glyph?
    }

    /// The module's binds on the tab (every bind with no module picked), most pressed today first, then by name.
    func rows() -> [Row] {
        let now = Date.now
        var rows = binds.bound.flatMap { code, actions in
            actions.filter { binds.infos[$0] != nil && (module == nil || binds.module($0) == module) }.map {
                Row(code: code, action: $0, label: binds.infos[$0]?.label ?? $0, today: engine.today.count(of: $0, now: now))
            }
        }
        .sorted { ($1.today, $0.label) < ($0.today, $1.label) }
        let glyphs = HomeBinds.unique(Dictionary(rows.enumerated().map { (Int64($0), binds.picture($1.action)) }, uniquingKeysWith: { a, _ in a }))
        for i in rows.indices { rows[i].glyph = glyphs[Int64(i)] }
        return rows
    }

    @ViewBuilder private func table(_ rows: [Row], _ arrangement: Arrangement) -> some View {
        let columns = TableColumns(width: tableWidth(arrangement))
        let most = max(1, rows.map(\.today).max() ?? 0)
        let list = VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { InstrumentRule() }
                tableRow(row, columns: columns, share: Double(row.today) / Double(most))
            }
            if rows.isEmpty {
                Text(module == nil ? "Nothing on \(Self.title(layer)) yet. Pick a free key to bind it." : "No \(BindsKeyboard.modules[module ?? 0]) bind on \(Self.title(layer)).")
                    .styleText(\.body).foregroundStyle(style.color(\.text3)).padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        VStack(spacing: 0) {
            TableLayout(columns: columns) {
                InstrumentEyebrow(text: "Trigger")
                InstrumentEyebrow(text: "\(module.map { BindsKeyboard.modules[$0] } ?? "All") · \(rows.count)")
                if columns.route { InstrumentEyebrow(text: "Route") }
                if columns.share { InstrumentEyebrow(text: "Share") }
                InstrumentEyebrow(text: "Today")
            }
            .padding(.horizontal, 18).frame(height: 32)
            InstrumentRule()
            list
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .styleSurface(\.card)
    }

    private func tableRow(_ row: Row, columns: TableColumns, share: Double) -> some View {
        let on = row.code == key
        return Button { acts.pick(row.code) } label: {
            TableLayout(columns: columns) {
                if let trigger = engine.binds.store.trigger(for: row.action) { InstrumentKeys(trigger: trigger) } else { Color.clear.frame(height: 1) }
                HStack(spacing: 10) {
                    Group {
                        switch row.glyph {
                        case .image(let image)?: Image(nsImage: image).resizable().interpolation(.high)
                        case .symbol(let symbol)?: Image(systemName: symbol).font(style.font(\.icon)).foregroundStyle(style.color(\.text2))
                        case nil: Color.clear
                        }
                    }
                    .frame(width: 18, height: 18).accessibilityHidden(true)
                    Text(row.label).styleText(\.body).foregroundStyle(style.color(\.text))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if columns.route { Text(row.action).styleText(\.mono).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true) }
                if columns.share { InstrumentMeter(share: share) }
                Text("\(row.today)").styleText(\.mono).foregroundStyle(style.color(\.text2)).monospacedDigit()
            }
            .padding(.horizontal, 18).padding(.vertical, 8).frame(minHeight: 34)
            .background { if on { style.color(\.accentSoft) } }
            .overlay(alignment: .leading) { if on { style.color(\.accent).frame(width: 2) } }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opensOnDoubleClick { acts.edit(.init(action: row.action)) }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The table's columns (the mockup's 96 pt, 1.2fr, 1.5fr, 120 pt and 56 pt): the route goes first, then the share, as
/// the table narrows, so the keys, the action and today's count always show whole.
struct TableColumns: Equatable {
    let route: Bool, share: Bool
    static let trigger: CGFloat = 96, share: CGFloat = 120, today: CGFloat = 56, gap: CGFloat = 16

    /// For a table `width` wide, its sides included.
    init(width: CGFloat) {
        route = width >= 640
        share = width >= 460
    }

    /// Each shown cell's width, the action's and the route's sharing what the fixed ones leave as 1.2 : 1.5.
    func widths(_ width: CGFloat) -> [CGFloat] {
        let shown = 3 + (route ? 1 : 0) + (share ? 1 : 0)
        let flex = max(0, width - Self.trigger - Self.today - (share ? Self.share : 0) - Self.gap * CGFloat(shown - 1))
        let action = route ? flex * 1.2 / 2.7 : flex
        return [Self.trigger, action] + (route ? [flex - action] : []) + (share ? [Self.share] : []) + [Self.today]
    }
}

/// The table's cells in their columns, each centred on the row's height; today's count against the column's right.
private struct TableLayout: Layout {
    let columns: TableColumns

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let heights = zip(subviews, columns.widths(width)).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        let widths = columns.widths(bounds.width)
        for (i, (view, w)) in zip(subviews, widths).enumerated() {
            let last = i == widths.count - 1
            let fit = min(w, view.sizeThatFits(ProposedViewSize(width: w, height: nil)).width)
            view.place(at: CGPoint(x: last ? x + w - fit : x, y: bounds.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: last ? fit : w, height: nil))
            x += w + TableColumns.gap
        }
    }
}

extension BindsKeyboardPage.Acts {
    /// A double-click on a key or a row (Bind editor T3) opens it as Return on the picked key does: a bound key's bind,
    /// a free key a new bind on it with the tab's sublayer.
    func open(_ code: Int64, bound: [Int64: [String]], layer: BindsKeyboard.Layer) {
        switch BindsKeyboard.Command(returnKey: true, picked: code, bound: bound) {
        case .rebind(let action): edit(.init(action: action))
        case .bind: edit(.init(action: nil, startKey: layer.sublayer.map { Key(keyCode: code, modifiers: $0.modifiers) }))
        case .clear, nil: break
        }
    }
}

// MARK: - Inspector

/// The picked key (the mockup's inspector): a bound one's picture, name and where it comes from, its keys large, its
/// route, today's presses, where else it shows, its clash and the bind under it, then Change key, Unbind and Reset; a free
/// one says so and offers a bind. Under both, the tab's free keys and the key on every tab.
struct InstrumentBindsInspector: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let binds: HomeBinds
    let key: Int64?
    let layer: BindsKeyboard.Layer
    let boards: KeyboardCaptions.Boards
    let clashes: [SymbolicHotKeys.Clash]
    let refusal: String?
    let acts: BindsKeyboardPage.Acts
    let shape: Shape

    /// Two columns (stacked on a page 600 pt wide), or one.
    enum Shape { case columns, column }

    var body: some View {
        Group {
            switch shape {
            case .columns:
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) { picked }.frame(maxWidth: .infinity, alignment: .topLeading)
                    InstrumentRule(vertical: true)
                    VStack(alignment: .leading, spacing: 0) { free; InstrumentRule(); everyLayer }.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .fixedSize(horizontal: false, vertical: true)
            case .column: column
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .styleSurface(\.card)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            picked
            InstrumentRule()
            free
            InstrumentRule()
            everyLayer
        }
    }

    // MARK: The picked key

    @ViewBuilder private var picked: some View {
        if let key, let action = binds.bound[key]?.first, binds.infos[action] != nil {
            bound(key, action: action)
        } else if let key {
            freeKey(key)
        }
    }

    private func bound(_ key: Int64, action: String) -> some View {
        let info = binds.infos[action]
        let module = binds.module(action)
        let store = engine.binds.store
        let today = engine.today.count(of: action, now: .now)
        let more = (binds.bound[key] ?? []).dropFirst().compactMap { binds.infos[$0]?.label }
        let clash = clashes.first { $0.action == action }?.hotkey.name
        let warning = BindsKeyboardPage.warning(for: action, store: store)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    picture(action)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info?.label ?? action).styleText(\.pageTitle).foregroundStyle(style.color(\.text)).fixedSize(horizontal: false, vertical: true)
                        Text("\(BindsKeyboard.modules[module]) · \(store.isCustom(action) ? "bound by you" : "\(store.preset.title) default")")
                            .styleText(\.caption).foregroundStyle(style.color(\.text3))
                    }
                }
                caps(key, action: action)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 18)
            InstrumentRule()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                fact("Route") { Text(action).styleText(\.mono).foregroundStyle(style.color(\.text2)).textSelection(.enabled) }
                fact("Used") { Text("\(today) today").styleText(\.caption).foregroundStyle(style.color(\.text)).monospacedDigit() }
                fact("Also in") { Text("Launcher › \(BindsKeyboard.modules[module])").styleText(\.caption).foregroundStyle(style.color(\.text)) }
                if !more.isEmpty { fact("And") { Text(more.joined(separator: ", ")).styleText(\.caption).foregroundStyle(style.color(\.text)) } }
                fact("Conflicts") {
                    Text(clash.map { "macOS: \($0)" } ?? warning ?? "None").styleText(\.caption)
                        .foregroundStyle(style.color(clash != nil || warning != nil ? \.accentText : \.text2))
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            HStack(spacing: 8) {
                // Return and Delete do the same while the board has the keyboard (BindsKeyboardPage.boardKeys).
                Button { acts.edit(.init(action: action)) } label: { signed("Change key", "↵") }.buttonStyle(InstrumentButtonStyle())
                Button { acts.clear(action) } label: { signed("Unbind", "⌫") }.buttonStyle(InstrumentButtonStyle(kind: .ghost))
                Spacer(minLength: 0)
                if store.isCustom(action) {
                    Button { acts.reset(action) } label: { Image(systemName: "arrow.counterclockwise").font(style.font(\.icon)) }
                        .buttonStyle(InstrumentButtonStyle(kind: .ghost))
                        .help("Back to the \(store.preset.title) default").accessibilityLabel("Reset to default")
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 18)
            if let refusal { Text(refusal).styleText(\.caption).foregroundStyle(style.color(\.accentText)).padding(.horizontal, 20).padding(.bottom, 14) }
        }
    }

    /// A button's words with the key that does the same after them.
    private func signed(_ title: String, _ sign: String) -> some View {
        HStack(spacing: 7) { Text(title); InstrumentKey(text: sign) }
    }

    private func fact(_ label: String, @ViewBuilder _ value: () -> some View) -> some View {
        GridRow {
            Text(label).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize()
            value().fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func freeKey(_ key: Int64) -> some View {
        let name = boards.full.caption(key)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free key").styleText(\.pageTitle).foregroundStyle(style.color(\.text))
                    Text(layer.sublayer.map { "Nothing on \($0.title)+\(name) yet." } ?? "No plain combo on \(name) yet.")
                        .styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                }
                caps(key)
                Button { acts.edit(.init(action: nil, startKey: layer.sublayer.map { Key(keyCode: key, modifiers: $0.modifiers) })) } label: {
                    signed("Bind something", "↵")
                }
                .buttonStyle(InstrumentButtonStyle(kind: .primary))
            }
            .padding(20)
        }
    }

    /// The bind's picture at 40 pt: the app's own icon, else its glyph on the raised fill.
    @ViewBuilder private func picture(_ action: String) -> some View {
        switch binds.glyph(action) {
        case .image(let image): Image(nsImage: image).resizable().interpolation(.high).frame(width: 40, height: 40).accessibilityHidden(true)
        case .symbol(let symbol):
            Image(systemName: symbol).font(style.font(\.title)).foregroundStyle(style.color(\.text2))
                .frame(width: 40, height: 40)
                .background(style.color(\.raised), in: .rect(cornerRadius: style.radii.control, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: style.radii.control, style: .continuous).strokeBorder(style.color(\.line2)) }
                .accessibilityHidden(true)
        }
    }

    /// The bind's keys, large: the layer key filled in the signal colour with its name, the tab's modifiers, the key; a
    /// plain combo its own.
    private func caps(_ key: Int64, action: String? = nil) -> some View {
        let parts = BindsKeyboardPage.capParts(key, action: action, layer: layer, store: engine.binds.store, board: boards.full)
        return HStack(spacing: 6) {
            if layer != .plain {
                InstrumentBigKey(text: "Hyper", symbol: "capslock", hyper: true)
                Text("+").styleText(\.caption).foregroundStyle(style.color(\.text3))
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Text("+").styleText(\.caption).foregroundStyle(style.color(\.text3)) }
                InstrumentBigKey(text: part)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(((layer == .plain ? [] : ["Hyper"]) + parts).joined(separator: " plus "))
    }

    // MARK: Free keys and every layer

    private var free: some View {
        let runs = BindsKeyboard.free(on: boards.compact, bound: binds.bound)
        let left = runs.reduce(0) { $0 + $1.codes.count }
        return VStack(alignment: .leading, spacing: 10) {
            InstrumentEyebrow(text: "Free on \(InstrumentBindsPage.title(layer)) · \(left)")
            Flow(spacing: 5, lineSpacing: 5) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    let on = run.codes.contains { $0 == key }
                    Button { run.codes.first.map(acts.pick) } label: {
                        InstrumentLegend(text: run.label).foregroundStyle(style.color(on ? \.accentText : \.text2)).fixedSize()
                            .padding(.horizontal, 7).frame(minWidth: 26, minHeight: 26)
                            .overlay {
                                RoundedRectangle(cornerRadius: style.radii.chip + 1, style: .continuous)
                                    .strokeBorder(style.color(on ? \.accentLine : \.line2))
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(run.label): free")
                }
            }
            Text("Double-click any key to open its bind. Press one while \(engine.settings.layerKeys.label) is held to pick it.")
                .styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    /// The picked key on every tab: what each puts on it, a click showing that tab with the key picked.
    @ViewBuilder private var everyLayer: some View {
        if let key {
            let onKey = engine.binds.store.binds.filter { $0.key.keyCode == key }
            VStack(alignment: .leading, spacing: 4) {
                InstrumentEyebrow(text: "\(boards.full.caption(key)) on every tab").padding(.leading, 8).padding(.bottom, 6)
                ForEach(BindsKeyboard.Layer.allCases, id: \.self) { other in
                    let action = onKey.filter { other.tab.holds($0.key) }.map(\.value).sorted().first
                    let on = other == layer
                    Button { acts.show(other, key) } label: {
                        HStack(spacing: 10) {
                            Text(InstrumentBindsPage.title(other)).styleText(\.caption).foregroundStyle(style.color(\.text3))
                                .frame(width: 84, alignment: .leading)
                            Text(action.map { binds.infos[$0]?.label ?? $0 } ?? "free").styleText(\.caption)
                                .foregroundStyle(style.color(action == nil ? \.text3 : \.text)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .instrumentRaised(on)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            // The rows' raised pick reaches 8 pt past the text, which sits at the 20 pt every section's does.
            .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 14)
        }
    }
}

/// One key of the inspector's bind, 30 pt high (the mockup's `.bigkey b`): the layer key filled in the signal colour.
private struct InstrumentBigKey: View {
    @Environment(\.style) private var style
    let text: String
    var symbol: String?
    var hyper = false

    var body: some View {
        let label = HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(style.font(\.key)).accessibilityHidden(true) }
            Text(text).styleText(\.mono)
        }
        .foregroundStyle(style.color(hyper ? \.onAccent : \.text))
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 10).frame(minWidth: 30, minHeight: 30)
        if hyper {
            label.background(style.color(\.accent), in: .rect(cornerRadius: style.radii.key, style: .continuous))
        } else {
            label.styleSurface(\.boardKey, fill: \.key, radius: \.key)
        }
    }
}

/// `main` with `side` beside it, 20 pt apart, `side` pinned in sight as the page scrolls (InstrumentBindsPage.pin): the
/// column under the inspector beside a long table never shows an empty band.
private struct PinnedBeside<Main: View, Side: View>: View {
    @ViewBuilder let main: Main
    @ViewBuilder let side: Side
    @State private var height: CGFloat = 0
    /// The inspector's offset, in whole points: set only when it moves, not on every frame the page scrolls.
    @State private var pin: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            main
            side
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .offset(y: pin)
        }
        .onGeometryChange(for: CGFloat.self) { [height] proxy in
            let column = proxy.frame(in: .scrollView)
            return InstrumentBindsPage.pin(columnTop: column.minY, column: column.height, inspector: height, inset: InstrumentBindsPage.pinInset).rounded()
        } action: { pin = $0 }
    }
}
