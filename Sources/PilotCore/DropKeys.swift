import Foundation

/// The bar drops' Escape and toggle rules (spec Bar drops T3, Q93; notes › Keys). In the terminal Escape belongs to the
/// shell: it always passes on, and a second within 0.4 s also closes the drop. Ask AI closes on one Escape, as before.
/// A drop's key toggles that drop alone; a click outside both hides both. The drop panel's local key monitor feeds it,
/// never the tap's callback, with the event's time; the panel shows what `open` says.
public struct DropKeys: Equatable, Sendable {
    public static let doubleEscape: TimeInterval = 0.4

    /// What an Escape does: whether the drop's view still gets the key, and the drop it closes.
    public struct Escape: Equatable, Sendable {
        public let passes: Bool
        public let closes: BarDropKind?

        public init(passes: Bool, closes: BarDropKind?) {
            self.passes = passes
            self.closes = closes
        }
    }

    public private(set) var open: Set<BarDropKind> = []
    /// The drop that has the keyboard.
    public private(set) var focused: BarDropKind?
    /// When the terminal's last Escape came, while no other key has come since.
    private var escapeAt: TimeInterval?

    public init() {}

    /// The focused drop's Escape at `time`.
    public mutating func escape(at time: TimeInterval) -> Escape {
        switch focused {
        case nil:
            return Escape(passes: true, closes: nil)
        case .askAI, .pill:
            let drop = focused!
            close(drop)
            return Escape(passes: false, closes: drop)
        case .terminal:
            if let escapeAt, time - escapeAt <= Self.doubleEscape {
                close(.terminal)
                return Escape(passes: true, closes: .terminal)
            }
            escapeAt = time
            return Escape(passes: true, closes: nil)
        }
    }

    /// Any other key in a drop: two Escapes with a key between are not a double.
    public mutating func typed() { escapeAt = nil }

    /// A drop's key: an open drop closes, the other keeping or taking the keyboard; a closed one opens beside any other
    /// and takes the keyboard.
    public mutating func toggle(_ drop: BarDropKind) {
        if open.contains(drop) { return close(drop) }
        // The pill is one open at a time: it closes the others as it opens, and they close it (spec desktop-controls).
        if drop == .pill { open = [] } else { open.remove(.pill) }
        open.insert(drop)
        focus(drop)
    }

    /// A click in an open drop gives it the keyboard.
    public mutating func click(in drop: BarDropKind) {
        if open.contains(drop) { focus(drop) }
    }

    /// A click outside both hides both.
    public mutating func clickOutside() {
        open = []
        focus(nil)
    }

    private mutating func close(_ drop: BarDropKind) {
        open.remove(drop)
        if focused == drop { focus(BarDropKind.allCases.first(where: open.contains)) }
    }

    private mutating func focus(_ drop: BarDropKind?) {
        if focused != drop { escapeAt = nil }
        focused = drop
    }
}
