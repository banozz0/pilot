import AppKit
import PilotCore
import SwiftUI

/// The Hyper+Space menu as the Rail draws it (menu Rail and Classic, direction B, frames B1–B3, B7, B8; look.menuLayout's
/// other choice, Classic the default since Q134): the search line, rows and foot (MenuParts) with Tab's kinds moved out of
/// the search line into a rail on the left, each with its count while Sven types, and under a Go to eyebrow the root's
/// branches in his order and Clipboard ↗. The panel is 750 wide everywhere (Q130). At the empty root the rail's branches
/// are the navigator's own rows, so the arrows, Return and → walk them as they walk today's root, with Recent and Waiting
/// beside them; a search or a kind Tab shows puts the list beside the rail; inside a branch or on an answer the rail folds
/// to a strip of icons. A picker draws no rail.
/// Only the drawing changes: the navigator, keys and rows are the one model.
struct RailMenu: View {
    @Bindable var model: MenuModel
    let pointer: PointerTrack
    var searchFocused: FocusState<Bool>.Binding
    var actionsFocused: FocusState<Bool>.Binding

    var body: some View {
        let size = model.instrumentSize, band = model.railBand
        let rail = Self.width(band), list = size.width - rail - (band == .none ? 0 : 1)
        VStack(spacing: 0) {
            InstrumentMenuSearch(model: model, focused: searchFocused, kinds: band == .none)
            HStack(spacing: 0) {
                if band != .none {
                    MenuRail(model: model, pointer: pointer, band: band)
                        .frame(width: rail).frame(maxHeight: .infinity, alignment: .top)
                        .modifier(RailGround())
                    InstrumentRule(vertical: true)
                }
                VStack(spacing: 0) {
                    if band == .root {
                        RailRecent(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .overlay(alignment: .bottomTrailing) {
                                MenuRowActions(model: model, pointer: pointer, focused: actionsFocused, width: list)
                            }
                    } else {
                        MenuBars(model: model)
                        MenuBody(model: model, pointer: pointer, actionsFocused: actionsFocused, width: list)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            InstrumentMenuFoot(model: model)
        }
        .frame(width: size.width, height: size.height)
        // Typing or a branch leaves the root: the arrows are back on the rows when it returns.
        .onChange(of: band) { model.railCursor = nil }
    }

    static func width(_ band: MenuPanelSize.RailBand) -> CGFloat {
        switch band {
        case .none: 0
        case .root: MenuPanelSize.railRootWidth
        case .full: MenuPanelSize.railWidth
        case .slim: MenuPanelSize.railSlimWidth
        }
    }
}

// MARK: - The rail

/// The rail's ground: the theme's sidebar colour, at the sidebar layer's strength while the whole face is on Glass
/// (Q356; it was the rail's own glass, notes › Rail: Glass, until Glass reached the face).
private struct RailGround: ViewModifier {
    @Environment(\.style) private var style

    func body(content: Content) -> some View { content.background(style.color(\.sidebar)) }
}

/// The rail on the theme's sidebar colour: the kinds, then Go to's branches and Clipboard ↗; or, slim, their icons. It
/// scrolls when it is taller than the panel, a fade at the cut edge.
private struct MenuRail: View {
    @Bindable var model: MenuModel
    let pointer: PointerTrack
    let band: MenuPanelSize.RailBand
    @State private var cut = Cut()

    private var nav: MenuNavigator { model.nav }

    var body: some View {
        let pointing = model.pointedRows(pointer)
        ScrollViewReader { proxy in
            following(pointing, proxy) {
                ScrollView {
                    Cut.ends {
                        if band == .slim { strip } else { rail(pointing) }
                    }
                }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: Cut.self, of: Cut.init) { cut = $1 }
                .mask { Cut.Fade(cut: cut) }
            }
        }
        .allowsHitTesting(nav.actions == nil)
    }

    /// Only at the root, where the rail draws the navigator's rows and no list does, the rail keeps the current row in
    /// view as the arrows move it. Elsewhere the list watches the rows alone: two watchers would each clear the pointer's
    /// mark (scrollsToSelection), so a hover could scroll the list (Moody, T6).
    @ViewBuilder private func following(_ pointing: PointerList, _ proxy: ScrollViewProxy, @ViewBuilder _ content: () -> some View) -> some View {
        if band == .root {
            content().scrollsToSelection(pointing) { _, _ in if let id = nav.selected?.id { proxy.scrollTo(id) } }
                // The pointer on a branch takes the arrows' place from a kind; ↑ onto a kind brings it into view.
                .onChange(of: nav.selection) { model.railCursor = nil }
                .onChange(of: model.railCursor) { _, new in if let new { proxy.scrollTo(Self.kindID(new)) } }
        } else {
            content()
        }
    }

    private func rail(_ pointing: PointerList) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(MenuEntry.Kind.tabOrder.enumerated()), id: \.offset) { index, kind in
                let count = band == .full ? Self.count(of: kind, model) : nil
                // At the root the arrows reach the kinds too (Q119): the one they are on is raised.
                let on = band == .root ? model.railCursor == index : model.searchingRoot && nav.only == kind
                RailRow(glyph: Self.glyph(of: kind), title: MenuModel.title(of: kind), count: count, zero: count == "0", on: on)
                    .onTapGesture { model.show(kind) }
                    .accessibilityHint("Shows \(MenuModel.title(of: kind).lowercased()); Tab steps the kinds")
                    .id(Self.kindID(index))
            }
            InstrumentEyebrow(text: "Go to")
                .padding(.horizontal, 9).padding(.bottom, 5)
                .frame(maxWidth: .infinity, minHeight: MenuPanelSize.railHeading, alignment: .bottomLeading)
            if band == .root {
                // The root's rows are the root's branches: the rail draws them, so the keys move through them here.
                ForEach(Array(nav.rows.enumerated()), id: \.element.id) { index, row in
                    RailRow(glyph: Self.glyph(of: row), title: row.shownTitle, on: index == nav.selection && model.railCursor == nil)
                        .pointerRow(pointing, index)
                        .id(row.id)
                }
            } else {
                ForEach(model.goTo, id: \.self) { branch in
                    RailRow(glyph: InstrumentRowIcon.glyph(of: branch), title: branch.title, on: false)
                        .onTapGesture { model.open(branch) }
                }
            }
            RailRow(glyph: Self.clipboardGlyph, title: MenuModel.clipboard.title, opens: true, on: false)
                .onTapGesture { model.run(MenuModel.clipboard) }
                .accessibilityLabel("Clipboard, opens its own panel")
        }
        .padding(MenuPanelSize.railInset)
    }

