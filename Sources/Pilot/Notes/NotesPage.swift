import AppKit
import PilotCore
import SwiftUI

/// Notes in the app window (task N1, Sven 2026-10-09: "notes should be accessible from inside the app as well"), direction
/// B (P60, 2026-10-18): the window has room, so the panel's list stays docked on the left, the folder one line under it;
/// the note beside it keeps the panel's head, a 620 pt measure and the panel's keys (Escape into the list, ⌘K, ⌘N, ⌘P,
/// ⌘⌫), through a key monitor while the page is on screen (NotesPageKeys). The page and the Hyper+Shift+N panel share
/// one model (NotesPanel.currentModel), so an edit in one shows in the other as it is typed.
struct NotesPage: View {
    /// Where a render starts.
    struct Start {
        /// Typed in the list's field, which has the keyboard.
        var query = ""
        /// A note waiting for its Trash confirm.
        var trashing: String?
        /// A folder picked, waiting for the move question.
        var picked: URL?
        /// Cmd+K open on the note.
        var actions = false
    }

    @Environment(\.style) private var style
    @Environment(Engine.self) private var engine
    /// The window shows: the folder is read again each time it comes back, and the page takes the panel's keys.
    let onScreen: Bool
    /// A render's own model; the app's is the panel's.
    private let given: NotesModel?
    private let start: Start
    @State private var model: NotesModel?
    @State private var keys = NotesPageKeys()

    init(onScreen: Bool, model: NotesModel? = nil, start: Start = .init()) {
        self.onScreen = onScreen
        self.start = start
        given = model
        _model = State(initialValue: model)
    }

    static let listWidth: CGFloat = 290

    var body: some View {
        GeometryReader { g in
            if let model {
                HStack(spacing: 0) {
                    NotesList(model: model, folder: (NotesFolder.folder(engine.settings.notesFolder), start.picked))
                        .frame(width: min(Self.listWidth, g.size.width * 0.38))
                    VStack(spacing: 0) {
                        NotesHead(model: model)
                        NotesNote(model: model, measure: NotesMeasure.page).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(style.color(\.panel))
                }
                .overlay(alignment: .bottomTrailing) { NotesActionsView(model: model).padding(12) }
            }
        }
        // The panel's model, again when the folder changes; the folder is read each time the page comes on screen.
        .task(id: "\(onScreen) \(engine.settings.notesFolder ?? "")") {
            let model = given ?? NotesPanel.shared.currentModel()
            self.model = model
            model.reload()
            // A render's start, on its own model.
            if given != nil, !start.query.isEmpty { model.focusList(); model.queryField = start.query }
            if given != nil, let id = start.trashing { model.open(id); model.askTrash() }
            if given != nil, start.actions { model.openActions() }
            if onScreen { keys.start(model) } else { keys.stop() }
        }
        .onDisappear {
            keys.stop()
            model?.flush()
        }
    }

    /// A panel key on the page: as in the panel, but Escape in the list goes back to the note, as there is no panel
    /// to hide.
    static func perform(_ key: NotesKey, on model: NotesModel) {
        if key == .hide { model.leaveList() } else { model.perform(key) }
    }
}

/// The Notes page's keys: the panel's (NotesKey), from a key monitor on Pilot's window, only while the note's editor or
/// the list's own field has the keyboard, so a key in another of the window's fields (⌘F's) goes on.
@MainActor
final class NotesPageKeys {
    private var monitor: Any?

