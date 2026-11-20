import AppKit
import PilotCore
import SwiftUI
import UniformTypeIdentifiers

/// The format bar over a selection (UI redesign T26, S6 A, round 1 shot 6a; Apple Notes' styles, Sven 2026-11-20): Aa
/// opens the paragraph styles (NotesStylesMenu), then bold, italic, underline and strikethrough, then code, the bulleted
/// list, the checklist and the link, each typing its Markdown (MarkdownFormat, with its key). A format the selection
/// already has is lit.
struct NotesFormatBar: View {
    @Environment(\.style) var style
    let handle: NotesEditorHandle
    /// The note's words and where the selection is: a change in either redraws the bar, so what is lit follows an edit
    /// and a selection moved.
    var text = ""
    var selection: CGRect = .zero
    /// The Aa menu, open under the bar (NotesEditor draws it).
    @Binding var styling: Bool
    /// The button under the pointer: a format, or nil with `aaHovered` for Aa.
    @State var hovered: MarkdownFormat?
    @State var aaHovered = false

    /// Its size, to keep it inside the note (NotesEditor): 3 pt round the Aa button (40), two rules (7 each) and eight
    /// buttons (28 each).
    static let size = CGSize(width: 3 + 40 + 7 + 4 * 28 + 7 + 4 * 28 + 3, height: 32)

    /// The bar's groups after Aa, in order: the inline marks, then code, the line formats and the link.
    static let groups: [[MarkdownFormat]] = [[.bold, .italic, .underline, .strike], [.code, .bullets, .checklist, .link]]

    var body: some View { bar }

    private var bar: some View {
        let lit = Self.lit(handle.held)
        return HStack(spacing: 0) {
            aa
            ForEach(Self.groups, id: \.self) { group in
                InstrumentRule(vertical: true, role: \.line2, length: 16).padding(.horizontal, 3)
                ForEach(group) { button($0, lit: lit.contains($0)) }
            }
        }
        .padding(3)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(style.color(\.panel), in: .rect(cornerRadius: 9, style: .continuous))
        // A pop-up is its ring alone, no shadow (DESIGN.md).
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(style.color(\.line2)) }
        .accessibilityElement(children: .contain).accessibilityLabel("Format")
    }

    /// Aa: the paragraph styles, lit while their menu is open. A press that just closed the menu (on Aa itself) leaves it
    /// closed.
    private var aa: some View {
        Button { if !NotesPopoverWatch.closingPress { styling.toggle() } } label: {
            chip(Text("Aa").font(.system(size: 13, weight: .medium)), width: 40, lit: styling, hovered: aaHovered)
        }
        .buttonStyle(.plain).focusable(false)
        .onHover { aaHovered = $0 }
        .help("Paragraph styles").accessibilityLabel("Paragraph styles")
        .accessibilityAddTraits(styling ? .isSelected : [])
    }

    private func button(_ format: MarkdownFormat, lit: Bool) -> some View {
        Button { handle.apply(format) } label: {
            chip(Image(systemName: format.symbol).font(.system(size: 12, weight: format == .bold ? .semibold : .medium)), width: 28,
                 lit: lit, hovered: hovered == format)
        }
        .buttonStyle(.plain).focusable(false)
        .onHover { hovered = $0 ? format : hovered == format ? nil : hovered }
        .help(help(format)).accessibilityLabel(format.title)
        .accessibilityAddTraits(lit ? .isSelected : [])
    }

    /// A button's face: lit in the accent on its soft fill, raised under the pointer.
    private func chip(_ label: some View, width: CGFloat, lit: Bool, hovered: Bool) -> some View {
        label
            .foregroundStyle(style.color(lit ? \.accentText : hovered ? \.text : \.text2))
            .frame(width: width, height: 26)
            .background { if lit { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(style.color(\.accentSoft)) } }
            .instrumentRaised(hovered && !lit, radius: 6)
            .contentShape(.rect)
    }

    func help(_ format: MarkdownFormat) -> String { format.key.map { "\(format.title)  \($0)" } ?? format.title }

    /// The formats the selection in `view` already has: bold, italic, underline, strikethrough, code or a link round it, a
    /// bullet or check mark on its first line.
    static func lit(_ view: NSTextView?) -> Set<MarkdownFormat> {
        guard let view else { return [] }
        return lit(view.string, selection: view.selectedRange())
    }

    static func lit(_ text: String, selection sel: NSRange) -> Set<MarkdownFormat> {
        let s = text as NSString
        guard sel.location <= s.length else { return [] }
        let line = s.lineRange(for: NSRange(location: sel.location, length: 0))
        var out = Set<MarkdownFormat>()
        // The line's kind, as Aa ticks it: the bar's bulleted list or checklist.
        let kind = MarkdownFormat.lineStyle(s.substring(with: line))
        if kind == .bullets || kind == .checklist { out.insert(kind) }
        // An inline span holds the selection when it covers every picked character, or the caret strictly inside it.
        let words = MarkdownFormat.words(s, sel)
        func around(_ mark: NSRegularExpression) -> Bool {
            mark.matches(in: text, range: line).contains { m in
                words.length > 0 ? NSIntersectionRange(m.range, words) == words : m.range.location < words.location && words.location < NSMaxRange(m.range)
            }
        }
        if around(MarkdownMarks.bold) { out.insert(.bold) }
        if around(MarkdownMarks.italic) { out.insert(.italic) }
        if around(MarkdownMarks.underline) { out.insert(.underline) }
        if around(MarkdownMarks.strike) { out.insert(.strike) }
        if around(MarkdownMarks.code) { out.insert(.code) }
        if around(MarkdownMarks.link) { out.insert(.link) }
        return out
    }
}

