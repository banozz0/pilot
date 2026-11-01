import AppKit
import PilotCore

/// One open view of an extension's list or detail command (cards agent-bo-95423243, 245): it asks the program for rows
/// as the search changes and shows them in the menu's live picker, a detail as its one row. With Pilot's filter the
/// program runs once and the menu ranks its rows; with the program's own, a change asks again once typing pauses, so
/// the newest search's answer is the one shown: a one-shot program runs again, the run before cancelled (its process
/// tree stopped); a session's one process is sent the search (ExtensionSession) and stopped as the view closes.
@MainActor
final class ExtensionListSession: MenuSource {
    /// How long typing must pause before the program is asked again: a run per keystroke would mostly be killed unread.
    static let pause: Duration = .milliseconds(80)

    let ext: Extension, command: Extension.Command
    var show: ([MenuEntry]) -> Void = { _ in }
    private let run: (Extension.Command, String) async -> ListOutcome
    /// Ends the transport as the view closes: a session's process; nothing for one-shot runs, each stopped as cancelled.
    private let end: () -> Void
    private let pause: () async -> Void
    private(set) var items: [Extension.Item] = []
    private var task: Task<Void, Never>?
    private var asked = false
    /// The search last asked, which a refresh asks again.
    private var query = ""

    /// What the row that pushed this list handed on, in each run message (card agent-bo-95423244).
    let context: JSONValue?
    /// The extension's preferences and folders, in each run message and handed to the views and runs its rows start (card agent-bo-95423246).
    let inputs: ExtensionRun.Inputs

    /// `run` and `end` stand in for the program in a test; `pause` waits out the typing pause, which a test releases by hand.
    init(_ ext: Extension, _ command: Extension.Command, inputs: ExtensionRun.Inputs, context: JSONValue? = nil,
         run: ((Extension.Command, String) async -> ListOutcome)? = nil, end: (() -> Void)? = nil,
         pause: @escaping () async -> Void = { try? await Task.sleep(for: ExtensionListSession.pause) }) {
        self.ext = ext; self.command = command; self.inputs = inputs; self.context = context; self.pause = pause
        if let run {
            self.run = run
            self.end = end ?? {}
        } else if command.session {
            let session = ExtensionSession(command, context: context, inputs: inputs)
            self.run = { await session.ask($1) }
            self.end = session.close
        } else {
            self.run = { await ExtensionRun.list($0, query: $1, context: context, inputs: inputs) }
            self.end = {}
        }
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
        task = Task { [weak self, command, run, pause] in
            if !now { await pause() }
            guard !Task.isCancelled else { return }
            let outcome = await run(command, query)
            guard !Task.isCancelled, let self else { return }
            let rows: [MenuEntry]
            var dropped = 0
            switch outcome {
            case .items(let items):
                self.items = items
                rows = ExtensionList.entries(items, of: command)
                dropped = items.reduce(0) { $0 + $1.dropped }
            case .detail(let detail):
                items = [Extension.Item(title: command.title, actions: detail.actions)]
                var row = ExtensionList.detail(detail, of: command)
                if ext.shownSurface != nil { row.extensionPage = ext.id }
                rows = [row]
                dropped = detail.dropped
            case .error(let reason):
                items = []
                rows = [ExtensionList.error(reason, of: command, in: ext.title)]
                dlog.error("extension: \(command.actionID, privacy: .public) list: \(reason, privacy: .private)")
            }
            dlog.notice("extension: \(command.actionID, privacy: .public) listed \(self.items.count) rows")
            if dropped > 0 { dlog.error("extension: \(command.actionID, privacy: .public) dropped \(dropped) actions of a type Pilot does not know") }
            show(rows)
        }
    }

    /// The run in flight has answered or been cancelled.
    func settled() async { await task?.value }

    /// The view closed: its run stops, a session's process with it.
    func close() {
        task?.cancel()
        end()
    }

    /// The action `index` of `row`'s item (0 is Return's); nil for the error row or an index it lacks.
    func action(_ index: Int = 0, for row: MenuEntry) -> Extension.Item.Action? {
        ExtensionList.item(at: row, in: items).flatMap { $0.actions.indices.contains(index) ? $0.actions[index] : nil }
    }

    func pick(_ row: MenuEntry, action index: Int) -> MenuPick { action(index, for: row).map { ExtensionActions.pick($0, in: ext, inputs: inputs) } ?? .stay }
}
