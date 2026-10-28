import Clipboard
import PilotCore
import SwiftUI

/// The clipboard panel in Toybox (card agent-bo-95423182, batch 6), the notes panel's idiom: the clipboard's page tile and
/// the search in Fredoka (the prompt Sven is in as a crumb on the sun's soft fill), the kinds and tags as chips in a
/// panel well with the order at its right, then the copies on the sunk fill left of an ink rule and the picked one's
/// preview on the panel, the menu's foot of keycaps under all. A copy's row is its kind's candy tile (a colour its own
/// swatch), its first line with what was searched underlined in the sun's edge, its tags, its app and its time; the
/// current one a sun keycap. The same model, keys and words as ClipboardPanelView; its block is the panel's pop face
/// (PopSurface).
struct ToyClipboardPanel: View {
    @Environment(\.style) private var style
    let panel: ClipboardPanelView
    let pointer: PointerTrack
    var searchFocused: FocusState<Bool>.Binding
    var editorFocused: FocusState<Bool>.Binding

    private var model: PanelModel { panel.model }

    /// The panel's face, and the list's share of it.
    static let size = CGSize(width: 820, height: 500), list: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            // Cmd+/'s list takes the panel's place above the foot (Sven, Build 79): the rest stays laid out under it,
            // unseen, so Escape brings it back as it was and the field keeps its focus.
            VStack(spacing: 0) {
                search
                ToyRule()
                filters
                ToyRule()
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if model.rows.isEmpty { EmptyTab(tab: model.tab, query: model.query) } else { rows }
                        ReadingText.under(model)
                    }
                    .frame(width: Self.list).frame(maxHeight: .infinity).background(style.color(\.sunken))
                    ToyRule(vertical: true)
                    ToyClipPreview(panel: panel, pointer: pointer, editorFocused: editorFocused)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 22).padding(.vertical, 18)
                }
                .frame(maxHeight: .infinity)
            }
            .opacity(model.showsKeys ? 0 : 1).allowsHitTesting(!model.showsKeys).accessibilityHidden(model.showsKeys)
            .overlay { if model.showsKeys { ToyKeysSheet(groups: panel.keyGroups) } }
            // The longest hints that fit: nine keys do not at the panel's width.
            ViewThatFits(in: .horizontal) {
                ForEach([9, 6, 4], id: \.self) { ToyFoot(hints: Array(panel.hints.prefix($0)), note: panel.pickedNote) }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // MARK: Search line

    /// The clipboard's page tile, or the prompt Sven is in as a crumb; the field in Fredoka; how many copies the list
    /// holds as a tag.
    private var search: some View {
        HStack(spacing: 14) {
            if let crumb = model.prompt?.crumb {
                ToyCrumb(symbol: crumb.symbol, text: crumb.text)
            } else {
                ToyTile(symbol: "doc.on.clipboard", color: Toy.pageTile(.clipboard, style), size: 36).accessibilityHidden(true)
            }
            ZStack(alignment: .leading) {
                if panel.field.wrappedValue.isEmpty {
                    Text(panel.fieldPrompt).font(Toy.fredoka(22)).foregroundStyle(style.color(\.text3)).lineLimit(1).allowsHitTesting(false)
                }
                TextField("", text: panel.field).textFieldStyle(.plain).font(Toy.fredoka(22))
                    .foregroundStyle(style.color(\.text)).tint(style.color(\.accentText)).focused(searchFocused)
                    .accessibilityLabel(panel.fieldPrompt)
            }
            Spacer(minLength: 8)
            if model.prompt == nil {
                let count = model.rows.count
                ToyTag(text: "\(count) \(count == 1 ? "copy" : "copies")")
            }
        }
        .padding(.horizontal, 18).frame(height: 66)
    }

    /// The kinds and tags (ClipTabs, in Toybox's chips), then the order ⌘S steps through.
    private var filters: some View {
        HStack(spacing: 12) {
            ClipTabs(tabs: model.tabs, picked: model.tab, onPick: { model.tab = $0 })
            HStack(spacing: 6) {
                Text(model.order.sort.title).font(Toy.nunito(800, 12.5)).foregroundStyle(style.color(\.text2))
                Image(systemName: model.order.reversed ? "arrow.up" : "arrow.down").font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(style.color(\.text3))
                ToyMenuCap(label: "⌘", height: 24)
                ToyMenuCap(label: "S", height: 24)
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sorted by \(model.order.sort.title.lowercased()), \(model.order.reversed ? "oldest" : "newest") first; Command S for the next")
            .padding(.trailing, 18)
        }
        .frame(height: 54)
    }

    // MARK: Rows

    private var rows: some View {
        let leaving = panel.leavingTag?.id
        let pointing = PointerList(track: pointer, name: "rows", selection: { model.cursor }, hover: { model.hover(at: $0) },
                                   click: { model.click(at: $0, returnCopies: panel.returnCopies) })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, clip in
                        let on = index == model.cursor && leaving == nil
                        VStack(alignment: .leading, spacing: 0) {
                            if index == 0 || clip.pinned != model.rows[index - 1].pinned {
                                ToyEyebrow(text: clip.pinned ? "Pinned" : "Recent").accessibilityAddTraits(.isHeader)
                                    .padding(.horizontal, 10).padding(.top, index == 0 ? 12 : 16).padding(.bottom, 6)
                            }
                            ToyClipRow(clip: clip, title: marked(clip.title, on: on), time: panel.time(clip), number: model.pickNumber(clip),
                                       thumbnail: model.thumbnail(clip), code: model.codes.code(of: clip), on: on, leaving: leaving)
                                .pointerRow(pointing, index)
                        }
                        .id(clip.id)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            .scrollsToSelection(pointing) { _, _ in if let id = model.selected?.id { proxy.scrollTo(id) } }
        }
    }

    /// The row's first line with each searched word underlined in the sun's edge (the ink on the sun row), as the menu's.
    private func marked(_ title: String, on: Bool) -> AttributedString {
        let line = String(title.prefix(300).prefix { $0 != "\n" })
        var text = AttributedString(line)
        for range in model.parsed.highlights(in: line) {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].underlineStyle = Text.LineStyle(pattern: .solid, color: style.color(on ? \.outline : \.accentEdge))
        }
        return text
    }
}

