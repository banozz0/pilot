import AppKit
import PilotCore

/// One open view of an extension's list or detail command (cards agent-bo-95423243, 245): it asks the program for rows
/// as the search changes and shows them in the menu's live picker, a detail as its one row. With Pilot's filter the
/// program runs once and the menu ranks its rows; with the program's own, a change asks again once typing pauses, so
/// the newest search's answer is the one shown: a one-shot program runs again, the run before cancelled (its process
/// tree stopped); a session's one process is sent the search (ExtensionSession) and stopped as the view closes. A
/// Raycast-format command (ADR 0017) is always a session, its host kept while the view is open: every answer it sends is
/// drawn, the newest last, a List still loading under Pilot's loading row, and a row's callback is pressed in it (T2).
/// An `Action.Push` (T8) opens a view of the menu's own over this one, filled by the same host: its first ask is the
/// push, it draws the host's answers while it is on top, and its Escape sends the host back to the view under it
/// (`navigation.pop.<depth>`) and hands the answers back to that view. A push or pop a callback makes itself redraws the
/// view on top in place; the next Escape still lands on the view under it. A Form (T10) opens in a key panel of its own
/// (ExtensionFormPanel), which takes the host over: the menu gives way, and its views leave the host running as they
/// close, the panel ending it.
@MainActor
final class ExtensionListSession: MenuSource {
    /// How long typing must pause before the program is asked again: a run per keystroke would mostly be killed unread.
    static let pause: Duration = .milliseconds(80)

    let ext: Extension, command: Extension.Command
    var show: ([MenuEntry]) -> Void = { _ in }
    /// The list's empty view while it has no rows (T26), nil otherwise; set before `show`.
    var showEmpty: (Extension.Empty?) -> Void = { _ in }
    private let run: (Extension.Command, String) async -> ListOutcome
    /// Ends the transport as the view closes: a session's process; nothing for one-shot runs, each stopped as cancelled.
    private let end: () -> Void
    private let pause: () async -> Void
    private(set) var items: [Extension.Item] = []
    /// A Raycast-format command's host, while the view is open.
    private let session: ExtensionSession?
    private var task: Task<Void, Never>?
    private var asked = false
    /// A draw of the host's newest answer is on its way; a burst of commits waits for that one.
    private var drawing = false
    /// The search last asked, which a refresh asks again.
    private var query = ""
    /// A pushed view's push, which its first ask presses (T8).
    private var pushing: String?
    /// How many views deep this one is in its host's stack: the command's own view is 1.
    private let depth: Int
    /// The host's handler that goes back a view (Escape), and `.<n>` after it back to the n-th; a push's ends in `.push`.
    static let pop = "navigation.pop", push = ".push"

    /// What the row that pushed this list handed on, in each run message (card agent-bo-95423244).
    let context: JSONValue?
    /// The extension's preferences and folders, in each run message and handed to the views and runs its rows start (card agent-bo-95423246).
    let inputs: ExtensionRun.Inputs

    /// `run` and `end` stand in for the program in a test; `pause` waits out the typing pause, which a test releases by hand.
    /// `input`: the words typed after a Raycast command's keyword at the root, its first argument (T11).
    init(_ ext: Extension, _ command: Extension.Command, inputs: ExtensionRun.Inputs, context: JSONValue? = nil, input: String? = nil,
         run: ((Extension.Command, String) async -> ListOutcome)? = nil, end: (() -> Void)? = nil,
         pause: @escaping () async -> Void = { try? await Task.sleep(for: ExtensionListSession.pause) }) {
        self.ext = ext; self.command = command; self.inputs = inputs; self.context = context; self.pause = pause; depth = 1
        var raycast: ExtensionSession?
        if let run {
            self.run = run
            self.end = end ?? {}
        } else if command.session || command.runtime == .raycast {
            let session = ExtensionSession(command, context: context, inputs: inputs, folder: ext.folder, input: input)
            if command.runtime == .raycast { raycast = session }
            self.run = { await session.ask($1) }
            self.end = session.close
        } else {
            self.run = { await ExtensionRun.list($0, query: $1, context: context, inputs: inputs) }
            self.end = {}
        }
        session = raycast
        listen()
    }

    /// The view a row's `Action.Push` opens over `parent`, in the same host (T8): its close goes back a view, not the host.
    private init(pushing handler: String, over parent: ExtensionListSession, in session: ExtensionSession) {
        ext = parent.ext; command = parent.command; inputs = parent.inputs; context = parent.context; pause = parent.pause
        self.session = session
        pushing = handler
        depth = parent.depth + 1
        run = { await session.ask($1) }
        end = { [weak parent, back = "\(Self.pop).\(parent.depth)"] in
            parent?.listen()
            Task { _ = await session.invoke(back) }
        }
    }

    /// The host's answers are drawn here from now on: as the view opens, and again once the view pushed over it closes.
    private func listen() {
        session?.watch { [weak self] in Task { @MainActor in self?.drawQueued() } }
    }

    /// The search changed (the empty one as the list opens, asked at once).
    func search(_ query: String) {
        guard command.filter == .program || !asked else { return }
        ask(query, now: !asked)
    }

