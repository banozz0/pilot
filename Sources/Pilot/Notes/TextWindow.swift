import AppKit
import OSLog
import PilotCore
import PilotTiler
import SwiftUI
import UniformTypeIdentifiers

let textlog = Logger(subsystem: "dev.banozz.pilot", category: "text")

/// Pilot opens .txt and .md files (T49, Sven 2026-11-04, Q834): Info.plist lists Pilot as an Alternate editor of plain
/// text and Markdown, so it shows in Finder's Open With and in Default apps' pickers; Pilot never makes itself the
/// default, Sven picks it. A file opens in a window of its own, in the Notes editor's look: Markdown drawn as it reads
/// (MarkdownEditor) with a raw toggle, plain text plain. Cmd+S saves in place through NSDocument's safe save (a temporary
/// file swapped in, the file's permissions kept) in the file's own encoding, byte order mark and line endings; nothing
/// is saved without Cmd+S or the close question's Save, and quitting asks about each unsaved file once (NSApplication's
/// own review). A change on disk reloads a clean file and asks over an edited one.
enum TextWindows {
    static let plainText = UTType.plainText.identifier
    static let markdown = "net.daringfireball.markdown"
    static let types = [markdown, plainText]
    /// Bigger files are refused: the editor holds the whole text and restyles on each keystroke.
    static let largest = 20 << 20
    /// A Markdown file this long opens raw: the drawn view restyles the whole text on each keystroke.
    static let drawnLimit = 100_000
    /// Past this the head counts no words: the count reads the whole text on each keystroke.
    static let countLimit = 200_000

    /// The document type `url` opens as: Markdown, plain text (any text that is not source code's own app's), or nil.
    static func type(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdown", "mkd", "mdwn"].contains(ext) { return markdown }
        guard let type = UTType(filenameExtension: ext) ?? (ext.isEmpty ? .plainText : nil) else { return nil }
        if let md = UTType(markdown), type.conforms(to: md) { return markdown }
        return type.conforms(to: .plainText) ? plainText : nil
    }

    /// Opens `url` in its window, or brings its open window forward (a link is followed, so the link stays a link and the
    /// window is its target's). The route `application(_:open:)` takes for a file.
    @MainActor @discardableResult
    static func open(_ url: URL) -> TextDocument? {
        guard let doc = load(url) else { return nil }
        if doc.windowControllers.isEmpty { doc.makeWindowControllers() }
        // Pilot is a menu-bar app: the Dock icon arrives first so the window opens as a regular app's (the app window's
        // rule, AppWindowController.present; its close watch counts this window and drops the icon after the last).
        AppWindowController.shared.applyDockIcon(.dock)
        let shown = doc.windowControllers.first?.window?.isVisible == true
        doc.showWindows()
        if !shown { TilerOwnWindows.shown() }
        WindowFocus.bringForward()
        NSDocumentController.shared.noteNewRecentDocument(doc)
        return doc
    }

    /// The document for `url`: the open one, or read from disk and added to the document controller. An unreadable file
    /// says why in an alert and gives nil.
    @MainActor
    static func load(_ url: URL, alert: Bool = true) -> TextDocument? {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let controller = NSDocumentController.shared
        if let open = controller.document(for: url) as? TextDocument { return open }
        guard !url.hasDirectoryPath, let type = type(of: url) else { return nil }
        do {
            // The size first: a file too large is never read.
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= largest else { throw TextFileFormat.Problem.tooLarge }
            let doc = try TextDocument(contentsOf: url, ofType: type)
            controller.addDocument(doc)
            doc.watch = FileWatch(url) { [weak doc] in doc?.diskChanged() }
            textlog.notice("text: opened \(url.lastPathComponent, privacy: .private)")
            return doc
        } catch {
            textlog.error("text: open failed: \(error.localizedDescription, privacy: .private)")
            if alert { NSAlert(error: error).runModal() }
            return nil
        }
    }

    /// The files opened lately, newest first (NSDocumentController's list, the head's clock menu).
    @MainActor static var recent: [URL] { NSDocumentController.shared.recentDocumentURLs }
}

