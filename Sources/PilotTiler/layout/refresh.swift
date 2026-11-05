// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/layout/refresh.swift
import AppKit

@MainActor
private var activeRefreshTask: Task<(), any Error>? = nil

#if DEBUG
/// Pilot: complete refreshes asked for so far, for tests to count what a drag costs.
@MainActor var completeRefreshesScheduled = 0
#endif

@MainActor
func scheduleCancellableCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) {
    #if DEBUG
    completeRefreshesScheduled += 1
    #endif
    activeRefreshTask?.cancel()
    activeRefreshTask = Task.startUnstructured { @MainActor in
        try checkCancellation()
        await runHeavyCompleteRefreshSession(
            event,
            assumeCancellable: true,
            optimisticallyPreLayoutWorkspaces: optimisticallyPreLayoutWorkspaces,
        )
    }
}

@MainActor
func runHeavyCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    assumeCancellable: Bool,
    layoutWorkspaces shouldLayoutWorkspaces: Bool = true,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) async {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    if !isTilerEnabled { return }
    let res = await Result {
        try await withFaultBoundary { try await $refreshSessionEvent.withValue(event) {
            gcMonitors() // Pilot: before the focused window registers, on a workspace still shown (live bug 2026-10-15)
            let nativeFocused = try await getNativeFocusedWindow(.cancellable)
            try updateFocusCache(nativeFocused)

            if shouldLayoutWorkspaces && optimisticallyPreLayoutWorkspaces { try await layoutWorkspaces() }

            try await refreshModel_nonCancellable()
            try await refresh()
            gcMonitors()

            try await normalizeLayoutReason()
            if shouldLayoutWorkspaces { try await layoutWorkspaces() }
        } }
    }
    endRefreshSession(res, assumeCancellable: assumeCancellable)
}

@MainActor
func endRefreshSession(_ res: Result<Void, any Error>, assumeCancellable: Bool) {
    switch res {
        case .success(()): break
        case .failure(let err as CancellationError): checkSoft(assumeCancellable, "Non cancellable refresh session was canceled: \(err) (\(type(of: err)))")
        case .failure(is TilerFault): break // reported and recovered at the boundary
        // Pilot (card agent-bo-95423039): a slow app is no fault; it was logged where it stalled, and the next session asks
        // again. Recovering here unparked every window and dropped the tree every few minutes.
        case .failure(is AxTimeout): break
        case .failure(let err): // AeroSpace died here: anything but cancellation is a bug
            _ = fault("Illegal error: \(err)")
            recoverFromFault()
    }
}

@MainActor
func runLightSession<T>(
    _ event: RefreshSessionEvent,
    _: RunSessionGuard,
    body: @MainActor () async throws -> T,
) async throws -> T {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    activeRefreshTask?.cancel() // Give priority to runSession
    activeRefreshTask = nil
    return try await withFaultBoundary { try await $refreshSessionEvent.withValue(event) {
        gcMonitors() // Pilot: as in the heavy session
        let nativeFocused = try await getNativeFocusedWindow(.cancellable)
        try updateFocusCache(nativeFocused)
        let focusBefore = focus.windowOrNil

        try await refreshModel_nonCancellable()
        let result = try await body()
        try await refreshModel_nonCancellable()

        let focusAfter = focus.windowOrNil

        if !event.isFocusFollowsMouse { try await layoutWorkspaces() }
        if focusBefore != focusAfter {
            focusAfter?.nativeFocus() // syncFocusToMacOs
        }
        switch event {
            case .focusFollowsMouse, .dragPreview, .gapResize: break // Pilot: a live swap's preview or a held gap changed only the tree
            default: scheduleCancellableCompleteRefreshSession(event)
        }
        return result
    } }
}

struct RunSessionGuard: Sendable {
    @MainActor
    static var isServerEnabled: RunSessionGuard? { isTilerEnabled ? forceRun : nil }
    static let forceRun = RunSessionGuard()
    private init() {}
}