/// One copy: its kind's candy tile (a colour its own swatch, an image its thumbnail), its first line, its tags in mono, the app it came from,
/// then its pick number as a keycap or its time. The current one a sun keycap; a tag the delete confirm asks about
/// struck out.
private struct ToyClipRow: View {
    @Environment(\.style) private var style
    let clip: StoredClip
    let title: AttributedString
    let time: String
    let number: Int?
    let thumbnail: NSImage?
    /// Its QR code once its preview read one (Sven, Q398): the row says what the preview offers.
    let code: ClipCode?
    let on: Bool
    var leaving: Int64?

    var body: some View {
        let ink = on ? style.color(\.onAccent) : style.color(\.text)
        let soft = on ? ink.opacity(0.75) : style.color(\.text3)
        HStack(spacing: 10) {
            tile
            Text(title).font(clip.kind == .colour ? Toy.mono(12.5) : Toy.nunito(800, 13.5)).foregroundStyle(ink).layoutPriority(1)
            Spacer(minLength: 6)
            ForEach(clip.tags, id: \.id) { tag in
                Text("#\(tag.name)").font(Toy.mono(11)).strikethrough(tag.id == leaving)
                    .foregroundStyle(tag.id == leaving ? style.color(\.text4) : soft).fixedSize()
            }
            if let code { Chip(text: code.title, symbol: "qrcode") }
            if let icon = clip.sourceApp.flatMap(AppsModule.icon(bundle:)) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
            }
            Group {
                if let number { ToyMenuCap(label: "\(number)", height: 24).accessibilityLabel("pick \(number)") }
                else { Text(time).font(Toy.mono(11)).foregroundStyle(soft) }
            }
            .frame(minWidth: 38, alignment: .trailing).fixedSize()
        }
        .lineLimit(1)
        .padding(.leading, 6).padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
        .toySunRow(on, radius: 13, style: style)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(clip.kind.label), \(String(title.characters))")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The kind's glyph on its candy soft fill, or a colour's swatch, or an image's thumbnail, in the ink outline.
    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Group {
            if let swatch = clip.swatch { Color(hex: swatch) }
            else if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill() }
            else {
                Toy.moduleSoft(Toy.module(of: clip.kind), style)
                    .overlay { Image(systemName: clip.kind.symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(style.color(\.text)) }
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(shape)
        .overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
        .accessibilityHidden(true)
    }
}

/// The preview beside the list: the copy's first line in Fredoka over its facts and what it holds (text in mono on a
/// sunk well, a colour's swatch and spellings, an image in the ink outline); several picks in their order; or what a
/// prompt asks, its choices rows with the current one a sun keycap.
private struct ToyClipPreview: View {
    @Environment(\.style) private var style
    let panel: ClipboardPanelView
    let pointer: PointerTrack
    var editorFocused: FocusState<Bool>.Binding

    private var model: PanelModel { panel.model }