/// How a file's text sits on disk, kept so a save writes it back the same way, never changing a byte that was not
/// edited (Q105): the encoding, whether it starts with a byte order mark, and its line endings. One kind of line ending is
/// LF in the editor and written back as it was; mixed ones stay as they are in the text, so each line keeps its own.
struct TextFileFormat: Equatable {
    enum LineEnding: String { case lf = "\n", crlf = "\r\n", cr = "\r" }

    var encoding: String.Encoding = .utf8
    var bom = false
    var lineEnding: LineEnding = .lf
    /// More than one kind of line ending: the text keeps its CRs and is written back as it is.
    var mixed = false
    /// Neither a byte order mark nor UTF-8 said what the file is; Latin-1 was a guess that reads every byte back.
    var guessed = false

    enum Problem: LocalizedError {
        case notText, tooLarge, cannotEncode(String)
        var errorDescription: String? {
            switch self {
            case .notText: "This file isn’t text Pilot can edit."
            case .tooLarge: "This file is too large for Pilot’s editor (20 MB at most)."
            case .cannotEncode(let name): "The text has characters \(name) can’t hold, so Pilot didn’t save it. Your edits are still here."
            }
        }
    }

    private static let boms: [(bytes: [UInt8], encoding: String.Encoding)] = [
        ([0xEF, 0xBB, 0xBF], .utf8), ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian), ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
        ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian),
    ]

    /// The text in `data`, LF lines when it has one kind of ending, and how it sat: a byte order mark's encoding, else
    /// UTF-8, else ISO Latin 1 guessed (which reads every byte and writes it back unchanged). A NUL without a mark is not
    /// text.
    static func decode(_ data: Data) throws -> (text: String, format: TextFileFormat) {
        guard data.count <= TextWindows.largest else { throw Problem.tooLarge }
        var format = TextFileFormat()
        var body = data
        if let mark = boms.first(where: { data.starts(with: $0.bytes) }) {
            (format.encoding, format.bom) = (mark.encoding, true)
            body = data.dropFirst(mark.bytes.count)
        } else if data.contains(0) {
            throw Problem.notText
        }
        var decoded = String(data: body, encoding: format.encoding)
        if decoded == nil, !format.bom {
            (format.encoding, format.guessed) = (.isoLatin1, true)
            decoded = String(data: body, encoding: .isoLatin1)
        }
        guard let raw = decoded else { throw Problem.notText }
        let (crlf, cr, lf) = endings(raw)
        switch (crlf > 0, cr > 0, lf > 0) {
        case (false, false, _): return (raw, format)
        case (true, false, false): format.lineEnding = .crlf
        case (false, true, false): format.lineEnding = .cr
        default:
            format.mixed = true
            return (raw, format)
        }
        let text = raw.replacingOccurrences(of: format.lineEnding.rawValue, with: "\n")
        return (text, format)
    }

    /// How many CRLF, lone CR and lone LF endings `text` has, in one pass over its bytes.
    static func endings(_ text: String) -> (crlf: Int, cr: Int, lf: Int) {
        var (crlf, cr, lf) = (0, 0, 0)
        var afterCR = false
        for byte in text.utf8 {
            if byte == 0x0A { afterCR ? (crlf += 1) : (lf += 1) } else if afterCR { cr += 1 }
            afterCR = byte == 0x0D
        }
        if afterCR { cr += 1 }
        return (crlf, cr, lf)
    }

    /// `text` as this format writes it; never lossy.
    func encode(_ text: String) throws -> Data {
        let lines = lineEnding == .lf || mixed ? text : text.replacingOccurrences(of: "\n", with: lineEnding.rawValue)
        guard let body = lines.data(using: encoding, allowLossyConversion: false) else { throw Problem.cannotEncode(encodingName) }
        guard bom, let mark = Self.boms.first(where: { $0.encoding == encoding }) else { return body }
        return Data(mark.bytes) + body
    }

    func canEncode(_ text: String) -> Bool { text.canBeConverted(to: encoding) }

    /// "UTF-8", "UTF-16 LE" and the like, for the head; a guessed encoding asks with "?".
    var name: String { guessed ? encodingName + "?" : encodingName }

    /// The encoding's own name, for a sentence.
    var encodingName: String {
        switch encoding {
        case .utf8: "UTF-8"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .utf32LittleEndian: "UTF-32 LE"
        case .utf32BigEndian: "UTF-32 BE"
        case .isoLatin1: "Latin-1"
        default: String.localizedName(of: encoding)
        }
    }

    var lineName: String { mixed ? "Mixed" : "\(lineEnding)".uppercased() }
}

