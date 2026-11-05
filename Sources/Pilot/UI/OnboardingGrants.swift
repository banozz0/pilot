import AppKit
import CoreBluetooth
import CoreGraphics
import EventKit
import IOKit.hid
import PilotCore
import UserNotifications

/// The grants Permissions shows beyond Accessibility, Full Disk Access and System Events (Sven, 2026-10-28, Q4: "make sure
/// that we have all permissions shown in the onboarding"): each read without a prompt, and each row's Allow, which asks
/// as the feature's own first use does: macOS's prompt when Pilot was never asked, its Privacy & Security pane after.
@MainActor
final class OnboardingGrants {
    static let shared = OnboardingGrants()

    /// Made at the first ask and held: CoreBluetooth and EventKit answer only while their object lives.
    private lazy var bluetooth = IOBluetoothSystem()
    private lazy var calendar = EventKitCalendar()

    /// The rows read here, each without a prompt.
    struct Reading {
        var screenRecording = false, inputMonitoring = false, notifications = false, bluetooth = false, location = false, calendars = false
        var reminders = false

        func apply(to s: inout Onboarding.Status) {
            s.screenRecording = screenRecording; s.inputMonitoring = inputMonitoring; s.notifications = notifications
            s.bluetooth = bluetooth; s.location = location; s.calendars = calendars; s.reminders = reminders
        }
    }

    /// Nil in a test run: it has no bundle to answer for, and UNUserNotificationCenter throws without one.
    func read() async -> Reading? {
        guard !isTestRun else { return nil }
        let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return Reading(screenRecording: CGPreflightScreenCaptureAccess(),   // a read, no prompt (ADR 0012, amended 2026-10-28)
                       inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
                       notifications: [.authorized, .provisional].contains(notifications),
                       bluetooth: CBManager.authorization == .allowedAlways,
                       location: BarReadings.coreWLAN.locationAccess() == .allowed,
                       calendars: EKEventStore.authorizationStatus(for: .event) == .fullAccess,
                       reminders: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess)
    }

    /// `still`: whether the ask is still wanted once its own read returns (Try it's Allow the rest, T58); a Settings row's
    /// press always is.
    func ask(_ row: Onboarding.Row, engine: Engine, still: @escaping @MainActor () -> Bool = { true }) {
        switch row {
        case .screenRecording: PilotCapture.shared.askScreenRecording()
        case .inputMonitoring: engine.mouseButtons.requestAccess()
        case .notifications:
            Task {
                let center = UNUserNotificationCenter.current()
                let status = await center.notificationSettings().authorizationStatus
                guard still() else { return }
                if status == .denied {
                    SystemModule.pane("com.apple.Notifications-Settings.extension?id=dev.banozz.pilot")
                } else {
                    _ = try? await center.requestAuthorization(options: [.alert])
                }
            }
        case .bluetooth:
            if bluetooth.authorization() == .denied { NSWorkspace.shared.open(SetupBluetooth.settingsPane); return }
            Task { _ = await bluetooth.requestAccess() }
        case .location:
            let wifi = BarReadings.coreWLAN
            if wifi.locationAccess() == .denied { return SystemModule.pane("com.apple.preference.security?Privacy_LocationServices") }
            Task { _ = await wifi.requestLocation() }
        case .calendars:
            if calendar.access == .denied { NSWorkspace.shared.open(ClockCalendar.privacy); return }
            Task { _ = await calendar.requestAccess() }
        case .reminders:
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .notDetermined: Task { await calendar.requestRemindersAccess() }
            case .fullAccess: break
            default: NSWorkspace.shared.open(ClockCalendar.remindersPrivacy)
            }
        case .accessibility, .systemEvents, .fullDiskAccess, .conflicts, .microphone: break
        }
    }
}

/// What the walk asks of the Mac: Pilot's own asks and reads, or a sandbox's.
@MainActor
protocol GrantSystem: AnyObject {
    /// Whether `row` reads allowed now, without a prompt.
    func allowed(_ row: Onboarding.Row) async -> Bool
    /// Asks as Settings › Permissions' row does: macOS's prompt, else its pane, with the drag helper where Settings uses it.
    /// An ask that waits on a read first acts only while `still` says the walk is on that step.
    func ask(_ row: Onboarding.Row, still: @escaping @MainActor () -> Bool)
    /// The drag helper goes when its own step is allowed, skipped or stopped; another list's helper stays.
    func closeHelper(_ row: Onboarding.Row)
}

