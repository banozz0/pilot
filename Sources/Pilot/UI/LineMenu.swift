import AppKit
import PilotCore
import SwiftUI

/// The Hyper+Space menu as Line draws it (menu-morph T1; look.menuLayout = line; Sven Q149, Q164, Q165): at the root,
/// Classic's list at Omarchy's 431 width, the root's rows in JetBrains Mono; once Sven types, Tabs a
/// kind or opens a branch, the menu's 750 list in Instrument's rows at 36 pt. One search line for both, 60 pt, what is
/// typed in JetBrains Mono 20 with the caret in the accent; at its right the menu's own keys at the root, what Return
/// does on the best match, an answer's result itself, or a branch's or picker's title. The kinds Tab steps live in the
/// foot with their counts. The 2 pt frame in the theme's accent line is Classic's. The list, the answer cards, Cmd+K's
/// actions, an extension's detail, a scan's wait and the empty line are MenuBody's, so every row kind the model lists
/// (apps, windows, files, actions, settings, Ask AI) draws as in Classic and the Rail.
struct LineMenu: View {
    @Environment(\.style) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: MenuModel
    let pointer: PointerTrack
    var searchFocused: FocusState<Bool>.Binding
    var actionsFocused: FocusState<Bool>.Binding

    var body: some View {
        let size = model.instrumentSize, root = model.atRoot
        // The Files view previews the selected file beside the list (FilePreviewPane), which narrows by the pane and its rule.
        let list = model.previewsFile ? size.width - FilePreviewPane.width - 1 : size.width
        VStack(spacing: 0) {
            // The one search field: never inside the branch below, so moving from the root to a search never rebuilds it
            // and the keyboard stays in it through the morph (menu-morph T2).
            LineSearch(model: model, focused: searchFocused, actionsFocused: actionsFocused)
            MenuBars(model: model)
            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    // Each list at its own final width from its first frame, pinned to the plate's left edge with the
                    // field; the plate's growing frame reveals it (LineMorph).
                    // Cmd+K steps into the row (T3): its actions take the list's place, the row a token in the line.
                    if let actions = model.nav.actions {
                        LineActions(model: model, menu: actions, pointer: pointer).frame(width: size.width)
                    } else if let speedTest = model.speedTest {
                        SpeedTestView(test: speedTest).frame(width: size.width)
                    } else if root {
                        ClassicRoot(model: model, pointer: pointer, row: MenuPanelSize.lineRow).style(ClassicMenu.face(style))
                            .frame(width: size.width).transition(LineMorph.root(reduce: reduceMotion))
                    } else {
                        MenuBody(model: model, pointer: pointer, actionsFocused: actionsFocused, width: list,
                                 rowHeight: MenuPanelSize.lineRow, numbered: !model.nav.inFiles)
                            .frame(width: list).transition(LineMorph.results(reduce: reduceMotion))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                // A line chip's list over the list's top right, under its chip (MenuChips).
                .overlay(alignment: .topTrailing) { if let chip = model.chip { ChipMenuView(model: model, chip: chip, pointer: pointer).padding(.top, 6).padding(.trailing, 14) } }
                LinePreviewSlot(model: model)
            }
            LineFoot(model: model)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        // Only a change between the root and the rest animates (LineMorph.plate, keyed on it); a key that only changes how
        // many rows show sets the new height at once, as typing gets no animation. The lists bring their own (transition).
        .animation(LineMorph.plate(back: root, reduce: reduceMotion), value: root)
        .popSurface(NSEdgeInsetsZero, shadows: false)
        // The frame, on the plate's own corner, so no sliver of the face shows outside it.
        .overlay { RoundedRectangle(cornerRadius: style.radii.pop, style: .continuous).strokeBorder(style.color(\.accentLine), lineWidth: 2) }
        .style(Self.face(style))
        // The window holds the union of both sizes while the plate morphs: the plate sits at its top centre.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// `tokens` with the search line in JetBrains Mono 20 (Q164); the rows keep Instrument's Geist.
    static func face(_ tokens: StyleTokens) -> StyleTokens {
        var type = tokens.type
        type.search = TypeRole(face: .bundled(StyleTokens.jetBrainsMono(400)), size: 20)
        return tokens.retyped(type)
    }
}

// MARK: - Search line

/// The search line, 60 pt: Pilot's mark (inside a branch its crumb), what is typed with the caret in the accent; at its
/// right the menu's keys at the root, a picker's title, an answer's result, what Return does on the best match, or what
/// a kind Tab lists whole holds.
private struct LineSearch: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel
    var focused: FocusState<Bool>.Binding
    var actionsFocused: FocusState<Bool>.Binding

    var body: some View {
        let nav = model.nav, stepped = nav.actions, speed = model.speedTest
        // Cmd+K's row or the Speed test covers the field, which stays in the tree hidden so it is never rebuilt.
        let typing = stepped == nil && speed == nil
        HStack(spacing: 12) {
            if speed != nil {
                InstrumentCrumb(symbol: "gauge.with.dots.needle.67percent", text: "Speed test")
            } else if let stepped {
                LineToken(row: stepped.row, windows: model.windows)
            } else if let branch = nav.path.last, !nav.isList {
                InstrumentCrumb(symbol: InstrumentRowIcon.glyph(of: branch), text: branch.title)
            } else {
                InstrumentMark(size: 18).foregroundStyle(style.color(\.text2))
            }
            ZStack(alignment: .leading) {
                if let speed {
                    Text(SpeedTestView.status(speed) ?? "").font(style.font(\.search, size: 16 / style.scale))
                        .foregroundStyle(style.color(\.text3)).lineLimit(1).allowsHitTesting(false)
                } else if nav.query.isEmpty, stepped == nil {
                    Text(prompt).styleText(\.search).foregroundStyle(style.color(\.text3)).lineLimit(1).allowsHitTesting(false)
                }
                if typing, let best = completion {
                    // The best match after what is typed, quiet: a hint of what Return opens, never inserted text.
                    HStack(spacing: 0) {
                        Text(nav.query).hidden()
                        Text("  → \(best)").foregroundStyle(style.color(\.text3))
                    }
                    .styleText(\.search).lineLimit(1).allowsHitTesting(false).accessibilityHidden(true)
                }
                // The query's field stays in the tree while the actions show, hidden, so it is never rebuilt.
                TextField("", text: $model.nav.query).textFieldStyle(.plain).styleText(\.search)
                    .foregroundStyle(style.color(\.text)).tint(style.color(\.accent)).focused(focused)
                    .accessibilityLabel(prompt)
                    .opacity(typing ? 1 : 0).allowsHitTesting(typing)
                if stepped != nil {
                    TextField("", text: $model.nav.actionQuery, prompt: Text("Filter actions…").foregroundStyle(style.color(\.text3)))
                        .textFieldStyle(.plain).styleText(\.search).foregroundStyle(style.color(\.text)).tint(style.color(\.accent))
                        .focused(actionsFocused).accessibilityLabel("Filter actions")
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 18).frame(height: MenuPanelSize.lineSearch)
        .overlay(alignment: .bottom) { InstrumentRule() }
    }

    /// The best match's name, which the line completes the query with at a typed root search; none for an answer, an
    /// offer to search elsewhere, or a name that is what was typed.
    private var completion: String? {
        let nav = model.nav
        guard model.searchingRoot, !nav.query.isEmpty, let best = nav.rows.first, !best.isAnswer, !best.isOffer,
              nav.selection == 0 else { return nil }
        let title = best.shownTitle
        return title.caseInsensitiveCompare(nav.query.trimmingCharacters(in: .whitespaces)) == .orderedSame && best.kind != .app ? nil : title
    }

    @ViewBuilder private var trailing: some View {
        let nav = model.nav
        if let speed = model.speedTest {
            SpeedTestTrailing(test: speed)
        } else if let stepped = nav.actions {
            Text("\(stepped.visible.count)").styleText(\.mono).foregroundStyle(style.color(\.text3))
        } else if let title = nav.title {
            InstrumentCrumb(text: title)
        } else if model.atRoot, let own = model.ownKey {
            InstrumentBindKeys(label: own, layerKeys: model.layerKeys)
        } else if model.hasLineChips {
            LineChips(model: model)
        } else if let row = nav.rows.first, let answer = model.answerCard(row, at: 0) {
            LineAnswer(answer: answer)
        } else if model.searchingRoot, !nav.query.isEmpty, let best = nav.rows.first, !best.isOffer {
            HStack(spacing: 6) {
                Text(best.returnLabel).styleText(\.caption).foregroundStyle(style.color(\.text3))
                InstrumentKey(text: "↵")
            }
            .lineLimit(1).fixedSize()
        } else if let count = model.resultCount {
            Text(count).styleText(\.mono).foregroundStyle(style.color(\.text3)).lineLimit(1).fixedSize()
        }
    }

    /// "Go…" at the root, as Classic's; "Filter windows…" over a kind Tab lists whole; else the menu's own.
    private var prompt: String {
        if model.atRoot { return "Go…" }
        if model.searchingRoot, let only = model.nav.only { return "Filter \(MenuModel.title(of: only).lowercased())…" }
        return model.branchPrompt ?? model.prompt
    }
}

/// An answer's result at the line's right, "= 13.67016623 mi": the number in the accent, its unit quieter; a colour's
/// swatch before its hex; a translation in the search face.
private struct LineAnswer: View {
    @Environment(\.style) private var style
    let answer: MenuAnswer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("=").styleText(\.mono).foregroundStyle(style.color(\.text3))
            if case .colour(let rgb) = answer.kind {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(rgb: rgb)).frame(width: 14, height: 14)
                    .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(style.color(\.imageOutline)) }
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            }
            Text(answer.value).styleText(\.search).foregroundStyle(style.color(\.accentText))
            if let unit = answer.unit { Text(unit).styleText(\.mono).foregroundStyle(style.color(\.text2)) }
        }
        .lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: 360, alignment: .trailing)
    }
}

