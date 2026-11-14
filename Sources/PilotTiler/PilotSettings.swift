import CoreGraphics
import PilotCore

extension TilerSettings {
    /// The engine's settings from Pilot's own (card agent-bo-95422997, AC1): the block's gaps, top bar (in the top gap, and
    /// as the edge floating windows keep under), scrolling layout, app rules and
    /// floats (by bundle id, then the float lists: whole app names, titles containing the text), the workspaces kept as
    /// persistent ones (WorkspaceList), and each workspace pinned to its monitor (WorkspaceMonitors, N7).
    public init(block: PilotBlock, workspaces: [String] = Workspaces.all, pins: [String: MonitorPin]) {
        self.init()
        let inner = block.gapsOn ? block.gaps.inner : 0, outer = block.gapsOn ? block.gaps.outer : 0
        let heights = block.topBar.compactMap { bar in
            MonitorDescription.pattern(PilotBlock.namePattern([bar.monitor])).map { PerMonitorValue(description: $0, value: bar.height) }
        }
        let bars = heights.map { PerMonitorValue(description: $0.description, value: outer + $0.value) }
        topBar = heights.isEmpty ? .constant(0) : .perMonitor(heights, default: 0)
        // Pilot's dock (spec pilot-dock): its room at the foot of its screen, in the bottom gap.
        let docks = block.dock.compactMap { dock in
            MonitorDescription.pattern(PilotBlock.namePattern([dock.monitor])).map { PerMonitorValue(description: $0, value: outer + dock.height) }
        }
        gaps = Gaps(
            inner: .init(vertical: inner, horizontal: inner),
            outer: .init(left: .constant(outer), bottom: docks.isEmpty ? .constant(outer) : .perMonitor(docks, default: outer), top: bars.isEmpty ? .constant(outer) : .perMonitor(bars, default: outer), right: .constant(outer)),
        )
        // Spec scrolling-layout T8 (Sven's Q42 and Q43, 2026-10-12): widths fit the window count and the strip glides at one
        // speed; the block's new width and speed still decode, hidden, and set nothing.
        scrollingWidths = block.scrolling.widths.map { CGFloat($0.fraction) }
        scrollingNewWidth = Strip.automaticWidth
        scrollingSliver = CGFloat(block.scrolling.sliver)
        scrollingGlide = Strip.glide
        scrollingCentre = block.scrolling.centre
        scrollingAppWidths = Dictionary(block.scrolling.apps.compactMap { rule in rule.width.map { (rule.appId, CGFloat($0.fraction)) } },
                                        uniquingKeysWith: { first, _ in first })
        glide = block.glide
        persistentWorkspaces = workspaces
        workspaceToMonitorForceAssignment = pins.mapValues(Self.monitors)
        // A kept focus first, going on to the rules after it, so an app rule still moves the window (T11).
        windowRules = block.scrolling.apps.filter { !$0.focus }.map { WindowRule(appId: $0.appId, actions: [.keepFocus], checkFurtherRules: true) }
        windowRules += block.rules.map { WindowRule(appId: $0.appId, actions: [.moveToWorkspace($0.workspace)]) }
            + block.floatAppIds.map { WindowRule(appId: $0, actions: [.float]) }
        let floats: [([String], ([String]) -> String, (CaseInsensitiveRegex) -> WindowRule)] = [
            (block.floatApps, PilotBlock.namePattern, { WindowRule(appNameRegexSubstring: $0, actions: [.float]) }),
            (block.floatTitles, PilotBlock.titlePattern, { WindowRule(windowTitleRegexSubstring: $0, actions: [.float]) }),
        ]
        for (names, pattern, rule) in floats where !names.isEmpty {
            if let regex = try? CaseInsensitiveRegex.new(pattern(names)).get() { windowRules.append(rule(regex)) }
        }
    }

    /// Where a pinned workspace opens, first match wins: its display, else main, so it waits there while its display is
    /// gone and goes back once the display returns, with the windows it took; the ones it gained on main stay there
    /// (gcMonitors). A carried-over pin is AeroSpace's description, read as AeroSpace did.
    static func monitors(_ pin: MonitorPin) -> [MonitorDescription] {
        switch pin {
            case .main: [.main]
            case .display(_, let id?): [.displayId(id), .main]
            case .display(let name, nil): ((try? parseMonitorDescription(name).get()).map { [$0] } ?? []) + [.main]
        }
    }
}
