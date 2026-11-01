// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/layout/layoutRecursive.swift
import AppKit

extension Workspace {
    /// Pilot: `unhidingColumns`, the tiler is stopping: a scrolling strip lays every column on screen, a stage every
    /// group. `slide`, the display just switched to this workspace (spaceSlide.swift). A stage keeps the shelf's room.
    @MainActor
    func layoutWorkspace(unhidingColumns: Bool = false, slide: SpaceSlide? = nil) async throws {
        if isEffectivelyEmpty { return }
        let layout = try rootTilingContainer.layout
        let padded = workspaceMonitor.visibleRectPaddedByOuterGaps
        let rect = layout == .stage && !unhidingColumns ? padded.leavingShelf() : padded
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        let context = LayoutContext(self, layout: layout, unhidingColumns: unhidingColumns, slide: slide)
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, context)
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch try nodeCases {
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                try await workspace.floatingWindowsContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .floatingWindowsContainer(let container):
                for window in container.children.filterIsInstance(of: Window.self) {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    try await skippingSlowApp { try await window.layoutFloatingWindow(context) } // Pilot (AC6): its app is hung, it stays put
                }
            case .window(let window):
                if window.windowId != currentlyManipulatedWithMouseWindowId {
                    lastAppliedLayoutVirtualRect = virtual
                    if try window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        // Pilot: from where it was laid out last, it glides (card agent-bo-95423033)
                        let previous = lastAppliedLayoutPhysicalRect
                        lastAppliedLayoutPhysicalRect = physicalRect
                        window.isFullscreen = false
                        if previous == nil, let slide = context.slide, slide.hidden.contains(window.windowId), let window = window as? MacWindow {
                            window.slideIn(to: physicalRect, slide) // Pilot (space-switch slide)
                        } else {
                            window.setAxFrame(point, CGSize(width: width, height: height),
                                              glidingFrom: context.glides && previous?.isClose(to: physicalRect) == false ? previous : nil,
                                              duration: context.glideDuration, span: context.span, screen: context.glideScreen)
                        }
                    }
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                switch container.layout {
                    case .tiles:
                        try await container.layoutTiles(point, width: width, height: height, virtual: virtual, context)
                    case .scrolling:
                        try await container.layoutScrolling(point, width: width, height: height, context)
                    case .stage:
                        try await container.layoutStage(point, width: width, height: height, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

private struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps
    /// Pilot (card agent-bo-95423033): windows glide from their last frame, except with Glide windows off, under Reduce
    /// Motion or Low Power Mode (Sven's Q147), and while the mouse resizes a window or holds a gap (its neighbours follow the mouse at once, card agent-bo-95423035); a drag's live
    /// swap glides (card agent-bo-95423034).
    let glides: Bool
    /// How long a glide runs: a scrolling strip's setting (zero for instant: it jumps), else GlideSet's 180 ms.
    let glideDuration: Duration
    /// The workspace's screen, whose refresh paces its glides; nil when nothing glides.
    let glideScreen: GlideScreen?
    let unhidingColumns: Bool
    /// A scrolling strip's or a stage's: the x its windows keep within, clear of the displays beside its monitor (FrameSteps).
    let span: ClosedRange<CGFloat>?
    /// Pilot (space-switch slide): the display just switched to this workspace; its windows out of a hide corner slide in.
    let slide: SpaceSlide?

    @MainActor
    init(_ workspace: Workspace, layout: Layout, unhidingColumns: Bool, slide: SpaceSlide?) {
        let scrolling = layout == .scrolling
        self.workspace = workspace
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
        self.glideDuration = scrolling ? config.scrollingGlide ?? .zero : GlideSet.duration
        self.glides = glidesAllowed && glideDuration > .zero
            && (currentlyManipulatedWithMouseWindowId == nil || currentlyManipulatedWithMouseWindowId == (draggedWindowId ?? cancelledDragWindowId))
        self.glideScreen = glides ? GlideScreen(workspace.workspaceMonitor) : nil
        self.unhidingColumns = unhidingColumns
        self.span = layout.isRow ? workspace.workspaceMonitor.columnSpan(among: monitorInfos) : nil
        self.slide = slide
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext) async throws {
        let workspace = context.workspace
        let windowRect = try await getAxRect(.cancellable) // Probably not idempotent
        let currentMonitor = windowRect?.center.monitorApproximation
        // Pilot: never pulled back while the mouse holds it; the move rebinds it (moveFloatingWindow, live bug 2026-10-17)
        let held = isLeftMouseButtonDown && self == focus.windowOrNil
        if let currentMonitor, let windowRect, workspace != currentMonitor.activeWorkspace, !held {
            let windowTopLeftCorner = windowRect.topLeftCorner
            let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
            let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

            let workspaceRect = workspace.workspaceMonitor.visibleRectBelowBar // Pilot: never under the top bar
            var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height

            let windowWidth = windowRect.width
            let windowHeight = windowRect.height
            newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
            newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

            setAxFrame(CGPoint(x: newX, y: newY), nil)
        } else if let windowRect, let currentMonitor, !isFullscreen {
            keepBelowBar(windowRect, on: currentMonitor) // Pilot (Sven on build 21): the top bar is a hard edge
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect = noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitor.visibleRectBelowBar // Pilot: the top gap holds the bar; this keeps it
            : context.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        setAxFrame(monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        var point = point
        var virtualPoint = virtual.topLeftCorner

        guard let delta = ((orientation == .h ? width : height) - CGFloat(try children.sumOfDouble { try $0.getWeight(orientation) }))
            .div(children.count) else { return }

        let lastIndex = children.indices.last
        for (i, child) in children.enumerated() {
            try child.setWeight(orientation, try child.getWeight(orientation) + delta)
            let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
            // Gaps. Consider 4 cases:
            // 1. Multiple children. Layout first child
            // 2. Multiple children. Layout last child
            // 3. Multiple children. Layout child in the middle
            // 4. Single child   let rawGap = gaps.inner.get(orientation).toDouble()
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            try await child.layoutRecursive(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? child.hWeight - gap : width,
                height: orientation == .v ? child.vWeight - gap : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? child.hWeight : width,
                    height: orientation == .v ? child.vWeight : height,
                ),
                context,
            )
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(try child.hWeight) : virtualPoint.addingYOffset(try child.vWeight)
            point = orientation == .h ? point.addingXOffset(try child.hWeight) : point.addingYOffset(try child.vWeight)
        }
    }

    /// Pilot (scrolling layout): each child a column on the strip (scrolling.swift), scrolled the least that shows the
    /// focused one whole. A column the strip would put over another display hides in the hide corner, a jump, and comes
    /// back with a jump, so a glide only runs between two frames clear of every other display and none ever crosses. On
    /// a space switch the columns on screen slide in from the display's edge (spaceSlide.swift), within the same rule.
    @MainActor
    fileprivate func layoutScrolling(_ point: CGPoint, width: CGFloat, height: CGFloat, _ context: LayoutContext) async throws {
        let monitor = context.workspace.workspaceMonitor, monitors = monitorInfos
        fitColumnWidths()
        let strip = strip(usable: Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height),
                          gap: CGFloat(context.resolvedGaps.inner.horizontal), equalWidths: context.unhidingColumns)
        stripOffset = context.unhidingColumns ? 0 : strip.offset(showing: focusedColumnIndex, from: stripOffset, centre: config.scrollingCentre)
        let others = monitors.filter { $0.rect.topLeftCorner != monitor.rect.topLeftCorner }.map(\.rect)
        let corner = optimalHideCorner(of: monitor, among: monitors)
        for (child, frame) in zip(children, strip.frames(at: stripOffset, on: monitor.rect, sliver: config.scrollingSliver)) {
            if others.contains(where: { $0.overlaps(frame) }) {
                child.hideColumn(frame.size, in: corner, of: monitor, span: context.span)
            } else {
                try await child.layoutColumn(frame, context)
            }
        }
    }

    /// Pilot (Stage layout, ADR 0015): the staged groups (stage.swift) side by side at equal widths in the room right of
    /// the shelf; every other group shelved in the hide corner as a strip's hidden column is, at the stage's size, a jump
    /// either way, so no frame crosses onto another display (ADR 0014). Tiling off, every group is staged. A stage's
    /// children keep their weights: the tree lets only a tiles parent change them.
    @MainActor
    fileprivate func layoutStage(_ point: CGPoint, width: CGFloat, height: CGFloat, _ context: LayoutContext) async throws {
        let monitor = context.workspace.workspaceMonitor
        let staged = context.unhidingColumns ? children : stagedChildren
        if staged.count < children.count {
            let corner = optimalHideCorner(of: monitor, among: monitorInfos), ids = Set(staged.map(ObjectIdentifier.init))
            for child in children where !ids.contains(ObjectIdentifier(child)) {
                child.hideColumn(CGSize(width: width, height: height), in: corner, of: monitor, span: context.span)
            }
        }
        let usable = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        let strip = Strip(fractions: staged.map { _ in 1 / CGFloat(staged.count) }, usable: usable, gap: CGFloat(context.resolvedGaps.inner.horizontal))
        for (child, frame) in zip(staged, strip.frames(at: 0, on: monitor.rect, sliver: 0)) {
            try await child.layoutColumn(frame, context)
        }
    }
}

extension TreeNode {
    /// Pilot: one column of a strip or group of a stage laid out at `frame`, half the inner gap on each side its own.
    @MainActor
    fileprivate func layoutColumn(_ frame: Rect, _ context: LayoutContext) async throws {
        let gap = CGFloat(context.resolvedGaps.inner.horizontal)
        let virtual = Rect(topLeftX: frame.minX - gap / 2, topLeftY: frame.minY, width: frame.width + gap, height: frame.height)
        try await layoutRecursive(frame.topLeftCorner, width: frame.width, height: frame.height, virtual: virtual, context)
    }
}
