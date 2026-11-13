import AppKit
import Observation
import os
import PilotCore
import UserNotifications

private let nudgeLog = Logger(subsystem: "dev.banozz.pilot", category: "smart-nudges")

/// Smart nudges (spec smart-nudges): Notifications › Smart nudges' three switches, all off by default, and the one funnel
/// Pilot's own alerts go through (`post`), which quiet hours hold. While every switch is off nothing here runs: no
/// Calendar store, no timer. Pause music reads Calendar the clock's way (CalendarStore), asked only as its switch goes on,
/// and sleeps until the next event's lead, not polling; the AI limit warning reads the AI usage extension's bar answer as
/// ExtensionBar receives it, so it hears nothing while that item is on no bar. Note reminders and quick reminders are
/// times Sven set himself, so they arrive in quiet hours too (spec smart-nudges).
@Observable @MainActor
final class SmartNudgeCenter {
    static let shared = SmartNudgeCenter()
    static let pauseKey = "smartNudges.pauseMusic", minutesKey = "smartNudges.pauseMusic.minutes", anyKey = "smartNudges.pauseMusic.anyEvent"
    static let aiKey = "smartNudges.aiLimit", thresholdKey = "smartNudges.aiLimit.threshold"
    static let quietKey = "smartNudges.quietHours", fromKey = "smartNudges.quietHours.from", toKey = "smartNudges.quietHours.to"
    /// What they remember across launches: the AI windows warned about, the notifications held, the meetings paused for.
    static let warnedKey = "smartNudges.state.warned", heldKey = "smartNudges.state.held", pausedKey = "smartNudges.state.paused"

    /// One of Pilot's own alerts: a tip (its body unless it has its own), with a sound when asked, and a notification
    /// unless it is a tip only.
    struct Post: Equatable {
        let id: String, title: String, body: String
        var tip: String?, sound = false, notifies = true
    }

    var pauseMusic: Bool {
        didSet {
            defaults.set(pauseMusic, forKey: Self.pauseKey)
            followCalendar(asking: pauseMusic)
        }
    }
    var minutes: Int { didSet { defaults.set(minutes, forKey: Self.minutesKey); wake() } }
    var anyEvent: Bool { didSet { defaults.set(anyEvent, forKey: Self.anyKey); wake() } }
    var aiLimit: Bool { didSet { defaults.set(aiLimit, forKey: Self.aiKey) } }
    var threshold: Int { didSet { defaults.set(threshold, forKey: Self.thresholdKey) } }
    var quietHours: Bool {
        didSet {
            defaults.set(quietHours, forKey: Self.quietKey)
            followQuiet()
        }
    }
    var quietFrom: String { didSet { defaults.set(quietFrom, forKey: Self.fromKey); followQuiet() } }
    var quietTo: String { didSet { defaults.set(quietTo, forKey: Self.toKey); followQuiet() } }
    /// Calendar access as Pause music last read it, once off the main thread; nil until its watch first ran. Refused,
    /// the row says so and links Privacy & Security.
    private(set) var calendarAccess: CalendarAccess?
    /// The notifications held in quiet hours, released as one summary as they end.
    private(set) var held: [HeldNudge] = []

