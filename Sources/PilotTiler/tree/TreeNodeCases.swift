// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/TreeNodeCases.swift

enum TreeNodeCases {
    case window(Window)
    case tilingContainer(TilingContainer)
    case workspace(Workspace)
    case macosMinimizedWindowsContainer(MacosMinimizedWindowsContainer)
    case macosHiddenAppsWindowsContainer(MacosHiddenAppsWindowsContainer)
    case macosFullscreenWindowsContainer(MacosFullscreenWindowsContainer)
    case macosPopupWindowsContainer(MacosPopupWindowsContainer)
    case floatingWindowsContainer(FloatingWindowsContainer)
}

enum NonLeafTreeNodeCases {
    case tilingContainer(TilingContainer)
    case workspace(Workspace)
    case macosMinimizedWindowsContainer(MacosMinimizedWindowsContainer)
    case macosHiddenAppsWindowsContainer(MacosHiddenAppsWindowsContainer)
    case macosFullscreenWindowsContainer(MacosFullscreenWindowsContainer)
    case macosPopupWindowsContainer(MacosPopupWindowsContainer)
    case floatingWindowsContainer(FloatingWindowsContainer)
}

enum TilingTreeNodeCases {
    case window(Window)
    case tilingContainer(TilingContainer)
}

enum NonLeafTreeNodeKind: Equatable {
    case tilingContainer
    case workspace
    case macosMinimizedWindowsContainer
    case macosHiddenAppsWindowsContainer
    case macosFullscreenWindowsContainer
    case macosPopupWindowsContainer
    case floatingWindowsContainer
}

enum WindowParentCases {
    case unbound
    case tilingContainer(TilingContainer)
    case macosMinimizedWindowsContainer(MacosMinimizedWindowsContainer)
    case macosHiddenAppsWindowsContainer(MacosHiddenAppsWindowsContainer)
    case macosFullscreenWindowsContainer(MacosFullscreenWindowsContainer)
    case macosPopupWindowsContainer(MacosPopupWindowsContainer)
    case floatingWindowsContainer(FloatingWindowsContainer)
}

enum TilingContainerParentCases {
    case unbound
    case tilingContainer(TilingContainer)
    case workspace(Workspace)
}

protocol NonLeafTreeNodeObject: TreeNode {}

extension Window {
    var windowParentCases: WindowParentCases {
        get throws {
            guard let parent else { return .unbound }
            return switch try parent.cases {
                case .floatingWindowsContainer(let it): .floatingWindowsContainer(it)
                case .macosFullscreenWindowsContainer(let it): .macosFullscreenWindowsContainer(it)
                case .macosHiddenAppsWindowsContainer(let it): .macosHiddenAppsWindowsContainer(it)
                case .macosMinimizedWindowsContainer(let it): .macosMinimizedWindowsContainer(it)
                case .macosPopupWindowsContainer(let it): .macosPopupWindowsContainer(it)
                case .tilingContainer(let it): .tilingContainer(it)
                case .workspace: try raiseFaultT("Workspace can't have direct Window children")
            }
        }
    }
}

extension TilingContainer {
    var tilingContainerParentCases: TilingContainerParentCases {
        get throws {
            guard let parent else { return .unbound }
            return switch try parent.cases {
                case .tilingContainer(let it): .tilingContainer(it)
                case .workspace(let it): .workspace(it)
                case .floatingWindowsContainer: try raiseFaultT("floatingWindowsContainer can't be TilingContainer's parent")
                case .macosFullscreenWindowsContainer: try raiseFaultT("macosFullscreenWindowsContainer can't be TilingContainer's parent")
                case .macosHiddenAppsWindowsContainer: try raiseFaultT("macosHiddenAppsWindowsContainer can't be TilingContainer's parent")
                case .macosMinimizedWindowsContainer: try raiseFaultT("macosMinimizedWindowsContainer can't be TilingContainer's parent")
                case .macosPopupWindowsContainer: try raiseFaultT("macosPopupWindowsContainer can't be TilingContainer's parent")
            }
        }
    }
}

extension TreeNode {
    var nodeCases: TreeNodeCases {
        get throws {
            switch self {
                case let window as Window: .window(window)
                case let workspace as Workspace: .workspace(workspace)
                case let tilingContainer as TilingContainer: .tilingContainer(tilingContainer)
                case let container as MacosHiddenAppsWindowsContainer: .macosHiddenAppsWindowsContainer(container)
                case let container as MacosMinimizedWindowsContainer: .macosMinimizedWindowsContainer(container)
                case let container as MacosFullscreenWindowsContainer: .macosFullscreenWindowsContainer(container)
                case let container as MacosPopupWindowsContainer: .macosPopupWindowsContainer(container)
                case let container as FloatingWindowsContainer: .floatingWindowsContainer(container)
                default: try raiseFault("Unknown tree")
            }
        }
    }

