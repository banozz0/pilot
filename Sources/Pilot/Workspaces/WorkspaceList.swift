import Foundation
import Observation
import PilotCore

/// Which workspaces Pilot keeps (Sven 2026-10-09): 1 to 9, nine by default, added and deleted on the Workspaces page.
/// Pilot's own setting (Workspaces, `workspaces.kept` in its defaults), the one owner of the list: it sets
/// TilerService's list, which the own tiler's settings, the Monitors rows, Home and the go and move binds read. Adding makes
/// the next number and opens it on the main display; deleting takes the picked one (Sven 2026-10-17, not the last) and
/// closes its number (Sven's Q233): its windows go to the one before it, and each one after it moves down a number with
/// everything tied to it (WorkspaceRenumber), so Hyper+N is always the Nth workspace.
@Observable @MainActor
final class WorkspaceList {
    private let tiler: TilerService
    private let block: PilotBlockStore
    private let monitors: WorkspaceMonitorStore
    @ObservationIgnored private let defaults: UserDefaults
    /// The stores tied to a workspace's number that are not the list's own (presets, layouts, snapshots), renumbered with
    /// it; the engine sets them (follow).
    @ObservationIgnored private var renumbered: @MainActor (WorkspaceRenumber) -> Void = { _ in }
    private(set) var names: [String]
    /// The last failure to hand the engine the list, shown on the Workspaces page; nil after a clean one.
    private(set) var lastError: String?

    var count: Int { names.count }
    var canAdd: Bool { count < Workspaces.all.count }
    var canRemove: Bool { count > 1 }

    init(tiler: TilerService, block: PilotBlockStore, monitors: WorkspaceMonitorStore, defaults: UserDefaults = .pilot()) {
        self.tiler = tiler
        self.block = block
        self.monitors = monitors
        self.defaults = defaults
        let first = defaults.object(forKey: Workspaces.key) == nil && defaults.object(forKey: Workspaces.keptKey) == nil
        names = Workspaces.kept(in: defaults)
        tiler.workspaces = names
        // The first launch with the setting: 5 to 9 are new, so they open on Main as an added one does.
        if first {
            Workspaces.save(kept: names, in: defaults)
            monitors.openOnMain(Array(names.dropFirst(Workspaces.before)))
        }
    }

    /// The stores renumbered with the list; a test leaves `snapshots` and `wallpaper` out, since every test shares the
    /// snapshots file and the wallpaper store is Pilot's own.
    func follow(presets: WorkspacePresets, layouts: WorkspaceLayouts, snapshots: WorkspaceSnapshots?, wallpaper: WallpaperSettings? = nil) {
        renumbered = { r in
            presets.renumber(r)
            layouts.renumber(r)
            snapshots?.renumber(r)
            wallpaper?.renumber(r)
        }
    }

    /// Adds the next number, on the main display unless it is pinned already; nil when all nine are kept.
    @discardableResult func add() -> String? {
        guard let added = Workspaces.all.first(where: { !names.contains($0) }) else { return nil }
        set(names + [added])
        monitors.openOnMain([added])
        apply()
        return added
    }

    /// Deletes `workspace`, the last when nil, and closes its number (WorkspaceRenumber).
    func remove(_ workspace: String? = nil) {
        guard canRemove, let gone = workspace ?? names.last, names.contains(gone) else { return }
        renumber(WorkspaceRenumber(deleting: gone, from: names))
    }

    /// The gaps a build of 2026-10-17 could leave (1, 2, 4) close up (1, 2, 3), data and windows following. The engine
    /// runs it once, after follow.
    func closeGaps() {
        let r = WorkspaceRenumber(deleting: nil, from: names)
        if r.changes { renumber(r) }
    }

    /// The list, the pins, the app rules and the followed stores under the new numbers at once; then the windows move
    /// down, the workspace that was on screen is shown under its new number, and the tiler takes the shorter list.
    private func renumber(_ r: WorkspaceRenumber) {
        let focused = tiler.focused
        set(r.names)
        monitors.renumber(r)
        // Worked out inside the edit, so one queued before it is renumbered too rather than written over.
        if block.block.rules.contains(where: { r.new($0.workspace) != $0.workspace }) { block.edit { $0.rules = r.rules($0.rules) } }
        renumbered(r)
        Task {
            await tiler.perform("workspaces.remove:\(r.gone ?? "gaps")") { runner in
                for move in r.moves {
                    for window in try await runner.windows(.workspace(move.from)) {
                        try await runner.run(.moveWindow(id: window.id, toWorkspace: move.to))
                    }
                }
                if let focused, r.new(focused) != focused { try await runner.run(.workspace(r.new(focused))) }
            }
            await settingsChanged()
        }
    }

    private func set(_ kept: [String]) {
        names = Workspaces.all.filter(kept.contains)
        Workspaces.save(kept: names, in: defaults)
        tiler.workspaces = names
        wslog.notice("workspaces: \(self.names.joined(separator: " "), privacy: .public)")
    }

    private func apply() { Task { await settingsChanged() } }

    private func settingsChanged() async {
        do {
            try await tiler.settingsChanged(block.block)
            lastError = nil
        } catch {
            lastError = String(describing: error)
            wslog.error("workspaces: \(self.lastError ?? "", privacy: .public)")
        }
    }
}
