import Foundation
import os
import Synchronization

/// A session command's program while its view is open (card agent-bo-95423245, ADR 0010): started by the first search
/// with the run message, then sent `{"type":"query","text":…}` for each later one, and answered in order, one list,
/// detail or error message per request. A request not answered within `timeout` stops it, as does `close`: the close
/// message, stdin closed, then the process tree stopped half a second later. Once stopped, every request gets the reason.
///
/// A Raycast-format command (ADR 0017, T2) runs this way in pilot-ext-host, started through ExtensionRun.launch in its
/// extension's folder. Its host answers when it likes: each query and each press (`invoke`, a callback by its handler id)
/// carries a number, `seq`, and the line that answers it carries it back as `ack`, answering every request up to it; the
/// first line answers the run. Any other line is an unsolicited commit (data arriving, a timer). Every line becomes the
/// newest view and the watcher is told, so the open view draws it, whoever asked.
///
/// A Raycast Form (T10) is edited by pressing a field's `change` handler with its new value (`edit`). The host may answer
/// an edit with an older value: the reply to an earlier edit, the view answered unchanged, or a controlled field's
/// echo that comes later. So while a field has edits the host has not agreed with, a value it sends that equals the
/// one before them or an older edit is a stale echo, and the newest edit is shown instead; the newest edit once every
/// edit is acked is agreement; any other value is the extension's own change, which wins.
///
/// A Raycast host may ask while its view is open (T11): an `ask` line (`AI.ask`, `getSelectedText`) is no answer; it is
/// answered through ExtensionAI on the host's stdin, and no request waits on it. The run message carries the
/// command's `input`, its first argument.
public final class ExtensionSession: Sendable {
    /// How long a closing program has between its close message and its stop.
    public static let closeGrace: Duration = .milliseconds(500)
    private static let log = Logger(subsystem: "dev.banozz.pilot", category: "extensions")

    private let command: Extension.Command, context: JSONValue?, inputs: ExtensionRun.Inputs, timeout: Duration, input: String?
    /// The child's environment, and Pilot's own, which says where the extension host is (ExtensionRun.host).
    private let environment: [String: String], pilot: [String: String]
    /// The extension's folder, where a Raycast-format command's host runs.
    private let folder: URL?

    /// What the open view shows now: the newest answer, and whether a Raycast List says it is still loading.
    public struct View: Equatable, Sendable {
        public let outcome: ListOutcome, loading: Bool
        /// A form's fields whose value on this line was a stale echo, shown as the newest edit instead, with what it said.
        public var stale: [String: JSONValue] = [:]
    }

    /// A form field's edits the host has not agreed with: its value before them, each value sent, the last one's number.
    private struct Edits { var base: JSONValue, sent: [JSONValue], seq: Int }

    private struct State {
        var child: ChildProcess.Session?
        /// A Raycast host's memory watch (ExtensionRun.watchMemory, T4), cancelled once it is gone.
        var memory: Task<Void, Never>?
        /// The requests waiting for their answers, oldest first, each with its number.
        var waiting: [(id: Int, answer: CheckedContinuation<ListOutcome, Never>)] = []
        var asked = 0
        /// Why the program no longer answers; set once and kept.
        var stopped: String?
        var ended = false, endWaiters: [CheckedContinuation<Void, Never>] = []
        /// A Raycast-format command's newest answer, who hears of each, and who waits for one no longer loading.
        var newest: View?
        var watcher: (@Sendable () -> Void)?
        var settling: [(id: Int, answer: CheckedContinuation<View?, Never>)] = [], settles = 0
        /// A form's open edits by field id, and the newest request the host acked.
        var edits: [String: Edits] = [:], acked = 0
    }

    private let state = Mutex(State())
    private var raycast: Bool { command.runtime == .raycast }

