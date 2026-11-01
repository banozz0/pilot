import Foundation
import PilotCore

/// Each AeroCommand as its typed call (card agent-bo-95422997, AC2), with what the CLI would print: the `--json`
/// listing for a query, nothing for an action. A call that did nothing throws TilerCallRefused, as the CLI exits 1.
@MainActor
func perform(_ command: AeroCommand) async throws -> String {
    let refused = TilerCallRefused(command: command.arguments)
    func done(_ ok: Bool) throws -> String {
        guard ok else { throw refused }
        return ""
    }
    func window(_ id: Int) throws -> Window {
        guard let window = UInt32(exactly: id).flatMap(Window.get(byId:)) else { throw refused }
        return window
    }
    func focused() throws -> Window {
        guard let window = focus.windowOrNil else { throw refused }
        return window
    }
    switch command {
        case .workspace(let name): return try done(focusWorkspace(named: name))
        case .workspaceNext: return try done(focusNextWorkspace(true))
        case .workspacePrevious: return try done(focusNextWorkspace(false))
        case .workspaceBackAndForth: return try done(focusPreviousWorkspace())
        case .moveWindow(let id, let name, let follow): return try done(window(id).moveToWorkspace(Workspace.get(byName: name), focusFollowsWindow: follow))
        case .listWindows(let scope): return try json(await listWindows(TilerWindowScope(scope)).map(\.cliFields))
        case .listVisibleWorkspaces:
            return try json(visibleWorkspaces().map {
                var row: [String: Any] = ["workspace": $0.name, "monitor-id": $0.monitorId, "monitor-name": $0.monitorName,
                                          "workspace-root-container-layout": $0.rootLayout.rawValue]
                if let uuid = $0.displayUUID { row["display-uuid"] = uuid }
                if $0.showingDesktop { row["workspace-showing-desktop"] = true }
                return row
            })
        case .focusedWorkspace: return try json([focusedWorkspace().cliFields])
        case .mouseWorkspace: return try json([mouseWorkspace().cliFields])
        case .eval(let commands):
            // AeroSpace's `;`: each runs whatever the one before it did; a fault still ends the session.
            var out = ""
            for command in commands {
                do { out += try await perform(command) } catch is TilerCallRefused {}
            }
            return out
        case .enable(let on): await setTilerEnabled(on); return ""
        case .focus(let direction): return try done(await focused().focusNeighbor(CardinalDirection(direction)))
        case .focusWindow(let id): return try done(window(id).focusWindow())
        case .focusRing(let next): return try done(focus.workspace.focusRing(from: focus.windowOrNil, next: next))
        case .joinWith(let id, let direction): return try done(window(id).join(with: CardinalDirection(direction)))
        case .balanceSizes(let name): try Workspace.get(byName: name).balanceSizes(); return ""
        case .closeAllButCurrent: try focus.workspace.closeAll(but: focused()); return ""
        case .toggleDesktop: try toggleShownDesktop(); return ""
        case .swap(let id, let direction): return try done(window(id).swap(CardinalDirection(direction)))
        case .resize(let id, let axis, let step): return try done(window(id).resize(axis == .width ? .h : .v, by: CGFloat(step)))
        case .flipSplit(let id): return try done(window(id).flipSplit())
        case .toggleScrolling(let name): return try done(Workspace.get(byName: name).setRootLayout(toggling: [.tiles, .scrolling]))
        case .cycleColumnWidth(let id, let forward): return try done(window(id).cycleColumnWidth(forward: forward))
        case .centreColumn(let id): return try done(window(id).centreColumn())
        case .maximiseColumn(let id): return try done(window(id).toggleColumnMaximised())
        case .leaveStack(let id): return try done(window(id).leaveStack())
        case .setColumnWidth(let id, let points): return try done(window(id).setColumnWidth(points: CGFloat(points)))
        case .focusMonitor(let direction): return try done(focusMonitor(CardinalDirection(direction)))
        case .moveToMonitor(let id, let direction): return try done(window(id).moveToMonitor(CardinalDirection(direction)))
        case .setFloating(let id, let on): return try done(await window(id).setLayout(on ? .floating : .tiling))
        case .setPinned(let id, let on): return try done(await window(id).setPinned(on))
        case .flatten(let name): try Workspace.get(byName: name).flatten(); return ""
        case .setRootLayout(let name, let raw):
            guard let layout = TilerLayout(rawValue: raw) else { throw refused }
            return try done(Workspace.get(byName: name).setRootLayout(toggling: [layout]))
        case .move(let id, let direction): return try done(window(id).move(CardinalDirection(direction)))
        case .unminimize(let id): return try done(await window(id).unminimize())
    }
}

extension Window {
    /// The column holding this window takes `points` of the strip, the inverse of the strip's f × (usable + gap) − gap,
    /// snapped to a width in the settings when it is that one to within a point; false outside a scrolling workspace.
    @MainActor
    fileprivate func setColumnWidth(points: CGFloat) -> Bool {
        guard let (_, column) = scrollingColumn, let monitor = nodeWorkspace?.workspaceMonitor else { return false }
        let gap = CGFloat(ResolvedGaps(gaps: config.gaps, monitor: monitor).inner.horizontal), across = monitor.visibleRectPaddedByOuterGaps.width + gap
        let width = ((points + gap) / across).coerce(in: 0.1 ... 1)
        column.columnWidth = config.scrollingWidths.first { abs($0 - width) * across < 1 } ?? width
        return true
    }
}

private func json(_ rows: [[String: Any]]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self)
}

extension CardinalDirection {
    init(_ direction: Direction) {
        self = switch direction {
            case .left: .left
            case .right: .right
            case .up: .up
            case .down: .down
        }
    }
}

extension TilerWindowScope {
    init(_ scope: AeroCommand.WindowScope) {
        self = switch scope {
            case .all: .all
            case .focused: .focused
            case .workspace(let name): .workspace(name)
            case .minimized: .minimized
        }
    }
}

extension TilerWindow {
    /// AeroWindow.format's fields, keyed as the CLI's `--json` prints them.
    var cliFields: [String: Any] {
        var fields: [String: Any] = ["window-id": id, "app-name": appName, "app-bundle-id": bundleId, "app-pid": pid, "workspace": workspace,
                                     "monitor-id": monitorId, "window-layout": layout, "window-title": title, "window-pinned": pinned]
        if shelved { fields["window-shelved"] = true }
        if let group { fields["window-group"] = group }
        return fields
    }
}

extension TilerWorkspace {
    var cliFields: [String: Any] { ["workspace": name, "workspace-root-container-layout": rootLayout.rawValue] }
}