    /// Slim: back to the search, then each Go to branch with the one Sven is in raised, then Clipboard.
    private var strip: some View {
        VStack(spacing: 2) {
            RailIcon(glyph: "magnifyingglass", label: "Search", on: false) { model.open(nil) }
            ForEach(model.goTo, id: \.self) { branch in
                RailIcon(glyph: InstrumentRowIcon.glyph(of: branch), label: branch.title, on: nav.path.first == branch) { model.open(branch) }
            }
            RailIcon(glyph: Self.clipboardGlyph, label: "Clipboard, opens its own panel", on: false) { model.run(MenuModel.clipboard) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MenuPanelSize.railInset)
    }

    static let clipboardGlyph = "doc.on.clipboard"
    static func kindID(_ index: Int) -> String { "rail-kind-\(index)" }

    /// A kind's count at the root (Menu.count(of:)): All's is what the typed search found; blank where the navigator
    /// counts nothing (files under All, files and packages before a search).
    @MainActor static func count(of kind: MenuEntry.Kind?, _ model: MenuModel) -> String? {
        guard let kind else {
            guard !model.nav.query.isEmpty else { return nil }
            return String(model.nav.rows.count { !$0.isOffer })
        }
        return model.nav.count(of: kind).map(String.init)
    }

    /// A kind's line glyph (the mockup's search, grid, window, file, zap and package).
    static func glyph(of kind: MenuEntry.Kind?) -> String {
        switch kind {
        case nil: "magnifyingglass"
        case .app?: "square.grid.2x2"
        case .window?: "macwindow"
        case .file?: "doc"
        case .action?: "bolt"
        case .package?: "shippingbox"
        default: "circle"
        }
    }

    /// A root row's glyph: its branch's, as Instrument draws it.
    @MainActor static func glyph(of row: MenuEntry) -> String {
        if case .branch(let branch) = row.target { return InstrumentRowIcon.glyph(of: branch) }
        return InstrumentRowIcon.glyph(row) ?? "circle"
    }
}

/// One rail row, 30 pt: its glyph, its name, its count right-aligned in mono or ↗ for a row that opens its own panel. The
/// shown kind or the current row is raised with the signal's tick, its count in the signal's text colour. A kind at zero
/// stays readable (notes › Contrast: 4.5:1 on the rail, since Tab lands on it).
private struct RailRow: View {
    @Environment(\.style) private var style
    let glyph: String
    let title: String
    var count: String?
    var zero = false
    var opens = false
    let on: Bool

