import AppKit
import PilotCore
import SwiftUI

/// Binds in Instrument (mockup A's binds.html, card agent-bo-95423181, ADR 0008; simplify-pages T14): the page's bar with
/// the six tabs and their counts, Conflicts while there is a clash, List, the preset and New bind; the keyboard in one
/// piece (Sven's Q36) on its panel with the modules under it (each picks what the board lights) and how to see the
/// overlay; and the picked key's inspector: what it does, its route, today's presses, where else it shows, its clash,
/// Change key, Unbind and Reset, the tab's free keys and the key on every tab; then Swap keys and what the overlay shows
/// (pages round 4). The binds as a table are List's; Cleaning is on More. Every act is BindsKeyboardPage's own (`Acts`), as Toybox's page uses them, so picking, binding, clearing,
/// presets and the list behave as in Toybox. Over 1100 pt the inspector stands beside the board while the board there
/// holds every name whole, else under a board across the page, in two columns while it is 600 pt wide. The page
/// scrolls; nothing in it scrolls on its own.
struct InstrumentBindsPage: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let binds: HomeBinds
    let key: Int64?
    @Binding var layer: BindsKeyboard.Layer
    let boards: KeyboardCaptions.Boards
    let refusal: String?
    let acts: BindsKeyboardPage.Acts
    /// The blocks under the board and its inspector (Swap keys and the overlay, pages round 4).
    var below: AnyView? = nil
    /// The module the board lights; nil for all six.
    @State var module: Int?
    @State private var width: CGFloat = 0
    @State private var clashes: [SymbolicHotKeys.Clash] = []

    /// The width from which the inspector may stand beside the board, and its own.
    static let beside: CGFloat = 1100, inspector: CGFloat = 272

    /// Where the inspector stands: beside the board, or under a board across the page.
    enum Arrangement { case beside, under }

    /// The arrangement on a page `width` wide and the board's keys' width in it: from 1100 pt the inspector beside the
    /// board while every name fits the narrower board there, a little smaller at most, else under it.
    @MainActor static func arrangement(_ width: CGFloat, marks: InstrumentBoardFit.Marks, boards: KeyboardCaptions.Boards,
                                       style: StyleTokens) -> (Arrangement, board: CGFloat) {
        let across = width - 2 * side(width, style) - 2 * inset(width)
        guard width >= beside else { return (.under, across) }
        let narrower = across - inspector - 20
        // Beside while the narrower board holds every name, a little smaller at most; the board is drawn whole either way.
        let rooms = InstrumentBoardFit.rooms(marks, on: boards.compact, width: narrower)
        return InstrumentBoardFit.fits(rooms, measure: InstrumentBoardFit.measure(style.type.keyName), scale: InstrumentBoardFit.gentle)
            ? (.beside, narrower) : (.under, across)
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

    /// A tab's name in the bar: Hyper, Shift, Ctrl, Alt, Shift Ctrl, Without Hyper.
    static func title(_ tab: BindsKeyboard.Layer) -> String {
        tab == .plain ? AppSection.plainCombos.title : tab == .hyper ? "Hyper" : String(tab.title.dropFirst(2))
    }

    /// The single modifiers' line signs, as the mockup's tabs wear them.
    static let signs: [BindsKeyboard.Layer: String] = [.shift: "shift", .ctrl: "control", .alt: "option"]

    /// The bar's buttons with their words, or, on a page too narrow for them (760 pt, one type step up), Conflicts as its
    /// glyph, so the title and New bind keep their place.
    private var fittedControls: some View {
        ViewThatFits(in: .horizontal) {
            controls(compact: false)
            controls(compact: true)
        }
    }

    private func controls(compact: Bool) -> some View {
        let store = engine.binds.store
        return HStack(spacing: 8) {
            // Abilities, Overlay and Mouse have one home each: Launcher › Abilities and Keys' own tabs (simplify-pages T2).
            // macOS shortcuts on a plain combo, and Pilot's defaults another action's key left without one.
            // Conflicts only while there is a clash (simplify-pages T14).
            let count = clashes.count + store.refused.count
            if count > 0 {
                Button { acts.go(AppPlace(.conflicts)) } label: {
                    HStack(spacing: 6) {
                        barLabel("Conflicts", symbol: "exclamationmark.triangle", compact: compact)
                        Text("\(count)").styleText(\.key).foregroundStyle(style.color(\.text3))
                    }
                }
                .accessibilityLabel("Conflicts, \(count)")
                .buttonStyle(InstrumentButtonStyle(kind: .raised))
                .help("macOS shortcuts that clash with your binds without Hyper, and actions whose default key another holds")
            }
            // Every bind of the tab as a list (the table the page drew until simplify-pages T14).
            Button(action: acts.showList) { barLabel("List", symbol: "list.bullet", compact: compact) }
                .buttonStyle(InstrumentButtonStyle()).help("Every bind as a list, to search and filter")
            Menu {
                PresetPicker(presets: store.presets, active: store.preset, pick: acts.switchTo)
                PresetMenuItems()
                Divider()
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
        if compact { Image(systemName: symbol).font(style.font(\.icon)).accessibilityLabel(title) } else { Text(title) }
    }

    // MARK: Layouts

    /// The board, the inspector beside it; the page scrolls when either runs past the window's foot, so nothing in the
    /// inspector is cut. The binds as a table are the List button's (simplify-pages T14).
    private func beside(_ marks: InstrumentBoardFit.Marks) -> some View {
        FillScroll {
            VStack(spacing: 0) {
                PinnedBeside {
                    keyboard(marks).frame(maxWidth: .infinity, alignment: .top)
                } side: {
                    sideInspector
                }
                .padding(.horizontal, Self.side(width, style)).padding(.vertical, Self.pinInset)
                below?.padding(.horizontal, Self.side(width, style)).padding(.bottom, Self.pinInset)
            }
        }
    }

    /// The page's top and foot inset, which the pinned inspector keeps under the window's top as the page scrolls.
    static let pinInset: CGFloat = 20

    /// How far down its column the inspector rides (Moody, batch 3: beside the long table, gone with simplify-pages T14,
    /// the column under it was a dead band): at its place while its column's top (`columnTop`, in the scroll view's space) is below the page's `inset`,
    /// then held `inset` under the window's top, never past the column's foot.
    static func pin(columnTop: CGFloat, column: CGFloat, inspector: CGFloat, inset: CGFloat) -> CGFloat {
        min(max(0, inset - columnTop), max(0, column - inspector))
    }

    /// The inspector in one column beside the board, as tall as what it says.
    private var sideInspector: some View {
        InstrumentBindsInspector(binds: binds, key: key, layer: layer, boards: boards, clashes: clashes, refusal: refusal, acts: acts,
                                 shape: .column)
            .frame(width: Self.inspector)
    }

    /// The board across the page, the inspector under it (in two columns while it is 600 pt wide), the page scrolling.
    private func under(_ marks: InstrumentBoardFit.Marks) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                keyboard(marks)
                InstrumentBindsInspector(binds: binds, key: key, layer: layer, boards: boards, clashes: clashes, refusal: refusal, acts: acts,
                                         shape: width - 2 * Self.side(width, style) >= 600 ? .columns : .column)
                below
            }
            .padding(.horizontal, Self.side(width, style)).padding(.vertical, 20)
        }
    }

    // MARK: Keyboard

    private func keyboard(_ marks: InstrumentBoardFit.Marks) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // In one piece, its names shrinking where the 75 % board is tight (Sven's Q36).
            InstrumentBindsBoard(boards: boards, binds: binds, layerKeys: engine.settings.layerKeys, layer: layer, picked: key, marks: marks,
                                 module: module, pick: acts.pick, open: { acts.open($0, bound: binds.bound, layer: layer) }, whole: true,
                                 tinted: true)
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
