// Pilot (Sven on build 21): Pilot's top bar is a hard edge. Tiled windows keep under it through the top gap
// (PilotSettings.swift); a floating window placed by its app, zoomed or filled, or dragged up there goes just under the
// bar once it settles: the same frame on two refreshes `BarEdge.settle` apart, the mouse up. A window it puts back is
// never fought frame by frame, and an app that puts its window back under the bar twice within `BarEdge.giveUp` keeps it
// there.
import AppKit
import PilotCore

extension MonitorInfo {
    /// The visible rect less the top bar, as Pilot's own placements have it (TopBarGeometry.belowBar).
    @MainActor var visibleRectBelowBar: Rect {
        TopBarGeometry.belowBar(visibleRect.cgRect, screen: rect.cgRect, bar: Double(config.topBar.getValue(for: self))).engineRect
    }
}

@MainActor
enum BarEdge {
    /// How long a window's frame holds before it counts as placed; tests shorten it.
    static var settle: Duration = .milliseconds(300)
    static let giveUp: Duration = .seconds(5)

    /// Each window seen under the bar: its frame and when it was first seen at it.
    private static var seen: [UInt32: (rect: Rect, at: ContinuousClock.Instant)] = [:]
    /// When each window was last put under the bar's edge.
    private static var moved: [UInt32: [ContinuousClock.Instant]] = [:]
    private static var recheck: Task<Void, Never>?

    /// Where a window at `rect` goes so none of it is under the bar at `edge`: just under it, its height cut to what fits
    /// above `bottom`; nil when it clears the edge already.
    nonisolated static func clamped(_ rect: Rect, edge: CGFloat, bottom: CGFloat) -> Rect? {
        guard rect.topLeftY < edge - 0.5 else { return nil }
        let height = min(rect.height, max(bottom - edge, 1))
        return Rect(topLeftX: rect.topLeftX, topLeftY: edge, width: rect.width, height: height)
    }

    /// The window at `rect` has held there since `settle` ago: it may move.
    static func settled(_ windowId: UInt32, _ rect: Rect, now: ContinuousClock.Instant = .now) -> Bool {
        if let last = seen[windowId], last.rect == rect { return now - last.at >= settle }
        seen[windowId] = (rect, now)
        // Another look once it has had time to settle; a test lays out again itself.
        guard !isUnitTest else { return false }
        recheck?.cancel()
        recheck = Task { @MainActor in
            try? await Task.sleep(for: settle + .milliseconds(20))
            guard !Task.isCancelled else { return }
            scheduleCancellableCompleteRefreshSession(.pilotCall("top bar edge"))
        }
        return false
    }

    /// One more move under the edge for this window, unless its app has put it back twice within `giveUp`.
    static func mayMove(_ windowId: UInt32, now: ContinuousClock.Instant = .now) -> Bool {
        let recent = (moved[windowId] ?? []).filter { now - $0 < giveUp }
        guard recent.count < 2 else {
            moved[windowId] = recent
            return false
        }
        moved[windowId] = recent + [now]
        return true
    }

    static func forget(_ windowId: UInt32) { seen[windowId] = nil }

    /// For the tests.
    static func reset() {
        (seen, moved) = ([:], [:])
        recheck?.cancel()
    }
}

extension Window {
    /// A floating window under the top bar on `monitor` goes just under it once it has settled there, the mouse up.
    @MainActor
    func keepBelowBar(_ rect: Rect, on monitor: any MonitorInfo) {
        let below = monitor.visibleRectBelowBar
        guard let to = BarEdge.clamped(rect, edge: below.topLeftY, bottom: below.maxY) else { return BarEdge.forget(windowId) }
        guard !isLeftMouseButtonDown, BarEdge.settled(windowId, rect), BarEdge.mayMove(windowId) else { return }
        BarEdge.forget(windowId)
        setAxFrame(to.topLeftCorner, to.height == rect.height ? nil : to.size)
    }
}
