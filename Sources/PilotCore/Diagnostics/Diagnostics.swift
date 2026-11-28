import Darwin
import Foundation
import OSLog
import Synchronization

private let checksLog = Logger(subsystem: "dev.banozz.pilot", category: "checks")

/// Pilot's checks inside the app (setup-overhaul T40; they ship in every copy, Sven Q24): a main thread that stops
/// answering and a memory footprint that spikes, each kept with its time for `pilot status --part problems` and logged.
/// No crash SDK (Q315): nothing here reads another thread's stack, stops the app or ends it.
///
/// The main run loop reports each of its steps to an observer that only stamps the time; a gap of `stallSeconds` between
/// two steps while it was not waiting for work is a stall, kept once it ends. A utility-queue timer, never the main
/// thread, logs a stall still going (so one that ends in a force quit is in the log) and reads the footprint. Times
/// are uptime, which stops while the Mac sleeps, so a closed lid is never a stall.
public final class Diagnostics: Sendable {
    public static let shared = Diagnostics()

    /// What a check found, with when it began.
    public struct Finding: Sendable, Equatable {
        public enum Kind: String, Sendable { case stall, memory }
        public let kind: Kind
        public let time: Date
        /// A stall's length; a spike's highest footprint, in MB, while it lasted.
        public var amount: Double

        public init(kind: Kind, time: Date, amount: Double) {
            self.kind = kind
            self.time = time
            self.amount = amount
        }

        public var title: String {
            switch kind {
            case .stall: "Pilot stopped answering for \(amount.formatted(.number.precision(.fractionLength(1)))) s"
            case .memory: "Pilot's memory reached \(Int(amount.rounded())) MB"
            }
        }

        public var detail: String {
            switch kind {
            case .stall: "Its main thread was busy, so keys, menus and windows waited"
            case .memory: "Over the \(Int(Diagnostics.memoryLimitMB)) MB line Pilot's checks watch"
            }
        }
    }

    /// Two seconds: well past Apple's 250 ms hang line, and the length a person notices keys gone dead.
    public static let stallSeconds = 2.0
    /// About five times Pilot's footprint after a day's use (212 MB, 2026-11-28) and over twenty times its idle budget.
    public static let memoryLimitMB = 1024.0
    /// A spike ends once the footprint is back under this share of the line, so one spike is one finding.
    static let rearmShare = 0.75
    /// The most findings kept; older ones drop.
    static let kept = 20
    /// The background check's period: a stall still going is logged and the footprint read this often.
    static let tickSeconds = 5

    private struct State {
        var lastStep: Double?
        var waiting = true
        var loggedStallFrom: Double?
        /// The start of the spike still over the line, until the footprint is back under its re-arm share.
        var spike: Date?
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
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { [self] _, activity in
            step(waiting: activity == .beforeWaiting, uptime: ProcessInfo.processInfo.systemUptime, date: .now)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(Self.tickSeconds), repeating: .seconds(Self.tickSeconds), leeway: .seconds(1))
        timer.setEventHandler { [self] in tick(uptime: ProcessInfo.processInfo.systemUptime, date: .now) }
        timer.resume()
        // Both live as long as the process: the observer in the main run loop, the timer by its own retain while resumed.
        _ = Unmanaged.passRetained(timer)
    }

    /// A step of the main run loop at `uptime`: `waiting` when it is about to sleep for work. Runs on the main thread, so it
    /// only compares two times; a stall it ends is kept and logged.
    func step(waiting: Bool, uptime: Double, date: Date) {
        let stall: Finding? = state.withLock { s in
            defer { s.lastStep = uptime; s.waiting = waiting; s.loggedStallFrom = nil }
            guard let last = s.lastStep, !s.waiting, uptime - last >= Self.stallSeconds else { return nil }
            let finding = Finding(kind: .stall, time: date.addingTimeInterval(last - uptime), amount: uptime - last)
            Self.keep(finding, in: &s)
            return finding
        }
        if let stall { checksLog.error("stall: main thread did not answer for \(stall.amount, format: .fixed(precision: 1)) s") }
    }

    /// The background check at `uptime`: logs a stall still going, once, and reads the footprint.
    func tick(uptime: Double, date: Date) {
        let going: Double? = state.withLock { s in
            guard let last = s.lastStep, !s.waiting, uptime - last >= Self.stallSeconds, s.loggedStallFrom != last else { return nil }
            s.loggedStallFrom = last
            return uptime - last
        }
        if let going { checksLog.fault("stall: main thread has not answered for \(going, format: .fixed(precision: 1)) s and counting") }
        guard let mb = footprint() else { return }
        let spike: Finding? = state.withLock { s in
            if let open = s.spike {
                if mb < Self.memoryLimitMB * Self.rearmShare { s.spike = nil; return nil }
                if let at = s.findings.lastIndex(where: { $0.kind == .memory && $0.time == open }) { s.findings[at].amount = max(s.findings[at].amount, mb) }
                return nil
            }
            guard mb >= Self.memoryLimitMB else { return nil }
            let finding = Finding(kind: .memory, time: date, amount: mb)
            Self.keep(finding, in: &s)
            s.spike = date
            return finding
        }
        if let spike { checksLog.error("memory: footprint reached \(spike.amount, format: .fixed(precision: 0)) MB") }
    }

    private static func keep(_ finding: Finding, in s: inout State) {
        s.findings.append(finding)
        if s.findings.count > kept { s.findings.removeFirst(s.findings.count - kept) }
    }

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
