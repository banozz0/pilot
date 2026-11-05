import AppKit
import PilotCore
import SwiftUI

/// The Hyper+Space menu as Classic draws it (menu Rail and Classic T8, frames D1–D8; look.menuLayout = classic), as Classic
/// Shell since Q139: Omarchy's menu drawn as a terminal pane. JetBrains Mono in every role on every theme, inside a 2 pt
/// frame in the theme's accent line, 750 wide as Raycast's (Q130); the default layout from Q134 until Line (Q165), whose
/// root it draws. A prompt line (❯ in the accent, a branch before it as a path); the root (as tall as its screen holds, T36) lists the
/// root's rows under `── go to`, 38 pt each, no recents (Sven 2026-10-20). A list is a ledger, 42 pt rows:
/// a 150 pt column with the key in capitals in the accent (HYPER + N, then →) or the place in a quiet colour (2 d ago,
/// ws 2, branch), the icon, the title and what it belongs to, under rule headings. The current row is a cursorline: a flat
/// band edge to edge with a 3 pt accent bar in the gutter, never a rounded pill. One status line at the foot holds the
/// mode, a root search's kinds with their counts and the keys. An answer draws its card at a 6 pt corner. The navigator,
/// keys and rows are the one model; Cmd+K, an extension's detail, a scan's wait and the empty line are MenuParts', in
/// Classic's face.
struct ClassicMenu: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel
    let pointer: PointerTrack
    var searchFocused: FocusState<Bool>.Binding
    var actionsFocused: FocusState<Bool>.Binding

    var body: some View {
        let size = model.instrumentSize, nav = model.nav
        VStack(spacing: 0) {
            ClassicSearch(model: model, focused: searchFocused)
            MenuBars(model: model)
            Group {
                if model.atRoot {
                    ClassicRoot(model: model, pointer: pointer).overlay(alignment: .bottomTrailing) { actions(size.width) }
                } else if nav.shownDetail == nil, model.scan == nil, !model.showsDefine, !nav.rows.isEmpty {
                    HStack(spacing: 0) {
                        ClassicList(model: model, pointer: pointer)
                        // The Files view previews the selected file (spec file-search-v2 T2).
                        if model.previewsFile {
                            InstrumentRule(vertical: true)
                            FilePreviewPane(path: nav.selected?.target.filePath).frame(width: FilePreviewPane.width)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) { actions(size.width) }
                } else {
                    MenuBody(model: model, pointer: pointer, actionsFocused: actionsFocused, width: size.width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            ClassicStatus(model: model)
        }
        .frame(width: size.width, height: size.height)
        // The frame, on the panel's own corner (PopSurface's), so no sliver of the face shows outside it.
        .overlay { RoundedRectangle(cornerRadius: style.radii.pop, style: .continuous).strokeBorder(style.color(\.accentLine), lineWidth: 2) }
        .style(Self.face(style))
    }

    private func actions(_ width: CGFloat) -> some View {
        MenuRowActions(model: model, pointer: pointer, focused: actionsFocused, width: width)
    }

    /// `tokens` with every role in JetBrains Mono (notes › Classic: Face), regular with keys and titles a weight up: the search
    /// at 18, a row at 16 (the root's) or 15, meta at 12.5; headings in lowercase, as Omarchy's. The sizes are as drawn: the mockups' are already a step up. Line
    /// icons stay the system's symbols.
    static func face(_ tokens: StyleTokens) -> StyleTokens {
        func mono(_ size: Double, _ weight: Int = 400, tracking: Double = 0) -> TypeRole {
            TypeRole(face: .bundled(StyleTokens.jetBrainsMono(weight)), size: size, tracking: tracking)
        }
        var type = tokens.type
        type.body = mono(13.5)
        type.strong = mono(13.5, 600)
        type.caption = mono(12.5)
        type.small = mono(11.5)
        type.title = mono(14, 600)
        type.pageTitle = mono(16, 600)
        type.display = mono(type.display.size, 500)
        type.mono = mono(12.5)
        type.eyebrow = mono(12.5)
        type.key = mono(11.5, 500)
        type.search = mono(18)
        type.row = mono(15, 500)
        type.keyName = mono(11.5, 500)
        type.barLabel = mono(11, 500)
        type.barStrong = mono(12.5, 600)
        type.barTime = mono(12.5, 500)
        return tokens.retyped(type)
    }

    /// The root's row face: 16 pt, a step over a list's.
    static let rootRow: Double = 16
}

// MARK: - Search line

/// The prompt line, 58 pt: ❯ in the accent, inside a branch its name before it as a path in the quiet colour (`apps ❯`),
/// what is typed at 18 pt with the caret in the accent; at its right only the menu's own key at the root, in capitals, or
/// a picker's title. What a search found and what an answer is live in the status line.
private struct ClassicSearch: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        let nav = model.nav
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                if let branch = nav.path.last, !nav.isList {
                    Text(branch.title.lowercased()).styleText(\.search).foregroundStyle(style.color(\.text3))
                }
                Text("❯").styleText(\.search).fontWeight(.bold).foregroundStyle(style.color(\.accent)).accessibilityHidden(true)
            }
            .fixedSize()
            ZStack(alignment: .leading) {
                if nav.query.isEmpty {
                    Text(prompt).styleText(\.search).foregroundStyle(style.color(\.text3)).lineLimit(1).allowsHitTesting(false)
                }
                TextField("", text: $model.nav.query).textFieldStyle(.plain).styleText(\.search)
                    .foregroundStyle(style.color(\.text)).tint(style.color(\.accent)).focused(focused)
                    .accessibilityLabel(prompt)
            }
            Spacer(minLength: 8)
            if let title = nav.title {
                InstrumentCrumb(text: title)
            } else if model.atRoot, let own = model.ownKey {
                Text(ClassicRowCaps.caps(own)).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1).fixedSize()
                    .accessibilityLabel("Opened with \(own)")
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 20).frame(height: 58)
        .overlay(alignment: .bottom) { InstrumentRule() }
    }

    /// "Go…" at the root, "Filter windows…" over a kind Tab lists whole, else the menu's own.
    private var prompt: String {
        if model.atRoot { return "Go…" }
        if model.searchingRoot, let only = model.nav.only { return "Filter \(MenuModel.title(of: only).lowercased())…" }
        return model.prompt
    }
}

