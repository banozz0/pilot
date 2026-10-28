import Foundation

/// Lock keyboard for cleaning (Part 04; Sven 2026-10-25, Q471, Q472, Q479): while it holds, the tap takes every key, and
/// Esc held 3 s, the overlay's Unlock or 2 minutes end it. Pure: the tap feeds it each key and acts on what it says.
public struct KeyboardLock: Sendable {
    /// How long Esc must stay down to unlock (Q471 A).
    public static let escapeHold: TimeInterval = 3
    /// The safety unlock: no lock outlives this, so a lost mouse never strands the keyboard (Q471).
    public static let safety: TimeInterval = 120

    /// When the lock began and when it ends by itself, in system uptime seconds.
    public let since: TimeInterval
    public var until: TimeInterval { since + Self.safety }
    /// When Esc went down while locked, nil while it is up.
    public private(set) var escapeSince: TimeInterval?
    /// The modifiers macOS's session had down as the lock began (a plain combo's Cmd and Shift): their release still
    /// reaches the session, so none is left stuck down after the unlock. Shift, Ctrl, Alt and Cmd only.
    private var heldModifiers: UInt64
    /// Keys the session had down as the lock began: their release passes for the same reason.
    private var heldKeys: Set<Int64>
    /// Keys whose press the lock took and whose release it has not seen: at the unlock they stay taken until they come up
    /// (HyperTap.unlockKeyboard), so Esc held 3 s never repeats into the app in front.
    public private(set) var takenDown: Set<Int64> = []

    public init(since: TimeInterval, heldModifiers: UInt64 = 0, heldKeys: Set<Int64> = []) {
        self.since = since
        self.heldModifiers = heldModifiers & Self.modifierMask
        self.heldKeys = heldKeys
    }

    static let modifierMask = KeyEvent.shiftMask | KeyEvent.chordMask

    /// Why a lock ended: the three ways Sven ends it, and every failure, which unlocks rather than leave the keys dead.
    public enum End: String, Sendable {
        case escape, button, safety
        /// The tap was paused or taken down (Bitwarden's unlock, Pilot switched off or quitting), or macOS turned it off.
        case tapOff = "tap off"
        case screenLocked = "screen locked"
        /// A password field took the keyboard: the tap is blind to it, so the lock would be a lie.
        case secureInput = "secure input"
        case noOverlay = "no overlay"
    }

    /// Whether a system-defined event (NX_SYSDEFINED) is a key's and is taken while locked: subtype 8, the volume,
    /// brightness, media and illumination keys (NX_SUBTYPE_AUX_CONTROL_BUTTONS), but not NX_POWER_KEY (key type 6), as
    /// the lock screen says the power button still works. The power key's own subtype (1), the mouse's buttons (7) and
    /// every other subtype pass.
    public static func takes(systemDefinedSubtype subtype: Int, data1: Int) -> Bool { subtype == 8 && (data1 & 0xFFFF_0000) >> 16 != 6 }

    /// What a key does while locked.
    public enum Outcome: Equatable, Sendable {
        /// Taken: nothing sees it.
        case take
        /// The release of a key or modifier held as the lock began: it goes on, so the session lets it go.
        case pass
        /// Esc went down (true) or came up (false): taken, and the hold starts or stops.
        case escape(Bool)
        /// Past the safety unlock: the lock ends and the key goes on.
        case expired
    }

    public mutating func handle(_ e: KeyEvent) -> Outcome {
        // The safety unlock's timer runs on the main run loop; this holds even if it never fires.
        if e.time >= until { return .expired }
        switch e.kind {
        case .keyDown:
            takenDown.insert(e.keyCode)
            guard e.keyCode == KeyCode.escape, !e.autorepeat else { return .take }
            escapeSince = e.time
            return .escape(true)
        case .keyUp:
            if heldKeys.remove(e.keyCode) != nil { return .pass }
            takenDown.remove(e.keyCode)
            guard e.keyCode == KeyCode.escape, escapeSince != nil else { return .take }
            escapeSince = nil
            return .escape(false)
        case .flagsChanged:
            // Only a change that lets go of modifiers held at the start, and adds none, goes on.
            let now = e.flags & Self.modifierMask
            guard now & ~heldModifiers == 0, now != heldModifiers else { return .take }
            heldModifiers = now
            return .pass
        }
    }

    /// Esc has been down since `since` and is down now (`held`, read from the HID state, so a release the tap missed
    /// never unlocks): the hold is done at `now`.
    public func escapeDone(armedAt since: TimeInterval, now: TimeInterval, held: Bool) -> Bool {
        held && escapeSince == since && now - since >= Self.escapeHold - 0.05
    }
}