/// One open file. Edits are tracked against the text last read or saved, so typing back to it is clean again; the
/// window's own undo manager takes the text view's undo (the document keeps none).
@objc(PilotTextDocument)
final class TextDocument: NSDocument {
    let model = TextWindowModel()
    /// The text as it is on disk: last read or saved.
    private(set) var saved = "" {
        didSet { savedBytes = saved.utf8.count }
    }
    /// Its length in UTF-8: a keystroke compares the whole text only when the lengths match.
    private var savedBytes = 0
    /// Another process's write to the file (an editor, git, a sync), which NSDocument's file presenter never hears.
    var watch: FileWatch?

    override init() {
        super.init()
        hasUndoManager = false
        model.document = self
    }

    // Nothing is written without Cmd+S or the close question's Save: no autosave, no versions, no drafts.
    override class var autosavesInPlace: Bool { false }
    override class var preservesVersions: Bool { false }
    override class var autosavesDrafts: Bool { false }
    override class var readableTypes: [String] { TextWindows.types }
    override class var writableTypes: [String] { TextWindows.types }
    override class func isNativeType(_ type: String) -> Bool { TextWindows.types.contains(type) }

    override func read(from data: Data, ofType typeName: String) throws {
        let (text, format) = try TextFileFormat.decode(data)
        MainActor.assumeIsolated {
            saved = text
            model.load(text, markdown: typeName == TextWindows.markdown, format: format)
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        try MainActor.assumeIsolated { try model.format.encode(model.text) }
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        // Never over a file Pilot can't or shouldn't write (Q105): read-only, locked, or moved to the Trash.
        if let refusal = Self.refusal(url) {
            textlog.notice("text: not saved: \(refusal.localizedDescription, privacy: .private)")
            return completionHandler(refusal)
        }
        let writing = model.text
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            MainActor.assumeIsolated {
                if error == nil, let self {
                    self.saved = writing
                    self.model.changedOnDisk = nil
                    self.textChanged()
                    textlog.notice("text: saved \(url.lastPathComponent, privacy: .private)")
                }
            }
            completionHandler(error)
        }
    }

