import AppKit
import PilotCore
import SwiftUI

/// The notes panel's editor (card agent-bo-95423042): plain text drawn as its Markdown reads (Q114, Sven 2026-10-15,
/// Obsidian's live preview): the marks (`#`, `**`, `_`, backticks, `>`, fences, table pipes, link brackets) are hidden
/// and drawn as what they make, and show again on the line the caret is on. Headings sized, `-` a dot, `- [ ]` a
/// checkbox a click toggles (done dim and struck through), a quote a callout with a bar, fenced code a panel, a table a
/// grid, and a line that only links a picture drawn with the picture under it (notes round 2). The text stays the
/// Markdown on disk; styling only sets attributes, so nothing typed is ever rewritten. A picture pasted or dropped in is
/// saved in the notes folder's attachments/ and linked.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var style: MarkdownStyle
    /// False for the list's preview and under the Trash confirm: shown, never typed into.
    var editable = true
    /// Takes the keyboard, now and whenever its window becomes key: the open note while the list does not have it.
    var focused = false
    /// The notes folder: where a picture's link is read from and a pasted or dropped one is saved; nil shows none.
    var folder: URL?
    /// Cmd+K's way in (the model's, shared by the panel and the Notes page): it acts on the editor in the key window.
    var handle: NotesEditorHandle?
    /// The format bar's way in: this editor's alone.
    var bar: NotesEditorHandle?
    /// This editor took the keyboard (a click in it, Return from the list): the list lets go of it.
    var onFocus: (() -> Void)?
    /// Where the selection's first line is, for the format bar over it (NotesEditor); nil while nothing is selected.
    var selection: Binding<CGRect?>?

    func makeNSView(context: Context) -> NSScrollView {
        let view = NotesTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.layoutManager?.delegate = view
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        // The inset alone sets the margins, so the first heading lines up with the search line's prompt.
        view.textContainer?.lineFragmentPadding = 0
        view.setAccessibilityLabel("Note")
        view.folder = folder
        view.apply(style)
        view.updateDragTypeRegistration()
        view.handle = handle
        handle?.hold(view)
        bar?.hold(view)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = view
        // A scroll moves the selection under the format bar.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(view, selector: #selector(NotesTextView.reportSelection), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NotesTextView else { return }
        context.coordinator.parent = self
        view.handle = handle
        handle?.hold(view)
        bar?.hold(view)
        view.onFocus = onFocus
        // After the update or keystroke that moved it, never inside SwiftUI's update: on the run loop's next turn, which
        // a render's wait turns too (a main-queue block would wait for the test to end).
        view.selectionChanged = selection.map { binding in
            { rect in
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated { if binding.wrappedValue != rect { binding.wrappedValue = rect } }
                }
            }
        }
        view.isEditable = editable
        view.wantsFocus = focused && editable
        view.takeFocus()
        // Typing restyles in textDidChange; here only a note swapped in, a theme change or a new folder does.
        guard view.style != style || view.string != text || view.folder != folder else { return }
        view.folder = folder
        if view.style != style { view.apply(style) }
        var place: NotesPlace?
        if view.string != text {
            view.string = text
            // A note opened puts the caret at its end, or where it was when the panel hid on it; a preview reads from the top.
            place = editable ? handle?.takePlace(for: text) : nil
            view.setSelectedRange(place?.selection ?? NSRange(location: editable ? (text as NSString).length : 0, length: 0))
            if !editable { view.scroll(.zero) }
        }
        view.restyle()
        if let place {
            // Once the words up to the kept scroll are laid out, so the clip view has the height to scroll to.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    guard let clip = view.enclosingScrollView?.contentView else { return }
                    if let container = view.textContainer {
                        view.layoutManager?.ensureLayout(forBoundingRect: CGRect(origin: place.scroll, size: clip.bounds.size), in: container)
                    }
                    clip.scroll(to: place.scroll)
                    view.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            }
        }
        handle?.settle(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NotesTextView else { return }
            view.restyle()
            parent.text = view.string
        }

        /// Typing starts from plain body text, never a hidden mark's or a checkbox's attributes; the restyle that follows
        /// every keystroke styles it.
        func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                      toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
            (textView as? NotesTextView)?.style.plain ?? newTypingAttributes
        }
    }
}

/// An editor's caret and scroll on the words it held.
struct NotesPlace: Equatable {
    let text: String
    let selection: NSRange
    let scroll: CGPoint
}

/// A hold on the editors a format, Cmd+K's Rename or the format bar acts on. The model's holds the panel's editor and
/// the Notes page's and acts on the one in the key window (the one last given the keyboard when neither is); the format
/// bar's holds its own editor alone, so a click on it never reaches the other surface's.
@MainActor
final class NotesEditorHandle {
    private let views = NSHashTable<NotesTextView>.weakObjects()
    private weak var last: NotesTextView?
    /// Cmd+K's Rename waiting for its note to reach the editor: the title words picked once the text is `text`, in the
    /// window Rename was asked in.
    private var titleFor: (text: String, window: NSWindow?)?

    func hold(_ view: NotesTextView) { views.add(view) }
    /// `view` took the keyboard.
    func focused(_ view: NotesTextView) { last = view }

    /// The editor in the key window, else the one last given the keyboard.
    var view: NotesTextView? {
        views.allObjects.first { $0.isEditable && $0.window?.isKeyWindow == true } ?? last
    }

    func apply(_ format: MarkdownFormat) { view?.format(format) }

    /// Cmd+K's Rename: the note's title words picked, so typing replaces them (the title is the note's first line); now
    /// when the editor already holds `text`, else once the note opened for it arrives.
    func selectTitle(of text: String) {
        let view = view
        titleFor = (text, view?.window ?? NSApp.keyWindow)
        if let view { settle(view) }
    }

    /// The notes panel hides (NotesReopen): the caret and the scroll of its editor on `text`, which the next editor
    /// given those very words takes back.
    func keepPlace(in window: NSWindow?, text: String) {
        guard let window, let view = views.allObjects.first(where: { $0.isEditable && $0.window === window }) else { return }
        kept = NotesPlace(text: text, selection: view.selectedRange(), scroll: view.enclosingScrollView?.contentView.bounds.origin ?? .zero)
    }

    /// The place kept on `text`, handed over once.
    func takePlace(for text: String) -> NotesPlace? {
        guard let place = kept, place.text == text else { return nil }
        kept = nil
        return place
    }

