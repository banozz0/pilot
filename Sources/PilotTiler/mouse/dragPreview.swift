import AppKit

// Pilot's live swap (card agent-bo-95423034): while a tiled window is dragged, the drop under the mouse is laid into the
// tree and laid out like any change, so the other windows glide aside. The workspaces it touches are kept beside it as they
// were and put back, objects and all, when the drop under the mouse changes, on Esc, or at a release elsewhere.

/// A drop laid into the live tree while the mouse still holds the window.
@MainActor
struct DragPreview {
    /// Where the dragged window lands, as the drop zone shows it: measured before the drop was laid in.
    let landing: Rect
    /// Where the mouse can move without changing the drop, read off the committed tree: a rect check per move.
    let zone: (CGPoint) -> Bool
    fileprivate let saved: [SavedWorkspace]

    /// Puts the committed tree back and runs `body` on it, then hands each window back the frame it was last laid out in,
    /// so the next layout glides it from where it is.
    fileprivate func restore(then body: () throws -> Void) throws {
        let tiled = try saved.map { try $0.workspace.rootTilingContainer.allLeafWindowsRecursive }
        let frames = tiled.joined().map { ($0, $0.lastAppliedLayoutPhysicalRect) }
        let known = saved.flatMap(\.windows)
        let present = tiled.joined().toSet()
        for (workspace, windows) in zip(saved, tiled) { try workspace.restore(present: present, newcomers: windows - known) }
        try body()
        for (window, frame) in frames { window.lastAppliedLayoutPhysicalRect = frame }
    }
}

/// The drop on show while a drag holds one; nil when the tree is the committed one.
@MainActor var dragPreview: DragPreview? = nil

/// The window whose drag Esc cancelled, until its release: its moves plan nothing, and the release drops nothing.
@MainActor var cancelledDragWindowId: UInt32? = nil

/// Takes the preview off show and runs `body` on the committed tree it puts back; with none on show, runs `body`.
@MainActor
func endPreview(then body: () throws -> Void) throws {
    let preview = dragPreview
    dragPreview = nil
    if let preview { try preview.restore(then: body) } else { try body() }
}

@MainActor private let dragPreviewSessions = SessionsInTurn()

/// Runs a preview's lay-in as a light session of its own; tests hold it open.
@MainActor var runDragPreviewSession: @MainActor (_ body: @MainActor () throws -> Void) async throws -> Void = { body in
    try await runLightSession(.dragPreview, .forceRun, body: body)
}

/// Lays the drop under the mouse in, in a session of its own (one at a time). A move that comes while one runs is checked
/// again once it ends, whatever it left on show (Moody REJECT lqjktf2-UEU).
@MainActor let previewInASession: @MainActor () -> Void = {
    guard RunSessionGuard.isServerEnabled != nil else { return }
    dragPreviewSessions.run({ try await runDragPreviewSession { try previewDrop(at: mouseLocation) } }) { missed in
        if missed { dragMoved() }
    }
}

/// How a move asks for the drop under the mouse to be laid in; tests lay it in themselves.
@MainActor var scheduleDragPreview = previewInASession

/// Each move of the dragged window. Inside the preview's zone it costs a rect check and writes no frame (AC4); anywhere a
/// release would move the window, it asks for a session to lay that drop in. Until the session runs, the drop zone keeps
/// the landing on show.
@MainActor
func dragMoved() {
    guard draggedWindowId != nil, dragPreview?.zone(mouseLocation) != true else { return }
    if updateDropZone() != nil { scheduleDragPreview() }
}

/// The drop under `point` laid into the live tree, for the session's layout to show. The preview on show is put back
/// first, unless `point` is still in its zone; nothing is laid in where a release would leave the window be (AC3).
@MainActor
func previewDrop(at point: CGPoint) throws {
    guard let id = draggedWindowId, let window = Window.get(byId: id), dragPreview?.zone(point) != true else { return }
    try endPreview { try layIn(window, at: point) }
    updateDropZone()
}

@MainActor
private func layIn(_ window: Window, at point: CGPoint) throws {
    guard window.parent is TilingContainer, let plan = try dropPlan(window, at: point),
          let landing = try landing(of: plan, for: window) else { return }
    let target = point.monitorApproximation.activeWorkspace
    let touched = [target] + (window.nodeWorkspace.flatMap { $0 == target ? nil : [$0] } ?? [])
    let saved = try touched.map(SavedWorkspace.init)
    let zone = try zone(of: plan, for: window, at: point)
    try land(window, plan)
    dragPreview = DragPreview(landing: landing, zone: zone, saved: saved)
}

/// Esc mid-drag (AC3): the committed tree back and the drop zone gone.
@MainActor
func cancelDrag() throws {
    guard let id = draggedWindowId else { return }
    cancelledDragWindowId = id
    draggedWindowId = nil
    try endPreview {}
}

public enum TilerDrag {
    /// Pilot's key tap saw Esc: a drag under way is cancelled in a session of its own, never on the tap.
    @MainActor public static func escape() {
        guard draggedWindowId != nil, let allowed = RunSessionGuard.isServerEnabled else { return }
        Task.startUnstructured { @MainActor in try await runLightSession(.hotkeyBinding, allowed) { try cancelDrag() } }
    }

    /// Pilot's modifier drag (story 119) moves tiled window `id`: the tiler holds it as a mouse drag from now on, as
    /// startDrag does, without reading the left button or the focused window: Pilot's tap swallows the press and focuses
    /// the window only after it, so on those the tiler took each move for any other and laid the window back in its tile
    /// under the mouse (Sven on build 19, 2026-10-10). False when the tiler does not tile it, or holds another drag.
    @MainActor public static func begin(_ id: UInt32) -> Bool {
        guard gapDrag == nil, draggedWindowId == nil, let window = tiledWindow(id) else { return false }
        startDrag(window)
        return true
    }

