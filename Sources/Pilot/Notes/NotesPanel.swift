import AppKit
import Observation
import OSLog
import PilotCore
import SwiftUI

let noteslog = Logger(subsystem: "dev.banozz.pilot", category: "notes")

/// The notes panel's state (card agent-bo-95423042): the notes on disk, the one open in the editor, the list while it has
/// the keyboard, Cmd+K's actions and the Trash confirm. Typing saves half a second after it stops; `flush` saves at once,
/// as hiding does. Scratch stays empty: the first words typed in it become a note of their own (Sven 2026-10-15).
@Observable @MainActor
final class NotesModel {
    @ObservationIgnored let store: NoteStore
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    /// True while a note's text is put in the editor, which is no edit.
    @ObservationIgnored private var loading = false
    /// The open note's editors, the panel's and the Notes page's, for Cmd+K's formats and Rename, which act on the one in
    /// the key window (each format bar holds its own editor).
    @ObservationIgnored let editor = NotesEditorHandle()
    /// Where Copy as Markdown puts a note, and how a done action says so; tests swap both.
    @ObservationIgnored var pasteboard = NSPasteboard.general
    @ObservationIgnored var tip: @MainActor (String) -> Void = { HUD.tip($0) }

    private(set) var notes: [Note] = []
    /// Kept in the defaults, so the Notes page opens on it after Pilot quits and starts again (the panel opens on Scratch).
    private(set) var current = NoteStore.scratch {
        didSet { defaults.set(current, forKey: Self.lastKey) }
    }
    private static let lastKey = "notes.last"
    /// The open note's text as the editor has it.
    var text = "" {
        didSet { if text != oldValue, !loading { edited() } }
    }
    /// Escape in the note hands the keyboard to the list (Q115, Sven 2026-10-15): ↑↓ move `selection`, which the note
    /// pane previews, Return opens it and gives the editor the keyboard back, Escape hides the panel.
    private(set) var listFocused = false
    /// The list's highlighted note while it has the keyboard.
    private(set) var selection: String?
    /// The list's filter, typed in its field while the list has the keyboard; a new word highlights the best match.
    var query = "" {
        didSet { if query != oldValue { selection = rows.first?.id } }
    }
    /// The field's words: empty under the Trash question, and set only by typing, so a field losing focus never changes
    /// what the list shows.
    var queryField: String {
        get { confirmingTrash ? "" : query }
        set { if listFocused, newValue != query { query = newValue } }
    }
    /// Cmd+Backspace (from the list) or Cmd+K's Move to Trash asked; Return moves the note to the Trash, Escape keeps it.
    var confirmingTrash = false
    /// Cmd+K's actions on the open note (the highlighted one while the list has the keyboard); nil while closed.
    private(set) var actions: NoteActions?
    /// A failed read or write, shown in the panel.
    private(set) var problem: String?

    @ObservationIgnored private let defaults: UserDefaults

    init(store: NoteStore, defaults: UserDefaults = .pilot()) {
        self.store = store
        self.defaults = defaults
        current = defaults.string(forKey: Self.lastKey) ?? NoteStore.scratch
    }

    var note: Note? { notes.first { $0.id == current } }
    var groups: [Notes.Group] { Notes.groups(notes, now: .now) }
    /// The list's rows in order: the groups' notes (Scratch, Pinned, Today, …), or with a filter typed the matches:
    /// titles best first, then notes with the words in their text, whose row shows the line that matched.
    var rows: [Note] {
        query.isEmpty ? groups.flatMap(\.notes) : Notes.search(notes, query: query)
    }
    /// The highlighted note while the list has the keyboard, which the note pane previews read-only.
    var selectedNote: Note? {
        guard listFocused, let selection else { return nil }
        return notes.first { $0.id == selection }
    }

