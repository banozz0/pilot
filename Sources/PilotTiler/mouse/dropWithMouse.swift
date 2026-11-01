import AppKit
import PilotCore

// Pilot's drag (card agent-bo-95422997, AC5; cards agent-bo-95422860 and agent-bo-95422861 at the source): AeroSpace moved
// a dragged tiled window in the tree on every AX move event, so it could cross to another monitor mid-drag and land on
// whichever side the last event left it. Here the tree waits for the release, then places it once.

/// The tiled window being dragged: the tree keeps it where it was, and layout skips it until the mouse is released. Its
/// drop zone shows from the start and goes whenever the drag ends (card agent-bo-95423032).
@MainActor var draggedWindowId: UInt32? = nil { didSet { updateDropZone() } }

@MainActor
func startDrag(_ window: Window) {
    guard window.parent is TilingContainer else { return }
    draggedWindowId = window.windowId
    currentlyManipulatedWithMouseWindowId = window.windowId
    window.lastAppliedLayoutPhysicalRect = nil
}

/// What a release at a point does with the dragged window, decided once for the drop and its preview (dropLanding).
enum DropPlan {
    /// An auto workspace rebuilt in the slot its layout has under the point (PilotCore's dropOrder); `tiled` is its order now.
    case arrange(Workspace, WorkspaceArrangement, tiled: [UInt32])
    /// Another workspace: AeroSpace's rule, bound beside the window under the point, on the side of the point.
    case insert(TilingContainer, index: Int)
    /// Its own workspace: AeroSpace's rule, swapped with the window under the point.
    case swap(Window)
}

/// The plan for `window` released at `point`; nil when the release leaves it where it is.
@MainActor
func dropPlan(_ window: Window, at point: CGPoint) throws -> DropPlan? {
    let target = point.monitorApproximation.activeWorkspace
    let root = try target.rootTilingContainer
    if var kept = arrangements[target.name], kept.auto {
        let tiled = root.allLeafWindowsRecursive.map(\.windowId)
        kept.order = kept.order(dropping: window.windowId, at: point, among: tiled, in: target.workspaceMonitor.visibleRectPaddedByOuterGaps,
                                columns: kept.columnFrames(tiled))
        return .arrange(target, kept, tiled: tiled)
    }
    let under = try point.findWindowRecursively(in: root, virtual: false).flatMap { $0 == window ? nil : $0 }
    guard target != window.nodeWorkspace else { return under.map { .swap($0) } }
    guard let under, let parent = under.parent as? TilingContainer, let rect = under.lastAppliedLayoutPhysicalRect, let own = try under.ownIndex else {
        return .insert((under?.parent as? TilingContainer) ?? root, index: 0)
    }
    return .insert(parent, index: point.isPastCentre(of: rect, along: parent.orientation) ? own + 1 : own)
}

extension WorkspaceArrangement {
    /// The order this auto workspace takes with `window` dropped at `point`: PilotCore's dropOrder over its tiled windows.
    /// A strip or a stage goes by its x instead, over `columns`, the frames its windows have on screen: a hidden column
    /// or a shelved window has none and is never the one dropped beside.
    func order(dropping window: UInt32, at point: CGPoint, among tiled: [UInt32], in area: Rect, columns: [UInt32: Rect]) -> [UInt32] {
        let others = tiled.filter { $0 != window }.map(Int.init)
        let order = dropsByFrame
            ? LayoutPreset.dropOrder(others, inserting: Int(window), at: point, slots: others.map { columns[UInt32($0)].map { ($0.cgRect, false) } })
            : preset.dropOrder(others, inserting: Int(window), at: point, in: area.cgRect)
        return order.map { UInt32($0) }
    }
}

extension WorkspaceArrangement {
    /// On a strip or a stage, each of `tiled`'s frames from the last layout, what its drop reads; nothing for any other preset.
    @MainActor
    func columnFrames(_ tiled: [UInt32]) -> [UInt32: Rect] {
        guard dropsByFrame else { return [:] }
        return tiled.reduce(into: [:]) { frames, id in frames[id] = Window.get(byId: id)?.lastAppliedLayoutPhysicalRect }
    }

