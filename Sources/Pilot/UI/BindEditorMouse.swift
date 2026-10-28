import PilotCore
import SwiftUI

/// A mouse button in the bind editor (Sven, after Build 82: Binds › Mouse opens the keyboard's sheet): what the catch
/// got or Change picked, in place of the keys. The strip names the button and, for a plain button, its trigger, Click or
/// Hold (P74); Save binds on Binds › Mouse's store (BindStore.setMouse), never the keyboard's.
struct MouseTrigger: Identifiable, Equatable {
    /// What the button sends, as caught: a plain trigger, or its Hyper one.
    var sends: Key
    var device: MouseKeys.Device?
    /// The drawn button it is bound on; nil for one the drawing lacks, or the wheel.
    var button: Int?
    /// Its With Hyper held action (P51).
    var hyper = false
    /// Other button… caught a drawn button's number (Q309).
    var note: String?

    var id: String { "\(sends.keyCode)-\(hyper)-\(button ?? 0)" }
    var isScroll: Bool { MouseKeys.isScroll(sends.keyCode) }
    /// A plain button has a Click and a Hold; the wheel and a Hyper action only the one.
    var holds: Bool { !hyper && !isScroll }
    /// "Wheel click", "Scroll down", "Button 7"; Hyper's cap is drawn apart.
    var name: String { button.map(MouseKeys.buttonName) ?? MouseKeys.sends(sends) }
    /// What it sends, beside its name when that says more: "Button 3", "Play key".
    var detail: String? { isScroll || MouseKeys.sends(sends) == name ? nil : MouseKeys.sends(sends) }

    func trigger(hold: Bool) -> Key { hyper ? MouseKeys.underHyper(sends) : hold && holds ? MouseKeys.hold(sends) : sends }

    /// The button as Save's sentence names it.
    func title(hold: Bool) -> String { (hyper ? "Hyper + " : "") + name + (hold && holds ? " held" : "") }
}

extension BindEditor {
    /// The mouse trigger Save binds: its Hold while Hold is picked or a ring is (a ring opens on the hold, P74).
    var mouseHolds: Bool {
        guard let mouse, mouse.holds else { return false }
        return holding || target.flatMap(Rings.ringID(inAction:)) != nil
    }

    /// A mouse bind's plan: no key moves (a mouse trigger frees no keyboard key); what the trigger runs now is replaced.
    func mousePlan(_ mouse: MouseTrigger) -> BindPlan {
        let now = key.flatMap(engine.binds.store.action(for:))
        var plan = BindPlan(key: key, name: target.map(name(of:)), opens: target.flatMap(AppLink.init(id:)) != nil,
                            holder: now == target ? nil : now.map(name(of:)), freed: nil)
        plan.keys = mouse.title(hold: mouseHolds)
        return plan
    }

    /// The line under the button: what it sends, and what Click and Hold do.
    func mouseCaption(_ mouse: MouseTrigger) -> String {
        if mouse.isScroll { return "Hyper + \(MouseKeys.sends(mouse.sends).lowercased()): each wheel notch, or each longer trackpad swipe, runs it." }
        let sends = MouseKeys.Catch.sends(mouse.button.map(MouseKeys.buttonName), MouseKeys.plain(mouse.sends), from: mouse.device?.name)
        if mouse.hyper { return sends + " With Hyper held it runs your pick." }
        return sends + (mouseHolds ? " Hold it, then let go: a quick press runs its Click bind, or nothing." : "")
    }

    /// Click or Hold picked: that trigger's bind, if it has one, shown to change.
    func pickTrigger(hold: Bool) {
        holding = hold
        scope(nil)
        finder.query = ""
        if let key, let action = engine.binds.store.action(for: key) { pick(action) }
    }

    /// As the sheet opens on a button: its Click bind, else its Hold's.
    func openMouse(_ mouse: MouseTrigger) {
        let store = engine.binds.store
        holding = mouse.holds && store.action(for: mouse.trigger(hold: false)) == nil && store.action(for: mouse.trigger(hold: true)) != nil
        if let key, let action = store.action(for: key) { pick(action) }
    }

    /// Remove: the trigger does its own job again.
    func mouseRemoval(_ mouse: MouseTrigger) -> (title: String, run: () -> Void)? {
        guard let key, engine.binds.store.action(for: key) != nil else { return nil }
        return ("Remove", { engine.binds.setMouse(key, to: nil); dismiss() })
    }

    /// Save: the pick on the button's trigger, which then holds this bind alone (BindStore.setMouse).
    func saveMouse(_ mouse: MouseTrigger) {
        guard let key, let target else { return }
        engine.binds.setMouse(key, to: target, device: mouse.device, button: mouse.button)
        dismiss()
    }
}