    /// The list shows and has the keyboard: not under the Trash question, which outranks it.
    var listing: Bool { listFocused && !confirmingTrash }
    /// The highlighted note the list shows behind it, when it is not the open one.
    var previewNote: Note? { listing ? selectedNote.flatMap { $0.id == current ? nil : $0 } : nil }

    /// The open note is a note with no words in it: the panel offers to delete it, and Cmd+Backspace deletes it with no
    /// question (Sven 2026-10-15). Never Scratch, which is always empty.
    var isEmptyNote: Bool {
        note?.isScratch == false && text.allSatisfy(\.isWhitespace)
    }

    /// Reads the folder again, staying on the open note, or Scratch when it is gone. Words left in Scratch (the old
    /// Scratch, a line the menu or the pilot command added) move to a note of their own first.
    func reload() {
        attempt("read") {
            if let moved = try store.moveScratch() { noteslog.notice("notes: Scratch's words moved to \(moved.id, privacy: .public)") }
            notes = try store.load()
            open(notes.contains { $0.id == current } ? current : NoteStore.scratch)
        }
    }

    func open(_ id: String) {
        flush()
        guard let note = notes.first(where: { $0.id == id }) else { return }
        current = id
        // Loading a note is not an edit.
        loading = true
        text = note.text
        loading = false
        pendingSave?.cancel()
        dirty = false
        leaveList()
        confirmingTrash = false
        actions = nil
    }

    /// Escape in the note: the list takes the keyboard on the open note, unfiltered.
    func focusList() {
        flush()
        confirmingTrash = false
        listFocused = true
        query = ""
        selection = current
    }

    /// The editor has the keyboard again; the list forgets its filter.
    func leaveList() {
        listFocused = false
        query = ""
        selection = nil
    }

    /// ↑ or ↓ while the list has the keyboard: the row `by` on from the highlighted one, stopping at either end.
    func stepList(_ by: Int) {
        let list = rows
        guard listFocused, !list.isEmpty else { return }
        let at = list.firstIndex { $0.id == selection }.map { min(max($0 + by, 0), list.count - 1) } ?? 0
        selection = list[at].id
    }

    /// Return in the list: the highlighted note opens and the editor takes the keyboard.
    func openSelection() {
        if let id = selectedNote?.id { open(id) } else { leaveList() }
    }

    /// What a panel key asks (NotesKey), short of hiding, which is the panel's.
    func perform(_ key: NotesKey) {
        switch key {
        case .hide: break
        case .list: focusList()
        case .keep: confirmingTrash = false
        case .confirmTrash: confirmTrash()
        case .open: openSelection()
        case .step(let by): stepList(by)
        case .new: new()
        case .pin: togglePin()
        case .askTrash:
            // From the list it asks about the highlighted note, which opens so the question shows it.
            if listFocused, let id = selectedNote?.id, id != current { open(id) }
            askTrash()
        case .actions: actions == nil ? openActions() : (actions = nil)
        case .closeActions: actions = nil
        case .stepActions(let by): stepActions(by)
        case .runAction: runAction()
        case .filterActions(let typed): filterActions(typed)
        case .held: break
        }
    }

    // MARK: Cmd+K

    /// Cmd+K: the actions on the open note, or the highlighted one while the list has the keyboard; the formats only on
    /// the note being written in.
    func openActions() {
        guard let target = selectedNote ?? note else { return }
        confirmingTrash = false
        actions = NoteActions(note: target.id, title: target.title, choices: NoteAction.choices(for: target, writing: selectedNote == nil))
    }

    func stepActions(_ by: Int) {
        guard let menu = actions, !menu.visible.isEmpty else { return }
        actions?.index = min(max(menu.index + by, 0), menu.visible.count - 1)
    }

    /// A key typed while Cmd+K is open: its search, a character added or (nil, Backspace) the last one taken off; the
    /// first match is highlighted.
    func filterActions(_ typed: String?) {
        guard var menu = actions else { return }
        if let typed { menu.query += typed } else if !menu.query.isEmpty { menu.query.removeLast() }
        menu.index = 0
        actions = menu
    }

