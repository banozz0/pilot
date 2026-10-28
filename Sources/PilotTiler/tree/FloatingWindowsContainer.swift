// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/FloatingWindowsContainer.swift
final class FloatingWindowsContainer: TreeNode, NonLeafTreeNodeObject {
    @MainActor
    init(parent: Workspace) throws {
        try super.init(parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }
}
