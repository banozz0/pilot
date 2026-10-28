import AppKit
import Observation
import PilotCore

/// Workspace snapshots (stories 69 and 71): save the focused workspace's windows, and put them back, reopening apps
/// that are closed. The tiler gives no frames, so Pilot reads them from the window list (the tiler's ids are
/// CGWindowIDs) and sets floating ones through Accessibility. The plans are SnapshotRestore's; this runs them.
@Observable @MainActor
final class WorkspaceSnapshots {
    private static let reopenKey = "snapshots.reopenApps"

    /// Snapshots by workspace, as the store has them.
    private(set) var saved: [String: Snapshot] = [:]
    /// On unless switched off in Settings › Snapshots.
    var reopenApps: Bool { didSet { defaults.set(reopenApps, forKey: Self.reopenKey) } }
    @ObservationIgnored private let defaults: UserDefaults
    /// The last store failure, shown on the settings page.
    private(set) var lastError: String?

    private let observers: EngineObservers
    private let store = SnapshotStore.standard
    private var tiler: TilerService { observers.tiler }

    init(observers: EngineObservers, defaults: UserDefaults = .pilot()) {
        self.observers = observers
        self.defaults = defaults
        reopenApps = defaults.object(forKey: Self.reopenKey) as? Bool ?? true
        do { saved = try store.load() } catch { fail("snapshots not read", error) }
    }

    static func register(into registry: inout ActionRegistry, snapshots: WorkspaceSnapshots) {
        do { try Snapshot.register(into: &registry, save: { snapshots.save() }, restore: { snapshots.restore() }) }
        catch { wslog.error("snapshot actions: \(String(describing: error), privacy: .public)") }
    }

    /// Saves the focused workspace, replacing its snapshot. A pinned pop-out belongs to every workspace, so to no snapshot.
    func save() {
        Task {
            await tiler.perform("workspaces.saveSnapshot") { client in
                guard let workspace = try await client.focusedWorkspace() else { throw NoFocusedWorkspace() }
                let windows = try await unpinned(client, .workspace(workspace.workspace))
                guard let snapshot = Snapshot.capture(workspace, windows: windows, frames: onScreen().mapValues(\.frame), at: .now) else {
                    return HUD.tip("This workspace has no windows: nothing saved")
                }
                do { try store.save(snapshot) } catch { fail("snapshot not saved", error); throw error }
                saved[snapshot.workspace] = snapshot
                lastError = nil
                wslog.notice("snapshot: workspace \(snapshot.workspace, privacy: .public) saved, \(snapshot.layout, privacy: .public), \(Self.describe(snapshot.windows.map { ($0, $0.frame) }), privacy: .public)")
                HUD.tip("Workspace \(snapshot.workspace) saved: \(snapshot.windows.count) windows")
            }
        }
    }

    /// Restores one workspace's snapshot, the focused workspace's when none is named; switches to it first, so the
    /// windows Pilot places are on screen.
    func restore(_ workspace: String? = nil) {
        Task {
            await tiler.perform("workspaces.restoreSnapshot") { client in
                guard let name = workspace ?? tiler.focused else { throw NoFocusedWorkspace() }
                guard let snapshot = saved[name] else { return HUD.tip("Workspace \(name) has no snapshot") }
                if name != tiler.focused {
                    try await client.run(.workspace(name))
                    try await Task.sleep(for: tilerSettle)
                }
                let reopened = reopenApps ? await reopen(snapshot, client) : []
                let plan = SnapshotRestore(snapshot, current: try await unpinned(client, .all))
                // Each step one eval, as a preset's rebuild runs: a call with nothing to do (the root already in the
                // saved layout) is refused, which alone would end the restore there.
                try await client.run(.eval(plan.placeCommands))
                try await Task.sleep(for: tilerSettle)
                let placed = try await unpinned(client, .workspace(name))
                try await client.run(.eval(plan.arrangeCommands(windows: placed, frames: onScreen().mapValues(\.frame))))
                let windows = onScreen()
                for (id, frame) in plan.floatingFrames { windows[id].flatMap(AXWindow.matching)?.setFrame(frame) }
                report(plan, reopened: reopened)
            }
        }
    }

    /// One log line with where each window landed, read after a settle: the proof of order, widths and floating frames.
    private func report(_ plan: SnapshotRestore, reopened: [String]) {
        Task {
            try? await Task.sleep(for: tilerSettle)
            let now = onScreen()
            let placed = plan.matches.map { ($0.saved, now[$0.window.id]?.frame ?? .zero) }
            let name = plan.snapshot.workspace
            let missing = plan.unmatched.map { "\($0.appName) '\($0.title)'" }.joined(separator: ", ")
            wslog.notice("snapshot: workspace \(name, privacy: .public) restored, \(plan.matches.count) of \(plan.snapshot.windows.count) windows, reopened \(reopened.joined(separator: ", "), privacy: .public); \(Self.describe(placed), privacy: .public)\(missing.isEmpty ? "" : "; not found: \(missing)", privacy: .public)")
            HUD.tip(missing.isEmpty ? "Workspace \(name) restored" : "Workspace \(name) restored; not found: \(missing)")
        }
    }

    /// Every snapshot under its workspace's new number (Sven's Q233); the deleted workspace's goes.
    func renumber(_ r: WorkspaceRenumber) {
        do {
            saved = try store.renumber(r)
            lastError = nil
        } catch { fail("snapshots not renumbered", error) }
    }

    func delete(_ workspace: String) {
        do {
            try store.delete(workspace: workspace)
            saved[workspace] = nil
            lastError = nil
            wslog.notice("snapshot: workspace \(workspace, privacy: .public) deleted")
        } catch { fail("snapshot not deleted", error) }
    }

    /// Opens the saved apps that are not running and waits up to 10 s for each to show as many windows as were saved.
    private func reopen(_ snapshot: Snapshot, _ client: any TilerRunning) async -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let missing = SnapshotRestore.missingApps(snapshot, running: running).filter { AppsModule.open(bundle: $0) }
        guard !missing.isEmpty else { return [] }
        let wanted = Dictionary(snapshot.windows.filter { missing.contains($0.bundleId) }.map { ($0.bundleId, 1) }, uniquingKeysWith: +)
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let windows = try? await client.windows(.all) else { continue }
            if wanted.allSatisfy({ bundle, count in windows.count { $0.bundleId == bundle } >= count }) { break }
        }
        return missing.map { AppsModule.appName($0) ?? $0 }
    }

    /// The tiler's windows less any pinned pop-out, which a restore must never match and move.
    private func unpinned(_ client: any TilerRunning, _ scope: AeroCommand.WindowScope) async throws -> [AeroWindow] {
        try await client.windows(scope).filter { !$0.isPinned }
    }

    /// On-screen windows by the tiler's id.
    private func onScreen() -> [Int: WindowInfo] { observers.windowsByID() }

    /// "Finder 'Home' tiled 8,33 952x1039 · …", the log's proof of order, widths and floating frames.
    private static func describe(_ windows: [(Snapshot.Window, CGRect)]) -> String {
        windows.map { w, f in
            "\(w.appName) '\(w.title)' \(w.floating ? "floating" : "tiled") \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
        }.joined(separator: " · ")
    }

    private func fail(_ what: String, _ error: Error) {
        lastError = "\(what): \(error)"
        wslog.error("\(self.lastError ?? "", privacy: .public)")
    }

    struct NoFocusedWorkspace: Error, CustomStringConvertible {
        var description: String { "no focused workspace known yet, nothing restored" }
    }
}