    /// Runs the highlighted action (or `at`, a clicked row) and closes the list.
    func runAction(at: Int? = nil) {
        guard let menu = actions else { return }
        let index = at ?? menu.index
        guard menu.visible.indices.contains(index) else { return }
        actions = nil
        run(menu.visible[index], on: menu.note)
    }

    func run(_ action: NoteAction, on id: String) {
        guard let target = notes.first(where: { $0.id == id }) else { return }
        let words = id == current ? text : target.text
        switch action {
        case .pin, .unpin: pin(id, action == .pin)
        case .rename:
            if id != current { open(id) } else { leaveList() }
            editor.selectTitle(of: text)
        case .duplicate:
            attempt("duplicate") { open(try create(text: NoteAction.copied(words)).id) }
        case .copy:
            pasteboard.clearContents()
            pasteboard.setString(words, forType: .string)
            tip("Copied “\(target.title)” as Markdown")
        case .reveal:
            flush()
            reveal(id)
        case .new: new()
        case .trash:
            if id != current { open(id) }
            askTrash()
        case .format(let format): editor.apply(format)
        }
    }

    func new() {
        attempt("create") { open(try create().id) }
    }

    /// A new note holding `text`, read into the list but not opened: New note's work, which the pilot command asks for
    /// too (CLI W12).
    @discardableResult
    func create(text: String = "") throws -> Note {
        flush()
        let note = try store.create(text: text)
        notes = try store.load()
        return note
    }

    /// Cmd+P (Q116, Sven 2026-10-15): pins or unpins the open note, or the highlighted one while the list has the keyboard.
    func togglePin() {
        guard let note = selectedNote ?? note else { return }
        pin(note.id, !note.pinned)
    }

    /// Pins or unpins any note, the open one or not (the Notes page's rows); Scratch is never pinned.
    func pin(_ id: String, _ on: Bool) { attempt("pin") { try setPin(id, on) } }

    /// Pin's work, throwing for the pilot command (CLI W12).
    func setPin(_ id: String, _ on: Bool) throws {
        guard id != NoteStore.scratch else { return }
        flush()
        try store.setPinned(id, on)
        notes = try store.load()
    }

    /// The menu's "note …" and the pilot command's append: `line` on the end of Scratch, which then moves to a note of
    /// its own (what is typed saved first). Answers that note's id.
    @discardableResult
    func appendToScratch(_ line: String) throws -> String {
        flush()
        try store.appendToScratch(line)
        let moved = try store.moveScratch()
        notes = try store.load()
        if current == NoteStore.scratch { open(NoteStore.scratch) }
        return moved?.id ?? NoteStore.scratch
    }

    /// Cmd+Backspace from the list: the Trash question, or for a note with no words in it, straight to the Trash (Sven
    /// 2026-10-15), which Cmd+Backspace in its editor does too.
    func askTrash() {
        guard note?.isScratch == false else { return }
        if isEmptyNote { trash(current) } else { confirmingTrash = true }
    }

    /// Shows a note's file in Finder.
    func reveal(_ id: String) { NSWorkspace.shared.activateFileViewerSelecting([store.folder.appending(path: id)]) }

    func confirmTrash() {
        guard confirmingTrash, let note else { return }
        trash(note.id)
    }

    /// Moves a note to the Trash (never Scratch); the open one gives way to Scratch.
    func trash(_ id: String) { attempt("trash") { try moveToTrash(id) } }

    /// Trash's work, throwing for the pilot command (CLI W12).
    func moveToTrash(_ id: String) throws {
        guard id != NoteStore.scratch else { return }
        defer { confirmingTrash = false }
        if id == current {
            pendingSave?.cancel()
            dirty = false
        } else {
            flush()
        }
        try store.trash(id)
        notes = try store.load()
        open(notes.contains { $0.id == current } ? current : NoteStore.scratch)
        noteslog.notice("notes: moved \(id, privacy: .public) to the Trash")
    }

