// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/MacWindow.swift
import AppKit

final class MacWindow: Window {
    let macApp: MacApp
    private var prevUnhiddenProportionalPositionInsideWorkspaceRect: CGPoint?

    @MainActor
    private init(_ id: UInt32, _ actor: MacApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) throws {
        self.macApp = actor
        try super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [UInt32: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    /// After a fault: forget every window so the next refresh registers each again from AX into a fresh tree.
    @MainActor
    static func dropAllForRebuild() {
        recoveredPlacements = recoveryPlacements(of: Array(allWindowsMap.values))
        for window in allWindowsMap.values { window.detachForRebuild() }
        allWindowsMap = [:]
        clearClosedWindowsCache()
    }

    /// Pilot: a window of `macApp` the engine already knows, registered without asking AX (AC6's hung-app test).
    @MainActor
    static func unitTestWindow(id: UInt32, _ macApp: MacApp, parent: NonLeafTreeNodeObject) throws -> MacWindow {
        let window = try MacWindow(id, macApp, lastFloatingSize: nil, parent: parent, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        allWindowsMap[id] = window
        return window
    }

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: UInt32, macApp: MacApp) async throws -> MacWindow {
        if let existing = allWindowsMap[windowId] { return existing }
        let rect = try await macApp.getAxRect(windowId, .cancellable)
        // Pilot (Q437): a window Pilot knew before it relaunched goes back to its workspace; its title is read only when its
        // id is not known but its app has a home left (a reboot gave its windows new ids).
        if recoveredPlacements[windowId] == nil, let home = try await windowHomes.claim(windowId, appBundleId: macApp.rawAppBundleId, title: {
            if let title = windowTitles[windowId] { title } else { try await macApp.getAxTitle(windowId, .cancellable) }
        }) { recoveredPlacements[windowId] = home }
        let (workspace, recovered) = registrationWorkspace(windowId: windowId, rect: rect)
        // Pilot: a relaunched app's new tiled window goes back to its slot (card agent-bo-95423036); one open at startup
        // stays put. Its title is read before the binding data, so no wait sits between that and the bind.
        let slotTitle = recovered != nil || isStartup ? nil : try await windowSlots.title(for: macApp.rawAppBundleId) {
            if let title = windowTitles[windowId] { title } else { try await macApp.getAxTitle(windowId, .cancellable) ?? "" }
        }
        var data = recovered?.isFloating == true
            ? BindingData(parent: try workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            : try await unbindAndGetBindingDataForNewWindow(windowId, macApp, workspace, window: nil, .cancellable)
        if let slotTitle, data.parent is TilingContainer, let slot = windowSlots.placement(appBundleId: macApp.rawAppBundleId, title: slotTitle) {
            data = slot
        }

        // atomic synchronous section
        if let existing = allWindowsMap[windowId] { return existing }
        let window = try MacWindow(windowId, macApp, lastFloatingSize: rect?.size, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        allWindowsMap[windowId] = window

        // A window put back after a fault was detected before: its rules already ran.
        if recovered == nil, try await !restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window) {
            try await runOnWindowDetected(ifConventional: window)
        }
        return window
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }

    func isWindowHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isWindowHeuristic(windowId, windowLevel, cm)
    }

    func setNativeFullscreen(_ value: Bool) {
        macApp.setNativeFullscreen(windowId, value)
    }

    func setNativeMinimized(_ value: Bool) {
        macApp.setNativeMinimized(windowId, value)
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) throws {
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        if !skipClosedWindowsCache { try cacheClosedWindowIfNeeded() }
        // Pilot: a quitting app's windows may go before it is reported terminated (card agent-bo-95423036)
        windowSlots.windowsLeaving([self])
        windowTitles[windowId] = nil
        let parent = try unbindFromParent().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        let focus = focus
        if let deadWindowWorkspace, deadWindowWorkspace == focus.workspace ||
            deadWindowWorkspace == prevFocusedWorkspace && prevFocusedWorkspaceDate.distance(to: .now) < 1
        {
            switch try parent.cases {
                case .tilingContainer, .floatingWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    let deadWindowFocus = deadWindowWorkspace.toLiveFocus()
                    _ = setFocus(to: deadWindowFocus)
                    // Guard against "Apple Reminders popup" bug: https://github.com/nikitabobko/AeroSpace/issues/201
                    if focus.windowOrNil?.app.pid != app.pid {
                        // Force focus to fix macOS annoyance with focused apps without windows.
                        //   https://github.com/nikitabobko/AeroSpace/issues/65
                        deadWindowFocus.windowOrNil?.nativeFocus()
                    }
                case .macosPopupWindowsContainer, // Don't switch back on popup destruction
                     .workspace, // Workspace is invalid parent for windows
                     .macosMinimizedWindowsContainer: // Don't switch back on minimized windows destruction
                    break
            }
        }
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { try await macApp.getAxTitle(windowId, cm) ?? "" }
    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeFullscreen(windowId, cm) == true }
    override func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeMinimized(windowId, cm) == true }

    @MainActor override func nativeFocus() {
        MacApp.newFocus() // Pilot (spec scrolling-layout T7)
        macApp.nativeFocus(windowId)
    }

    override func closeAxWindow() throws {
        try garbageCollect(skipClosedWindowsCache: true)
        macApp.closeAndUnregisterAxWindow(windowId)
    }

    // todo it's part of the window layout and should be moved to layoutRecursive.swift
    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner) async throws {
        guard let nodeMonitor = try nodeMonitor else { return }
        lastAppliedLayoutPhysicalRect = nil // Pilot: back from the corner it jumps (card agent-bo-95423033), or slides in on a space switch
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent `hideInCorner` calls
        if !isHiddenInCorner {
            guard let windowRect = try await getAxRect(.cancellable) else { return }
            // Check for isHiddenInCorner for the second time because of the suspension point above
            if !isHiddenInCorner {
                let monitorRect = windowRect.center.monitorApproximation.rect // Similar to layoutFloatingWindow. Non idempotent
                rememberPlace(windowRect.topLeftCorner, in: monitorRect)
                if try isFloating {
                    lastFloatingSize = windowRect.size
                }
            }
        }
        let p: CGPoint
        switch corner {
            case .bottomLeftCorner:
                guard let s = try await getAxSize(.cancellable) else { fallthrough }
                p = cornerTopLeft(corner, on: nodeMonitor, width: s.width)
            case .bottomRightCorner:
                p = cornerTopLeft(.bottomRightCorner, on: nodeMonitor, width: 0)
        }
        setAxFrame(p, nil)
    }