// MARK: - Kinds

/// The kinds Tab steps through, as Classic's status line and Line's foot count them.
enum ClassicKinds {
    /// A kind's count (Menu.count(of:)): All's is what the typed search found; blank where the navigator counts nothing
    /// (files under All, files and packages before a search).
    @MainActor static func count(of kind: MenuEntry.Kind?, _ model: MenuModel) -> String? {
        guard let kind else {
            guard !model.nav.query.isEmpty else { return nil }
            return String(model.nav.rows.count { !$0.isOffer })
        }
        return model.nav.count(of: kind).map(String.init)
    }

    /// A kind at zero: the third text where it reads at 4.5:1 on the panel, else the second.
    static func quiet(_ style: StyleTokens) -> KeyPath<StyleColors, Paint> {
        Contrast.ratio(style.colors.text3.rgb, style.colors.panel.rgb) >= 4.5 ? \.text3 : \.text2
    }
}

// MARK: - Root

/// The root (frame D1): under `── go to`, the root's rows, the navigator's own, so the arrows, Return and → walk them;
/// no recents or pins over them (Sven 2026-10-20: a simple menu). Update and Clean say what waits in them. Line draws it
/// at its 36 pt rows (`row`).
struct ClassicRoot: View {
    @Bindable var model: MenuModel
    let pointer: PointerTrack
    var row: CGFloat = MenuPanelSize.classicRow

    var body: some View {
        let nav = model.nav, pointing = model.pointedRows(pointer)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ClassicHeading(title: "go to", height: MenuPanelSize.classicRootHeading)
                    ForEach(Array(nav.rows.enumerated()), id: \.element.id) { index, entry in
                        ClassicRootRow(row: entry, on: index == nav.selection, right: waiting(entry), height: row)
                            .pointerRow(pointing, index)
                            .id(entry.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .scrollsToSelection(pointing) { _, _ in if let id = nav.selected?.id { proxy.scrollTo(id) } }
        }
        .allowsHitTesting(nav.actions == nil)
    }

    /// What waits in a branch: Update's count, Clean's size (MenuModel.waiting).
    private func waiting(_ row: MenuEntry) -> String? {
        guard let detail = model.waiting.first(where: { $0.target == row.target })?.detail else { return nil }
        return row.target == .branch(.update) ? "\(detail) waiting" : detail
    }
}

/// A root row, 38 pt (Line's 36): its icon or glyph, its name at 16 pt, at its right `right`, in the accent when it is a
/// row's keys (`keyed`), else quiet (what waits in a branch, a window's workspace); current, the cursorline with its
/// glyph in the accent.
private struct ClassicRootRow: View {
    @Environment(\.style) private var style
    let row: MenuEntry
    let on: Bool
    let right: String?
    var keyed = false
    var height: CGFloat = MenuPanelSize.classicRow

