import AppKit
import PilotCore
import SwiftUI

// The Hyper+Space menu's parts both layouts draw (menu Rail and Classic, T6): the search line, the bars over the list,
// what shows under them (an extension's detail, a scan's wait, the empty line or the rows), the rows, Cmd+K's actions
// and the foot. InstrumentMenu (Classic) and RailMenu compose them; the navigator, keys and rows are one model.

/// The bars over the list: the Files view's filters at a root search, Stickers and GIFs' GIFs | Stickers.
struct MenuBars: View {
    @Bindable var model: MenuModel

    var body: some View {
        if model.searchingRoot && model.nav.inFiles {
            FileFilterBar(model: model).padding(.horizontal, 18).padding(.vertical, 8).overlay(alignment: .bottom) { InstrumentRule() }
        }
        if model.showsGiphyBar {
            GiphyKindBar(model: model).padding(.horizontal, 18).padding(.vertical, 8).overlay(alignment: .bottom) { InstrumentRule() }
        }
    }
}

/// What the menu shows under its search line: an extension's detail, a list still being read, the empty line, or the rows
/// under their headings, with Cmd+K's actions over the list's corner.
struct MenuBody: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel
    let pointer: PointerTrack
    var actionsFocused: FocusState<Bool>.Binding
    /// The list's own width, which a narrow list's Cmd+K spans whole.
    let width: CGFloat
    /// A row's height when the layout sets its own (Line's 36 pt, MenuPanelSize.lineRow); Instrument's otherwise.
    var rowHeight: CGFloat?
    /// The first nine rows wear their ⌘ number (Line, outside the Files view).
    var numbered = false

    private var nav: MenuNavigator { model.nav }

    var body: some View {
        Group {
            if let detail = nav.shownDetail {
                ExtensionDetailView(detail: detail, act: model.runDetail).overlay(alignment: .bottomTrailing) { rowActions }
            } else if let scan = model.scan {
                // At its own height, which the panel takes (MenuModel.instrumentSize), so no band shows under it.
                InstrumentScan(scan: scan, tools: model.tools)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { model.waitHeight = $0 }
            } else if model.showsStats {
                // Stats' cards, which list no rows (Q400).
                MenuStatsScreen { model.open(.activity) }
            } else if model.showsAbout {
                // About's mark and cards, which list no rows (Q443).
                MenuAboutScreen(displays: NSScreen.screens.count)
            } else if model.showsDefine {
                // The word's rows and its entry beside them, whatever it holds (Q596, layout C).
                DefinePane(model: model).overlay(alignment: .bottomTrailing) { rowActions }
            } else if model.hasLineChips, nav.branch == .translate {
                // Its text and translation side by side, whatever it holds (P40).
                TranslatePanes(model: model).overlay(alignment: .bottomTrailing) { rowActions }
            } else if nav.rows.isEmpty {
                empty
            } else if model.hasLineChips, nav.branch == .emoji {
                EmojiGridView(model: model, pointer: pointer).overlay(alignment: .bottomTrailing) { rowActions }
            } else {
                list.overlay(alignment: .bottomTrailing) { rowActions }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var rowActions: some View {
        MenuRowActions(model: model, pointer: pointer, focused: actionsFocused, width: width)
    }

    /// A window row's tile on its workspace's glyph; nil for any other row, or a window the menu did not list.
    private func tile(of row: MenuEntry) -> CGRect? {
        if case .window(let id) = row.target { InstrumentWindowGlyph.tile(of: id, in: model.windows) } else { nil }
    }

    /// A window row's window as the menu listed it; nil for any other row.
    private func window(of row: MenuEntry) -> AeroWindow? {
        if case .window(let id) = row.target { model.windows.first { $0.id == id } } else { nil }
    }

    private var list: some View {
        let rows = nav.rows, headings = model.headings, pointing = model.pointedRows(pointer)
        // System's switches follow where Sven is, not the panel's shape: the Rail draws System wide (Moody, T6).
        let (quiet, system, searching) = (model.quiet, model.inSystem, model.searchingRoot)
        // Only a typed search has a best match: a kind Tab lists whole before typing has none (T1's carry-over).
        let typed = searching && !nav.query.isEmpty
        // A list whose rows would all wear one glyph (Kill a process, a repo picker) wears none: it would say nothing. The
        // icon column goes too when no row has a picture of its own to keep it.
        let shared = InstrumentRowIcon.shared(rows)
        let bare = shared != nil && rows.allSatisfy { InstrumentRowIcon.glyph($0) == shared }
        let height = rowHeight ?? (quiet ? MenuPanelSize.instrumentRow : MenuPanelSize.instrumentWideRow)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Typing stats (P42): the Mac's readings above the rows, never a row itself.
                    if model.statsCards { StatsStrip { model.open($0.page == .stats ? .stats : .activity) } }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        // One view per row with its heading, so scrolling to a row brings its heading too.
                        // An answer that copies a result draws as its card in the top slot, the same row (T7).
                        let card = model.answerCard(row, at: index)
                        VStack(alignment: .leading, spacing: 0) {
                            if let heading = card?.eyebrow ?? headings[index]?.title(goTo: true) {
                                InstrumentEyebrow(text: heading)
                                    .padding(.horizontal, 12).padding(.bottom, 6)
                                    .frame(maxWidth: .infinity, minHeight: MenuPanelSize.instrumentHeading, alignment: .bottomLeading)
                            }
                            if let card {
                                AnswerCard(answer: card, on: index == nav.selection).pointerRow(pointing, index)
                            } else {
                                InstrumentMenuRow(row: row, on: index == nav.selection, quiet: quiet, system: system,
                                                  best: typed && index == 0, query: nav.query, alias: nav.alias(of: row),
                                                  layerKeys: model.layerKeys, tile: tile(of: row), window: window(of: row), bare: bare, hidden: shared,
                                                  height: height, number: numbered && index < 9 ? index + 1 : nil)
                                    .pointerRow(pointing, index)
                            }
                        }
                    }
                    if model.noMatch { noMatch }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .scrollsToSelection(pointing) { _, _ in if let id = nav.selected?.id { proxy.scrollTo(id) } }
        }
        // While Cmd+K's actions show over it, the list waits for them (MenuView's reason).
        .allowsHitTesting(nav.actions == nil)
    }

    /// A root search that found nothing but its offers (Ask AI, Search the web, Search files, Search to install): says so
    /// under those rows, and what Return does on the first.
    private var noMatch: some View {
        VStack(spacing: 4) {
            Text("Nothing else matches “\(nav.query)”").styleText(\.strong).foregroundStyle(style.color(\.text))
            Text("Return asks your AI; ↓ searches the web, your files or packages to install.").styleText(\.caption).foregroundStyle(style.color(\.text3))
        }
        .lineLimit(1).truncationMode(.middle).multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: MenuModel.noMatchRoom)
    }

    /// Nothing to list: the first sentence as the line, the rest under it, centred in the list's room under a glyph
    /// that says why (a spinner while a list is read).
    private var empty: some View {
        let text = model.emptyText
        let cut = text.range(of: ". ")
        return VStack(spacing: 6) {
            if model.reading {
                ProgressView().controlSize(.small).padding(.bottom, 4)
            } else {
                Image(systemName: nav.branch.map(InstrumentRowIcon.glyph(of:)) ?? "magnifyingglass").font(style.font(\.search))
                    .foregroundStyle(style.color(\.text3)).padding(.bottom, 4).accessibilityHidden(true)
            }
            Text(cut.map { String(text[..<$0.lowerBound]) + "." } ?? text).styleText(\.strong).foregroundStyle(style.color(\.text))
            if let cut { Text(text[cut.upperBound...]).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
        }
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Cmd+K's actions over the list's corner, on its inset, never over the search line or the foot; across a narrow list
/// whole, so no sliver of a row shows beside it.
struct MenuRowActions: View {
    @Bindable var model: MenuModel
    let pointer: PointerTrack
    var focused: FocusState<Bool>.Binding
    let width: CGFloat

    var body: some View {
        if let actions = model.nav.actions {
            InstrumentRowActions(menu: actions, width: model.quiet ? width - 16 : nil, filter: $model.nav.actionQuery,
                                 focused: focused, pointing: model.pointedActions(pointer), tile: tile(of: actions.row))
                .padding(8)
        }
    }

    private func tile(of row: MenuEntry) -> CGRect? {
        if case .window(let id) = row.target { InstrumentWindowGlyph.tile(of: id, in: model.windows) } else { nil }
    }
}

// MARK: - Search line

/// The search line: Pilot's mark, or inside a branch its crumb; what is typed in the search face, the caret in the
/// signal colour; at a root search how many rows it found (or a kind listed whole holds) and, in Classic, the kinds Tab
/// steps through; a picker's title.
struct InstrumentMenuSearch: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel
    var focused: FocusState<Bool>.Binding
    /// Tab's kinds at the line's right (Classic); the Rail keeps them in its rail.
    var kinds = true

    var body: some View {
        let nav = model.nav
        HStack(spacing: 12) {
            if let branch = nav.path.last, !nav.isList {
                InstrumentCrumb(symbol: InstrumentRowIcon.glyph(of: branch), text: branch.title)
            } else {
                InstrumentMark(size: 18).foregroundStyle(style.color(\.text2))
            }
            ZStack(alignment: .leading) {
                if nav.query.isEmpty {
                    Text(model.prompt).styleText(\.search).foregroundStyle(style.color(\.text3)).lineLimit(1).allowsHitTesting(false)
                }
                TextField("", text: $model.nav.query).textFieldStyle(.plain).styleText(\.search)
                    .foregroundStyle(style.color(\.text)).tint(style.color(\.accent)).focused(focused)
                    .accessibilityLabel(model.prompt)
            }
            Spacer(minLength: 8)
            if model.searchingRoot {
                if let count = model.resultCount {
                    Text(count).styleText(\.mono).foregroundStyle(style.color(\.text3)).fixedSize()
                }
                if kinds { kindTabs }
            }
            if let title = nav.title { InstrumentCrumb(text: title) }
        }
        .padding(.horizontal, 18).frame(height: 58)
        .overlay(alignment: .bottom) { InstrumentRule() }
    }

    /// Tab's kinds on a sunk track, the shown one raised; a click shows a kind as Tab reaching it does.
    private var kindTabs: some View {
        InstrumentSegments(options: MenuEntry.Kind.tabOrder.map { ($0, MenuModel.title(of: $0)) },
                           selection: Binding(get: { model.nav.only }, set: { kind in withAnimation(nil) { model.nav.show(kind) } }),
                           height: 22, role: \.caption, ink: \.text3)
            .lineLimit(1).fixedSize()
            .accessibilityLabel("Showing \(model.nav.only.map { $0.rawValue + "s" } ?? "all kinds"); Tab for the next kind")
    }
}

// MARK: - Rows

/// One row (menu.html's .r): its icon, its title with what was typed underlined, its alias, what it belongs to muted
/// after it; at the right a place, a version or a count in mono, the running dot, its keys (the Hyper one in the signal
/// colour), a System switch, a file's day and a branch's chevron. A quiet list's rows stay bare but for the current one,
/// as MenuRow's do. The current row is raised on a hairline ring with a 2 pt tick in the signal colour in the list's
/// inset.
struct InstrumentMenuRow: View {
    @Environment(\.style) private var style
    let row: MenuEntry
    let on: Bool
    let quiet: Bool
    let system: Bool
    /// The best match of a root search, which says its kind first.
    let best: Bool
    let query: String
    let alias: String?
    let layerKeys: [LayerKey]
    let tile: CGRect?
    /// A window row's window: its title alone, its app beside the workspace (menu.html's window rows).
    let window: AeroWindow?
    /// Drawn without an icon column (a list whose rows all share one glyph).
    var bare = false
    /// The glyph every glyph row of the list shares, which none draws.
    var hidden: String?
    let height: CGFloat
    /// Its ⌘ number in Line (⌘1 to ⌘9 run the first nine rows, menu-morph T3); nil elsewhere.
    var number: Int?

    var body: some View {
        let file = row.kind == .file
        // A row that repeats the search (Search files for "…", Search to install "…", an answer) underlines nothing.
        let echoes = row.isAnswer || row.isOffer
        // A window's workspace glyph is not its app's icon, so Title only leaves it (story 154).
        let shows = row.appShows
        HStack(spacing: 12) {
            if !bare, shows.icon || tile != nil { InstrumentRowIcon(row: row, on: on, tile: tile, hidden: hidden) }
            if shows.title {
                Text(Self.marked(title, echoes ? "" : query, line: style.color(\.text3))).styleText(\.row)
                    .foregroundStyle(style.color(\.text)).layoutPriority(1)
            }
            if let alias { InstrumentKey(text: alias) }
            if !quiet || on, let meta {
                // A window's app and workspace stay whole: a long title gives way to them (test row 2.3).
                Text(meta).styleText(file ? \.mono : \.caption).foregroundStyle(style.color(\.text3)).truncationMode(.middle)
                    .fixedSize(horizontal: row.kind == .window, vertical: false)
            }
            Spacer(minLength: 8)
            trailing
        }
        .lineLimit(1)
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .appTip(title, when: !shows.title)
        // The signal's tick inside the raised fill, as the window's sidebar marks its page.
        .instrumentPicked(on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// An emoji's row draws the emoji as its icon, so its title is the name alone.
    private var title: String {
        if case .emoji(let e) = row.target, row.title.hasPrefix(e) { return row.title.dropFirst(e.count).trimmingCharacters(in: .whitespaces) }
        if let window, !window.title.isEmpty { return window.title }
        return row.shownTitle
    }

    /// The muted words after the title: the best match's kind (a window's glyph says it), then what the row belongs to
    /// (a window's app and workspace, an action's app, a file's folder).
    private var meta: String? {
        if case .window = row.target {
            return window.map { "\($0.appName) · workspace \($0.workspace)" } ?? row.detail
        }
        let words = [best ? row.kindWord : nil, row.subtitle].compactMap(\.self)
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    @ViewBuilder private var trailing: some View {
        let file = row.kind == .file, window = { if case .window = row.target { true } else { false } }()
        if quiet {
            let words = [row.hint, row.detailIsKey ? "" : row.detail ?? ""].filter { !$0.isEmpty }
            if on, !words.isEmpty { Text(words.joined(separator: " · ")).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
            if on, row.detailIsKey, let detail = row.detail { InstrumentBindKeys(label: detail, layerKeys: layerKeys) }
        } else {
            if let detail = row.detail, !row.detailIsKey, !file, !window {
                // Numbers, versions, paths and commands in mono (NOTES: every changing number is a readout); words in the
                // caption face.
                // A detail with a summary (Update all's command) shows the summary, the detail whole in its tooltip.
                let shown = row.short ?? detail
                let readout = shown.contains(where: \.isNumber) || shown.contains("/") || shown.contains("&&")
                Text(shown).styleText(readout ? \.mono : \.caption).foregroundStyle(style.color(readout ? \.text2 : \.text3))
                    .truncationMode(.middle).help(detail)
            }
            if row.running {
                Circle().fill(style.color(\.text3)).frame(width: 5, height: 5).accessibilityLabel("running")
            }
            if let detail = row.detail, row.detailIsKey, on || !system { InstrumentBindKeys(label: detail, layerKeys: layerKeys) }
        }
        if system, let isOn = row.isOn {
            InstrumentSwitchFace(isOn: isOn, lit: false).accessibilityElement().accessibilityLabel(isOn ? "on" : "off")
        }
        if file, let day = row.detail { Text(day).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
        if !quiet || on, row.kind == .branch {
            Image(systemName: "chevron.right").font(style.font(\.small)).foregroundStyle(style.color(on ? \.text2 : \.text3))
                .accessibilityHidden(true)
        }
        if let number {
            Text("⌘\(number)").styleText(\.mono).foregroundStyle(style.color(\.text3)).frame(minWidth: 26, alignment: .trailing)
                .accessibilityLabel("command \(number)")
        }
    }

    /// `title` with each typed word's first match underlined in a hairline of `line` (menu.html's mark).
    static func marked(_ title: String, _ query: String, line: Color) -> AttributedString {
        var text = AttributedString(title)
        for word in query.split(whereSeparator: \.isWhitespace) {
            guard let found = title.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]),
                  let range = Range(found, in: text) else { continue }
            text[range].underlineStyle = Text.LineStyle(pattern: .solid, color: line)
        }
        return text
    }
}

/// A row's icon in a 22 pt box: an app's own (an app's action with a badge saying what it does), a file's, a window as
/// its workspace with its tile lit, an emoji itself; any other row its line glyph, which the row's colour draws.
struct InstrumentRowIcon: View {
    @Environment(\.style) private var style
    let row: MenuEntry
    let on: Bool
    let tile: CGRect?
    /// A glyph not drawn, as every glyph row of the list wears it.
    var hidden: String?
    var side: CGFloat = 22

    var body: some View {
        Group {
            if let tile {
                InstrumentWindowGlyph(tile: tile, on: on)
            } else if case .emoji(let e) = row.target {
                Text(e).styleText(\.search)
            } else {
                if case .icon(let image, let badge)? = Self.art(row) {
                    let icon = ArtImage(image: image).frame(width: side, height: side)
                    if let badge { icon.modifier(InstrumentBadge(symbol: badge)) } else { icon }
                } else if let symbol = Self.glyph(row) ?? (row.kind == .app ? MenuIcon.app.symbol : nil), symbol != hidden {
                    // An app whose icon the Mac lacks still says it is an app.
                    Image(systemName: symbol).font(style.font(\.icon)).foregroundStyle(style.color(on ? \.text : \.text2))
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

extension InstrumentRowIcon {
    /// The row's art (MenuEntry.art), with a branch's glyph as Instrument draws it unless the row brings its own icon
    /// (Remove's and Update's categories).
    @MainActor static func art(_ row: MenuEntry) -> MenuEntry.Art? {
        if case .branch(let b) = row.target, row.icon == nil { return .symbol(glyph(of: b), .module(b.look.colour)) }
        return row.art(tiled: false)
    }

    /// The one glyph every row of `rows` that wears a glyph would wear, when at least two do; nil once two differ.
    @MainActor static func shared(_ rows: [MenuEntry]) -> String? {
        var shared: String?, count = 0
        for row in rows {
            guard let g = glyph(row) else { continue }
            if let shared, shared != g { return nil }
            shared = g
            count += 1
        }
        return count > 1 ? shared : nil
    }

    /// The line glyph a row would wear; nil for one wearing a picture (an app's, a file's, a window's, an emoji).
    @MainActor static func glyph(_ row: MenuEntry) -> String? {
        if case .window = row.target { return nil }
        switch art(row) {
        case .tile(let symbol, _)?, .symbol(let symbol, _)?: return symbol
        default: return nil
        }
    }

    /// A branch's glyph: its own, but where two rows of one list differ by colour alone, which Instrument's one ink
    /// cannot tell apart (Trigger's Emoji picker and Stickers and GIFs), a glyph of its own.
    static func glyph(of branch: MenuBranch) -> String { branch == .stickers ? "photo.on.rectangle.angled" : branch.look.symbol }
}

/// An app's action's badge: the action's glyph on a raised chip at the icon's foot, cut out of the icon by a hairline gap.
private struct InstrumentBadge: ViewModifier {
    @Environment(\.style) private var style
    let symbol: String

    func body(content: Content) -> some View {
        let side: CGFloat = 13, gap: CGFloat = 1.5, out: CGFloat = 3
        let radius = style.radii.chip - 1
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .mask(alignment: .bottomTrailing) {
                ZStack(alignment: .bottomTrailing) {
                    Rectangle()
                    RoundedRectangle(cornerRadius: radius + gap, style: .continuous)
                        .frame(width: side + 2 * gap, height: side + 2 * gap)
                        .offset(x: out + gap, y: out + gap).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: symbol).font(style.font(\.small)).imageScale(.small).foregroundStyle(style.color(\.text))
                    .frame(width: side, height: side)
                    .background(style.color(\.raised), in: shape)
                    .overlay { shape.strokeBorder(style.color(\.line2)) }
                    .offset(x: out, y: out)
            }
    }
}

/// A window as a tiny workspace with its tile lit (mockup A's NOTES), so two windows of one app wear different icons.
struct InstrumentWindowGlyph: View {
    @Environment(\.style) private var style
    /// The window's share of its workspace, 0 to 1 each way.
    let tile: CGRect
    let on: Bool

    var body: some View {
        let inner = CGSize(width: 18, height: 11), radius = style.radii.chip - 1
        RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(style.color(on ? \.text2 : \.text3), lineWidth: 1.25)
            .frame(width: inner.width + 4, height: inner.height + 4)
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: radius / 2, style: .continuous).fill(style.color(\.text))
                    .frame(width: tile.width * inner.width - 1, height: tile.height * inner.height - 1)
                    .offset(x: 2 + tile.minX * inner.width, y: 2 + tile.minY * inner.height)
            }
    }

    /// Where window `id` sits on its workspace, as Home's map lays the tiled windows out (three a row, or one a row when
    /// the tiler stacks them), a floating one in the middle; nil when `windows` lacks it.
    static func tile(of id: Int, in windows: [AeroWindow]) -> CGRect? {
        guard let window = windows.first(where: { $0.id == id }) else { return nil }
        if window.isFloating { return CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6) }
        let tiled = windows.filter { $0.workspace == window.workspace && !$0.isFloating }
        let rows = tiled.layoutRows
        for (r, row) in rows.enumerated() {
            guard let c = row.firstIndex(where: { $0.id == id }) else { continue }
            let w = 1 / CGFloat(row.count), h = 1 / CGFloat(rows.count)
            return CGRect(x: CGFloat(c) * w, y: CGFloat(r) * h, width: w, height: h)
        }
        return nil
    }
}

/// A bind's keys as chips from its label ("Hyper+Shift+T"): the layer key's sign in the signal colour, each modifier
/// its sign, then the key.
struct InstrumentBindKeys: View {
    let label: String
    let layerKeys: [LayerKey]

    var body: some View {
        let caps = Self.caps(label, layerKeys: layerKeys)
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { InstrumentKey(text: $1.text, hyper: $1.hyper) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.replacingOccurrences(of: "+", with: " "))
    }

    /// Each part of the label as a cap: Hyper the layer key's sign, a modifier its sign (a side spelled out before it),
    /// Return, Escape, Delete and Space as Home's keys show them.
    static func caps(_ label: String, layerKeys: [LayerKey]) -> [(text: String, hyper: Bool)] {
        let signs = ["Shift": "⇧", "Ctrl": "⌃", "Alt": "⌥", "Cmd": "⌘", "Return": "↵", "Escape": "Esc", "Delete": "⌫"]
        return label.split(separator: "+").map { part in
            if part == "Hyper" { return (layerKeys.symbol, true) }
            let words = part.split(separator: " ")
            if words.count == 2, let sign = signs[String(words[1])] { return (String(words[0].prefix(1)) + sign, false) }
            return (signs[String(part)] ?? String(part), false)
        }
    }
}

// MARK: - Cmd+K

/// Cmd+K's actions on the current row over the list's corner (RowActionsPopover's rules): the row's icon and name, its
/// actions in groups split by hairlines (the ones that remove or quit by force in the problem colour), ↵ on the current
/// one, the filter at the foot. On the style's pop face, so it floats over the list.
private struct InstrumentRowActions: View {
    @Environment(\.style) private var style
    let menu: RowActionsMenu
    var width: CGFloat?
    @Binding var filter: String
    var focused: FocusState<Bool>.Binding
    let pointing: PointerList
    let tile: CGRect?
    @State private var cut = Cut()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                InstrumentRowIcon(row: menu.row, on: false, tile: tile, side: 16)
                Text(menu.row.shownTitle).styleText(\.caption).foregroundStyle(style.color(\.text3))
            }
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ViewThatFits(in: .vertical) {
                    actions
                    ScrollView { Cut.ends { actions } }.scrollIndicators(.never)
                        .onScrollGeometryChange(for: Cut.self, of: Cut.init) { cut = $1 }
                        .mask { Cut.Fade(cut: cut) }
                        .overlay(alignment: .top) { if cut.above { arrow("chevron.compact.up") } }
                        .overlay(alignment: .bottom) { if cut.below { arrow("chevron.compact.down") } }
                }
                .scrollsToSelection(pointing) { Cut.scroll(proxy, from: $0, to: $1, in: menu.visible) }
            }
            InstrumentRule()
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease").font(style.font(\.icon)).foregroundStyle(style.color(\.text3))
                    .accessibilityHidden(true)
                TextField("Filter actions…", text: $filter, prompt: Text("Filter actions…").foregroundStyle(style.color(\.text3)))
                    .textFieldStyle(.plain).styleText(\.body).foregroundStyle(style.color(\.text)).focused(focused)
            }
            .padding(.horizontal, 12).frame(height: 38)
        }
        .frame(width: width ?? 300)
        .styleSurface(\.pop, fill: \.panel, radius: \.card)
        .onAppear { focused.wrappedValue = true }
        .onChange(of: menu.query) { cut = Cut() }
    }

    private func arrow(_ symbol: String) -> some View {
        Image(systemName: symbol).font(style.font(\.icon)).foregroundStyle(style.color(\.text3))
            .frame(maxWidth: .infinity).frame(height: Cut.strip).allowsHitTesting(false).accessibilityHidden(true)
    }

    private var actions: some View { RowActionsList(menu: menu, pointing: pointing) }
}

/// Cmd+K's actions for one row: each with its glyph, a hairline between groups, the current one raised with ↵; a
/// filter that matches none says so. The popover (InstrumentRowActions) and Line's in-place list (LineActions) draw it.
struct RowActionsList: View {
    @Environment(\.style) private var style
    let menu: RowActionsMenu
    let pointing: PointerList

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if menu.visible.isEmpty {
                let all = menu.total
                VStack(spacing: 3) {
                    Text("No action called “\(menu.query)”").styleText(\.strong).foregroundStyle(style.color(\.text))
                    Text("\(menu.row.shownTitle) has \(all) action\(all == 1 ? "" : "s"); clear the filter to see them.")
                        .styleText(\.caption).foregroundStyle(style.color(\.text3))
                }
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.vertical, 18)
            }
            ForEach(Array(menu.visible.enumerated()), id: \.element) { index, action in
                VStack(alignment: .leading, spacing: 0) {
                    if index > 0, action.group != menu.visible[index - 1].group {
                        InstrumentRule().padding(.horizontal, 6).padding(.vertical, 4)
                    }
                    InstrumentActionRow(action: action, row: menu.row, on: index == menu.selection)
                        .pointerRow(pointing, index)
                }
            }
        }
        .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 6)
    }
}

