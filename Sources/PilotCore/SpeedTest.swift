import Darwin
import Foundation
import Observation

/// Test internet speed (card agent-bo-95422772; Vicinae's Speedtest, rebuilt): macOS's own networkQuality, built in,
/// no account, about 20 seconds. One run at a time. Since P41 (Sven, Q292) the menu shows the run as it measures, read
/// from networkQuality's own progress line, and keeps the last 30 results; a run the menu is not showing says it started
/// and then what it measured in Pilot's alert.
@MainActor @Observable
public final class SpeedTest {
    /// Download and upload in Mbit/s, responsiveness in round trips a minute (0 until networkQuality has one).
    public struct Reading: Codable, Equatable, Sendable {
        public var download: Double, upload: Double, responsiveness: Double
        public init(download: Double, upload: Double, responsiveness: Double) {
            self.download = download; self.upload = upload; self.responsiveness = responsiveness
        }
    }

    /// One finished run, as the history keeps it.
    public struct Result: Codable, Equatable, Sendable {
        public var reading: Reading
        public var at: Date
        /// How long networkQuality measured; nil when its JSON has no dates.
        public var seconds: Double?
        /// The interface it measured on ("en0").
        public var interface: String?
        public init(reading: Reading, at: Date, seconds: Double? = nil, interface: String? = nil) {
            self.reading = reading; self.at = at; self.seconds = seconds; self.interface = interface
        }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Since when; the numbers so far are `live`.
        case running(since: Date)
        case done(Result)
        case failed
        case stopped
    }

    /// networkQuality's run: it hears each progress reading and returns the JSON of `-c`.
    public typealias Measure = @MainActor (_ live: @escaping @MainActor (Reading) -> Void) async throws -> String

    @ObservationIgnored private let measure: Measure
    @ObservationIgnored private let say: @MainActor (String) -> Void
    @ObservationIgnored private let history: DayFile<[Result]>?
    @ObservationIgnored private let clock: () -> Date
    /// This one's run, and the run going now whichever SpeedTest started it, each ending on its line: `pilot speedtest`
    /// starts the key's own run and waits on it.
    @ObservationIgnored public private(set) var run: Task<String, Never>?
    @ObservationIgnored public private(set) static var current: Task<String, Never>?

    public private(set) var phase = Phase.idle
    /// networkQuality's latest progress line while it runs, nil before its first: apart from `phase`, so its five updates
    /// a second redraw the gauges alone, never the panel's size, line or foot.
    public private(set) var live: Reading?
    /// The last results, oldest first, at most `kept`.
    public private(set) var runs: [Result] = []
    /// The menu shows the run: no alert says it started or what it measured.
    @ObservationIgnored public var shown = false
    public static let kept = 30

    public var running: Bool { run != nil }

    /// A test's speed test: `measure` returns the JSON with no progress, and no history is kept.
    public convenience init(measure: @escaping @MainActor () async throws -> String, say: @escaping @MainActor (String) -> Void) {
        self.init(live: { _ in try await measure() }, history: nil, say: say)
    }

    public init(live measure: @escaping Measure = { try await SpeedTest.networkQuality(live: $0) },
                history: DayFile<[Result]>? = nil, clock: @escaping () -> Date = { Date() },
                say: @escaping @MainActor (String) -> Void) {
        self.measure = measure
        self.history = history
        self.clock = clock
        self.say = say
        runs = (try? history?.load(or: [])) ?? []
    }

    /// Starts a run, which ends on its line; nil while one is running.
    @discardableResult
    public func start() -> Task<String, Never>? {
        guard self.run == nil else { return nil }
        if !shown { say("Testing internet speed…") }
        phase = .running(since: clock())
        live = nil
        let run = Task {
            let out = try? await measure { reading in
                if case .running = self.phase, self.live != reading { self.live = reading }
            }
            let result = out.flatMap { Self.result($0, at: self.clock()) }
            let line: String
            if Task.isCancelled {
                (phase, line) = (.stopped, Self.stoppedLine)
            } else if let result {
                (phase, line) = (.done(result), Self.line(result.reading))
                keep(result)
            } else {
                (phase, line) = (.failed, Self.failed)
            }
            if !shown { say(line) }
            self.run = nil
            Self.current = nil
            return line
        }
        self.run = run
        Self.current = run
        return run
    }

    /// Stops the run going now (the menu's ⌘.): networkQuality is terminated and the run ends stopped.
    public func stop() { run?.cancel() }

    /// Back to idle once the menu leaves a finished run, so the next open starts afresh; a run going on is left alone.
    public func dismiss() {
        shown = false
        if run == nil { phase = .idle }
    }

