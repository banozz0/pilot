import AppKit
import Clipboard
import Observation
import OSLog
import PilotCore
import SwiftUI

let cliplog = Logger(subsystem: "dev.banozz.pilot", category: "clipboard")

/// Clipboard history and its panel (story 89, wireframe ol5Ak83dAho section 3): the watcher records copies from
/// launch, the panel lists them with pins on top and a preview, and Return pastes into the app Sven was in by
/// writing the pasteboard, then posting Cmd+V into that app (ADR 0001 allows a keystroke into the focused app).
/// Observable for its settings only: Settings › Clipboard follows a sort changed in the panel (card agent-bo-95422783).
@Observable @MainActor
final class ClipboardHistory: ScreenPausing {
    static let shared = ClipboardHistory()
    /// Read by the pilot command too (CLI W11); nil while the history is not running.
    @ObservationIgnored private(set) var store: ClipboardStore?
    @ObservationIgnored private var watcher: ClipboardWatcher?
    /// Reads the text in image copies (card agent-bo-95423070): each new one, and at launch any not read yet.
    @ObservationIgnored private var ocr: ClipboardOCR?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var model: PanelModel?
    /// Where the menu stood when its Trigger › Clipboard row opened the panel; Escape goes back there (card agent-bo-95423020).
    @ObservationIgnored private var menuBack: MenuNavigator.Spot?
    /// The dropdown's Clipboard switch (SessionSwitch.clipboard, card agent-bo-95422912): paused, nothing copied is kept;
    /// resumed, recording starts from what is on the pasteboard then, never what was copied meanwhile.
    /// Paused, the secrets already due leave the disk now, not when recording resumes; the rest stay hidden once due (P65).
    func setRecording(_ on: Bool) {
        on ? watcher?.start() : watcher?.stop()
        if !on { do { try store?.prune() } catch { cliplog.error("clipboard prune: \(String(describing: error), privacy: .public)") } }
        cliplog.notice("clipboard recording \(on ? "on" : "paused", privacy: .public)")
    }

    /// Locked or asleep (card agent-bo-95422839): the watcher stops polling; unlocked, it keeps what was copied meanwhile.
    func pause() { watcher?.pause() }
    func resume() { watcher?.resume() }

    /// Settings › Clipboard, read at launch; `apply` stores a change and puts it into effect at once.
    private(set) var settings: ClipboardSettings
    /// Where the settings live: the app's own, or a test's.
    @ObservationIgnored private let defaults: UserDefaults

    /// `store` a test's or a render's, read without a watcher; the app's opens in `start()`.
    init(defaults: UserDefaults = .pilot(), store: ClipboardStore? = nil) {
        self.defaults = defaults
        self.store = store
        settings = ClipboardSettings(defaults: defaults)
    }

    func start() {
        guard store == nil else { return }
        do {
            // Pilot's folder: in a test run, the run's own.
            let path = PilotFolder.support.appending(path: "clipboard.sqlite")
            let store = try ClipboardStore(path: path)
            self.store = store
            let ocr = ClipboardOCR(store: store, recognizer: HelperText.standard)
            self.ocr = ocr
            watcher = ClipboardWatcher(store: store)
            // A copy stored or an image's text read while the panel is open shows at once, not at the next keystroke.
            watcher?.onStore = { [weak self] in ocr.catchUp(); self?.model?.refresh() }
            watcher?.onExpire = { [weak self] in self?.model?.refresh() }
            ocr.onRead = { [weak self] in self?.model?.refresh() }
            configure(prune: true)
            watcher?.start()
            ocr.catchUp()
            cliplog.notice("clipboard history started at \(path.path, privacy: .public)")
        } catch {
            cliplog.error("clipboard store: \(String(describing: error), privacy: .public)")
        }
    }

    func apply(_ settings: ClipboardSettings) {
        let limitsChanged = settings.keepCount != self.settings.keepCount || settings.keepDays != self.settings.keepDays
            || settings.secretLifetime != self.settings.secretLifetime
        self.settings = settings
        settings.save(to: defaults)
        configure(prune: limitsChanged)
    }

    /// Puts the settings into the store and watcher; a limit lowered, or a day passed since the last run, prunes now.
    private func configure(prune: Bool) {
        watcher?.capture = settings.capture
        if model?.order != settings.order { model?.order = settings.order }
        guard let store else { return }
        store.cap = settings.keepCount
        store.maxAge = settings.maxAge
        guard prune else { return }
        do {
            try store.setSecretLifetime(settings.secretLifetime)
            try store.prune()
        } catch { cliplog.error("clipboard prune: \(String(describing: error), privacy: .public)") }
    }

    /// Clear history: every unpinned item goes.
    func clear() {
        do { try store?.clear() } catch { cliplog.error("clipboard clear: \(String(describing: error), privacy: .public)") }
    }

    /// Home's Last copied (card agent-bo-95422992): the newest item and how many the history holds; nil while not running.
    func newest() -> (clip: StoredClip, count: Int)? {
        guard let all = try? store?.recent(), let first = all.first else { return nil }
        return (first, all.count)
    }

    /// Settings › Clipboard › Recent (card agent-bo-95423004): every kept copy, newest first; none while not running.
    func recent() -> [StoredClip] { (try? store?.recent()) ?? [] }

    /// A change the pilot command made shows in an open panel at once, as a copy does.
    func changedFromControl() { model?.refresh() }

    /// Paste one by one from the pilot command: the panel's own sequence, so the tap's Cmd+V reports reach it. The
    /// caller posts the first Cmd+V.
    func startSequence(_ clips: [StoredClip]) throws {
        guard let store else { return }
        try sequence.start(clips, from: store)
    }

    #if DEBUG
    /// The renders' seeded history, read without a watcher.
    func useStore(_ store: ClipboardStore?) { self.store = store }
    #endif

    /// Settings › Clipboard › Tags (card agent-bo-95422782): the tags, and their rename, recolour and delete.
    func tags() -> [ClipTag] { (try? store?.tags()) ?? [] }

    func editTag(_ tag: ClipTag) {
        do { try store?.updateTag(tag) } catch { cliplog.error("clipboard tag \(tag.id): \(String(describing: error), privacy: .public)") }
    }

    func deleteTag(_ id: Int64) {
        do { try store?.deleteTag(id) } catch { cliplog.error("clipboard tag delete: \(String(describing: error), privacy: .public)") }
    }

    /// Its action's id, whose alias with words opens it searching them (T42).
    static let actionID = "apps.clipboard"

    /// Runs after the tap callback returns: building the rows reads the store, too slow for the tap. `words` open it
    /// searching them ("cb invoice", T42).
    func toggle(searching words: String? = nil) {
        let back = PilotMenu.origin
        DispatchQueue.main.async { self.toggleNow(back: back, searching: words) }
    }

