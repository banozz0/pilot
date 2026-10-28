// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/Window.swift
import AppKit

open class Window: TreeNode, Hashable {
    let windowId: UInt32
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    var isFullscreen: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    var layoutReason: LayoutReason = .standard
    /// Pilot: a pinned pop-out (spec omarchy-ideas T1) follows every workspace its monitor shows, floating; tiler memory
    /// only, gone on a restart. Not a workspace pin (N7), which ties a workspace to a display.
    var isPinned = false

    @MainActor
    init(id: UInt32, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) throws {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        try super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: UInt32) -> Window? { // todo make non optional
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor
    func closeAxWindow() throws { try raiseFault("Not implemented") }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { try raiseFault("Not implemented") }
    func getTitle(_ cm: CancellationMode) async throws -> String { try raiseFault("Not implemented") }
    func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { false }
    func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { false } // todo replace with enum MacOsWindowNativeState { normal, fullscreen, invisible }
    var isHiddenInCorner: Bool { checkSoft(false, "Not implemented"); return false }
    @MainActor func nativeFocus() { checkSoft(false, "Not implemented") }
    func getAxRect(_ cm: CancellationMode) async throws -> Rect? { try raiseFault("Not implemented") }
    func getCenter(_ cm: CancellationMode) async throws -> CGPoint? { try await getAxRect(cm)?.center }

    /// Pilot: `glidingFrom`, layout's frame to glide from, for `duration` (card agent-bo-95423033), paced by `screen`'s
    /// refresh; `span`, the x a scrolling column keeps within on its way (FrameSteps).
    func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?, glidingFrom: Rect? = nil, duration: Duration = GlideSet.duration,
                    span: ClosedRange<CGFloat>? = nil, screen: GlideScreen? = nil) { checkSoft(false, "Not implemented") }
}

enum LayoutReason: Equatable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: NonLeafTreeNodeKind)
}

extension Window {
    var isFloating: Bool { // Pilot: a pinned window (isPinned) floats too, so this stays true for it
        get throws {
        switch try windowParentCases {
            case .floatingWindowsContainer: true
            case .macosFullscreenWindowsContainer: false
            case .macosHiddenAppsWindowsContainer: false
            case .macosMinimizedWindowsContainer: false
            case .macosPopupWindowsContainer: false
            case .tilingContainer: false
            case .unbound: false
        }
        }
    }

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) throws -> BindingData? {
        try bind(to: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func asMacWindow() throws(TilerFault) -> MacWindow { try (self as? MacWindow).orFault("\(self) is not a MacWindow") }
}
