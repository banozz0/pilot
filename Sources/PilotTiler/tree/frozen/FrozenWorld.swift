// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/frozen/FrozenWorld.swift
struct FrozenWorld {
    let workspaces: [FrozenWorkspace]
    let monitors: [FrozenMonitor]
    let windowIds: Set<UInt32>
}

func collectAllWindowIdsRecursive(_ node: TreeNode) -> [UInt32] {
    if let window = node as? Window { return [window.windowId] }
    var result = [UInt32]()
    for child in node.children {
        result += collectAllWindowIdsRecursive(child)
    }
    return result
}