    private func keep(_ result: Result) {
        runs = Array((runs + [result]).suffix(Self.kept))
        do { try history?.save(runs) } catch { say("Pilot could not keep the speed test's result: \(error.localizedDescription)") }
    }

    public static let failed = "The speed test could not run; check the connection"
    public static let stoppedLine = "The speed test was stopped"

    /// The one line the alert, `pilot speedtest` and the menu's Copy result say.
    public static func line(_ r: Reading) -> String {
        "Download \(Int(r.download)) Mbit/s · Upload \(Int(r.upload)) Mbit/s · Responsiveness \(Int(r.responsiveness.rounded())) RPM"
    }

    /// networkQuality -c's JSON as one line: download and upload in Mbit/s, responsiveness in round trips per minute;
    /// nil without both throughputs and the responsiveness.
    public static func summary(_ json: String) -> String? { result(json, at: Date()).map { line($0.reading) } }

    /// networkQuality -c's JSON as a result measured at `at`; nil without both throughputs and the responsiveness.
    public static func result(_ json: String, at: Date) -> Result? {
        struct Raw: Decodable {
            var dl_throughput: Double, ul_throughput: Double, responsiveness: Double
            var start_date: String?, end_date: String?, interface_name: String?
        }
        guard let r = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else { return nil }
        var seconds: Double?
        if let start = r.start_date.flatMap(dates.date), let end = r.end_date.flatMap(dates.date) { seconds = end.timeIntervalSince(start) }
        return Result(reading: Reading(download: r.dl_throughput / 1_000_000, upload: r.ul_throughput / 1_000_000, responsiveness: r.responsiveness),
                      at: at, seconds: seconds, interface: r.interface_name)
    }

    /// networkQuality's JSON dates, "2026-10-18 14:46:20.722".
    private static let dates = {
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return dates
    }()

    /// One of networkQuality's progress lines, "Downlink: 834.886 Mbps, 384 RPM - Uplink: 61.657 Mbps, 384 RPM"; nil for
    /// anything else (the summary, a blank).
    public nonisolated static func reading(_ line: String) -> Reading? {
        guard let m = line.firstMatch(of: /Downlink: ([\d.]+) Mbps, ([\d.]+) RPM - Uplink: ([\d.]+) Mbps/),
              let down = Double(m.1), let rpm = Double(m.2), let up = Double(m.3) else { return nil }
        return Reading(download: down, upload: up, responsiveness: rpm)
    }

    /// Runs networkQuality with its output on a pseudo-terminal, the only place it writes its progress (about every
    /// 200 ms; piped, it prints the result alone, 2026-10-18 on macOS 27.0.1), and its JSON in a file: `-c<path>` as one
    /// argument, since `-c <path>` takes no path. Stopped after 120 s, or when the task is cancelled.
    public nonisolated static func networkQuality(live: @escaping @MainActor (Reading) -> Void) async throws -> String {
        let json = FileManager.default.temporaryDirectory.appending(path: "pilot-speedtest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: json) }
        var fds: (master: Int32, slave: Int32) = (-1, -1)
        guard openpty(&fds.master, &fds.slave, nil, nil, nil) == 0 else { throw POSIXError(.ENXIO) }
        let (master, slave) = fds
        let tty = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/networkQuality")
        process.arguments = ["-c" + json.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = tty
        process.standardError = tty
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { close(master); throw error }
        // The child holds the terminal now: the master reads to its end once the child is gone.
        try? tty.close()
        nonisolated(unsafe) let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: stop)
        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { done in
                // A GCD thread, not the async pool: the reads block for the life of the child.
                DispatchQueue.global(qos: .userInitiated).async {
                    var pending = "", buffer = [UInt8](repeating: 0, count: 4096)
                    while case let n = Darwin.read(master, &buffer, buffer.count), n > 0 {
                        pending += String(decoding: buffer[..<n], as: UTF8.self)
                        // Each update rewrites the line: "\r\e[2K\rDownlink: …". The last piece may be half a line.
                        var pieces = pending.split(omittingEmptySubsequences: false) { $0 == "\r" || $0 == "\n" }.map(String.init)
                        pending = pieces.removeLast()
                        if let reading = pieces.reversed().lazy.compactMap(reading).first { Task { @MainActor in live(reading) } }
                    }
                    close(master)
                    ended.wait()
                    done.resume(returning: process.terminationStatus)
                }
            }
        } onCancel: {
            stop.perform()
        }
        stop.cancel()
        try Task.checkCancellation()
        guard status == 0 else { throw ChildProcess.Failure(tool: "networkQuality", status: status, message: "") }
        return try String(contentsOf: json, encoding: .utf8)
    }
}
