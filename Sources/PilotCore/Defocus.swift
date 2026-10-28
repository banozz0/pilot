import Foundation

/// Defocus (card agent-bo-95423220, story 138, ADR 0009; idea from defocus.me): everything but the focused window blurred and
/// dimmed, toggled by a mouse shake or a bind. The overlay itself is Pilot's DefocusController; this decides the look.
public enum Defocus {
    public static let actionID = "windows.defocus"
    /// Hyper+Alt+D: free in My binds and Pilot default.
    public static let defaultKey = Key("d", .alt)

    /// The blur, Off (0) then 1 light to 5 heavy, and the dim, a percent of black from Off (0) to 80 (Sven, 2026-10-16:
    /// "set another setting to dim the background as well"): either alone, or both.
    public static let strengths = 0...5
    public static let defaultStrength = 3
    public static func clamped(_ strength: Int) -> Int { min(max(strength, strengths.lowerBound), strengths.upperBound) }
    public static let dims = 0...80
    public static func clamped(dim: Int) -> Int { min(max(dim, dims.lowerBound), dims.upperBound) }
    /// The dim each strength carried before the split, so a saved strength keeps its look until the dim is moved.
    public static func dim(strength: Int) -> Int { [10, 14, 18, 22, 26][max(clamped(strength), 1) - 1] }
    public static let defaultDim = dim(strength: defaultStrength)

    /// The window server's background blur radius (0 is none) and the black laid over it, 0 to 1.
    public struct Look: Equatable, Sendable {
        public var blurRadius: Int, dim: Double
        public init(blurRadius: Int, dim: Double) { self.blurRadius = blurRadius; self.dim = dim }
    }

    /// One per strength, light to heavy.
    private static let radii = [8, 14, 20, 28, 36]
    /// With Reduce Transparency there is no blur, so the dim stands in for it, a step darker.
    private static let reducedExtraDim = 0.10

    /// The look for a blur strength and a dim in percent; nil when both are off, and Defocus has nothing to do.
    public static func look(strength: Int, dim: Int, reduceTransparency: Bool) -> Look? {
        let strength = clamped(strength), dim = Double(clamped(dim: dim)) / 100
        guard strength > 0 || dim > 0 else { return nil }
        guard strength > 0 else { return Look(blurRadius: 0, dim: dim) }
        return reduceTransparency ? Look(blurRadius: 0, dim: dim + reducedExtraDim) : Look(blurRadius: radii[strength - 1], dim: dim)
    }

    /// What Defocus does as set, the first words of Look's hint.
    public static func summary(strength: Int, dim: Int) -> String {
        switch (clamped(strength) > 0, clamped(dim: dim) > 0) {
        case (true, true): "Blurs and dims every other window."
        case (true, false): "Blurs every other window."
        case (false, true): "Dims every other window."
        case (false, false): "Blur and Dim are both off, so Defocus has nothing to do."
        }
    }

    /// The tip windows.defocus or a shake gives while Blur and Dim are both off.
    public static let nothingToDo = "Defocus has nothing to do: Blur and Dim are both off on the Look page."

    /// What sets it off, as Look says it: the shake while its switch is on, and windows.defocus's key as bound now, or a
    /// nudge to bind one.
    public static func hint(key: Key?, shake: Bool) -> String {
        switch (shake, key) {
        case (true, let key?): "Shake the mouse or press \(key.label)"
        case (true, nil): "Shake the mouse, or bind a key in Binds"
        case (false, let key?): "Press \(key.label)"
        case (false, nil): "Bind a key in Binds to turn it on"
        }
    }

    /// Whether `window` is one to keep sharp with the rest blurred: a standard window, neither minimised nor fullscreen
    /// (a fullscreen window has its own Space and nothing beside it to blur). Otherwise the blur waits, hidden.
    public static func keepsSharp(_ window: WindowBorder.Window?) -> Bool {
        guard let window else { return false }
        return !window.minimised && !window.fullScreen && window.subrole == "AXStandardWindow"
    }
}

/// A mouse shake from the stream of mouse moves: `swings` direction changes within `within` seconds, each stroke before
/// one at least `minStroke` points sideways and mostly sideways (vertical travel at most `maxTilt` of it). A pause over
/// `pause` starts over, and after a shake the detector rests for `cooldown`, so one shake is one toggle. A scroll or a
/// gesture starts over too, and moves count again only `scrollQuiet` after the last of it: on a trackpad or
/// Magic Mouse the pointer drifts sideways while the fingers scroll.
public struct ShakeDetector: Sendable {
    /// Look's Swings needed and Within (C2, 2026-10-09): five swings by default, a step stricter than the four it took.
    public static let swingsRange = 3...8
    public static let defaultSwings = 5
    public static let withinRange: ClosedRange<TimeInterval> = 0.4...1.5
    public static let defaultWithin: TimeInterval = 0.7
    public static func clamped(swings: Int) -> Int { min(max(swings, swingsRange.lowerBound), swingsRange.upperBound) }
    /// To the range and to a tenth, so Look's stepper never saves 0.7999999.
    public static func clamped(within: TimeInterval) -> TimeInterval {
        (min(max(within, withinRange.lowerBound), withinRange.upperBound) * 10).rounded() / 10
    }
    public static let minStroke = 40.0
    public static let maxTilt = 0.5
    public static let pause: TimeInterval = 0.2
    public static let cooldown: TimeInterval = 1.0
    public static let scrollQuiet: TimeInterval = 0.4

    public var swings: Int
    public var within: TimeInterval
    private var direction = 0.0
    private var stroke = 0.0
    private var tilt = 0.0
    private var last: TimeInterval?
    private var turns: [TimeInterval] = []
    private var restUntil: TimeInterval = -.infinity

    public init(swings: Int = defaultSwings, within: TimeInterval = defaultWithin) {
        self.swings = swings
        self.within = within
    }

    /// A scroll or gesture event at `t`: what was building is dropped, and moves wait until it has been quiet a while.
    public mutating func scroll(at t: TimeInterval) {
        reset()
        restUntil = max(restUntil, t + Self.scrollQuiet)
    }

    /// One mouse move of `dx`, `dy` points (the event's delta, so a pointer pinned at a screen edge still counts) at `t`
    /// seconds; true on the move that completes a shake.
    public mutating func move(dx: Double, dy: Double, at t: TimeInterval) -> Bool {
        defer { last = t }
        guard t >= restUntil else { return false }
        if last.map({ t - $0 > Self.pause }) == true { reset() }
        let sign: Double = dx > 0 ? 1 : dx < 0 ? -1 : direction
        if sign == direction {
            stroke += abs(dx)
            tilt += abs(dy)
            return false
        }
        if direction != 0 {
            if stroke >= Self.minStroke, tilt <= stroke * Self.maxTilt {
                turns.append(t)
                turns.removeAll { t - $0 > within }
            } else {
                turns.removeAll()
            }
        }
        direction = sign
        stroke = abs(dx)
        tilt = abs(dy)
        guard turns.count >= swings else { return false }
        reset()
        restUntil = t + Self.cooldown
        return true
    }

    private mutating func reset() {
        direction = 0
        stroke = 0
        tilt = 0
        turns.removeAll()
    }
}
