/// A three-finger sideways swipe on a trackpad moves to the next or previous workspace (card agent-bo-95422973;
/// the shape SwipeAeroSpace, MIT, https://github.com/MediosZ/SwipeAeroSpace, uses). Fed one frame per gesture event: the
/// touching fingers' normalised x (0 at the trackpad's left edge, 1 at its right). Exactly three touches start a swipe
/// at their average x; once the average has moved `threshold` of the width it fires once, fingers moving left meaning
/// the next workspace and right the previous, as macOS's natural swipe between Spaces. Any other count ends the swipe,
/// so a fourth finger, a lift or a two-finger scroll never fires and one swipe fires at most once.
public struct WorkspaceSwipe: Sendable {
    public enum Fire: Equatable, Sendable { case next, previous }

    public static let threshold = 0.15

    private enum State { case idle, tracking(start: Double), fired }
    private var state = State.idle

    public init() {}

    public mutating func frame(_ xs: [Double]) -> Fire? {
        guard xs.count == 3 else { state = .idle; return nil }
        let x = xs.reduce(0, +) / 3
        switch state {
        case .idle:
            state = .tracking(start: x)
        case .tracking(let start):
            let moved = x - start
            guard abs(moved) >= Self.threshold else { return nil }
            state = .fired
            return moved < 0 ? .next : .previous
        case .fired:
            break
        }
        return nil
    }
}