    private func toggleNow(back: MenuNavigator.Spot?, searching words: String?) {
        if panel != nil { close(); return }
        menuBack = back
        guard let store else { HUD.tip("Clipboard history is not running."); return }
        let model = PanelModel(store: store, order: settings.order)
        if let words { model.query = words }
        self.model = model
        model.run = { [weak self, weak model] in if let self, let model { self.perform($0, model) } }
        let p = Self.makePanel(model, returnCopies: settings.returnAction == .copy)
        panel = p
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // The panel's keys go to handle; letters go on to the search field, given the keyboard if it lost it (card agent-bo-95422767).
        keyMonitor = HUD.showSearchPanel(p, handle: { [weak self] in self?.handle($0, $1, $2) == true },
                                         keepsSearch: { [weak self] in self?.model?.prompt != .edit },
                                         log: { cliplog.notice("clipboard panel: \($0, privacy: .public)") })
        cliplog.notice("clipboard panel shown, \(model.rows.count) rows, over \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
    }

    static func makePanel(_ model: PanelModel, returnCopies: Bool) -> NSPanel {
        HUD.makePanel(ClipboardPanelView(model: model, returnCopies: returnCopies), surface: .clipboard)
    }

    private func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        resignObserver = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    private func handle(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ characters: String?) -> Bool {
        guard let model else { return false }
        let key: PanelCommand.Key? = switch code {
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 36, 76: .return
        case 53: .escape
        case 51: .backspace
        case 48: .tab
        default: characters?.lowercased().first.map { .character($0) }
        }
        // The search field's caret, for Left and Right at the ends of the typed text.
        let caret = HUD.caretEnds(in: panel)
        let textSelected = (panel.flatMap(HUD.searchCaret)?.selection.length ?? 0) > 0
        guard let key, let command = PanelCommand(key: key, command: flags.contains(.command), option: flags.contains(.option),
                                                  shift: flags.contains(.shift), control: flags.contains(.control),
                                                  returnCopies: settings.returnAction == .copy, textSelected: textSelected,
                                                  prompting: model.prompt != nil, editing: model.prompt == .edit,
                                                  caretAtStart: caret.atStart, caretAtEnd: caret.atEnd,
                                                  searchEmpty: model.query.isEmpty, snippets: model.showsSnippets,
                                                  picked: model.pickCount > 0, keysShown: model.showsKeys) else { return model.showsKeys }
        // While Cmd+/'s list stands in for the panel only Escape and Cmd+/ act; every other key is held, so the hidden
        // query, tab, selection and picks are as they were when the list goes (Sven, Build 79).
        if model.showsKeys && command != .keys { return true }
        perform(command, model)
        return true
    }

    private func perform(_ command: PanelCommand, _ model: PanelModel) {
        if command != .keys { model.showsKeys = false }
        switch command {
        case .paste where model.showsSnippets: paste(model.selectedSnippet)
        case .pasteRow(let row) where model.showsSnippets: paste(model.snippetRows.indices.contains(row) ? model.snippetRows[row] : nil)
        case .paste(let plain): put(model.targets, plain: plain, paste: true)
        case .pasteRow(let row): put(model.rows.indices.contains(row) ? [model.rows[row]] : [], plain: false, paste: true)
        case .copy: put(model.targets, plain: false, paste: false)
        case .move(let step): model.move(step)
        case .extend(let step): model.extend(step)
        case .pickAll: model.pickAll()
        case .togglePin: model.togglePin()
        case .delete: model.deleteSelected()
        case .cycleFilter(let step): model.stepTab(step)
        case .tag: model.open(.tag)
        case .actions: model.open(.actions)
        case .confirm: if model.confirm() { put(model.targets, plain: false, paste: true, delete: true) }
        case .dismiss: model.dismiss()
        case .pasteAndDelete(let plain): put(model.targets, plain: plain, paste: true, delete: true)
        case .deleteTag: model.askDeleteTag()
        case .pasteInSequence: pasteInSequence(model.targets)
        case .togglePick: model.togglePick()
        case .clearPicks: model.clearPicks()
        case .keys: model.showsKeys.toggle()
        case .editSnippets:
            close()
            AppWindowController.shared.open(.snippets)
        case .cycleSort: sort { $0.sort = $0.sort.next }
        case .reverseSort: sort { $0.reversed.toggle() }
        case .close:
            close()
            if let menuBack { PilotMenu.shared.reopen(menuBack) }
        }
    }

    /// Paste in sequence (card agent-bo-95423071): the tap reports each Cmd+V, Pilot's own too, so this one pastes the first.
    @ObservationIgnored private lazy var sequence = PasteSequence { event in
        cliplog.notice("clipboard sequence \(String(describing: event), privacy: .public)")
        switch event {
        case .started(let count): HUD.tip("Pasting \(count) one by one: ⌘V pastes the next.")
        case .done(let count): HUD.tip("All \(count) pasted.")
        case .next, .ended: break
        }
    }

    /// Hyper+Alt+V (card agent-bo-95423072): what is copied pastes as plain text into the focused app, and the copy goes
    /// back once it has read it. After the tap callback returns: it reads the pasteboard.
    func pastePlain() {
        DispatchQueue.main.async { [store] in
            let target = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            let count = PlainPaste(store: store, post: { Post.key(KeyCode.v, .cmd) }).run()
            cliplog.notice("clipboard paste plain \(count.map { "\($0) characters" } ?? "as it is", privacy: .public) into \(target, privacy: .public)")
        }
    }

    /// A Cmd+V went by: a running sequence puts its next item on.
    func pasted() { sequence.pasted() }

    /// One target is an ordinary paste; several go on one by one, the first pasted now.
    private func pasteInSequence(_ clips: [StoredClip]) {
        guard clips.count > 1, let store else { return put(clips, plain: false, paste: true) }
        do { try sequence.start(clips, from: store) } catch {
            cliplog.error("clipboard sequence \(clips.map(\.id)): \(String(describing: error), privacy: .public)"); return
        }
        leave("sequence ids=\(clips.map(\.id))", paste: true)
    }

    /// Closes the panel and, for a paste, sends Cmd+V to the app Sven was in: the panel never activated Pilot, so that
    /// app has focus again once the panel is gone. `steps`: several pastes, each with its own Cmd+V (PasteSteps).
    private func leave(_ what: String, paste: Bool, steps: [PanelRows.Paste]? = nil) {
        close()
        cliplog.notice("clipboard \(what, privacy: .public)\(steps.map { " in \($0.count) steps" } ?? "", privacy: .public) into \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
        guard paste else { return }
        let post = { Post.key(KeyCode.v, .cmd) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { if let steps { PasteSteps(post: post).run(steps) } else { post() } }
    }

    /// A snippet into the app Sven was in, as Hyper+Space › Snippets pastes it: one that takes an argument opens
    /// Hyper+Space on Snippets with its name typed, so Sven types the argument there.
    private func paste(_ snippet: Snippet?) {
        guard let snippet else { return }
        close()
        cliplog.notice("clipboard snippet \(snippet.name, privacy: .public) into \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
        if snippet.needsArgument { return PilotMenu.shared.askArgument(for: snippet) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { SnippetLibrary.shared.paste(SnippetPick(id: snippet.id)) }
    }

    /// Settings › Clipboard keeps the new order, and `configure` shows it in the panel at once.
    private func sort(_ change: (inout ClipOrder) -> Void) {
        var settings = settings
        change(&settings.order)
        apply(settings)
    }

    /// The clips on the pasteboard as one paste; `delete` then removes them from the history. A `paste` of several that
    /// cannot go on as one (an image among them) writes nothing and returns its steps, for PasteSteps. The panel's paste
    /// and copy, and the pilot command's (CLI W11, on a test's own pasteboard there).
    @discardableResult
    func write(_ clips: [StoredClip], plain: Bool, delete: Bool = false, paste: Bool = false,
               to pasteboard: NSPasteboard = .general) throws -> [PanelRows.Paste]? {
        guard let store else { return nil }
        let steps = try PanelRows.write(clips, from: store, plain: plain, forget: delete, paste: paste, to: pasteboard)
        if delete { try store.delete(clips.map(\.id)) }
        return steps
    }

    /// Writes the clips to the pasteboard as one paste and closes; a paste then sends Cmd+V to the app that has focus
    /// again, or pastes them in steps when they cannot go on as one (an image among them, PanelRows.steps). `delete`
    /// (Option+Return) removes them from the history once they are read.
    private func put(_ clips: [StoredClip], plain: Bool, paste: Bool, delete: Bool = false) {
        guard !clips.isEmpty, store != nil else { return }
        let steps: [PanelRows.Paste]?
        do { steps = try write(clips, plain: plain, delete: delete, paste: paste) } catch {
            cliplog.error("clipboard read \(clips.map(\.id)): \(String(describing: error), privacy: .public)"); return
        }
        leave("\(paste ? (plain ? "paste plain" : "paste") : "copy")\(delete ? " and delete" : "") ids=\(clips.map(\.id))", paste: paste, steps: steps)
    }
}

/// The QR code each image copy holds (Sven, Q398), read for its preview only, never for the whole history, and kept per
/// copy across openings so the panel never reads one twice; "" is none. The oldest go past `limit`. Kept by id and first
/// copy, as the store hands a deleted copy's id to the next one.
@Observable @MainActor
final class ClipCodes {
    struct Key: Hashable {
        let id: Int64, first: Date
        init(_ clip: StoredClip) { id = clip.id; first = clip.firstCopiedAt }
    }

    static let shared = ClipCodes()
    private(set) var found: [Key: String] = [:]
    @ObservationIgnored private var order: [Key] = []
    static let limit = 256

    /// The copy's code once read; nil before, and for none.
    func code(of clip: StoredClip) -> ClipCode? { found[Key(clip)].flatMap { $0.isEmpty ? nil : ClipCode($0) } }

    func knows(_ clip: StoredClip) -> Bool { found[Key(clip)] != nil }

    func note(_ key: Key, _ payload: String) {
        guard found[key] == nil else { return }
        order.append(key)
        found[key] = payload
        while order.count > Self.limit { found[order.removeFirst()] = nil }
    }
}

@Observable @MainActor
final class PanelModel {
    private let store: ClipboardStore
    /// Cmd+/'s list of every key, in place of the search, tabs, rows and preview; Escape or Cmd+/ shuts it.
    var showsKeys = false
    var query = "" { didSet { guard query != oldValue else { return }; showsKeys = false; selection = PanelSelection(); snippetCursor = 0; reload() } }
    /// The kind or tag Left, Right, Tab and Shift+Tab step through (cards agent-bo-95422781 and 970).
    var tab = PanelTab.kind(.all) { didSet { selection = PanelSelection(); snippetCursor = 0; reload() } }
    var tabs: [PanelTab] { PanelTab.all(tags: allTags) }
    /// The search as parsed, kept for the rows' highlights.
    private(set) var parsed = ClipQuery("")
    /// Cmd+T, Cmd+K and the actions that need typing: the search field types a tag's name, an action's name, the
    /// copy's new name or its new text instead, and the preview lists the choices (cards agent-bo-95422782 and 784).
    /// The search and the picks stay as they were.
    /// `deleteTag`: Cmd+Shift+Backspace on a tag's tab asks before the tag goes (card agent-bo-95422986).
    enum Prompt: Equatable { case tag, actions, rename, edit, deleteTag(ClipTag) }
    private(set) var prompt: Prompt?
    private(set) var promptText = ""
    private(set) var promptCursor = 0
    private var allTags: [ClipTag] = []
    var tagChoices: [TagChoice] { TagChoice.list(typed: promptText, tags: allTags) }
    var actionChoices: [ClipAction] {
        ClipAction.available(for: targets, code: targets.count == 1 ? targets.first.flatMap(codes.code(of:)) : nil).filter { named($0.title) }
    }
    /// Cmd+K's list as its rows show it; on the Snippets tab, paste the snippet at the cursor or edit them all, each
    /// with the command it runs.
    struct ActionRow { let title: String, key: String?; var command: PanelCommand? }
    var actionRows: [ActionRow] {
        guard showsSnippets else { return actionChoices.map { ActionRow(title: $0.title, key: $0.key) } }
        return [selectedSnippet.map { _ in ActionRow(title: "Paste", key: "↵", command: .paste(plain: false)) },
                ActionRow(title: "Edit snippets", key: "⌘E", command: .editSnippets)].compactMap(\.self).filter { named($0.title) }
    }
    /// What Cmd+K's list acts on.
    var actionsHeading: String {
        showsSnippets ? selectedSnippet?.name ?? "Snippets" : targets.count == 1 ? "1 item" : "\(targets.count) items"
    }
    private func named(_ title: String) -> Bool {
        let name = promptText.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || title.localizedCaseInsensitiveContains(name)
    }
    private var choiceCount: Int { prompt == .tag ? tagChoices.count : prompt == .actions ? actionRows.count : 0 }
    /// The tags every target has, ticked in the tag list; choosing one of them untags.
    var sharedTagIDs: Set<Int64> {
        targets.map { Set($0.tags.map(\.id)) }.reduce(nil) { $0?.intersection($1) ?? $1 } ?? []
    }
    private let actions: ClipActions
    private(set) var rows: [StoredClip] = []
    /// Images whose text is still being read: a search cannot find them by their words yet, so the list says so.
    private(set) var readingCount = 0
    var readingLine: String? {
        guard readingCount > 0 else { return nil }
        return "Reading the text in \(readingCount) image\(readingCount == 1 ? "" : "s")…"
    }
    /// The cursor plus the rows picked with Shift+arrows or Cmd+A (card agent-bo-95422780).
    private(set) var selection = PanelSelection()
    private(set) var preview: NSImage?
    /// The copy `preview` shows, so a reload on the same row (each keystroke) neither reads nor decodes it again.
    @ObservationIgnored private var previewOf: Int64?
    /// The preview's longest side: sharp at the panel's size on a Retina screen, never the whole image, which a 5K
    /// screenshot decoded to about 59 MB at every cursor move.
    nonisolated static let previewPixels = 1600
    /// Where the searched words are written on the previewed image (0 to 1, origin top left), when it matched through
    /// the text read from it: read again for this image only, off the main thread.
    private(set) var previewBoxes: [CGRect] = []
    @ObservationIgnored private let recognizer: any TextRecognizing
    @ObservationIgnored private var boxesTask: Task<Void, Never>?
    @ObservationIgnored private var codeTask: Task<Void, Never>?
    let codes: ClipCodes
    /// The Snippets tab, or type:snippet typed (Sven, 2026-10-08): the saved snippets matching the search, in the
    /// editor's order, and the cursor over them. Not copies: no pin, tag or pick.
    var showsSnippets: Bool { parsed.snippets }
    private(set) var snippetRows: [Snippet] = []
    private(set) var snippetCursor = 0
    var selectedSnippet: Snippet? { snippetRows.indices.contains(snippetCursor) ? snippetRows[snippetCursor] : nil }
    /// SnippetLibrary's, read only while the Snippets tab shows; a test's own.
    private let snippets: () -> [Snippet]

    /// Cmd+S and Cmd+Shift+S; Settings › Clipboard keeps it for the next opening (card agent-bo-95422783). The cursor goes
    /// to the new first row: following its row to wherever the order put it looked like a jump to a random spot (Sven).
    var order: ClipOrder { didSet { reload(toTop: true) } }

    init(store: ClipboardStore, order: ClipOrder = ClipOrder(), opener: any ClipOpening = PilotOpener(),
         snippets: @escaping () -> [Snippet] = { SnippetLibrary.shared.snippets }, recognizer: any TextRecognizing = HelperText.standard,
         codes: ClipCodes = .shared) {
        self.store = store
        self.codes = codes
        self.order = order
        self.snippets = snippets
        self.recognizer = recognizer
        actions = ClipActions(store: store, opener: opener)
        reload()
    }

    var cursor: Int { selection.cursor }
    var selected: StoredClip? { rows.indices.contains(cursor) ? rows[cursor] : nil }
    /// What Return, Cmd+C, Shift+Return, Cmd+Backspace and Cmd+P act on: the picks in pick order, else the cursor row.
    var targets: [StoredClip] { selection.targets(in: rows) }
    func pickNumber(_ clip: StoredClip) -> Int? { selection.pickNumber(of: clip.id) }

    var pickCount: Int { selection.picks.count }

    /// Several picks preview as a numbered list in pick order: an image as its thumbnail, anything else as `line` gives it
    /// (Sven, build 46: three images read "Image" three times).
    var picked: [StoredClip]? { pickCount > 1 ? targets : nil }

    /// A pick's first line with text, cut at 200 characters.
    static func line(_ clip: StoredClip) -> String {
        String((clip.title.split(separator: "\n", omittingEmptySubsequences: true).first ?? "").prefix(200))
    }

    /// A picked image's thumbnail in the picked list: `pickHeight` high, as wide as its shape, at most 200 points; a square
    /// while it is made.
    static let pickHeight: CGFloat = 64
    static func pickWidth(_ image: NSImage?) -> CGFloat {
        guard let size = image?.size, size.height > 0 else { return pickHeight }
        return min(200, (pickHeight * size.width / size.height).rounded())
    }

    /// Image copies' pictures, `thumbnailPixels` on their longest side at most, for their rows and the picked preview.
    /// Each is read from the store as its row first draws and decoded off the main thread; a row redraws once it is in.
    /// At most `thumbnailLimit` are kept, oldest out first.
    private(set) var thumbnails: [Int64: NSImage] = [:]
    @ObservationIgnored private var thumbnailOrder: [Int64] = []
    /// Being decoded, or not decodable: neither is asked for again.
    @ObservationIgnored private var thumbnailsAsked: Set<Int64> = []
    nonisolated static let thumbnailPixels = 240
    static let thumbnailLimit = 48

    /// The image copy's thumbnail when it is made; nil for any other copy, and while it is made.
    func thumbnail(_ clip: StoredClip) -> NSImage? {
        guard clip.kind == .image else { return nil }
        if let image = thumbnails[clip.id] { return image }
        guard thumbnailsAsked.insert(clip.id).inserted, let data = try? store.image(of: clip.id) else { return nil }
        let id = clip.id
        Task { [weak self] in
            guard let image = await Task.detached(priority: .userInitiated, operation: { Self.downsample(data) }).value, let self else { return }
            thumbnailsAsked.remove(id)
            thumbnailOrder.append(id)
            thumbnails[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            while thumbnailOrder.count > Self.thumbnailLimit { thumbnails[thumbnailOrder.removeFirst()] = nil }
        }
        return nil
    }

    /// The picture at most `maxPixels` a side (a row's thumbnail unless told), decoded at that size rather than whole and scaled.
    nonisolated static func downsample(_ data: Data, maxPixels: Int = thumbnailPixels) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    func move(_ step: Int) {
        if prompt != nil {
            promptCursor = min(max(promptCursor + step, 0), max(choiceCount - 1, 0))
        } else if showsSnippets {
            snippetCursor = min(max(snippetCursor + step, 0), max(snippetRows.count - 1, 0))
        } else {
            select { $0.move(step, in: rows) }
        }
    }
    func stepTab(_ step: Int) { tab = tab.step(step, in: tabs) }
    /// The panel owner's command runner, for what a click does (card agent-bo-95422994).
    var run: ((PanelCommand) -> Void)?
    /// The pointer over a row moves the cursor there; with rows picked it leaves them be.
    func hover(at index: Int) {
        guard prompt == nil else { return }
        if showsSnippets { if snippetRows.indices.contains(index) { snippetCursor = index } }
        else if pickCount == 0 { select { $0.place(index, in: rows) } }
    }
    /// A click puts the cursor on the row alone and does what Return does; a Cmd+click picks or unpicks it as
    /// Cmd+Return does; while a prompt asks, the rows wait. A snippet pastes; it is never picked.
    func click(at index: Int, returnCopies: Bool, command: Bool = false) {
        if showsSnippets, prompt == nil, !command, snippetRows.indices.contains(index) {
            snippetCursor = index
            run?(.paste(plain: false))
            return
        }
        guard prompt == nil, rows.indices.contains(index) else { return }
        if command { return select { $0.toggle(index, in: rows) } }
        select { $0.place(index, in: rows) }
        run?(.click(returnCopies: returnCopies))
    }
    /// The pointer over a Cmd+T or Cmd+K choice moves to it; a click confirms it, as Return does.
    func hoverChoice(at index: Int) { if (0..<choiceCount).contains(index) { promptCursor = index } }
    func clickChoice(at index: Int) {
        guard (0..<choiceCount).contains(index) else { return }
        promptCursor = index
        run?(.confirm)
    }
    func extend(_ step: Int) { select { $0.extend(step, in: rows) } }
    func togglePick() { let index = cursor; select { $0.toggle(index, in: rows) } }
    func pickAll() { select { $0.pickAll(rows) } }
    func clearPicks() { select { $0.clearPicks() } }

    private func select(_ change: (inout PanelSelection) -> Void) {
        change(&selection)
        loadPreview()
    }

    /// Pins every target, or unpins them all when every one is pinned already.
    func togglePin() {
        try? actions.run(.pin, on: targets)
        reload(keeping: selected?.id)
    }

    /// On the Snippets tab only Cmd+K's list opens.
    func open(_ prompt: Prompt) {
        guard showsSnippets ? prompt == .actions : !targets.isEmpty else { return }
        promptText = switch prompt {
        case .rename: targets.first?.customTitle ?? ""
        case .edit: targets.first?.text ?? ""
        case .tag, .actions, .deleteTag: ""
        }
        promptCursor = 0
        self.prompt = prompt
    }

    func dismiss() { prompt = nil; promptText = "" }

    /// Cmd+Shift+Backspace on a tag's tab: asks, and Return deletes the tag from its items, never the items.
    func askDeleteTag() {
        guard case .tag(let tag) = tab else { return }
        promptText = ""
        prompt = .deleteTag(tag)
    }

    /// The search field types into the open prompt.
    func type(_ text: String) {
        guard prompt != nil else { return }
        promptText = text
        promptCursor = 0
    }

    /// Return in a prompt. A tag goes on every target, or comes off them all when every one has it; an action runs
    /// (rename and edit open their own prompt first); a name or a text is saved. True for paste and delete, which the
    /// panel's owner runs because it pastes.
    func confirm() -> Bool {
        if prompt == .actions, showsSnippets {
            let command = actionRows.dropFirst(promptCursor).first?.command
            dismiss()
            if let command { run?(command) }
            return false
        }
        let ids = targets.map(\.id), text = promptText, prompt = prompt
        let tag = prompt == .tag ? tagChoices.dropFirst(promptCursor).first : nil
        let shared = sharedTagIDs
        let action = prompt == .actions ? actionChoices.dropFirst(promptCursor).first : nil
        dismiss()
        switch (prompt, tag, action) {
        case (.tag, .create(let name)?, _): try? store.tag(ids, with: name)
        case (.tag, .existing(let tag)?, _) where shared.contains(tag.id): try? store.untag(ids, from: tag.id)
        case (.tag, .existing(let tag)?, _): try? store.tag(ids, with: tag.name)
        case (.actions, _, .pasteAndDelete?): return true
        case (.actions, _, .pasteInSequence?): run?(.pasteInSequence); return false
        case (.actions, _, .rename?): open(.rename)
        case (.actions, _, .edit?): open(.edit)
        case (.actions, _, let action?):
            let made = (try? actions.run(action, on: targets)) ?? []
            reload(keeping: selected?.id)
            if !made.isEmpty { select { $0.select(made, in: rows) } }
            return false
        case (.rename, _, _): if let id = ids.first { try? store.rename(id, to: text) }
        case (.edit, _, _): if let id = ids.first, !text.isEmpty { try? store.setText(id, to: text) }
        case (.deleteTag(let tag)?, _, _): try? store.deleteTag(tag.id)
        default: break
        }
        reload(keeping: selected?.id)
        return false
    }

    func deleteSelected() {
        try? actions.run(.delete, on: targets)
        reload()
    }

    /// The store changed while the panel is open (a copy, an image's text read): a search typed meanwhile finds it now,
    /// the cursor kept on its row.
    func refresh() { reload(keeping: selected?.id) }

    private func reload(keeping id: Int64? = nil, toTop: Bool = false) {
        // Assigned only on a change, so a keystroke does not redraw the tabs.
        let tags = (try? store.tags()) ?? []
        if tags != allTags { allTags = tags }
        // A tag that went (deleted, or its last item untagged) takes its tab with it; All is open instead.
        // Setting the tab reloads again through its didSet, so this pass stops here.
        if case .tag(let open) = tab, !tags.contains(where: { $0.id == open.id }) { tab = .kind(.all); return }
        parsed = ClipQuery(query, tab: tab, order: order)
        // Counted only while a search could miss them: every keystroke reloads.
        let reading = parsed.searchesImageText ? (try? store.unreadImageCount()) ?? 0 : 0
        if reading != readingCount { readingCount = reading }
        if parsed.snippets {
            snippetRows = snippets().filter { parsed.matches([$0.name, $0.keyword, $0.text]) }
            snippetCursor = min(snippetCursor, max(snippetRows.count - 1, 0))
            rows = []
        } else {
            snippetRows = []
            rows = PanelRows.ordered((try? store.search(parsed)) ?? [])
        }
        selection.refit(rows, cursorOn: toTop ? rows.first?.id : id)
        loadPreview()
    }

    /// Images are loaded for the selected row only, never for the whole list.
    private func loadPreview() {
        previewBoxes = []
        boxesTask?.cancel()
        guard pickCount <= 1, let clip = selected, clip.kind == .image else { codeTask?.cancel(); preview = nil; previewOf = nil; return }
        let words = parsed.words.filter { clip.recognised?.localizedCaseInsensitiveContains($0) == true }
        let same = previewOf == clip.id && preview != nil
        guard !same || !words.isEmpty else { return }
        guard let data = try? store.image(of: clip.id) else { preview = nil; previewOf = nil; return }
        if !same {
            preview = Self.downsample(data, maxPixels: Self.previewPixels).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            previewOf = clip.id
            readCode(clip, data)
        }
        guard !words.isEmpty else { return }
        // A pause first, so typing a word reads the image once, after the last key.
        boxesTask = Task { [recognizer] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let boxes = await recognizer.boxes(of: words, in: data)
            guard !Task.isCancelled else { return }
            previewBoxes = boxes
        }
    }
}

extension PanelModel {
    /// The selected copy's QR code (Sven, Q398): Open link or Copy text, as Cmd+K's row runs it.
    func useCode() {
        guard let clip = selected, let code = codes.code(of: clip) else { return }
        try? actions.run(.code(code), on: [clip])
    }

    /// Reads the previewed image's QR code once, after a pause so arrowing past an image reads nothing.
    fileprivate func readCode(_ clip: StoredClip, _ data: Data) {
        codeTask?.cancel()
        guard !codes.knows(clip) else { return }
        let key = ClipCodes.Key(clip)
        codeTask = Task { [recognizer, codes] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            codes.note(key, await recognizer.codes(in: data).first ?? "")
        }
    }
}

extension PanelModel.Prompt {
    /// The crumb the panel shows in its search line's glyph place: what the prompt does, with its glyph.
    var crumb: (symbol: String, text: String) {
        switch self {
        case .tag: ("number", "Tag")
        case .actions: ("command", "Actions")
        case .rename: ("character.cursor.ibeam", "Rename")
        case .edit: ("pencil", "Edit text")
        case .deleteTag: ("trash", "Delete tag")
        }
    }
}

struct ClipboardPanelView: View {
    @Environment(\.style) private var style
    @Bindable var model: PanelModel
    /// Settings › Clipboard's Copy only swaps what Return and Cmd+C do, so the hint swaps too.
    let returnCopies: Bool
    /// The pointer the rows and the Cmd+K and Cmd+T choices follow (PointerTrack); a test passes one on its own pointer.
    @State var pointer = PointerTrack()
    @FocusState private var searchFocused: Bool
    @FocusState private var editorFocused: Bool

    /// The clipboard panel (design round 4, card agent-bo-95422895): Instrument and Toybox draw their own
    /// (InstrumentClipboardPanel, ToyClipboardPanel) on the same model, keys and words.
    var body: some View {
        Group {
            switch style.kind {
            case .instrument: InstrumentClipboardPanel(panel: self, pointer: pointer, searchFocused: $searchFocused, editorFocused: $editorFocused)
            case .toybox: ToyClipboardPanel(panel: self, pointer: pointer, searchFocused: $searchFocused, editorFocused: $editorFocused)
            }
        }
        .tracksPointer(pointer)
        .onAppear { searchFocused = true }
    }

    /// The tag the delete confirm is asking about.
    var leavingTag: ClipTag? {
        if case .deleteTag(let tag) = model.prompt { tag } else { nil }
    }

    /// Footer A (Sven, Q396): one row of the five most used keys, the rest in Cmd+/'s list (`keyGroups`); with rows
    /// picked, what to do with the picks.
    var hints: [KeyHint] {
        if model.showsKeys { return [("Esc", "back")] }
        return switch model.prompt {
        case .tag: [("↵", "tag or untag"), ("↑↓", "choose"), ("Esc", "back to the list")]
        case .actions: [("↵", "run"), ("↑↓", "choose"), ("Esc", "back to the list")]
        case .rename: [("↵", "save"), ("Esc", "back to the list")]
        case .edit: [("⌘↵", "save as plain text"), ("Esc", "back to the list")]
        case .deleteTag: [("↵", "delete the tag"), ("Esc", "keep it")]
        case nil where model.showsSnippets:
            model.snippetRows.isEmpty ? [("←→", "kinds and tags"), ("⌘E", "edit snippets")]
                : [("↵", "paste"), ("←→", "kinds and tags"), ("⌘E", "edit snippets"), ("⌘K", "actions"), ("1–9", "paste that row")]
        case nil where model.pickCount > 0:
            [("↵", returnCopies ? "copy all" : "paste all"), ("⌃↵", "one by one"), ("⌘↵", "pick"), ("Esc", "clear"), ("⌘/", "all keys")]
        case nil:
            [("↵", returnCopies ? "copy only" : "paste"), ("⇧↑↓", "pick a run"), ("⌘↵", "pick"), ("⌘K", "actions"), ("⌘/", "all keys")]
        }
    }

    /// Cmd+/'s list: every key the list takes, in three groups (footer A, Sven, Q396).
    var keyGroups: [(title: String, keys: [KeyHint])] {
        let onTag = if case .tag = model.tab { true } else { false }
        return [("Paste", [returnCopies ? ("↵", "copy only") : ("↵", "paste"), returnCopies ? ("⌘C", "paste") : ("⌘C", "copy only"),
                           ("⇧↵", "plain text"), ("⌃↵", "paste one by one"), ("⌥↵", "paste and delete"), ("1–9", "paste that row")]),
                ("Pick", [("⇧↑↓", "pick a run"), ("⌘↵", "pick or unpick"), ("⌘A", "pick all"), ("Esc", "clear picks")]),
                ("List", [("←→", "kinds and tags"), ("⌘K", "actions"), ("⌘T", "tag"), ("⌘P", "pin"), ("⌘S", "sort"), ("⌘⌫", "delete")]
                    + (onTag ? [("⇧⌘⌫", "delete tag")] : []))]
    }

    /// The foot's words while rows are picked, so picks the cursor has moved away from still show (Sven, 2026-10-21).
    var pickedNote: String? { model.prompt == nil && !model.showsKeys && model.pickCount > 0 ? "\(model.pickCount) picked" : nil }

    var fieldPrompt: String {
        switch model.prompt {
        case .tag: "Tag name…"
        case .actions: "Action…"
        case .rename: "Name, or empty for the text…"
        case .deleteTag(let tag): "Delete #\(tag.name)?"
        case .edit, nil: "Search clipboard…"
        }
    }

    /// One field: the search, or what a tag, action or rename prompt types, so the panel's focus rule stays as it is.
    /// Edit text has its own editor in the preview; the search waits meanwhile.
    var field: Binding<String> {
        Binding(get: { model.prompt == nil || model.prompt == .edit ? model.query : model.promptText },
                set: { switch model.prompt {
                       case nil: model.query = $0
                       case .edit: break
                       default: model.type($0)
                       } })
    }

    /// The app it was copied in, by name.
    func source(_ clip: StoredClip) -> String? { clip.sourceApp.flatMap(AppsModule.appName) }

    /// Today's time, else the day; a copied secret's says when it goes instead (P65).
    func time(_ clip: StoredClip) -> String {
        if let ends = clip.expiresAt {
            return "gone at \(ends.formatted(date: Calendar.current.isDateInToday(ends) ? .omitted : .abbreviated, time: .shortened))"
        }
        return Calendar.current.isDateInToday(clip.copiedAt) ? clip.copiedAt.formatted(date: .omitted, time: .shortened)
            : clip.copiedAt.formatted(date: .abbreviated, time: .omitted)
    }
}

extension Snippet {
    /// The preview's facts, in every style.
    var keywordFact: String { keyword.isEmpty ? "None, Hyper+Space only" : keyword }
    var pastesFact: String { needsArgument ? "After asking for {argument}" : "Into the app you were in" }
}

extension ClipKind {
    /// The kind's icon, on the panel's rows and its empty tab, and on Settings › Clipboard › Recent.
    var symbol: String {
        switch self {
        case .text, .richText: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .colour: "drop"
        case .email: "envelope"
        }
    }
}

/// The panel's tabs (card agent-bo-95422970): the eight kinds and Snippets, a hairline, then a tab per tag behind its colour dot.
/// Tabs that do not fit scroll: a fade marks each side with tabs past it, and the pick is kept whole and clear
/// of the fade as the keys or a click move it. A click picks a tab, a half-hidden one included, as the keys do.
struct ClipTabs: View {
    @Environment(\.style) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tabs: [PanelTab]
    let picked: PanelTab
    let onPick: (PanelTab) -> Void
    @Namespace private var pick
    /// Each tab's run along the strip's content, measured as it lays out.
    @State private var spans: [PanelTab: ClosedRange<CGFloat>] = [:]
    @State private var view = Viewport()
    @State private var position = ScrollPosition(x: 0)

    /// How wide the fade over a cut side is, and so how far in from either edge the pick is kept; its outer `clear`
    /// points show nothing but the chevron.
    static let fade: CGFloat = 34
    static let clear: CGFloat = 14

    /// What the strip shows of its content.
    struct Viewport: Equatable {
        var offset: CGFloat = 0, width: CGFloat = 0, content: CGFloat = 0
        var cutLeading: Bool { offset > 0.5 }
        var cutTrailing: Bool { offset + width < content - 0.5 }
    }

    /// The offset that shows `span` whole and clear of the fades, moved as little as it can be from where it is.
    static func offset(showing span: ClosedRange<CGFloat>, in view: Viewport) -> CGFloat {
        guard view.content > view.width else { return 0 }
        var x = view.offset
        if span.lowerBound - fade < x { x = span.lowerBound - fade }
        else if span.upperBound + fade > x + view.width { x = span.upperBound + fade - view.width }
        return min(max(x, 0), view.content - view.width)
    }

    /// What moves the strip: the pick, where it lies, or the strip's size.
    private struct Aim: Equatable {
        var tab: PanelTab, span: ClosedRange<CGFloat>?, width: CGFloat, content: CGFloat
    }

    /// Toybox's strip: the chips in a panel block, the pick an inverted ink pill (ToySegments), a tag behind its candy dot;
    /// Instrument's: InstrumentSegments' sunk track, the pick raised on a hairline ring, the tags in words alone.
    private var toybox: Bool { style.kind == .toybox }

    var body: some View {
        let firstTag = tabs.first { if case .tag = $0 { true } else { false } }
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.self) { tab in
                    if tab == firstTag {
                        style.color(toybox ? \.outline : \.line2).frame(width: toybox ? 2 : 1, height: toybox ? 18 : 14)
                            .padding(.horizontal, 6).accessibilityHidden(true)
                    }
                    // Plain, as Segments' tabs are: the pick moving is the press's answer.
                    Button { onPick(tab) } label: { label(tab, on: tab == picked) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tab.accessibilityName)
                        .accessibilityAddTraits(tab == picked ? .isSelected : [])
                        .onGeometryChange(for: ClosedRange<CGFloat>.self) { geometry in
                            let frame = geometry.frame(in: .named(Self.space))
                            return frame.minX...frame.maxX
                        } action: { spans[tab] = $0 }
                }
            }
            .padding(toybox ? 3 : 2)
            .padding(toybox ? EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2) : EdgeInsets())
            .background {
                if toybox {
                    Toy.block(style, fill: style.color(\.panel), radius: style.radii.control, edge: style.depth.control.edge)
                } else {
                    Color.clear.instrumentWell()
                }
            }
            .animation(reduceMotion ? nil : Kit.change, value: picked)
            .padding(.horizontal, 16)
            .coordinateSpace(.named(Self.space))
        }
        .scrollIndicators(.never)
        .scrollPosition($position)
        .onScrollGeometryChange(for: Viewport.self) {
            Viewport(offset: $0.contentOffset.x, width: $0.containerSize.width, content: $0.contentSize.width)
        } action: { view = $1 }
        .mask {
            HStack(spacing: 0) {
                edge(cut: view.cutLeading, from: .leading)
                Color.black
                edge(cut: view.cutTrailing, from: .trailing)
            }
        }
        // A chevron in each cut side's clear end, so tabs past the edge show even when no word is half in view; a click
        // there reaches the tab under it.
        .overlay(alignment: .leading) { if view.cutLeading { chevron("chevron.left") } }
        .overlay(alignment: .trailing) { if view.cutTrailing { chevron("chevron.right") } }
        .onChange(of: Aim(tab: picked, span: spans[picked], width: view.width, content: view.content), initial: true) { old, new in
            guard let span = new.span else { return }
            let x = Self.offset(showing: span, in: view)
            guard abs(x - view.offset) > 0.5 else { return }
            // A step slides the strip with the pick; the first measure, or a resize, puts it there at once.
            if old.tab != new.tab, old.span != nil, !reduceMotion {
                withAnimation(Kit.change) { position.scrollTo(x: x) }
            } else {
                position.scrollTo(x: x)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kind or tag; Left and Right for the next")
    }

    private nonisolated static let space = "clip-tabs"

    /// A side's part of the mask: whole when nothing is past it, else clear for the chevron, then fading in.
    private func edge(cut: Bool, from side: UnitPoint) -> some View {
        let outside = Color.black.opacity(cut ? 0 : 1)
        return LinearGradient(stops: [.init(color: outside, location: 0), .init(color: outside, location: Self.clear / Self.fade),
                                      .init(color: .black, location: 1)],
                              startPoint: side, endPoint: side == .leading ? .trailing : .leading)
            .frame(width: Self.fade)
    }

    private func chevron(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(style.color(\.text3))
            .frame(width: Self.clear).allowsHitTesting(false).accessibilityHidden(true)
    }

    /// One tab: a tag's dot and #name, or a kind's name, at the picked weight underneath so it keeps its width as the
    /// pick moves past; clickable across its padding.
    @ViewBuilder private func label(_ tab: PanelTab, on: Bool) -> some View {
        if toybox { toyboxLabel(tab, on: on) } else { instrumentLabel(tab, on: on) }
    }

    /// Toybox's tab: Nunito 800 in the second ink, the pick's on the inverted ink pill; a tag behind its dot.
    private func toyboxLabel(_ tab: PanelTab, on: Bool) -> some View {
        HStack(spacing: 5) {
            if case .tag(let tag) = tab { ToyDot(color: Theme.tag(tag.colour), size: 8) }
            Text(tab.label).foregroundStyle(style.color(on ? \.onInverse : \.text2))
        }
        .font(Toy.nunito(800, 13.5)).lineLimit(1).fixedSize()
        .padding(.horizontal, 13).frame(height: 30)
        .background {
            if on { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(style.color(\.inverse)).matchedGeometryEffect(id: "pick", in: pick) }
        }
        .contentShape(.rect)
    }

    /// Instrument's tab: the words in the caption face, the pick's strong in the text colour on a raised cap; at the
    /// pick's weight underneath, so it keeps its width as the pick moves past.
    private func instrumentLabel(_ tab: PanelTab, on: Bool) -> some View {
        return ZStack {
            Text(tab.label).styleText(\.strong).hidden()
            Text(tab.label).styleText(on ? \.strong : \.caption).foregroundStyle(style.color(on ? \.text : \.text3))
        }
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 9).frame(height: 22)
        .background {
            if on {
                Color.clear.instrumentRaised(true, fill: \.panel, radius: style.radii.control - 2)
                    .matchedGeometryEffect(id: "pick", in: pick)
            }
        }
        .contentShape(.rect)
    }
}

extension PanelTab {
    /// VoiceOver says "tag" rather than reading out the #.
    var accessibilityName: String {
        switch self {
        case .kind(let kind): kind.label
        case .tag(let tag): "tag \(tag.name)"
        }
    }
}

/// A tab with no rows says so plainly in the list (card agent-bo-95422970): nothing of that kind, nothing pinned or
/// tagged, or nothing matching the search there; Pinned and a tag say which key fills them.
struct EmptyTab: View {
    @Environment(\.style) private var style
    let tab: PanelTab
    let query: String
    /// The Snippets tab with none saved: its one button, to the editor.
    var newSnippet: (() -> Void)?

    var body: some View {
        switch style.kind {
        case .instrument: instrument
        case .toybox: toybox
        }
    }

    /// Toybox's: the kind's glyph on its candy tile (a tag's # on the sun's soft fill), the line in Fredoka, the hint under.
    private var toybox: some View {
        VStack(spacing: 6) {
            let tag = if case .tag = tab { true } else { false }
            ToyTile(symbol: symbol, color: tag ? style.color(\.accentSoft) : Toy.moduleSoft(kindModule, style), size: 40, letter: tag ? "#" : nil)
                .padding(.bottom, 6).accessibilityHidden(true)
            Text(line).font(Toy.fredoka(17)).foregroundStyle(style.color(\.text))
            if let hint { Text(hint).font(Toy.nunito(700, 13)).foregroundStyle(style.color(\.text3)) }
        }
        .multilineTextAlignment(.center).lineLimit(3)
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 24)
    }

    /// A kind tab's candy colour, its copies' (Toy.module(of:)); All and Pinned the Pilot module's.
    private var kindModule: Int {
        if case .kind(let kind) = tab, let clip = ClipKind(rawValue: kind.rawValue) { Toy.module(of: clip) } else { 5 }
    }

    private var button: (() -> Void)? { typed.isEmpty ? newSnippet : nil }

    /// Instrument's: the kind's glyph in the third text colour (a tag's # mark, as its tab shows no colour), the line,
    /// the hint under it.
    private var instrument: some View {
        VStack(spacing: 6) {
            Group {
                if case .tag = tab { Text("#").styleText(\.search) } else { Image(systemName: symbol).font(style.font(\.search)) }
            }
            .foregroundStyle(style.color(\.text3)).padding(.bottom, 4).accessibilityHidden(true)
            Text(line).styleText(\.strong).foregroundStyle(style.color(\.text))
            if let hint { Text(hint).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
            if let button { Button("New snippet", action: button).buttonStyle(InstrumentButtonStyle(kind: .primary)).padding(.top, 10) }
        }
        .multilineTextAlignment(.center).lineLimit(3)
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 24)
    }

    private var typed: String { query.trimmingCharacters(in: .whitespaces) }

    private var line: String {
        let match = typed.isEmpty ? nil : "“\(typed)”"
        switch tab {
        case .kind(.all): return match.map { "Nothing matches \($0)." } ?? "Nothing copied yet."
        case .kind(.pinned): return match.map { "Nothing pinned matches \($0)." } ?? "Nothing pinned yet."
        case .kind(.snippet): return match.map { "No snippets match \($0)." } ?? "Type ;sig anywhere to drop in saved text."
        case .tag(let tag): return match.map { "Nothing tagged #\(tag.name) matches \($0)." } ?? "Nothing tagged #\(tag.name)."
        case .kind(let kind):
            let (plural, many) = switch kind {
            case .text: ("text", false)
            case .image: ("images", true)
            case .file: ("files", true)
            case .link: ("links", true)
            case .colour: ("colours", true)
            default: ("email addresses", true)
            }
            return match.map { "No \(plural) \(many ? "match" : "matches") \($0)." } ?? "No \(plural) copied yet."
        }
    }

    private var hint: String? {
        guard typed.isEmpty else { return nil }
        switch tab {
        case .kind(.pinned): return "Pin a copy with ⌘P and it shows here."
        case .tag: return "Tag a copy with ⌘T and it shows here."
        default: return nil
        }
    }

    /// The kind's own icon, as its rows show it.
    private var symbol: String {
        switch tab {
        case .kind(.pinned): "pin"
        case .kind(.snippet): MenuBranch.snippets.look.symbol
        case .kind(let kind): ClipKind(rawValue: kind.rawValue)?.symbol ?? "doc.on.clipboard"
        case .tag: "doc.on.clipboard"
        }
    }
}

/// An image's text still being read (Sven, build 31): under its picture in the preview, and under the list while a search
/// cannot find it by its words yet. Each style's quiet caption, with the text-reading glyph.
struct ReadingText: View {
    @Environment(\.style) private var style
    @Environment(\.ink) private var ink
    let line: String
    static let preview = "Reading the text in this image…"

    /// The list's line, while the model has one.
    @ViewBuilder static func under(_ model: PanelModel) -> some View {
        if let line = model.readingLine { ReadingText(line: line).padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading) }
    }

    var body: some View {
        let label = Label(line, systemImage: "text.viewfinder").lineLimit(1).foregroundStyle(ink.muted)
        switch style.kind {
        case .instrument: label.styleText(\.caption)
        case .toybox: label.font(Toy.nunito(700, 13))
        }
    }
}

/// The clipboard panel's way out of the store: NSWorkspace, Pilot's copy with its alert, and a save panel that begins
/// rather than runs modal, so the tap keeps going while it is open (card agent-bo-95422784).
@MainActor
struct PilotOpener: ClipOpening {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func openWith(_ urls: [URL]) { FileActions.openWith(urls) }
    func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    func copy(_ text: String, tip: String) { SystemModule.copy(text, tip: tip) }

    func saveImage(_ data: Data, named name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.png]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) } catch { HUD.tip("\(url.lastPathComponent) not saved: \(error.localizedDescription)") }
        }
    }
}

extension StoredClip {
    /// A colour clip's colour, as 0xRRGGBB; nil for any other clip.
    var swatch: UInt32? {
        kind == .colour ? ClipboardCapture.colourValue(text) : nil
    }

    /// A colour's spellings under its swatch, as the menu's colour card lists them (menu Rail and Classic T10): hex, rgb,
    /// hsl, hsb and SwiftUI (ColourAnswer.formats).
    static func colourValues(_ hex: UInt32) -> [String] { ColourAnswer.formats(hex) }
}
