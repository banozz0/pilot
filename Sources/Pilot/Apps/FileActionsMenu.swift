import AppKit
import OSLog
import PDFKit
import PilotCore
import UniformTypeIdentifiers

/// Hyper + right-click on a file (story 199): Pilot's own actions for the files under the pointer, as the menu's picker
/// opened at the pointer, its rows those FileAction lists for their kind. Each row runs what Pilot already does to a file
/// (Open With, Quick Look, Convert, Resize and Upscale, folder designs); Read aloud and Ask AI read the file's text off
/// the main thread first, at most FileAction.textLimit characters; Change icon sets a picture as the file's icon.
/// Nothing is kept once the picker closes.
@MainActor
enum FileActionsMenu {
    /// What the press named: Finder's files under its point, read through Accessibility, on the desktop (no window
    /// there) or in a Finder window, or a file Pilot already lists.
    enum Source { case finder, desktop, files([URL]) }

    /// The picker for what lies under `point` (a CGEvent's location, top left), after the tap's callback returned. Over
    /// a Finder window with no file there nothing opens: the press is already taken; over the empty desktop its own
    /// menu does (DesktopMenu).
    static func open(_ source: Source, at point: CGPoint) {
        let anchor = CGPoint(x: point.x, y: Screens.primaryHeight - point.y)
        switch source {
        case .files(let urls): show(urls, at: anchor)
        case .finder, .desktop:
            Task {
                let urls = await Task.detached(priority: .userInitiated) { FinderItems.at(point) }.value
                guard !urls.isEmpty else {
                    if case .desktop = source { return DesktopMenu.open(at: point) }
                    return flog.notice("file menu: no file under the pointer")
                }
                show(urls, at: anchor)
            }
        }
    }

    /// The picker for `urls` with its top left at `anchor`. `own` runs an action itself and says so (Pilot Files' Cmd+K:
    /// Move to Trash through FileOps, so Cmd+Z puts it back, and Open on a folder in the window); any other is `run`'s.
    /// `except` leaves those rows out.
    static func show(_ urls: [URL], at anchor: CGPoint, except: Set<FileAction> = [],
                     own: @escaping @MainActor (FileAction) -> Bool = { _ in false }) {
        Task {
            // Off the main thread: a folder's icon is hashed to tell whether Pilot dressed it.
            let actions = await Task.detached(priority: .userInitiated) {
                FileAction.list(for: urls.map(kind), customIcon: customIcon(urls)).filter { !except.contains($0) }
            }.value
            pick(urls, actions, at: anchor, own: own)
        }
    }

    /// Whether the one file wears an icon Reset icon takes back: a file's or an app's own, or a folder's Pilot dressed it
    /// in (one set elsewhere stays, as folder designs leave it).
    nonisolated static func customIcon(_ urls: [URL]) -> Bool {
        guard urls.count == 1, let url = urls.first else { return false }
        guard FolderLooks.isFolder(url) else { return FolderLooks.hasCustomIcon(url) }
        if case .pilot = FolderDesigns.looks.look(of: url) { return true }
        return false
    }

    private static func pick(_ urls: [URL], _ actions: [FileAction], at anchor: CGPoint, own: @escaping @MainActor (FileAction) -> Bool) {
        let rows = rows(actions)
        flog.notice("file menu: \(urls.count) files, \(rows.count) actions")
        PilotMenu.$anchor.withValue(anchor) {
            PilotMenu.shared.pick(rows, title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") { row in
                guard case .action(let id) = row.target, let action = FileAction(rawValue: String(id.dropFirst(prefix.count))) else { return }
                // A picker the action opens (Convert to…, Open With…, Folder design…) opens at the pointer too.
                PilotMenu.$anchor.withValue(anchor) { if !own(action) { run(action, on: urls) } }
            }
        }
    }

    /// A row's action id: this prefix and the FileAction's name.
    private static let prefix = "files."

    /// The picker's rows, one per action, each with its glyph; Move to Trash in red.
    static func rows(_ actions: [FileAction]) -> [MenuEntry] {
        actions.map { MenuEntry(title: $0.title, target: .action(prefix + $0.rawValue), icon: .glyph($0.symbol, $0 == .trash ? .problem : .accent)) }
    }

    static func run(_ action: FileAction, on urls: [URL]) {
        guard let first = urls.first else { return }
        flog.notice("file menu: \(action.rawValue, privacy: .public) on \(urls.count) files")
        switch action {
        case .open: urls.forEach { NSWorkspace.shared.open($0) }
        case .openWith: FileActions.openWith(urls)
        case .preview: FilePreviewWindow.open(first)
        case .quickLook: FileActions.preview(first.path)
        case .askAI: askAI(first)
        case .readAloud: readAloud(first)
        case .resize: ImageTools.offer(.resize, urls)
        case .upscale: ImageTools.offer(.upscale, urls)
        case .convert: ConvertFiles.offer(urls)
        case .readQR: QRCodes.read(file: first)
        case .folderDesign: FolderDesigns.pick(urls.filter(FolderLooks.isFolder))
        case .changeIcon: changeIcon(first)
        case .resetIcon: resetIcon(first)
        case .copyPath: SystemModule.copy(urls.map(\.path).joined(separator: "\n"), tip: urls.count == 1 ? "Copied the path" : "Copied \(urls.count) paths")
        case .copyFile:
            // A Pilot recording goes with its pointer drawn in when it kept it out (Q821); any other file as it is.
            RecordingHandout.handOut(urls) { files in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(files as [NSURL])
                HUD.tip(files.count == 1 ? "Copied \(first.lastPathComponent)" : "Copied \(files.count) files")
            }
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .trash: FileActions.trash(first.path)
        }
    }