    /// Writes the open note now if it changed; a new first line renames its file. Only that note changes in the list:
    /// the folder is read again on show, not on every pause in typing.
    func flush() {
        pendingSave?.cancel()
        guard dirty else { return }
        dirty = false
        attempt("save") {
            let id = try store.save(current, text: text)
            if let i = notes.firstIndex(where: { $0.id == current }) {
                notes[i] = Note(id: id, text: text, edited: .now, pinned: notes[i].pinned)
            }
            current = id
        }
    }

    /// The pilot command's write (CLI W12): what is typed is saved first, then `text` replaces the note's on disk, the
    /// open one followed when a new first line renames it. Answers the id it is saved under.
    func write(_ id: String, text: String) throws -> String {
        flush()
        let saved = try store.save(id, text: text)
        if id == current { current = saved }
        reload()
        return saved
    }

    private func edited() {
        if current == NoteStore.scratch, !Notes.isBlankScratch(text) { return promoteScratch() }
        dirty = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// The first words typed in Scratch: they become a new note, written at once, which the editor stays on with the
    /// caret where it was; Scratch is left empty for next time. Anything another app wrote into Scratch.md while it sat
    /// open moves to a note of its own first, never written over; the editor leaves Scratch the moment its note exists,
    /// so a failed write after that never makes a second note.
    private func promoteScratch() {
        attempt("save") {
            pendingSave?.cancel()
            if let moved = try store.moveScratch() { noteslog.notice("notes: words written into Scratch elsewhere moved to \(moved.id, privacy: .public)") }
            let note = try store.create(text: text)
            current = note.id
            dirty = false
            notes = try store.load()
            noteslog.notice("notes: Scratch typed into, now \(note.id, privacy: .public)")
        }
    }

    private func attempt(_ what: String, _ body: () throws -> Void) {
        do { try body(); problem = nil } catch {
            problem = "Could not \(what) the note: \(error.localizedDescription)"
            noteslog.error("notes \(what): \(String(describing: error), privacy: .public)")
        }
    }
}

/// Hyper+Shift+W: the notes panel, floating over every workspace and full-screen app; it keeps its size and place.
@MainActor
final class NotesPanel {
    static let shared = NotesPanel()
    static let toggleID = "notes.toggle"
    static let defaultSize = CGSize(width: 760, height: 480)
    static let minSize = CGSize(width: 520, height: 320)
    /// Over full-screen apps and every workspace; the passing HUDs sit above it (HUD.level).
    static let level = NSWindow.Level.popUpMenu

    private var model: NotesModel?
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var clickMonitors: [Any] = []
    /// Where a press outside the panel went down, in screen points; nil while none is held.
    private var outsideDown: CGPoint?

    /// The folder the Notes page picked, else Pilot's own.
    var folder: URL { NotesFolder.folder(Engine.shared?.settings.notesFolder) }

    static func register(into registry: inout ActionRegistry) {
        do {
            try registry.register(Action(id: toggleID, label: "Quick notes", module: .apps, defaultKey: Key("n", .shift), tier: .v1) {
                NotesPanel.shared.toggle()
            })
        } catch { noteslog.error("\(toggleID, privacy: .public): \(String(describing: error), privacy: .public)") }
    }

    var isShown: Bool { panel?.isVisible == true }

    /// After the tap callback returns: reading the folder is too slow for it.
    func toggle() {
        DispatchQueue.main.async { self.isShown ? self.hide() : self.show() }
    }