    private var kept: NotesPlace?

    /// After an update: picks the waiting title once the editor in Rename's window holds its note.
    func settle(_ view: NotesTextView) {
        guard let wanted = titleFor, view.string == wanted.text, wanted.window == nil || view.window === wanted.window else { return }
        titleFor = nil
        view.setSelectedRange(MarkdownFormat.titleRange(wanted.text))
        view.window?.makeFirstResponder(view)
        view.scrollRangeToVisible(view.selectedRange())
    }
}

/// The editor's type and colours in a style (round 1 spec), its faces and the theme's colours as the style draws them.
struct MarkdownStyle: Equatable {
    /// A heading level's face, its tracking in points, its line and the room under it.
    struct Heading: Equatable {
        var font: NSFont
        var tracking: CGFloat = 0
        var line: CGFloat
        var after: CGFloat = 0
    }

    var body: NSFont
    var bold: NSFont
    var code: NSFont
    var h1: Heading
    var h2: Heading
    /// A body line's height.
    var line: CGFloat
    /// Side and top margins: the least room either side of the words, and over the first line.
    var inset: NSSize
    /// The words' widest line (direction B: 560 pt in the panel, 620 on the Notes page); the margins grow past it.
    var measure: CGFloat = NotesMeasure.panel
    var codeRadius: CGFloat
    /// A checkbox's side, corner, the room to its text and its tick's size.
    var box: CGFloat
    var boxRadius: CGFloat
    var boxGap: CGFloat
    var tick: CGFloat
    var text: NSColor
    var muted: NSColor
    /// The caret's colour.
    var accent: NSColor
    /// A ticked box's tick.
    var onAccent: NSColor
    var codeFill: NSColor
    var selection: NSColor
    /// A link's words, a ticked box's fill and an unticked box's edge.
    var link: NSColor
    var ticked: NSColor
    var unticked: NSColor
    /// A quote's words and a list's dots and numbers.
    var quote: NSColor
    /// A quote's bar.
    var quoteBar: NSColor
    /// A table's lines.
    var rule: NSColor
    /// A code block's line.
    var codeLine: CGFloat

    /// Instrument's (card agent-bo-95423181): Geist on a 1.6 line, the page title's face for `#` and the panel title's
    /// for `##` and bold, Geist Mono for code on the raised fill; the signal colour for the caret alone (the live
    /// thing), a link in the text colour on a faint underline, a ticked box in the second text colour as a switch that is
    /// not Hyper's.
    @MainActor init(style: StyleTokens, measure: CGFloat = NotesMeasure.panel) {
        self.measure = measure
        // Instrument sets every role in a bundled face.
        // A step over the role's size (Sven 2026-10-15: "the font should be bigger"): body 15, headings 21 and 17.
        func font(_ role: KeyPath<StyleTypography, TypeRole>, size: CGFloat) -> NSFont {
            let role = style.type[keyPath: role]
            guard case .bundled(let face) = role.face else { return .systemFont(ofSize: size) }
            return DisplayFaces.font(face, size: size)
        }
        func color(_ role: KeyPath<StyleColors, Paint>) -> NSColor { Self.color(role, style) }
        let size = style.type.body.size + Self.step
        body = font(\.body, size: size)
        bold = font(\.title, size: size)
        code = font(\.mono, size: style.type.mono.size + Self.step)
        h1 = Heading(font: font(\.pageTitle, size: style.type.pageTitle.size + 6), tracking: style.tracking(\.pageTitle), line: 32, after: 6)
        h2 = Heading(font: font(\.title, size: size + 2), tracking: style.tracking(\.title), line: 28, after: 2)
        line = (size * 1.6).rounded()
        // The title 22 pt under the head (direction B).
        inset = NSSize(width: 24, height: 22)
        codeRadius = style.radii.chip
        (box, boxRadius, boxGap, tick) = (16, style.radii.chip, 10, 9)
        text = color(\.text); muted = color(\.text3); accent = color(\.accent); onAccent = color(\.panel)
        codeFill = color(\.raised); selection = color(\.accentSoft)
        (link, ticked, unticked) = (text, color(\.text2), color(\.text3))
        (quote, quoteBar, rule) = (color(\.text2), color(\.text3), color(\.line2))
        codeLine = (code.pointSize * 1.6).rounded()
        if style.kind == .toybox { toybox(style) }
    }

    /// Toybox's (card agent-bo-95423182): Nunito at 15 on a 1.6 line with its 800 for bold, Fredoka for `#` and `##`,
    /// JetBrains Mono on the sunk fill; the caret and a link in the sun's darker edge, a ticked box the sun with the ink's
    /// tick, as the menu's picked row.
    @MainActor private mutating func toybox(_ style: StyleTokens) {
        func color(_ role: KeyPath<StyleColors, Paint>) -> NSColor { Self.color(role, style) }
        body = DisplayFaces.font(StyleTokens.nunito(600), size: 15 + Self.step)
        bold = DisplayFaces.font(StyleTokens.nunito(800), size: 15 + Self.step)
        code = DisplayFaces.font(StyleTokens.jetBrainsMono(500), size: 13 + Self.step)
        h1 = Heading(font: DisplayFaces.font(StyleTokens.fredoka(600), size: 30), line: 38, after: 6)
        h2 = Heading(font: DisplayFaces.font(StyleTokens.fredoka(600), size: 23), line: 30, after: 2)
        line = 27
        inset = NSSize(width: 26, height: 22)
        codeRadius = 6
        (box, boxRadius, boxGap, tick) = (18, 5, 10, 10)
        accent = color(\.accentText); onAccent = color(\.onAccent); codeFill = color(\.sunken)
        (link, ticked, unticked) = (color(\.accentText), color(\.accent), color(\.text3))
        quoteBar = color(\.accent)
        codeLine = 24
    }

    /// How much bigger the note's words are than the style's body (Sven 2026-10-15).
    static let step: CGFloat = 2

    /// A style's colour role as an sRGB NSColor.
    @MainActor private static func color(_ role: KeyPath<StyleColors, Paint>, _ style: StyleTokens) -> NSColor { resolved(style.color(role)) }

    /// `colour` as an sRGB NSColor, so two styles compare equal when their colours are.
    private static func resolved(_ colour: Color) -> NSColor { NSColor(colour).usingColorSpace(.sRGB) ?? NSColor(colour) }