    var body: some View {
        switch model.prompt {
        case .tag:
            let have = model.sharedTagIDs, tags = model.tagChoices
            choices(heading: model.targets.count == 1 ? "Tag 1 item" : "Tag \(model.targets.count) items", count: tags.count,
                    empty: "Type a name for a new tag.") { index, on in
                switch tags[index] {
                case .create(let name):
                    Image(systemName: "plus").font(.system(size: 13, weight: .heavy)).frame(width: 16)
                    Text("New tag “\(name)”")
                case .existing(let tag):
                    Text("#").font(Toy.mono(13)).opacity(on ? 0.75 : 0.6).frame(width: 16)
                    Text(tag.name)
                    Spacer(minLength: 0)
                    if have.contains(tag.id) { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)) }
                }
            }
        case .actions:
            let actions = model.actionChoices
            choices(heading: model.targets.count == 1 ? "1 item" : "\(model.targets.count) items", count: actions.count,
                    empty: "No action by that name.") { index, on in
                Text(actions[index].title)
                Spacer(minLength: 0)
                if let key = actions[index].key {
                    HStack(spacing: 4) { ForEach(ToyCaps.hint(key), id: \.self) { ToyMenuCap(label: $0, height: 24) } }
                }
            }
        case .rename:
            VStack(alignment: .leading, spacing: 8) {
                ToyEyebrow(text: "Rename")
                Text("The list shows this name instead of the text, and the search finds it. Empty shows the text again.")
                    .font(Toy.nunito(700, 13.5)).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
            }
        case .deleteTag(let tag):
            let count = model.rows.count
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) { ToyDot(color: style.color(\.problem)); ToyEyebrow(text: "Delete tag") }
                Text("#\(tag.name)").font(Toy.fredoka(24)).foregroundStyle(style.color(\.text)).lineLimit(1).padding(.top, 10)
                Text(count == 1 ? "Comes off 1 item. It stays in the history." : "Comes off \(count) items. They stay in the history.")
                    .font(Toy.nunito(700, 13.5)).foregroundStyle(style.color(\.text2)).padding(.top, 6)
            }
        case .edit:
            VStack(alignment: .leading, spacing: 10) {
                ToyEyebrow(text: "Edit text")
                TextEditor(text: Binding(get: { model.promptText }, set: { model.type($0) }))
                    .font(Toy.mono(12.5)).foregroundStyle(style.color(\.text)).scrollContentBackground(.hidden)
                    .tint(style.color(\.accentText))
                    .padding(10).toyWell(radius: 14)
                    .focused(editorFocused)
                    .onAppear { editorFocused.wrappedValue = true }
            }
        case nil:
            items
        }
    }

    @ViewBuilder private var items: some View {
        if let picked = model.picked {
            VStack(alignment: .leading, spacing: 10) {
                ToyEyebrow(text: "Picked")
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(picked.enumerated()), id: \.element.id) { index, clip in pick(index + 1, clip) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .scrollIndicators(.never)
                .toyWell(radius: 14)
                Text("\(model.pickCount) items, pasted in this order").font(Toy.nunito(700, 12.5)).foregroundStyle(style.color(\.text3))
            }
        } else if let clip = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                Text(ClipHighlight.lit(clip.title.prefix { $0 != "\n" }, model.parsed, style.color(\.accent))).font(Toy.fredoka(20)).foregroundStyle(style.color(\.text)).lineLimit(1)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    fact("From") { Text(panel.source(clip) ?? "—") }
                    fact("Kind") { Text(clip.kind.label) }
                    fact("Copied") { Text(panel.time(clip) + (clip.copyCount > 1 ? " · \(clip.copyCount) times" : "")).monospacedDigit() }
                }
                .font(Toy.nunito(700, 13)).foregroundStyle(style.color(\.text2)).padding(.top, 10)
                Group {
                    if let swatch = clip.swatch {
                        HStack(spacing: 16) {
                            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
                            shape.fill(Color(hex: swatch)).frame(width: 84, height: 84)
                                .overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(StoredClip.colourValues(swatch), id: \.self) { Text($0) }
                            }
                            .font(Toy.mono(12.5)).foregroundStyle(style.color(\.text2)).textSelection(.enabled)
                        }
                    } else if let image = model.preview {
                        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                        VStack(alignment: .leading, spacing: 10) {
                            Image(nsImage: image).resizable().scaledToFit().litBoxes(model.previewBoxes, style.color(\.accent)).clipShape(shape)
                                .overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
                            if let code = model.codes.code(of: clip) {
                                HStack(spacing: 8) {
                                    Button { model.useCode() } label: { Chip(text: code.title, symbol: "qrcode") }.buttonStyle(.plain)
                                        .help("\(code.title) from the QR code")
                                    Text(code.payload).font(Toy.mono(12)).foregroundStyle(style.color(\.text2)).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            if let text = clip.recognised, !text.isEmpty { textBlock(text).frame(maxHeight: 110) }
                            else if clip.isReadingText { ReadingText(line: ReadingText.preview) }
                        }
                    } else {
                        textBlock(clip.text)
                    }
                }
                .padding(.top, 16)
                if clip.swatch == nil, model.preview == nil {
                    Text("\(clip.text.count) characters").font(Toy.mono(11.5)).foregroundStyle(style.color(\.text3)).padding(.top, 8)
                }
            }
        } else {
            Color.clear
        }
    }

    /// One pick in the picked list: its number as a keycap, as the rows show it, then its thumbnail in the ink outline
    /// (a frame of its size while it is made) or its first line in mono.
    private func pick(_ number: Int, _ clip: StoredClip) -> some View {
        HStack(alignment: clip.kind == .image ? .top : .center, spacing: 10) {
            ToyMenuCap(label: "\(number)", height: 24).accessibilityLabel("pick \(number)")
            if clip.kind == .image {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                let image = model.thumbnail(clip)
                Group {
                    if let image { Image(nsImage: image).resizable().scaledToFill() } else { style.color(\.sunken) }
                }
                .frame(width: PanelModel.pickWidth(image), height: PanelModel.pickHeight).clipShape(shape)
                .overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
                .accessibilityLabel("Image")
            } else {
                Text(PanelModel.line(clip)).font(Toy.mono(12.5)).foregroundStyle(style.color(\.text)).lineLimit(1)
            }
        }
    }

    /// A fact's name in the third ink, its value after it.
    private func fact(_ name: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(name).font(Toy.nunito(800, 12)).foregroundStyle(style.color(\.text3))
            value()
        }
    }

    /// A copy's text, scrolling and selectable, in mono on a well sunk into the panel, the search lit and its first match in view.
    private func textBlock(_ text: String) -> some View {
        ScrollView {
            LitText(text: text, query: model.parsed, lit: style.color(\.accent), spacing: 4) {
                $0.font(Toy.mono(12.5)).lineSpacing(4).foregroundStyle(style.color(\.text)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .scrollsToFirstMatch(text, model.parsed)
        .toyWell(radius: 14)
    }

    /// A prompt's list: its eyebrow, then the choices, the current one a sun keycap as the rows are.
    private func choices(heading: String, count: Int, empty: String, @ViewBuilder row: @escaping (Int, Bool) -> some View) -> some View {
        let pointing = PointerList(track: pointer, name: "choices", selection: { model.promptCursor },
                                   hover: { model.hoverChoice(at: $0) }, click: { model.clickChoice(at: $0) })
        return VStack(alignment: .leading, spacing: 8) {
            ToyEyebrow(text: heading)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(0..<count, id: \.self) { index in
                            let on = index == model.promptCursor
                            HStack(spacing: 10) { row(index, on) }
                                .font(Toy.nunito(800, 13.5)).foregroundStyle(style.color(on ? \.onAccent : \.text)).lineLimit(1)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                                .toySunRow(on, radius: 12, style: style)
                                .accessibilityAddTraits(on ? .isSelected : [])
                                .pointerRow(pointing, index).id(index)
                        }
                    }
                }
                .scrollIndicators(.never)
                .scrollsToSelection(pointing) { _, new in if let new { proxy.scrollTo(new) } }
            }
            if count == 0 { Text(empty).font(Toy.nunito(700, 12.5)).foregroundStyle(style.color(\.text3)) }
            Spacer(minLength: 0)
        }
    }
}