    /// Shows the panel on `note`, else on Scratch, empty and ready to type in (Sven 2026-10-15: the key opens Scratch).
    func show(note: String? = nil) {
        let model = currentModel()
        model.reload()
        model.open(note ?? NoteStore.scratch)
        if panel == nil { panel = makePanel(model) }
        guard let panel else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        // The list's field keeps the keyboard only while the list has it; otherwise the editor has it.
        // Cmd+K's search is the model's own (its keys typed through NotesKey), so the field never takes the keyboard from it.
        keyMonitor = HUD.showSearchPanel(panel, handle: { [weak self] in self?.handle($0, $1, $2) == true },
                                         keepsSearch: { [weak model] in model?.listFocused == true && model?.actions == nil }, onlyPanel: true,
                                         log: { noteslog.debug("notes panel: \($0, privacy: .public)") })
        watchClicks()
        noteslog.notice("notes panel shown on \(model.current, privacy: .public), \(model.notes.count) notes")
    }

    /// Shows the panel on a new note, as its own New note makes one: the desktop's Hyper + right-click › New note.
    func showNew() {
        show()
        model?.new()
    }

    /// Saves, then hides; the model stays, so the next show lands on the same note. The panel itself goes, as the menu's
    /// and the clipboard's do, so the next show is built in the Look of that moment (the style, the theme, the glass).
    func hide() {
        model?.flush()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
        model?.leaveList()
        dropPanel()
        noteslog.notice("notes panel hidden")
    }

    /// Keeps the panel's size and place under its name for the next one, then lets it go.
    private func dropPanel() {
        guard let panel else { return }
        panel.saveFrame(usingName: Self.frameName)
        panel.setFrameAutosaveName("")
        panel.orderOut(nil)
        self.panel = nil
    }

    /// The menu's "note …": the line goes on the end of Scratch without showing the panel.
    func append(_ line: String) {
        do {
            try currentModel().appendToScratch(line)
            HUD.tip("Saved as a note")
            noteslog.notice("notes: saved \(line.count) characters as a note")
        } catch {
            HUD.tip("Could not save the note.")
            noteslog.error("notes append: \(String(describing: error), privacy: .public)")
        }
    }

    /// The menu's Move to Trash… on a note (notes round 2): the menu's confirm, then the shared model moves it, so
    /// the panel and the Notes page drop it too. Scratch never goes.
    func askTrash(_ id: String, confirm: InstallModule.Confirm = InstallModule.confirm) {
        guard id != NoteStore.scratch else { return HUD.tip("Scratch stays: clear it instead.") }
        let question = Self.trashQuestion(notes().first { $0.id == id }?.title ?? id)
        confirm(question.title, question.detail) { [weak self] in
            guard let self else { return }
            let model = self.currentModel()
            model.reload()
            model.trash(id)
            HUD.tip("Moved to the Trash")
        }
    }

    /// The Trash confirm's words, which the pilot command's Allow question shows too.
    static func trashQuestion(_ title: String) -> (title: String, detail: String) {
        ("Move “\(title)” to the Trash", "Finder can put it back")
    }

    /// The note a file path names: a .md file straight in the notes folder.
    func noteID(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "md", NotesFolder.same(url.deletingLastPathComponent(), folder) else { return nil }
        return url.lastPathComponent
    }

    /// The menu's Notes branch reads the folder each time it opens.
    func notes() -> [Note] {
        welcomeOnce()
        return (try? NoteStore(folder: folder).load()) ?? []
    }

    /// The first time the notes are read, the welcome note goes in when the folder holds none (Q529); never again, so a
    /// welcome sent to the Trash stays gone and a folder already holding notes never gets one. A failed write tries
    /// again on the next read.
    private func welcomeOnce() {
        guard !defaults.bool(forKey: Self.welcomedKey) else { return }
        do {
            if let url = try NotesWelcome.write(in: folder) { noteslog.notice("notes: wrote \(url.lastPathComponent, privacy: .public)") }
            defaults.set(true, forKey: Self.welcomedKey)
        } catch { noteslog.error("notes welcome: \(String(describing: error), privacy: .public)") }
    }

    private static let welcomedKey = "notes.welcomed"