    nonisolated static func kind(_ url: URL) -> FileAction.Kind {
        if FolderLooks.isFolder(url) { return .folder }
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        return type.conforms(to: .plainText) ? .text : .other
    }

    /// The whole file read aloud, Markdown's marks left out, at most FileAction.textLimit characters, which the tip says.
    private static func readAloud(_ url: URL) {
        Task {
            guard let read = await capped(url, speakable: true) else { return HUD.tip("\(url.lastPathComponent) has no text to read") }
            ReadAloud.shared.read(service: read.text, note: read.cut ? "the first \(FileAction.textLimit.formatted()) characters" : nil)
        }
    }

    /// The file's text off the main thread, cut to FileAction.textLimit; nil when it has none but whitespace.
    private static func capped(_ url: URL, speakable: Bool) async -> (text: String, cut: Bool)? {
        let read = await Task.detached(priority: .userInitiated) {
            text(of: url).map { FileAction.capped(speakable ? FileAction.speakable($0, markdown: isMarkdown(url)) : $0) }
        }.value
        return read.flatMap { $0.text.allSatisfy(\.isWhitespace) ? nil : $0 }
    }

    /// A picture goes to the AI chat as a capture does (story 191); text and a PDF's words to the selection box, as
    /// Ask Pilot AI on selected text does; anything else is a new chat whose message starts with the file's path.
    private static func askAI(_ url: URL) {
        switch kind(url) {
        case .image:
            Task {
                guard let picture = await Task.detached(priority: .userInitiated, operation: { picture(url) }).value else {
                    return HUD.tip("Pilot cannot read \(url.lastPathComponent)")
                }
                AIChatPanel.shared.ask(about: picture)
            }
        case .text, .pdf:
            Task {
                guard let read = await capped(url, speakable: false) else { return HUD.tip("\(url.lastPathComponent) has no text to ask about") }
                if read.cut { flog.notice("file menu: Ask AI takes the first \(FileAction.textLimit) characters") }
                SelectionBox.shared.open(service: read.text)
            }
        case .folder, .other:
            let chat = AIChatPanel.shared
            chat.model.clear()
            chat.model.draft = "About \(url.path): "
            chat.show()
        }
    }

    /// A picture for the icon: a folder is dressed in it as Your own (P43), so Reset takes it back; a file gets it
    /// through NSWorkspace.setIcon, as Finder's Get Info does.
    private static func changeIcon(_ url: URL) {
        let folder = FolderLooks.isFolder(url)
        let message = "A picture for \(url.lastPathComponent)" + (folder ? ": a cut-out picture is the whole icon, any other is fitted inside the folder's front." : ".")
        FolderDesigns.chooseOwn(types: [.image], message: message) { picture in
            if folder {
                Task { FolderDesigns.applied(await FolderDesigns.apply(.own(picture), to: [url]), .own(picture)) }
                return
            }
            guard let image = NSImage(contentsOf: picture) else { return HUD.tip("Pilot cannot read that picture") }
            // Drawn on a square, as a folder's is (FolderLooks.square): a bitmap at an odd size made IconServices fault.
            let set = NSWorkspace.shared.setIcon(FolderLooks.square(image), forFile: url.path, options: [])
            flog.notice("file menu: icon \(set ? "set" : "not set", privacy: .public) on \(url.path, privacy: .public)")
            HUD.tip(set ? "\(url.lastPathComponent) has its new icon" : "macOS did not take the icon for \(url.lastPathComponent)")
        }
    }

    /// Takes the icon back: a folder's design through FolderLooks, which puts back what it had; a file's or an app's own
    /// through NSWorkspace.setIcon with none, as Get Info's Delete does.
    private static func resetIcon(_ url: URL) {
        if FolderLooks.isFolder(url) {
            Task { HUD.tip(await FolderDesigns.reset([url]).line("Reset")) }
            return
        }
        let reset = NSWorkspace.shared.setIcon(nil, forFile: url.path, options: [])
        flog.notice("file menu: icon \(reset ? "reset" : "not reset", privacy: .public) on \(url.path, privacy: .public)")
        HUD.tip(reset ? "\(url.lastPathComponent) has its own icon back" : "macOS did not take the icon off \(url.lastPathComponent)")
    }

    /// The file's text: a PDF's words page by page, anything else as UTF-8, read no further than the cap needs.
    nonisolated static func text(of url: URL) -> String? {
        let most = FileAction.textLimit + 1
        if kind(url) == .pdf {
            guard let pdf = PDFDocument(url: url) else { return nil }
            var text = ""
            for i in 0..<pdf.pageCount where text.count < most { text += (pdf.page(at: i)?.string ?? "") + "\n" }
            return text
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Four bytes a character at most, so the cap's characters are all read; a read cut inside a character loses that
        // character, as the Files preview's does.
        guard let data = try? handle.read(upToCount: most * 4) else { return nil }
        return (0...3).lazy.compactMap { String(data: data.dropLast($0), encoding: .utf8) }.first ?? String(decoding: data, as: UTF8.self)
    }

    nonisolated static func isMarkdown(_ url: URL) -> Bool { MarkdownHTML.isMarkdown(url) }

    /// The picture as Ask AI sends a capture, read no bigger than it is sent.
    nonisolated static func picture(_ url: URL) -> AIChat.Image? {
        NoteAttachments.picture(at: url, pixels: Int(CaptureAskAI.longest)).flatMap(CaptureAskAI.picture)
    }
}

private let flog = Logger(subsystem: "dev.banozz.pilot", category: "files")
