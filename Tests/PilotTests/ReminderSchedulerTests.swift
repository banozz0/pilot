import AppKit
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95422935: the scheduler on a fake clock, a temp file and a recording alert; no timer, no tip, no sound.
@MainActor
@Suite("Reminder scheduler")
struct ReminderSchedulerTests {
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    final class Clock { var now = ReminderSchedulerTests.t0 }

    /// A file of its own per test, removed by the caller's defer.
    func tempURL() -> URL { FileManager.default.temporaryDirectory.appending(path: "pilot-reminders-\(UUID().uuidString).json") }

    func make(_ url: URL, _ clock: Clock, wake: NotificationCenter = NotificationCenter(), _ shown: @escaping @MainActor (String) -> Void) -> ReminderScheduler {
        ReminderScheduler(store: ReminderStore(url: url), now: { clock.now }, alert: shown, wake: wake, armsTimer: false)
    }

    @Test("A due reminder shows once, a cancelled one never, and both changes are saved")
    func fires() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = Clock()
        var shown: [String] = []
        let s = make(url, clock) { shown.append($0) }
        s.add("stretch", in: 60)
        s.add("tea", in: 120)
        guard let tea = s.list.upcoming.last else { Issue.record("tea was not added"); return }
        s.cancel(tea.id)
        clock.now = Self.t0.addingTimeInterval(61)
        s.fireDue()
        s.fireDue()
        clock.now = Self.t0.addingTimeInterval(500)
        s.fireDue()
        #expect(shown == ["stretch"])
        #expect((try? ReminderStore(url: url).load().upcoming.isEmpty) == true)
    }

    @Test("One that fell due while Pilot was off shows at start with the time it was due")
    func missed() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var list = ReminderList()
        let r = list.add("call mum", in: 60, now: Self.t0)
        try ReminderStore(url: url).save(list)
        let clock = Clock()
        clock.now = Self.t0.addingTimeInterval(3600)
        var shown: [String] = []
        make(url, clock) { shown.append($0) }.start()
        #expect(shown == ["call mum (due \(r.due.formatted(date: .omitted, time: .shortened)))"])
    }

    @Test("One that fell due while the Mac slept shows at wake with the time it was due")
    func wake() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = Clock(), wake = NotificationCenter()
        var shown: [String] = []
        let s = make(url, clock, wake: wake) { shown.append($0) }
        s.start()
        s.add("stretch", in: 60)
        guard let due = s.list.upcoming.first?.due else { Issue.record("stretch was not added"); return }
        clock.now = Self.t0.addingTimeInterval(1800)
        wake.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(shown == ["stretch (due \(due.formatted(date: .omitted, time: .shortened)))"])
    }

    @Test("Several due at once show together in one pop-up, since a tip closes the one before")
    func together() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = Clock()
        var shown: [String] = []
        let s = make(url, clock) { shown.append($0) }
        s.add("stretch", in: 60)
        s.add("tea", in: 90)
        clock.now = Self.t0.addingTimeInterval(120)
        s.fireDue()
        #expect(shown == ["stretch · tea"])
    }

    @Test("A reminders file that does not read is never overwritten")
    func unreadable() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let s = make(url, Clock()) { _ in }
        s.add("stretch", in: 60)
        #expect(try Data(contentsOf: url) == Data("not json".utf8))
    }
}
