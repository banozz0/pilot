import AppKit
import PilotCore
import SwiftUI

/// Toybox's Hyper+Space menu (card agent-bo-95423182, mockup B's launcher, pilot-redesign-B/src/menu.html): a pop block
/// (22 pt corner, 2 pt ink outline, 7 pt edge) holding the Pilot mark and the search in Fredoka with the menu's own bind
/// as key caps, the kinds as chips (the shown one inverted), eyebrow headings, rows on 34 pt app icons or candy tiles with
/// the current row a sun keycap, and the foot's keys as caps; a sum's, a translation's or a colour's answer as a chunky
/// card (menu Rail and Classic T13: Toybox keeps its own menu, the Rail half dropped after Q134). Drawn from the same
/// navigator, keys, pointer and Cmd+K actions as today's menu (MenuView), so only the look changes. Today's menu previews
/// no row beside the list, so neither does this one: the mockup's right-hand Ghostty card is left out.
extension MenuView {
    var toyBody: some View {
        let size = model.toyboxSize
        return ToyMenuFrame(size: size) {
            ToyMenuSearch(prompt: model.prompt, text: $model.nav.query, focused: $searchFocused,
                          path: nav.isList ? [] : nav.path, title: nav.title, ownKey: nav.isList ? nil : model.ownKey)
            if model.searchingRoot { toyKinds }
            if model.searchingRoot && nav.inFiles { FileFilterBar(model: model).padding(.horizontal, 20).padding(.bottom, 12) }
            if model.showsGiphyBar { GiphyKindBar(model: model).padding(.horizontal, 20).padding(.bottom, 12) }
            ToyRule()
            if let detail = nav.shownDetail {
                ExtensionDetailView(detail: detail).overlay(alignment: .bottomTrailing) { toyActions(size) }
            } else if let scan = model.scan {
                ToyScan(scan: scan, tools: model.tools)
                Spacer(minLength: 0)
            } else if model.showsStats {
                MenuStatsScreen { model.open(.activity) }
                Spacer(minLength: 0)
            } else if model.showsAbout {
                MenuAboutScreen(displays: NSScreen.screens.count)
                Spacer(minLength: 0)
            } else if nav.rows.isEmpty {
                ToyMenuEmpty(text: model.emptyText, branch: nav.isList ? nil : nav.branch)
            } else {
                toyList.overlay(alignment: .bottomTrailing) { toyActions(size) }
            }
            ToyFoot(hints: model.footer, trailing: model.footerTrailing, commands: model.footerCommands, note: model.footerNote)
        }
    }

    /// Cmd+K's actions over the list's corner, as today's: across a narrow list whole, else 320 pt.
    @ViewBuilder private func toyActions(_ size: CGSize) -> some View {
        if let actions = nav.actions {
            ToyRowActions(menu: actions, width: model.quiet ? size.width - 2 * 10 - 4 : 320, filter: $model.nav.actionQuery,
                          focused: $actionsFocused, pointing: model.pointedActions(pointer))
                .padding(10)
        }
    }

