import AppKit

// Pilot's gap resize (card agent-bo-95423035): the inner gap between two tiles is a handle. After each layout Pilot gets
// every inner gap the visible workspaces have (TilerGaps) and lays a see-through panel over each, which shows the resize
// cursor and takes the press, so a mouse move costs the engine nothing. The drag hands weight from one tile to the other:
// their sum, and so layout's shared delta, stays put, and the split moves exactly as far as the mouse.

/// The inner gap between children `index` and `index + 1` of a tiles container, as it was last laid out.
struct InnerGap {
    let container: TilingContainer
    let index: Int
    let orientation: Orientation
    let tiles: (TreeNode, TreeNode)
    let rect: Rect

    /// Whether the tree still holds the two tiles side by side as they were laid out.
    @MainActor var isCurrent: Bool {
        container.orientation == orientation && container.layout == .tiles && container.children.count > index + 1
            && container.children[index] === tiles.0 && container.children[index + 1] === tiles.1
    }
}

/// Every inner gap of `workspace`'s tiles containers, read off the last layout only (no AX). A tile not laid out (dragged,
/// fullscreen) has no gaps, and a scrolling strip none between its columns (they keep their own widths); its stacks do.
@MainActor
func innerGaps(of workspace: Workspace) -> [InnerGap] {
    var gaps: [InnerGap] = []
    func collect(_ container: TilingContainer) {
        if container.layout == .scrolling {
            for case let child as TilingContainer in container.children { collect(child) }
            return
        }
        guard let frame = container.lastAppliedLayoutPhysicalRect else { return }
        let children = container.children, orientation = container.orientation
        for (index, (a, b)) in zip(children, children.dropFirst()).enumerated() {
            guard let ra = a.lastAppliedLayoutPhysicalRect, let rb = b.lastAppliedLayoutPhysicalRect else { continue }
            let rect = orientation == .h
                ? Rect(topLeftX: ra.maxX, topLeftY: frame.minY, width: rb.minX - ra.maxX, height: frame.height)
                : Rect(topLeftX: frame.minX, topLeftY: ra.maxY, width: frame.width, height: rb.minY - ra.maxY)
            if rect.width > 0 && rect.height > 0 { gaps.append(InnerGap(container: container, index: index, orientation: orientation, tiles: (a, b), rect: rect)) }
        }
        for case let child as TilingContainer in children { collect(child) }
    }
    if let root = try? workspace.rootTilingContainer { collect(root) }
    return gaps
}

/// The inner gap under `point` on the workspace its monitor shows; nil inside a tile or on an outer gap.
@MainActor
func innerGap(at point: CGPoint) -> InnerGap? {
    innerGaps(of: point.monitorApproximation.activeWorkspace).first { $0.rect.contains(point) }
}

/// A gap held by the mouse: where the press was, and the two tiles' weights then.
struct GapDrag {
    /// The narrowest a tile gets, its gap left out.
    static let minimumTile: CGFloat = 100

    let gap: InnerGap
    let start: CGPoint
    let weights: (CGFloat, CGFloat)

    /// The two weights with the split moved `distance` along the container: what one gains the other loses, as far as
    /// either can go and stay `minimumTile` wide.
    func weights(movedBy distance: CGFloat) -> (CGFloat, CGFloat) {
        let least = Self.minimumTile + gap.rect.getDimension(gap.orientation), total = weights.0 + weights.1
        let first = (weights.0 + distance).coerce(in: least ... max(least, total - least))
        return (first, total - first)
    }
}

/// The gap the mouse holds, from the press to the release; layout jumps while it is held (LayoutContext.glides).
@MainActor var gapDrag: GapDrag? = nil

/// The press at the mouse: holds the inner gap under it, if any.
@MainActor
func pressGap() -> Bool {
    let point = mouseLocation
    guard let gap = innerGap(at: point), let a = try? gap.tiles.0.getWeight(gap.orientation),
          let b = try? gap.tiles.1.getWeight(gap.orientation) else { return false }
    gapDrag = GapDrag(gap: gap, start: point, weights: (a, b))
    return true
}

/// The held gap's split at `point`, in the tree; the next layout puts it on screen. A tree that no longer holds the two
/// tiles side by side (one closed or moved) ends the drag.
@MainActor
func moveGap(to point: CGPoint = mouseLocation) throws {
    guard let drag = gapDrag else { return }
    let gap = drag.gap
    guard gap.isCurrent else { return gapDrag = nil }
    let (a, b) = drag.weights(movedBy: point.getProjection(gap.orientation) - drag.start.getProjection(gap.orientation))
    try gap.tiles.0.setWeight(gap.orientation, a)
    try gap.tiles.1.setWeight(gap.orientation, b)
}

@MainActor
func releaseGap() { gapDrag = nil }

/// Hands Pilot the visible workspaces' inner gaps when they changed since the last time, none while the engine is off. A
/// held gap's handles stay where they were until the release: the press's handle keeps the drag wherever it is.
@MainActor
func publishGaps() {
    guard gapDrag == nil else { return }
    let gaps = !isTilerEnabled ? [] : monitorInfos.flatMap { innerGaps(of: $0.activeWorkspace) }
        .map { TilerGap(frame: $0.rect.appKitFrame, vertical: $0.orientation == .h) }
    guard gaps != TilerGaps.shown else { return }
    TilerGaps.shown = gaps
    TilerGaps.show(gaps)
}

/// An inner gap Pilot lays a handle over: `frame` in AppKit coordinates; `vertical` when its tiles sit side by side, so it
/// resizes left and right.
public struct TilerGap: Equatable, Sendable {
    public let frame: NSRect
    public let vertical: Bool

    public init(frame: NSRect, vertical: Bool) {
        self.frame = frame
        self.vertical = vertical
    }
}

/// Pilot's side of the gap resize: `show` gets the gaps after each layout that changed them ([] once the engine stops),
/// and a gap's handle reports its press, drags and release, all at the mouse.
public enum TilerGaps {
    @MainActor public static var show: @MainActor ([TilerGap]) -> Void = { _ in }
    @MainActor static var shown: [TilerGap] = []

    /// Holds the gap under the mouse; false when there is none (the handle is stale) or the engine is off.
    @MainActor
    public static func press() -> Bool {
        guard isTilerEnabled else { return false }
        released = false
        return pressGap()
    }

    @MainActor public static func drag() { layInASession() }

    @MainActor
    public static func release() {
        guard gapDrag != nil else { return }
        released = true
        layInASession()
    }

    @MainActor private static let sessions = SessionsInTurn()
    @MainActor private static var released = false

    /// Lays the split at the mouse in a light session of its own: a move meanwhile is laid once it ends, and the release,
    /// once the last move is laid, ends the drag with a complete refresh.
    @MainActor
    private static func layInASession() {
        guard gapDrag != nil, RunSessionGuard.isServerEnabled != nil else { return }
        sessions.run({ try await runLightSession(.gapResize, .forceRun) { try moveGap() } }) { missed in
            if missed { return layInASession() }
            guard released else { return }
            released = false
            releaseGap()
            scheduleCancellableCompleteRefreshSession(.gapResize)
        }
    }
}
