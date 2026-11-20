import Foundation

/// The capture box (pilot-ui-redesign S5 B, T23): with Captures › Capture box on, each of the six capture binds opens
/// the capture overlay as the box, in its own mode, and fixed letters switch the mode inside it (Q257), whatever keys the
/// user's binds are on. Two choices make a mode: how much of the screen (`How`) and what the capture makes (`What`), with
/// a timer beside them. Return captures, Esc closes. This is the box's state alone; the overlay keeps it and T24's
/// view draws it.
public struct CaptureBox: Equatable, Sendable {
    /// How much of the screen: an area dragged, a window clicked, the whole display, or an area Pilot scrolls and stitches.
    public enum How: String, CaseIterable, Sendable { case area, window, full, scroll }
    /// What the capture makes: a picture, a recording, or the text read off the screen.
    public enum What: String, CaseIterable, Sendable { case photo, record, text }

    /// The box's letters (Q257), read by the character they type, so they sit on the same letters in any layout.
    /// Area again (already in Area) is the overlay's smart selection, A's key before the box.
    public enum Letter: Character, CaseIterable, Sendable {
        case area = "a", window = "w", full = "f", scroll = "s", record = "r", text = "o", timer = "t"

        /// The letter a key typed, or nil for any other key.
        public init?(typed characters: String?) {
            guard let characters, characters.count == 1, let letter = Letter(rawValue: Character(characters.lowercased())) else { return nil }
            self = letter
        }
    }

    public var how: How
    public var what: What
    /// Seconds before the capture, one of `timers`: 0 is off. A recording counts down this long first.
    public var timer: Int

    /// The timer's steps, which T walks round: off, 3, 5 and 10 seconds.
    public static let timers = [0, 3, 5, 10]

    public init(how: How = .area, what: What = .photo, timer: Int = 0) {
        self.how = how
        self.what = what
        self.timer = Self.timers.contains(timer) ? timer : 0
    }

    /// The action button's words: Capture, Record, Copy text, or Start scrolling for a scrolling capture.
    public var action: String {
        switch (how, what) {
        case (.scroll, _): "Start scrolling"
        case (_, .record): "Record"
        case (_, .text): "Copy text"
        default: "Capture"
        }
    }

    /// A letter pressed in the box. A scrolling capture is a picture only, so Scroll turns Record or Text back to Photo,
    /// and Record or Text from Scroll goes to Area. R or O again goes back to Photo.
    public mutating func press(_ letter: Letter) {
        switch letter {
        case .area: how = .area
        case .window: how = .window
        case .full: how = .full
        case .scroll: how = .scroll; what = .photo
        case .record: what = what == .record ? .photo : .record
        case .text: what = what == .text ? .photo : .text
        case .timer: timer = Self.timers[((Self.timers.firstIndex(of: timer) ?? 0) + 1) % Self.timers.count]
        }
        if how == .scroll, what != .photo { how = .area }
    }

    /// The six capture binds and the mode each opens, in the key sheet's order (S5 B): its left column joins these with
    /// the user's keys from the bind store, an unset one shown as "no key".
    public static let binds: [(action: String, opens: CaptureBox)] = [
        ("captures.area", CaptureBox(how: .area)),
        ("captures.activeWindow", CaptureBox(how: .window)),
        ("captures.fullscreen", CaptureBox(how: .full)),
        ("captures.scrolling", CaptureBox(how: .scroll)),
        ("captures.ocr", CaptureBox(how: .area, what: .text)),
        ("captures.screenRecording", CaptureBox(how: .area, what: .record)),
    ]

    /// The mode `action` opens the box in; nil for an action that is not one of the six.
    public static func opening(_ action: String) -> CaptureBox? { binds.first { $0.action == action }?.opens }
}