/// Pilot's own asks and reads, the ones Settings › Permissions and the features use.
@MainActor
final class LiveGrants: GrantSystem {
    /// System Events' last answer: idle, it says -600 whatever the grant (Onboarding.systemEvents).
    private var systemEvents = false

    func allowed(_ row: Onboarding.Row) async -> Bool {
        switch row {
        case .systemEvents:
            let answer = await Task.detached { ControlStatus.mayControlSystemEvents() }.value
            systemEvents = Onboarding.systemEvents(answer: answer, last: systemEvents)
            return systemEvents
        case .fullDiskAccess: return await Task.detached { FileIndex.hasFullDiskAccess() }.value
        case .microphone:
            MicrophoneGrant.shared.refresh()
            return MicrophoneGrant.shared.isGranted
        // A read, no prompt, once the walk's step showed: its press counts as a capture press (ADR 0012).
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .inputMonitoring: return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        case .notifications:
            guard !isTestRun else { return false }
            return [.authorized, .provisional].contains(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
        case .accessibility, .conflicts, .bluetooth, .location, .calendars, .reminders: return false
        }
    }

    func ask(_ row: Onboarding.Row, still: @escaping @MainActor () -> Bool) {
        switch row {
        case .systemEvents:
            // macOS prompts once; refused before (-1743), it never asks again, so its pane opens. The TCC read runs off
            // the main thread, as Settings' does; a Skip or Stop meanwhile leaves osascript and the pane alone.
            Task {
                let answer = await Task.detached { ControlStatus.mayControlSystemEvents() }.value
                guard still() else { return }
                if answer == -1743 { SystemModule.pane(MorePermissionRows.automationPane) } else { SystemModule.systemEvents("count processes") }
            }
        case .fullDiskAccess:
            SystemModule.openFullDiskAccess()
            PermissionDragPanel.show(.fullDiskAccess)
        case .microphone:
            if MicrophoneGrant.shared.status == .notDetermined { Task { await MicrophoneGrant.shared.ask() } } else { MicrophoneGrant.openSettings() }
        case .screenRecording: PilotCapture.shared.askScreenRecording()
        case .inputMonitoring, .notifications:
            guard let engine = Engine.shared else { return }
            OnboardingGrants.shared.ask(row, engine: engine, still: still)
        case .accessibility, .conflicts, .bluetooth, .location, .calendars, .reminders: break
        }
    }

    func closeHelper(_ row: Onboarding.Row) {
        switch row {
        case .fullDiskAccess: PermissionDragPanel.close(.fullDiskAccess)
        case .screenRecording: PermissionDragPanel.close(.screenRecording)
        default: break
        }
    }
}

/// Try it's Allow the rest (T58; Sven, 2026-11-05, Q851, Q852): the grants Access left for later, one after another, so
/// nobody allows them one by one in Settings. Each step asks as Settings › Permissions does and moves on by itself once it
/// reads allowed, read once a second while the walk runs; Skip moves on, Stop ends it. Nothing is read before the walk
/// starts, and each grant only when its step comes, so Screen Recording is read only after its own ask, a capture
/// press (ADR 0012). Clashing shortcuts is no grant and stays with Settings › Shortcut conflicts.
@Observable @MainActor
final class GrantWalk {
    /// Access's "Later, from Settings" list, in its order, but clashing shortcuts.
    static let steps = OnboardingModel.later.filter { $0 != .conflicts }

    enum Phase: Equatable { case ready, asking(Onboarding.Row), finished }

    private(set) var phase = Phase.ready
    /// The steps read allowed, in order.
    private(set) var allowedRows: [Onboarding.Row] = []
    /// The steps skipped or ended before they read allowed.
    private(set) var skipped: [Onboarding.Row] = []

    @ObservationIgnored let system: GrantSystem
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var reading = false
    /// Each step entered, skip and stop moves it on: an awaited read or ask whose turn has passed does nothing, so no
    /// stopped or skipped walk asks, reads or opens anything again (reviewer, T58).
    @ObservationIgnored private var turn = 0

