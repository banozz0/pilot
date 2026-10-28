// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/TreeNodeEx.swift
import AppKit

extension TreeNode {
    private func visit(node: TreeNode, result: inout [Window]) {
        if let node = node as? Window {
            result.append(node)
        }
        for child in node.children {
            visit(node: child, result: &result)
        }
    }
    var allLeafWindowsRecursive: [Window] {
        var result: [Window] = []
        visit(node: self, result: &result)
        return result
    }

    var ownIndex: Int? {
        get throws {
            guard let parent else { return nil }
            return try parent.children.firstIndex(of: self).orFault()
        }
    }

    var parents: [NonLeafTreeNodeObject] { parent.flatMap { [$0] + $0.parents } ?? [] }
    var parentsWithSelf: [TreeNode] { parent.flatMap { [self] + $0.parentsWithSelf } ?? [self] }

    /// Also see visualWorkspace
    var nodeWorkspace: Workspace? {
        self as? Workspace ?? parent?.nodeWorkspace
    }

    /// Also see: workspace
    @MainActor
    var visualWorkspace: Workspace? {
        get throws {
            if let nodeWorkspace { return nodeWorkspace }
            return try nodeMonitor?.activeWorkspace
        }
    }

    @MainActor
    var nodeMonitor: MonitorInfo? {
        get throws {
            switch try self.nodeCases {
                case .workspace(let ws): ws.workspaceMonitor
                case .window,
                     .tilingContainer,
                     .macosFullscreenWindowsContainer,
                     .macosHiddenAppsWindowsContainer,
                     .floatingWindowsContainer: try parent?.nodeMonitor
                case .macosMinimizedWindowsContainer, .macosPopupWindowsContainer: nil
            }
        }
    }

    var mostRecentWindowRecursive: Window? {
        self as? Window ?? mostRecentChild?.mostRecentWindowRecursive
    }

    var anyLeafWindowRecursive: Window? {
        if let window = self as? Window {
            return window
        }
        for child in children {
            if let window = child.anyLeafWindowRecursive {
                return window
            }
        }
        return nil
    }

    // Doesn't contain at least one window
    var isEffectivelyEmpty: Bool {
        anyLeafWindowRecursive == nil
    }

    @MainActor
    var hWeight: CGFloat {
        get throws { try getWeight(.h) }
    }

    @MainActor
    var vWeight: CGFloat {
        get throws { try getWeight(.v) }
    }

    /// Returns closest parent that has children in the specified direction relative to `self`
    func closestParent(
        hasChildrenInDirection direction: CardinalDirection,
        withLayout layout: Layout?,
    ) throws -> (parent: TilingContainer, ownIndex: Int)? {
        let innermostChild = try parentsWithSelf.first(where: { (node: TreeNode) -> Bool in
            return switch try node.parent?.cases {
                // stop searching. We didn't find it, or something went wrong
                case .workspace, nil, .macosMinimizedWindowsContainer,
                     .floatingWindowsContainer,
                     .macosFullscreenWindowsContainer,
                     .macosHiddenAppsWindowsContainer,
                     .macosPopupWindowsContainer:
                    true
                case .tilingContainer(let parent):
                    try (layout == nil || parent.layout == layout) &&
                        parent.orientation == direction.orientation &&
                        (node.ownIndex.map { parent.children.indices.contains($0 + direction.focusOffset) } ?? true)
            }
        })
        guard let innermostChild else { return nil }
        switch try innermostChild.parent?.cases {
            case .tilingContainer(let parent):
                try ensure(parent.orientation == direction.orientation)
                return try innermostChild.ownIndex.map { (parent, $0) }
            case .workspace, .floatingWindowsContainer, nil, .macosMinimizedWindowsContainer,
                 .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer, .macosPopupWindowsContainer:
                return nil
        }
    }
}
