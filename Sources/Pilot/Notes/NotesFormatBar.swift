import AppKit
import PilotCore
import SwiftUI
import UniformTypeIdentifiers

/// The format bar over a selection (UI redesign T26, S6 A, round 1 shot 6a): Aa for the heading, then bold, italic and
/// code, then the bulleted list, the checklist and the link, each typing its Markdown (MarkdownFormat, with its key). A
/// format the selection already has is lit. No underline or strikethrough: Markdown has no underline, and strikethrough
/// is out of the spec's scope.
struct NotesFormatBar: View {
    @Environment(\.style) var style
    let handle: NotesEditorHandle
    /// The note's words and where the selection is: a change in either redraws the bar, so what is lit follows an edit
    /// and a selection moved.
    var text = ""
    var selection: CGRect = .zero
    @State var hovered: MarkdownFormat?

    /// Its size, to keep it inside the note (NotesEditor): 3 pt round the Aa button (40), two rules (7 each) and six
    /// buttons (28 each).
    static let size = CGSize(width: 3 + 40 + 7 + 3 * 28 + 7 + 3 * 28 + 3, height: 32)

    /// The bar's groups, in order: the heading, the inline formats, the line formats and the link.
    static let groups: [[MarkdownFormat]] = [[.heading], [.bold, .italic, .code], [.bullets, .checklist, .link]]

    var body: some View { bar }

    private var bar: some View {
        let lit = Self.lit(handle.view)
        return HStack(spacing: 0) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { InstrumentRule(vertical: true, role: \.line2, length: 16).padding(.horizontal, 3) }
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

    private func button(_ format: MarkdownFormat, lit: Bool) -> some View {
        Button { handle.apply(format) } label: {
            Group {
                if format == .heading {
                    Text("Aa").font(.system(size: 13, weight: .medium))
                } else {
                    Image(systemName: format.symbol).font(.system(size: 12, weight: format == .bold ? .semibold : .medium))
                }
            }
            .foregroundStyle(style.color(lit ? \.accentText : hovered == format ? \.text : \.text2))
            .frame(width: format == .heading ? 40 : 28, height: 26)
            .background { if lit { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(style.color(\.accentSoft)) } }
            .instrumentRaised(hovered == format && !lit, radius: 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain).focusable(false)
        .onHover { hovered = $0 ? format : hovered == format ? nil : hovered }
        .help(help(format)).accessibilityLabel(format.title)
        .accessibilityAddTraits(lit ? .isSelected : [])
    }

    func help(_ format: MarkdownFormat) -> String { format.key.map { "\(format.title)  \($0)" } ?? format.title }

    /// The formats the selection in `view` already has: bold, italic, code or a link round it, a heading, bullet or check
    /// mark on its first line.
    static func lit(_ view: NSTextView?) -> Set<MarkdownFormat> {
        guard let view else { return [] }
        return lit(view.string, selection: view.selectedRange())
    }

    static func lit(_ text: String, selection sel: NSRange) -> Set<MarkdownFormat> {
        let s = text as NSString
        guard sel.location <= s.length else { return [] }
        let line = s.lineRange(for: NSRange(location: sel.location, length: 0))
        let body = s.substring(with: line)
        let trimmed = String(body.drop { $0 == " " || $0 == "\t" })
        var out = Set<MarkdownFormat>()
        if MarkdownFormat.headingLevel(body) > 0 { out.insert(.heading) }
        func has(_ mark: NSRegularExpression, _ line: String) -> Bool {
            mark.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
        if has(MarkdownFormat.checkMark, trimmed) { out.insert(.checklist) } else if has(MarkdownFormat.bulletMark, trimmed) { out.insert(.bullets) }
        // An inline span holds the selection when it covers every picked character, or the caret strictly inside it.
        let words = MarkdownFormat.words(s, sel)
        func around(_ mark: NSRegularExpression) -> Bool {
            mark.matches(in: text, range: line).contains { m in
                words.length > 0 ? NSIntersectionRange(m.range, words) == words : m.range.location < words.location && words.location < NSMaxRange(m.range)
            }
        }
        if around(MarkdownMarks.bold) { out.insert(.bold) }
        if around(MarkdownMarks.italic) { out.insert(.italic) }
        if around(MarkdownMarks.code) { out.insert(.code) }
        if around(MarkdownMarks.link) { out.insert(.link) }
        return out
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
