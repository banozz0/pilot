import Foundation
import os
import Synchronization

/// A session command's program while its view is open (card agent-bo-95423245, ADR 0010): started by the first search
/// with the run message, then sent `{"type":"query","text":…}` for each later one, and answered in order, one list,
/// detail or error message per request. A request not answered within `timeout` stops it, as does `close`: the close
/// message, stdin closed, then the process tree stopped half a second later. Once stopped, every request gets the reason.
public final class ExtensionSession: Sendable {
    /// How long a closing program has between its close message and its stop.
    public static let closeGrace: Duration = .milliseconds(500)
    private static let log = Logger(subsystem: "dev.banozz.pilot", category: "extensions")

    private let command: Extension.Command, context: JSONValue?, inputs: ExtensionRun.Inputs, environment: [String: String], timeout: Duration

    private struct State {
        var child: ChildProcess.Session?
        /// The requests waiting for their answers, oldest first, each with its number.
        var waiting: [(id: Int, answer: CheckedContinuation<ListOutcome, Never>)] = []
        var asked = 0
        /// Why the program no longer answers; set once and kept.
        var stopped: String?
        var ended = false, endWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init(_ command: Extension.Command, context: JSONValue?, inputs: ExtensionRun.Inputs,
                environment: [String: String] = ProcessInfo.processInfo.environment, timeout: Duration = ExtensionRun.listTimeout) {
        self.command = command; self.context = context; self.inputs = inputs; self.timeout = timeout
        self.environment = ExtensionRun.environment(for: command, from: environment)
    }

    /// The program's pid once it started.
    public var pid: pid_t? { state.withLock { $0.child?.pid } }

    /// Asks for what `query` shows: the first ask starts the program. Concurrent, so the launch is never on the main actor.
    @concurrent public func ask(_ query: String) async -> ListOutcome {
        await withCheckedContinuation { continuation in
            let id = state.withLock { s -> Int? in
                if let stopped = s.stopped {
                    continuation.resume(returning: .error(stopped))
                    return nil
                }
                let first = s.child == nil
                if first {
                    do {
                        s.child = try ChildProcess.Session(command.program.path, environment: environment, directory: command.program.deletingLastPathComponent(),
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
                s.child?.send(first ? ExtensionRun.message(command, query: query, context: context, inputs: inputs)
                                    : ExtensionRun.line(["type": .string("query"), "text": .string(query)]))
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
    private func received(_ line: String) {
        let outcome: ListOutcome
        switch ExtensionRun.reply(line) {
        case .answer(let answer): outcome = answer
        case .plain: return Self.log.debug("\(self.command.actionID, privacy: .public) printed a plain line: \(line.prefix(200))")
        case .skip: return
        }
        state.withLock { s in
            guard !s.waiting.isEmpty else { return }
            s.waiting.removeFirst().answer.resume(returning: outcome)
        }
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
        return kept
    }

    private func finish(_ s: inout State) {
        s.ended = true
        s.endWaiters.forEach { $0.resume() }
        s.endWaiters = []
    }
}