    /// Points the notes at `new`, first moving every note there when `move` (task N1); the panel and the Notes page
    /// then read the new folder.
    func changeFolder(to new: URL, move: Bool) throws {
        model?.flush()
        let moved = move ? try NotesFolder.move(from: folder, to: new) : NotesFolder.Moved()
        Engine.shared?.settings.notesFolder = NotesFolder.setting(new)
        noteslog.notice("notes: folder is now \(new.path, privacy: .public), \(moved.count) moved, \(moved.renamed.count) renamed")
    }

    /// The model the panel and the Notes page share, so an edit in one shows in the other at once; a folder changed on
    /// the Notes page starts a new one.
    func currentModel() -> NotesModel {
        if let model, model.store.folder == folder { return model }
        model?.flush()
        welcomeOnce()
        let model = NotesModel(store: NoteStore(folder: folder))
        self.model = model
        dropPanel()
        return model
    }

    private func makePanel(_ model: NotesModel) -> NSPanel {
        let panel = HUD.makePanel(NotesPanelView(model: model).frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height), surface: .notes)
        panel.resizesFromFace()
        panel.isMovableByWindowBackground = true
        panel.level = Self.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "Quick notes"
        // A restyled panel's window holds its shadow's margins round the face (PopSurface): the size and place kept are
        // the face's, whichever style saved them, so a switch of style never shrinks or moves the note.
        let margins = panel.margins
        let saved = panel.setFrameUsingName(Self.frameName) ? panel.frame : nil
        let screen = Screens.focusedScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(Self.frame(saved: saved, savedMargins: Self.savedMargins(defaults), margins: margins, screen: screen), display: false)
        panel.minSize = PopSurface.window(Self.minSize, margins)
        Self.saveMargins(margins, defaults)
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    private static let frameName = "PilotQuickNotes"
    /// The margins round the face of the panel that saved the frame under frameName last; none before styles.
    private static let marginsKey = "notes.frameMargins"
    private let defaults = UserDefaults.pilot()

    /// The panel's frame: the face of a `saved` frame (saved by a panel with `savedMargins` round its face), else the
    /// default size centred on `screen`, at least the smallest size, its top edge kept, with `margins` round it.
    static func frame(saved: CGRect?, savedMargins: NSEdgeInsets, margins: NSEdgeInsets, screen: CGRect) -> CGRect {
        let face = saved.map { PopSurface.face($0, savedMargins) } ?? CGRect(x: screen.midX - defaultSize.width / 2, y: screen.midY - defaultSize.height / 2, width: defaultSize.width, height: defaultSize.height)
        let size = CGSize(width: max(face.width, minSize.width), height: max(face.height, minSize.height))
        let window = PopSurface.window(size, margins)
        return CGRect(x: face.minX - margins.left, y: face.maxY + margins.top - window.height, width: window.width, height: window.height)
    }

    static func savedMargins(_ defaults: UserDefaults) -> NSEdgeInsets {
        guard let m = defaults.array(forKey: marginsKey) as? [Double], m.count == 4 else { return NSEdgeInsetsZero }
        return NSEdgeInsets(top: m[0], left: m[1], bottom: m[2], right: m[3])
    }

    static func saveMargins(_ m: NSEdgeInsets, _ defaults: UserDefaults) {
        defaults.set([m.top, m.left, m.bottom, m.right].map(Double.init), forKey: marginsKey)
    }

    /// The panel's own keys (NotesKey); anything else goes on to the editor or the list's field.
    private func handle(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags, _ key: String?) -> Bool {
        guard let model, let command = NotesKey.pressed(code, modifiers, key, model: model, responder: panel?.firstResponder) else { return false }
        if command == .hide { hide() } else { model.perform(command) }
        return true
    }

