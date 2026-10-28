import Clipboard
import PilotCore
import SwiftUI

/// The clipboard panel in Instrument (card agent-bo-95423181, ADR 0008), the menu's idiom: the glyph and the search on a
/// 58 pt line (the prompt Sven is in as a crumb in the glyph's place), the kinds and tags on a sunk track under it with
/// the order at its right, then the copies beside their preview on a hairline, and a foot with where Sven is and what the
/// keys do. A copy's row is its app's icon, its first line with what was searched underlined, its kind and its time in
/// mono; the current one raised with a tick in the signal colour. The same model, keys and words as ClipboardPanelView;
/// its face, corner, ring and shadow are the panel's (PopSurface).
struct InstrumentClipboardPanel: View {
    @Environment(\.style) private var style
    let panel: ClipboardPanelView
    let pointer: PointerTrack
    var searchFocused: FocusState<Bool>.Binding
    var editorFocused: FocusState<Bool>.Binding

    private var model: PanelModel { panel.model }

    /// The panel's face, and the list's share of it.
    static let size = CGSize(width: 800, height: 480), list: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            // Cmd+/'s list takes the panel's place above the foot (Sven, Build 79): the search, tabs, rows and preview
            // stay laid out under it, unseen, so Escape brings them back as they were and the field keeps its focus.
            VStack(spacing: 0) {
                search
                filters
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if model.showsSnippets {
                            if model.snippetRows.isEmpty {
                                EmptyTab(tab: .kind(.snippet), query: model.query, newSnippet: { model.run?(.editSnippets) })
                            } else { snippetRows }
                        } else if model.rows.isEmpty { EmptyTab(tab: model.tab, query: model.query) } else { rows }
                        ReadingText.under(model)
                    }
                    .frame(width: Self.list)
                    InstrumentRule(vertical: true)
                    InstrumentClipPreview(panel: panel, pointer: pointer, editorFocused: editorFocused)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 20).padding(.vertical, 18)
                }
                .frame(maxHeight: .infinity)
            }
            .opacity(model.showsKeys ? 0 : 1).allowsHitTesting(!model.showsKeys).accessibilityHidden(model.showsKeys)
            .overlay { if model.showsKeys { InstrumentKeysSheet(groups: panel.keyGroups) } }
            InstrumentFoot(hints: panel.hints, note: panel.pickedNote) {
                Text("Clipboard").foregroundStyle(style.color(\.text2))
                Text("›").foregroundStyle(style.color(\.text3))
                Text(model.tab.label).foregroundStyle(style.color(\.text3))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // MARK: Search line

    /// The glyph, or the prompt Sven is in as a crumb; the field in the search face, the caret in the signal colour; how
    /// many copies the list holds, in mono.
    private var search: some View {
        HStack(spacing: 12) {
            if let crumb = model.prompt?.crumb {
                InstrumentCrumb(symbol: crumb.symbol, text: crumb.text)
            } else {
                Image(systemName: "doc.on.clipboard").font(style.font(\.icon)).imageScale(.large).foregroundStyle(style.color(\.text2))
                    .frame(width: 18).accessibilityHidden(true)
            }
            ZStack(alignment: .leading) {
                if panel.field.wrappedValue.isEmpty {
                    Text(panel.fieldPrompt).styleText(\.search).foregroundStyle(style.color(\.text3)).lineLimit(1).allowsHitTesting(false)
                }
                TextField("", text: panel.field).textFieldStyle(.plain).styleText(\.search)
                    .foregroundStyle(style.color(\.text)).tint(style.color(\.accent)).focused(searchFocused)
                    .accessibilityLabel(panel.fieldPrompt)
            }
            Spacer(minLength: 8)
            if model.prompt == nil {
                let count = model.showsSnippets ? model.snippetRows.count : model.rows.count
                let noun = model.showsSnippets ? (count == 1 ? "snippet" : "snippets") : count == 1 ? "copy" : "copies"
                Text("\(count) \(noun)").styleText(\.mono).foregroundStyle(style.color(\.text3)).fixedSize()
            }
        }
        .padding(.horizontal, 18).frame(height: 58)
        .overlay(alignment: .bottom) { InstrumentRule() }
    }

    /// The kinds and tags (ClipTabs, in Instrument's drawing), then the order ⌘S steps through.
    private var filters: some View {
        HStack(spacing: 12) {
            ClipTabs(tabs: model.tabs, picked: model.tab, onPick: { model.tab = $0 })
            // Snippets keep the editor's order.
            if !model.showsSnippets { sort }
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) { InstrumentRule() }
    }

    private var sort: some View {
        HStack(spacing: 6) {
            Text(model.order.sort.title).styleText(\.caption).foregroundStyle(style.color(\.text2))
            Image(systemName: model.order.reversed ? "arrow.up" : "arrow.down").font(style.font(\.small)).foregroundStyle(style.color(\.text3))
            InstrumentKeys(caps: ["⌘", "S"], hyper: false)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sorted by \(model.order.sort.title.lowercased()), \(model.order.reversed ? "oldest" : "newest") first; Command S for the next")
        .padding(.trailing, 18)
    }

    // MARK: Rows

    private var rows: some View {
        let leaving = panel.leavingTag?.id
        let pointing = PointerList(track: pointer, name: "rows", selection: { model.cursor }, hover: { model.hover(at: $0) },
                                   click: { model.click(at: $0, returnCopies: panel.returnCopies, command: NSEvent.modifierFlags.contains(.command)) })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, clip in
                        let on = index == model.cursor && leaving == nil
                        VStack(alignment: .leading, spacing: 0) {
                            if index == 0 || clip.pinned != model.rows[index - 1].pinned {
                                InstrumentEyebrow(text: clip.pinned ? "Pinned" : "Recent")
                                    .padding(.horizontal, 12).padding(.bottom, 6)
                                    .frame(maxWidth: .infinity, minHeight: index == 0 ? 26 : 34, alignment: .bottomLeading)
                            }
                            InstrumentClipRow(clip: clip, title: marked(clip.title), time: panel.time(clip), number: model.pickNumber(clip),
                                              thumbnail: model.thumbnail(clip), code: model.codes.code(of: clip), on: on, leaving: leaving)
                                .pointerRow(pointing, index)
                        }
                        .id(clip.id)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .scrollsToSelection(pointing) { _, _ in if let id = model.selected?.id { proxy.scrollTo(id) } }
        }
    }

    /// The Snippets tab's rows under their eyebrow, as the copies sit under theirs.
    private var snippetRows: some View {
        let pointing = PointerList(track: pointer, name: "rows", selection: { model.snippetCursor }, hover: { model.hover(at: $0) },
                                   click: { model.click(at: $0, returnCopies: panel.returnCopies, command: NSEvent.modifierFlags.contains(.command)) })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.snippetRows.enumerated()), id: \.element.id) { index, snippet in
                        VStack(alignment: .leading, spacing: 0) {
                            if index == 0 {
                                InstrumentEyebrow(text: "Snippets").padding(.horizontal, 12).padding(.bottom, 6)
                                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .bottomLeading)
                            }
                            InstrumentSnippetRow(snippet: snippet, name: marked(snippet.name), on: index == model.snippetCursor)
                                .pointerRow(pointing, index)
                        }
                        .id(snippet.id)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .scrollsToSelection(pointing) { _, _ in if let id = model.selectedSnippet?.id { proxy.scrollTo(id) } }
        }
    }

    /// The row's first line with each searched word underlined in a hairline of the third text colour (the menu's mark).
    private func marked(_ title: String) -> AttributedString {
        let line = String(title.prefix(300).prefix { $0 != "\n" })
        var text = AttributedString(line)
        for range in model.parsed.highlights(in: line) {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].underlineStyle = Text.LineStyle(pattern: .solid, color: style.color(\.text3))
        }
        return text
    }
}

