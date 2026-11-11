import PilotCore
import SwiftUI

/// Binds in Toybox (card agent-bo-95423182, mockup B binds.html; simplify-pages T14): the title with the tab's count and
/// how to press it, My binds or Omarchy, Find (the list) and Add bind; the six tabs as chips with their counts beside the
/// module legend; the keyboard in its case, in one piece (Sven's Q36); then the picked key, the tab's binds by module, and
/// its free keys with the macOS clashes while there are any. Cleaning is on More. Every act is BindsKeyboardPage's own
/// (`BindsKeyboardPage.Acts`), so picking, binding, clearing, presets, Find and the tabs behave as in Instrument.
struct ToyBindsPage: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let binds: HomeBinds
    let key: Int64?
    @Binding var layer: BindsKeyboard.Layer
    let boards: KeyboardCaptions.Boards
    let refusal: String?
    let acts: BindsKeyboardPage.Acts
    /// The blocks under the board's lower half (Swap keys and the overlay, pages round 4).
    var below: AnyView? = nil
    @State private var width: CGFloat = 1364
    @State private var clashes = 0

    /// The page's side margin on a page `width` wide.
    static func side(_ width: CGFloat) -> CGFloat { width >= 1000 ? 32 : 20 }

    var body: some View {
        let side = Self.side(width)
        // How many binds each tab holds, read once a pass.
        let counts = Dictionary(uniqueKeysWithValues: BindsKeyboard.Layer.allCases.map { tab in
            (tab, BindsKeyboard.bound(store: engine.binds.store, layer: tab).values.reduce(0) { $0 + $1.count })
        })
        FillScroll {
            VStack(alignment: .leading, spacing: 14) {
                header(count: counts[layer] ?? 0)
                chips(counts)
                ToyBindsBoard(boards: boards, binds: binds, layerKeys: engine.settings.layerKeys, layer: layer, picked: key, pick: acts.pick,
                              open: { acts.open($0, bound: binds.bound, layer: layer) }, whole: true)
                lower(width - 2 * side)
                below
                if let refusal {
                    Label(refusal, systemImage: "exclamationmark.triangle.fill").font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2))
                        .symbolRenderingMode(.multicolor)
                }
            }
            .padding(.horizontal, side).padding(.top, 18).padding(.bottom, 18)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(style.color(\.canvas))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // ShortcutConflicts' clash count, read once per change of the binds, as the window's Conflicts count is.
        .task(id: engine.binds.store.binds) { clashes = ShortcutConflicts.shared.clashes(binds: engine.binds.store.binds).count }
    }

    // MARK: Title and tabs

    /// The title and its line, then the preset, Find, Add bind and the rest of the old My binds menu; the controls drop
    /// under the title when the page is narrow.
    private func header(count: Int) -> some View {
        let name = Text("Binds").styleText(\.pageTitle).tracking(-0.5).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
        let summary = layer.summary(count: count, layerKeys: engine.settings.layerKeys)
        let line = Text(summary).font(style.toyNunito(700, 14)).foregroundStyle(style.color(\.text2))
        let title = HStack(alignment: .firstTextBaseline, spacing: 14) { name; line.lineLimit(1) }.fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { title; Spacer(minLength: 12); controls() }
            VStack(alignment: .leading, spacing: 14) { title; controls() }
            VStack(alignment: .leading, spacing: 10) {
                name
                line.fixedSize(horizontal: false, vertical: true)
                controls().padding(.top, 4)
            }
            // The least window, one type step up (C3): Find as its glyph.
            VStack(alignment: .leading, spacing: 10) {
                name
                line.fixedSize(horizontal: false, vertical: true)
                controls(compact: true).padding(.top, 4)
            }
        }
    }

    private func controls(compact: Bool = false) -> some View {
        HStack(spacing: 10) {
            ToySegments(selection: Binding(get: { engine.binds.store.preset }, set: { if $0 != engine.binds.store.preset { acts.switchTo($0) } }),
                        options: engine.binds.store.presets.map { ($0, $0.title) }, label: "Layout")
            PresetMoreMenu()
            Button(action: acts.showList) { barLabel("Find", "magnifyingglass", compact) }.buttonStyle(.pilot).help("Find")
            // Abilities, Overlay and Mouse have one home each: Launcher › Abilities and Keys' own tabs (simplify-pages T2).
            Button { acts.edit(.init(action: nil)) } label: { Label("Add bind", systemImage: "plus") }.buttonStyle(.pilotPrimary)
            Menu {
                Button("Import or export binds…") { acts.go(AppPlace(.exportImport)) }
                Button("Save keyboard map…") { BindsMapSave.run(engine: engine) }
                Divider()
                Button("Reset all to defaults…", role: .destructive, action: acts.resetAll)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15 * style.scale, weight: .heavy)).foregroundStyle(style.color(\.text))
                    .frame(width: style.points(40), height: style.points(34)).padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
                    .background(Toy.block(style, fill: style.color(\.raised), radius: style.radii.control, edge: 4))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More binds actions")
        }
        .fixedSize()
    }

    /// A bar button's words with its glyph, or the glyph alone (its title stays its accessibility label).
    @ViewBuilder private func barLabel(_ title: String, _ symbol: String, _ compact: Bool) -> some View {
        if compact { Label(title, systemImage: symbol).labelStyle(.iconOnly) } else { Label(title, systemImage: symbol) }
    }

    /// The six tabs as chips with their counts, the picked one sun; the module legend beside them, or under them.
    private func chips(_ counts: [BindsKeyboard.Layer: Int]) -> some View {
        let tabs = ForEach(BindsKeyboard.Layer.allCases, id: \.self) { tab in
            ToyLayerChip(title: tab.title, count: counts[tab] ?? 0, hyper: tab == .hyper, on: layer == tab) { layer = tab }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { HStack(spacing: 8) { tabs }.fixedSize(); Spacer(minLength: 12); legend(0..<6) }
            VStack(alignment: .leading, spacing: 12) { HStack(spacing: 8) { tabs }.fixedSize(); legend(0..<6) }
            VStack(alignment: .leading, spacing: 12) {
                Flow(spacing: 8, lineSpacing: 8) { tabs }
                VStack(alignment: .leading, spacing: 8) { legend(0..<3); legend(3..<6) }
            }
        }
    }

    private func legend(_ modules: Range<Int>) -> some View {
        HStack(spacing: 14) {
            ForEach(modules, id: \.self) { i in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Toy.module(i, style))
                        .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(style.color(\.outline), lineWidth: 2) }
                        .frame(width: 14, height: 14)
                    Text(BindsKeyboard.modules[i]).font(style.toyNunito(800, 12.5)).foregroundStyle(style.color(\.text2))
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    // MARK: The cards under the board

    /// Selected, By module and Free keys side by side as the mockup's 1.15 : 1 : 1; under 1100 pt Selected over the other
    /// two, under 760 pt all three stacked.
    @ViewBuilder private func lower(_ width: CGFloat) -> some View {
        let gap: CGFloat = 18
        if width >= 1100 {
            let unit = (width - 2 * gap) / 3.15
            // To the window's foot, the three one height.
            HStack(alignment: .top, spacing: gap) {
                selected(unit * 1.15).frame(width: unit * 1.15)
                byModule
                freeKeys
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else if width >= 740 {
            VStack(spacing: gap) {
                selected(width)
                HStack(alignment: .top, spacing: gap) { byModule; freeKeys }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: gap) { selected(width); byModule; freeKeys }.fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Selected

    /// The picked key, in a card `width` wide.
    @ViewBuilder private func selected(_ width: CGFloat) -> some View {
        ToyCard(title: "Selected") {
            if let key, let action = binds.bound[key]?.first {
                boundKey(key, action: action, beside: width - 2 * style.density.padding >= 400)
            } else if let key {
                freeKey(key)
            }
        }
    }

    /// `beside`: the action beside its keys, its id wrapping; else under them.
    private func boundKey(_ key: Int64, action: String, beside: Bool) -> some View {
        let info = binds.infos[action]
        let module = binds.module(action)
        let store = engine.binds.store
        let today = engine.today.count(of: action, now: .now)
        let more = (binds.bound[key] ?? []).dropFirst().compactMap { binds.infos[$0]?.label }
        return VStack(alignment: .leading, spacing: 14) {
            let layout = beside ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            layout { caps(key, action: action); what(action, label: info?.label ?? action, module: module) }
            Flow(spacing: 8, lineSpacing: 8) {
                ToyFact(text: "\(today) press\(today == 1 ? "" : "es") today")
                ToyFact(text: "Also in Launcher › \(BindsKeyboard.modules[module])")
                ToyFact(text: store.isCustom(action) ? "Your bind" : "\(store.preset.title) default")
                if !more.isEmpty { ToyFact(text: "And \(more.joined(separator: ", "))") }
                if let warning = BindsKeyboardPage.warning(for: action, store: store) { ToyFact(text: warning, warn: true) }
            }
            Spacer(minLength: 0)
            Flow(spacing: 10, lineSpacing: 10) {
                Button { acts.edit(.init(action: action)) } label: { Label("Change key", systemImage: "keyboard") }
                Button { acts.edit(.init(action: action)) } label: { Label("Edit action", systemImage: "pencil") }
                Button { acts.clear(action) } label: { Label("Remove", systemImage: "trash") }
            }
            .buttonStyle(.pilot)
        }
    }

    /// The action's picture, its name and its id.
    private func what(_ action: String, label: String, module: Int) -> some View {
        HStack(spacing: 14) {
            switch binds.glyph(action) {
            case .image(let image): Image(nsImage: image).resizable().interpolation(.high).frame(width: 44, height: 44).accessibilityHidden(true)
            case .symbol(let symbol): ToyTile(symbol: symbol, color: Toy.module(module, style), size: 40).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(style.toyFredoka(22)).foregroundStyle(style.color(\.text)).fixedSize(horizontal: false, vertical: true)
                Text(action).styleText(\.mono).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func freeKey(_ key: Int64) -> some View {
        let name = boards.full.caption(key)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                caps(key)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Free key").font(style.toyFredoka(22)).foregroundStyle(style.color(\.text))
                    Text(layer.sublayer.map { "Nothing on \($0.title)+\(name) yet." } ?? "No plain combo on \(name) yet.")
                        .font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button { acts.edit(.init(action: nil, startKey: layer.sublayer.map { Key(keyCode: key, modifiers: $0.modifiers) })) } label: {
                Label("Bind something", systemImage: "plus")
            }
            .buttonStyle(.pilotPrimary)
        }
    }

    /// The bind as big keycaps: Hyper, the tab's modifiers and the key; a plain combo's own keys.
    private func caps(_ key: Int64, action: String? = nil) -> some View {
        let parts = BindsKeyboardPage.capParts(key, action: action, layer: layer, store: engine.binds.store, board: boards.full)
        return ToyKeys(keys: parts, hyper: layer != .plain, plus: true, large: true).fixedSize()
    }

    // MARK: By module

    private var byModule: some View {
        var counts = Array(repeating: 0, count: BindsKeyboard.modules.count)
        for actions in binds.bound.values { for action in actions { counts[binds.module(action)] += 1 } }
        let total = counts.reduce(0, +)
        let off = binds.bound.filter { !boards.compact.codes.contains($0.key) }.values.reduce(0) { $0 + $1.count }
        return ToyCard(title: "By module") {
            Text("\(total) bound").font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2)).monospacedDigit()
        } content: {
            Grid(horizontalSpacing: 14, verticalSpacing: 9) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<2, id: \.self) { column in moduleRow(row * 2 + column, count: counts[row * 2 + column]) }
                    }
                }
            }
            if off > 0 {
                Spacer(minLength: 0)
                Button(action: acts.showList) {
                    Text("\(off) of them on keys off this board").font(style.toyNunito(800, 13)).foregroundStyle(style.color(\.accentText))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func moduleRow(_ module: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Toy.module(module, style))
                .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(style.color(\.outline), lineWidth: 2) }
                .frame(width: 18, height: 18)
            Text(BindsKeyboard.modules[module]).font(style.toyNunito(800, 13.5)).foregroundStyle(style.color(\.text)).lineLimit(1).fixedSize()
            Spacer(minLength: 6)
            Text("\(count)").font(style.toyFredoka(18)).foregroundStyle(style.color(\.text)).monospacedDigit()
        }
        .padding(.leading, 8).padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: 34)
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style.color(\.outline), lineWidth: 2) }
        .accessibilityElement(children: .combine)
    }

    // MARK: Free keys

    private var freeKeys: some View {
        let runs = BindsKeyboard.free(on: boards.compact, bound: binds.bound)
        let left = runs.reduce(0) { $0 + $1.codes.count }
        return ToyCard(title: "Free keys") {
            Text("\(left) left").font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2)).monospacedDigit()
        } content: {
            Flow(spacing: 7, lineSpacing: 7) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    Button { run.codes.first.map(acts.pick) } label: { ToyFreeCap(label: run.label, picked: run.codes.contains { $0 == key }) }
                        .buttonStyle(.kitPress)
                        .accessibilityLabel("\(run.label): free")
                }
            }
            // The clashes only while there are some (simplify-pages T14).
            if clashes > 0 {
                Spacer(minLength: 0)
                clashState
            }
        }
    }

    /// ShortcutConflicts' state: how many clashes, in the problem colour, with a way to them.
    private var clashState: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .black)).foregroundStyle(style.color(\.outline))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Toy.module(3, style)))
                .overlay { Circle().strokeBorder(style.color(\.outline), lineWidth: 2) }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(clashes) clash\(clashes == 1 ? "" : "es")").font(style.toyNunito(800, 13.5)).foregroundStyle(style.color(\.text))
                Text("with macOS shortcuts").font(style.toyNunito(700, 13.5)).foregroundStyle(style.color(\.text2))
            }
            Spacer(minLength: 8)
            Button("Show") { acts.go(AppPlace(.conflicts)) }.buttonStyle(ToyBindsButton(small: true))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Toy.moduleSoft(3, style), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(style.color(\.outline), lineWidth: 2) }
        .accessibilityElement(children: .combine)
    }
}

