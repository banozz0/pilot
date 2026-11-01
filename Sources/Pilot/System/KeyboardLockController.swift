import AppKit
import OSLog
import PilotCore
import SwiftUI

/// Lock keyboard for cleaning (Part 04; Sven 2026-10-25, Q471, Q472, Q479): the tap takes every key (HyperTap.lockKeyboard)
/// while a lock screen on every display says so, fills its ring while Esc is held and offers Unlock and Screenshot to the
/// mouse, which stays live. Esc held 3 s, Unlock or 2 minutes end it, and so does every failure: the tap going off, paused
/// or taken down (quit, Pilot switched off), the screen locking or the Mac sleeping, a password field taking the keyboard,
/// or no lock screen to show. Bindable, with no default key (Q479).
@MainActor
final class KeyboardLockController {
    static let actionID = "system.lockKeyboard"

    private let tap: HyperTap
    /// Whether a password field has the keyboard now (SecureInputMonitor): the tap is blind then, so no lock starts.
    var secureInput: () -> Bool = { false }
    private var panels: [KeyPanel] = []
    private var model: KeyboardLockModel?
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    /// Bumped at every lock and unlock: a timer armed for an earlier lock finds it gone and does nothing.
    private var generation = 0
    /// What follows each Screenshot taken during this lock (its thumbnail or the editor), held until the lock ends; nil
    /// before the lock's first Screenshot, so an unlock without one never wakes the capture.
    private var heldCaptures: [@MainActor () -> Void]?

    init(tap: HyperTap) {
        self.tap = tap
        tap.onUnlock = { [weak self] in self?.ended($0) }
        tap.onLockEscape = { [weak self] down, at in self?.escape(down, at: at) }
    }

    static func register(into registry: inout ActionRegistry, lock: KeyboardLockController) {
        try? registry.register(Action(id: actionID, label: "Lock keyboard for cleaning", module: .system, keywords: "clean wipe") { [weak lock] in
            lock?.lock()
        })
    }

    var isLocked: Bool { tap.keyboardLock != nil }