    /// Tab's kinds as chips; a click shows a kind as Tab reaching it does.
    private var toyKinds: some View {
        HStack(spacing: 7) {
            ForEach(MenuEntry.Kind.tabOrder, id: \.self) { kind in
                ToyKindChip(kind: kind, on: nav.only == kind, count: nav.rows.count) { withAnimation(nil) { model.nav.show(kind) } }
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Showing \(nav.only.map { $0.rawValue + "s" } ?? "all kinds"); Tab for the next kind")
    }

    private var toyList: some View {
        let rows = nav.rows
        let (quiet, system, searching) = (model.quiet, model.shape == .system, model.searchingRoot)
        let headings = model.headings
        let pointing = model.pointedRows(pointer)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        // One view per row with its heading, as today's list, so scrolling to a row brings the row.
                        // An answer that copies a result draws as its card in the top slot, the same row (T7, T13).
                        let card = model.answerCard(row, at: index)
                        VStack(alignment: .leading, spacing: 0) {
                            if let heading = card?.eyebrow ?? headings[index]?.title(goTo: false) {
                                ToyEyebrow(text: heading)
                                    .padding(.horizontal, 10).padding(.top, index == 0 ? 4 : 10).padding(.bottom, 6)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            if let card {
                                ToyAnswerCard(answer: card, on: index == nav.selection).pointerRow(pointing, index)
                            } else {
                                ToyMenuRow(row: row, on: index == nav.selection, tag: searching, quiet: quiet, system: system,
                                           query: nav.query, alias: nav.alias(of: row))
                                    .pointerRow(pointing, index)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            }
            .scrollsToSelection(pointing) { _, _ in if let id = nav.selected?.id { proxy.scrollTo(id) } }
        }
        .allowsHitTesting(nav.actions == nil)
    }
}

/// The pop block the menu sits in: its fill, corner, outline and edge from the style's pop tokens, the content clipped to
/// the inner corner.
private struct ToyMenuFrame<Content: View>: View {
    @Environment(\.style) private var style
    let size: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        let d = style.depth.pop
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(width: size.width - 2 * d.outline, height: size.height - d.outline - d.edge)
            .clipShape(.rect(cornerRadius: style.radii.pop - d.outline, style: .continuous))
            .foregroundStyle(style.color(\.text))
            .styleSurface(\.pop, fill: \.panel, radius: \.pop)
    }
}

/// A 2 pt rule in the ink across the panel (the mockup's section borders).
struct ToyRule: View {
    @Environment(\.style) private var style
    /// Down a panel (the notes list's edge) instead of across it.
    var vertical = false
    var body: some View { style.color(\.outline).frame(width: vertical ? 2 : nil, height: vertical ? nil : 2) }
}

/// Key caps for a bind's label and a foot's key (pure, so the caps are tested apart from the drawing).
enum ToyCaps {
    struct Bind: Equatable {
        var hyper: Bool
        var keys: [String]
    }

    /// "Hyper+Shift+T": Hyper's cap, then Shift and T.
    static func bind(_ label: String) -> Bind {
        var keys = label.split(separator: "+").map(String.init)
        let hyper = keys.first == "Hyper"
        if hyper { keys.removeFirst() }
        return Bind(hyper: hyper, keys: keys)
    }

    /// "⌘K" is ⌘ and K, "↑↓" two caps, "← →" two, "Esc" and "Tab" one each: a run of letters or digits is one cap, any
    /// other character its own, spaces none.
    static func hint(_ key: String) -> [String] {
        var caps: [String] = [], word = ""
        for c in key {
            if c.isLetter || c.isNumber { word.append(c); continue }
            if !word.isEmpty { caps.append(word); word = "" }
            if !c.isWhitespace { caps.append(String(c)) }
        }
        if !word.isEmpty { caps.append(word) }
        return caps
    }
}

/// The mockup's row-sized key cap (`.kc`, 26 pt with its border, the foot's 24): a word or a symbol in Nunito 800, the
/// surface colour with an ink outline and a 4 pt edge; Hyper's cap sun with its arrow, inverted (ink, sun arrow) on the
/// sun row.
struct ToyMenuCap: View {
    @Environment(\.style) private var style
    var label: String?
    var hyper = false
    /// On the current row's sun fill.
    var onSun = false
    var height: CGFloat = 26

    var body: some View {
        let fill = hyper ? (onSun ? style.color(\.outline) : style.color(\.hyper)) : style.color(\.raised)
        let ink = hyper ? (onSun ? style.color(\.accent) : style.color(\.onHyper)) : style.color(\.text)
        let edge: CGFloat = height > 24 ? 4 : 3
        Group {
            if let label { Text(label).font(style.toyNunito(800, height > 24 ? 12 : 11.5)) } else {
                Image(systemName: "arrowshape.up.fill").font(.system(size: height > 24 ? 10 : 9.5, weight: .heavy))
            }
        }
        .foregroundStyle(ink).lineLimit(1).fixedSize()
        .padding(.horizontal, 6)
        .frame(minWidth: height - 4, minHeight: height - 2 - edge)
        .padding(EdgeInsets(top: 2, leading: 2, bottom: edge, trailing: 2))
        .background(Toy.block(style, fill: fill, radius: 8, edge: edge))
        .accessibilityLabel(label ?? "Hyper")
    }
}

/// A bind as caps: Hyper's, then each key.
private struct ToyBindCaps: View {
    let label: String
    var onSun = false

    var body: some View {
        let bind = ToyCaps.bind(label)
        HStack(spacing: 4) {
            if bind.hyper { ToyMenuCap(hyper: true, onSun: onSun) }
            ForEach(Array(bind.keys.enumerated()), id: \.offset) { ToyMenuCap(label: $1, onSun: onSun) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

/// A row's words on the right (`.tag`): a place, a count, a file's day, in a small outlined chip on the sunk fill, the
/// surface's on the sun row.
struct ToyTag: View {
    @Environment(\.style) private var style
    let text: String
    var onSun = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Text(text).font(style.toyNunito(800, 11.5)).foregroundStyle(style.color(\.text)).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(onSun ? style.color(\.raised) : style.color(\.sunken), in: shape)
            .overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
    }
}

/// A window's workspace on the right: the word, then its number in Fredoka on a flat sunk well, as the top bar's chips
/// and Home's tiles number a workspace (flat, so it never reads as a key to press); the surface's well on the sun row.
private struct ToyWorkspaceTag: View {
    @Environment(\.style) private var style
    let name: String
    let onSun: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text("workspace").font(style.toyNunito(700, 12.5)).foregroundStyle(onSun ? style.color(\.onAccent).opacity(0.75) : style.color(\.text2))
            Text(name).font(style.toyFredoka(15)).monospacedDigit().foregroundStyle(style.color(\.text))
                .padding(.horizontal, 7).frame(minWidth: 26, minHeight: 26)
                .toyWell(onSun ? \.raised : \.sunken, radius: 8)
        }
        .lineLimit(1).fixedSize()
        .accessibilityElement(children: .ignore).accessibilityLabel("workspace \(name)")
    }
}

/// The search line (`.search`): the Pilot mark where Capsy sat, inside a branch its crumb, the field in Fredoka, a
/// picker's title or the menu's own bind on the right.
private struct ToyMenuSearch: View {
    @Environment(\.style) private var style
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let path: [MenuBranch]
    let title: String?
    let ownKey: String?

    var body: some View {
        HStack(spacing: 14) {
            PilotMark(size: 44)
            if !path.isEmpty { ToyCrumb(path: path) }
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt).font(style.toyFredoka(26)).foregroundStyle(style.color(\.text3)).lineLimit(1).allowsHitTesting(false)
                }
                TextField("", text: $text).textFieldStyle(.plain).font(style.toyFredoka(26)).foregroundStyle(style.color(\.text))
                    .focused(focused).accessibilityLabel(prompt)
            }
            Spacer(minLength: 8)
            if let title { ToyTag(text: title) } else if let ownKey { ToyBindCaps(label: ownKey) }
        }
        .padding(.leading, 16).padding(.trailing, 20).padding(.top, 16).padding(.bottom, 14)
    }
}

