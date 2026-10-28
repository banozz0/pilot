import AppKit
import PilotCore

/// Keys Pilot posts into macOS's own shortcuts (ADR 0001: never into another app's hotkey). Each event carries the
/// tap's own mark so the tap lets it through, and posting waits until the tap callback has returned.
@MainActor
enum Post {
    private static let source = CGEventSource(stateID: .hidSystemState)

    /// A key with modifiers, e.g. cmd+v for a paste, pressed and released as a keyboard does
    /// (KeyEvent.keystroke): each modifier goes down and comes back up, so macOS never keeps Command held after it.
    static func key(_ code: Int64, _ modifiers: Modifiers) {
        DispatchQueue.main.async { events(KeyEvent.keystroke(code, modifiers: modifiers), own: true) }
    }

    /// Posts `events` at the HID tap, each with its flags set, even none: an event left unset takes the source's own
    /// (0x20000000 at rest on this Mac, Command too while one is stuck). `own` marks them so the tap lets them through;
    /// pilot://press leaves them unmarked, so the tap handles them as a keyboard's, `pause` apart.
    static func events(_ events: [KeyEvent], own: Bool, pause: useconds_t = 0) {
        for k in events {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(k.keyCode), keyDown: k.kind == .keyDown) else { continue }
            if k.kind == .flagsChanged { e.type = .flagsChanged }
            e.flags = CGEventFlags(rawValue: k.flags)
            if own { e.setIntegerValueField(.eventSourceUserData, value: HyperTap.ownEventMark) }
            e.post(tap: .cghidEventTap)
            if pause > 0 { usleep(pause) }
        }
    }

    /// Text typed into the focused app as unicode keystrokes, a few characters per event, marked as Pilot's own so the
    /// tap lets them through untouched and unlogged. Bitwarden's fill types a password this way (card
    /// agent-bo-95422814): into the field in front, never onto a pasteboard.
    static func text(_ text: String) {
        DispatchQueue.main.async {
            // Up to 16 UTF-16 units an event, cut between characters, so an emoji is never split.
            var chunks: [[UniChar]] = [[]]
            for character in text {
                let units = Array(String(character).utf16)
                if chunks[chunks.count - 1].count + units.count > 16 { chunks.append([]) }
                chunks[chunks.count - 1] += units
            }
            for var chunk in chunks where !chunk.isEmpty {
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                    e.flags = []
                    e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                    e.setIntegerValueField(.eventSourceUserData, value: HyperTap.ownEventMark)
                    e.post(tap: .cghidEventTap)
                }
            }
        }
    }

    /// The keyboard's media keys (NX_KEYTYPE_*), as the top row of a Mac keyboard sends them: volume, play, next.
    enum MediaKey: Int32 { case volumeUp = 0, volumeDown = 1, mute = 7, playPause = 16, next = 17, previous = 18 }

    static func media(_ key: MediaKey) { media(keyType: key.rawValue) }

    /// Any NX key type, as a mouse's own media key sends it (a hold-bound media key's quick press, to Now Playing, P74).
    static func media(keyType: Int32) {
        DispatchQueue.main.async {
            for down in [true, false] {
                let state: Int32 = down ? 0xA : 0xB
                let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                            subtype: 8, data1: Int((keyType << 16) | (state << 8)), data2: -1)
                // Marked, so the tap never takes Pilot's own media key for the mouse's.
                guard let event = ev?.cgEvent else { continue }
                event.setIntegerValueField(.eventSourceUserData, value: HyperTap.ownEventMark)
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