    /// Pilot (space-switch slide, spaceSlide.swift): the window glides from its tile out the edge `slide` leaves by and
    /// jumps into `corner` once it lands, on its app's AX thread. It counts as hidden from now on, its place kept from its
    /// tile with no AX read. False for a window not on a tile, which hides as before.
    @MainActor
    func slideOut(_ slide: SpaceSlide, hidingIn corner: OptimalHideCorner) -> Bool {
        guard let from = lastAppliedLayoutPhysicalRect, !isHiddenInCorner, !(macApp is OwnApp),
              windowId != currentlyManipulatedWithMouseWindowId else { return false }
        lastAppliedLayoutPhysicalRect = nil
        rememberPlace(from.topLeftCorner, in: slide.monitor.rect)
        let to = slide.shifted(from)
        macApp.setAxFrame(windowId, to.topLeftCorner, to.size, glidingFrom: from, span: slide.span, screen: slide.screen,
                          then: cornerTopLeft(corner, on: slide.monitor, width: from.width))
        return true
    }

    /// Pilot (space-switch slide): out of its hide corner the window glides onto `tile` from the edge `slide` enters by,
    /// its size set where it waits before it moves.
    func slideIn(to tile: Rect, _ slide: SpaceSlide) {
        macApp.setAxFrame(windowId, tile.topLeftCorner, tile.size, glidingFrom: slide.shifted(tile), span: slide.span,
                          screen: slide.screen, fromCorner: true)
    }

