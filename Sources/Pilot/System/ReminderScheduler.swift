import AppKit
import Observation
import OSLog
import PilotCore

private let rlog = Logger(subsystem: "dev.banozz.pilot", category: "reminders")

/// Quick reminders (card agent-bo-95422935): one timer for the next due reminder; a due one shows Pilot's tip for a
/// minute with a sound, no notification permission. One that fell due while Pilot was not running shows at start with
/// the time it was due, and so does one that fell due while the Mac slept (a run-loop timer does not count sleep, so it
/// would come late). The list is saved on every change, so a reminder outlives a restart. Observed, so the Mode lights'
/// reminders light follows the list.
@Observable @MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()

    private let store: ReminderStore
    private let now: () -> Date
    private let alert: @MainActor (String) -> Void
    private let wake: NotificationCenter
    /// Off in tests: they call fireDue themselves with a fake clock.
    private let armsTimer: Bool
    private(set) var list: ReminderList
    /// False when the file was there but did not read: nothing is saved over it (JSONFile's rule), so Sven's reminders
    /// are not lost to one bad read; this run's reminders then live in memory only.
    private let canSave: Bool
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init(store: ReminderStore = .standard, now: @escaping () -> Date = Date.init, alert: @escaping @MainActor (String) -> Void = ReminderScheduler.show,
         wake: NotificationCenter = NSWorkspace.shared.notificationCenter, armsTimer: Bool = true) {
        self.store = store
        self.now = now
        self.alert = alert
        self.wake = wake
        self.armsTimer = armsTimer
        do {
            list = try store.load()
            canSave = true
        } catch {
            rlog.error("reminders: \(store.url.path, privacy: .public) not read, so not saved over: \(String(describing: error), privacy: .public)")
            list = ReminderList()
            canSave = false
        }
    }

    /// At launch: whatever fell due meanwhile shows now, then the timer waits for the next.
    func start() {
        tick(late: true)
        guard wakeObserver == nil else { return }
        wakeObserver = wake.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(late: true) }
        }
    }

    func add(_ text: String, in seconds: TimeInterval) {
        let r = list.add(text, in: seconds, now: now())
        rlog.notice("reminder set for \(r.due.formatted(date: .omitted, time: .shortened), privacy: .public)")
        changed()
    }

    func cancel(_ id: UUID) {
        list.cancel(id)
        rlog.notice("reminder cancelled")
        changed()
    }

    /// Shows every due reminder once, together in one pop-up since a tip closes the one before; `late` adds when each
    /// was due, for one missed while Pilot was not running or the Mac slept.
    func fireDue(late: Bool = false) {
        let due = list.due(at: now())
        guard !due.isEmpty else { return }
        alert(due.map { late ? "\($0.text) (due \($0.due.formatted(date: .omitted, time: .shortened)))" : $0.text }.joined(separator: " · "))
        save()
    }

    private func tick(late: Bool) {
        fireDue(late: late)
        arm()
    }

    private func changed() {
        save()
        arm()
    }

    private func save() {
        guard canSave else { return }
        do { try store.save(list) } catch { rlog.error("reminders: not saved: \(String(describing: error), privacy: .public)") }
    }

    private func arm() {
        timer?.invalidate()
        guard armsTimer, let next = list.upcoming.first else { return }
        let t = Timer(fire: next.due, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(late: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func show(_ text: String) {
        NSSound(named: "Glass")?.play()
        HUD.tip(text, seconds: 60)
    }
}
