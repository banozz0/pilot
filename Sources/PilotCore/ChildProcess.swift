import Darwin
import Foundation
import Synchronization

/// Runs a CLI as a direct child with arguments, no shell: Hammerspoon's and extensions'. Every call is async and
/// off the main thread the tap runs on.
public enum ChildProcess {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let tool: String
        public let status: Int32
        public let message: String
        public var description: String { "\(tool) exited \(status): \(message)" }
    }

    /// The child was still running at its timeout and was stopped (card agent-bo-95423242).
    public struct TimedOut: Error, Equatable, CustomStringConvertible {
        public let tool: String
        public var description: String { "\(tool) timed out" }
    }

    /// The child printed more than its caller's `limit` and was stopped with every process it started.
    public struct TooLarge: Error, Equatable, CustomStringConvertible {
        public let tool: String, limit: Int
        public var description: String { "\(tool) printed more than \(limit) bytes" }
    }

    /// This process's environment with the tool's own folder, then Homebrew's, first on PATH: npm runs `env node`, and
    /// Pilot runs with launchd's short PATH.
    public static func toolEnvironment(_ cli: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath(for: cli, then: environment["PATH"])
        return environment
    }

    /// The tool's own folder, then Homebrew's, then `then` (the system's folders when nil).
    public static func searchPath(for cli: String, then path: String? = nil) -> String {
        [URL(filePath: cli).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", path ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
            .joined(separator: ":")
    }

    /// Runs to completion and returns stdout; a non-zero exit throws with stderr, or stdout when stderr is empty
    /// (some tools print their error there). Stdin is /dev/null. A child still
    /// running after `timeout` is killed and throws TimedOut, so a wedged tool never holds its caller; so is one whose task
    /// is cancelled, which throws CancellationError, not the kill's exit.
    /// `environment` replaces the child's environment when given: how a secret reaches a tool without showing in
    /// `ps`, which lists arguments (card agent-bo-95422814). `success` is the exits that return stdout: `npm outdated`
    /// exits 1 when it lists anything. `lines` hears each stdout line as it is printed, on the reading thread: Clean's
    /// progress (card agent-bo-95423002). `input` goes to stdin in place of /dev/null, then stdin closes: text `ps` must
    /// not show (Quick AI, card agent-bo-95423050). `directory` is the child's working folder: an extension's own
    /// (card agent-bo-95423242). `limit` caps stdout and stderr in bytes: past it the child is stopped with every process it
    /// started and TooLarge is thrown, so a widget's command never fills Pilot's memory (ADR 0016).
    public static func run(_ cli: String, _ arguments: [String], environment: [String: String]? = nil, input: Data? = nil,
                           directory: URL? = nil, timeout: Duration? = nil, success: Set<Int32> = [0], limit: Int? = nil,
                           lines: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await run(cli, arguments, environment: environment, input: input, directory: directory, timeout: timeout, success: success,
                      limit: limit, lines: lines, launching: nil)
    }

    /// `run`'s stdout as bytes, not text: a file `gh api` fetched, which must hash as it was sent (the extension
    /// catalogue, 2026-10-10), or a picture a helper made from `input` (pilot-text's subject, P72).
    public static func data(_ cli: String, _ arguments: [String], environment: [String: String]? = nil, input: Data? = nil,
                            timeout: Duration? = nil) async throws -> Data {
        try await output(cli, arguments, environment: environment, input: input, directory: nil, timeout: timeout, success: [0], limit: nil, lines: nil,
                         launching: nil)
    }

    /// `launching` runs on the reading thread just before the child starts: a test's hold on the cancel window.
    static func run(_ cli: String, _ arguments: [String], environment: [String: String]?, input: Data?, directory: URL? = nil, timeout: Duration?,
                    success: Set<Int32>, limit: Int? = nil, lines: (@Sendable (String) -> Void)?,
                    launching: (@Sendable () -> Void)?) async throws -> String {
        String(decoding: try await output(cli, arguments, environment: environment, input: input, directory: directory, timeout: timeout,
                                          success: success, limit: limit, lines: lines, launching: launching), as: UTF8.self)
    }

    /// What `run` and `data` share: the child's stdout as it printed it.
    private static func output(_ cli: String, _ arguments: [String], environment: [String: String]?, input: Data?, directory: URL?,
                               timeout: Duration?, success: Set<Int32>, limit: Int?, lines: (@Sendable (String) -> Void)?,
                               launching: (@Sendable () -> Void)?) async throws -> Data {
        try Task.checkCancellation()
        let child = Child()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A GCD thread, not the async pool: the reads below block for the life of the child.
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = child.process
                    let stdin = input.map { (pipe: Pipe(), data: $0) }
                    let (out, err) = child.prepare(cli, arguments, environment: environment, directory: directory,
                                                   input: stdin?.pipe ?? FileHandle.nullDevice)
                    launching?()
                    do { try child.launch() } catch { continuation.resume(throwing: error); return }
                    if let (stdin, input) = stdin {
                        // Written beside the reads, so a child that answers before reading it all never stalls on a full pipe.
                        DispatchQueue.global(qos: .userInitiated).async {
                            // A child gone before reading it must fail the write, not raise SIGPIPE, which kills Pilot.
                            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                            try? stdin.fileHandleForWriting.write(contentsOf: input)
                            try? stdin.fileHandleForWriting.close()
                        }
                    }
                    let kill = DispatchWorkItem { child.timeOut() }
                    if let timeout {
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout.inSeconds, execute: kill)
                    }
                    defer { kill.cancel() }
                    // Drain before waiting, so a large listing never fills the pipe and stalls the child.
                    let stdout = read(out.fileHandleForReading, lines: lines, limit: limit) { child.overflow() }
                    let stderr = String(decoding: read(err.fileHandleForReading, lines: nil, limit: limit) { child.overflow() }, as: UTF8.self)
                    process.waitUntilExit()
                    let tool = URL(fileURLWithPath: cli).lastPathComponent
                    if child.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else if child.overflowed, let limit { continuation.resume(throwing: TooLarge(tool: tool, limit: limit)) }
                    else if child.timedOut { continuation.resume(throwing: TimedOut(tool: tool)) }
                    else if success.contains(process.terminationStatus) { continuation.resume(returning: stdout) }
                    else { continuation.resume(throwing: Failure(tool: tool,
                                                                 status: process.terminationStatus,
                                                                 message: (stderr.isEmpty ? String(decoding: stdout, as: UTF8.self) : stderr)
                                                                    .trimmingCharacters(in: .whitespacesAndNewlines))) }
                }
            }
        } onCancel: {
            child.cancel()
        }
    }

    /// The handle's data to its end, handing each complete line, then a last unterminated one, to `lines` as it arrives.
    /// Past `limit` bytes it calls `over` once (which stops the child) and keeps only what came before.
    private static func read(_ handle: FileHandle, lines: ((String) -> Void)?, limit: Int?, over: () -> Void) -> Data {
        guard lines != nil || limit != nil else { return handle.readDataToEndOfFile() }
        var data = Data()
        let buffer = LineBuffer()
        while case let chunk = handle.availableData, !chunk.isEmpty {
            if let limit, data.count + chunk.count > limit {
                over()
                break
            }
            data.append(chunk)
            if let lines { buffer.append(chunk).forEach(lines) }
        }
        if let lines { buffer.flush().map(lines) }
        return data
    }

    /// A child that keeps running while Pilot talks to it: an extension's session (card agent-bo-95423245). It starts
    /// at once, on the caller's thread; its stdout lines reach `lines` on a reading thread, never the main one, and its
    /// exit status and the end of its stderr reach `ended` there once it is gone. Writes go out in order on their own
    /// queue, so a child that stops reading never blocks the caller, and one gone fails them rather than raising SIGPIPE.
    /// `stop` is run's cancel: the same launch and cancel lock, the whole process tree stopped.
    public final class Session: Sendable {
        private let child = Child()
        private let input = Pipe()
        private let writer = DispatchQueue(label: "dev.banozz.pilot.child-input")
        /// Whether stdin is still open.
        private let open = Mutex(true)

        public var pid: pid_t { child.process.processIdentifier }

        public init(_ cli: String, _ arguments: [String] = [], environment: [String: String]? = nil, directory: URL? = nil,
                    lines: @escaping @Sendable (String) -> Void, ended: @escaping @Sendable (Int32, String) -> Void) throws {
            let process = child.process
            let (out, err) = child.prepare(cli, arguments, environment: environment, directory: directory, input: input)
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try child.launch()
            // Drained beside stdout, so a chatty stderr never fills its pipe and stalls the child; only its end is kept.
            let stderr = Mutex(Data()), drained = DispatchGroup()
            DispatchQueue.global(qos: .utility).async(group: drained) {
                while case let chunk = err.fileHandleForReading.availableData, !chunk.isEmpty {
                    stderr.withLock { $0 = ($0 + chunk).suffix(2048) }
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                // Lines are handed on, never kept: a session may print for as long as its view is open.
                let buffer = LineBuffer()
                while case let chunk = out.fileHandleForReading.availableData, !chunk.isEmpty { buffer.append(chunk).forEach(lines) }
                buffer.flush().map(lines)
                process.waitUntilExit()
                // Its stderr ends with it, but the drain may not have run yet on a loaded Mac, so it is waited for; only a
                // process it started and left running holds stderr open past this, delaying the reason by these seconds.
                _ = drained.wait(timeout: .now() + 5)
                ended(process.terminationStatus, String(decoding: stderr.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        /// Writes `data` on the child's stdin, after whatever was sent before; nothing once stdin is closed.
        public func send(_ data: Data) {
            writer.async { [self] in
                guard open.withLock({ $0 }) else { return }
                try? input.fileHandleForWriting.write(contentsOf: data)
            }
        }

        /// Closes the child's stdin once what was sent before is written: the end of its input.
        public func closeInput() {
            writer.async { [self] in
                guard open.withLock({ was in defer { was = false }; return was }) else { return }
                try? input.fileHandleForWriting.close()
            }
        }

        /// Stops the child and every process it started.
        public func stop() { child.cancel() }
    }

    /// The process, shared with the cancellation handler. Launch and cancel take turns under one lock, so a cancel
    /// that lands before launch stops it from starting, and one that lands after terminates it (card agent-bo-95423085).
    private final class Child: @unchecked Sendable {
        let process = Process()
        private let cancelled = Mutex(false), expired = Mutex(false), overflown = Mutex(false)

        /// Sets the process up to run `cli` with `input` on its stdin; its stdout and stderr go to the pipes returned.
        func prepare(_ cli: String, _ arguments: [String], environment: [String: String]?, directory: URL?, input: Any) -> (out: Pipe, err: Pipe) {
            let out = Pipe(), err = Pipe()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = arguments
            if let environment { process.environment = environment }
            if let directory { process.currentDirectoryURL = directory }
            process.standardInput = input
            process.standardOutput = out
            process.standardError = err
            return (out, err)
        }

        func launch() throws {
            try cancelled.withLock {
                if $0 { throw CancellationError() }
                try process.run()
            }
        }

        /// Stops a child still running at its timeout, so it throws TimedOut.
        func timeOut() {
            expired.withLock {
                guard process.isRunning else { return }
                $0 = true
                stop()
            }
        }

        var timedOut: Bool { expired.withLock { $0 } }

        /// Stops a child that printed past its limit, so it throws TooLarge.
        func overflow() {
            overflown.withLock {
                guard !$0 else { return }
                $0 = true
                if process.isRunning { stop() }
            }
        }

        var overflowed: Bool { overflown.withLock { $0 } }

        var isCancelled: Bool { cancelled.withLock { $0 } }

        func cancel() {
            cancelled.withLock {
                $0 = true
                if process.isRunning { stop() }
            }
        }

        /// SIGTERM to the child and every process it started (a script's curl or sleep holds its stdout open, so the read
        /// would wait on them), then SIGKILL to any still there after half a second (Moody w-ZY8aT2-pk), the tree listed
        /// again first: a child started in that half second (a loaded Mac starts a script's children late) holds stdout too.
        /// Both go to the child's process group as well (Process makes the child its leader): a child forked after a
        /// listing, its parent then gone, is no one's descendant any more and held stdout for its whole minute (full
        /// runs, 2026-10-10, `sleep 60 & sleep 60 & wait`). One forked while the group was signalled misses that pass but
        /// stays in the group, so SIGKILL goes again until no one is left, for a second at most.
        private func stop() {
            let root = process.processIdentifier, tree = [root] + Self.descendants(of: root), leads = getpgid(root) == root
            for pid in tree { kill(pid, SIGTERM) }
            if leads { killpg(root, SIGTERM) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                for pid in tree + Self.descendants(of: root) where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                var sweeps = 0
                while leads, sweeps < 100, killpg(root, SIGKILL) == 0 {
                    sweeps += 1
                    usleep(10_000)
                }
            }
        }

        /// The processes `pid` started, their own children after them.
        private static func descendants(of pid: pid_t) -> [pid_t] {
            var buffer = [pid_t](repeating: 0, count: 256)
            let count = Int(proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size)))
            let children = buffer.prefix(max(0, min(count, buffer.count))).filter { $0 > 0 }
            return children + children.flatMap(descendants(of:))
        }
    }
}

extension Duration {
    /// The duration in seconds: a GCD deadline's offset, or a number to show.
    public var inSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