    /// Why `url` is not saved over: it is in a Trash, or it exists and is read-only or locked (Finder's Locked).
    static func refusal(_ url: URL) -> NSError? {
        let name = url.lastPathComponent
        func refused(_ why: String, _ code: Int) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: code,
                    userInfo: [NSLocalizedDescriptionKey: "“\(name)” \(why), so Pilot didn’t save it. Your edits are still here."])
        }
        if url.standardizedFileURL.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) {
            return refused("is in the Trash", NSFileWriteUnknownError)
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let locked = (try? fm.attributesOfItem(atPath: url.path))?[.immutable] as? Bool ?? false
        return !fm.isWritableFile(atPath: url.path) || locked ? refused("is read-only or locked", NSFileWriteNoPermissionError) : nil
    }

    override func makeWindowControllers() { addWindowController(TextWindowController(document: self)) }

    /// The text changed (typed, read, saved): the document is edited while it differs from the file. A keystroke
    /// compares the whole text only when its length matches the file's.
    func textChanged() {
        let edited = model.text.utf8.count != savedBytes || model.text != saved
        if edited != isDocumentEdited { updateChangeCount(edited ? .changeDone : .changeCleared) }
        model.edited = edited
    }

    /// Cmd+S: saves in place. Text the file's encoding can't hold is never written: only a guessed Latin-1 file can't
    /// hold a character, and converting it could scramble every letter the guess read wrong, so the edit waits.
    func saveNow() {
        guard !model.format.canEncode(model.text) else { return save(nil) }
        let alert = NSAlert()
        alert.messageText = "Pilot didn’t save “\(model.name)”"
        alert.informativeText = "Pilot guessed this file’s encoding, and the new text has characters it can’t hold. Pilot can’t "
            + "add them without risking the rest of the file. Your edits are still here."
        alert.addButton(withTitle: "Cancel")
        if let window = windowControllers.first?.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    override func close() {
        watch?.stop()
        watch = nil
        super.close()
    }

    // A change on disk, coordinated (presentedItemDidChange) or not (watch): a clean document reads it again, an edited
    // one asks in the window.
    nonisolated override func presentedItemDidChange() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.diskChanged() } }
    }

    func diskChanged() {
        // From the file itself: a URL's resource values are cached, and NSDocument read this one's date at the open.
        guard let url = fileURL, let type = fileType,
              let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              date != fileModificationDate else { return }
        guard isDocumentEdited else { return reload(url, type) }
        model.changedOnDisk = date
    }

    /// The changed-on-disk question's Reload: the file's text over the edits.
    func reload() {
        guard let url = fileURL, let type = fileType else { return }
        reload(url, type)
    }

    private func reload(_ url: URL, _ type: String) {
        do { try revert(toContentsOf: url, ofType: type) } catch { presentError(error) }
    }

    /// Its Keep mine: the next Cmd+S writes the edits over the change without NSDocument's second question.
    func keepMine() {
        if let date = model.changedOnDisk { fileModificationDate = date }
        model.changedOnDisk = nil
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        model.changedOnDisk = nil
        textChanged()
    }
}

/// Tells `changed` when the file at `url` is written, extended, touched or replaced, from a kernel vnode watch: no
/// polling, nothing while the file sits still. A replace (an atomic save's rename, a delete and write) leaves the watch on
/// the old file, so it watches the path's new file again, trying for a few seconds while the path is empty.
@MainActor
final class FileWatch {
    private let url: URL
    private let changed: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var stopped = false

    init(_ url: URL, changed: @escaping @MainActor () -> Void) {
        self.url = url
        self.changed = changed
        arm()
    }

    private func arm(tries: Int = 10) {
        source?.cancel()
        source = nil
        guard !stopped else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.arm(tries: tries - 1)
                        self?.changed()
                    }
                }
            }
            return
        }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename],
                                                              queue: .main)
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) { self.arm() }
                self.changed()
            }
        }
        watch.setCancelHandler { close(fd) }
        source = watch
        watch.resume()
    }

    func stop() {
        stopped = true
        source?.cancel()
        source = nil
    }
}

/// What the window shows: the text, Markdown or plain, drawn or raw, edited, and a change on disk waiting.
@MainActor @Observable
final class TextWindowModel {
    @ObservationIgnored weak var document: TextDocument?
    var text = "" {
        didSet { document?.textChanged() }
    }
    private(set) var markdown = false
    /// Markdown shown as its marks: always for plain text.
    var raw = false
    var edited = false
    var format = TextFileFormat()
    /// When the file changed on disk under unsaved edits; nil while nothing waits.
    var changedOnDisk: Date?
    @ObservationIgnored private var loaded = false

    /// The file's text, read or read again; the first read opens a long Markdown file raw.
    func load(_ text: String, markdown: Bool, format: TextFileFormat) {
        self.text = text
        self.markdown = markdown
        self.format = format
        if !loaded { raw = markdown && (text as NSString).length > TextWindows.drawnLimit }
        loaded = true
    }

    var name: String { document?.fileURL?.lastPathComponent ?? "Untitled" }
    var folder: String? { document?.fileURL?.deletingLastPathComponent().lastPathComponent }
    var drawn: Bool { markdown && !raw }
}