    init(system: GrantSystem = LiveGrants()) { self.system = system }

    /// "Done: 2 of 6".
    var done: String { "Done: \(allowedRows.count) of \(Self.steps.count)" }

    /// The step after `row`, nil at the end.
    private func next(after row: Onboarding.Row?) -> Onboarding.Row? {
        guard let row, let i = Self.steps.firstIndex(of: row) else { return Self.steps.first }
        return Self.steps.dropFirst(i + 1).first
    }

    func start() {
        guard phase == .ready else { return }
        log.notice("onboarding: allow the rest")
        allowedRows = []
        skipped = []
        phase = .asking(Self.steps[0])
        turn += 1
        let mine = turn
        // A Stop before the Task runs ends it there.
        Task { guard turn == mine else { return }; await enter(Self.steps.first) }
    }

    /// A step: read first, so one already allowed passes without an ask; else its ask, then the poll. Screen Recording is
    /// asked before any read: its ask is the capture press (ADR 0012), and it asks nothing once allowed.
    private func enter(_ row: Onboarding.Row?) async {
        guard let row else { return finish() }
        turn += 1
        let mine = turn
        phase = .asking(row)
        let ok = row == .screenRecording ? false : await system.allowed(row)
        guard turn == mine, phase == .asking(row) else { return }
        if ok {
            allowedRows.append(row)
            return await enter(next(after: row))
        }
        system.ask(row) { [weak self] in self?.turn == mine && self?.phase == .asking(row) }
        watch()
    }

    private func watch() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Once a second: the step read again, and on when it reads allowed.
    func tick() {
        guard case .asking(let row) = phase, !reading else { return }
        reading = true
        let mine = turn
        Task {
            let ok = await system.allowed(row)
            // A passed turn's read leaves `reading` to its own step.
            guard turn == mine else { return }
            reading = false
            guard ok, phase == .asking(row) else { return }
            allowedRows.append(row)
            stopWatch()
            // Screen Recording's helper turns to Quit & Reopen once allowed, which it needs to take effect: it is not
            // closed here, and the next steps close only their own (closeHelper), so it stays until Later or Quit & Reopen.
            if row != .screenRecording { system.closeHelper(row) }
            await enter(next(after: row))
        }
    }

    /// On without it: Settings › Permissions has it still, Notifications System Settings.
    func skip() {
        guard case .asking(let row) = phase else { return }
        turn += 1
        reading = false
        skipped.append(row)
        stopWatch()
        system.closeHelper(row)
        let mine = turn
        Task { guard turn == mine else { return }; await enter(next(after: row)) }
    }

    /// Ends the walk: what is left counts as skipped.
    func stop() {
        guard case .asking(let row) = phase, let i = Self.steps.firstIndex(of: row) else { return }
        turn += 1
        skipped += Self.steps[i...].filter { !allowedRows.contains($0) }
        system.closeHelper(row)
        finish()
    }

    private func finish() {
        reading = false
        stopWatch()
        phase = .finished
        log.notice("onboarding: allow the rest, \(self.done, privacy: .public)")
    }

    private func stopWatch() {
        timer?.invalidate()
        timer = nil
    }

    /// A step's name: Screen Recording without Access's "at first capture".
    static func name(_ row: Onboarding.Row) -> String { row == .screenRecording ? "Screen Recording" : row.short }

    /// What the current step says while it waits.
    static func hint(_ row: Onboarding.Row) -> String {
        switch row {
        case .fullDiskAccess: "Switch Pilot on in System Settings; drag it in from the helper if it is not listed. It may read allowed only after Pilot reopens: Skip then."
        case .screenRecording: "Switch Pilot on in System Settings; drag it in from the helper if it is not listed."
        case .systemEvents, .microphone, .inputMonitoring, .notifications: "Answer macOS's prompt, or switch Pilot on in System Settings."
        default: ""
        }
    }

    #if DEBUG
    /// A render's walk at a step, with what it has allowed and skipped.
    func seed(_ phase: Phase, allowed: [Onboarding.Row] = [], skipped: [Onboarding.Row] = []) {
        self.phase = phase
        allowedRows = allowed
        self.skipped = skipped
    }
    #endif
}