    /// Locks the keyboard, or says why it can't. Runs inside the tap's callback when its bind runs: the tap is locked at
    /// once, so the bind's own release is taken, and the lock screen shows after the callback has returned.
    func lock() {
        guard !isLocked else { return }
        guard !secureInput() else { return Self.tipLater("A password field has the keyboard, so Pilot can't lock it") }
        let now = ProcessInfo.processInfo.systemUptime
        let lock = KeyboardLock(since: now, heldModifiers: CGEventSource.flagsState(.combinedSessionState).rawValue, heldKeys: Self.keysDown())
        guard tap.lockKeyboard(lock) else { return Self.tipLater("Pilot's keyboard tap is off, so it can't lock the keyboard") }
        generation &+= 1
        let generation = generation
        slog.notice("keyboard locked")
        model = KeyboardLockModel(since: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + KeyboardLock.safety) { [weak self] in
            MainActor.assumeIsolated { if self?.generation == generation { self?.tap.unlockKeyboard(.safety) } }
        }
        watch()
        // Off the tap's callback: windows made inside it risk macOS turning the tap off.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if self?.generation == generation { self?.show() } }
        }
    }

    /// A tip after the tap's callback, which `lock` may run inside: a window made there risks macOS turning the tap off.
    private static func tipLater(_ text: String) {
        DispatchQueue.main.async { HUD.tip(text, seconds: 4) }
    }

    /// A password field took the keyboard (SecureInputMonitor): the tap no longer sees the keys, so the lock ends.
    func secureInputCameOn() { tap.unlockKeyboard(.secureInput) }

    /// The keys macOS's session holds down now: their releases still reach it once locked (KeyboardLock.heldKeys).
    private static func keysDown() -> Set<Int64> {
        Set((0..<128).filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }.map(Int64.init))
    }

    /// Esc went down or came up while locked: the ring fills or empties, and held 3 s with its key still down it unlocks.
    private func escape(_ down: Bool, at time: TimeInterval) {
        model?.escapeSince = down ? .now : nil
        guard down else { return }
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + KeyboardLock.escapeHold) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, let lock = self.tap.keyboardLock else { return }
                guard lock.escapeDone(armedAt: time, now: ProcessInfo.processInfo.systemUptime) else {
                    // Let go or pressed again since: a later press arms its own check.
                    return slog.notice("keyboard lock: esc hold from \(time, privacy: .public) not done")
                }
                self.tap.unlockKeyboard(.escape)
            }
        }
    }

    /// The lock screen's Screenshot (Sven on 1.0.2 build 9): a full-screen still as Hyper+A's, the click being the press
    /// (ADR 0012), saved and copied as every capture; the keyboard stays locked. Its thumbnail, or the editor, would sit
    /// under the lock screen, so it is held until the lock ends (Sven, 2026-11-01) and the screen says it was taken.
    private func screenshot() {
        let capture = PilotCapture.shared
        guard capture.permitted() else {
            model?.screenshot = "Screen Recording is off for Pilot: allow it once unlocked"
            return
        }
        model?.screenshot = nil
        // A save that ends after the lock follows at once.
        if heldCaptures == nil { heldCaptures = [] }
        capture.holdAfter = { [weak self] follow in
            if let self, self.isLocked, self.heldCaptures != nil { self.heldCaptures?.append(follow) } else { follow() }
        }
        capture.run(.fullScreen) { [weak self] in self?.model?.screenshot = "Screenshot taken: it shows once you unlock" }
    }

    /// The lock screen on every display, made anew when the displays change; with none shown, the lock ends.
    private func show() {
        guard let model else { return }
        panels.forEach { $0.close() }
        let look = Look.shared, glass = look.material(on: .menu) == .glass
        panels = NSScreen.screens.map { screen in
            let view = KeyboardLockView(model: model, glass: glass, screenshot: { [weak self] in self?.screenshot() }) { [weak self] in
                self?.tap.unlockKeyboard(.button)
            }
            let panel = Self.makePanel(view, frame: screen.frame, look: look)
            panel.orderFrontRegardless()
            return panel
        }
        if !panels.contains(where: \.isVisible) { tap.unlockKeyboard(.noOverlay) }
    }

    /// One display's lock screen: above every window, on every Space, over full-screen apps; never made key, so the app in
    /// front keeps its focus. Glass when Look's Glass is on, else the style's ground.
    static func makePanel(_ view: KeyboardLockView, frame: CGRect, look: Look = .shared) -> KeyPanel {
        let host = NSHostingView(rootView: view.styled(.hud, look: look).pilotTheme(look: look))
        host.frame = CGRect(origin: .zero, size: frame.size)
        let panel = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let backdrop = MaterialBackdrop(content: host)
        backdrop.show(view.glass ? .glass : .solid, tint: look.glassTint(look.colors.ground))
        panel.contentView = backdrop
        panel.appearance = look.appearance(for: .hud)
        panel.level = .screenSaver
        panel.setFrame(frame, display: false)
        return panel
    }

    /// What ends a lock besides its three ways, watched only while it holds.
    private func watch() {
        let distributed = DistributedNotificationCenter.default(), workspace = NSWorkspace.shared.notificationCenter, app = NotificationCenter.default
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ run: @escaping @MainActor (KeyboardLockController) -> Void) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { run(self) } }
            }))
        }
        // The lock screen and a sleeping Mac need the keys for the password.
        for (center, name) in [(distributed, ScreenEvents.locked), (workspace, NSWorkspace.willSleepNotification),
                               (workspace, NSWorkspace.sessionDidResignActiveNotification)] {
            on(center, name) { $0.tap.unlockKeyboard(.screenLocked) }
        }
        on(app, NSApplication.didChangeScreenParametersNotification) { $0.show() }
        on(app, NSApplication.willTerminateNotification) { $0.tap.unlockKeyboard(.tapOff) }
    }

    /// The lock ended (HyperTap.onUnlock), whichever way: every timer it armed goes stale, and the lock screen closes after
    /// the tap's callback, which this may run inside, has returned.
    private func ended(_ end: KeyboardLock.End) {
        generation &+= 1
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        let closing = panels
        panels = []
        model = nil
        let held = heldCaptures ?? []
        if heldCaptures != nil { PilotCapture.shared.holdAfter = nil }
        heldCaptures = nil
        slog.notice("keyboard unlocked: \(end.rawValue, privacy: .public)")
        DispatchQueue.main.async {
            closing.forEach { $0.close() }
            if let tip = Self.tip(end) { HUD.tip(tip, seconds: 4) }
            held.forEach { $0() }
        }
    }

    /// The tip for a lock that ended by itself; none for Esc or Unlock, which Sven did.
    static func tip(_ end: KeyboardLock.End) -> String? {
        switch end {
        case .escape, .button: nil
        case .safety: "Keyboard unlocked: 2 minutes are up"
        case .tapOff: "Keyboard unlocked: Pilot's keyboard tap went off"
        case .screenLocked: "Keyboard unlocked as the screen locked"
        case .secureInput: "Keyboard unlocked: a password field took the keyboard"
        case .noOverlay: "Keyboard unlocked: Pilot could not show its lock screen"
        }
    }
}

/// What the lock screen shows: when the lock began and ends by itself, and since when Esc is held.
@Observable @MainActor
final class KeyboardLockModel {
    let since: Date
    var until: Date { since.addingTimeInterval(KeyboardLock.safety) }
    var escapeSince: Date?
    /// What the last Screenshot came to, under the buttons; nil before one.
    var screenshot: String?
    /// The clock the screen reads; a render fixes it.
    @ObservationIgnored let now: () -> Date

    init(since: Date, escapeSince: Date? = nil, screenshot: String? = nil, now: @escaping () -> Date = Date.init) {
        self.since = since
        self.escapeSince = escapeSince
        self.screenshot = screenshot
        self.now = now
    }
}