@MainActor
func refreshModel_nonCancellable() async throws {
    if refreshSessionEvent?.isFocusFollowsMouse == true {
        await checkOnFocusChangedCallbacks_nonCancellable()
    } else {
        Workspace.garbageCollectUnusedWorkspaces()
        await checkOnFocusChangedCallbacks_nonCancellable()
        try normalizeContainers()
    }
}

/// Pilot (card agent-bo-95423039): a slow app's new windows wait for the next session; the other apps' register now.
@MainActor
func registerWindows(of app: MacApp, _ windowIds: [UInt32]) async throws {
    try await skippingSlowApp {
        for windowId in windowIds {
            try await MacWindow.getOrRegister(windowId: windowId, macApp: app)
        }
    }
}

/// Pilot (card agent-bo-95423039): a slow app's window stays where it is until the next session; the others hide now. A
/// window sliding out of a space switch hides as its glide lands (spaceSlide.swift); `slide`, the display just left
/// this workspace.
@MainActor
func hideInCorner(_ workspace: Workspace, _ corner: OptimalHideCorner, slide: SpaceSlide? = nil) async throws {
    if let slide { workspace.slideOut(slide, hidingIn: corner) }
    for window in workspace.allLeafWindowsRecursive where !isSlidingOut(window) {
        try await skippingSlowApp { try await (window as? MacWindow)?.hideInCorner(corner) }
    }
}

@MainActor
private func refresh() async throws {
    // Garbage collect terminated apps and windows before working with all windows
    let mapping = try await MacApp.refreshAllAndGetAliveWindowIds(frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    let aliveWindowIds = mapping.values.flatMap(id).toSet()
    windowHomes.alive = aliveWindowIds // Pilot (Q437): a home found by title is never a live window's

    for window in MacWindow.allWindows {
        if !aliveWindowIds.contains(window.windowId) {
            try window.garbageCollect(skipClosedWindowsCache: false)
        }
    }
    for (app, windowIds) in mapping {
        try await registerWindows(of: app, windowIds)
    }

    // Garbage collect workspaces after apps, because workspaces contain apps.
    Workspace.garbageCollectUnusedWorkspaces()
}

func refreshObs(_: AXObserver, _: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    refreshOnWindowEvent(notif as String)
}

/// Pilot: also what Pilot's own windows post (OwnApp).
func refreshOnWindowEvent(_ notif: String) {
    Task.startUnstructured { @MainActor in
        if !isTilerEnabled { return }
        scheduleCancellableCompleteRefreshSession(.ax(notif))
    }
}

enum OptimalHideCorner {
    case bottomLeftCorner, bottomRightCorner
}

@MainActor
private func layoutWorkspaces() async throws {
    if !isTilerEnabled {
        shownDesktop = nil // Pilot: off, every window back on screen
        for workspace in Workspace.all {
            try workspace.allLeafWindowsRecursive.forEach { try ($0 as? MacWindow)?.unhideFromCorner() }
            try await workspace.layoutWorkspace(unhidingColumns: true) // Unhide tiling windows from corner
        }
        forgetShownWorkspaces() // Pilot: back on, the tiler slides nothing until a switch
        announceStages() // Pilot: the Window shelf hides
        return publishGaps()
    }
    // Pilot (spec omarchy-ideas T1): pinned windows move to the workspace their monitor shows before any hiding below,
    // so none is ever parked
    let carried = try carryPinnedWindows()
    try arrangeAutoWorkspaces() // Pilot: auto layouts rebuild in memory first (card agent-bo-95422997, AC3)
    let monitors = monitorInfos
    let slides = spaceSlides(monitors) // Pilot (space-switch slide), before the unhiding below
    var monitorToOptimalHideCorner: [CGPoint: OptimalHideCorner] = [:]
    for monitor in monitors {
        monitorToOptimalHideCorner[monitor.rect.topLeftCorner] = optimalHideCorner(of: monitor, among: monitors)
    }

    // to reduce flicker, first unhide visible workspaces, then hide invisible ones
    let desktop = workspaceShowingDesktop() // Pilot (Show desktop): its windows wait in the corner, never sliding
    for monitor in monitors {
        let workspace = monitor.activeWorkspace
        if workspace === desktop {
            try await hideInCorner(workspace, monitorToOptimalHideCorner[monitor.rect.topLeftCorner] ?? .bottomRightCorner)
            continue
        }
        try workspace.allLeafWindowsRecursive.forEach { try ($0 as? MacWindow)?.unhideFromCorner() }
        try await workspace.layoutWorkspace(slide: slides[workspace])
    }
    for workspace in Workspace.all where !workspace.isVisible {
        let corner = monitorToOptimalHideCorner[workspace.workspaceMonitor.rect.topLeftCorner] ?? .bottomRightCorner
        try await hideInCorner(workspace, corner, slide: slides[workspace])
    }
    publishGaps() // Pilot: the gaps' handles (card agent-bo-95423035)
    announceStages() // Pilot: the Window shelf (ADR 0015)
    windowHomes.record(Workspace.all.flatMap(\.allLeafWindowsRecursive)) // Pilot (Q437): for the next launch
    raiseWithoutFocus(carried)
}

/// Pilot (spec omarchy-ideas T1, Q96): each pinned window carried to a new workspace comes up over its tiles, its app
/// left in the back; a click on a tile covers it again until the next switch. A beat after the pass, so the focus
/// hand-off to the new workspace's window (which activates its app) lands first. Off the main thread on fresh AX
/// elements with the engine's timeout, since the app's own AX thread is MacApp's.
@MainActor
private func raiseWithoutFocus(_ windows: [Window]) {
    for case let window as MacWindow in windows {
        let pid = window.app.pid, windowId = window.windowId
        // Pilot's own (OwnApp) through AppKit: AX into its own process off the main thread deadlocks it (T59).
        guard pid != myPid else {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                NSApp.windows.first { $0.windowNumber == Int(windowId) }?.orderFrontRegardless()
            }
            continue
        }
        Task.detached {
            try? await Task.sleep(for: .milliseconds(250))
            let app = AXUIElementCreateApplication(pid).withMessagingTimeout()
            guard let ax = app.get(Ax.windowsAttr)?.first(where: { $0.windowId == windowId })?.ax else { return }
            AXUIElementPerformAction(ax.withMessagingTimeout(), kAXRaiseAction as CFString)
        }
    }
}