/// The file's window: the app window's frame (Liquid Glass or Solid as Look says, the title bar hidden over the head),
/// one per file, its size kept for the next. Cmd+S saves, Cmd+W closes (asking about unsaved edits), Cmd+Q quits.
@MainActor
final class TextWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 820, height: 680), minSize = NSSize(width: 420, height: 300)

    convenience init(document: TextDocument) {
        let w = AppWindowController.makeWindow(content: NSHostingView(rootView: TextWindowView(model: document.model).styled(.page(.notes))),
                                               size: Self.size, minSize: Self.minSize)
        w.isRestorable = false
        self.init(window: w)
        w.delegate = self
        w.onSave = { [weak document] in document?.saveNow() }
        w.onQuit = { AppWindowController.shared.quit() }
        // The first window where the last one was; each next one cascades from the one before.
        shouldCascadeWindows = true
        windowFrameAutosaveName = "PilotTextWindow"
        followLook()
    }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String { displayName }

    /// The theme and the material as the app window's (AppWindowController.applyLook), followed while the window lives.
    private func followLook() {
        guard let window else { return }
        AppWindowController.applyLook(.shared, to: window)
        withObservationTracking { _ = (Look.shared.layers, Look.shared.style, Look.shared.theme, Look.shared.glassBlur) } onChange: { [weak self] in
            Task { @MainActor in self?.followLook() }
        }
    }

    /// A closed window lets go of its SwiftUI tree at once (the app window's rule: closed windows kept theirs).
    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { window.contentView = nil } }
    }
}

/// The file in the Notes page's look: the head (where it is, its name, edited, encoding and line endings, the raw
/// toggle, recent files, Save) over the editor at the page's measure.
struct TextWindowView: View {
    @Environment(\.style) private var style
    @Bindable var model: TextWindowModel

    var body: some View {
        let markdown = MarkdownStyle(style: style, measure: NotesMeasure.page)
        VStack(spacing: 0) {
            TextWindowHead(model: model)
            if let date = model.changedOnDisk { TextDiskChanged(model: model, date: date) }
            Group {
                if model.drawn {
                    MarkdownEditor(text: $model.text, style: markdown, focused: true)
                } else {
                    PlainTextEditor(text: $model.text, style: markdown)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(style.color(\.panel))
    }
}

/// The head (34 pt, the Notes head's), clear of the window's buttons: "folder › name", a dot while edited, then
/// "UTF-8 · LF · 120 words", the raw toggle for Markdown, recent files and Save.
struct TextWindowHead: View {
    @Environment(\.style) private var style
    let model: TextWindowModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                if let folder = model.folder {
                    Text(folder).foregroundStyle(style.color(\.text3))
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(style.color(\.text3))
                }
                Text(model.name).foregroundStyle(style.color(\.text2)).truncationMode(.middle)
                if model.edited {
                    Circle().fill(style.color(\.accent)).frame(width: 6, height: 6).accessibilityLabel("Edited")
                }
            }
            .font(style.font(\.caption)).lineLimit(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Text(status)
                .font(style.font(\.mono)).monospacedDigit().foregroundStyle(style.color(\.text3)).lineLimit(1).fixedSize()
            if model.markdown {
                NotesHeadButton(symbol: model.raw ? "eye" : "chevron.left.forwardslash.chevron.right",
                                label: model.raw ? "Show formatted" : "Show raw Markdown") { toggleRaw() }
            }
            TextRecentMenu()
            NotesHeadButton(key: "⌘S", label: "Save") { model.document?.saveNow() }
        }
        // The window's close, minimise and zoom buttons sit over the head's left.
        .padding(.leading, 78).padding(.trailing, 8).frame(height: 34)
        .overlay(alignment: .bottom) { NotesRule() }
    }

    /// "UTF-8 · LF · 120 words"; no count for a long file.
    private var status: String {
        let shape = "\(model.format.name) · \(model.format.lineName)"
        let length = (model.text as NSString).length
        return length > TextWindows.countLimit ? shape : "\(shape) · \(NotesText.count(NotesText.words(model.text)))"
    }

    /// The other editor takes the text; the undo kept was the last one's, so it goes.
    private func toggleRaw() {
        model.raw.toggle()
        model.document?.windowControllers.first?.window?.undoManager?.removeAllActions()
    }
}

/// The files opened lately: one opens it (or its window), Clear empties the list.
private struct TextRecentMenu: View {
    @Environment(\.style) private var style

