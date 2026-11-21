import AppKit
import OSLog
import PilotCore
import UniformTypeIdentifiers

/// Act on any selection (spec launcher-best T11; the idea from Alfred's Universal Actions and File Buffer and LaunchBar's
/// Instant Send, their docs only): the menu opened over selected text leads its root with Translate, Ask AI and Act on
/// the selection…, which lists every text action Pilot already has (your AI commands, Search the web, Send to an app,
/// Copy as plain text); over Finder's selected files a search finds Act on the selected files… (Pilot's file actions),
/// Add to the file buffer and Send to an app. Files gathered into the buffer from several windows lead the root as Act
/// on the buffered files…. The text is read once as the menu opens, through Accessibility alone (PlaceholderReads, never
/// the app's Copy: no key is posted, ADR 0001), Finder's files through FinderItems; Send to opens it in the app through
/// `/usr/bin/open -a`, the app's own route, never a key or another automation target. Nothing read is logged.
@MainActor
enum SelectionActions {
    /// What the selection rows act on: text, or Finder's files.
    enum Held: Equatable, Sendable {
        case text(String), files([URL])
    }

    /// What the open menu's rows act on, read as it opened and never again; nil while nothing was selected.
    static var held: Held?
    /// Files gathered from Finder windows, kept until acted on, cleared or Pilot quits; in memory only.
    static var buffer: [URL] = []

    nonisolated static let prefix = "selection."
    /// Each row's id after the prefix; an AI command's is `ai:<its id>`.
    enum Verb: String, Sendable {
        case translate, ask, more, web, send, copy, files, bufferAdd = "buffer.add", bufferAct = "buffer.act", bufferClear = "buffer.clear"
    }
    nonisolated static let command = "ai:"

    nonisolated static func owns(_ id: String) -> Bool { id.hasPrefix(prefix) }

    /// The rows for what is held and the buffer: text's lead the root with Translate, Ask AI and Act on the selection…;
    /// files' are found by a search; the buffer's Act row leads while it holds files. `commands` are your AI commands
    /// (id, title), in your order.
    nonisolated static func rows(_ held: Held?, buffer: [URL], commands: [(id: String, title: String)]) -> [MenuEntry] {
        var rows: [MenuEntry] = []
        switch held {
        case .text(let text)?:
            let shown = preview(text)
            rows = [row("Translate", .translate, "character.book.closed", shown, "translate selection selected text language", leads: true),
                    row("Ask AI", .ask, "sparkles", shown, "ask ai chat selection selected text question", leads: true),
                    row("Act on the selection…", .more, "text.cursor", shown, "selection selected text actions universal", leads: true)]
                + textActions(text, commands: commands).filter { $0.target != .action(prefix + Verb.translate.rawValue) && $0.target != .action(prefix + Verb.ask.rawValue) }
        case .files(let urls)? where !urls.isEmpty:
            let count = files(urls.count)
            rows = [row("Act on the selected files…", .files, "doc.on.doc", "Finder selection", "selection selected files actions convert open with", detail: count),
                    row("Add to the file buffer", .bufferAdd, "tray.and.arrow.down", "Finder selection", "selection selected files buffer gather collect", detail: count),
                    row("Send to an app…", .send, "paperplane", "Finder selection", "selection selected files send open in app instant", detail: count)]
        default: break
        }
        guard !buffer.isEmpty else { return rows }
        return rows + [row("Act on the buffered files…", .bufferAct, "tray.full", "File buffer", "buffer buffered files actions convert", detail: files(buffer.count), leads: true),
                       row("Clear the file buffer", .bufferClear, "tray", "File buffer", "buffer buffered files clear empty", detail: files(buffer.count))]
    }

    /// Every action on selected text, as Act on the selection… lists them: Translate, Ask AI, your AI commands, Search the
    /// web, Send to an app…, Copy as plain text.
    nonisolated static func textActions(_ text: String, commands: [(id: String, title: String)]) -> [MenuEntry] {
        let shown = preview(text)
        return [row("Translate", .translate, "character.book.closed", shown, "translate selection selected text language"),
                row("Ask AI", .ask, "sparkles", shown, "ask ai chat selection selected text question")]
            + commands.map { c in
                MenuEntry(title: c.title, target: .action(prefix + command + c.id), keywords: "ai command selection selected text", ownKind: .selection,
                          subtitle: shown, icon: .glyph("sparkles", .accent)).onSelection()
            }
            + [row("Search the web", .web, "globe", shown, "search web google selection selected text"),
               row("Send to an app…", .send, "paperplane", shown, "send open in app instant selection selected text"),
               row("Copy as plain text", .copy, "doc.on.clipboard", shown, "copy plain text selection selected unformatted")]
    }

    private nonisolated static func row(_ title: String, _ verb: Verb, _ symbol: String, _ subtitle: String, _ words: String,
                                        detail: String? = nil, leads: Bool = false) -> MenuEntry {
        var entry = MenuEntry(title: title, target: .action(prefix + verb.rawValue), detail: detail, keywords: words, ownKind: .selection,
                              subtitle: subtitle, icon: .glyph(symbol, .accent)).onSelection()
        entry.leadsSelection = leads
        return entry
    }