    /// A strip or a stage: some of its windows are off screen, so a drop goes by the frames on screen, not the preset's slots.
    private var dropsByFrame: Bool { preset == .scrolling || preset == .stage }
}

extension CGPoint {
    /// AeroSpace's side rule: a drop at or past the centre of the window under it goes after that window.
    func isPastCentre(of rect: Rect, along orientation: Orientation) -> Bool {
        getProjection(orientation) >= rect.center.getProjection(orientation)
    }
}

/// The release: the dragged window lands as `dropPlan` says, the auto workspace rebuilt. A live swap's preview under the
/// release is that drop already; any other is put back first (card agent-bo-95423034, AC2).
@MainActor
func dropDraggedWindow(at point: CGPoint) throws {
    guard let id = draggedWindowId else { return }
    draggedWindowId = nil
    if dragPreview?.zone(point) == true { return dragPreview = nil }
    try endPreview {
        guard let window = Window.get(byId: id), window.parent is TilingContainer, let plan = try dropPlan(window, at: point) else { return }
        try land(window, plan)
    }
}

/// Binds `window` where `plan` says: the release, and the live swap's preview of it.
@MainActor
func land(_ window: Window, _ plan: DropPlan) throws {
    switch plan {
        case .arrange(let target, let kept, _):
            try window.bind(to: target.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            try target.arrange(kept)
        case .insert(let parent, let index): try window.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: index)
        case .swap(let under): try swapWindows(mruDominant: window, under)
    }
}

/// Pilot's drop-zone overlay (card agent-bo-95423032): Pilot sets `show`, which draws `frame` (AppKit coordinates) just
/// below window `below`, the one being dragged; nil hides it.
public enum TilerDropZone {
    @MainActor public static var show: @MainActor (_ frame: NSRect?, _ below: UInt32?) -> Void = { _, _ in }
    @MainActor fileprivate static var shown: Rect?
}

/// Each move of the dragged window, and the drag's start and end: the overlay at the frame a drop under the mouse would
/// give it (the live swap's landing while one is on show), hidden once nothing is dragged; that frame is returned. An
/// unchanged frame is not redrawn.
@MainActor
@discardableResult
func updateDropZone() -> Rect? {
    let frame = draggedWindowId == nil ? nil : dragPreview?.landing ?? (try? dropLanding(at: mouseLocation)) ?? nil
    guard frame != TilerDropZone.shown else { return frame }
    TilerDropZone.shown = frame
    TilerDropZone.show(frame?.appKitFrame, draggedWindowId)
    return frame
}

/// The frame the dragged window would land in if released at `point`, as `dropPlan` places it and layout then frames it,
/// read from the last layout with no AX call; nil when the drop leaves it where it was.
@MainActor
func dropLanding(at point: CGPoint) throws -> Rect? {
    guard let id = draggedWindowId, let window = Window.get(byId: id), window.parent is TilingContainer,
          let plan = try dropPlan(window, at: point) else { return nil }
    return try landing(of: plan, for: window)
}