/// One Cmd+K action: its glyph, its title, ↵ on the current one, raised on a hairline ring.
struct InstrumentActionRow: View {
    @Environment(\.style) private var style
    let action: RowActionsMenu.Choice
    let row: MenuEntry
    let on: Bool

    var body: some View {
        let ink: KeyPath<StyleColors, Paint> = action.danger ? \.problem : \.text
        HStack(spacing: 10) {
            Image(systemName: action.instrumentSymbol(on: row)).font(style.font(\.icon)).frame(width: 18)
                .foregroundStyle(style.color(on || action.danger ? ink : \.text3)).accessibilityHidden(true)
            Text(action.title).styleText(\.body).foregroundStyle(style.color(ink))
            Spacer(minLength: 8)
            if let key = action.key(on: row) { InstrumentKey(text: key) }
            if on { InstrumentKey(text: "↵") }
        }
        .lineLimit(1)
        .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .instrumentRaised(on)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Foot

/// The foot (menu.html's .foot): Pilot's mark and where Sven is ("Pilot › Search"), then what the keys do, each word
/// before its keys, what Return does set brighter. Short of room the place gives way to the mark; the keys never do.
struct InstrumentMenuFoot: View {
    @Environment(\.style) private var style
    let model: MenuModel

    var body: some View {
        InstrumentFoot(hints: model.footer + model.footerTrailing + model.footerCommands, note: model.footerNote) {
            Text("Pilot").foregroundStyle(style.color(\.text2))
            ForEach(Array(crumbs.enumerated()), id: \.offset) { _, crumb in
                Text("›").foregroundStyle(style.color(\.text3))
                Text(crumb).foregroundStyle(style.color(\.text3))
            }
        }
    }

    /// Where Sven is after "Pilot": a root search (and the kind Tab picked), the branches down to this one, a picker.
    private var crumbs: [String] {
        let nav = model.nav
        if nav.isList { return ["Pick"] }
        if model.searchingRoot { return ["Search"] + (nav.only == nil ? [] : [MenuModel.title(of: nav.only)]) }
        return nav.path.map(\.title)
    }
}

// MARK: - Scan

/// A list still being read (MenuScan: Clean, Update, Remove, Install): the wait with a spinner over its live line, the
/// three steps from here with the running one marked "now" in the signal colour (live), then what the list can hold.
private struct InstrumentScan: View {
    @Environment(\.style) private var style
    let scan: MenuScan
    let tools: Set<String>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scan.heading).styleText(\.strong).foregroundStyle(style.color(\.text))
                    Text(scan.line).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 14)
            ForEach(Array(scan.steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 12) {
                    Image(systemName: step.icon.symbol).font(style.font(\.icon)).frame(width: 22)
                        .foregroundStyle(style.color(index == 0 ? \.text : \.text2)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).styleText(\.strong).foregroundStyle(style.color(index == 0 ? \.text : \.text2))
                        Text(step.detail).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(index == 0 ? "now" : "next").styleText(\.key).foregroundStyle(style.color(index == 0 ? \.accentText : \.text3))
                }
                .padding(.vertical, 10)
                .overlay(alignment: .top) { if index > 0 { InstrumentRule() } }
            }
            InstrumentEyebrow(text: "What the list can hold").padding(.top, 16).padding(.bottom, 10)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(scan.kinds(on: tools), id: \.title) { kind in
                    HStack(spacing: 8) {
                        Image(systemName: kind.icon.symbol).font(style.font(\.icon))
                            .foregroundStyle(style.color(\.text3)).frame(width: 18).accessibilityHidden(true)
                        Text(kind.title).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension RowActionsMenu.Choice {
    /// Instrument's glyph: an extension row's own action draws its own symbol.
    func instrumentSymbol(on row: MenuEntry) -> String {
        if case .row(let action) = self { action.instrumentSymbol(on: row) } else { symbol(on: row) }
    }
}

extension RowAction {
    /// The action's glyph in Instrument: each copy its own, as one ink cannot tell two copies apart by
    /// their colour (Moody vzACUY1p1lU).
    func instrumentSymbol(on row: MenuEntry) -> String {
        switch self {
        case .copyBundleID: "number"
        case .copyID: "number.square"
        case .copyTitle: "textformat"
        default: symbol(on: row)
        }
    }
}
