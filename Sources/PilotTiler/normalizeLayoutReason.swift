// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/normalizeLayoutReason.swift
@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self))
    try await validateStillPopups()
}

@MainActor
private func validateStillPopups() async throws {
    for case let popup as MacWindow in macosPopupWindowsContainer.children {
        let windowLevel = getWindowLevel(for: popup.windowId)
        try await skippingSlowApp { // Pilot (card agent-bo-95423039)
            if try await popup.isWindowHeuristic(windowLevel, .cancellable) {
                try await popup.relayoutWindow(on: focus.workspace, .cancellable)
                try await runOnWindowDetected(ifConventional: popup)
            }
        }
    }
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window]) async throws {
    for window in windows {
        try await skippingSlowApp { try await normalizeLayoutReason(of: window, on: workspace) } // Pilot (card agent-bo-95423039)
    }
}

@MainActor
private func normalizeLayoutReason(of window: Window, on workspace: Workspace) async throws {
    let isMacosFullscreen = try await window.isMacosFullscreen(.cancellable)
    let isMacosMinimized = try await (!isMacosFullscreen).andAsync { @MainActor @Sendable in try await window.isMacosMinimized(.cancellable) }
    let isMacosWindowOfHiddenApp = try !isMacosFullscreen && !isMacosMinimized &&
        !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden
    switch window.layoutReason {
        case .standard:
            guard let parent = window.parent else { return }
            switch true {
                case isMacosFullscreen:
                    window.layoutReason = .macos(prevParentKind: try parent.kind)
                    try window.bind(to: try workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                case isMacosMinimized:
                    window.layoutReason = .macos(prevParentKind: try parent.kind)
                    window.minimizedFrom = workspace.name // Pilot (ADR 0015, Q690): the Window shelf lists it there
                    try window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                case isMacosWindowOfHiddenApp:
                    window.layoutReason = .macos(prevParentKind: try parent.kind)
                    try window.bind(to: try workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                default: break
            }
        case .macos(let prevParentKind):
            if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp {
                try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
            }
    }
}

@MainActor
func exitMacOsNativeUnconventionalState(
    window: Window,
    prevParentKind: NonLeafTreeNodeKind,
    workspace: Workspace,
    _ cm: CancellationMode,
) async throws {
    let reason = window.layoutReason
    window.layoutReason = .standard
    // Pilot (card agent-bo-95423039): an app too slow to say what the window is leaves it where it was, still waiting to
    // come back, so the next session tries again (it asks before it unbinds).
    do { try await rebindAfterMacOsNativeState(window, prevParentKind, workspace, cm) } catch is AxTimeout {
        window.layoutReason = reason
        throw AxTimeout()
    }
}

@MainActor
private func rebindAfterMacOsNativeState(_ window: Window, _ prevParentKind: NonLeafTreeNodeKind, _ workspace: Workspace, _ cm: CancellationMode) async throws {
    switch prevParentKind {
        case .floatingWindowsContainer:
            try window.bindAsFloatingWindow(to: workspace)
        case .workspace:
            break // Not possible
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, cm, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace, cm)
    }
}