    var body: some View {
        HStack(spacing: 12) {
            ClassicIcon(row: row, on: on)
            Text(row.shownTitle).font(style.font(\.row, size: ClassicMenu.rootRow / style.scale)).foregroundStyle(style.color(\.text))
            Spacer(minLength: 8)
            if let right {
                Text(right).styleText(\.caption).foregroundStyle(style.color(keyed ? \.accentText : \.text3))
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .cursorline(on)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A heading as a rule with its name in it, `── windows ─────────`: lowercase, in the quiet colour, a terminal's way of
/// dividing a list (Classic Shell, Q139).
struct ClassicHeading: View {
    @Environment(\.style) private var style
    let title: String
    var height: CGFloat = MenuPanelSize.instrumentHeading

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(style.color(\.line2)).frame(width: 12, height: 1)
            Text(title.lowercased()).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1).fixedSize()
            Rectangle().fill(style.color(\.line)).frame(height: 1)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Classic's current row: a flat band edge to edge in the raised colour with a 3 pt accent bar in the gutter, no corner,
    /// no inset: a terminal's current line, not a launcher's pill (Q139).
    func cursorline(_ on: Bool) -> some View { modifier(ClassicCursorline(on: on)) }
}

private struct ClassicCursorline: ViewModifier {
    @Environment(\.style) private var style
    let on: Bool

    func body(content: Content) -> some View {
        content
            .background(on ? style.color(\.raised) : .clear)
            .overlay(alignment: .leading) { if on { Rectangle().fill(style.color(\.accent)).frame(width: 3) } }
    }
}

/// A row's icon: an app's own, a window's tile, an emoji, or its line glyph in the accent while it is current.
private struct ClassicIcon: View {
    @Environment(\.style) private var style
    let row: MenuEntry
    let on: Bool
    var tile: CGRect?

    var body: some View {
        if case .branch(let branch) = row.target, row.icon == nil {
            Image(systemName: InstrumentRowIcon.glyph(of: branch)).font(style.font(\.icon))
                .foregroundStyle(style.color(on ? \.accentText : \.text2))
                .frame(width: 22, height: 22).accessibilityHidden(true)
        } else {
            InstrumentRowIcon(row: row, on: on, tile: tile)
        }
    }
}

// MARK: - Lists

/// A list (frames D2–D8): the rows under rule headings, an answer's first row as its card; in a narrow list (Trigger,
/// Capture) and System the root's rows instead, with System's switches. A root search that found only its offers says so
/// under them.
private struct ClassicList: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel
    let pointer: PointerTrack

    private var nav: MenuNavigator { model.nav }

    var body: some View {
        let rows = nav.rows, headings = model.headings, pointing = model.pointedRows(pointer)
        let wide = model.shape == .wide, typed = model.searchingRoot && !nav.query.isEmpty
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        let card = model.answerCard(row, at: index), on = index == nav.selection
                        VStack(alignment: .leading, spacing: 0) {
                            if let heading = card?.eyebrow ?? headings[index]?.title(goTo: true) { ClassicHeading(title: heading) }
                            if let card {
                                AnswerCard(answer: card, on: on, radius: 6).padding(.horizontal, 12).pointerRow(pointing, index)
                            } else if wide {
                                ClassicRow(row: row, on: on, best: typed && index == 0, query: nav.query, model: model)
                                    .pointerRow(pointing, index)
                            } else {
                                ClassicRootRow(row: row, on: on, right: narrowRight(row, on: on), keyed: ClassicRow.column(row, model: model).key)
                                    .overlay(alignment: .trailing) { toggle(row) }
                                    .pointerRow(pointing, index)
                            }
                        }
                    }
                    if model.noMatch { noMatch }
                }
                .padding(.vertical, 6)
            }
            .scrollsToSelection(pointing) { _, _ in if let id = nav.selected?.id { proxy.scrollTo(id) } }
        }
        .allowsHitTesting(nav.actions == nil)
    }

    /// A narrow row's right: its keys in capitals, or the current row's detail; a System switch row leaves room for it.
    private func narrowRight(_ row: MenuEntry, on: Bool) -> String? {
        if model.inSystem, row.isOn != nil { return nil }
        let column = ClassicRow.column(row, model: model)
        if column.key { return column.text }
        return on ? row.short ?? row.detail : nil
    }

    @ViewBuilder private func toggle(_ row: MenuEntry) -> some View {
        if model.inSystem, let isOn = row.isOn {
            InstrumentSwitchFace(isOn: isOn, lit: false).padding(.trailing, 20)
                .accessibilityElement().accessibilityLabel(isOn ? "on" : "off")
        }
    }

    /// A root search that found nothing but its offers (Ask AI, Search the web, Search files, Search to install): says so
    /// under those rows.
    private var noMatch: some View {
        VStack(spacing: 4) {
            Text("Nothing else matches “\(nav.query)”").styleText(\.strong).foregroundStyle(style.color(\.text))
            Text("Return asks your AI; ↓ searches the web, your files or packages to install.").styleText(\.caption).foregroundStyle(style.color(\.text3))
        }
        .lineLimit(1).truncationMode(.middle).multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: MenuModel.noMatchRoom)
    }
}

