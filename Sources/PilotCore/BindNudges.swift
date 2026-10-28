import Foundation

/// Bind nudges (card agent-bo-95422934; Sven's Hammerspoon promoter, rebuilt): after an app is opened by mouse, or an
/// app or action is picked in the menu, a hint names its bind; an app with no key gets an offer to set one there
/// (story 122). Rate-limited so it teaches without nagging.
public struct BindNudges: Sendable {
    /// One hint per bind an hour, and one of any kind every two minutes.
    private static let perBind: TimeInterval = 3600, gap: TimeInterval = 120

    private var last: [String: Date] = [:]
    private var lastAny: Date?

    public init() {}

    /// The hint's text when one may show now for this key, counted; nil inside the limits. Keyed by the bind's key, so a
    /// click and a menu pick of the same app, or an app reached through a role's key, share one limit.
    public mutating func hint(for name: String, key: String, at now: Date) -> String? {
        allow(key, at: now) ? Self.text(for: name, key: key) : nil
    }

    /// The offer's text when one may show now for an app with no key, counted under the same limits, keyed by the
    /// action its key would run (`apps.open:<bundle>`); nil inside the limits.
    public mutating func offer(for name: String, action: String, at now: Date) -> String? {
        allow(action, at: now) ? Self.offer(for: name) : nil
    }

    /// Whether a hint for this bind may show now; one that may is counted.
    mutating func allow(_ action: String, at now: Date) -> Bool {
        if let any = lastAny, now.timeIntervalSince(any) < Self.gap { return false }
        if let mine = last[action], now.timeIntervalSince(mine) < Self.perBind { return false }
        last[action] = now
        lastAny = now
        return true
    }

    /// An activation is the mouse's when a button went down within a second and no Pilot bind ran within 1.5 s: Hyper
    /// keys, workspace switches, Cmd+Tab and the focus a closed window hands on never count.
    public static func byMouse(sinceMouseDown: TimeInterval, sinceBind: TimeInterval?) -> Bool {
        sinceMouseDown < 1 && (sinceBind ?? .infinity) >= 1.5
    }

    public static func text(for name: String, key: String) -> String { "\(name) is on \(key)" }

    /// The offer for an app with no key, and its button.
    public static func offer(for name: String) -> String { "\(name) has no key" }
    public static let setKey = "Set a key"

    /// While the offer waits for a Hyper key; `taken` names the bind a refused key runs, so the next press tries again.
    public static func capture(for name: String, taken: (key: String, by: String)? = nil) -> String {
        (taken.map { "\($0.key) runs \($0.by) · " } ?? "") + "Press a Hyper key for \(name) · Esc stops"
    }
}