    /// Asked again at once with the search as it stands, Pilot's filter or the program's (after a run that stays); the
    /// row of `row`'s item, by its id, while it is still in the same section.
    func refresh(keeping row: MenuEntry?) async -> MenuEntry.Target? {
        let held = row.flatMap { ExtensionList.item(at: $0, in: items) }
        ask(query, now: true)
        await settled()
        guard let id = held?.id, let index = items.firstIndex(where: { $0.id == id && $0.section == held?.section }) else { return nil }
        return .action("\(command.actionID)#\(index)")
    }

    private func ask(_ query: String, now: Bool) {
        asked = true
        self.query = query
        task?.cancel()
        // A pushed view's first ask is its push; the answers it brings are drawn here, not in the view under it.
        let push = pushing
        if push != nil { pushing = nil; listen() }
        task = Task { [weak self, command, run, pause, session] in
            if !now { await pause() }
            guard !Task.isCancelled else { return }
            let outcome = if let push, let session { await session.invoke(push) } else { await run(command, query) }
            guard !Task.isCancelled, let self else { return }
            // A Raycast host's answers are drawn as they come (drawQueued); only a stop's reason, which is no line, is drawn here.
            if session == nil { display(outcome) } else if case .error = outcome { display(outcome) }
        }
    }

    /// Draws a Raycast host's newest answer once per burst: by the time this runs, later commits are in `newest` too.
    private func drawQueued() {
        guard !drawing else { return }
        drawing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            drawing = false
            if let view = session?.newest { display(view.outcome, loading: view.loading) }
        }
    }

    /// Shows what the program answered, under the loading row while it still loads.
    private func display(_ outcome: ListOutcome, loading: Bool = false) {
        var rows: [MenuEntry]
        var dropped = 0
        switch outcome {
        case .items(let items):
            self.items = items
            rows = ExtensionList.entries(items, of: command)
            dropped = items.reduce(0) { $0 + $1.dropped }
        case .detail(let detail):
            items = ExtensionList.items(detail, of: command)
            var row = ExtensionList.detail(detail, of: command)
            if ext.shownSurface != nil { row.extensionPage = ext.id }
            rows = [row]
            dropped = detail.dropped
        case .form:
            items = []
            if let session, !ExtensionFormPanel.owns(session) { ExtensionFormPanel.show(session, ext: ext, command: command) }
            rows = [MenuEntry(title: "\(ext.title) opened its form in a window of its own", target: .action("\(command.actionID)#form"), isAnswer: true,
                              icon: .command(emoji: command.icon))]
        case .empty(let empty):
            // Its actions ride one row the panel keeps behind the empty look (MenuParts), so Return and Cmd+K press them
            // as a row's (T28).
            items = empty.item.map { [$0] } ?? []
            rows = ExtensionList.entries(items, of: command)
        case .error(let reason):
            items = []
            rows = [ExtensionList.error(reason, of: command, in: ext.title)]
            dlog.error("extension: \(self.command.actionID, privacy: .public) list: \(reason, privacy: .private)")
        }
        if case .empty(let empty) = outcome { showEmpty(empty) } else { showEmpty(nil) }
        dlog.notice("extension: \(self.command.actionID, privacy: .public) listed \(self.items.count) rows")
        if dropped > 0 { dlog.error("extension: \(self.command.actionID, privacy: .public) dropped \(dropped) actions of a type Pilot does not know") }
        if loading {
            rows.insert(MenuEntry(title: "\(ext.title) is loading…", target: .action("\(command.actionID)#loading"), isAnswer: true,
                                  icon: .command(emoji: command.icon)), at: 0)
        }
        show(rows)
    }

    /// A Raycast command's host still runs, so its view can be kept as the panel closes (T30).
    var keepsRunning: Bool { session.map { $0.stopped == nil } ?? false }

    /// The host's newest answer drawn again: a kept view shown once more, its draws while hidden having gone nowhere.
    func redraw() {
        if session?.newest != nil { drawQueued() }
    }

    /// The run in flight has answered or been cancelled.
    func settled() async { await task?.value }

    /// The view closed: its run stops, a session's process with it.
    func close() {
        task?.cancel()
        if let session, ExtensionFormPanel.owns(session) { return }
        end()
    }

    /// The action `index` of `row`'s item (0 is Return's); nil for the error row or an index it lacks.
    func action(_ index: Int = 0, for row: MenuEntry) -> Extension.Item.Action? {
        ExtensionList.item(at: row, in: items).flatMap { $0.actions.indices.contains(index) ? $0.actions[index] : nil }
    }

    /// A callback is pressed in the open view's host, the panel kept open: its answer is drawn as it comes. A push opens
    /// its view over this one (the host names it `<serial>.push`).
    func pick(_ row: MenuEntry, action index: Int) -> MenuPick {
        guard let action = action(index, for: row) else { return .stay }
        guard case .invoke(let handler) = action.kind else { return ExtensionActions.pick(action, in: ext, inputs: inputs) }
        guard let session else { return .stay }
        if handler.hasSuffix(Self.push) { return .push(action.label, ExtensionListSession(pushing: handler, over: self, in: session)) }
        return .keep(clear: false, back: false) { Task { _ = await session.invoke(handler) } }
    }
}