    /// A click outside the panel hides it (Q114 item 5, Sven 2026-10-15) and still lands where it was made: the monitors
    /// only watch, never take or post an event. A press that moves away before it lets go is a drag (a picture dragged
    /// in from Finder), so the panel stays for the drop.
    private func watchClicks() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        // Another app's windows, the desktop and the menu bar: every event a global monitor sees is outside Pilot.
        let global = NSEvent.addGlobalMonitorForEvents(matching: kinds) { [weak self] event in
            let (type, at) = (event.type, NSEvent.mouseLocation)
            MainActor.assumeIsolated { self?.click(type, at: at, outside: true) }
        }
        // Pilot's own other windows (the app window, the bar): outside too; the panel and its child windows are not, nor
        // the selection pill and its Ask AI bubble, which work on the note's selected text.
        let local = NSEvent.addLocalMonitorForEvents(matching: kinds) { [weak self] event in
            let (type, at, window) = (event.type, NSEvent.mouseLocation, event.window)
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.click(type, at: at, outside: window != nil && window !== panel && window?.parent !== panel
                    && window?.identifier != SelectionTools.panelID)
            }
            return event
        }
        clickMonitors = [global, local].compactMap { $0 }
    }

    private func click(_ type: NSEvent.EventType, at point: CGPoint, outside: Bool) {
        switch type {
        case .leftMouseDown, .rightMouseDown: outsideDown = outside ? point : nil
        default:
            defer { outsideDown = nil }
            guard outside, Self.isClick(from: outsideDown, to: point) else { return }
            noteslog.notice("notes panel: a click outside hides it")
            // After the event is handed on, so the click lands first.
            DispatchQueue.main.async { if self.isShown { self.hide() } }
        }
    }

    /// A press and its release within 4 points of each other: a click, not a drag.
    static func isClick(from down: CGPoint?, to up: CGPoint) -> Bool {
        guard let down else { return false }
        return hypot(up.x - down.x, up.y - down.y) <= 4
    }
}

/// What a key does in the notes panel, by the state it is in (Q115, Q116, Sven 2026-10-15). Escape steps back one place:
/// the Trash question keeps the note, the note hands the keyboard to the list, the list hides the panel. Return answers
/// the question or opens the highlighted note; ↑↓ move through the list; Cmd+P pins, Cmd+N makes a note, Cmd+Backspace
/// asks before the Trash from the list, or deletes a note with no words in it, and is the editor's delete to the line's
/// start otherwise (P56, Sven build 68); Cmd+K opens the actions, which then hold every key: what is typed searches
/// them, ↑↓ choose, Return runs, Escape or Cmd+K close. Nil: the key goes on to the editor or the list's field. `key` is
/// the key's characters, modifiers aside (NSEvent's charactersIgnoringModifiers).
enum NotesKey: Equatable {
    case hide, list, keep, confirmTrash, open, step(Int), new, pin, askTrash, actions, closeActions, stepActions(Int), runAction
    /// A character for Cmd+K's search, or nil: Backspace takes one off.
    case filterActions(String?)
    case held

    init?(code: UInt16, flags modifiers: NSEvent.ModifierFlags, key raw: String?, list: Bool, confirming: Bool, actions: Bool = false,
          empty: Bool = false) {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        let key = raw?.lowercased()
        if actions {
            switch (code, flags, key) {
            case (53, _, _), (_, [.command], "k"): self = .closeActions
            case (36, [], _), (76, [], _): self = .runAction
            case (126, [], _): self = .stepActions(-1)
            case (125, [], _): self = .stepActions(1)
            case (51, [], _): self = .filterActions(nil)
            default:
                // A printed character, shifted or not; anything with Command, Control or Option is held.
                if flags.subtracting(.shift).isEmpty, let raw, raw.count == 1, raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
                    self = .filterActions(raw)
                } else { self = .held }
            }
            return
        }
        switch (code, flags) {
        case (53, _): self = confirming ? .keep : list ? .hide : .list
        case (36, []), (76, []):
            if confirming { self = .confirmTrash } else if list { self = .open } else { return nil }
        case (126, []) where list && !confirming: self = .step(-1)
        case (125, []) where list && !confirming: self = .step(1)
        case (51, [.command]) where list || empty: self = .askTrash
        default:
            switch (key, flags) {
            case ("n", [.command]): self = .new
            case ("p", [.command]): self = .pin
            case ("k", [.command]): self = .actions
            default: return nil
            }
        }
    }
}

