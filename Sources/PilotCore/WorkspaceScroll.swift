/// Hyper+scroll steps through workspaces (Omarchy ideas T2, Q95): one mouse-wheel notch is one step, the wheel rolled
/// down (towards you) the next workspace and up the previous, whatever natural scrolling says. Only a discrete wheel
/// notch steps: a trackpad's or a smooth mouse's continuous scroll, its phases and its momentum give none, so a flick
/// never runs through every workspace. A fast spin's accelerated notch is still one step.
public enum WorkspaceScroll {
    public typealias Fire = WorkspaceSwipe.Fire

    /// One scroll-wheel event, as CGEvent's fields give it. `delta` is the vertical line delta (positive up, as the
    /// app sees it); `inverted` is natural scrolling, which flips that sign from the device's.
    public struct Event: Sendable {
        public var delta: Int64
        public var continuous: Bool
        public var phase: Int64
        public var momentumPhase: Int64
        public var inverted: Bool
        /// The vertical point delta, a continuous scroll's measure (Steps).
        public var points: Double

        public init(delta: Int64, continuous: Bool = false, phase: Int64 = 0, momentumPhase: Int64 = 0, inverted: Bool = false,
                    points: Double = 0) {
            self.delta = delta
            self.points = points
            self.continuous = continuous
            self.phase = phase
            self.momentumPhase = momentumPhase
            self.inverted = inverted
        }

        /// A notch that may step: discrete, no phase, no momentum, not zero. Read before `inverted`, which costs an
        /// NSEvent to learn.
        public var isNotch: Bool { !continuous && phase == 0 && momentumPhase == 0 && delta != 0 }
    }

    public static func step(_ e: Event) -> Fire? {
        guard e.isNotch else { return nil }
        let rolledUp = e.inverted ? e.delta < 0 : e.delta > 0
        return rolledUp ? .previous : .next
    }

    /// Steps for Hyper + scroll once it is bound (P51): a notch is one, as `step` reads it; a trackpad's or a smooth wheel's
    /// point deltas add up to one every `length` points, counted afresh as a gesture begins; a flick's momentum never steps.
    public struct Steps: Sendable {
        let length: Double
        private var carried: BarScroll.Steps

        public init(length: Double) { self.length = length; carried = BarScroll.Steps(points: length) }

        /// Counts afresh: a gesture begins, or a new Hyper hold, whose first step never starts part-way.
        public mutating func reset() { carried = BarScroll.Steps(points: length) }

        public mutating func step(_ e: Event) -> Fire? {
            guard e.momentumPhase == 0 else { return nil }
            if e.phase == Self.began { reset() }
            let n = carried.add((e.inverted ? -1 : 1) * (e.continuous ? e.points : Double(e.delta)), precise: e.continuous)
            return n > 0 ? .previous : n < 0 ? .next : nil
        }

        /// kCGScrollPhaseBegan.
        static let began: Int64 = 1
    }
}