    public init(_ command: Extension.Command, context: JSONValue?, inputs: ExtensionRun.Inputs, folder: URL? = nil, input: String? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment, timeout: Duration = ExtensionRun.listTimeout) {
        self.command = command; self.context = context; self.inputs = inputs; self.timeout = timeout; self.folder = folder; self.input = input
        self.pilot = environment
        self.environment = ExtensionRun.environment(for: command, from: environment)
    }

    /// The program's pid once it started.
    public var pid: pid_t? { state.withLock { $0.child?.pid } }

    /// A Raycast-format command's newest answer; nil before its first.
    public var newest: View? { state.withLock { $0.newest } }

    /// Tells `watcher` of each answer (off the main actor).
    public func watch(_ watcher: @escaping @Sendable () -> Void) { state.withLock { $0.watcher = watcher } }

    /// Asks for what `query` shows: the first ask starts the program. Concurrent, so the launch is never on the main actor.
    @concurrent public func ask(_ query: String) async -> ListOutcome {
        await request(starts: true) { first, id in
            if first { return ExtensionRun.message(command, query: query, context: context, input: input, inputs: inputs) }
            return ExtensionRun.line(["type": .string("query"), "text": .string(query)].merging(raycast ? ["seq": .number(Double(id))] : [:]) { $1 })
        }
    }

    /// Presses the callback `handler` names in the newest answer (a Raycast-format command's, ADR 0017): the answer is
    /// the view after it, the current one unchanged when the id is stale.
    @concurrent public func invoke(_ handler: String) async -> ListOutcome {
        await request(starts: false) { _, id in
            Self.invokeLine(handler, seq: id)
        }
    }

    /// An `invoke` line: the press of `handler`, with a form's `value`, numbered `seq`.
    private static func invokeLine(_ handler: String, value: JSONValue? = nil, seq: Int) -> Data {
        ExtensionRun.line(["type": .string("invoke"), "handler": .string(handler), "seq": .number(Double(seq))].merging(value.map { ["value": $0] } ?? [:]) { $1 })
    }

    /// Types into the form field `id`: each of `values` pressed in order on its `handler`, without waiting between them,
    /// as keystrokes come (T10). The answer is the view after the last, the field showing the newest edit until the host
    /// agrees with it.
    @concurrent public func edit(_ id: String, handler: String, values: [JSONValue]) async -> ListOutcome {
        guard !values.isEmpty else { return newest?.outcome ?? .error("is not open") }
        return await request(starts: false, extra: values.count - 1, note: { s, last in Self.note(&s, id, values, last: last) }) { _, last in
            var lines = Data()
            for (offset, value) in values.enumerated() { lines += Self.invokeLine(handler, value: value, seq: last - values.count + 1 + offset) }
            return lines
        }
    }

    /// One edit of the form field `id`, sent at once and not waited for (a keystroke in Pilot's form panel): its answer
    /// is drawn as it comes, so edits leave in the order they are made. Nothing when the host is not open.
    public func edit(_ id: String, handler: String, value: JSONValue) {
        state.withLock { s in
            guard s.stopped == nil, let child = s.child else { return }
            s.asked += 1
            Self.note(&s, id, [value], last: s.asked)
            child.send(Self.invokeLine(handler, value: value, seq: s.asked))
        }
    }

    /// Records `values` sent to field `id`, the last numbered `last`, from the value it showed before its open edits.
    private static func note(_ s: inout State, _ id: String, _ values: [JSONValue], last: Int) {
        let base = s.newest?.outcome.form?.field(id)?.value ?? .null
        s.edits[id, default: Edits(base: base, sent: [], seq: last)].sent.append(contentsOf: values)
        s.edits[id]?.seq = last
    }