    /// The seams: Calendar, what plays, where a post goes, and AI usage's last bar answer. The app's are real; the
    /// sandbox's are files.
    @ObservationIgnored var makeCalendar: @MainActor () -> CalendarStore = { EventKitCalendar() }
    @ObservationIgnored var media: MediaControlling = BundledMediaControl()
    @ObservationIgnored var deliver: @MainActor (Post) -> Void = SmartNudgeCenter.show
    @ObservationIgnored var lastAIAnswer: @MainActor () -> Extension.BarAnswer? = {
        ExtensionBar.shared.items.first { $0.id == AILimit.extensionID }?.answer
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var store: CalendarStore?
    @ObservationIgnored private var watch = AILimitWatch()
    /// The meeting occurrences paused for, by when they start, so each pauses once.
    @ObservationIgnored private var paused: [String: Date] = [:]
    @ObservationIgnored private var meetingLoop: Task<Void, Never>?
    @ObservationIgnored private var nap: Task<Void, Never>?
    /// A burst of Calendar changes is read once, after it settles.
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private var release: Task<Void, Never>?

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        pauseMusic = defaults.bool(forKey: Self.pauseKey)
        minutes = (defaults.object(forKey: Self.minutesKey) as? Int).map { SmartNudges.clamped($0, to: SmartNudges.minutes) } ?? SmartNudges.standardMinutes
        anyEvent = defaults.bool(forKey: Self.anyKey)
        aiLimit = defaults.bool(forKey: Self.aiKey)
        threshold = (defaults.object(forKey: Self.thresholdKey) as? Int).map { SmartNudges.clamped($0, to: SmartNudges.thresholds) }
            ?? SmartNudges.standardThreshold
        quietHours = defaults.bool(forKey: Self.quietKey)
        quietFrom = defaults.string(forKey: Self.fromKey) ?? SmartNudges.standardFrom
        quietTo = defaults.string(forKey: Self.toKey) ?? SmartNudges.standardTo
        let decoder = JSONDecoder()
        watch = defaults.data(forKey: Self.warnedKey).flatMap { try? decoder.decode(AILimitWatch.self, from: $0) } ?? AILimitWatch()
        held = defaults.data(forKey: Self.heldKey).flatMap { try? decoder.decode([HeldNudge].self, from: $0) } ?? []
        paused = defaults.data(forKey: Self.pausedKey).flatMap { try? decoder.decode([String: Date].self, from: $0) } ?? [:]
    }

    /// At launch: AI usage's bar answers heard, Pause music's watch when on (never asking for Calendar), and anything held
    /// released or waited for.
    func start() {
        ExtensionBar.shared.answered = { [weak self] id, answer in self?.barAnswered(id, answer) }
        followCalendar(asking: false)
        followQuiet()
    }

    // MARK: The funnel

    /// Quiet hours' range, when they are on and the times read.
    var quiet: QuietHours? { quietHours ? QuietHours(from: quietFrom, to: quietTo) : nil }

    /// Whether Pilot keeps quiet at `date`.
    func isQuiet(at date: Date) -> Bool { quiet?.contains(date) ?? false }

    /// Every one of Pilot's own alerts: shown now, or held while quiet hours hold and summed up as they end.
    func post(_ post: Post, at date: Date? = nil) {
        let at = date ?? Date()
        guard isQuiet(at: at) else { return deliver(post) }
        held.append(HeldNudge(title: post.title, body: post.body, at: at))
        save(held, Self.heldKey)
        nudgeLog.notice("held \(post.id, privacy: .public): \(self.held.count) held")
        wakeAtQuietEnd(after: at)
    }

    /// Releases what is held once quiet hours are over (or off): one notification sums it up. True when it did.
    @discardableResult
    func releaseIfDue(at date: Date? = nil) -> Bool {
        let at = date ?? Date()
        guard !held.isEmpty, !isQuiet(at: at) else { return false }
        let summary = HeldNudge.summary(held)
        held = []
        save(held, Self.heldKey)
        deliver(Post(id: "smartNudges.summary", title: summary.title, body: summary.body, tip: summary.title))
        return true
    }

    /// Quiet hours' settings changed, or Pilot launched: what is held goes out if they are over, else waits for their end.
    private func followQuiet() {
        guard !releaseIfDue(), !held.isEmpty else { release?.cancel(); return }
        wakeAtQuietEnd(after: Date())
    }

