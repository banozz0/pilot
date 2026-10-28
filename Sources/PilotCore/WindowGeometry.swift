import Foundation
import CoreGraphics

/// A screen-relative placement: fractions of the visible frame. `place(0, 0.5)` is the left half.
public struct Placement: Sendable, Equatable {
    public var x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    public init(x: CGFloat = 0, y: CGFloat = 0, width: CGFloat, height: CGFloat = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let leftHalf = Placement(width: 0.5)
    public static let rightHalf = Placement(x: 0.5, width: 0.5)
    public static let topHalf = Placement(width: 1, height: 0.5)
    public static let bottomHalf = Placement(y: 0.5, width: 1, height: 0.5)
    public static let maximise = Placement(width: 1)
    public static let firstThreeQuarters = Placement(width: 0.75)
    public static let lastQuarter = Placement(x: 0.75, width: 0.25)
    public static let firstThird = Placement(width: 1 / 3)
    public static let middleThird = Placement(x: 1 / 3, width: 1 / 3)
    public static let lastThird = Placement(x: 2 / 3, width: 1 / 3)
    public static let firstTwoThirds = Placement(width: 2 / 3)
    public static let lastTwoThirds = Placement(x: 1 / 3, width: 2 / 3)
    public static let centre = Placement(x: 0.125, y: 0.1, width: 0.75, height: 0.8)

    /// The frame this placement is on a screen's visible frame (same coordinate space in, same out).
    public func frame(in visible: CGRect) -> CGRect {
        CGRect(x: visible.minX + visible.width * x, y: visible.minY + visible.height * y,
               width: visible.width * width, height: visible.height * height).integral
    }

    /// The placement a frame occupies on a screen, so it can be re-applied on another screen.
    public init(of frame: CGRect, in visible: CGRect) {
        x = (frame.minX - visible.minX) / visible.width
        y = (frame.minY - visible.minY) / visible.height
        width = frame.width / visible.width
        height = frame.height / visible.height
    }
}

public enum Direction: String, Sendable, CaseIterable {
    case left, right, up, down

    /// H J K L, the vim key for the direction.
    public var vimKey: String {
        switch self { case .left: "h"; case .down: "j"; case .up: "k"; case .right: "l" }
    }

    public var opposite: Direction {
        switch self { case .left: .right; case .right: .left; case .up: .down; case .down: .up }
    }
}

/// Pure geometry the Windows module runs on. Every rect here is in Accessibility coordinates:
/// origin at the top-left of the primary display, y grows downwards.
public enum WindowGeometry {
    /// AppKit's bottom-left frame to the AX top-left frame (and back: the conversion is its own inverse).
    public static func flip(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The nearest window in a direction, by centre. A window counts only if its centre is past the focused
    /// window's centre on that axis; off-axis distance is penalised so "left" prefers the window straight left.
    /// A window under the focused one (its frame covers the focused centre) is behind, not beside, and never counts.
    /// Candidates come front to back, so one whose centre lies inside a window listed before it is hidden and never
    /// counts either.
    public static func nearest<ID>(from focused: CGRect, in direction: Direction,
                                   among candidates: [(id: ID, frame: CGRect)]) -> ID? {
        let c = CGPoint(x: focused.midX, y: focused.midY)
        var best: (id: ID, score: CGFloat)?
        for (i, w) in candidates.enumerated() {
            if w.frame.contains(c) { continue }
            let p = CGPoint(x: w.frame.midX, y: w.frame.midY)
            if candidates[..<i].contains(where: { $0.frame.contains(p) }) { continue }
            let along: CGFloat, across: CGFloat
            switch direction {
            case .left: along = c.x - p.x; across = abs(p.y - c.y)
            case .right: along = p.x - c.x; across = abs(p.y - c.y)
            case .up: along = c.y - p.y; across = abs(p.x - c.x)
            case .down: along = p.y - c.y; across = abs(p.x - c.x)
            }
            guard along > 1 else { continue }
            let score = along + across * 2
            if best == nil || score < best!.score { best = (w.id, score) }
        }
        return best?.id
    }

    /// The index of the screen under a window's centre; nil when it is off every screen.
    public static func screen(holding frame: CGRect, among screens: [CGRect]) -> Int? {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        return screens.firstIndex { $0.contains(c) }
    }

    /// The display beside one in a direction, by centre; past the last one it wraps to the farthest the other way,
    /// as the tiler's `--wrap-around` does. Nil when no display lies on that axis.
    public static func screen(_ direction: Direction, from index: Int, among screens: [CGRect]) -> Int? {
        let others = screens.indices.filter { $0 != index }.map { (id: $0, frame: screens[$0]) }
        if let next = nearest(from: screens[index], in: direction, among: others) { return next }
        let behind = others.filter { nearest(from: screens[index], in: direction.opposite, among: [$0]) != nil }
        let distance: (CGRect) -> CGFloat = switch direction {
        case .left, .right: { abs($0.midX - screens[index].midX) }
        case .up, .down: { abs($0.midY - screens[index].midY) }
        }
        return behind.max { distance($0.frame) < distance($1.frame) }?.id
    }

    /// The smallest a resize by key or by mouse makes a window.
    public static let minimumSize = CGSize(width: 200, height: 150)

    /// Grows (positive) or shrinks (negative) a frame by a step on one axis, kept inside the visible frame.
    /// The top-left corner stays put unless the window would run off the screen.
    public static func resized(_ frame: CGRect, dw: CGFloat, dh: CGFloat, within visible: CGRect,
                               minimum: CGSize = minimumSize) -> CGRect {
        var r = frame
        r.size.width = min(max(frame.width + dw, minimum.width), visible.width)
        r.size.height = min(max(frame.height + dh, minimum.height), visible.height)
        if r.maxX > visible.maxX { r.origin.x = visible.maxX - r.width }
        if r.maxY > visible.maxY { r.origin.y = visible.maxY - r.height }
        if r.minX < visible.minX { r.origin.x = visible.minX }
        if r.minY < visible.minY { r.origin.y = visible.minY }
        return r.integral
    }

    /// The same placement on another screen: a left half stays a left half.
    public static func moved(_ frame: CGRect, from: CGRect, to: CGRect) -> CGRect {
        Placement(of: frame, in: from).frame(in: to)
    }
}
