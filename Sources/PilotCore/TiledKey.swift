import Foundation

/// A tiled window key (stories 8, 9, 11 and 67) and where it runs: Pilot's tiler for tiled windows, Pilot's own
/// Accessibility code for floating ones (story 9) and whenever the tiler is off (SPEC.md, Windows module line).
public enum TiledKey: Equatable, Sendable {
    case focus(Direction)
    case focusRing(next: Bool)
    /// The old tiler's service mode (Sven, 2026-10-05): join a group, equal sizes, reset the layout, close the others.
    case join(Direction)
    case balance
    case resetLayout
    case closeOthers
    case swap(Direction)
    case resize(AeroCommand.Axis, by: Int)
    case flipSplit
    case toggleScrolling
    /// The scrolling layout's column keys (spec scrolling-layout): step a column's width, centre it.
    case cycleColumnWidth(forward: Bool)
    case centreColumn
    /// T10: maximise the column and back; leave the column's stack.
    case maximiseColumn
    case leaveStack
    case focusMonitor(Direction)
    case sendToMonitor(Direction)

    public enum Route: Equatable, Sendable {
        case tiler(AeroCommand)
        case pilot
        /// Nothing can do it, and why: a floating window has no split, and only the tiler tiles.
        case unavailable(String)
    }

    /// `window` is the tiler's focused window, already checked to be the frontmost app's; nil when there is none, as
    /// on an empty workspace, where focus still moves. `tiler` names the tiler that is not running.
    public func route(running: Bool, window: AeroWindow?, tiler: String) -> Route {
        switch (self, running, window) {
        case (_, false, _): return needsTiler ? .unavailable("\(tiler) is not running") : .pilot
        case (.focus(let d), true, _): return .tiler(.focus(d))
        case (.focusRing(let next), true, _): return .tiler(.focusRing(next: next))
        case (.focusMonitor(let d), true, _): return .tiler(.focusMonitor(d))
        case (_, true, nil): return .unavailable("No window to act on")
        case (_, true, let window?): return route(on: window)
        }
    }

    /// Keys only the tiler can do: Pilot's key code outside it has no split, group, ring, column or layout.
    private var needsTiler: Bool {
        switch self {
        case .focus, .swap, .resize, .focusMonitor, .sendToMonitor: false
        case .flipSplit, .toggleScrolling, .cycleColumnWidth, .centreColumn, .maximiseColumn, .leaveStack, .focusRing, .join, .balance, .resetLayout, .closeOthers: true
        }
    }

    /// A column key's command for the window `id`; only the column keys reach it.
    private func columnCommand(_ id: Int) -> AeroCommand {
        switch self {
        case .cycleColumnWidth(let forward): .cycleColumnWidth(id: id, forward: forward)
        case .maximiseColumn: .maximiseColumn(id: id)
        case .leaveStack: .leaveStack(id: id)
        default: .centreColumn(id: id)
        }
    }

    private func route(on window: AeroWindow) -> Route {
        switch self {
        case .focus(let d): return .tiler(.focus(d))
        case .focusRing(let next): return .tiler(.focusRing(next: next))
        case .swap(let d): return window.isFloating ? .pilot : .tiler(.swap(id: window.id, d))
        case .resize(let axis, let step): return window.isFloating ? .pilot : .tiler(.resize(id: window.id, axis, by: step))
        case .flipSplit: return window.isFloating ? .unavailable("A floating window has no split") : .tiler(.flipSplit(id: window.id))
        case .toggleScrolling: return .tiler(.toggleScrolling(workspace: window.workspace))
        case .cycleColumnWidth, .centreColumn, .maximiseColumn, .leaveStack:
            if window.isFloating { return .unavailable("A floating window has no column") }
            return .tiler(columnCommand(window.id))
        case .join(let d): return window.isFloating ? .unavailable("A floating window joins no group") : .tiler(.joinWith(id: window.id, d))
        case .balance: return .tiler(.balanceSizes(workspace: window.workspace))
        case .resetLayout: return .tiler(.flatten(workspace: window.workspace))
        case .closeOthers: return .tiler(.closeAllButCurrent)
        case .focusMonitor(let d): return .tiler(.focusMonitor(d))
        case .sendToMonitor(let d): return .tiler(.moveToMonitor(id: window.id, d))
        }
    }
}
