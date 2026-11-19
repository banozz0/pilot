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
public final class ExtensionSession: Sendable {
    /// How long a closing program has between its close message and its stop.
    public static let closeGrace: Duration = .milliseconds(500)
    private static let log = Logger(subsystem: "dev.banozz.pilot", category: "extensions")

    private let command: Extension.Command, context: JSONValue?, inputs: ExtensionRun.Inputs, timeout: Duration
    /// The child's environment, and Pilot's own, which says where the extension host is (ExtensionRun.host).
    private let environment: [String: String], pilot: [String: String]
    /// The extension's folder, where a Raycast-format command's host runs.
    private let folder: URL?

    /// What the open view shows now: the newest answer, and whether a Raycast List says it is still loading.
    public struct View: Equatable, Sendable {
        public let outcome: ListOutcome, loading: Bool
    }

    private struct State {
        var child: ChildProcess.Session?
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
    }

    private let state = Mutex(State())
    private var raycast: Bool { command.runtime == .raycast }

    public init(_ command: Extension.Command, context: JSONValue?, inputs: ExtensionRun.Inputs, folder: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment, timeout: Duration = ExtensionRun.listTimeout) {
        self.command = command; self.context = context; self.inputs = inputs; self.timeout = timeout; self.folder = folder
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
            if first { return ExtensionRun.message(command, query: query, context: context, inputs: inputs) }
            return ExtensionRun.line(["type": .string("query"), "text": .string(query)].merging(raycast ? ["seq": .number(Double(id))] : [:]) { $1 })
        }
    }

    /// Presses the callback `handler` names in the newest answer (a Raycast-format command's, ADR 0017): the answer is
    /// the view after it, the current one unchanged when the id is stale.
    @concurrent public func invoke(_ handler: String) async -> ListOutcome {
        await request(starts: false) { _, id in
            ExtensionRun.line(["type": .string("invoke"), "handler": .string(handler), "seq": .number(Double(id))])
        }
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
    /// `message` makes of its number.
    private func request(starts: Bool, _ message: (_ first: Bool, _ id: Int) -> Data) async -> ListOutcome {
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
                        s.child = try ChildProcess.Session(path, arguments, environment: environment, directory: directory,
                                                           lines: { [weak self] in self?.received($0) }, ended: { [weak self] in self?.ended(status: $0, stderr: $1) })
                    } catch {
                        let reason = stop(&s, because: "did not start: \(error.localizedDescription)")
                        finish(&s)
                        continuation.resume(returning: .error(reason))
                        return nil
                    }
                }
                s.asked += 1
                s.waiting.append((s.asked, continuation))
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
            let first = s.newest == nil, view = View(outcome: outcome, loading: meta.loading)
            s.newest = view
            if !view.loading { settle(&s) }
            // An error answers everything waiting; an ack every request up to it; the first line the run.
            let upTo: Int? = if case .error = outcome { s.asked } else if let ack = meta.ack { ack } else if first { 1 } else { nil }
            if let upTo {
                for waiter in s.waiting where waiter.id <= upTo { waiter.answer.resume(returning: outcome) }
                s.waiting.removeAll { $0.id <= upTo }
            }
            return s.watcher
        }
        watcher?()
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
        s.ended = true
        s.endWaiters.forEach { $0.resume() }
        s.endWaiters = []
    }
}