    var body: some View {
        Menu {
            let recent = TextWindows.recent
            if recent.isEmpty { Text("No recent files") }
            ForEach(recent, id: \.self) { url in
                Button(url.lastPathComponent) { TextWindows.open(url) }
            }
            if !recent.isEmpty {
                Divider()
                Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }
            }
        } label: {
            Image(systemName: "clock").font(.system(size: 12, weight: .medium)).foregroundStyle(style.color(\.text2))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().frame(minWidth: 24, minHeight: 24)
        .help("Open Recent").accessibilityLabel("Open Recent")
    }
}

/// The file changed on disk under unsaved edits: Reload takes the file's, Keep mine keeps the edits for the next save.
private struct TextDiskChanged: View {
    @Environment(\.style) private var style
    let model: TextWindowModel
    let date: Date

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(style.color(\.accent))
            Text("Changed on disk at \(date.formatted(date: .omitted, time: .shortened)). Your edits aren’t saved.")
                .foregroundStyle(style.color(\.text2)).lineLimit(1)
            Spacer(minLength: 8)
            Button("Keep mine") { model.document?.keepMine() }
            Button("Reload") { model.document?.reload() }
        }
        .font(style.font(\.caption)).buttonStyle(.pilot)
        .padding(.horizontal, 14).frame(height: 36)
        .background(style.color(\.raised))
        .overlay(alignment: .bottom) { NotesRule() }
    }
}

/// Plain text and raw Markdown: the note's face, colours and measure with no Markdown drawn, so a keystroke restyles
/// nothing and a long file stays quick.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var style: MarkdownStyle

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        let plain = PlainTextView(frame: view.frame)
        plain.autoresizingMask = [.width]
        plain.isVerticallyResizable = true
        plain.textContainer?.widthTracksTextView = true
        plain.textContainer?.lineFragmentPadding = 0
        plain.delegate = context.coordinator
        plain.isRichText = false
        plain.importsGraphics = false
        plain.allowsUndo = true
        plain.drawsBackground = false
        plain.usesFindBar = true
        plain.isIncrementalSearchingEnabled = true
        plain.isAutomaticQuoteSubstitutionEnabled = false
        plain.isAutomaticDashSubstitutionEnabled = false
        plain.isAutomaticTextReplacementEnabled = false
        plain.isAutomaticSpellingCorrectionEnabled = false
        plain.setAccessibilityLabel("Text")
        plain.apply(style)
        plain.string = text
        context.coordinator.typed = text
        scroll.documentView = plain
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        DispatchQueue.main.async { plain.window?.makeFirstResponder(plain) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? PlainTextView else { return }
        if view.style != style { view.apply(style) }
        // The update a keystroke caused carries the view's own string back: the same storage, which == knows at once
        // without reading it. Anything else (a reload, even to text typed earlier) is compared once.
        if text != context.coordinator.typed, view.string != text {
            view.string = text
            context.coordinator.typed = text
            view.textStorage?.setAttributes(style.plain, range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        /// The string the view holds, as last typed or set from the model: an update handing it back skips the compare.
        var typed = ""
        init(_ parent: PlainTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            typed = view.string
            parent.text = typed
        }
    }
}

/// The plain editor's view: the words at the style's measure, centred, as the note's.
final class PlainTextView: NSTextView {
    var style = MarkdownStyle(style: .unstyled)

    func apply(_ style: MarkdownStyle) {
        self.style = style
        font = style.body
        textColor = style.text
        insertionPointColor = style.accent
        selectedTextAttributes = [.backgroundColor: style.selection]
        typingAttributes = style.plain
        defaultParagraphStyle = style.paragraph()
        textStorage?.setAttributes(style.plain, range: NSRange(location: 0, length: textStorage?.length ?? 0))
        centre()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        centre()
    }

    private func centre() {
        let side = NotesMeasure.side(width: bounds.width, measure: style.measure, least: style.inset.width)
        let inset = NSSize(width: side, height: style.inset.height)
        if textContainerInset != inset { textContainerInset = inset }
    }
}
