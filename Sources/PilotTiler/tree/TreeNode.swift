// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/TreeNode.swift
import AppKit

open class TreeNode: Equatable, AeroAny {
    private var _children: [TreeNode] = []
    var children: [TreeNode] { _children }
    fileprivate final weak var _parent: NonLeafTreeNodeObject? = nil
    final var parent: NonLeafTreeNodeObject? { _parent }
    private var adaptiveWeight: CGFloat
    private let _mruChildren: MruStack<TreeNode> = MruStack()
    // Usages:
    // - resize with mouse
    // - makeFloatingWindowsSeenAsTiling in focus command
    var lastAppliedLayoutVirtualRect: Rect? = nil  // as if inner gaps were always zero
    // Usages:
    // - resize with mouse
    // - drag window with mouse
    // - move-mouse command
    // - focus-follows-mouse
    var lastAppliedLayoutPhysicalRect: Rect? = nil // with real inner gaps
    /// Pilot (scrolling layout): this column's width as a fraction of the usable width, once a scrolling strip laid it out;
    /// nil before, when it takes a new column's width.
    var columnWidth: CGFloat? = nil { didSet { widthBeforeMaximise = nil } }
    /// Pilot (scrolling layout T10): the width a maximised column goes back to; any other width set forgets it.
    var widthBeforeMaximise: CGFloat? = nil
    final var unboundStacktrace: String? = nil
    var isBound: Bool { parent != nil } // todo drop, once https://github.com/nikitabobko/AeroSpace/issues/1215 is fixed

    @MainActor
    init(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) throws {
        self.adaptiveWeight = adaptiveWeight
        try bind(to: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    /// A node with no parent, such as NilTreeNode or the minimized and popup containers.
    init(unboundWithWeight adaptiveWeight: CGFloat = 0) {
        self.adaptiveWeight = adaptiveWeight
    }

    /// See: ``getWeight(_:)``
    func setWeight(_ targetOrientation: Orientation, _ newValue: CGFloat) throws {
        guard let parent else { try raiseFault("Can't change weight if TreeNode doesn't have parent") }
        switch try getChildParentRelation(child: self, parent: parent) {
            case .tiling(let parent):
                if parent.orientation != targetOrientation {
                    try raiseFault("You can't change \(targetOrientation) weight of nodes located in \(parent.orientation) container")
                }
                if parent.layout != .tiles {
                    try raiseFault("Weight can be changed only for nodes whose parent has 'tiles' layout")
                }
                adaptiveWeight = newValue
            default:
                try raiseFault("Can't change weight")
        }
    }

    /// Weight itself doesn't make sense. The parent container controls semantics of weight
    @MainActor
    func getWeight(_ targetOrientation: Orientation) throws -> CGFloat {
        guard let parent else { try raiseFault("Weight doesn't make sense for containers without parent") }
        return switch try getChildParentRelation(child: self, parent: parent) {
            case .tiling(let parent):
                parent.orientation == targetOrientation ? adaptiveWeight : try parent.getWeight(targetOrientation)
            case .rootTilingContainer: try parent.getWeight(targetOrientation)
            case .floatingWindow, .macosNativeFullscreenWindow: try raiseFaultT("Weight doesn't make sense for floating windows")
            case .macosNativeMinimizedWindow: try raiseFaultT("Weight doesn't make sense for minimized windows")
            case .macosPopupWindow: try raiseFaultT("Weight doesn't make sense for popup windows")
            case .macosNativeHiddenAppWindow: try raiseFaultT("Weight doesn't make sense for windows of hidden apps")
            case .shimContainerRelation: try raiseFaultT("Weight doesn't make sense for stub containers")
        }
    }

    @MainActor
    @discardableResult
    func bind(to newParent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) throws -> BindingData? {
        let result = try unbindIfBound()

        if newParent === NilTreeNode.instance {
            return result
        }
        let relation = try getChildParentRelation(child: self, parent: newParent) // Side effect: verify relation
        if adaptiveWeight == WEIGHT_AUTO {
            self.adaptiveWeight = switch relation {
                case .tiling(let newParent):
                    CGFloat(try newParent.children.sumOfDouble { try $0.getWeight(newParent.orientation) }).div(newParent.children.count) ?? 1
                case .floatingWindow, .macosNativeFullscreenWindow,
                     .rootTilingContainer, .macosNativeMinimizedWindow,
                     .shimContainerRelation, .macosPopupWindow, .macosNativeHiddenAppWindow:
                    WEIGHT_DOESNT_MATTER
            }
        } else {
            self.adaptiveWeight = adaptiveWeight
        }
        newParent._children.insert(self, at: index != INDEX_BIND_LAST ? index : newParent._children.count)
        _parent = newParent
        unboundStacktrace = nil
        // todo consider disabling automatic mru propogation
        // 1. "floating windows" in FocusCommand break the MRU because of that :(
        // 2. Misbehaved apps that abuse real window as popups https://github.com/nikitabobko/AeroSpace/issues/106 (the
        //    last appeared window, is not necessarily the one that has the focus)
        markAsMostRecentChild()
        return result
    }

    private func unbindIfBound() throws -> BindingData? {
        guard let _parent else { return nil }

        let index = try _parent._children.remove(element: self).orFault("Can't find child in its parent")
        try ensure(_parent._mruChildren.remove(self))
        self._parent = nil
        unboundStacktrace = getStringStacktrace()

        return BindingData(parent: _parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    /// Leaves the parent without checking a single invariant: the tree may be broken after a fault.
    final func detachForRebuild() {
        guard let _parent else { return }
        _parent._children.removeAll { $0 === self }
        _ = _parent._mruChildren.remove(self)
        self._parent = nil
    }

    func markAsMostRecentChild() {
        guard let _parent else { return }
        _parent._mruChildren.pushOrRaise(self)
        _parent.markAsMostRecentChild()
    }

    var mostRecentChild: TreeNode? { _mruChildren.mostRecent ?? children.last }

    var mruChildren: MruStack<TreeNode> { _mruChildren }

    @discardableResult
    func unbindFromParent() throws -> BindingData {
        try unbindIfBound().orFault("\(self) is already unbound. The stacktrace where it was unbound:\n\(unboundStacktrace.prettyDescription)")
    }

    nonisolated public static func == (lhs: TreeNode, rhs: TreeNode) -> Bool {
        lhs === rhs
    }

    private var userData: [String: Any] = [:]
    func getUserData<T>(key: TreeNodeUserDataKey<T>) -> T? { userData[key.key] as? T }
    func putUserData<T>(key: TreeNodeUserDataKey<T>, data: T) {
        userData[key.key] = data
    }
    @discardableResult
    func cleanUserData<T>(key: TreeNodeUserDataKey<T>) -> T? { userData.removeValue(forKey: key.key) as? T }
}

// periphery:ignore - Generic T is used
struct TreeNodeUserDataKey<T> {
    let key: String
}

let WEIGHT_DOESNT_MATTER = CGFloat(-2)
/// Splits containers evenly if tiling.
///
/// Reset weight is bind to workspace (aka "floating windows")
let WEIGHT_AUTO = CGFloat(-1)

let INDEX_BIND_LAST = -1

struct BindingData {
    let parent: NonLeafTreeNodeObject
    let adaptiveWeight: CGFloat
    let index: Int
}

final class NilTreeNode: TreeNode, NonLeafTreeNodeObject {
    private init() {
        super.init()
    }
    @MainActor static let instance = NilTreeNode()
}