    private nonisolated static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

    /// The selection as the rows' subtitle shows it: one line, quoted, cut at 40 characters.
    nonisolated static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return "“\(line.count > 40 ? String(line.prefix(39)) + "…" : line)”"
    }

    // MARK: Reading

    /// What is selected in `front` as the menu opens, off the main thread: Finder's files, else the text through
    /// Accessibility alone (the sandbox's PILOT_SANDBOX_SELECTION in its place); nil when nothing is.
    static func read(front: NSRunningApplication?) async -> (held: Held?, folders: [URL]) {
        if front?.bundleIdentifier == DesktopIcons.finder {
            let urls = await Task.detached(priority: .userInitiated) { FinderItems.selection() }.value
            return (urls.isEmpty ? nil : .files(urls), urls.filter(FolderLooks.isFolder))
        }
        return (await PlaceholderReads.selection().map(Held.text), [])
    }

    // MARK: Running

    /// Runs a selection row picked in the menu, which has closed, once the app Sven was in is in front again; `web`
    /// searches the web as the menu's own row does, `frontmost` waits for that app again after a picker this opens.
    static func run(_ id: String, web: @escaping (String) -> Void, frontmost: @escaping (@escaping () -> Void) -> Void) {
        let word = String(id.dropFirst(prefix.count))
        sellog.notice("selection: \(word.hasPrefix(command) ? "ai command" : word, privacy: .public)")
        if word.hasPrefix(command) {
            guard case .text(let text)? = held, let c = AICommandBook.shared.command(String(word.dropFirst(command.count))) else { return }
            // Its replace goes back over the selection read, Accessibility asked again with the app in front (T10).
            Task { if let found = await SelectionEdit.shared.capture(given: text) { await AICommands.shared.run(c, on: found) } }
            return
        }
        guard let verb = Verb(rawValue: word) else { return }
        switch (verb, held) {
        case (.translate, .text(let text)?): PilotMenu.shared.open(typing: text, in: .translate)
        case (.ask, .text(let text)?): SelectionBox.shared.open(service: text)
        case (.more, .text(let text)?): offerText(text, web: web, frontmost: frontmost)
        case (.web, .text(let text)?): web(text)
        case (.copy, .text(let text)?): SystemModule.copy(text, tip: "Copied as plain text")
        case (.send, let held?): offerSend(held)
        case (.files, .files(let urls)?): offerFiles(urls, buffered: false)
        case (.bufferAdd, .files(let urls)?): gather(urls)
        case (.bufferAct, _): if !buffer.isEmpty { offerFiles(buffer, buffered: true) }
        case (.bufferClear, _):
            buffer = []
            HUD.tip("The file buffer is empty")
        default: sellog.notice("selection: \(word, privacy: .public) has nothing selected to act on")
        }
    }

    /// Act on the selection (`apps.selectionActions`, no default key: Hyper+A is Capture full screen): the actions for
    /// what is selected in the app in front, read as Hyper+Space reads it, as a picker; the buffer's when nothing is.
    static func open() {
        let front = NSWorkspace.shared.frontmostApplication
        Task {
            let read = await read(front: front)
            held = read.held
            switch read.held {
            case .text(let text)?: offerText(text, web: searchWeb, frontmost: { $0() })
            case .files(let urls)?: offerFiles(urls, buffered: false)
            case nil: if buffer.isEmpty { HUD.tip(SelectionBox.nothingSelected) } else { offerFiles(buffer, buffered: true) }
            }
        }
    }

    /// Every action on selected text as a picker titled Selection; the one picked runs once the app is in front.
    private static func offerText(_ text: String, web: @escaping (String) -> Void, frontmost: @escaping (@escaping () -> Void) -> Void) {
        let commands = AICommandBook.shared.commands.map { (id: $0.id, title: $0.title) }
        PilotMenu.shared.pick(textActions(text, commands: commands), title: "Selection", logTitles: false) { row in
            guard case .action(let picked) = row.target else { return }
            frontmost { run(picked, web: web, frontmost: frontmost) }
        }
    }

    /// Search the web for `text` with the default browser's engine, as the menu's Search the web row does.
    private static func searchWeb(_ text: String) {
        WebSearchReader.open(text, with: WebSearchReader.read(browser: WebSearchReader.defaultBrowser(), fullDiskAccess: FileIndex.hasFullDiskAccess()))
    }

    /// Pilot's file actions on `urls` (FileActionsMenu) with the selection's own rows after them; an action picked on the
    /// buffer empties it, as Alfred's does once acted on.
    private static func offerFiles(_ urls: [URL], buffered: Bool) {
        FileActionsMenu.show(urls, at: nil, extra: extras(urls, buffered: buffered)) { _ in
            if buffered { buffer = [] }
            return false
        }
    }

    /// The rows the file actions' picker ends with: Send to an app, then Add to the file buffer, or Clear the file buffer
    /// on the buffer's own. Hyper + right-click on a file lists them too, so files from several windows gather there.
    static func extras(_ urls: [URL], buffered: Bool = false) -> [FileActionsMenu.Extra] {
        [.init(title: "Send to an app…", symbol: "paperplane") { offerSend(.files(urls)) },
         buffered ? .init(title: "Clear the file buffer", symbol: "tray") { buffer = [] }
             : .init(title: "Add to the file buffer", symbol: "tray.and.arrow.down") { gather(urls) }]
    }

    /// `urls` into the buffer, each file once.
    private static func gather(_ urls: [URL]) {
        buffer += urls.filter { url in !buffer.contains { $0.standardizedFileURL == url.standardizedFileURL } }
        HUD.tip("\(files(buffer.count)) in the buffer")
    }

    // MARK: Send to an app

    /// The apps that open what is held, by name, as Open With lists them; the picker sends it to the one picked.
    private static func offerSend(_ held: Held) {
        Task {
            let apps = await Task.detached(priority: .userInitiated) { receivers(held) }.value
            guard !apps.isEmpty else { return HUD.tip("No app opens that") }
            let byBundle = apps.compactMap { url in Bundle(url: url)?.bundleIdentifier.map { ($0, url) } }
            let urls = Dictionary(byBundle) { first, _ in first }
            let rows = byBundle.map { MenuEntry(title: name(of: $0.1), target: .app($0.0)) }
            PilotMenu.shared.pick(rows, title: "Send to", logTitles: false) { row in
                guard case .app(let bundle) = row.target, let app = urls[bundle] else { return }
                send(held, to: app)
            }
        }
    }

    /// An app's name as Finder shows it, without `.app`.
    private nonisolated static func name(of app: URL) -> String { FileManager.default.displayName(atPath: app.path).replacing(".app", with: "") }

    /// The app `word` names, as `pilot menu send` takes it: a bundle id, an app's path, or an installed app's name.
    static func app(_ word: String) -> URL? {
        if word.hasSuffix(".app"), FileManager.default.fileExists(atPath: word) { return URL(filePath: word) }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: word) { return url }
        let named = AppsModule.installedApps().first { $0.name.caseInsensitiveCompare(word) == .orderedSame }
        return named.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) }
    }

    /// The apps Launch Services says open what is held: for text, plain text's; for files, the ones every file names.
    nonisolated static func receivers(_ held: Held) -> [URL] {
        let workspace = NSWorkspace.shared
        let apps: [URL]
        switch held {
        case .text: apps = workspace.urlsForApplications(toOpen: .plainText)
        case .files(let urls):
            guard let first = urls.first else { return [] }
            let rest = urls.dropFirst().map { Set(workspace.urlsForApplications(toOpen: $0).map(\.standardizedFileURL)) }
            apps = workspace.urlsForApplications(toOpen: first).filter { app in rest.allSatisfy { $0.contains(app.standardizedFileURL) } }
        }
        var seen = Set<String>()
        return apps.filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// What Send to runs: `/usr/bin/open -a <app> <files>`, text as a plain text file `Selection.txt` in a folder of
    /// its own under `folder`. Pure, so `pilot menu send` shows it unrun.
    nonisolated static func plan(_ held: Held, to app: URL, folder: URL) -> (command: [String], textFile: URL?) {
        switch held {
        case .text:
            let file = folder.appending(path: "Selection.txt")
            return (["/usr/bin/open", "-a", app.path, file.path], file)
        case .files(let urls): return (["/usr/bin/open", "-a", app.path] + urls.map(\.path), nil)
        }
    }

    /// Sends what is held to `app` as the plan says, its text written first; a refusal says so in a tip.
    /// A folder of its own for one send's text file.
    nonisolated static func sendFolder() -> URL { FileManager.default.temporaryDirectory.appending(path: "Pilot selection \(UUID().uuidString)") }

    static func send(_ held: Held, to app: URL) {
        let folder = sendFolder()
        let planned = plan(held, to: app, folder: folder)
        let name = name(of: app)
        do {
            if case .text(let text) = held, let file = planned.textFile {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            let open = Process()
            open.executableURL = URL(filePath: planned.command[0])
            open.arguments = Array(planned.command.dropFirst())
            open.terminationHandler = { p in
                let status = p.terminationStatus
                Task { @MainActor in
                    sellog.notice("selection: sent to \(name, privacy: .public), open exited \(status)")
                    if status != 0 { HUD.tip("\(name) did not open it") }
                }
            }
            try open.run()
        } catch {
            sellog.error("selection: send to \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            HUD.tip("\(name) did not open it")
        }
    }
}

private extension MenuEntry {
    func onSelection() -> MenuEntry {
        var row = self
        row.onSelection = true
        return row
    }
}

private let sellog = Logger(subsystem: "dev.banozz.pilot", category: "selection")
