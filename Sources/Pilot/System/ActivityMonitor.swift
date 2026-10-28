import AppKit
import Darwin
import Observation
import OSLog
import PilotCore

/// Activity's one reader (task N3): ps and macOS's running apps, read into an Activity.Snapshot every 3 s while the
/// Activity page shows (`watch`, ended with the page's task) and once when the menu's Kill a process opens (`refresh`).
/// Both quit through `quit`. Nothing reads while neither asks; ps is about 30 ms a read, off the main thread.
@Observable @MainActor
final class ActivityMonitor {
    static let shared = ActivityMonitor()
    static let interval: Duration = .seconds(3)
    nonisolated private static let log = Logger(subsystem: "dev.banozz.pilot", category: "activity")

    private(set) var snapshot = Activity.Snapshot.empty
    /// False until the first read lands; the page says Reading… till then.
    private(set) var hasRead = false
    /// Rows asked to quit, by id, until a read no longer lists them: the page says Quitting… on them.
    private(set) var quitting: Set<String> = []
    let physicalMemory = ProcessInfo.processInfo.physicalMemory
    @ObservationIgnored private let readProcesses: @Sendable () async -> [Activity.Process]?
    @ObservationIgnored private let runningApps: @MainActor () -> [Activity.App]

    init(readProcesses: @escaping @Sendable () async -> [Activity.Process]? = { await ActivityMonitor.readProcesses() },
         runningApps: @escaping @MainActor () -> [Activity.App] = { ActivityMonitor.runningApps() }) {
        self.readProcesses = readProcesses
        self.runningApps = runningApps
    }

    #if DEBUG
    /// The renders' rows: shown as if read, nothing read from this Mac.
    func seed(_ snapshot: Activity.Snapshot, quitting: Set<String> = []) {
        self.snapshot = snapshot
        self.quitting = quitting
        hasRead = true
    }
    #endif

    /// Reads every `interval` until the calling task is cancelled: the page holds it while it shows.
    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.interval, tolerance: .milliseconds(300))
        }
    }

    /// Reads once; false when ps could not be read, the last snapshot kept.
    @discardableResult func refresh() async -> Bool {
        // The apps on the main thread, where NSWorkspace lives; ps and the grouping off it.
        let read = readProcesses, apps = runningApps()
        guard let new = await Task.detached(priority: .utility, operation: {
            await read().map { Activity.snapshot($0, apps: apps) }
        }).value else { return false }
        // Set only on a change: every assignment wakes what observes it.
        let ids = new.ids, still = quitting.filter(ids.contains)
        if still != quitting { quitting = still }
        if new != snapshot { snapshot = new }
        if !hasRead { hasRead = true }
        return true
    }

    /// Quits `row` as Activity.quit plans it: an app through macOS (it may ask to save first), anything else by a signal.
    /// False when its rights do not allow it, or it is gone or not yours.
    func quit(_ row: Activity.Row, force: Bool) -> Bool {
        guard let plan = Activity.quit(row, force: force) else { return false }
        let sent = switch plan {
        case .app(let pid, let force): NSRunningApplication(processIdentifier: pid).map { force ? $0.forceTerminate() : $0.terminate() } ?? false
        case .signal(let pid, let signal): KillProcess.send(signal, to: pid)
        }
        Self.log.notice("quit \(row.name, privacy: .public) pid \(row.pid)\(force ? " forced" : "", privacy: .public): \(sent ? "sent" : "refused", privacy: .public)")
        guard sent else { return false }
        quitting.insert(row.id)
        // Read again soon, so a quit row goes without waiting for the page's next tick.
        Task { try? await Task.sleep(for: .seconds(1)); await refresh() }
        return true
    }

    /// Every process from ps; memory as Activity Monitor counts it (the footprint) for your own, the ones macOS lets
    /// Pilot read, else ps's resident size.
    nonisolated static func readProcesses() async -> [Activity.Process]? {
        guard let ps = try? await ChildProcess.run("/bin/ps", Activity.psArguments, timeout: .seconds(3)) else { return nil }
        return Activity.footprinted(Activity.parse(ps)) { pid in
            var info = rusage_info_v0()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
            }
            return ok == 0 ? info.ri_phys_footprint : nil
        }
    }

    /// The apps with a Dock icon, as macOS runs them.
    static func runningApps() -> [Activity.App] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
            Activity.App(pid: $0.processIdentifier, name: $0.localizedName ?? $0.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                         bundlePath: $0.bundleURL?.path)
        }
    }
}