    /// Where the window was on `monitorRect` as it hides, in fractions of it: where a floating one comes back.
    private func rememberPlace(_ topLeft: CGPoint, in monitorRect: Rect) {
        let absolutePoint = topLeft - monitorRect.topLeftCorner
        prevUnhiddenProportionalPositionInsideWorkspaceRect =
            CGPoint(x: absolutePoint.x / monitorRect.width, y: absolutePoint.y / monitorRect.height)
    }

    @MainActor
    func unhideFromCorner() throws {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect else { return }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
        guard let parent else { return }

        switch try getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow:
                let workspaceRect = nodeWorkspace.workspaceMonitor.rect
                var newX = workspaceRect.topLeftX + workspaceRect.width * prevUnhiddenProportionalPositionInsideWorkspaceRect.x
                var newY = workspaceRect.topLeftY + workspaceRect.height * prevUnhiddenProportionalPositionInsideWorkspaceRect.y
                // todo we probably should replace lastFloatingSize with proper floating window sizing
                // https://github.com/nikitabobko/AeroSpace/issues/1519
                let windowWidth = lastFloatingSize?.width ?? 0
                let windowHeight = lastFloatingSize?.height ?? 0
                newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
                newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

                setAxFrame(CGPoint(x: newX, y: newY), nil)
            case .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .tiling, .rootTilingContainer, .shimContainerRelation: break
        }

        self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
    }

    override var isHiddenInCorner: Bool {
        prevUnhiddenProportionalPositionInsideWorkspaceRect != nil
    }

    override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        try await macApp.getAxSize(windowId, cm)
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?, glidingFrom: Rect? = nil, duration: Duration = GlideSet.duration,
                             span: ClosedRange<CGFloat>? = nil, screen: GlideScreen? = nil) {
        macApp.setAxFrame(windowId, topLeft, size, glidingFrom: glidingFrom, duration: duration, span: span, screen: screen)
    }

    override func getAxRect(_ cm: CancellationMode) async throws -> Rect? {
        try await macApp.getAxRect(windowId, cm)
    }
}

extension Window {
    /// Where a window `width` wide sits hidden in `corner` of `monitor`: just past it, one pixel showing.
    func cornerTopLeft(_ corner: OptimalHideCorner, on monitor: MonitorInfo, width: CGFloat) -> CGPoint {
        // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/AeroSpace/issues/527
        // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
        let zoom = (self as? MacWindow)?.macApp.appId == .zoom
        return switch corner {
            case .bottomLeftCorner: monitor.visibleRect.bottomLeftCorner + (zoom ? .zero : CGPoint(x: 1, y: -1)) + CGPoint(x: -width, y: 0)
            case .bottomRightCorner: monitor.visibleRect.bottomRightCorner - (zoom ? .zero : CGPoint(x: 1, y: 1))
        }
    }

