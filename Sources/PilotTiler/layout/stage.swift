// Pilot (Stage layout, ADR 0015, spec Projects/Pilot/specs/pilot-1-1.html T11): a Stage root tiles one group in the
// centre and shelves the rest in the hide corner, keeping the shelf's room free at the monitor's left edge. Layout itself
// is layoutStage in layoutRecursive.swift; which groups are on the stage is here.
import AppKit
import PilotCore

extension TilingContainer {
    /// The groups on the stage, in tree order: the child holding the focused window, else the most recent (the last
    /// when none is), so a stage with windows is never empty; a lone window brings every other lone window of its app along.
    @MainActor
    var stagedChildren: [TreeNode] {
        guard let index = focusedColumnIndex else { return [] }
        let focused = children[index]
        guard let app = (focused as? Window)?.app else { return [focused] }
        return children.filter { $0 === focused || ($0 as? Window)?.app.pid == app.pid }
    }

    /// The frame a drop gives `window` bound here at `index` (nil: last), as layoutStage frames it once the drop
    /// focuses it: its share of the stage with its app's other lone windows; the stage right of the shelf before the
    /// first layout.
    @MainActor
    func stageLanding(of window: Window, at index: Int?, on monitor: MonitorInfo) -> Rect {
        var order = children.filter { $0 !== window }
        order.insert(window, at: min(index ?? order.count, order.count))
        let staged = order.filter { $0 === window || ($0 as? Window)?.app.pid == window.app.pid }
        let usable = lastAppliedLayoutPhysicalRect ?? monitor.visibleRectPaddedByOuterGaps.leavingShelf()
        let strip = Strip(fractions: staged.map { _ in 1 / CGFloat(staged.count) }, usable: usable,
                          gap: CGFloat(ResolvedGaps(gaps: config.gaps, monitor: monitor).inner.horizontal))
        return strip.frames(at: 0, on: monitor.rect, sliver: 0)[staged.firstIndex { $0 === window } ?? 0]
    }
}

extension TilingContainer {
    /// The staged groups, by identity, for `shelving` (the listing reads them once per workspace).
    @MainActor
    var stagedIds: Set<ObjectIdentifier> { Set(stagedChildren.map(ObjectIdentifier.init)) }

    /// For the Window shelf (`list-windows`): whether `window`'s group is off the stage, and the first window of the
    /// joined group it is in (nil for a window alone).
    @MainActor
    func shelving(_ window: Window, staged: Set<ObjectIdentifier>) -> (shelved: Bool, group: UInt32?) {
        guard let column = column(of: window) else { return (false, nil) }
        return (!staged.contains(ObjectIdentifier(column)), column === window ? nil : column.anyLeafWindowRecursive?.windowId)
    }
}

/// The shown stages as the shelf last heard of them: each shown workspace's name, and a Stage one's windows, each marked
/// when on the stage.
@MainActor private var shownStages = ""

/// After each layout: tells the Window shelf when a shown Stage workspace's windows, its minimized ones or its stage
/// changed, or a shown workspace became or stopped being one, which no focus event says; nothing while they stay as they
/// were. Tiling off, none shows, nor on a Stage workspace while Show desktop holds its windows in the corner.
@MainActor
func announceStages() {
    let minimized = macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self)
    let now = isTilerEnabled ? monitorInfos.map { monitor in
        let workspace = monitor.activeWorkspace
        guard let root = try? workspace.rootTilingContainer, root.layout == .stage, shownDesktop?.workspace !== workspace else {
            return workspace.name
        }
        let staged = root.stagedIds
        return workspace.name + ":" + root.allLeafWindowsRecursive.map { window in
            "\(window.windowId)" + (root.shelving(window, staged: staged).shelved ? "" : "*")
        }.joined(separator: ",") + "~" + minimized.filter { $0.minimizedFrom == workspace.name }.map { "\($0.windowId)" }.joined(separator: ",")
    }.joined(separator: "|") : ""
    guard now != shownStages else { return }
    shownStages = now
    broadcastEvent(.stagesChanged(workspace: focus.workspace.name))
}

extension Rect {
    /// The rect less the Window shelf's room at its left edge, never narrower than one point.
    func leavingShelf() -> Rect {
        let room = min(CGFloat(PilotBlock.shelfWidth), width - 1)
        return Rect(topLeftX: minX + room, topLeftY: minY, width: width - room, height: height)
    }
}

extension Window {
    /// The Window shelf's click on a minimized window (ADR 0015, Q690): macOS restores it, it joins the workspace it was
    /// minimized from (else the focused one, where a restore from the Dock puts it), and takes the focus, which puts it
    /// on that workspace's stage.
    /// False for a window that is not minimized.
    @MainActor
    func unminimize() async throws -> Bool {
        guard parent === macosMinimizedWindowsContainer, case .macos(let prevParentKind) = layoutReason,
              let window = self as? MacWindow else { return false }
        window.setNativeMinimized(false)
        let workspace = minimizedFrom.map(Workspace.get(byName:)) ?? focus.workspace
        try await exitMacOsNativeUnconventionalState(window: self, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
        return try focusWindow()
    }
}