    func start(_ model: NotesModel) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            let taken = MainActor.assumeIsolated {
                // The app window's alone: a text file's window (T49) holds a NotesTextView too.
                guard let model, let window = event.window as? PilotWindow, window === AppWindowController.shared.window, window.isKeyWindow,
                      let key = Self.key(event.keyCode, event.modifierFlags, event.charactersIgnoringModifiers, model: model,
                                         responder: window.firstResponder) else { return false }
                NotesPage.perform(key, on: model)
                return true
            }
            return taken ? nil : event
        }
    }

    /// What a key does on the page with `responder` holding the keyboard: the panel's key while the note's editor or the
    /// list's own field has it (the editor's outranking a list the model still thinks open, NotesKey.pressed); nil (the
    /// key goes on) for any other field.
    static func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ characters: String?, model: NotesModel, responder: NSResponder?) -> NotesKey? {
        guard responder is NotesTextView || NotesField.holds(responder) else { return nil }
        return NotesKey.pressed(code, flags, characters, model: model, responder: responder)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// How long the notes key reopens the note left (NotesReopen, Sven 2026-11-12), over the folder's line: `pilot set
/// notes.reopenMinutes` takes any count in its range, which the picker then lists too.
struct NotesReopenLine: View {
    @Environment(\.style) private var style
    @Environment(Engine.self) private var engine

    static let offered = [0, 5, 15, 30, 60]
    static let info = "Open quick notes again within this time and they open on the note you left, caret and all. After it, or with Always Scratch, they open on Scratch."

    static func title(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Always Scratch"
        case 60: "1 hour"
        default: "\(minutes) min"
        }
    }

    var body: some View {
        let minutes = Binding(get: { engine.settings.notesReopenMinutes }, set: { engine.settings.notesReopenMinutes = $0 })
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).accessibilityHidden(true)
            Text("Reopen last note").styleText(\.caption).lineLimit(1).fixedSize()
            InfoMark(text: Self.info)
            Spacer(minLength: 6)
            Picker("Reopen last note", selection: minutes) {
                ForEach(Set(Self.offered + [minutes.wrappedValue]).sorted(), id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(maxWidth: 120)
        }
        .foregroundStyle(style.color(\.text2))
        .frame(height: 20)
    }
}

/// Where the notes live (task N1), one line under the Notes page's list (direction B): the folder, which a click shows
/// in Finder, Pilot's own when another is picked, and Change… with a picker; when the folder holds notes, a change asks
/// over the line whether they move too (Move notes, Leave them, Cancel).
struct NotesFolderLine: View {
    @Environment(\.style) private var style
    /// The folder the notes are read from now.
    let folder: URL
    /// A folder picked and the notes the move question would carry there.
    @State private var pending: (url: URL, count: Int)?
    @State private var problem: String?

    init(folder: URL, picked: URL? = nil) {
        self.folder = folder
        _pending = State(initialValue: picked.map { ($0, NotesFolder.notes(in: folder).count) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pending {
                Text("Move the \(ExtensionsPageView.plural(pending.count, "note")) to \(tilde(pending.url))?").styleText(\.caption)
                    .foregroundStyle(style.color(\.text)).lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Cancel") { self.pending = nil }.buttonStyle(.pilotSoft)
                    Button("Leave them") { change(to: pending.url, move: false) }.buttonStyle(.pilot)
                    Button("Move notes") { change(to: pending.url, move: true) }.buttonStyle(.pilotPrimary)
                }
                .controlSize(.small)
            }
            if let problem { FinePrint(text: problem, color: style.color(\.problem)) }
            NotesReopenLine()
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 11)).accessibilityHidden(true)
                Button(tilde(folder)) { reveal() }.buttonStyle(.plain).focusable(false)
                    .lineLimit(1).truncationMode(.middle).help("Reveal in Finder: each note is a Markdown file here")
                Spacer(minLength: 6)
                if folder != NotesFolder.pilotDefault { link("Pilot’s own") { ask(NotesFolder.pilotDefault) } }
                link("Change…") { choose() }
            }
            .styleText(\.mono).foregroundStyle(style.color(\.text3))
            .frame(height: 20)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .top) { NotesRule() }
    }

    private func link(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain).focusable(false)
            .styleText(\.caption).foregroundStyle(style.color(\.text2)).fixedSize()
    }

    private func tilde(_ url: URL) -> String { AppConfigs.tilde(url.path, home: NSHomeDirectory()) }

    private func reveal() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Use folder"
        panel.message = "Pick where your notes live."
        if panel.runModal() == .OK, let url = panel.url { ask(url) }
    }

    /// Straight there when no note would move; else the question.
    private func ask(_ url: URL) {
        guard !NotesFolder.same(url, folder) else { pending = nil; return }
        let count = NotesFolder.notes(in: folder).count
        if count == 0 { change(to: url, move: false) } else { pending = (url, count) }
    }

    private func change(to url: URL, move: Bool) {
        do {
            try NotesPanel.shared.changeFolder(to: url, move: move)
            pending = nil
            problem = nil
        } catch {
            problem = "Could not move the notes: \(error.localizedDescription)"
        }
    }
}