/// Where Sven is inside a branch, or which prompt the clipboard panel is in: its glyph and words on the sun's soft fill,
/// outlined.
struct ToyCrumb: View {
    @Environment(\.style) private var style
    let symbol: String
    let text: String

    init(symbol: String, text: String) { self.symbol = symbol; self.text = text }
    init(path: [MenuBranch]) {
        self.init(symbol: path.last?.look.symbol ?? "chevron.right", text: path.map(\.title).joined(separator: " › "))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold))
            Text(text).font(style.toyNunito(800, 13.5))
        }
        .foregroundStyle(style.color(\.text)).lineLimit(1).fixedSize()
        .padding(.horizontal, 11).frame(height: 32)
        .background(style.color(\.accentSoft), in: shape)
        .overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
        .accessibilityElement(children: .ignore).accessibilityLabel("In \(text)")
    }
}

/// One kind as a chip (`.chip`): its glyph and plural; the shown one inverted with how many rows it lists.
private struct ToyKindChip: View {
    @Environment(\.style) private var style
    let kind: MenuEntry.Kind?
    let on: Bool
    let count: Int
    let pick: () -> Void

    private static let glyphs: [MenuEntry.Kind: String] = [.app: "macwindow", .window: "rectangle.split.2x1", .file: "folder",
                                                           .action: "bolt", .package: "shippingbox"]

