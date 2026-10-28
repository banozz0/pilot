// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/MacosUnconventionalWindowsContainer.swift

final class MacosFullscreenWindowsContainer: TreeNode, NonLeafTreeNodeObject {
    @MainActor
    init(parent: Workspace) throws {
        try super.init(parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }
}

/// The container for macOS windows of hidden apps
final class MacosHiddenAppsWindowsContainer: TreeNode, NonLeafTreeNodeObject {
    @MainActor
    init(parent: Workspace) throws {
        try super.init(parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }
}

@MainActor let macosMinimizedWindowsContainer = MacosMinimizedWindowsContainer()
final class MacosMinimizedWindowsContainer: TreeNode, NonLeafTreeNodeObject {
    @MainActor
    fileprivate init() {
        super.init(unboundWithWeight: 1)
    }
}

@MainActor let macosPopupWindowsContainer = MacosPopupWindowsContainer()
/// The container for macOS objects that are windows from AX perspective but from human perspective they are not even
/// dialogs. E.g. Sonoma (macOS 14) keyboard layout switch
final class MacosPopupWindowsContainer: TreeNode, NonLeafTreeNodeObject {
    @MainActor
    fileprivate init() {
        super.init(unboundWithWeight: 1)
    }
}