    func tilingTreeNodeCasesOrDie() throws(TilerFault) -> TilingTreeNodeCases {
        switch self {
            case let window as Window: .window(window)
            case let tilingContainer as TilingContainer: .tilingContainer(tilingContainer)
            default: try illegalChildParentRelation(child: self, parent: parent)
        }
    }
}

extension NonLeafTreeNodeObject {
    var cases: NonLeafTreeNodeCases {
        get throws {
            switch self {
                case is Window: try raiseFault("Windows are leaf nodes. They can't have children")
                case let workspace as Workspace: .workspace(workspace)
                case let tilingContainer as TilingContainer: .tilingContainer(tilingContainer)
                case let container as MacosMinimizedWindowsContainer: .macosMinimizedWindowsContainer(container)
                case let container as MacosHiddenAppsWindowsContainer: .macosHiddenAppsWindowsContainer(container)
                case let container as MacosFullscreenWindowsContainer: .macosFullscreenWindowsContainer(container)
                case let container as MacosPopupWindowsContainer: .macosPopupWindowsContainer(container)
                case let container as FloatingWindowsContainer: .floatingWindowsContainer(container)
                default: try raiseFault("Unknown tree \(self)")
            }
        }
    }

    var kind: NonLeafTreeNodeKind {
        get throws {
            switch try cases {
                case .tilingContainer: .tilingContainer
                case .floatingWindowsContainer: .floatingWindowsContainer
                case .workspace: .workspace
                case .macosMinimizedWindowsContainer: .macosMinimizedWindowsContainer
                case .macosFullscreenWindowsContainer: .macosFullscreenWindowsContainer
                case .macosHiddenAppsWindowsContainer: .macosHiddenAppsWindowsContainer
                case .macosPopupWindowsContainer: .macosPopupWindowsContainer
            }
        }
    }
}

enum ChildParentRelation: Equatable {
    case floatingWindow
    case macosNativeFullscreenWindow
    case macosNativeHiddenAppWindow
    case macosNativeMinimizedWindow
    case macosPopupWindow
    case tiling(parent: TilingContainer) // todo consider splitting it on 'tiles' and 'scrolling'
    case rootTilingContainer

    case shimContainerRelation
}

func getChildParentRelation(child: TreeNode, parent: NonLeafTreeNodeObject) throws -> ChildParentRelation {
    if let relation = try getChildParentRelationOrNil(child: child, parent: parent) {
        return relation
    }
    try illegalChildParentRelation(child: child, parent: parent)
}

func illegalChildParentRelation(
    child: TreeNode,
    parent: NonLeafTreeNodeObject?,
    file: StaticString = #fileID,
    line: Int = #line,
    column: Int = #column,
    function: String = #function,
) throws(TilerFault) -> Never {
    let msg = "Illegal child-parent relation. Child: \(child), Parent: \((parent ?? child.parent).prettyDescription)"
    try raiseFault(msg, file: file, line: line, column: column, function: function)
}

func getChildParentRelationOrNil(child: TreeNode, parent: NonLeafTreeNodeObject) throws -> ChildParentRelation? {
    return switch (try child.nodeCases, try parent.cases) {
        case (.workspace, _): nil
        case (.window, .workspace): nil

        case (.window, .macosPopupWindowsContainer): .macosPopupWindow
        case (_, .macosPopupWindowsContainer): nil
        case (.macosPopupWindowsContainer, _): nil

        case (.window, .macosMinimizedWindowsContainer): .macosNativeMinimizedWindow
        case (_, .macosMinimizedWindowsContainer): nil
        case (.macosMinimizedWindowsContainer, _): nil

        case (.tilingContainer, .tilingContainer(let container)),
             (.window, .tilingContainer(let container)): .tiling(parent: container)
        case (.tilingContainer, .workspace): .rootTilingContainer

        case (.floatingWindowsContainer, .workspace): .shimContainerRelation
        case (.window, .floatingWindowsContainer): .floatingWindow
        case (.floatingWindowsContainer, _): nil
        case (_, .floatingWindowsContainer): nil

        case (.macosFullscreenWindowsContainer, .workspace): .shimContainerRelation
        case (.window, .macosFullscreenWindowsContainer): .macosNativeFullscreenWindow
        case (.macosFullscreenWindowsContainer, _): nil
        case (_, .macosFullscreenWindowsContainer): nil

        case (.macosHiddenAppsWindowsContainer, .workspace): .shimContainerRelation
        case (.window, .macosHiddenAppsWindowsContainer): .macosNativeHiddenAppWindow
        case (.macosHiddenAppsWindowsContainer, _): nil
        case (_, .macosHiddenAppsWindowsContainer): nil
    }
}