/// The row Cmd+K stepped into, as a token in the line: its icon and name on the accent's soft fill, then ›. Escape
/// takes it away and the query comes back.
private struct LineToken: View {
    @Environment(\.style) private var style
    let row: MenuEntry
    let windows: [AeroWindow]

    var body: some View {
        HStack(spacing: 6) {
            InstrumentRowIcon(row: row, on: true, tile: tile, side: 18)
            Text(row.shownTitle).styleText(\.strong).foregroundStyle(style.color(\.accentText)).lineLimit(1)
            Image(systemName: "chevron.right").font(style.font(\.small)).foregroundStyle(style.color(\.accentText))
        }
        .padding(.leading, 6).padding(.trailing, 9).frame(height: 30)
        .frame(maxWidth: 260, alignment: .leading).fixedSize()
        .background(style.color(\.accentSoft), in: .rect(cornerRadius: style.radii.control, style: .continuous))
        .accessibilityElement(children: .combine).accessibilityLabel("Actions for \(row.shownTitle)")
    }

    private var tile: CGRect? {
        if case .window(let id) = row.target { InstrumentWindowGlyph.tile(of: id, in: windows) } else { nil }
    }
}

// MARK: - Actions

/// Cmd+K in Line: the row's actions where the list was, full width, each as Instrument draws them (RowActionsList),
/// the pointer on them as on the rows.
private struct LineActions: View {
    @Bindable var model: MenuModel
    let menu: RowActionsMenu
    let pointer: PointerTrack