extension NotesKey {
    /// The key a press is, in the state `model` is in with `responder` holding the keyboard: the panel's and the Notes
    /// page's monitors ask this one way. The note's editor holding the keyboard means the list has let go, whatever the
    /// model last heard (focus that never reached the list's field, a click back in an editor that never lost it): the
    /// list leaves first, so Return, ↑↓ and ⌘⌫ are the editor's and never answer for the list.
    @MainActor static func pressed(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ key: String?, model: NotesModel,
                                   responder: NSResponder?) -> NotesKey? {
        if responder is NotesTextView, model.listFocused { model.leaveList() }
        return NotesKey(code: code, flags: flags, key: key, list: model.listFocused, confirming: model.confirmingTrash,
                        actions: model.actions != nil, empty: code == 51 && model.isEmptyNote)
    }
}

/// One of Cmd+K's actions on a note (Sven 2026-10-15), in the menu's groups: the note itself, its words, the formats with
/// their keys (direction B, 2026-10-18), a new one, the Trash last in the problem colour.
enum NoteAction: Equatable {
    case pin, unpin, rename, duplicate, copy, reveal, format(MarkdownFormat), new, trash

    var title: String {
        switch self {
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .rename: "Rename"
        case .duplicate: "Duplicate"
        case .copy: "Copy as Markdown"
        case .reveal: "Reveal in Finder"
        case .new: "New note"
        case .trash: "Move to Trash"
        case .format(let format): format.title
        }
    }

    /// The key that does it without Cmd+K, as its row shows it.
    var key: String? {
        switch self {
        case .new: "⌘N"
        case .trash: "⌘⌫"
        case .format(let format): format.key
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .rename: "pencil"
        case .duplicate: "plus.square.on.square"
        case .copy: "doc.on.doc"
        case .reveal: "folder"
        case .new: "square.and.pencil"
        case .trash: "trash"
        case .format(let format): format.symbol
        }
    }

    var group: Int {
        switch self {
        case .pin, .unpin, .rename, .duplicate: 0
        case .copy, .reveal: 1
        case .format: 2
        case .new: 3
        case .trash: 4
        }
    }

    var danger: Bool { self == .trash }

    /// A note's actions, the formats only for the note being `writing` in: Scratch, never pinned, empty and kept, has only
    /// its words, Finder, the formats and New note.
    static func choices(for note: Note, writing: Bool = true) -> [NoteAction] {
        let formats = writing ? MarkdownFormat.keyed.map(NoteAction.format) : []
        if note.isScratch { return [.copy, .reveal] + formats + [.new] }
        return [note.pinned ? .unpin : .pin, .rename, .duplicate, .copy, .reveal] + formats + [.new, .trash]
    }

    /// A duplicate's words: the same, its title line ending " copy", so the two tell apart in the list.
    static func copied(_ text: String) -> String {
        let title = MarkdownFormat.titleRange(text)
        guard title.length > 0 else { return text }
        return (text as NSString).replacingCharacters(in: NSRange(location: NSMaxRange(title), length: 0), with: " copy")
    }
}

/// Cmd+K's list while open: the note it acts on, what is typed in its search and the highlighted action of the ones it
/// matches.
struct NoteActions: Equatable {
    let note: String
    let title: String
    let choices: [NoteAction]
    var index = 0
    var query = ""

    /// The actions whose title matches what is typed, as the menu's Cmd+K matches, in their groups' order.
    var visible: [NoteAction] {
        query.isEmpty ? choices : choices.filter { FuzzyRanker.score(query, in: $0.title) != nil }
    }
}
