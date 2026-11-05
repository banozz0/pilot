import AppKit
import OSLog
import PilotCore

private let nlog = Logger(subsystem: "dev.banozz.pilot", category: "nudges")

/// Bind hints (card agent-bo-95422934): after a click brings up an app that has a bind, or a menu pick of an app or
/// action that shows one, Pilot's tip names the key. An app with no key gets "Set a key" instead, which takes the next
/// Hyper key as the bind editor's Record does and binds it under the editor's rules (story 122). PilotCore's BindNudges
/// decides when.
@MainActor
final class BindNudger {
    private unowned let engine: Engine
    private var limits = BindNudges()
    /// The tip waits for an app's key, until a free Hyper key binds it or the tip closes.
    private(set) var waiting = false

    init(engine: Engine) { self.engine = engine }

    func start() { engine.observers.onActivate = { [weak self] in self?.activated($0) } }

    private func activated(_ app: NSRunningApplication) {
        guard engine.settings.bindNudges, let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier else { return }
        let sinceMouse = [CGEventType.leftMouseDown, .rightMouseDown]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
        let sinceBind = engine.presses.first { $0.action != nil }.map { -$0.time.timeIntervalSinceNow }
        let store = engine.binds.store
        guard BindNudges.byMouse(sinceMouseDown: sinceMouse, sinceBind: sinceBind) else { return }
        let name = app.localizedName ?? bundle
        guard let key = MenuEntries.appKey(bundle, store: store, roleKeys: MenuEntries.roleKeys(store: store, roleApps: AppsModule.roleApps()),
                                           openID: AppsModule.openID(bundle:)) else { return offer(name, bundle: bundle, from: "click") }
        show(name, key: key.label, from: "click")
    }

    /// A menu pick: its row shows the key when it has one; an app's row with none offers one.
    func picked(_ entry: MenuEntry) {
        guard engine.settings.bindNudges, entry.detailIsKey, entry.frecencyKey != nil else { return }
        if let key = entry.detail { return show(entry.title, key: key, from: "menu") }
        if case .app(let bundle) = entry.target, bundle != Bundle.main.bundleIdentifier { offer(entry.title, bundle: bundle, from: "menu") }
    }

    private func show(_ name: String, key: String, from: String) {
        guard let text = limits.hint(for: name, key: key, at: .now) else { return }
        nlog.notice("hint after a \(from, privacy: .public): \(text, privacy: .private)")
        HUD.tip(text)
    }

    /// "Telegram has no key", its button starting the wait for one; it stays up a little longer than a hint, as the
    /// promoter's did.
    private func offer(_ name: String, bundle: String, from: String) {
        let target = AppsModule.openID(bundle: bundle)
        guard let text = limits.offer(for: name, action: target, at: .now) else { return }
        nlog.notice("offer after a \(from, privacy: .public): \(text, privacy: .public)")
        HUD.tip(text, seconds: 6, action: HUD.TipAction(title: BindNudges.setKey) { [weak self] in self?.capture(name, target: target) })
    }

    /// Waits for a Hyper key while the tip says so; a key another bind holds is refused and the wait goes on. Every
    /// other key, Cmd+C included, reaches the front app untouched. The tip closing any way stops the wait, so a later
    /// Hyper key runs its bind again instead of becoming this one.
    func capture(_ name: String, target: String, taken: (key: String, by: String)? = nil) {
        HUD.tip(BindNudges.capture(for: name, taken: taken), seconds: 10) { [weak self] in
            guard let self, waiting else { return }
            waiting = false
            engine.recordKey(nil)
        }
        waiting = true
        engine.recordKey(onlyHyper: true) { [weak self] key in
            guard let self else { return }
            waiting = false
            var binds = engine.binds
            switch Self.assign(key, to: target, store: binds.store, in: &binds, name: label(of:)) {
            case .bound:
                nlog.notice("hint set \(key.label, privacy: .public) for \(target, privacy: .public)")
                HUD.tip(BindNudges.text(for: name, key: key.label))
            case .taken(let by): capture(name, target: target, taken: (key.label, by))
            case .plain: capture(name, target: target)
            }
        }
    }

    /// What a key pressed for an app with no key does, by the bind editor's rules (BindPlan, BindWrite): a free Hyper
    /// key binds it; a key another action holds is refused, never taken from it, as no clash shows before the press.
    /// A plain combo is refused too: "Press a Hyper key" asked for none, and Cmd+V pressed by habit must never bind.
    enum Assigned: Equatable { case bound, taken(by: String), plain }

    static func assign<W: BindWriting>(_ key: Key, to target: String, store: BindStore, in binds: inout W, name: (String) -> String) -> Assigned {
        guard key.hyper else { return .plain }
        let plan = BindPlan(store: store, key: key, target: target, editing: nil, name: name)
        if let holder = plan.holderID { return .taken(by: name(holder)) }
        do throws(BindStore.BindError) { try BindWrite.save(plan, target, to: key, from: nil, in: &binds) } catch {
            switch error { case .triggerTaken(_, let by): return .taken(by: name(by)) }
        }
        return .bound
    }

    /// An action's name as the editor gives it: an app's own, else the engine's label.
    private func label(of id: String) -> String {
        AppsModule.bundle(in: id).flatMap(AppsModule.appName) ?? engine.action(id)?.label ?? id
    }
}
