// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/mouse/resizeWithMouse.swift
import AppKit

@MainActor
private var resizeWithMouseTask: Task<(), any Error>? = nil

func resizedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    if isGliding(windowId) { return } // Pilot: its own glide's frames (card agent-bo-95423033)
    windowResized(windowId, notif as String)
}

/// Pilot: also what Pilot's own windows post (OwnApp).
func windowResized(_ windowId: UInt32?, _ notif: String) {
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        resizeWithMouseTask?.cancel()
        resizeWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await resizeWithMouse(window)
            }
        }
    }
}

@MainActor
func resetManipulatedWithMouseIfPossible() async throws {
    if currentlyManipulatedWithMouseWindowId != nil {
        currentlyManipulatedWithMouseWindowId = nil
        for workspace in Workspace.all {
            workspace.resetResizeWeightBeforeResizeRecursive()
        }
        scheduleCancellableCompleteRefreshSession(.resetManipulatedWithMouse, optimisticallyPreLayoutWorkspaces: true)
    }
}

private let adaptiveWeightBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "adaptiveWeightBeforeResizeWithMouseKey")

@MainActor
private func resizeWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    switch try window.windowParentCases {
        case .unbound: return
        case .floatingWindowsContainer, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Nothing to do for floating, or unconventional windows
        case .tilingContainer:
            guard let rect = try await window.getAxRect(.cancellable) else { return }
            guard let lastAppliedLayoutRect = window.lastAppliedLayoutPhysicalRect else { return }
            // 5 pixels should be enough to fight with accumulated floating precision error
            try window.shareEdgeMoves(from: lastAppliedLayoutRect, to: rect, past: 5) { try $0.getWeightBeforeResize($1) }
            currentlyManipulatedWithMouseWindowId = window.windowId
    }
}

extension Window {
    /// Pilot: resizeWithMouse's sharing, pulled out for Pilot's modifier resize too (pilotDragResize.swift): each edge of
    /// `rect` that moved more than `past` from `last` adds the difference on this window's side, from `base`, and takes it
    /// evenly from the tiles beyond that edge.
    @MainActor
    func shareEdgeMoves(from last: Rect, to rect: Rect, past: CGFloat, base: (TreeNode, Orientation) throws -> CGFloat) throws {
        let (lParent, lOwnIndex) = try closestParent(hasChildrenInDirection: .left, withLayout: .tiles) ?? (nil, nil)
        let (dParent, dOwnIndex) = try closestParent(hasChildrenInDirection: .down, withLayout: .tiles) ?? (nil, nil)
        let (uParent, uOwnIndex) = try closestParent(hasChildrenInDirection: .up, withLayout: .tiles) ?? (nil, nil)
        let (rParent, rOwnIndex) = try closestParent(hasChildrenInDirection: .right, withLayout: .tiles) ?? (nil, nil)
        let table: [(CGFloat, TilingContainer?, Int?, Int?)] = [
            (last.minX - rect.minX, lParent, 0,                        lOwnIndex),               // Horizontal, to the left of the window
            (rect.maxY - last.maxY, dParent, dOwnIndex.map { $0 + 1 }, dParent?.children.count), // Vertical, to the down of the window
            (last.minY - rect.minY, uParent, 0,                        uOwnIndex),               // Vertical, to the up of the window
            (rect.maxX - last.maxX, rParent, rOwnIndex.map { $0 + 1 }, rParent?.children.count), // Horizontal, to the right of the window
        ]
        for (diff, parent, startIndex, pastTheEndIndex) in table {
            if let parent, let startIndex, let pastTheEndIndex, pastTheEndIndex - startIndex > 0 && abs(diff) > past {
                let siblingDiff = try diff.div(pastTheEndIndex - startIndex).orFault()
                let orientation = parent.orientation

                try parentsWithSelf.lazy
                    .prefix(while: { $0 != parent })
                    .filter {
                        let parent = $0.parent as? TilingContainer
                        return parent?.orientation == orientation && parent?.layout == .tiles
                    }
                    .forEach { try $0.setWeight(orientation, base($0, orientation) + diff) }
                for sibling in parent.children[startIndex ..< pastTheEndIndex] {
                    try sibling.setWeight(orientation, base(sibling, orientation) - siblingDiff)
                }
            }
        }
    }
}

extension TreeNode {
    @MainActor
    fileprivate func getWeightBeforeResize(_ orientation: Orientation) throws -> CGFloat {
        let currentWeight = try getWeight(orientation) // Check assertions
        return getUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
            ?? (lastAppliedLayoutVirtualRect?.getDimension(orientation) ?? currentWeight)
            .also { putUserData(key: adaptiveWeightBeforeResizeWithMouseKey, data: $0) }
    }

    fileprivate func resetResizeWeightBeforeResizeRecursive() {
        cleanUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
        for child in children {
            child.resetResizeWeightBeforeResizeRecursive()
        }
    }
}