/// The frame `plan` lands `window` in, from the last layout; nil when it leaves the window where it was.
@MainActor
func landing(of plan: DropPlan, for window: Window) throws -> Rect? {
    switch plan {
        case .arrange(let target, let kept, let tiled):
            if target == window.nodeWorkspace && kept.order == tiled { return nil }
            guard let slot = kept.order.firstIndex(of: window.windowId) else { return nil }
            if kept.preset == .stage { return try target.rootTilingContainer.stageLanding(of: window, at: nil, on: target.workspaceMonitor) }
            if kept.preset == .scrolling {
                let others = kept.order.filter { $0 != window.windowId }.compactMap(Window.get(byId:))
                return try target.rootTilingContainer.stripLanding(of: window, at: slot, among: others, on: target.workspaceMonitor)
            }
            let area = target.workspaceMonitor.visibleRectPaddedByOuterGaps
            let frame = try target.rootTilingContainer.lastAppliedLayoutPhysicalRect ?? area
            let inner = ResolvedGaps(gaps: config.gaps, monitor: target.workspaceMonitor).inner
            return kept.preset.tiles(kept.order.count, in: frame.cgRect)[slot].engineRect.inset(within: frame, by: inner)
        case .insert(let parent, let index):
            guard let target = parent.nodeWorkspace else { return nil }
            if parent.layout == .stage { return parent.stageLanding(of: window, at: index, on: target.workspaceMonitor) }
            if parent.layout == .scrolling { return parent.stripLanding(of: window, at: index, among: parent.children, on: target.workspaceMonitor) }
            return try parent.insertedFrame(at: index, gaps: ResolvedGaps(gaps: config.gaps, monitor: target.workspaceMonitor))
                ?? target.workspaceMonitor.visibleRectPaddedByOuterGaps
        case .swap(let under): return under.lastAppliedLayoutPhysicalRect
    }
}

extension TilingContainer {
    /// The frame layout gives a window bound here at `index` with WEIGHT_AUTO (the average of its siblings' weights),
    /// from this container's last frame: nil before its first layout. As layoutTiles does, every weight then gains one
    /// shared delta so they fill the container, and the inner gap comes off each side another tile meets.
    @MainActor
    fileprivate func insertedFrame(at index: Int, gaps: ResolvedGaps) throws -> Rect? {
        guard let frame = lastAppliedLayoutPhysicalRect else { return nil }
        if children.isEmpty { return frame }
        let weights = try children.map { try $0.getWeight(orientation) }
        let sum = weights.reduce(0, +), added = sum / CGFloat(children.count)
        let delta = (frame.getDimension(orientation) - sum - added) / CGFloat(children.count + 1)
        let gap = CGFloat(gaps.inner.get(orientation))
        let start = weights.prefix(index).reduce(0, +) + delta * CGFloat(index) + (index == 0 ? 0 : gap / 2)
        let length = added + delta - (index == 0 ? 0 : gap / 2) - (index == children.count ? 0 : gap / 2)
        return orientation == .h
            ? Rect(topLeftX: frame.minX + start, topLeftY: frame.minY, width: length, height: frame.height)
            : Rect(topLeftX: frame.minX, topLeftY: frame.minY + start, width: frame.width, height: length)
    }
}

extension TilingContainer {
    /// The frame a strip gives `window` as a column at `index` among `others`, from this strip's last frame, scrolled the
    /// least that shows it (it is focused once dropped), as layoutScrolling frames it; the strip's whole frame before
    /// its first layout.
    @MainActor
    fileprivate func stripLanding(of window: Window, at index: Int, among others: [TreeNode], on monitor: MonitorInfo) -> Rect {
        let usable = lastAppliedLayoutPhysicalRect ?? monitor.visibleRectPaddedByOuterGaps
        var fractions = others.map { $0.columnWidth ?? config.scrollingNewWidth }
        fractions.insert(window.columnWidth ?? config.scrollingNewWidth, at: index)
        let strip = Strip(fractions: fractions, usable: usable, gap: CGFloat(ResolvedGaps(gaps: config.gaps, monitor: monitor).inner.horizontal))
        return strip.frames(at: strip.offset(showing: index, from: stripOffset), on: monitor.rect, sliver: config.scrollingSliver)[index]
    }
}

extension Rect {
    /// This tile as layout frames it within `area`: half the inner gap off each side another tile meets.
    fileprivate func inset(within area: Rect, by inner: ResolvedGaps.Inner) -> Rect {
        let h = CGFloat(inner.horizontal) / 2, v = CGFloat(inner.vertical) / 2
        let left = minX > area.minX + 0.5 ? h : 0, right = maxX < area.maxX - 0.5 ? h : 0
        let top = minY > area.minY + 0.5 ? v : 0, bottom = maxY < area.maxY - 0.5 ? v : 0
        return Rect(topLeftX: minX + left, topLeftY: minY + top, width: width - left - right, height: height - top - bottom)
    }
}