    /// Pilot's drag is over, its last frame written: dropped at `point` (top-left coordinates, as the tiler's mouse), or
    /// put back with nil. Pilot keeps that mouse-up from the tiler, so this is the drag's release.
    @MainActor public static func end(at point: CGPoint?) {
        guard let allowed = RunSessionGuard.isServerEnabled else { return }
        Task.startUnstructured { @MainActor in
            try await resetManipulatedWithMouseIfPossible()
            try await endMouseDrag(at: point, allowed)
        }
    }
}

/// A mouse drag's release, the tiler's own mouse-up's or Pilot's (TilerDrag.end), in a session of its own; nothing when
/// no drag is held.
@MainActor
func endMouseDrag(at point: CGPoint?, _ allowed: RunSessionGuard) async throws {
    guard draggedWindowId != nil || cancelledDragWindowId != nil else { return }
    try await runLightSession(.globalObserverLeftMouseUp, allowed) { try releaseDrag(at: point) }
}

/// The drop under `point`, or with nil the committed tree back; after Esc, nothing more.
@MainActor
func releaseDrag(at point: CGPoint?) throws {
    if let point { try dropDraggedWindow(at: point) } else { try cancelDrag() }
    cancelledDragWindowId = nil
}

/// Where the mouse can move without changing `plan`, read off the committed tree now with dropPlan's own rules.
@MainActor
private func zone(of plan: DropPlan, for window: Window, at point: CGPoint) throws -> (CGPoint) -> Bool {
    let monitor = point.monitorApproximation.rect
    switch plan {
        case .arrange(let target, let kept, let tiled):
            let area = target.workspaceMonitor.visibleRectPaddedByOuterGaps, id = window.windowId, columns = kept.columnFrames(tiled)
            return { monitor.contains($0) && kept.order(dropping: id, at: $0, among: tiled, in: area, columns: columns) == kept.order }
        case .swap(let under):
            let rect = under.lastAppliedLayoutPhysicalRect
            return { rect?.contains($0) == true }
        case .insert(let parent, _):
            let root = try point.monitorApproximation.activeWorkspace.rootTilingContainer
            if let rect = try point.findWindowRecursively(in: root, virtual: false)?.lastAppliedLayoutPhysicalRect {
                let side = parent.orientation, after = point.isPastCentre(of: rect, along: side)
                return { rect.contains($0) && $0.isPastCentre(of: rect, along: side) == after }
            }
            let tiles = root.allLeafWindowsRecursive.compactMap(\.lastAppliedLayoutPhysicalRect)
            return { p in monitor.contains(p) && !tiles.contains { $0.contains(p) } }
    }
}

/// One workspace's tiled tree as it was: its own container objects (dropPlan's hit test reads their frames), each one's
/// children with their weights, its orientation, layout, MRU order and strip offset, every node's frames, and the
/// arrangement.
@MainActor
private struct SavedWorkspace {
    struct Container {
        let node: TilingContainer
        let orientation: Orientation
        let layout: Layout
        let children: [(node: TreeNode, weight: CGFloat)]
        let mru: [TreeNode]
        let stripOffset: CGFloat
    }

    let workspace: Workspace
    let arrangement: WorkspaceArrangement?
    /// The root first, each container before its children.
    let containers: [Container]
    let frames: [(node: TreeNode, physical: Rect?, virtual: Rect?)]

    init(_ workspace: Workspace) throws {
        var containers: [Container] = []
        var frames: [(node: TreeNode, physical: Rect?, virtual: Rect?)] = []
        func save(_ node: TreeNode) throws {
            frames.append((node, node.lastAppliedLayoutPhysicalRect, node.lastAppliedLayoutVirtualRect))
            guard let container = node as? TilingContainer else { return }
            containers.append(Container(node: container, orientation: container.orientation, layout: container.layout,
                                        children: try container.children.map { ($0, try $0.getWeight(container.orientation)) },
                                        mru: Array(container.mruChildren), stripOffset: container.stripOffset))
            for child in container.children { try save(child) }
        }
        try save(workspace.rootTilingContainer)
        self.workspace = workspace
        self.arrangement = arrangements[workspace.name]
        self.containers = containers
        self.frames = frames
    }

    var windows: [Window] { frames.compactMap { $0.node as? Window } }

    /// The saved tree built again from its own objects. A saved window no longer tiled in a touched workspace (closed or
    /// floated mid-drag) stays out; one not saved (opened mid-drag) goes last in the root.
    func restore(present: Set<Window>, newcomers: [Window]) throws {
        let root = containers[0].node
        let current = try workspace.rootTilingContainer
        if current !== root { // normalization flattened the root away
            try current.unbindFromParent()
            try root.bind(to: workspace, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        }
        for container in containers {
            for child in container.node.children { try child.unbindFromParent() }
        }
        for container in containers {
            container.node.layout = container.layout
            container.node.changeOrientation(container.orientation)
            container.node.stripOffset = container.stripOffset
            for (child, weight) in container.children where (child as? Window).map(present.contains) ?? true {
                try child.bind(to: container.node, adaptiveWeight: weight, index: INDEX_BIND_LAST)
            }
        }
        for window in newcomers { try window.bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST) }
        for container in containers.reversed() { // children first, so each container's own order wins
            for node in container.mru.reversed() where node.parent === container.node { node.markAsMostRecentChild() }
        }
        for (node, physical, virtual) in frames {
            node.lastAppliedLayoutPhysicalRect = physical
            node.lastAppliedLayoutVirtualRect = virtual
        }
        arrangements[workspace.name] = arrangement
    }
}