/// One copy (Home's Clipboard rows in mockup A): the app it came from (a colour its swatch, an image its thumbnail), its
/// first line, its tags in mono, its kind, then its pick number or its time. The current one raised on a hairline ring, its tick in the signal
/// colour; a tag the delete confirm asks about struck out.
private struct InstrumentClipRow: View {
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
        HStack(spacing: 10) {
            // A colour or a picture is its own icon, ringed so it shows on any fill.
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
            if let swatch = clip.swatch {
                shape.fill(Color(hex: swatch)).overlay { shape.strokeBorder(style.color(\.imageOutline)) }
                    .frame(width: 14, height: 14).frame(width: 16).accessibilityHidden(true)
            } else if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill().frame(width: 16, height: 16).clipShape(shape)
                    .overlay { shape.strokeBorder(style.color(\.imageOutline)) }.accessibilityHidden(true)
            } else {
                InstrumentAppIcon(bundle: clip.sourceApp, symbol: clip.kind.symbol, size: 16)
            }
            Text(title).styleText(clip.kind == .colour ? \.mono : \.body).foregroundStyle(style.color(\.text)).layoutPriority(1)
            Spacer(minLength: 6)
            ForEach(clip.tags, id: \.id) { tag in
                Text("#\(tag.name)").styleText(\.mono).strikethrough(tag.id == leaving)
                    .foregroundStyle(style.color(tag.id == leaving ? \.text4 : \.text3)).fixedSize()
            }
            if let code { Chip(text: code.title, symbol: "qrcode") }
            Text(clip.kind.label).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize()
            Group {
                if let number { Text("\(number)").styleText(\.key).foregroundStyle(style.color(\.accentText)).accessibilityLabel("pick \(number)") }
                else { Text(time).styleText(\.mono).foregroundStyle(style.color(\.text3)) }
            }
            .frame(minWidth: 40, alignment: .trailing).fixedSize()
        }
        .lineLimit(1)
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
        .instrumentPicked(on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One snippet: the snippets' icon, its name with what was searched underlined, its keyword on a chip; the current one
/// raised as a copy's row is.
private struct InstrumentSnippetRow: View {
    @Environment(\.style) private var style
    let snippet: Snippet
    let name: AttributedString
    let on: Bool

    var body: some View {
        HStack(spacing: 10) {
            InstrumentAppIcon(bundle: nil, symbol: MenuBranch.snippets.look.symbol, size: 16)
            Text(name).styleText(\.body).foregroundStyle(style.color(\.text)).layoutPriority(1)
            Spacer(minLength: 6)
            if !snippet.keyword.isEmpty { Chip(text: snippet.keyword) }
        }
        .lineLimit(1)
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
        .instrumentPicked(on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The preview beside the list: the copy's first line over its facts and what it holds (text in mono on a sunk well, a
/// colour's big swatch, ramp and formats, an image on a hairline); several picks in their order; or what a prompt asks.
private struct InstrumentClipPreview: View {
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
                    Image(systemName: "plus").font(style.font(\.icon)).foregroundStyle(style.color(on ? \.text : \.text2)).frame(width: 16)
                    Text("New tag “\(name)”")
                case .existing(let tag):
                    Text("#").styleText(\.mono).foregroundStyle(style.color(\.text3)).frame(width: 16)
                    Text(tag.name)
                    Spacer(minLength: 0)
                    if have.contains(tag.id) { Image(systemName: "checkmark").font(style.font(\.small)).foregroundStyle(style.color(\.text2)) }
                }
            }
        case .actions:
            let actions = model.actionRows
            choices(heading: model.actionsHeading, count: actions.count, empty: "No action by that name.") { index, _ in
                Text(actions[index].title)
                Spacer(minLength: 0)
                if let key = actions[index].key { InstrumentKeys(caps: InstrumentHint.caps(key), hyper: false) }
            }
        case .rename:
            VStack(alignment: .leading, spacing: 10) {
                InstrumentEyebrow(text: "Rename")
                Text("The list shows this name instead of the text, and the search finds it. Empty shows the text again.")
                    .styleText(\.body).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
            }
        case .deleteTag(let tag):
            let count = model.rows.count
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) { InstrumentTick(); InstrumentEyebrow(text: "Delete tag", role: \.text2) }
                Text("#\(tag.name)").styleText(\.pageTitle).foregroundStyle(style.color(\.text)).lineLimit(1).padding(.top, 12)
                Text(count == 1 ? "Comes off 1 item. It stays in the history." : "Comes off \(count) items. They stay in the history.")
                    .styleText(\.body).foregroundStyle(style.color(\.text2)).padding(.top, 6)
            }
        case .edit:
            VStack(alignment: .leading, spacing: 10) {
                InstrumentEyebrow(text: "Edit text")
                TextEditor(text: Binding(get: { model.promptText }, set: { model.type($0) }))
                    .styleText(\.mono).foregroundStyle(style.color(\.text)).scrollContentBackground(.hidden)
                    .tint(style.color(\.accent))
                    .padding(8).instrumentWell()
                    .focused(editorFocused)
                    .onAppear { editorFocused.wrappedValue = true }
            }
        case nil:
            items
        }
    }

    @ViewBuilder private var items: some View {
        if model.showsSnippets {
            if let snippet = model.selectedSnippet { snippetPreview(snippet) } else { Color.clear }
        } else if let picked = model.picked {
            VStack(alignment: .leading, spacing: 10) {
                InstrumentEyebrow(text: "Picked")
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(picked.enumerated()), id: \.element.id) { index, clip in pick(index + 1, clip) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .instrumentWell()
                Text("\(model.pickCount) items, pasted in this order").styleText(\.mono).foregroundStyle(style.color(\.text3))
            }
        } else if let clip = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                Text(ClipHighlight.lit(clip.title.prefix { $0 != "\n" }, model.parsed, style.color(\.accent))).styleText(\.pageTitle).foregroundStyle(style.color(\.text)).lineLimit(1)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    fact("From") { Text(panel.source(clip) ?? "—").styleText(\.body) }
                    fact("Kind") { Text(clip.kind.label).styleText(\.body) }
                    fact("Copied") {
                        Text(panel.time(clip) + (clip.copyCount > 1 ? " · \(clip.copyCount) times" : "")).styleText(\.mono)
                    }
                }
                .foregroundStyle(style.color(\.text2)).padding(.top, 12)
                Group {
                    if let swatch = clip.swatch {
                        ClipColour(colour: swatch)
                    } else if let image = model.preview {
                        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
                        VStack(alignment: .leading, spacing: 10) {
                            Image(nsImage: image).resizable().scaledToFit().litBoxes(model.previewBoxes, style.color(\.accent))
                                .clipShape(shape).overlay { shape.strokeBorder(style.color(\.imageOutline)) }
                            if let code = model.codes.code(of: clip) {
                                HStack(spacing: 8) {
                                    Button { model.useCode() } label: { Chip(text: code.title, symbol: "qrcode") }.buttonStyle(.plain)
                                        .help("\(code.title) from the QR code")
                                    Text(code.payload).styleText(\.mono).foregroundStyle(style.color(\.text2)).lineLimit(1).truncationMode(.middle)
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
                    Text("\(clip.text.count) characters").styleText(\.mono).foregroundStyle(style.color(\.text3)).padding(.top, 8)
                }
            }
        } else {
            Color.clear
        }
    }

    /// One pick in the picked list: its number as the rows show it, then its thumbnail (a frame of its size while it is
    /// made) or its first line in mono.
    private func pick(_ number: Int, _ clip: StoredClip) -> some View {
        HStack(alignment: clip.kind == .image ? .top : .firstTextBaseline, spacing: 10) {
            Text("\(number)").styleText(\.key).foregroundStyle(style.color(\.accentText)).frame(minWidth: 14, alignment: .trailing)
                .accessibilityLabel("pick \(number)")
            if clip.kind == .image {
                let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
                let image = model.thumbnail(clip)
                Group {
                    if let image { Image(nsImage: image).resizable().scaledToFill() } else { style.color(\.raised) }
                }
                .frame(width: PanelModel.pickWidth(image), height: PanelModel.pickHeight).clipShape(shape)
                .overlay { shape.strokeBorder(style.color(\.imageOutline)) }
                .accessibilityLabel("Image")
            } else {
                Text(PanelModel.line(clip)).styleText(\.mono).foregroundStyle(style.color(\.text)).lineLimit(1)
            }
        }
    }

    /// A snippet as a copy previews: its name over its facts, then its text as saved, placeholders and all.
    private func snippetPreview(_ snippet: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(snippet.name).styleText(\.pageTitle).foregroundStyle(style.color(\.text)).lineLimit(1)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                fact("Keyword") { Text(snippet.keywordFact).styleText(\.mono) }
                fact("Pastes") { Text(snippet.pastesFact).styleText(\.body) }
            }
            .foregroundStyle(style.color(\.text2)).padding(.top, 12)
            textBlock(snippet.text).padding(.top, 16)
            Text("\(snippet.text.count) characters").styleText(\.mono).foregroundStyle(style.color(\.text3)).padding(.top, 8)
        }
    }

    /// A fact's name in the third text colour, its value after it.
    private func fact(_ name: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(name).styleText(\.caption).foregroundStyle(style.color(\.text3))
            value()
        }
    }

    /// A copy's text, scrolling and selectable, in mono on a well sunk into the panel, the search lit and its first match in view.
    private func textBlock(_ text: String) -> some View {
        ScrollView {
            LitText(text: text, query: model.parsed, lit: style.color(\.accent), spacing: 4) {
                $0.styleText(\.mono).lineSpacing(4).foregroundStyle(style.color(\.text)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .scrollsToFirstMatch(text, model.parsed)
        .instrumentWell()
    }

    /// A prompt's list: its eyebrow, then the choices, the current one raised as the rows are.
    private func choices(heading: String, count: Int, empty: String, @ViewBuilder row: @escaping (Int, Bool) -> some View) -> some View {
        let pointing = PointerList(track: pointer, name: "choices", selection: { model.promptCursor },
                                   hover: { model.hoverChoice(at: $0) }, click: { model.clickChoice(at: $0) })
        return VStack(alignment: .leading, spacing: 8) {
            InstrumentEyebrow(text: heading)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(0..<count, id: \.self) { index in
                            let on = index == model.promptCursor
                            HStack(spacing: 10) { row(index, on) }
                                .styleText(\.body).foregroundStyle(style.color(\.text)).lineLimit(1)
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .instrumentRaised(on)
                                .accessibilityAddTraits(on ? .isSelected : [])
                                .pointerRow(pointing, index).id(index)
                        }
                    }
                }
                .scrollsToSelection(pointing) { _, new in if let new { proxy.scrollTo(new) } }
            }
            if count == 0 { Text(empty).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
            Spacer(minLength: 0)
        }
    }
}