/// A wide list's row, 42 pt, a ledger line: a 150 pt column with the row's keys in capitals in the accent and → after them
/// (the key does this), or its place in the quiet colour; then the icon, the title with what was typed underlined, and what
/// it belongs to; at the right the running dot, a System switch and a branch's ›. Current, the cursorline.
private struct ClassicRow: View {
    @Environment(\.style) private var style
    let row: MenuEntry
    let on: Bool
    /// The best match of a root search, which says its kind after its title.
    let best: Bool
    let query: String
    let model: MenuModel

    var body: some View {
        let column = Self.column(row, model: model), window = window
        let echoes = row.isAnswer || row.isOffer
        HStack(spacing: 0) {
            Text(column.text ?? "").styleText(\.caption).foregroundStyle(style.color(column.key ? \.accentText : \.text3))
                .truncationMode(.middle).frame(width: 124, alignment: .leading)
            Text(column.key ? "→" : "").styleText(\.caption).foregroundStyle(style.color(\.text3)).frame(width: 26, alignment: .leading)
                .accessibilityHidden(true)
            HStack(spacing: 10) {
                ClassicIcon(row: row, on: on, tile: tile)
                Text(InstrumentMenuRow.marked(title(window), echoes ? "" : query, line: style.color(on ? \.accentLine : \.text3)))
                    .styleText(\.row).foregroundStyle(style.color(\.text)).layoutPriority(1)
                if let alias = model.nav.alias(of: row) { InstrumentKey(text: alias) }
                if let meta = meta(window) {
                    Text(meta).styleText(\.caption).foregroundStyle(style.color(\.text3)).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if row.running {
                Circle().fill(style.color(\.text3)).frame(width: 5, height: 5).padding(.trailing, 8).accessibilityLabel("running")
            }
            if model.inSystem, let isOn = row.isOn {
                InstrumentSwitchFace(isOn: isOn, lit: false).accessibilityElement().accessibilityLabel(isOn ? "on" : "off")
            }
            if row.kind == .branch || row.isOffer {
                Image(systemName: "chevron.right").font(style.font(\.small)).foregroundStyle(style.color(on ? \.accentText : \.text3))
                    .accessibilityHidden(true)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: MenuPanelSize.classicWideRow, maxHeight: MenuPanelSize.classicWideRow, alignment: .leading)
        .cursorline(on)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var window: AeroWindow? {
        if case .window(let id) = row.target { model.windows.first { $0.id == id } } else { nil }
    }

    private var tile: CGRect? {
        if case .window(let id) = row.target { InstrumentWindowGlyph.tile(of: id, in: model.windows) } else { nil }
    }

    private func title(_ window: AeroWindow?) -> String {
        if case .emoji(let e) = row.target, row.title.hasPrefix(e) { return row.title.dropFirst(e.count).trimmingCharacters(in: .whitespaces) }
        if let window, !window.title.isEmpty { return window.title }
        return row.shownTitle
    }

    /// After the title: the best match's kind, then what the row belongs to (a window's app, an action's app, a file's
    /// folder).
    private func meta(_ window: AeroWindow?) -> String? {
        if let window { return window.appName }
        let words = [best && !row.isOffer ? row.kindWord?.lowercased() : nil, row.subtitle].compactMap(\.self)
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    /// The left column: a bind's keys in capitals (`HYPER + ⇧ + N`, in the accent); else where the row is, quiet: a
    /// window's workspace, a file's day, what a search offer searches, a branch, a version or a count; else its kind.
    @MainActor static func column(_ row: MenuEntry, model: MenuModel) -> (text: String?, key: Bool) {
        if row.detailIsKey, let detail = row.detail { return (ClassicRowCaps.caps(detail), true) }
        switch row.target {
        case .window(let id):
            // The window as the menu listed it, else the row's own "workspace 3" (MenuEntries.windows): every window row
            // says its workspace, whether the menu kept the tiler's list or not.
            let workspace = model.windows.first { $0.id == id }?.workspace
                ?? row.detail.flatMap { $0.hasPrefix("workspace ") ? String($0.dropFirst("workspace ".count)) : nil }
            return (workspace.map { "ws \($0)" } ?? "window", false)
        case .searchFiles: return ("files", false)
        case .searchInstall: return ("install", false)
        case .searchWeb: return ("web", false)
        case .ask where row.isOffer: return ("ai", false)
        default: break
        }
        if let detail = row.short ?? row.detail, !detail.isEmpty, detail.count <= 18 { return (detail, false) }
        if row.kind == .branch { return ("branch", false) }
        return (row.kindWord?.lowercased(), false)
    }
}

// MARK: - Status line

/// The status line at the foot, 32 pt on the sunken colour, as a terminal editor's (Classic Shell, Q139): the mode in a
/// solid accent block (GO, SEARCH, WINDOWS, CALCULATOR, INSTALL, PICK); then at a root search the kinds Tab steps with
/// their counts, the shown one in the accent, bold and underlined, a kind at zero quieter, a click showing a kind as Tab
/// would; elsewhere where Sven is (`pilot › install`). At its right Activity's note when it has one, then
/// the menu's keys as a terminal prints them, `↵ open`, as many as fit after the kinds. It replaces Classic's kinds line and foot.
struct ClassicStatus: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel

    var body: some View {
        let quiet = Self.quiet(style.colors), hints = hints
        HStack(spacing: 0) {
            Text(mode).styleText(\.caption).fontWeight(.bold).foregroundStyle(style.color(\.onAccent))
                .padding(.horizontal, 12).frame(maxHeight: .infinity).background(style.color(\.accent))
                .accessibilityLabel("Mode \(mode.lowercased())")
            Group {
                if model.searchingRoot { kinds(quiet) } else { place }
            }
            .padding(.leading, 14).fixedSize().layoutPriority(1)
            Spacer(minLength: 12)
            // Words that are no key, never given way: Activity's note (GIPHY's attribution is on its bar, T39).
            if let note = model.footerNote { Text(note).foregroundStyle(style.color(quiet)).fixedSize().padding(.trailing, 14) }
            ViewThatFits(in: .horizontal) {
                hintLine(hints, quiet)
                hintLine(Array(hints.prefix(3)), quiet)
                hintLine(Array(hints.prefix(2)), quiet)
                hintLine(Array(hints.prefix(1)), quiet)
                Color.clear.frame(width: 0)
            }
            .padding(.trailing, 16)
        }
        .styleText(\.caption).lineLimit(1)
        .frame(height: MenuPanelSize.classicStatus)
        .background(style.color(\.sunken))
        .overlay(alignment: .top) { InstrumentRule() }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: style.radii.pop, bottomTrailingRadius: style.radii.pop, style: .continuous))
    }

    /// The mode: GO at the root, an answer's kind over its card, SEARCH while a root search is typed, the kind Tab lists
    /// whole, ACTIONS under Cmd+K, PICK in a picker, else the branch.
    var mode: String {
        let nav = model.nav
        if nav.actions != nil { return "ACTIONS" }
        if model.atRoot { return "GO" }
        if let row = nav.rows.first, let card = model.answerCard(row, at: 0) { return card.eyebrow.uppercased() }
        if model.searchingRoot { return nav.query.isEmpty ? MenuModel.title(of: nav.only).uppercased() : "SEARCH" }
        if nav.isList { return "PICK" }
        return nav.path.last?.title.uppercased() ?? "GO"
    }

    /// The keys the foot gave (MenuModel.footer and its commands), Tab's as `⇥ kind` first at a root search, where the
    /// kinds take Shift+Tab's room.
    var hints: [KeyHint] {
        let all = model.footer + model.footerTrailing + model.footerCommands
        guard model.searchingRoot, model.nav.actions == nil else { return all }
        let tab: [KeyHint] = all.contains { $0.key == "Tab" } ? [("Tab", "kind")] : []
        return tab + all.filter { $0.key != "Tab" && $0.key != "⇧Tab" }
    }

    private func kinds(_ quiet: KeyPath<StyleColors, Paint>) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(MenuEntry.Kind.tabOrder.enumerated()), id: \.offset) { _, kind in
                let on = model.nav.only == kind, count = ClassicKinds.count(of: kind, model)
                // A plain button, as the kinds line's was, that never takes the keyboard from the search field.
                Button { model.show(kind) } label: {
                    HStack(spacing: 5) {
                        Text(MenuModel.title(of: kind).lowercased())
                        if let count { Text(count).monospacedDigit() }
                    }
                    .fontWeight(on ? .bold : .regular)
                    .foregroundStyle(style.color(on ? \.accentText : count == "0" ? quiet : \.text2))
                    .overlay(alignment: .bottom) { if on { Rectangle().fill(style.color(\.accent)).frame(height: 2).offset(y: 5) } }
                    .frame(maxHeight: .infinity).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var place: some View {
        let nav = model.nav
        let crumbs = nav.isList ? ["pick"] : nav.path.map { $0.title.lowercased() }
        return Text((["pilot"] + crumbs).joined(separator: " › ")).foregroundStyle(style.color(\.text2))
    }

    private func hintLine(_ hints: [KeyHint], _ quiet: KeyPath<StyleColors, Paint>) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 6) {
                    Text(Self.sign(hint.key)).foregroundStyle(style.color(\.text2))
                    Text(hint.label.lowercased()).foregroundStyle(style.color(quiet))
                }
                .accessibilityElement(children: .ignore).accessibilityLabel("\(hint.label) \(hint.key)")
            }
        }
        .fixedSize()
    }

    /// A key as a terminal prints it: Tab ⇥, Shift+Tab ⇧⇥, Escape esc; the rest as the foot names them.
    static func sign(_ key: String) -> String {
        switch key {
        case "Tab": "⇥"
        case "⇧Tab": "⇧⇥"
        case "Esc", "esc": "esc"
        case "Space": "space"
        default: key
        }
    }

    /// The quiet words: the third text where it reads at 4.5:1 on the sunken band, else the second.
    static func quiet(_ colors: StyleColors) -> KeyPath<StyleColors, Paint> {
        Contrast.ratio(colors.text3.rgb, colors.sunken.rgb) >= 4.5 ? \.text3 : \.text2
    }
}

enum ClassicRowCaps {
    /// A bind's label in capitals, each part its sign (Shift ⇧, Cmd ⌘, Alt ⌥, Ctrl ⌃, Return ↵), joined by " + ".
    static func caps(_ label: String) -> String {
        let signs = ["Shift": "⇧", "Ctrl": "⌃", "Alt": "⌥", "Cmd": "⌘", "Return": "↵", "Escape": "ESC", "Delete": "⌫"]
        return label.split(separator: "+").map { part in
            let words = part.split(separator: " ")
            if words.count == 2, let sign = signs[String(words[1])] { return words[0].prefix(1).uppercased() + sign }
            return signs[String(part)] ?? part.uppercased()
        }
        .joined(separator: " + ")
    }
}
