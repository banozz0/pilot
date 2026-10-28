// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/frozen/FrozenTreeNode.swift
import AppKit

enum FrozenTreeNode: Sendable {
    case container(FrozenContainer)
    case window(FrozenWindow)
}

struct FrozenContainer: Sendable {
    let children: [FrozenTreeNode]
    let layout: Layout
    let orientation: Orientation
    let weight: CGFloat

    @MainActor init(_ container: TilingContainer) throws {
        children = try container.children.map {
            switch try $0.nodeCases {
                case .window(let w): .window(try FrozenWindow(w))
                case .tilingContainer(let c): .container(try FrozenContainer(c))
                case .workspace,
                     .floatingWindowsContainer,
                     .macosMinimizedWindowsContainer,
                     .macosHiddenAppsWindowsContainer,
                     .macosFullscreenWindowsContainer,
                     .macosPopupWindowsContainer:
                    try illegalChildParentRelation(child: $0, parent: container)
            }
        }
        layout = container.layout
        orientation = container.orientation
        weight = try getWeightOrNil(container) ?? 1
    }
}

struct FrozenWindow: Sendable {
    let id: UInt32
    let weight: CGFloat

    @MainActor init(_ window: Window) throws {
        id = window.windowId
        weight = try getWeightOrNil(window) ?? 1
    }
}

@MainActor private func getWeightOrNil(_ node: TreeNode) throws -> CGFloat? {
    try ((node.parent as? TilingContainer)?.orientation).map { try node.getWeight($0) }
}