    /// One wake at the end of the quiet hours `date` falls in, to release what is held.
    private func wakeAtQuietEnd(after date: Date) {
        release?.cancel()
        release = nil
        guard let quiet else { return }
        let wait = max(1, quiet.end(after: date).timeIntervalSince(date))
        release = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.followQuiet()
        }
    }

    /// The app's delivery: the sound, Pilot's tip and, unless a tip only, a notification (macOS asks once, at the first).
    static func show(_ post: Post) {
        if post.sound { NSSound(named: "Glass")?.play() }
        HUD.tip(post.tip ?? post.body, seconds: 10)
        guard post.notifies else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = post.title
            content.body = post.body
            try? await center.add(UNNotificationRequest(identifier: post.id, content: content, trigger: nil))
        }
    }

    // MARK: Pause music

    /// Pause music's watch: Calendar's store made, and access asked when `asking` (its switch just went on), then one
    /// sleep to the next event's lead at a time, woken by any Calendar change.
    private func followCalendar(asking: Bool) {
        meetingLoop?.cancel()
        nap?.cancel()
        meetingLoop = nil
        guard pauseMusic else { return }
        meetingLoop = Task { [weak self] in
            guard let self, await granted(asking: asking) else { return }
            while !Task.isCancelled {
                let wait = await checkMeetings().wait
                let nap = Task { _ = try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(5)) }
                self.nap = nap
                await nap.value
            }
        }
    }

    /// A setting the watch reads changed: it looks again now.
    private func wake() { nap?.cancel() }

    /// Calendar changed, here or anywhere (a sync posts a burst): one look once it has been quiet for 2 s.
    private func calendarChanged() {
        settling?.cancel()
        settling = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            self?.wake()
        }
    }

    /// Calendar's store once access is given; asked only when `asking`, so a launch never shows macOS's prompt.
    private func granted(asking: Bool) async -> Bool {
        let store = store ?? makeCalendar()
        if self.store == nil {
            self.store = store
            store.observe { [weak self] in self?.calendarChanged() }
        }
        var access = await store.readAccess()
        if access == .undetermined && asking { access = await store.requestAccess() ? .granted : .denied }
        calendarAccess = access
        if access != .granted { nudgeLog.notice("pause music: no Calendar access (\(String(describing: access), privacy: .public))") }
        return access == .granted
    }

    /// One look at Calendar at `date`: pauses what plays for an event coming due; says what it did, and how long until
    /// the next look (at most an hour, so only the coming hour and the lead are read).
    @discardableResult
    func checkMeetings(at date: Date? = nil) async -> (said: String?, wait: TimeInterval) {
        let at = date ?? Date()
        guard pauseMusic else { return (nil, 3600) }
        // A check just after the switch went on can come before the watch has made the store.
        if store == nil { _ = await granted(asking: false) }
        guard let store, calendarAccess == .granted else { return (nil, 3600) }
        paused = paused.filter { $0.value > at.addingTimeInterval(-86400) }
        let events = store.meetings(in: DateInterval(start: at, duration: 3600 + Double(minutes * 60)))
        let plan = MusicPause.plan(events, at: at, minutes: minutes, anyEvent: anyEvent, done: Set(paused.keys))
        var said: String?
        if let event = plan.due {
            paused[event.occurrence] = event.start
            save(paused, Self.pausedKey)
            said = await pause(for: event, at: at)
        }
        return (said, min(max(plan.next.map { $0.timeIntervalSince(at) } ?? 3600, 1), 3600))
    }

    /// Pauses what plays, if anything does, and tips why: held in quiet hours like any other.
    private func pause(for event: MeetingEvent, at date: Date) async -> String {
        let didPause = await withCheckedContinuation { done in media.pauseIfPlaying { done.resume(returning: $0) } }
        nudgeLog.notice("pause music: \(didPause ? "paused" : "nothing playing", privacy: .public)")
        guard didPause else { return "nothing playing for “\(event.title)”" }
        let tip = MusicPause.tip(event, at: date)
        post(Post(id: "smartNudges.pauseMusic", title: "Pause music", body: tip, notifies: false), at: date)
        return tip
    }

    // MARK: AI limit warning

    /// An extension's bar answer, as ExtensionBar's round received it: AI usage's windows read, and each that passed
    /// the threshold in a window not warned about yet posts one notification. Says what it warned.
    @discardableResult
    func barAnswered(_ id: String, _ answer: Extension.BarAnswer, at date: Date? = nil) -> [String] {
        guard aiLimit, id == AILimit.extensionID else { return [] }
        let at = date ?? Date()
        let before = watch
        let fresh = watch.record(AILimit.windows(in: answer), threshold: threshold)
        if watch != before { save(watch, Self.warnedKey) }
        return fresh.map { window in
            let text = AILimit.text(window, now: at)
            post(Post(id: "smartNudges.aiLimit.\(window.key)", title: "AI limit", body: text), at: at)
            return text
        }
    }

    /// The AI windows as AI usage's last bar answer shows them.
    var aiWindows: [AIWindow] { lastAIAnswer().map(AILimit.windows) ?? [] }

    /// The AI windows warned about in their current window.
    var warned: [String] { watch.warned.keys.sorted() }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
