import AppKit
import Carbon.HIToolbox
import IOKit
import Observation
import PilotCore

/// Password fields turn on secure input and the tap sees nothing. Pilot shows it, never works around it.
/// Polled every second: the layer key itself never reaches the tap in that state, so "while held" is too late.
@Observable @MainActor
final class SecureInputMonitor: ScreenPausing {
    /// The process macOS says turned secure input on, and its name: read only when secure input comes on or the
    /// screen unlocks, nil when macOS names none.
    typealias Owner = (pid: pid_t, name: String?)
    private let isEnabled: () -> Bool
    private let owner: () -> Owner?
    private let isAlive: (pid_t) -> Bool
    private let now: () -> Date
    private(set) var isActive: Bool
    /// Who holds it while it is on, nil while it is off.
    private(set) var holder: SecureInputHolder?
    @ObservationIgnored private var ownerPID: pid_t?
    @ObservationIgnored private var ownerName: String?
    private(set) var timer: Timer?
    private var paused = false
    /// Secure input just came on (Sven, 2026-10-08: Bitwarden's unlock field made Pilot seem dead): the tip that says
    /// so, once an app an hour, never for Pilot's own field or the lock screen.
    @ObservationIgnored var onTip: ((String) -> Void)?
    @ObservationIgnored private var tipped: [String: Date] = [:]
    /// Secure input came on or off: the tap is blind while it is on, so a Hyper release may be lost.
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    nonisolated static let pilot = "Pilot"
    /// How late the once-a-second poll may fire.
    nonisolated static let tolerance: TimeInterval = 0.2

    init(isEnabled: @escaping () -> Bool = IsSecureEventInputEnabled, owner: @escaping () -> Owner? = SecureInputMonitor.owner,
         isAlive: @escaping (pid_t) -> Bool = SecureInputMonitor.isAlive, now: @escaping () -> Date = Date.init) {
        self.isEnabled = isEnabled
        self.owner = owner
        self.isAlive = isAlive
        self.now = now
        isActive = isEnabled()
        if isActive { readOwner() }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // A fifth of a second late at most, so macOS fires it with Pilot's other wake-ups rather than on its own.
        timer.tolerance = Self.tolerance
        // Common modes: a default-mode timer stops while a menu is open (Pilot's dropdown, any app's menu-bar
        // menu) or a modal panel runs, and the icon shows a stale state until it closes.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Locked or asleep (card agent-bo-95422839): no polling until `resume`, which looks at once.
    func pause() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        paused = true
    }

    func resume() {
        guard paused else { return }
        paused = false
        // Unlocking moves macOS's owner to the login window (2026-10-21), so read it again.
        if isActive, isEnabled() { readOwner() }
        refresh()
        start()
    }

    func refresh() {
        let on = isEnabled()
        guard on != isActive else {
            // One kill(pid, 0) a tick: the app that turned it on quitting while it stays on is a leaked lock.
            if on, case .app(let name) = holder, let ownerPID, !isAlive(ownerPID) { holder = .quit(name) }
            return
        }
        isActive = on
        if on { readOwner() } else { holder = nil; ownerPID = nil; ownerName = nil }
        onChange?(on)
        if on { tip() }
    }

    private func readOwner() {
        let found = owner()
        ownerPID = found?.pid
        ownerName = found?.name
        // The login window, its screen unlocked, only turned it on last; the app holding it now is unknown.
        guard let found, found.name != "loginwindow" else { holder = .unknown; return }
        holder = !isAlive(found.pid) ? .quit(found.name) : found.name.map { .app($0) } ?? .unknown
    }

    private func tip() {
        // Pilot's own field, and the lock screen's while it lets go.
        guard ownerName != Self.pilot, ownerName != "loginwindow" else { return }
        let app: String? = if case .app(let name) = holder { name } else { nil }
        let at = now()
        if let last = tipped[app ?? ""], at.timeIntervalSince(last) < 3600 { return }
        tipped[app ?? ""] = at
        onTip?(app.map { "A password field in \($0) has the keyboard, so Hyper waits" } ?? "A password field has the keyboard, so Hyper waits")
    }

    /// The process that last turned secure input on: kCGSSessionSecureInputPID on this user's IOConsoleUsers entry, the
    /// record `ioreg` shows. CGSessionCopyCurrentDictionary's key of that name follows the front app instead (2026-10-21).
    nonisolated static func owner() -> Owner? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]],
              let mine = users.first(where: { ($0["kCGSSessionUserIDKey"] as? Int).map(uid_t.init) == getuid() }),
              let pid = (mine["kCGSSessionSecureInputPID"] as? Int).map(pid_t.init), pid > 0 else { return nil }
        if pid == ProcessInfo.processInfo.processIdentifier { return (pid, pilot) }
        return (pid, NSRunningApplication(processIdentifier: pid)?.localizedName ?? processName(pid))
    }

    /// A process's name when it is no app (loginwindow), nil once it is gone.
    nonisolated static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// EPERM: alive, just another user's.
    nonisolated static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    #if DEBUG
    /// The renders draw the every-day dropdown whatever another app's password field is doing.
    func seed(active: Bool) {
        timer?.invalidate()
        timer = nil
        isActive = active
        holder = active ? .unknown : nil
    }
    #endif
}
