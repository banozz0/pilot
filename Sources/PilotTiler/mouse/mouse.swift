// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/mouse/mouse.swift
import AppKit

@MainActor var currentlyManipulatedWithMouseWindowId: UInt32? = nil
var isLeftMouseButtonDown: Bool { isUnitTest ? unitTestScreen.withLock { $0.leftMouseDown } : NSEvent.pressedMouseButtons == 1 }

@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    // Pilot: a held gap's button is no window's drag or resize, whatever the tiles it moves report (Moody REJECT CKZpHR_bQTQ)
    try await (gapDrag == nil && !window.isHiddenInCorner && // Don't allow to resize/move windows of hidden workspaces
        isLeftMouseButtonDown &&
        (currentlyManipulatedWithMouseWindowId == nil || window.windowId == currentlyManipulatedWithMouseWindowId))
        .andAsync { @Sendable @MainActor in try await getNativeFocusedWindow(.cancellable) == window }
}

/// Same motivation as in monitorFrameNormalized
var mouseLocation: CGPoint { isUnitTest ? unitTestScreen.withLock { $0.mouse } : NSEvent.mouseLocation.withYAxisFlipped }

// Pilot: AeroSpace's moveWithMouse.swift, rewritten so a drag is decided at the release (code review 2026-10-07; card
// agent-bo-95422997, AC5): a tiled window being dragged only starts a drag (dropWithMouse.swift); any other move
// refreshes like any other AX event.
func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    if isGliding(windowId) { return } // Pilot: its own glide's frames (card agent-bo-95423033)
    windowMoved(windowId, notif as String)
}

/// Also what Pilot's own windows post (OwnApp).
func windowMoved(_ windowId: UInt32?, _ notif: String) {
    Task.startUnstructured { @MainActor in
        // The release places it; until then, its drop zone and the live swap follow the mouse (cards agent-bo-95423032, 034)
        if let windowId, windowId == draggedWindowId { return dragMoved() }
        if let windowId, windowId == cancelledDragWindowId { return } // Esc cancelled it: nothing until the release
        if let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) {
            startDrag(window)
            if draggedWindowId == windowId { return }
            try await moveFloatingWindow(window)
            // Pilot (Sven's report 2026-10-17, a fast drag lagged the whole screen): no complete refresh per move of a
            // window the mouse holds; the release's refresh (GlobalObserver's left mouse up) lays it out once
            return
        }
        scheduleCancellableCompleteRefreshSession(.ax(notif))
    }
}

/// AeroSpace's moveFloatingWindow, which the rewrite above had dropped: a floating window the mouse moves onto another
/// display joins the workspace that display shows, by its centre as layoutFloatingWindow reads it. Left on its own
/// workspace, each refresh pulled it back to that display, and one wider than it hung over the edge (live bug 2026-10-17).
@MainActor
func moveFloatingWindow(_ window: Window) async throws {
    guard window.parent is FloatingWindowsContainer,
          let target = try await window.getCenter(.cancellable)?.monitorApproximation.activeWorkspace,
          window.parent is FloatingWindowsContainer, target != window.nodeWorkspace else { return } // still floating after the read
    _ = try window.bindAsFloatingWindow(to: target)
}

/// Pilot: a mouse gesture's sessions, one at a time (the live swap's, a held gap's). A run asked for while one is under
/// way is not queued but counted as missed, and `then` hears whether one was, once the session ends however it ends.
@MainActor
final class SessionsInTurn {
    private var task: Task<Void, any Error>?
    private var missed = false

    func run(_ session: @escaping @MainActor () async throws -> Void, then: @escaping @MainActor (_ missed: Bool) -> Void) {
        guard task == nil else { return missed = true }
        task = Task.startUnstructured { @MainActor in
            defer {
                self.task = nil
                let wasMissed = self.missed
                self.missed = false
                then(wasMissed)
            }
            try await session()
        }
    }
}
