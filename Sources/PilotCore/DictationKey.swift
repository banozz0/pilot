import Foundation

/// The one modifier that alone starts and stops dictation (Q224, Sven 2026-10-17: Right Control): a tap
/// of it pressed and released alone, or held to talk. Each only while it is no layer key.
/// Fn is left out: macOS owns a lone Fn (🌐) press (Keyboard › Press 🌐 key to).
public enum DictationKey: String, CaseIterable, Sendable {
    case off, rightControl, rightOption, rightCommand

    public var label: String { layerKey?.label ?? "Off" }

    /// The layer key this key would be too, by the same name.
    public var layerKey: LayerKey? { LayerKey(rawValue: rawValue) }

    /// No layer key: a layer key is Hyper, never the dictation key too.
    public func isFree(layerKeys: [LayerKey]) -> Bool { layerKey.map { !layerKeys.contains($0) } ?? true }

    /// The keys the setting offers: every one that is no layer key.
    public static func offered(layerKeys: [LayerKey]) -> [DictationKey] { allCases.filter { $0.isFree(layerKeys: layerKeys) } }

    var keyCode: Int64? { layerKey?.keyCode }

    var deviceFlag: UInt64 { layerKey?.deviceFlag ?? 0 }

    /// The modifier mask the key sets, Ctrl, Alt or Cmd.
    var mask: UInt64 { layerKey?.modifierMask ?? 0 }
}

/// Toggle: a tap turns dictation on, the next one off. Hold: dictation runs while the key is down.
public enum DictationKeyMode: String, CaseIterable, Sendable {
    case toggle, hold

    public var label: String { self == .toggle ? "Tap on, tap off" : "Hold to talk" }
}

/// Watches the dictation key in the tap's events. Pure, so it is tested without a window server; it never takes an
/// event, so the key reaches the app as plain Control and every Ctrl shortcut works as before.
public struct DictationKeyWatch: Sendable {
    /// A tap is a press and release under this, alone; held alone this long, Hold mode starts talking.
    public static let window: TimeInterval = 0.3

    public enum Decision: Sendable, Equatable {
        case none
        /// A tap in Toggle mode: dictation on or off.
        case toggle
        /// Hold mode: the key went down alone; call `held(at:clickedWithin:)` once `window` has passed.
        case arm
        /// Hold mode: dictation starts (true) or stops (false).
        case hold(Bool)
    }

    public let key: DictationKey
    public let mode: DictationKeyMode
    private var downSince: TimeInterval?
    /// Something else happened while the key was down (a key, another modifier, Hyper): no tap.
    private var used = false
    private var holding = false

    public init(key: DictationKey = .off, mode: DictationKeyMode = .toggle) {
        self.key = key; self.mode = mode
    }

    /// What `e` does to the key. `layerDown`: Hyper is held, so the key is a sublayer. `clickedWithin` answers whether a
    /// mouse button went down or the wheel scrolled in the last so many seconds; asked once, on a release that would be a
    /// tap.
    public mutating func handle(_ e: KeyEvent, layerDown: Bool, clickedWithin: (TimeInterval) -> Bool = { _ in false }) -> Decision {
        guard let code = key.keyCode else { return .none }
        guard e.kind == .flagsChanged, e.keyCode == code else {
            // Anything else while the key is down: no tap, and no hold starts. A take already running ends at the release.
            if downSince != nil { used = true }
            return .none
        }
        if e.flags & key.deviceFlag != 0 {
            guard downSince == nil else { return .none }
            downSince = e.time
            used = layerDown || e.flags & KeyEvent.modifierMask & ~(key.mask | key.deviceFlag) != 0
            return mode == .hold && !used ? .arm : .none
        }
        guard let since = downSince else { return .none }
        downSince = nil
        if holding { return reset() }
        let elapsed = e.time - since
        guard mode == .toggle, !used, elapsed < Self.window, !clickedWithin(elapsed) else { return .none }
        return .toggle
    }

    /// Hold mode's timer, `window` after the press: still down alone, with no click or scroll since, dictation starts.
    /// A chord or a Ctrl+click before then starts nothing. A timer left from an earlier press finds this one too young.
    public mutating func held(at now: TimeInterval, clickedWithin: (TimeInterval) -> Bool = { _ in false }) -> Decision {
        guard mode == .hold, let since = downSince, !used, !holding else { return .none }
        let elapsed = now - since
        // A timer fires no earlier than asked; the slack is the clocks' rounding.
        guard elapsed + 0.01 >= Self.window, !clickedWithin(elapsed) else { return .none }
        holding = true
        return .hold(true)
    }

    /// The key's release may go unseen (the tap paused or turned off): forget the press; a held talk stops.
    public mutating func reset() -> Decision {
        let wasHolding = holding
        downSince = nil; used = false; holding = false
        return wasHolding ? .hold(false) : .none
    }
}