/// A copied colour (menu Rail and Classic T10, as a typed hex answers in the menu): the colour across the preview's width
/// with its hex and rgb on it, as tall as the room under the facts allows (56 to 132 pt), its seven-step ramp, then the
/// five formats (StoredClip.colourValues) two by two with SwiftUI's across, each name beside its value and selectable. The menu card's stacked list
/// would push the panel's search line and foot out of its 480 pt.
private struct ClipColour: View {
    @Environment(\.style) private var style
    let colour: UInt32

    var body: some View {
        let formats = StoredClip.colourValues(colour), shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formats[0]).font(style.font(\.mono, size: 20 / style.scale)).tracking(-0.4)
                Text(formats[1]).font(style.font(\.mono, size: 12 / style.scale)).opacity(0.8)
            }
            .foregroundStyle(Color(hex: AnswerInk.ink(on: colour)))
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 132, alignment: .bottomLeading)
            .background(Color(hex: colour), in: shape)
            .overlay { shape.strokeBorder(style.color(\.imageOutline)) }
            .accessibilityElement(children: .combine)
            ColourRamp(colour: colour)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow { format("Hex", formats[0]); format("RGB", formats[1]) }
                GridRow { format("HSL", formats[2]); format("HSB", formats[3]) }
                GridRow { format("SwiftUI", formats[4]).gridCellColumns(2) }
            }
            .padding(.top, 4)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One format: its name in quiet capitals beside its value in mono, shrunk a little rather than cut.
    private func format(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name.uppercased()).font(style.font(\.mono, size: 10.5 / style.scale)).tracking(0.6).foregroundStyle(style.color(\.text3))
                .fixedSize()
            Text(value).styleText(\.mono).foregroundStyle(style.color(\.text2)).lineLimit(1).minimumScaleFactor(0.7)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Cmd+/'s list in the panel's place (footer A, Sven, Q396; alone, Build 79): every key in its group, an eyebrow over