    var body: some View {
        ToyChip(on: on, pick: pick) {
            HStack(spacing: 6) {
                if let kind, let glyph = Self.glyphs[kind] { Image(systemName: glyph).font(.system(size: 12.5, weight: .bold)) }
                Text(kind.map { $0.rawValue.capitalized + "s" } ?? "All").font(style.toyNunito(800, 13))
                if on { Text("\(count)").font(style.toyNunito(800, 11)).monospacedDigit().opacity(0.6) }
            }
        }
    }
}

/// One row (`.item`): its icon, its title (the typed letters underlined in the sun's edge) with its alias, under it
/// what it is and belongs to; on the right its key as caps, a window's workspace numbered as the bar numbers it, or its
/// place, count or day as a tag, the running dot, a branch's chevron, System's switch. The current row is a sun keycap.
/// A quiet list (the root's, Trigger's, Capture's) keeps the rest for its current row, as today's does.
private struct ToyMenuRow: View {
    @Environment(\.style) private var style
    let row: MenuEntry
    let on: Bool
    /// A root search: the kind leads the second line.
    let tag: Bool
    let quiet: Bool
    let system: Bool
    let query: String
    let alias: String?

    var body: some View {
        let extras = !quiet || on
        let ink = on ? style.color(\.onAccent) : style.color(\.text)
        let shows = row.appShows
        HStack(spacing: 12) {
            if shows.icon { ToyRowIcon(row: row, on: on) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if shows.title { title.font(style.toyNunito(800, 14.5)).foregroundStyle(ink).lineLimit(1) }
                    if let alias { ToyAlias(alias: alias, onSun: on) }
                }
                if let second {
                    Text(second).font(style.toyNunito(700, 12.5)).foregroundStyle(on ? ink.opacity(0.75) : style.color(\.text2))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if row.running, extras {
                Circle().fill(Toy.module(2, style)).overlay { Circle().strokeBorder(style.color(\.outline), lineWidth: 2) }
                    .frame(width: 10, height: 10).accessibilityLabel("running")
            }
            if let detail = row.detail, extras {
                if row.detailIsKey { if on || !system { ToyBindCaps(label: detail, onSun: on) } }
                else if let workspace { ToyWorkspaceTag(name: workspace, onSun: on) } else { ToyTag(text: detail, onSun: on) }
            }
            if system, let isOn = row.isOn {
                ToySwitchFace(isOn: isOn, width: 40, height: 24).accessibilityElement().accessibilityLabel(isOn ? "on" : "off")
            }
            if extras, row.kind == .branch {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(on ? ink : style.color(\.text3)).accessibilityHidden(true)
            }
        }
        .padding(.leading, 9).padding(.trailing, 12)
        .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
        .frame(maxWidth: .infinity, minHeight: MenuPanelSize.toyboxRowPitch, maxHeight: MenuPanelSize.toyboxRowPitch, alignment: .leading)
        .background { if on { Toy.block(style, fill: style.color(\.accent), radius: 15, edge: 4) } }
        .appTip(row.shownTitle, when: !shows.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// What it is and belongs to: while searching its kind (a file says its folder alone, its day sits on the right),
    /// the app an action belongs to or a file's folder, a branch's hint.
    private var second: String? {
        let kind = tag && !row.isOffer ? row.kindWord : nil
        let words = [kind, row.subtitle, row.hint.isEmpty ? nil : row.hint].compactMap(\.self)
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    /// A window's workspace, from its detail ("workspace 3", MenuEntries.windows); nil for any other row.
    private var workspace: String? {
        let word = "workspace "
        guard row.kind == .window, let detail = row.detail, detail.hasPrefix(word), detail.count > word.count else { return nil }
        return String(detail.dropFirst(word.count))
    }

    /// The title with the typed letters, where they run in it, underlined in the sun's edge (the ink on the sun row).
    private var title: Text {
        let shown = row.shownTitle, typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, let range = shown.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) else { return Text(shown) }
        let mark = on ? style.color(\.outline) : style.color(\.accentEdge)
        return Text("\(String(shown[..<range.lowerBound]))\(Text(shown[range]).underline(color: mark))\(String(shown[range.upperBound...]))")
    }
}

/// An answer's card in Toybox's look (menu Rail and Classic T13; MenuAnswer reads it from the row, as Instrument's
/// AnswerCard does): a chunky block (2 pt ink outline, 5 pt edge) with what was typed in Fredoka and its tag on the left, a
/// sun disc with the arrow between, the result on the right (a number in JetBrains Mono, its unit quieter) and its tag;
/// a colour's swatch, ramp and five formats instead. The current one wears a sun "Return copies" cap. It is the row
/// Return copies; the Ask row stays a row under it.
private struct ToyAnswerCard: View {
    @Environment(\.style) private var style
    let answer: MenuAnswer
    let on: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if case .colour(let colour) = answer.kind { colourFace(colour) } else { sides }
            }
            .padding(EdgeInsets(top: 2, leading: 2, bottom: 5, trailing: 2))
            .background { Toy.block(style, fill: style.color(\.raised), radius: 18, edge: 5) }
            .overlay(alignment: .topTrailing) {
                if on {
                    Text("↵ copies").font(style.toyNunito(800, 11.5)).foregroundStyle(style.color(\.onAccent))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background { Toy.block(style, fill: style.color(\.accent), radius: 8, edge: 3) }
                        .padding(10)
                }
            }
            if let note = answer.note {
                Text(note).font(style.toyNunito(700, 12.5)).foregroundStyle(style.color(\.text2)).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 2).padding(.bottom, 8)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint("Return copies \(answer.value)\(answer.unit.map { " \($0)" } ?? "")")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private var label: String {
        if case .colour = answer.kind { return "Colour \(answer.value)" }
        return "\(answer.expression), \(answer.expressionChip), is \(answer.value)\(answer.unit.map { " \($0)" } ?? ""), \(answer.resultChip)"
    }

    private var sides: some View {
        HStack(spacing: 0) {
            side(tag: answer.expressionChip) {
                Text(answer.expression).font(style.toyFredoka(26)).foregroundStyle(style.color(\.text))
            }
            Rectangle().fill(style.color(\.outline).opacity(0.25)).frame(width: 2)
                .overlay {
                    Image(systemName: "arrow.right").font(.system(size: 14, weight: .heavy)).foregroundStyle(style.color(\.onAccent))
                        .frame(width: 34, height: 34)
                        .background { Circle().fill(style.color(\.accent)).overlay { Circle().strokeBorder(style.color(\.outline), lineWidth: 2) } }
                }
                .frame(width: 44)
            side(tag: answer.resultChip) {
                if answer.kind == .translation {
                    Text(answer.value).font(style.toyFredoka(26)).foregroundStyle(style.color(\.text))
                } else {
                    let number = Text(answer.value).font(style.toyMono(26, bold: true)).foregroundStyle(style.color(\.text))
                    let unit = Text(answer.unit.map { " \($0)" } ?? "").font(style.toyMono(18)).foregroundStyle(style.color(\.text2))
                    Text("\(number)\(unit)").monospacedDigit()
                }
            }
        }
        .frame(minHeight: 150)
    }

    /// One side: its words over its tag, centred.
    private func side(tag: String, @ViewBuilder _ text: () -> some View) -> some View {
        VStack(spacing: 10) {
            text().lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.5)
            ToyTag(text: tag)
        }
        .padding(.horizontal, 16).padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    /// A colour: its swatch on an ink outline with the hex in Fredoka on it, its seven-step ramp, and beside them the five
    /// formats (ColourAnswer), each selectable.
    private func colourFace(_ colour: UInt32) -> some View {
        let formats = ColourAnswer.formats(colour), shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formats[0]).font(style.toyFredoka(20))
                    Text(formats[1]).font(style.toyMono(11.5)).opacity(0.8)
                }
                .foregroundStyle(Color(hex: AnswerInk.ink(on: colour)))
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104, alignment: .bottomLeading)
                .background(Color(hex: colour), in: shape)
                .overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
                HStack(spacing: 4) {
                    ForEach(Array(AnswerInk.ramp(colour).enumerated()), id: \.offset) { _, step in
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(hex: step)).frame(height: 16)
                            .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(style.color(\.outline), lineWidth: 1.5) }
                    }
                }
                .accessibilityHidden(true)
            }
            .frame(width: 220)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(Array(zip(ColourFormats.names, formats)), id: \.0) { name, value in
                    GridRow {
                        Text(name.uppercased()).font(style.toyNunito(800, 11)).tracking(0.6).foregroundStyle(style.color(\.text3))
                        Text(value).font(style.toyMono(12.5)).foregroundStyle(style.color(\.text2))
                            .lineLimit(1).minimumScaleFactor(0.75).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            // Under the current card's "↵ copies" cap, which sits in the top corner.
            .padding(.top, 30)
        }
        .padding(14)
    }
}