/// Cmd+/'s list in the panel's place in Toybox (footer A, Sven, Q396; alone, Build 79): every key in its group under an
/// eyebrow, the words left and the keycaps right, on the panel's own face (its fill, or its glass). The rows share the
/// panel's height in even slots, level across the columns, so the list fills the panel at any size (Sven, Build 82).
struct ToyKeysSheet: View {
    @Environment(\.style) private var style
    let groups: [(title: String, keys: [KeyHint])]

    var body: some View {
        let slots = groups.map(\.keys.count).max() ?? 0
        HStack(alignment: .top, spacing: 40) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 0) {
                    ToyEyebrow(text: group.title).accessibilityAddTraits(.isHeader).padding(.bottom, 6)
                    ForEach(0..<slots, id: \.self) { i in
                        // A short column keeps its empty slots, so its rows stand level with the long ones.
                        Group { if i < group.keys.count { row(group.keys[i]) } else { row(groups[0].keys[0]).hidden() } }
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(style.toyNunito(700, 15.5)).foregroundStyle(style.color(\.text2)).lineLimit(1)
        .padding(.horizontal, 32).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ hint: KeyHint) -> some View {
        HStack(spacing: 8) {
            Text(hint.label.prefix(1).uppercased() + hint.label.dropFirst())
            Spacer(minLength: 8)
            HStack(spacing: 4) { ForEach(ToyCaps.hint(hint.key), id: \.self) { ToyMenuCap(label: $0, height: 24) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(hint.label) \(hint.key)")
    }
}
