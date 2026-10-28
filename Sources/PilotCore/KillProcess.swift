import Darwin
import Foundation

/// Kill a process (card agent-bo-95422771; Vicinae's Kill process, rebuilt): what to signal and how. Its list is
/// Activity's (task N3), apps with their helpers first; a pick quits, a second pick of the same one forces it. The ps
/// row stays for This Mac's busiest lists (SystemStats.busiest).
public enum KillProcess {
    public struct Row: Equatable, Sendable {
        public var pid: Int32, cpu: Double, memoryKB: Int, name: String
        public init(pid: Int32, cpu: Double, memoryKB: Int, name: String) {
            self.pid = pid; self.cpu = cpu; self.memoryKB = memoryKB; self.name = name
        }
        /// Activity's listing of the process, its memory in KB.
        public init(_ p: Activity.Process) { self.init(pid: p.pid, cpu: p.cpu, memoryKB: Int(p.memory / 1024), name: p.name) }
    }

    /// Every line of a `pid=,%cpu=,rss=,comm=` listing, unfiltered; the name is the program's, without its path, and
    /// may hold spaces. The tests' listings; This Mac's busiest lists now read Activity's (Activity.parse).
    public static func parse(_ ps: String) -> [Row] {
        ps.split(separator: "\n").compactMap { line -> Row? in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), let cpu = Double(f[1]), let rss = Int(f[2]) else { return nil }
            return Row(pid: pid, cpu: cpu, memoryKB: rss, name: String(f[3].split(separator: "/").last ?? f[3]))
        }
    }

    /// Which signal a pick sends: SIGTERM asks politely; the same pid picked again within 30 s gets SIGKILL.
    public struct Kills: Sendable {
        private var asked: [Int32: Date] = [:]

        public init() {}

        public mutating func signal(for pid: Int32, now: Date) -> Int32 {
            let last = asked[pid]
            asked = asked.filter { now.timeIntervalSince($1) <= 30 }
            asked[pid] = now
            guard let last, now.timeIntervalSince(last) <= 30 else { return SIGTERM }
            return SIGKILL
        }
    }

    /// False when the process is gone or not Sven's to signal. Pids 0, 1 and below never reach kill(2): 0 and -1 would
    /// signal his whole session, 1 is launchd.
    public static func send(_ signal: Int32, to pid: Int32) -> Bool { pid > 1 && kill(pid, signal) == 0 }
}
