import Darwin
import Foundation
import OSLog
import Synchronization

private let checksLog = Logger(subsystem: "dev.banozz.pilot", category: "checks")

/// Pilot's checks inside the app (setup-overhaul T40; they ship in every copy, Sven Q24): a main thread that stops
/// answering and a memory footprint that spikes, each kept with its time for `pilot status --part problems` and logged.
/// No crash SDK (Q315): nothing here reads another thread's stack, stops the app or ends it.
///
/// The main run loop's steps go to two observers that only swap one atomic stamp: the first of every callout when it
/// wakes or takes a source, the last of every callout before it sleeps, so layout, drawing and the Core Animation commit
/// (beforeWaiting callouts too) count as busy. A gap of `stallSeconds` between two steps while it was not waiting for
/// work is a stall, kept once it ends. A utility-queue timer, never the main thread,
/// logs a stall still going (so one that ends in a force quit is in the log) and reads the footprint. Times are uptime,
/// which stops while the Mac sleeps, so a closed lid is never a stall.
public final class Diagnostics: Sendable {
    public static let shared = Diagnostics()

    /// What a check found, with when it began.
    public struct Finding: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case stall, memory

            /// What `amount` counts, as `pilot status` names it.
            public var unit: String { self == .stall ? "seconds" : "megabytes" }
        }

        public let kind: Kind
        public let time: Date
        /// A stall's length in seconds; a spike's highest footprint in MB while it lasted.
        public var amount: Double

        public init(kind: Kind, time: Date, amount: Double) {
            self.kind = kind
            self.time = time
            self.amount = amount
        }

        public var title: String {
            switch kind {
            case .stall: "Pilot stopped answering for \(String(format: "%.1f", amount)) s"
            case .memory: "Pilot's memory reached \(SystemStats.memorySize(UInt64(amount * 1_048_576)))"
            }
        }

        public var detail: String {
            switch kind {
            case .stall: "Its main thread was busy, so keys, menus and windows waited"
            case .memory: "Over the \(SystemStats.memorySize(UInt64(Diagnostics.memoryLimitMB) << 20)) line Pilot's checks watch"
            }
        }
    }

    /// Two seconds: well past Apple's 250 ms hang line, and the length a person notices keys gone dead.
    public static let stallSeconds = 2.0
    /// About five times one reading of Pilot's footprint in use (212 MB, 2026-11-28) and over twenty times its idle budget.
    public static let memoryLimitMB = 1024.0
    /// A spike ends once the footprint is back under this share of the line, so one spike is one finding.
    static let rearmShare = 0.75
    /// The most findings kept; older ones drop.
    static let kept = 20
    /// The background check's period: a stall still going is logged and the footprint read this often.
    static let tickSeconds = 5

    /// The main run loop's last step, in uptime nanoseconds, with the low bit set while it waits for work. Only the main
    /// thread writes it, so a step never takes a lock; it starts waiting.
    private let beat = Atomic<UInt64>(1)

    private struct State {
        /// The beat a stall still going was logged at, so the timer logs it once.
        var loggedStallAt: UInt64 = 0
        /// The time of the spike over the line and not yet back under its re-arm share; its finding is matched on it, so
        /// one evicted by newer findings is never mistaken for an older spike.
        var openSpike: Date?
        var findings: [Finding] = []
        var started = false
    }

    private let state = Mutex(State())
    private let footprint: @Sendable () -> Double?

    /// `footprint` reads this process's footprint in MB; the tests hand in their own.
    public init(footprint: @escaping @Sendable () -> Double? = Diagnostics.footprintMB) {
        self.footprint = footprint
    }

    /// The findings this run, oldest first.
    public var findings: [Finding] { state.withLock { $0.findings } }

    /// Starts both checks once; later calls do nothing. Safe from any thread.
    public func start() {
        let first = state.withLock { s in
            defer { s.started = true }
            return !s.started
        }
        guard first else { return }
        // Observers run in increasing order within a stage. Before sources stamps a loop that never sleeps, after waiting
        // the end of a sleep, each ahead of every other callout; before waiting starts the sleep only after every other
        // callout of that stage, the Core Animation commit (order 2000000) and the autorelease pool's drain among them.
        let busy = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.beforeSources, .afterWaiting]).rawValue, true, .min) { [self] _, _ in
            step(waiting: false, nanos: Self.uptime())
        }
        let waits = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, .max) { [self] _, _ in
            step(waiting: true, nanos: Self.uptime())
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), busy, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), waits, .commonModes)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(Self.tickSeconds), repeating: .seconds(Self.tickSeconds), leeway: .seconds(1))
        timer.setEventHandler { [self] in tick(nanos: Self.uptime()) }
        timer.resume()
        // All three live as long as the process: the observers in the main run loop, the timer by this retain.
        _ = Unmanaged.passRetained(timer)
    }

    /// A step of the main run loop at `nanos`: `waiting` when it is about to sleep for work. On the main thread, so it only
    /// swaps the beat; a stall it ends is kept and logged.
    func step(waiting: Bool, nanos: UInt64, date: @autoclosure () -> Date = .now) {
        let last = beat.exchange(nanos & ~1 | (waiting ? 1 : 0), ordering: .acquiringAndReleasing)
        guard let seconds = Self.stalled(last, at: nanos) else { return }
        let finding = Finding(kind: .stall, time: date().addingTimeInterval(-seconds), amount: seconds)
        state.withLock { Self.keep(finding, in: &$0) }
        checksLog.error("stall: main thread did not answer for \(seconds, format: .fixed(precision: 1)) s")
    }

    /// The background check at `nanos`: logs a stall still going, once, and reads the footprint.
    func tick(nanos: UInt64, date: @autoclosure () -> Date = .now) {
        let last = beat.load(ordering: .acquiring)
        if let going = Self.stalled(last, at: nanos), state.withLock({ s in defer { s.loggedStallAt = last }; return s.loggedStallAt != last }) {
            checksLog.fault("stall: main thread has not answered for \(going, format: .fixed(precision: 1)) s and counting")
        }
        guard let mb = footprint() else { return }
        let spike: Finding? = state.withLock { s in
            if let open = s.openSpike {
                if mb < Self.memoryLimitMB * Self.rearmShare { s.openSpike = nil }
                else if let at = s.findings.lastIndex(where: { $0.kind == .memory && $0.time == open }) { s.findings[at].amount = max(s.findings[at].amount, mb) }
                return nil
            }
            guard mb >= Self.memoryLimitMB else { return nil }
            let finding = Finding(kind: .memory, time: date(), amount: mb)
            Self.keep(finding, in: &s)
            s.openSpike = finding.time
            return finding
        }
        if let spike { checksLog.error("memory: footprint reached \(spike.amount, format: .fixed(precision: 0)) MB") }
    }

    /// The seconds the main run loop has been busy since `beat` at `nanos`, once that reaches the line; nil while it waits.
    private static func stalled(_ beat: UInt64, at nanos: UInt64) -> Double? {
        guard beat & 1 == 0, nanos > beat else { return nil }
        let seconds = Double(nanos - beat) / 1e9
        return seconds >= stallSeconds ? seconds : nil
    }

    private static func keep(_ finding: Finding, in s: inout State) {
        s.findings.append(finding)
        if s.findings.count > kept { s.findings.removeFirst(s.findings.count - kept) }
    }

    /// Uptime that stops while the Mac sleeps.
    private static func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// This process's footprint in MB, as Activity Monitor's Memory column counts it; nil when the kernel does not say.
    public static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }
}