/// The bottom corner of `monitor` a hidden window peeks out of, the one fewer other monitors touch (AeroSpace's
/// layoutWorkspaces); Pilot's hidden scrolling columns hide there too.
func optimalHideCorner(of monitor: MonitorInfo, among monitors: [MonitorInfo]) -> OptimalHideCorner {
    let xOff = monitor.width * 0.1
    let yOff = monitor.height * 0.1
    // brc = bottomRightCorner
    let brc1 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: -yOff)
    let brc2 = monitor.rect.bottomRightCorner + CGPoint(x: -xOff, y: 2)
    let brc3 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: 2)

    // blc = bottomLeftCorner
    let blc1 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: -yOff)
    let blc2 = monitor.rect.bottomLeftCorner + CGPoint(x: xOff, y: 2)
    let blc3 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: 2)

    func contains(_ monitor: MonitorInfo, _ point: CGPoint) -> Int { monitor.rect.contains(point) ? 1 : 0 }
    let important = 10

    return monitors.sumOfInt { contains($0, blc1) + contains($0, blc2) + important * contains($0, blc3) } <
        monitors.sumOfInt { contains($0, brc1) + contains($0, brc2) + important * contains($0, brc3) }
        ? .bottomLeftCorner
        : .bottomRightCorner
}

@MainActor
private func normalizeContainers() throws {
    // Can't do it only for visible workspace because most of the commands support --window-id and --workspace flags
    for workspace in Workspace.all {
        try workspace.normalizeContainers()
    }
}