    @MainActor
    func relayoutWindow(on workspace: Workspace, _ cm: CancellationMode, forceTile: Bool = false) async throws {
        let data = forceTile
            ? try unbindAndGetBindingDataForNewTilingWindow(workspace, window: self)
            : try await unbindAndGetBindingDataForNewWindow(asMacWindow().windowId, asMacWindow().macApp, workspace, window: self, cm)
        try bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewWindow(_ windowId: UInt32, _ macApp: MacApp, _ workspace: Workspace, window: Window?, _ cm: CancellationMode) async throws -> BindingData {
    let windowLevel = getWindowLevel(for: windowId)
    return switch try await macApp.getAxUiElementWindowType(windowId, windowLevel, cm) {
        case .popup: BindingData(parent: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .dialog: BindingData(parent: try workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .window: try unbindAndGetBindingDataForNewTilingWindow(workspace, window: window)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewTilingWindow(_ workspace: Workspace, window: Window?) throws -> BindingData {
    try window?.unbindFromParent() // It's important to unbind to get correct data from below
    let mruWindow = workspace.mostRecentWindowRecursive
    // Pilot (scrolling layout): on a strip a new window is a new column, at a new column's width, right of the focused
    // one (the strip's own anchor: the workspace's most recent child may be its empty floating container); never a tile
    // in that column's stack.
    // A stage's new window is a group of its own after the focused one, never inside a group Sven joined (ADR 0015).
    let root = try workspace.rootTilingContainer
    if root.layout.isRow {
        window?.columnWidth = nil
        return BindingData(parent: root, adaptiveWeight: WEIGHT_AUTO, index: root.focusedColumnIndex.map { $0 + 1 } ?? INDEX_BIND_LAST)
    }
    // Pilot (Sven's Q122): on a workspace with a ready layout a new window takes the layout's next slot, Keep this layout on or off
    if let preset = arrangements[workspace.name]?.preset { return try root.nextSlot(preset) }
    if let mruWindow, let tilingParent = mruWindow.parent as? TilingContainer {
        return BindingData(
            parent: tilingParent,
            adaptiveWeight: WEIGHT_AUTO,
            index: try mruWindow.ownIndex.orFault() + 1,
        )
    } else {
        return BindingData(
            parent: try workspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: INDEX_BIND_LAST,
        )
    }
}

/// Where a window sat when a fault dropped the tree (Moody fbYAVj96Ats) or Pilot quit (WindowHomes, Q437): the rebuild
/// or the relaunch puts it back there, instead of registering every window on the focused workspace as for a window that
/// just opened. Such a window skips its on-window-detected rules and the closed-windows cache: they ran when it first came.
struct RecoveredPlacement: Codable, Equatable, Sendable {
    let workspace: String
    let isFloating: Bool
}

@MainActor var recoveredPlacements: [UInt32: RecoveredPlacement] = [:]

/// Reads only parent links, never a throwing accessor: the tree may be what faulted.
@MainActor
func recoveryPlacements(of windows: [Window]) -> [UInt32: RecoveredPlacement] {
    Dictionary(windows.compactMap { window in
        window.nodeWorkspace.map { (window.windowId, RecoveredPlacement(workspace: $0.name, isFloating: window.parent is FloatingWindowsContainer)) }
    }, uniquingKeysWith: { first, _ in first })
}

/// The workspace a window being registered joins: where it sat before a fault or before Pilot relaunched (used once),
/// else the one under it at startup or when it first showed during a drag (a tab dragged out, dropped on another display),
/// else the focused one.
@MainActor
func registrationWorkspace(windowId: UInt32, rect: Rect?) -> (workspace: Workspace, recovered: RecoveredPlacement?) {
    if let recovered = recoveredPlacements.removeValue(forKey: windowId) {
        return (Workspace.get(byName: recovered.workspace), recovered)
    }
    let dropped = windowsSeenInDrag.withLock { $0.remove(windowId) } != nil
    let workspace = isStartup || dropped ? (rect?.center.monitorApproximation ?? mainMonitorInfo).activeWorkspace : focus.workspace
    return (workspace, nil)
}

@MainActor
func runOnWindowDetected(ifConventional window: Window) async throws {
    switch try window.windowParentCases {
        case .tilingContainer, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            try await onWindowDetected(window)
        case .macosPopupWindowsContainer, .unbound:
            break
    }
}

// Pilot: AeroSpace's on-window-detected callbacks ran commands; here they are typed rules (code review, 2026-10-07).
@MainActor
func onWindowDetected(_ window: Window) async throws {
    broadcastEvent(.windowDetected(
        windowId: window.windowId,
        workspace: window.nodeWorkspace?.name,
        appBundleId: window.app.rawAppBundleId,
        appName: window.app.name,
    ))
    for rule in config.windowRules where await rule.matches(window) {
        try await rule.apply(to: window)
        if !rule.checkFurtherRules { return }
    }
}

extension WindowRule {
    @MainActor
    func matches(_ window: Window) async -> Bool {
        if let startup = duringStartup, startup != isStartup {
            return false
        }
        if let regex = windowTitleRegexSubstring, (try? await window.getTitle(.nonCancellable))?.contains(caseInsensitiveRegex: regex) != true {
            return false
        }
        if let appId, appId != window.app.rawAppBundleId {
            return false
        }
        if let regex = appNameRegexSubstring, !(window.app.name ?? "").contains(caseInsensitiveRegex: regex) {
            return false
        }
        if let workspace, workspace != window.nodeWorkspace?.name {
            return false
        }
        return true
    }
}