/// Aa's list (Apple Notes' paragraph styles, Sven 2026-11-20): Title, Heading, Subheading, Body, Monostyled, Bulleted,
/// Dashed and Numbered List and Block Quote, each drawn in its own look as the note draws it, the selection's line's
/// style ticked, each style's key at the right. A pick converts the picked lines (MarkdownFormat). Drawn in the note, a
/// ring and no shadow (DESIGN.md); it closes as a popover does (NotesPopoverWatch) and on Escape (NotesKey).
struct NotesStylesMenu: View {
    @Environment(\.style) private var style
    let markdown: MarkdownStyle
    /// The selection's line's style, ticked.
    let current: MarkdownFormat?
    let pick: (MarkdownFormat) -> Void
    let close: () -> Void
    @State private var hovered: MarkdownFormat?

    static let width: CGFloat = 264
    /// A row's height: Title's taller, for its face.
    static func rowHeight(_ format: MarkdownFormat) -> CGFloat { format == .title ? 40 : format == .heading ? 34 : 30 }
    /// Its height: the rows, the room between them and its padding.
    static var height: CGFloat { MarkdownFormat.styles.map(rowHeight).reduce(12, +) + CGFloat(MarkdownFormat.styles.count - 1) }

    var body: some View {
        VStack(spacing: 1) {
            ForEach(MarkdownFormat.styles) { format in
                Button { pick(format) } label: { row(format) }
                    .buttonStyle(.plain).focusable(false)
                    .onHover { hovered = $0 ? format : hovered == format ? nil : hovered }
                    .accessibilityLabel(format.title)
                    .accessibilityHint(format.key.map { "Key \($0)" } ?? "")
                    .accessibilityAddTraits(format == current ? .isSelected : [])
            }
        }
        .padding(6)
        .frame(width: Self.width)
        .background(style.color(\.panel), in: .rect(cornerRadius: 11, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(style.color(\.line2)) }
        .background(NotesPopoverWatch(close: close))
        .accessibilityElement(children: .contain).accessibilityLabel("Paragraph styles")
    }

    private func row(_ format: MarkdownFormat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style.color(\.accent)).opacity(format == current ? 1 : 0).frame(width: 14).accessibilityHidden(true)
            sample(format).lineLimit(1)
            Spacer(minLength: 8)
            if let key = format.key {
                Text(key).styleText(\.mono).foregroundStyle(style.color(\.text3)).fixedSize().accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8).frame(height: Self.rowHeight(format))
        .instrumentRaised(hovered == format, radius: 7)
        .contentShape(.rect)
    }

