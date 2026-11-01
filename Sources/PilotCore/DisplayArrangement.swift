import CoreGraphics

/// Moving one screen beside another in macOS's arrangement (Sven 2026-10-30, Setup › Displays): the geometry alone, so the
/// origins are proven without moving a real screen. Frames are CoreGraphics's global space: points, the top-left corner
/// the origin, y growing down, the main display at (0, 0).
public enum DisplayArrangement {
    public enum Side: String, CaseIterable, Sendable {
        case left, right, above, below

        /// "left of", "above": how the move reads before the other screen's name.
        public var words: String {
            switch self {
            case .left: "left of"
            case .right: "right of"
            case .above: "above"
            case .below: "below"
            }
        }
    }

    /// Every screen's origin once `moving` sits on `side` of `anchor`, centred along the edge they share and rounded to
    /// whole points, as CGConfigureDisplayOrigin takes them; all shifted so `main` stays at (0, 0), as macOS keeps it. Nil
    /// when either screen is missing, they are the same, or the moved screen would overlap a third.
    public static func origins(_ frames: [CGDirectDisplayID: CGRect], moving: CGDirectDisplayID, beside anchor: CGDirectDisplayID,
                               side: Side, main: CGDirectDisplayID) -> [CGDirectDisplayID: CGPoint]? {
        guard moving != anchor, let m = frames[moving], let a = frames[anchor] else { return nil }
        let origin = switch side {
        case .left: CGPoint(x: a.minX - m.width, y: a.midY - m.height / 2)
        case .right: CGPoint(x: a.maxX, y: a.midY - m.height / 2)
        case .above: CGPoint(x: a.midX - m.width / 2, y: a.minY - m.height)
        case .below: CGPoint(x: a.midX - m.width / 2, y: a.maxY)
        }
        return arranged(frames, moving: moving, at: CGRect(origin: origin, size: m.size), main: main)
    }

    /// Where a screen dragged in the picture and dropped at `dropped` lands (Sven 2026-10-31): against the nearest edge
    /// of another screen it can touch without covering a third, keeping where it was dropped along that edge but sharing
    /// at least an eighth of it, and lining up with the other's top, middle or bottom (left, middle or right) when it is
    /// dropped within 6 % of that. Nil when no edge is free.
    public static func snapped(_ frames: [CGDirectDisplayID: CGRect], moving: CGDirectDisplayID, to dropped: CGRect,
                               main: CGDirectDisplayID) -> (anchor: CGDirectDisplayID, side: Side, origins: [CGDirectDisplayID: CGPoint])? {
        guard let m = frames[moving] else { return nil }
        var best: (distance: CGFloat, anchor: CGDirectDisplayID, side: Side, origins: [CGDirectDisplayID: CGPoint])?
        for (id, a) in frames where id != moving {
            for side in Side.allCases {
                let across = side == .left || side == .right
                let length = across ? m.height : m.width, edge = across ? a.height : a.width, start = across ? a.minY : a.minX
                let keep = min(length, edge) / 8, tolerance = max(length, edge) * 0.06
                var along = min(max(across ? dropped.minY : dropped.minX, start - length + keep), start + edge - keep)
                if let lined = [start, start + (edge - length) / 2, start + edge - length].min(by: { abs($0 - along) < abs($1 - along) }),
                   abs(lined - along) <= tolerance { along = lined }
                let origin = switch side {
                case .left: CGPoint(x: a.minX - m.width, y: along)
                case .right: CGPoint(x: a.maxX, y: along)
                case .above: CGPoint(x: along, y: a.minY - m.height)
                case .below: CGPoint(x: along, y: a.maxY)
                }
                let distance = hypot(origin.x - dropped.minX, origin.y - dropped.minY)
                guard distance < best?.distance ?? .infinity,
                      let origins = arranged(frames, moving: moving, at: CGRect(origin: origin, size: m.size), main: main) else { continue }
                best = (distance, id, side, origins)
            }
        }
        return best.map { ($0.anchor, $0.side, $0.origins) }
    }

    /// Every screen's origin with `moving` at `placed`, rounded to whole points, as CGConfigureDisplayOrigin takes them; all
    /// shifted so `main` stays at (0, 0), as macOS keeps it. Nil when it would cover another screen: edges may touch.
    private static func arranged(_ frames: [CGDirectDisplayID: CGRect], moving: CGDirectDisplayID, at placed: CGRect,
                                 main: CGDirectDisplayID) -> [CGDirectDisplayID: CGPoint]? {
        let placed = CGRect(origin: CGPoint(x: placed.minX.rounded(), y: placed.minY.rounded()), size: placed.size)
        let overlaps = frames.contains { id, frame in
            let shared = frame.intersection(placed)
            return id != moving && shared.width > 0 && shared.height > 0
        }
        guard !overlaps else { return nil }
        var moved = frames
        moved[moving] = placed
        let shift = moved[main]?.origin ?? .zero
        return moved.mapValues { CGPoint(x: $0.minX - shift.x, y: $0.minY - shift.y) }
    }

    /// The side of `anchor` the screen at `frame` sits on now, left and right before above and below; nil when they
    /// overlap.
    public static func side(of frame: CGRect, from anchor: CGRect) -> Side? {
        if frame.maxX <= anchor.minX { return .left }
        if frame.minX >= anchor.maxX { return .right }
        if frame.maxY <= anchor.minY { return .above }
        if frame.minY >= anchor.maxY { return .below }
        return nil
    }
}