/// each column, the words left and the caps right, on the panel's own face (its fill, or its glass). The rows share the
/// panel's height in even slots, level across the columns, so the list fills the panel at any size (Sven, Build 82).
struct InstrumentKeysSheet: View {
    @Environment(\.style) private var style
    let groups: [(title: String, keys: [KeyHint])]

    var body: some View {
        let slots = groups.map(\.keys.count).max() ?? 0
        HStack(alignment: .top, spacing: 40) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 0) {
                    InstrumentEyebrow(text: group.title).padding(.bottom, 6)
                    ForEach(0..<slots, id: \.self) { i in
                        // A short column keeps its empty slots, so its rows stand level with the long ones.
                        Group { if i < group.keys.count { row(group.keys[i]) } else { row(groups[0].keys[0]).hidden() } }
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(style.font(\.body, size: 15)).lineLimit(1)
        .padding(.horizontal, 32).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ hint: KeyHint) -> some View {
        HStack(spacing: 8) {
            Text(hint.label.prefix(1).uppercased() + hint.label.dropFirst()).foregroundStyle(style.color(\.text2))
            Spacer(minLength: 8)
            HStack(spacing: 3) { ForEach(Array(InstrumentHint.caps(hint.key).enumerated()), id: \.offset) { InstrumentKey(text: $1) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(hint.label) \(hint.key)")
    }
}