/// A row's alias beside its title, in mono as it is typed, on a faint fill.
private struct ToyAlias: View {
    @Environment(\.style) private var style
    let alias: String
    let onSun: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text(verbatim: alias).font(style.toyMono(11)).lineLimit(1).fixedSize()
            .foregroundStyle(onSun ? style.color(\.onAccent) : style.color(\.text2))
            .padding(.horizontal, 5).frame(minHeight: 18)
            .overlay { shape.strokeBorder(onSun ? style.color(\.onAccent).opacity(0.5) : style.color(\.line3), lineWidth: 1.5) }
            .accessibilityLabel("alias \(alias)")
    }
}

/// A row's icon at 34 pt: an app's or a file's own icon (an app's action badged with what it does), else its glyph on a
/// candy tile in its module's or role's colour.
private struct ToyRowIcon: View {
    let row: MenuEntry
    let on: Bool

    var body: some View { ToyArt(art: row.art(tiled: true), size: 34) }
}

/// A row's art at `size`: an app's or a file's own icon (an action's badged with what it does), else its glyph on a candy
/// tile in its module's or role's colour; nothing, in the same room, for a row with neither.
private struct ToyArt: View {
    @Environment(\.style) private var style
    let art: MenuEntry.Art?
    let size: CGFloat

    var body: some View {
        Group {
            switch art {
            case .icon(let image, let badge)?:
                ArtImage(image: image).frame(width: size, height: size)
                    .overlay(alignment: .bottomTrailing) {
                        if let badge { ToyTile(symbol: badge, color: style.color(\.accent), size: size / 2).offset(x: 4, y: 4) }
                    }
            case .tile(let symbol, let paint)?, .symbol(let symbol, let paint)?:
                ToyTile(symbol: symbol, color: paint.toy(style), size: size)
            case nil:
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension MenuPaint {
    /// Toybox's candy colour for the role: each tint its own module colour, a neutral row the quiet lilac grey.
    func toy(_ style: StyleTokens) -> Color {
        switch self {
        case .module(let i): Toy.module(i, style)
        case .tint(let tint):
            switch tint {
            case .accent: Toy.module(0, style)
            case .second: Toy.module(1, style)
            case .good: Toy.module(2, style)
            case .problem: Toy.module(3, style)
            case .third: Toy.module(4, style)
            case .amber: Toy.module(5, style)
            case .neutral: style.color(\.text3)
            }
        }
    }
}

/// Nothing to list, in the middle of the list's room: inside a branch its tile, then the first sentence as the line and
/// the rest under it.
private struct ToyMenuEmpty: View {
    @Environment(\.style) private var style
    let text: String
    let branch: MenuBranch?

    var body: some View {
        let cut = text.range(of: ". ")
        VStack(spacing: 4) {
            if let look = branch?.look { ToyTile(symbol: look.symbol, color: MenuPaint.module(look.colour).toy(style), size: 52).padding(.bottom, 12) }
            Text(cut.map { String(text[..<$0.lowerBound]) + "." } ?? text).font(style.toyNunito(800, 15)).foregroundStyle(style.color(\.text))
            if let cut { Text(text[cut.upperBound...]).font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2)) }
        }
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 28).padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A list still being read (MenuScan: Clean, Update, Remove, Install): the wait with its live line, the three steps from
/// here, the kinds of row the list can hold.
private struct ToyScan: View {
    @Environment(\.style) private var style
    let scan: MenuScan
    let tools: Set<String>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scan.heading).font(style.toyNunito(800, 14.5))
                    Text(scan.line).font(style.toyNunito(700, 12.5)).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 14)
            ForEach(Array(scan.steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 12) {
                    ToyArt(art: MenuEntry.art(step.icon, tiled: true), size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(style.toyNunito(800, 14))
                        Text(step.detail).font(style.toyNunito(700, 12.5)).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    ToyTag(text: index == 0 ? "now" : "next", onSun: index == 0)
                }
                .padding(.vertical, 8)
            }
            ToyEyebrow(text: "What the list can hold").padding(.top, 12).padding(.bottom, 8)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(scan.kinds(on: tools), id: \.title) { kind in
                    HStack(spacing: 8) {
                        ToyArt(art: MenuEntry.art(kind.icon, tiled: true), size: 22)
                        Text(kind.title).font(style.toyNunito(700, 12.5)).foregroundStyle(style.color(\.text2)).lineLimit(1)
                    }
                }
            }
        }
        .foregroundStyle(style.color(\.text))
        .padding(.horizontal, 22).padding(.top, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The foot (`.foot`): a 2 pt rule, then each key as caps beside what it does; on the right the root's way out and what
/// the current row's keys do. The panels' foot too.
struct ToyFoot: View {
    @Environment(\.style) private var style
    let hints: [KeyHint]
    var trailing: [KeyHint] = []
    var commands: [KeyHint] = []
    /// Words at the right edge, not keys: a panel's count ("49 words", "2 changes").
    var note: String?

    var body: some View {
        VStack(spacing: 0) {
            ToyRule()
            HStack(spacing: 18) {
                ForEach(Array(hints.enumerated()), id: \.offset) { hint($1, keyFirst: true) }
                Spacer(minLength: 8)
                ForEach(Array(trailing.enumerated()), id: \.offset) { hint($1, keyFirst: true) }
                if let note { Text(note).monospacedDigit() }
                ForEach(Array(commands.enumerated()), id: \.offset) { hint($1, keyFirst: false) }
            }
            .font(style.toyNunito(700, 12.5)).foregroundStyle(style.color(\.text2)).lineLimit(1)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((hints + trailing).map { "\($0.key) \($0.label)" }.joined(separator: ", ")
                                + commands.map { ", \($0.label) \($0.key)" }.joined() + (note.map { ", \($0)" } ?? ""))
        }
    }

    /// The key's caps and its words: the hints key first, the current row's commands words first as mockup C sets them.
    private func hint(_ hint: KeyHint, keyFirst: Bool) -> some View {
        HStack(spacing: 7) {
            if !keyFirst { Text(hint.label).foregroundStyle(style.color(\.text)).fontWeight(.heavy) }
            HStack(spacing: 4) { ForEach(ToyCaps.hint(hint.key), id: \.self) { ToyMenuCap(label: $0, height: 24) } }
            if keyFirst { Text(hint.label) }
        }
        .fixedSize()
    }
}

/// Cmd+K's actions on the current row in Toybox: a raised block over the list's corner, the row's icon and name, its
/// actions in groups with a 2 pt rule between (the ones that force or remove in coral), the current one a sun keycap
/// with ↵, the filter at the foot holding the keyboard. The same list, keys, pointer and fades as today's
/// (RowActionsPopover).
private struct ToyRowActions: View {
    @Environment(\.style) private var style
    let menu: RowActionsMenu
    let width: CGFloat
    @Binding var filter: String
    var focused: FocusState<Bool>.Binding
    let pointing: PointerList
    @State private var cut = Cut()

    var body: some View {
        KitPopover(width: width, inset: 0, arrow: false) {
            HStack(spacing: 8) {
                ToyArt(art: menu.row.art(tiled: true), size: 17)
                Text(menu.row.shownTitle).font(style.toyNunito(800, 12.5)).foregroundStyle(style.color(\.text2)).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ViewThatFits(in: .vertical) {
                    actions
                    ScrollView { Cut.ends { actions } }.scrollIndicators(.never)
                        .onScrollGeometryChange(for: Cut.self, of: Cut.init) { cut = $1 }
                        .mask { Cut.Fade(cut: cut) }
                        .overlay(alignment: .top) { if cut.above { Cut.arrow("chevron.compact.up") } }
                        .overlay(alignment: .bottom) { if cut.below { Cut.arrow("chevron.compact.down") } }
                }
                .scrollsToSelection(pointing) { Cut.scroll(proxy, from: $0, to: $1, in: menu.visible) }
            }
            ToyRule()
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13, weight: .bold)).foregroundStyle(style.color(\.text3))
                    .accessibilityHidden(true)
                TextField("Filter actions…", text: $filter).textFieldStyle(.plain).font(style.toyNunito(700, 13.5)).focused(focused)
            }
            .padding(.horizontal, 14).frame(height: 40)
        }
        .onAppear { focused.wrappedValue = true }
        .onChange(of: menu.query) { cut = Cut() }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if menu.visible.isEmpty {
                VStack(spacing: 3) {
                    Text("No action called “\(menu.query)”").font(style.toyNunito(800, 13.5))
                    Text("\(menu.row.shownTitle) has \(menu.total) action\(menu.total == 1 ? "" : "s"); clear the filter to see them.")
                        .font(style.toyNunito(700, 12.5)).foregroundStyle(style.color(\.text2))
                }
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.vertical, 18)
            }
            ForEach(Array(menu.visible.enumerated()), id: \.element) { index, action in
                VStack(alignment: .leading, spacing: 0) {
                    if index > 0, action.group != menu.visible[index - 1].group {
                        style.color(\.line2).frame(height: 2).padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    row(action, on: index == menu.selection).pointerRow(pointing, index)
                }
            }
        }
        // MenuScrollTests: Arrow Down onto the last action shows its end, so the inset under it stays small.
        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 6)
    }

    private func row(_ action: RowActionsMenu.Choice, on: Bool) -> some View {
        let ink = on ? style.color(\.onAccent) : action.danger ? style.color(\.problem) : style.color(\.text)
        return HStack(spacing: 10) {
            Image(systemName: action.symbol(on: menu.row)).font(.system(size: 13, weight: .bold)).frame(width: 20)
                .foregroundStyle(on || action.danger ? ink : style.color(\.text2)).accessibilityHidden(true)
            Text(action.title).font(style.toyNunito(800, 13.5)).foregroundStyle(ink).lineLimit(1)
            Spacer(minLength: 8)
            if let key = action.key(on: menu.row) { ToyMenuCap(label: key, onSun: on, height: 24) }
            if on { ToyMenuCap(label: "↵", onSun: true, height: 24) }
        }
        .padding(.horizontal, 10)
        .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background { if on { Toy.block(style, fill: style.color(\.accent), radius: 12, edge: 4) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
