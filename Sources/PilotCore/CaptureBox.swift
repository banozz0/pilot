import CoreGraphics
import Foundation

/// The capture box (pilot-ui-redesign S5 B, T23; changed by Sven 2026-11-20): Capture tool opens the capture overlay as
/// the box, and fixed letters pick the mode inside it (Q257), whatever keys the user's binds are on; each specific capture
/// bind captures at once in its own mode instead. Two choices make a mode: how much of the screen (`How`) and what the capture makes (`What`), with
/// a timer beside them. Return captures, Esc closes. A dragged area stays held with handles to adjust until Return
/// (shots 5c-*). This is the box's state and the held area's geometry alone; the overlay keeps them and T24's view draws them.
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

    /// The six capture binds and the mode each captures in at once, in the key sheet's order (S5 B): its left column joins
    /// these with the user's keys from the bind store, an unset one shown as "no key".
    public static let binds: [(action: String, opens: CaptureBox)] = [
        ("captures.area", CaptureBox(how: .area)),
        ("captures.activeWindow", CaptureBox(how: .window)),
        ("captures.fullscreen", CaptureBox(how: .full)),
        ("captures.scrolling", CaptureBox(how: .scroll)),
        ("captures.ocr", CaptureBox(how: .area, what: .text)),
        ("captures.screenRecording", CaptureBox(how: .area, what: .record)),
    ]

    // MARK: The bar's parts

    /// What a click on the bar lands on (Sven, 2026-11-20: "select which type from the toolbar and then press return"):
    /// one of How's or What's choices, the timer, the action button, or Esc's Close.
    public enum Part: Hashable, Sendable { case how(How), what(What), timer, action, close }

    /// The letter a click on `part` presses, so a click picks as its letter does; nil for a choice already picked (a
    /// click picks, it never turns one off) and for the action and Close, which act as Return and Esc. Photo has no
    /// letter: a click on it presses the letter of the Record or Text it goes back from.
    public func letter(for part: Part) -> Letter? {
        switch part {
        case .how(let picked): picked == how ? nil : picked.letter
        case .what(let picked): picked == what ? nil : picked.letter ?? what.letter
        case .timer: .timer
        case .action, .close: nil
        }
    }

    // MARK: The bar's place

    /// Where the box's bar of `size` goes in `bounds` (Sven, 2026-11-20): centred just under `area` and kept on the
    /// display, above it when there is no room below, and inside the display's foot only when neither fits (an area
    /// that fills the screen's height) or there is no area: Full, Window and an Area not yet dragged. In a flipped view,
    /// whole points; `gap` clears the area's middle handle.
    public static func barFrame(_ size: CGSize, under area: CGRect?, within bounds: CGRect, gap: CGFloat = 14,
                                margin: CGFloat = 8, foot: CGFloat = 26) -> CGRect {
        let footing = CGRect(x: (bounds.midX - size.width / 2).rounded(), y: bounds.maxY - size.height - foot, width: size.width, height: size.height)
        guard let area, !area.isEmpty else { return footing }
        let x = min(max((area.midX - size.width / 2).rounded(), bounds.minX + margin), bounds.maxX - margin - size.width)
        let below = (area.maxY + gap).rounded(), above = (area.minY - gap - size.height).rounded()
        if below + size.height <= bounds.maxY - margin { return CGRect(x: x, y: below, width: size.width, height: size.height) }
        if above >= bounds.minY + margin { return CGRect(x: x, y: above, width: size.width, height: size.height) }
        return CGRect(x: x, y: footing.minY, width: size.width, height: size.height)
    }

    // MARK: The held area

    /// What a press on a held area takes hold of (shots 5c-area, 5c-scroll): one of its eight handles, or the area itself
    /// to move it. In a flipped view, as the overlay's points are: top is the smaller y.
    public enum Grip: CaseIterable, Equatable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

        /// Where this handle sits on `rect`; nil for Move.
        public func point(on rect: CGRect) -> CGPoint? {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .top: CGPoint(x: rect.midX, y: rect.minY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .right: CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .left: CGPoint(x: rect.minX, y: rect.midY)
            case .move: nil
            }
        }

        /// The eight handles, Move left out.
        public static let handles = allCases.filter { $0 != .move }
    }

    /// The handle within `reach` of `point`, else Move inside `rect`, else nil: a press outside starts a new area.
    public static func grip(at point: CGPoint, of rect: CGRect, reach: CGFloat = 8) -> Grip? {
        if let handle = Grip.handles.first(where: { $0.point(on: rect).map { abs($0.x - point.x) <= reach && abs($0.y - point.y) <= reach } ?? false }) {
            return handle
        }
        return rect.contains(point) ? .move : nil
    }

    /// `rect` with `grip` dragged from `start` to `point`, in whole points inside `bounds`: Move slides it whole, kept on
    /// the display; a handle moves its edges, an edge dragged past the opposite one turning the area over.
    public static func adjusted(_ rect: CGRect, _ grip: Grip, from start: CGPoint, to point: CGPoint, within bounds: CGRect) -> CGRect {
        let dx = point.x - start.x, dy = point.y - start.y
        if grip == .move {
            let x = min(max(rect.minX + dx, bounds.minX), bounds.maxX - rect.width)
            let y = min(max(rect.minY + dy, bounds.minY), bounds.maxY - rect.height)
            return CGRect(x: x, y: y, width: rect.width, height: rect.height).integral
        }
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        if [.topLeft, .left, .bottomLeft].contains(grip) { left += dx }
        if [.topRight, .right, .bottomRight].contains(grip) { right += dx }
        if [.topLeft, .top, .topRight].contains(grip) { top += dy }
        if [.bottomLeft, .bottom, .bottomRight].contains(grip) { bottom += dy }
        let x0 = min(max(min(left, right), bounds.minX), bounds.maxX), x1 = min(max(max(left, right), bounds.minX), bounds.maxX)
        let y0 = min(max(min(top, bottom), bounds.minY), bounds.maxY), y1 = min(max(max(top, bottom), bounds.minY), bounds.maxY)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).integral
    }
}

extension CaptureBox.How {
    /// The letter that picks it.
    public var letter: CaptureBox.Letter {
        switch self {
        case .area: .area
        case .window: .window
        case .full: .full
        case .scroll: .scroll
        }
    }
}

extension CaptureBox.What {
    /// The letter that picks it; Photo has none: R or O again goes back to it.
    public var letter: CaptureBox.Letter? {
        switch self {
        case .photo: nil
        case .record: .record
        case .text: .text
        }
    }
}