    /// The style's name in its own look: the note's faces, a list's mark before it, a quote's bar beside it.
    @ViewBuilder private func sample(_ format: MarkdownFormat) -> some View {
        if format == .quote {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(markdown.quoteBar)).frame(width: 3, height: 18)
                Text(format.title).font(Font(markdown.body)).foregroundStyle(Color(markdown.quote))
            }
        } else {
            let face: NSFont = switch format {
            case .title: markdown.h1.font
            case .heading: markdown.h2.font
            case .subheading: markdown.bold
            case .mono: markdown.code
            default: markdown.body
            }
            let lead = [MarkdownFormat.bullets: "•  ", .dashes: "–  ", .numbers: "1.  "][format] ?? ""
            (Text(lead).foregroundStyle(Color(markdown.quote)) + Text(format.title).foregroundStyle(Color(markdown.text))).font(Font(face))
        }
    }
}

/// What the note head's + puts in a note (round 2 shot 6c-insert; Open question 9: the drawn keys, Table left out; the
/// sketch removed, Sven 2026-11-20).
enum NotesInsert: String, CaseIterable, Identifiable {
    case checklist, picture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .checklist: "Checklist"
        case .picture: "Picture…"
        }
    }

    var symbol: String {
        switch self {
        case .checklist: MarkdownFormat.checklist.symbol
        case .picture: "photo"
        }
    }

    /// Its key as the row shows it: the checklist's is MarkdownFormat's ⌘⇧L; Picture has none.
    var key: String? {
        switch self {
        case .checklist: MarkdownFormat.checklist.key
        case .picture: nil
        }
    }

    /// Puts it in the note the handle holds, at the caret.
    @MainActor func perform(_ handle: NotesEditorHandle) {
        switch self {
        case .checklist: handle.apply(.checklist)
        case .picture: Self.choosePictures(handle)
        }
    }

    /// Picture…: the file sheet over the note, its pictures saved and linked as a paste or a drop is (insertPictures).
    @MainActor private static func choosePictures(_ handle: NotesEditorHandle) {
        guard let view = handle.view, view.isEditable else { return }
        let open = NSOpenPanel()
        open.allowedContentTypes = [.image]
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.prompt = "Insert"
        open.message = "Pick pictures to put in the note."
        let insert: (NSApplication.ModalResponse) -> Void = { [weak view] answer in
            guard answer == .OK, let view, !open.urls.isEmpty else { return }
            let board = NSPasteboard(name: NSPasteboard.Name("dev.banozz.pilot.notes.insert"))
            board.clearContents()
            board.writeObjects(open.urls as [NSURL])
            _ = view.insertPictures(from: board)
            board.clearContents()
            view.window?.makeFirstResponder(view)
        }
        if let window = view.window { open.beginSheetModal(for: window, completionHandler: insert) } else { insert(open.runModal()) }
    }
}

/// The Insert menu under the head's +: Checklist and Picture…, each its own glyph, its name and its key. Drawn
/// in the panel, a ring and no shadow (DESIGN.md), so it renders offscreen as Pilot shows it.
struct NotesInsertMenu: View {
    @Environment(\.style) private var style
    @Binding var hovered: NotesInsert?
    let pick: (NotesInsert) -> Void

    static let width: CGFloat = 232

    var body: some View {
        VStack(spacing: 2) {
            ForEach(NotesInsert.allCases) { item in
                Button { pick(item) } label: { row(item) }
                    .buttonStyle(.plain).focusable(false)
                    .onHover { hovered = $0 ? item : hovered == item ? nil : hovered }
                    .accessibilityLabel(item.title)
                    .accessibilityHint(item.key.map { "Key \($0)" } ?? "")
            }
        }
        .padding(6)
        .frame(width: Self.width)
        .background(style.color(\.panel), in: .rect(cornerRadius: 11, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(style.color(\.line2)) }
        .accessibilityElement(children: .contain).accessibilityLabel("Insert")
    }

    private func row(_ item: NotesInsert) -> some View {
        let on = hovered == item
        return HStack(spacing: 10) {
            Image(systemName: item.symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(style.color(on ? \.accent : \.text2)).frame(width: 18).accessibilityHidden(true)
            Text(item.title).styleText(\.body).foregroundStyle(style.color(\.text)).lineLimit(1)
            Spacer(minLength: 8)
            if let key = item.key {
                Text(key).styleText(\.mono).foregroundStyle(style.color(\.text3)).fixedSize().accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .instrumentRaised(on, radius: 7)
        .contentShape(.rect)
    }
}