    /// The room a code panel or a table cell keeps round its words, and a quote's words from its bar's edge.
    static let blockPad: CGFloat = 12
    /// The room above and below a callout, a code panel or a table.
    static let blockGap: CGFloat = 8

    /// `#` and `##`; deeper levels take the bold body.
    func heading(_ level: Int) -> Heading? { level == 1 ? h1 : level == 2 ? h2 : nil }

    /// `font` with bold added: the body's bold, an italic's bold italic; headings and code keep their weight.
    func emboldened(_ font: NSFont) -> NSFont {
        if font == body { return bold }
        if font.fontDescriptor.symbolicTraits.contains(.italic), font.pointSize == body.pointSize {
            return NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        }
        return font
    }

    /// A body line's paragraph: its fixed height, and how far a wrapped line steps in.
    func paragraph(line: CGFloat? = nil, after: CGFloat = 0, indent: CGFloat = 0, first: CGFloat = 0) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = line ?? self.line
        paragraph.maximumLineHeight = line ?? self.line
        paragraph.paragraphSpacing = after
        paragraph.headIndent = indent
        paragraph.firstLineHeadIndent = first
        return paragraph
    }

    /// What typing starts from: body text on a body line.
    var plain: [NSAttributedString.Key: Any] { [.font: body, .foregroundColor: text, .paragraphStyle: paragraph()] }
}