    /// Waits, up to `timeout`, for an answer that is no longer loading; the newest answer then, loading or not.
    @concurrent public func settled() async -> View? {
        await withCheckedContinuation { continuation in
            let id = state.withLock { s -> Int? in
                if s.stopped != nil || s.newest?.loading == false {
                    continuation.resume(returning: s.newest)
                    return nil
                }
                s.settles += 1
                s.settling.append((s.settles, continuation))
                return s.settles
            }
            guard let id else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.inSeconds) { [weak self] in
                self?.state.withLock { s in
                    guard let at = s.settling.firstIndex(where: { $0.id == id }) else { return }
                    s.settling.remove(at: at).answer.resume(returning: s.newest)
                }
            }
        }
    }

    /// One request: the first starts the program (when `starts` lets it) with the run message, a later one sends what
    /// `message` makes of its number. `extra` numbers go to lines sent before it in the same message, none waited for;
    /// `note` records what the request changes, in the same lock as its send.
    private func request(starts: Bool, extra: Int = 0, note: (inout State, _ id: Int) -> Void = { _, _ in },
                         _ message: (_ first: Bool, _ id: Int) -> Data) async -> ListOutcome {
        await withCheckedContinuation { continuation in
            let id = state.withLock { s -> Int? in
                if let stopped = s.stopped {
                    continuation.resume(returning: .error(stopped))
                    return nil
                }
                let first = s.child == nil
                if first {
                    guard starts else {
                        continuation.resume(returning: .error("is not open"))
                        return nil
                    }
                    do {
                        let (path, arguments, directory) = try ExtensionRun.launch(command, folder: folder, environment: pilot)
                        let child = try ChildProcess.Session(path, arguments, environment: environment, directory: directory,
                                                             lines: { [weak self] in self?.received($0) }, ended: { [weak self] in self?.ended(status: $0, stderr: $1) })
                        s.child = child
                        if raycast { s.memory = ExtensionRun.watchMemory(of: child.pid) { [weak self] in self?.overMemory() } }
                    } catch {
                        let reason = stop(&s, because: "did not start: \(error.localizedDescription)")
                        finish(&s)
                        continuation.resume(returning: .error(reason))
                        return nil
                    }
                }
                s.asked += 1 + extra
                s.waiting.append((s.asked, continuation))
                note(&s, s.asked)
                s.child?.send(message(first, s.asked))
                return s.asked
            }
            guard let id else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.inSeconds) { [weak self] in self?.expire(id) }
        }
    }

    /// The view closed: the close message, stdin closed, the program stopped after closeGrace. Requests still waiting get
    /// "closed", which no one shows.
    public func close() {
        let child = state.withLock { s -> ChildProcess.Session? in
            stop(&s, because: "closed")
            if s.child == nil { finish(&s) }
            return s.child
        }
        guard let child else { return }
        child.send(ExtensionRun.line(["type": .string("close")]))
        child.closeInput()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.closeGrace.inSeconds) { child.stop() }
    }

    /// Returns once the program is gone (at once when it never started and the session closed).
    public func ended() async {
        await withCheckedContinuation { continuation in
            state.withLock { s in
                if s.ended { continuation.resume() } else { s.endWaiters.append(continuation) }
            }
        }
    }

    /// One line the program printed: the answer to the oldest waiting request, unless it is no answer at all. A line
    /// outside the message format, such as a debug print, is logged and answers nothing, so it never shifts the answers.
    /// A Raycast-format command's answers what it acks (or, the first, the run), else is unsolicited.
    private func received(_ line: String) {
        if raycast, let (number, ask) = ExtensionAI.hostAsk(line) { return answer(number, ask) }
        let outcome: ListOutcome, meta: ExtensionRun.Meta
        switch ExtensionRun.reply(line) {
        case .answer(let answer, let fields): (outcome, meta) = (answer, fields)
        case .plain: return Self.log.debug("\(self.command.actionID, privacy: .public) printed a plain line: \(line.prefix(200))")
        case .skip: return
        }
        guard raycast else {
            return state.withLock { s in
                guard !s.waiting.isEmpty else { return }
                s.waiting.removeFirst().answer.resume(returning: outcome)
            }
        }
        let watcher = state.withLock { s -> (@Sendable () -> Void)? in
            if let ack = meta.ack { s.acked = max(s.acked, ack) }
            let (shown, stale) = merged(outcome, &s)
            let first = s.newest == nil, view = View(outcome: shown, loading: meta.loading, stale: stale)
            s.newest = view
            if !view.loading { settle(&s) }
            // An error answers everything waiting; an ack every request up to it; the first line the run.
            let upTo: Int? = if case .error = shown { s.asked } else if let ack = meta.ack { ack } else if first { 1 } else { nil }
            if let upTo {
                for waiter in s.waiting where waiter.id <= upTo { waiter.answer.resume(returning: shown) }
                s.waiting.removeAll { $0.id <= upTo }
            }
            return s.watcher
        }
        watcher?()
    }

    /// Answers the host's ask `number` off this thread, on its stdin, unless the session stopped meanwhile (T11).
    private func answer(_ number: Int, _ ask: ExtensionAI.HostAsk) {
        let id = command.id.extension
        Task.detached { [weak self] in
            let answer = await ExtensionAI.answer(number, ask, of: id)
            self?.state.withLock { s in
                guard s.stopped == nil else { return }
                s.child?.send(answer)
            }
        }
    }

    /// A form's line with each field's stale echo replaced by its newest edit (the rule above), and what each said; the
    /// edits end once agreed, or when the extension changed the field or the view is no longer a form.
    private func merged(_ outcome: ListOutcome, _ s: inout State) -> (ListOutcome, [String: JSONValue]) {
        guard case .form(var form) = outcome else {
            s.edits = [:]
            return (outcome, [:])
        }
        var stale: [String: JSONValue] = [:]
        for (index, field) in form.fields.enumerated() {
            guard let id = field.id, let edits = s.edits[id], let newest = edits.sent.last else { continue }
            let said = field.value ?? .null
            if said == newest {
                if s.acked >= edits.seq { s.edits[id] = nil }
            } else if said == edits.base || edits.sent.dropLast().contains(said) {
                form.fields[index].value = newest
                stale[id] = said
            } else {
                s.edits[id] = nil
            }
        }
        return (.form(form), stale)
    }

    /// Request `id`'s time ran out: when it is still waiting, the program is stopped.
    private func expire(_ id: Int) {
        let child = state.withLock { s -> ChildProcess.Session? in
            guard s.waiting.contains(where: { $0.id == id }) else { return nil }
            stop(&s, because: ExtensionRun.late(timeout))
            return s.child
        }
        child?.stop()
    }

    /// The host passed the memory stop (T4): it is stopped, and the open view shows why as its error row.
    private func overMemory() {
        let reason = ExtensionRun.OverMemory(limitMB: ExtensionRun.memoryStopMB).localizedDescription
        let (child, watcher) = state.withLock { s -> (ChildProcess.Session?, (@Sendable () -> Void)?) in
            guard s.stopped == nil else { return (nil, nil) }
            stop(&s, because: reason)
            s.newest = View(outcome: .error(reason), loading: false)
            return (s.child, s.watcher)
        }
        child?.stop()
        watcher?()
    }

    private func ended(status: Int32, stderr: String) {
        state.withLock { s in
            stop(&s, because: status != 0 && !stderr.isEmpty ? "stopped with an error: \(stderr.prefix(120))" : "stopped")
            finish(&s)
        }
    }

    /// Answers every waiting request with the reason the program stopped, the first one given and kept for later
    /// requests, which it returns.
    @discardableResult private func stop(_ s: inout State, because reason: String) -> String {
        let kept = s.stopped ?? reason
        s.stopped = kept
        for waiter in s.waiting { waiter.answer.resume(returning: .error(kept)) }
        s.waiting = []
        settle(&s)
        return kept
    }

    /// Hands everyone waiting in `settled` the newest answer.
    private func settle(_ s: inout State) {
        for waiter in s.settling { waiter.answer.resume(returning: s.newest) }
        s.settling = []
    }

    private func finish(_ s: inout State) {
        s.memory?.cancel()
        s.ended = true
        s.endWaiters.forEach { $0.resume() }
        s.endWaiters = []
    }
}
