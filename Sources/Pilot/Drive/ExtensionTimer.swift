import AppKit
import PilotCore
import SwiftUI

/// Pilot's one timer (Pomodoro as an extension, 2026-10-10; ADR 0010's `timer` action): an extension starts it and Pilot
/// counts it down in the Timer bar item, the dropdown's Now block and Home's Timer block, with its title and buttons. A
/// new timer replaces the one running, whoever sent it; `"seconds": 0` stops it only for the extension that owns it.
/// At zero it runs its `end` as that extension's action, or says the title is done. Kept in memory only, so a restart
/// drops it. The 1 s tick runs only while a timer counts; `now` is the clock, injectable so tests never wait.
@Observable @MainActor
final class ExtensionTimer {
    static let shared = ExtensionTimer()

    /// Whose timer it is: the extension's id, and its title for the HUD when it has gone since.
    struct Owner: Equatable {
        let id: String, title: String
    }

    /// The timer showing, as its extension sent it, and whose; nil when none.
    private(set) var spec: Extension.TimerSpec?
    private(set) var owner: Owner?
    /// The time left, "24:59"; nil when none shows.
    private(set) var countdown: String?
    /// The share of the timer left, for the ring; nil when none.
    private(set) var left: Double?
    /// When a counting timer ends; nil while paused or with none.
    private(set) var ends: Date?

    var title: String? { spec?.title }
    var isPaused: Bool { spec?.paused == true }
    var buttons: [Extension.Item.Action] { spec?.actions ?? [] }

    /// Runs one of the timer's actions as its extension's (ExtensionActions.run(_:asExtension:)); a test's spy.
    @ObservationIgnored var act: (Extension.Item.Action, Owner) -> Void = { action, owner in
        Task { await ExtensionActions.run(action, asExtension: owner.id, title: owner.title) }
    }
    @ObservationIgnored var hud: (String) -> Void = { HUD.tip($0) }
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var timer: Timer?

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    /// The `timer` action of `ext`.
    func start(_ spec: Extension.TimerSpec, extension ext: Extension) { start(spec, owner: Owner(id: ext.id, title: ext.title)) }

    /// Shows `spec` for `owner`, replacing any timer; seconds 0 stops the owner's timer instead. Paused, it holds its
    /// time and schedules no tick.
    func start(_ spec: Extension.TimerSpec, owner: Owner) {
        guard !spec.stops else { return stop(extension: owner.id) }
        halt()
        self.spec = spec
        self.owner = owner
        countdown = Extension.TimerSpec.countdown(spec.seconds)
        left = 1
        dlog.notice("timer: \(owner.id, privacy: .public) \(spec.paused ? "holds" : "starts") \(spec.seconds) s")
        guard !spec.paused else { return }
        ends = now().addingTimeInterval(TimeInterval(spec.seconds))
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        // The tick reads the clock, so macOS may group its wake-ups with others.
        timer.tolerance = 0.2
        // Common modes: the countdown keeps going while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops the timer if extension `id` owns it; another's keeps going.
    func stop(extension id: String) {
        guard owner?.id == id else { return }
        stop()
    }

    func stop() {
        guard spec != nil else { return }
        dlog.notice("timer: \(self.owner?.id ?? "", privacy: .public) stopped")
        halt()
    }

    /// A second passed: the countdown and ring follow the clock; at zero the timer goes and its end runs.
    func tick() {
        guard let spec, let owner, let ends else { return }
        let rest = ends.timeIntervalSince(now())
        guard rest > 0 else {
            halt()
            dlog.notice("timer: \(owner.id, privacy: .public) done")
            if let end = spec.end { act(end, owner) } else { hud("\(spec.title) done") }
            return
        }
        let text = Extension.TimerSpec.countdown(Int(rest.rounded(.up)))
        if text != countdown {
            countdown = text
            left = rest / TimeInterval(spec.seconds)
        }
    }

    /// Button `index` pressed (the popover's or Home's): its action runs as the timer's extension's.
    func press(_ index: Int) {
        guard let owner, buttons.indices.contains(index) else { return }
        act(buttons[index], owner)
    }

    private func halt() {
        timer?.invalidate()
        timer = nil
        spec = nil
        owner = nil
        countdown = nil
        left = nil
        ends = nil
    }
}

/// Pilot's own alert for an extension (ADR 0010's `alert` action; the old Pomodoro end alert, generalised): a HUD panel
/// that stays until a button is pressed, so one that shows while Sven is away is still there when he comes back. Any
/// button closes it, then runs its action as the extension's; OK only closes it.
@MainActor
enum ExtensionAlert {
    private static var panel: NSPanel?

    /// Shows `alert` from `ext`, replacing any shown, and plays its sound.
    static func show(_ alert: Extension.AlertSpec, from ext: Extension) {
        close()
        let id = ext.id, title = ext.title
        alert.sound.map(ExtensionActions.play)
        dlog.notice("alert: \(ext.id, privacy: .public) shown")
        let p = HUD.makePanel(ExtensionAlertView(alert: alert) { index in
            close()
            guard let index, alert.actions.indices.contains(index) else { return }
            Task { await ExtensionActions.run(alert.actions[index], asExtension: id, title: title) }
        })
        p.orderFrontRegardless()
        panel = p
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The alert's buttons as each style draws them: one per action, the first primary, or OK alone.
struct ExtensionAlertButton: Identifiable {
    let id: Int?, title: String, primary: Bool

    /// `alert`'s buttons in its order; OK (no index) when it has none.
    static func all(_ alert: Extension.AlertSpec) -> [ExtensionAlertButton] {
        guard !alert.actions.isEmpty else { return [ExtensionAlertButton(id: nil, title: "OK", primary: true)] }
        return alert.actions.enumerated().map { ExtensionAlertButton(id: $0.offset, title: $0.element.label, primary: $0.offset == 0) }
    }
}

/// The alert HUD: its heading, its note, then its buttons; `press` gets the action's index, nil for OK. `extra` sits
/// before the buttons and answers nothing (the Allow prompt's Show details).
struct ExtensionAlertView: View {
    @Environment(\.style) private var style
    let alert: Extension.AlertSpec
    var extra: AnyView?
    var press: (Int?) -> Void = { _ in }

    var body: some View {
        switch style.kind {
        case .instrument: InstrumentExtensionAlert(alert: alert, extra: extra, press: press)
        case .toybox: ToyExtensionAlert(alert: alert, extra: extra, press: press)
        }
    }

}