/// Markdown's marks, matched line by line.
enum MarkdownMarks {
    static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+\S.*$"#, options: .anchorsMatchLines)
    static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    /// `_words_` or `*words*`; an underscore's may sit right inside or outside bold's `**` (`**_both_**`, `_**both**_`).
    static let italic = try! NSRegularExpression(pattern: #"(?<!\w)_(?=[^\s_]).+?(?<=[^\s_])_(?!\w)|(?<![\*\w])\*(?=[^\s\*_]).+?(?<=[^\s\*_])\*(?![\*\w])"#)
    static let code = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    static let link = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    static let bareURL = try! NSRegularExpression(pattern: #"(?<![\(\[])https?://[^\s)\]]+"#)
    /// A list line's marker: its indent, then `-`, `*`, `+` or `1.`, then the space.
    static let list = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+[.)])[ \t]+"#, options: .anchorsMatchLines)
    /// A line that only shows a picture, `![alt](path)`: the alt words, then the path.
    static let image = try! NSRegularExpression(pattern: #"^[ \t]*"# + NoteAttachments.link + #"[ \t]*$"#, options: .anchorsMatchLines)
    /// A quote's line: its `>` and the space after it, then its words.
    static let quote = try! NSRegularExpression(pattern: #"^([ \t]*>[ \t]?)(.*)$"#, options: .anchorsMatchLines)
    /// `- [ ] ` or `- [x] `: the box is the five characters from the dash.
    static let checkbox = try! NSRegularExpression(pattern: #"^[ \t]*([-*] \[([ xX])\])[ \t]"#, options: .anchorsMatchLines)
}

extension NSAttributedString.Key {
    /// On a checkbox's five characters: whether it is ticked.
    static let notesCheckbox = NSAttributedString.Key("PilotNotesCheckbox")
    /// On inline code, backticks included: drawn on its rounded fill.
    static let notesCode = NSAttributedString.Key("PilotNotesCode")
    /// On a picture's line: the picture's link, drawn under the line.
    static let notesImage = NSAttributedString.Key("PilotNotesImage")
}

/// The text view: draws inline code on its fill, each checkbox over its hidden `- [ ]` and each picture under its line,
/// toggles a box on a click, and saves a picture pasted or dropped in.
final class NotesTextView: NSTextView {
    var style = MarkdownStyle(style: .unstyled)
    /// Whether it takes the keyboard when its window becomes key.
    var wantsFocus = false
    /// Cmd+K's hold: told when this editor takes the keyboard.
    weak var handle: NotesEditorHandle?
    /// Called when it takes the keyboard (MarkdownEditor's `onFocus`).
    var onFocus: (() -> Void)?
    /// Told where the selection's first line is (MarkdownEditor's `selection`), nil while nothing is selected; only
    /// when that changes.
    var selectionChanged: ((CGRect?) -> Void)?
    private var reported: CGRect?
    var folder: URL? {
        didSet { if folder != oldValue { unreadable = [] } }
    }
    /// The pictures read, by file, shared by every editor (the note and the list's preview) and let go under memory
    /// pressure or past 40.
    private static let pictures: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 40
        return cache
    }()
    /// Links whose file did not read: not tried again on every keystroke, only after a new folder or a picture saved.
    private var unreadable: Set<String> = []
    /// Whether the text shows a picture, so a new width restyles only then.
    private var hasPictures = false
    /// The width the pictures were sized for: a new one restyles, so a picture always fits the line.
    private var picturesWidth: CGFloat = 0
    static let pictureGap: CGFloat = 6
    static let pictureMaxHeight: CGFloat = 280

    func apply(_ style: MarkdownStyle) {
        self.style = style
        centre()
        insertionPointColor = style.accent
        linkTextAttributes = [.foregroundColor: style.link, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .underlineColor: style.link.withAlphaComponent(0.45), .cursor: NSCursor.pointingHand]
        selectedTextAttributes = [.backgroundColor: style.selection]
        typingAttributes = style.plain
    }

    /// Becomes first responder once the current event is done, when it still wants to and lacks it.
    func takeFocus() {
        guard wantsFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus, let window = self.window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window { NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: window) }
    }

    /// Its window became key: it takes the keyboard if it wants it, and when it holds it, Cmd+K's hold points here (an
    /// editor keeps its window's keyboard while another window is key, so taking it is not the only sign).
    @objc private func windowBecameKey() {
        if window?.firstResponder === self { handle?.focused(self) }
        takeFocus()
    }

    /// The lines whose marks show (the caret's, while this editor has the keyboard), as the last restyle drew them.
    private(set) var revealed: NSRange?
    /// True between becoming and resigning first responder: only the note being typed in shows a line's marks.
    private var hasFocus = false
    /// True while a click or a drag is held: the marks wait for the release, so text never moves under the pointer.
    private var tracking = false

    /// The lines the caret or the selection is on, while this editor is typed into; nil shows every line as it reads.
    func revealedLines() -> NSRange? {
        guard isEditable, hasFocus, let storage = textStorage else { return nil }
        return (storage.string as NSString).paragraphRange(for: selectedRange())
    }

    /// Restyles when the caret has gone to another line.
    func restyleIfMoved() {
        guard !tracking, revealedLines() != revealed else { return }
        // Inside an edit of the text (an undo's group), after it.
        if let storage = textStorage, !storage.editedMask.isEmpty {
            return DispatchQueue.main.async { [weak self] in self?.restyleIfMoved() }
        }
        restyle()
    }

    /// The caret onto another line shows that line's marks and hides the last one's, once a drag has settled.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { restyleIfMoved() }
        reportSelection()
    }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took {
            hasFocus = true
            handle?.focused(self)
            onFocus?()
            restyleIfMoved()
            reportSelection()
        }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave { hasFocus = false; restyleIfMoved(); reportSelection() }
        return gave
    }

    /// The margins that keep the words at the style's measure, centred, never under the least inset.
    private func centre() {
        let side = NotesMeasure.side(width: bounds.width, measure: style.measure, least: style.inset.width)
        let inset = NSSize(width: side, height: style.inset.height)
        if textContainerInset != inset { textContainerInset = inset }
    }

    /// Tells the format bar where the selection's first line is, in the scroll view's points from its top left, while this
    /// editor is typed into and the selection shows; nil hides the bar (nothing picked, a drag still going, scrolled off).
    @objc func reportSelection() {
        guard selectionChanged != nil else { return }
        let range = selectedRange()
        guard isEditable, hasFocus, !tracking, range.length > 0, let layout = layoutManager, let container = textContainer,
              let scroll = enclosingScrollView else { return report(nil) }
        var first = NSRect.null
        layout.enumerateEnclosingRects(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                       withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, stop in
            first = rect
            stop.pointee = true
        }
        guard !first.isNull else { return report(nil) }
        let inScroll = convert(first.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), to: scroll)
        let rect = scroll.isFlipped ? inScroll
            : NSRect(x: inScroll.minX, y: scroll.bounds.height - inScroll.maxY, width: inScroll.width, height: inScroll.height)
        report(rect.maxY > 0 && rect.minY < scroll.bounds.height ? rect : nil)
    }

    private func report(_ rect: CGRect?) {
        guard rect != reported else { return }
        reported = rect
        selectionChanged?(rect)
    }

    /// Every attribute from the text again: cheap at a note's size, and never out of step with an undo.
    func restyle() {
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length), s = storage.string as NSString
        let reveal = revealedLines()
        revealed = reveal
        storage.beginEditing()
        storage.setAttributes(style.plain, range: all)
        let fences = MarkdownBlocks.fences(s)
        /// Inside a fenced code block nothing is Markdown.
        func quiet(_ range: NSRange) -> Bool { fences.contains { NSIntersectionRange($0.block, range).length > 0 } }
        func each(_ regex: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: storage.string, range: all) { m, _, _ in if let m, !quiet(m.range) { body(m) } }
        }
        func mute(_ range: NSRange) { storage.addAttribute(.foregroundColor, value: style.muted, range: range) }
        /// Whether `range`'s lines show their marks: the caret is on one of them.
        func shows(_ range: NSRange) -> Bool {
            guard let reveal else { return false }
            let lines = s.paragraphRange(for: range)
            return NSIntersectionRange(lines, reveal).length > 0 || lines.location == reveal.location
        }
        func hide(_ range: NSRange) { if range.length > 0 { storage.addAttribute(.notesHidden, value: true, range: range) } }
        /// A mark: hidden and taking no room, or muted on the caret's line.
        func mark(_ range: NSRange) { shows(range) ? mute(range) : hide(range) }
        func restyleFonts(_ range: NSRange, _ change: (NSFont) -> NSFont) {
            storage.enumerateAttribute(.font, in: range) { value, r, _ in
                guard let font = value as? NSFont else { return }
                storage.addAttribute(.font, value: change(font), range: r)
            }
        }
        /// Adds room after the character at `index`, on top of any already there.
        func kern(_ amount: CGFloat, at index: Int) {
            let now = storage.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat ?? 0
            storage.addAttribute(.kern, value: now + amount, range: NSRange(location: index, length: 1))
        }
        func width(_ range: NSRange) -> CGFloat { NSAttributedString(string: s.substring(with: range), attributes: [.font: style.body]).size().width }
        func lineStyle(_ range: NSRange, _ paragraph: NSParagraphStyle) { storage.addAttribute(.paragraphStyle, value: paragraph, range: s.paragraphRange(for: range)) }
        /// Lines that open or close a callout, a code panel or a table: the room above and below is added last, over
        /// whatever paragraph the line before has by then.
        var blocks: [NSRange] = []

        // Fenced code: the code face on the panel, its words in from the panel's edge; off the caret, the fences are the
        // panel's padding.
        for fence in fences {
            let raw = shows(fence.block)
            storage.addAttributes([.font: style.code, .foregroundColor: style.text, .notesCodeBlock: fence.block.location], range: fence.block)
            lineStyle(fence.block, style.paragraph(line: style.codeLine, indent: MarkdownStyle.blockPad, first: MarkdownStyle.blockPad))
            for line in [fence.open, fence.close].compactMap({ $0 }) {
                if raw { mute(line) } else {
                    hide(line)
                    lineStyle(line, style.paragraph(line: MarkdownStyle.blockPad - 2))
                }
            }
            blocks.append(fence.block)
        }
        each(MarkdownMarks.heading) { m in
            let level = m.range(at: 1).length
            if let heading = style.heading(level) {
                storage.addAttribute(.font, value: heading.font, range: m.range)
                // Tracking, not kern: kern would turn the face's own pair kerning off.
                if heading.tracking != 0 { storage.addAttribute(.tracking, value: heading.tracking, range: m.range) }
                lineStyle(m.range, style.paragraph(line: heading.line, after: heading.after))
            } else {
                storage.addAttribute(.font, value: style.bold, range: m.range)
            }
            var end = NSMaxRange(m.range(at: 1))
            while end < NSMaxRange(m.range), [32, 9].contains(s.character(at: end)) { end += 1 }
            mark(NSRange(location: m.range(at: 1).location, length: end - m.range(at: 1).location))
        }
        // A quote: a callout, its words in the second text colour in from its bar.
        var quoteLines: [NSRange] = []
        each(MarkdownMarks.quote) { m in
            let line = s.lineRange(for: m.range)
            storage.addAttributes([.notesQuote: true, .foregroundColor: style.quote], range: line)
            mark(m.range(at: 1))
            lineStyle(m.range, style.paragraph(line: style.line + 4, indent: MarkdownStyle.blockPad + 2, first: MarkdownStyle.blockPad + 2))
            if let last = quoteLines.last, NSMaxRange(last) == line.location {
                quoteLines[quoteLines.count - 1] = NSUnionRange(last, line)
            } else {
                quoteLines.append(line)
            }
        }
        blocks += quoteLines
        each(MarkdownMarks.bold) { m in
            restyleFonts(m.range, style.emboldened)
            mark(m.range(at: 1))
            mark(NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length, length: m.range(at: 1).length))
        }
        each(MarkdownMarks.italic) { m in
            restyleFonts(m.range) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
            mark(NSRange(location: m.range.location, length: 1))
            mark(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }
        each(MarkdownMarks.link) { m in
            storage.addAttribute(.link, value: s.substring(with: m.range(at: 2)), range: m.range(at: 1))
            mark(NSRange(location: m.range.location, length: 1))
            mark(NSRange(location: NSMaxRange(m.range(at: 1)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 1))))
        }
        each(MarkdownMarks.bareURL) { m in storage.addAttribute(.link, value: s.substring(with: m.range), range: m.range) }
        each(MarkdownMarks.code) { m in
            storage.addAttributes([.font: style.code, .foregroundColor: style.text], range: m.range)
            storage.removeAttribute(.link, range: m.range)
            let ticks = [NSRange(location: m.range.location, length: 1), NSRange(location: NSMaxRange(m.range) - 1, length: 1)]
            ticks.forEach(mark)
            // The fill sits on what shows: the words alone once the backticks are hidden.
            let raw = shows(m.range)
            let filled = raw ? m.range : NSRange(location: m.range.location + 1, length: m.range.length - 2)
            storage.addAttribute(.notesCode, value: true, range: filled)
            // Room for the fill's 4 pt each side, so it never touches the words beside it.
            kern(4, at: NSMaxRange(filled) - 1)
            if m.range.location > 0, s.character(at: m.range.location - 1) != 10 { kern(4, at: m.range.location - 1) }
        }
        // A line that only shows a picture: the link muted, never a link to click, and room under it for the picture.
        picturesWidth = textContainer?.size.width ?? 0
        hasPictures = false
        each(MarkdownMarks.image) { m in
            let link = s.substring(with: m.range(at: 2))
            storage.removeAttribute(.link, range: m.range)
            storage.addAttribute(.foregroundColor, value: style.muted, range: m.range)
            guard let size = pictureSize(link) else { return }
            storage.addAttribute(.notesImage, value: link, range: m.range)
            hasPictures = true
            lineStyle(m.range, style.paragraph(after: size.height + 2 * Self.pictureGap))
        }
        // A list: `-`, `*` or `+` drawn as a dot (raw while the caret sits inside the mark), numbers in the quote's
        // colour; a wrapped line lines up under its own text.
        let caret = selectedRange()
        each(MarkdownMarks.list) { m in
            let sign = m.range(at: 2)
            let line = s.lineRange(for: m.range)
            let isBox = MarkdownMarks.checkbox.firstMatch(in: storage.string, range: line) != nil
            if sign.length == 1, "-*+".contains(s.substring(with: sign)), !isBox {
                let inside = reveal != nil && caret.length == 0 && caret.location > sign.location && caret.location < NSMaxRange(m.range)
                if inside { mute(sign) } else { storage.addAttributes([.notesBullet: true, .foregroundColor: NSColor.clear], range: sign) }
            } else if !isBox {
                storage.addAttribute(.foregroundColor, value: style.quote, range: sign)
            }
            lineStyle(m.range, style.paragraph(indent: width(m.range)))
        }
        each(MarkdownMarks.checkbox) { m in
            let ticked = s.substring(with: m.range(at: 2)) != " "
            storage.addAttributes([.notesCheckbox: ticked, .foregroundColor: NSColor.clear], range: m.range(at: 1))
            // The hidden `- [ ] ` takes exactly the box and the room after it, spread over its six characters.
            let marker = NSRange(location: m.range(at: 1).location, length: NSMaxRange(m.range) - m.range(at: 1).location)
            let spread = (style.box + style.boxGap - width(marker)) / CGFloat(marker.length)
            for i in marker.location..<NSMaxRange(marker) { kern(spread, at: i) }
            let lead = NSRange(location: m.range.location, length: marker.location - m.range.location)
            lineStyle(m.range, style.paragraph(indent: width(lead) + style.box + style.boxGap))
            if ticked {
                let rest = s.lineRange(for: m.range)
                let after = NSRange(location: NSMaxRange(m.range), length: NSMaxRange(rest) - NSMaxRange(m.range))
                storage.addAttributes([.foregroundColor: style.muted, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .strikethroughColor: style.muted], range: after)
            }
        }
        for table in MarkdownBlocks.tables(s, skipping: fences.map(\.block)) {
            grid(table, raw: shows(table.block))
            blocks.append(table.block)
        }
        // Room above and below each block, on top of what the lines round it already keep.
        for block in blocks {
            if block.location > 0 { roomAfter(s.paragraphRange(for: NSRange(location: block.location - 1, length: 0))) }
            roomAfter(s.paragraphRange(for: NSRange(location: max(NSMaxRange(block) - 1, block.location), length: 0)))
        }
        storage.endEditing()
        // A mark hidden or shown changes the glyphs, not only how they draw.
        layoutManager?.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
        layoutManager?.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        needsDisplay = true

        /// A table as a grid (or its raw lines, pipes muted, on the caret): the pipes and the spaces round each cell's words
        /// hidden, the `|---|` line a hairline, the header bold, each cell's words moved to their column with kerning.
        func grid(_ table: MarkdownBlocks.Table, raw: Bool) {
            let pad = MarkdownStyle.blockPad
            if raw {
                for row in table.rows {
                    for i in row.location..<NSMaxRange(row) where s.character(at: i) == 124 { mute(NSRange(location: i, length: 1)) }
                }
                return
            }
            var cells: [[NSRange]] = []
            for (n, row) in table.rows.enumerated() {
                if n == 1 {
                    hide(row)
                    lineStyle(row, style.paragraph(line: 1))
                    cells.append([])
                    continue
                }
                let words = MarkdownBlocks.cells(s, row: row)
                var at = row.location
                for cell in words + [NSRange(location: NSMaxRange(row), length: 0)] {
                    if cell.location > at { hide(NSRange(location: at, length: cell.location - at)) }
                    at = max(at, NSMaxRange(cell))
                }
                if n == 0 { words.forEach { restyleFonts($0, style.emboldened) } }
                cells.append(words)
            }
            /// What shows of a cell's words: its width with the hidden marks left out, and its last shown character.
            func shown(_ range: NSRange) -> (width: CGFloat, last: Int?) {
                guard range.length > 0 else { return (0, nil) }
                let piece = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
                var hidden: [NSRange] = []
                piece.enumerateAttribute(.notesHidden, in: NSRange(location: 0, length: piece.length)) { v, r, _ in if v != nil { hidden.append(r) } }
                var last: Int?
                for i in (0..<range.length).reversed() where !hidden.contains(where: { NSLocationInRange(i, $0) }) { last = range.location + i; break }
                hidden.reversed().forEach { piece.deleteCharacters(in: $0) }
                return (piece.size().width.rounded(.up), last)
            }
            let count = cells.map(\.count).max() ?? 0
            var widths = [CGFloat](repeating: 0, count: count)
            for row in cells { for (j, cell) in row.enumerated() { widths[j] = max(widths[j], shown(cell).width) } }
            var columns: [CGFloat] = [0]
            for w in widths { columns.append(columns[columns.count - 1] + w + 2 * pad) }
            for (n, row) in table.rows.enumerated() where n != 1 {
                var x: CGFloat = 0, last: Int?, first = pad
                for (j, cell) in cells[n].enumerated() {
                    let piece = shown(cell)
                    guard let end = piece.last else { continue }
                    let target = columns[j] + pad
                    if let last { kern(target - x, at: last) } else { first = target }
                    x = target + piece.width
                    last = end
                }
                lineStyle(row, style.paragraph(line: style.line + 10, indent: first, first: first))
            }
            storage.addAttribute(.notesTable, value: MarkdownTableGrid(columns: columns, rows: table.rows), range: table.block)
        }

        /// Room under a line: at least the block gap, kept when it already has more.
        func roomAfter(_ line: NSRange) {
            guard line.length > 0, let now = storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle,
                  now.paragraphSpacing < MarkdownStyle.blockGap,
                  let paragraph = now.mutableCopy() as? NSMutableParagraphStyle else { return }
            paragraph.paragraphSpacing = MarkdownStyle.blockGap
            storage.addAttribute(.paragraphStyle, value: paragraph, range: line)
        }
    }

    /// The line fragment holding `glyph`, in view coordinates, and the glyph's baseline in it.
    private func fragment(at glyph: Int) -> (rect: NSRect, glyphs: NSRange, baseline: CGFloat)? {
        guard let layout = layoutManager else { return nil }
        var glyphs = NSRange()
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return (rect, glyphs, rect.minY + layout.location(forGlyphAt: glyph).y)
    }

    /// Each checkbox's box and whether it is ticked, in view coordinates: centred on its line, at the dash's place.
    func checkboxes() -> [(range: NSRange, rect: NSRect, ticked: Bool)] {
        guard let storage = textStorage, let layout = layoutManager else { return [] }
        var boxes: [(NSRange, NSRect, Bool)] = []
        storage.enumerateAttribute(.notesCheckbox, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let ticked = value as? Bool else { return }
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            guard let line = fragment(at: glyph) else { return }
            let height = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight ?? style.line
            let x = line.rect.minX + layout.location(forGlyphAt: glyph).x
            let rect = NSRect(x: x.rounded(), y: (line.rect.minY + (height - style.box) / 2).rounded(), width: style.box, height: style.box)
            boxes.append((range, rect, ticked))
        }
        return boxes
    }

    /// Each inline code's fill, one per line it wraps over: 4 pt past its glyphs each side, 1 pt over and under.
    private func codeFills() -> [NSRect] {
        guard let storage = textStorage, let layout = layoutManager else { return [] }
        var fills: [NSRect] = []
        storage.enumerateAttribute(.notesCode, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            var glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            while glyphs.length > 0, let line = fragment(at: glyphs.location) {
                let piece = NSIntersectionRange(glyphs, line.glyphs)
                guard piece.length > 0 else { break }
                let last = NSMaxRange(piece) - 1
                let start = line.rect.minX + layout.location(forGlyphAt: piece.location).x
                let end = line.rect.minX + layout.location(forGlyphAt: last).x + style.code.advancement(forCGGlyph: layout.cgGlyph(at: last)).width
                fills.append(NSRect(x: start - 4, y: line.baseline - style.code.ascender - 1,
                                    width: end - start + 8, height: style.code.ascender - style.code.descender + 2))
                glyphs = NSRange(location: NSMaxRange(piece), length: NSMaxRange(glyphs) - NSMaxRange(piece))
            }
        }
        return fills
    }

    /// The picture a link names, read once at most 1200 px a side; nil without a folder or when the file does not read.
    private func picture(_ link: String) -> NSImage? {
        guard let folder, !unreadable.contains(link), let url = NoteAttachments.url(link, in: folder) else { return nil }
        if let known = Self.pictures.object(forKey: url as NSURL) { return known }
        guard let image = NoteAttachments.picture(at: url) else { unreadable.insert(link); return nil }
        // Pixels at the screen's scale, so a Retina screenshot shows at the size it was taken.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let picture = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        Self.pictures.setObject(picture, forKey: url as NSURL)
        return picture
    }

    /// A picture's size on the page: its own, made smaller to fit the line's width and at most 280 pt tall.
    private func pictureSize(_ link: String) -> NSSize? {
        guard let size = picture(link)?.size, size.width > 0, size.height > 0 else { return nil }
        let fit = min(1, max(picturesWidth, 40) / size.width, Self.pictureMaxHeight / size.height)
        return NSSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
    }

    /// Each picture and where it draws, in view coordinates: under its line, at the line's start.
    func pictureRects() -> [(rect: NSRect, image: NSImage)] {
        guard let storage = textStorage, let layout = layoutManager else { return [] }
        var shown: [(NSRect, NSImage)] = []
        storage.enumerateAttribute(.notesImage, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let link = value as? String, let image = picture(link), let size = pictureSize(link) else { return }
            let glyph = layout.glyphIndexForCharacter(at: NSMaxRange(range) - 1)
            guard let line = fragment(at: glyph) else { return }
            let height = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight ?? style.line
            shown.append((NSRect(x: line.rect.minX, y: line.rect.minY + height + Self.pictureGap, width: size.width, height: size.height), image))
        }
        return shown
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        centre()
        if hasPictures, let width = textContainer?.size.width, width != picturesWidth { restyle() }
    }

    // MARK: Pictures in

    /// Cmd+V: a picture on the clipboard is saved and linked; text, or anything else, pastes as before.
    override func paste(_ sender: Any?) {
        if !insertPictures(from: .general) { super.paste(sender) }
    }

    /// A plain-text view reads no picture types, so AppKit greyed out Paste, and Cmd+V never reached `paste`, while the
    /// clipboard held only a copied screenshot (PNG and TIFF, no text); text still reads first.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + (folder == nil ? [] : [.png, .tiff])
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { super.acceptableDragTypes + [.fileURL, .png, .tiff] }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { pictureDrop(super.draggingEntered(sender), sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { pictureDrop(super.draggingUpdated(sender), sender) }

    /// Copy over a drop of pictures the text view itself would refuse; decided by the types alone, as it runs on every
    /// move of the pointer.
    private func pictureDrop(_ operation: NSDragOperation, _ sender: NSDraggingInfo) -> NSDragOperation {
        operation.isEmpty && isEditable && holdsPictures(sender.draggingPasteboard) ? .copy : operation
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable, holdsPictures(sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)), length: 0))
        return insertPictures(from: sender.draggingPasteboard)
    }

    private func files(_ board: NSPasteboard) -> [URL] {
        board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Whether a pasteboard holds pictures, without reading one: files that are all pictures, else a picture with no
    /// text beside it (a screenshot copied).
    private func holdsPictures(_ board: NSPasteboard) -> Bool {
        let files = files(board)
        if !files.isEmpty { return files.allSatisfy(NoteAttachments.isImage) }
        return board.string(forType: .string) == nil && board.availableType(from: [.png, .tiff]) != nil
    }

    /// The pictures a pasteboard holds (holdsPictures), each its bytes, its file's name (nil when it has none) and
    /// extension; a copied picture as PNG.
    private func pictureData(_ board: NSPasteboard) -> [(data: Data, name: String?, ext: String)] {
        guard holdsPictures(board) else { return [] }
        let files = files(board)
        if !files.isEmpty { return files.compactMap { url in (try? Data(contentsOf: url)).map { ($0, url.lastPathComponent, url.pathExtension) } } }
        if let png = board.data(forType: .png) { return [(png, nil, "png")] }
        if let tiff = board.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [(png, nil, "png")]
        }
        return []
    }

    /// Saves the pasteboard's pictures in attachments/ and types their links at the caret, each on a line of its own, as
    /// an edit Undo takes back (the file stays). False when it holds none, or there is no folder to save in.
    func insertPictures(from board: NSPasteboard) -> Bool {
        guard isEditable, let folder else { return false }
        let found = pictureData(board)
        guard !found.isEmpty else { return false }
        var links: [String] = []
        for picture in found {
            do { links.append(try NoteAttachments.save(picture.data, named: picture.name, ext: picture.ext, in: folder, now: .now)) } catch {
                noteslog.error("notes: picture not saved: \(String(describing: error), privacy: .public)")
            }
        }
        guard !links.isEmpty else { NSSound.beep(); return true }
        unreadable = []
        let at = selectedRange(), s = string as NSString
        let before = at.location > 0 && s.character(at: at.location - 1) != 10 ? "\n" : ""
        insertText(before + links.joined(separator: "\n") + "\n", replacementRange: at)
        noteslog.notice("notes: \(links.count) picture(s) saved in attachments")
        return true
    }

    /// The lines holding `range`, from the first's top to the last's foot (its own height, not the room under it), the
    /// text's full width, in view coordinates.
    func linesRect(_ range: NSRange) -> NSRect? {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer, range.length > 0 else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var top = CGFloat.greatestFiniteMagnitude, foot = -CGFloat.greatestFiniteMagnitude
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, lineGlyphs, _ in
            let at = layout.characterIndexForGlyph(at: lineGlyphs.location)
            // A hidden mark at a line's start is laid out on the line before; that line is not the block's.
            guard at >= range.location else { return }
            let height = at < storage.length ? (storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight ?? 0 : 0
            top = min(top, rect.minY)
            foot = max(foot, rect.minY + (height > 0 ? min(height, rect.height) : rect.height))
        }
        guard top < foot else { return nil }
        let origin = textContainerOrigin
        return NSRect(x: origin.x, y: top + origin.y, width: container.size.width, height: foot - top)
    }

    /// Each run of `key` over the text with its value, longest first, as the passes set them.
    private func runs(_ key: NSAttributedString.Key) -> [(range: NSRange, value: Any)] {
        guard let storage = textStorage else { return [] }
        var out: [(NSRange, Any)] = []
        storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let value { out.append((range, value)) }
        }
        return out
    }

    /// Code panels, callouts and tables' header fills, under the words.
    private func drawBlocks(_ dirty: NSRect) {
        let radius = style.codeRadius + 2
        style.codeFill.setFill()
        for run in runs(.notesCodeBlock) {
            guard let rect = linesRect(run.range), rect.intersects(dirty) else { continue }
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        for run in runs(.notesQuote) {
            guard let rect = linesRect(run.range), rect.intersects(dirty) else { continue }
            style.codeFill.withAlphaComponent(style.codeFill.alphaComponent * 0.7).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            style.quoteBar.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height), xRadius: 1.5, yRadius: 1.5).fill()
        }
        for run in runs(.notesTable) {
            guard let grid = run.value as? MarkdownTableGrid, let box = linesRect(run.range), box.intersects(dirty),
                  let header = grid.rows.first.flatMap(linesRect) else { continue }
            let width = grid.columns.last ?? 0
            let frame = NSRect(x: box.minX, y: box.minY, width: width, height: box.height).insetBy(dx: 0.5, dy: 0.5)
            let outline = NSBezierPath(roundedRect: frame, xRadius: style.codeRadius, yRadius: style.codeRadius)
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            style.codeFill.setFill()
            NSRect(x: box.minX, y: header.minY, width: width, height: header.height).fill()
            NSGraphicsContext.restoreGraphicsState()
            style.rule.setStroke()
            let lines = NSBezierPath()
            lines.lineWidth = 1
            for row in grid.rows.dropFirst(2) {
                guard let rect = linesRect(row) else { continue }
                lines.move(to: NSPoint(x: frame.minX, y: rect.minY.rounded() + 0.5))
                lines.line(to: NSPoint(x: frame.maxX, y: rect.minY.rounded() + 0.5))
            }
            lines.move(to: NSPoint(x: frame.minX, y: header.maxY.rounded() + 0.5))
            lines.line(to: NSPoint(x: frame.maxX, y: header.maxY.rounded() + 0.5))
            for x in grid.columns.dropFirst().dropLast() {
                lines.move(to: NSPoint(x: (box.minX + x).rounded() + 0.5, y: frame.minY))
                lines.line(to: NSPoint(x: (box.minX + x).rounded() + 0.5, y: frame.maxY))
            }
            lines.stroke()
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    /// Each list dot: the hidden `-`'s place, centred on its line.
    func bullets() -> [NSRect] {
        guard let storage = textStorage, let layout = layoutManager else { return [] }
        let size = (style.body.pointSize * 0.36).rounded()
        return runs(.notesBullet).flatMap { run in
            (run.range.location..<NSMaxRange(run.range)).compactMap { at -> NSRect? in
                let glyph = layout.glyphIndexForCharacter(at: at)
                guard let line = fragment(at: glyph) else { return nil }
                let height = (storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight ?? style.line
                let x = line.rect.minX + layout.location(forGlyphAt: glyph).x
                let advance = style.body.advancement(forCGGlyph: layout.cgGlyph(at: glyph)).width
                return NSRect(x: (x + (advance - size) / 2).rounded(), y: (line.rect.minY + (height - size) / 2).rounded(), width: size, height: size)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBlocks(dirtyRect)
        style.codeFill.setFill()
        for fill in codeFills() where fill.intersects(dirtyRect) {
            NSBezierPath(roundedRect: fill, xRadius: style.codeRadius, yRadius: style.codeRadius).fill()
        }
        super.draw(dirtyRect)
        for picture in pictureRects() where picture.rect.intersects(dirtyRect) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: picture.rect, xRadius: style.codeRadius, yRadius: style.codeRadius).addClip()
            picture.image.draw(in: picture.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        style.quote.setFill()
        for dot in bullets() where dot.intersects(dirtyRect) { NSBezierPath(ovalIn: dot).fill() }
        for box in checkboxes() where box.rect.intersects(dirtyRect) {
            if box.ticked {
                style.ticked.setFill()
                NSBezierPath(roundedRect: box.rect, xRadius: style.boxRadius, yRadius: style.boxRadius).fill()
                let config = NSImage.SymbolConfiguration(pointSize: style.tick, weight: .bold).applying(.init(paletteColors: [style.onAccent]))
                if let tick = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let size = tick.size
                    tick.draw(in: NSRect(x: box.rect.midX - size.width / 2, y: box.rect.midY - size.height / 2, width: size.width, height: size.height),
                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            } else {
                let radius = max(style.boxRadius - 0.75, 0)
                let path = NSBezierPath(roundedRect: box.rect.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
                path.lineWidth = 1.5
                style.unticked.setStroke(); path.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isEditable, let box = checkboxes().first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }) {
            return toggle(box.range, ticked: box.ticked)
        }
        // NSTextView tracks the drag until the release; the marks follow the caret after it.
        tracking = true
        super.mouseDown(with: event)
        tracking = false
        restyleIfMoved()
        reportSelection()
    }

    /// ⌘B, ⌘I, ⌘E, ⌘⇧H and ⌘⇧L format the selection while this editor has the keyboard (direction B), in the panel and on
    /// the Notes page alike; any other key equivalent goes on as before.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard isEditable, window?.firstResponder === self, flags.isSubset(of: [.command, .shift]),
              let format = MarkdownFormat.keyed(event.charactersIgnoringModifiers, command: flags.contains(.command), shift: flags.contains(.shift))
        else { return super.performKeyEquivalent(with: event) }
        self.format(format)
        return true
    }

    /// A format at the selection (the format bar, Cmd+K or its key), as an edit Undo takes back; the editor keeps the
    /// keyboard.
    func format(_ format: MarkdownFormat) {
        guard isEditable else { return }
        let edit = format.edit(string, selection: selectedRange())
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: style.plain))
        didChangeText()
        setSelectedRange(edit.selection)
        window?.makeFirstResponder(self)
    }

    /// Ticks or unticks the box at `range`, as an edit Undo takes back.
    func toggle(_ range: NSRange, ticked: Bool) {
        let mark = NSRange(location: range.location + 3, length: 1)
        let new = ticked ? " " : "x"
        guard shouldChangeText(in: mark, replacementString: new) else { return }
        textStorage?.replaceCharacters(in: mark, with: new)
        didChangeText()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEditable else { return }
        for box in checkboxes() { addCursorRect(box.rect, cursor: .pointingHand) }
    }
}

extension NotesTextView: @preconcurrency NSLayoutManagerDelegate {
    /// A hidden mark's characters (`.notesHidden`) as null glyphs: drawn as nothing and taking no room.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
        var properties: [NSLayoutManager.GlyphProperty]?
        for i in 0..<glyphRange.length {
            let at = characterIndexes[i]
            guard at < storage.length, storage.attribute(.notesHidden, at: at, effectiveRange: nil) != nil else { continue }
            if properties == nil { properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length)) }
            properties?[i] = .null
        }
        guard let properties else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: properties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    /// Each line's text centred in its fixed height (TextKit sets it on the bottom), so a box or a code fill centred on
    /// the line sits on the words.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = textStorage, glyphRange.length > 0 else { return false }
        let chars = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard chars.location < storage.length,
              let paragraph = storage.attribute(.paragraphStyle, at: chars.location, effectiveRange: nil) as? NSParagraphStyle,
              paragraph.minimumLineHeight > 0 else { return false }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        storage.enumerateAttribute(.font, in: chars) { value, _, _ in
            guard let font = value as? NSFont else { return }
            ascent = max(ascent, font.ascender); descent = max(descent, -font.descender)
        }
        baselineOffset.pointee = ((paragraph.minimumLineHeight - ascent - descent) / 2 + ascent).rounded()
        return true
    }
}