    var body: some View {
        let quiet = RailInk.quiet(style)
        HStack(spacing: 9) {
            Image(systemName: glyph).font(style.font(\.icon)).frame(width: 18)
                .foregroundStyle(style.color(on ? \.text : zero ? quiet : \.text3)).accessibilityHidden(true)
            Text(title).styleText(\.body).foregroundStyle(style.color(on ? \.text : zero ? quiet : \.text2))
            Spacer(minLength: 6)
            if let count {
                Text(count).styleText(\.mono).monospacedDigit().foregroundStyle(style.color(on ? \.accentText : quiet))
            }
            if opens {
                Image(systemName: "arrow.up.right").font(style.font(\.small)).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: MenuPanelSize.railRow, maxHeight: MenuPanelSize.railRow, alignment: .leading)
        .contentShape(.rect)
        .instrumentPicked(on)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// One icon of the slim strip, 36 by 32, raised with the tick where Sven is.
private struct RailIcon: View {
    @Environment(\.style) private var style
    let glyph: String
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        // A tap, never a Button: nothing in the panel may take the keyboard from the search field.
        Image(systemName: glyph).font(style.font(\.icon)).foregroundStyle(style.color(on ? \.text : \.text3))
            .frame(width: 36, height: MenuPanelSize.railSlimRow)
            .contentShape(.rect)
            .instrumentPicked(on)
            .onTapGesture(perform: action)
            .help(label)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

enum RailInk {
    /// The quiet colour of an idle count and a kind at zero: the third text where it reads at 4.5:1 on the rail's
    /// sidebar colour, else the second (notes › Contrast).
    static func quiet(_ style: StyleTokens) -> KeyPath<StyleColors, Paint> {
        Contrast.ratio(style.colors.text3.rgb, style.colors.sidebar.rgb) >= 4.5 ? \.text3 : \.text2
    }
}

// MARK: - The rail's keys

extension MenuModel {
    /// ↑ and ↓ at the Rail's root walk the whole rail (Sven, Q119): ↑ on Go to's first branch climbs into the kinds
    /// (Packages up to All), ↓ on Packages comes back down to the branches; on a kind Return or → shows it as a click or
    /// Tab does. True when the key was the rail's; anywhere but the Rail's root, or with Cmd+K's actions open, the
    /// navigator has every key and the kinds let go.
    func railKey(_ key: MenuNavigator.Key) -> Bool {
        guard railBand == .root, nav.actions == nil else {
            railCursor = nil
            return false
        }
        let kinds = MenuEntry.Kind.tabOrder
        switch (key, railCursor) {
        case (.up, nil) where nav.selection == 0 && !kinds.isEmpty: railCursor = kinds.count - 1
        case (.up, let i?): railCursor = max(i - 1, 0)
        case (.down, let i?): railCursor = i + 1 < kinds.count ? i + 1 : nil
        case (.return, let i?), (.right, let i?):
            // All is what the root already shows: the cursor stays on it.
            guard let kind = kinds[i] else { break }
            railCursor = nil
            show(kind)
        // On a kind there is no row for Cmd+K or Space to act on.
        case (.commandK, _?), (.space, _?): break
        case (_, nil): return false
        default:
            // Tab, Escape, ←: the navigator's, as from a branch.
            railCursor = nil
            return false
        }
        return true
    }
}

// MARK: - The root's Recent

/// Beside the root's rail: the entries picked last, each a click from running as Return on it would (before any pick, a
/// line that says what will show here); then Waiting, Update's count and Clean's size, each a click from its branch.
private struct RailRecent: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InstrumentEyebrow(text: "Recent")
                .padding(.horizontal, 12).padding(.bottom, 6)
                .frame(maxWidth: .infinity, minHeight: MenuPanelSize.instrumentHeading, alignment: .bottomLeading)
            if model.recent.isEmpty {
                Text("What you open from the menu shows up here.")
                    .styleText(\.caption).foregroundStyle(style.color(\.text3))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.top, 2)
            }
            ForEach(model.recent, id: \.id) { row in
                recentRow(row)
            }
            if !model.waiting.isEmpty {
                InstrumentEyebrow(text: "Waiting")
                    .padding(.horizontal, 12).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, minHeight: MenuPanelSize.instrumentHeading, alignment: .bottomLeading)
                // A tap opens the branch, as Return on it in the rail does.
                ForEach(model.waiting, id: \.id) { row in
                    recentRow(row) { if case .branch(let branch) = row.target { model.open(branch) } }
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .allowsHitTesting(model.nav.actions == nil)
    }

    /// One row beside the rail; a tap runs it as Return on it would, or does `tap`.
    private func recentRow(_ row: MenuEntry, tap: (() -> Void)? = nil) -> some View {
        // A tap, never a Button, as the rail's rows: the search field keeps the keyboard.
        InstrumentMenuRow(row: row, on: false, quiet: false, system: false, best: false, query: "", alias: model.nav.alias(of: row),
                          layerKeys: model.layerKeys, tile: nil, window: nil, height: MenuPanelSize.instrumentRow)
            .contentShape(.rect)
            .onTapGesture { if let tap { tap() } else { model.run(row) } }
            .accessibilityAddTraits(.isButton)
    }
}