    var body: some View {
        let pointing = model.pointedActions(pointer)
        ScrollViewReader { proxy in
            ScrollView {
                RowActionsList(menu: menu, pointing: pointing).padding(.horizontal, 2).padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            .scrollsToSelection(pointing) { Cut.scroll(proxy, from: $0, to: $1, in: menu.visible) }
        }
    }
}

// MARK: - Foot

/// The foot: at a root search the kinds Tab steps with their counts (the shown one on the accent's soft fill, a kind at
/// zero quieter, a click shows it as Tab would) and `⇥`; elsewhere where Sven is (Pilot › Install). At its right the keys
/// that matter now, as Instrument's foot draws them.
private struct LineFoot: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel

    var body: some View {
        HStack(spacing: 4) {
            if model.searchingRoot, model.speedTest == nil {
                kinds
            } else if model.nav.branch == .activity, let note = model.footerNote {
                // Activity's refusal, or the force quit waiting for its second ⌘Return, in the place's room (Q399).
                Text(note).foregroundStyle(style.color(\.accentText)).truncationMode(.tail).padding(.leading, 8)
            } else {
                place
            }
            Spacer(minLength: 12)
            HStack(spacing: 14) {
                ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in InstrumentHint(hint: hint) }
            }
            .fixedSize()
        }
        .styleText(\.caption).lineLimit(1)
        .padding(.leading, 10).padding(.trailing, 14)
        .frame(height: MenuPanelSize.s(42))
        .overlay(alignment: .top) { InstrumentRule() }
    }

    /// The keys. At a root search the kinds already say Tab and the line says what Return does, so neither repeats here
    /// and the kinds keep their whole words.
    private var hints: [KeyHint] {
        if let speed = model.speedTest { return SpeedTestView.hints(speed) }
        let all = model.footer + model.footerTrailing + model.footerCommands
        guard model.searchingRoot else { return Array(all.prefix(4)) }
        return all.filter { !$0.key.contains("Tab") && !$0.key.contains("⇥") && $0.key != "↵" }
    }

    private var kinds: some View {
        let quiet = ClassicKinds.quiet(style)
        return HStack(spacing: 2) {
            ForEach(Array(MenuEntry.Kind.tabOrder.enumerated()), id: \.offset) { _, kind in
                let on = model.nav.only == kind, count = ClassicKinds.count(of: kind, model)
                Button { model.show(kind) } label: {
                    HStack(spacing: 5) {
                        Text(MenuModel.title(of: kind).lowercased())
                        if let count { Text(count).monospacedDigit() }
                    }
                    .foregroundStyle(style.color(on ? \.accentText : count == "0" ? quiet : \.text2))
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(on ? style.color(\.accentSoft) : .clear, in: .rect(cornerRadius: 5))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Text("⇥").foregroundStyle(style.color(\.text3)).padding(.leading, 4).accessibilityHidden(true)
        }
        .fixedSize()
    }

    private var place: some View {
        HStack(spacing: 6) {
            InstrumentMark(size: 13).foregroundStyle(style.color(\.text3))
            Text("Pilot").foregroundStyle(style.color(\.text2))
            ForEach(Array(crumbs.enumerated()), id: \.offset) { _, crumb in
                Text("›").foregroundStyle(style.color(\.text3))
                Text(crumb).foregroundStyle(style.color(\.text3))
            }
        }
        .padding(.leading, 8)
    }

    private var crumbs: [String] {
        let nav = model.nav
        if nav.isList { return ["Pick"] }
        if let purpose = model.chip?.purpose, purpose != .emojiCategory { return ["Translate", purpose == .translateFrom ? "From" : "To"] }
        return nav.path.map(\.title)
    }
}

// MARK: - Preview slot

/// Beside the list in the Files view, the selected file's preview (FilePreviewPane, spec file-search-v2 T2) behind a
/// hairline, as Classic hosts it; nothing anywhere else, so the list keeps the whole width.
private struct LinePreviewSlot: View {
    let model: MenuModel
    var body: some View {
        if model.previewsFile, model.nav.actions == nil {
            InstrumentRule(vertical: true)
            FilePreviewPane(path: model.nav.selected?.target.filePath).frame(width: FilePreviewPane.width)
        }
    }
}