/// One tab as a chip (`.layer`): its name and count, Hyper's with its arrow, the picked one sun.
private struct ToyLayerChip: View {
    @Environment(\.style) private var style
    let title: String
    let count: Int
    let hyper: Bool
    let on: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                if hyper { Image(systemName: "arrowshape.up.fill").font(.system(size: 12, weight: .heavy)) }
                Text(title).font(style.toyNunito(800, 14))
                Text("\(count)").font(style.toyNunito(800, 11.5)).monospacedDigit()
                    .foregroundStyle(on ? style.color(\.onAccent).opacity(0.65) : style.color(\.text3))
            }
            .foregroundStyle(on ? style.color(\.onAccent) : style.color(\.text))
            .padding(.horizontal, 14).frame(height: 38 - 6)
            .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
            .background(Toy.block(style, fill: on ? style.color(\.accent) : style.color(\.panel), radius: style.radii.control, edge: style.depth.control.edge))
            .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .accessibilityLabel("\(title), \(count) binds")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A fact under the picked bind (`.fact`): a sunk chip, the warning's in the warn colour.
private struct ToyFact: View {
    @Environment(\.style) private var style
    let text: String
    var warn = false

    var body: some View {
        Text(text).font(style.toyNunito(800, 12.5)).foregroundStyle(style.color(\.text))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(warn ? style.color(\.accentSoft) : style.color(\.sunken), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.color(\.outline), lineWidth: 2) }
    }
}

/// A free key's cap (`.free .kc`): 32 pt, the free colour; the picked one ringed in sun.
private struct ToyFreeCap: View {
    @Environment(\.style) private var style
    let label: String
    let picked: Bool

    var body: some View {
        Text(label).font(style.toyNunito(800, 13)).foregroundStyle(style.color(\.text)).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).frame(minWidth: 32 - 4, minHeight: 32 - 6)
            .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
            .background(Toy.block(style, fill: style.color(\.keyFree), radius: style.radii.chip, edge: 4))
            .overlay { if picked { RoundedRectangle(cornerRadius: style.radii.chip + 3, style: .continuous).stroke(style.color(\.accent), lineWidth: 3).padding(-3) } }
    }
}

/// A Toybox button that is not the window's default size: small (`.btn.small`).
struct ToyBindsButton: ButtonStyle {
    var small = false
    func makeBody(configuration: Configuration) -> some View { ToyButtonFace(configuration: configuration, small: small) }
}
