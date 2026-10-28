import Foundation
import Observation
import PilotCore

/// Each workspace's Monitor pick (N7, Sven 2026-10-09): Any, Main or one display. Pilot's own setting, saved in its
/// defaults (WorkspaceMonitors), the one owner of the pins: it hands them to TilerService, which builds the
/// tiler's settings with them. ~/.aerospace.toml is read once as an import on the first launch, to start from what its
/// table pinned; Pilot never writes it.
@Observable @MainActor
final class WorkspaceMonitorStore {
    private let tiler: TilerService
    private let block: PilotBlockStore
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var pins: [String: MonitorPin]
    /// The last failure to hand the engine its pins, shown on the Tiling tab; nil after a clean one.
    private(set) var lastError: String?

    init(tiler: TilerService, block: PilotBlockStore, defaults: UserDefaults = .pilot()) {
        self.tiler = tiler
        self.block = block
        self.defaults = defaults
        pins = WorkspaceMonitors.pins(in: defaults, carryingFrom: (try? String(contentsOfFile: PilotBlockStore.path, encoding: .utf8)) ?? "",
                                      displays: ConnectedDisplay.current)
        tiler.pins = pins
    }

    /// The workspaces kept (WorkspaceList): the Monitors block draws a row for each.
    var workspaces: [String] { tiler.workspaces }

    /// Pins `workspace` to `pin`, or frees it with nil (Any), saves, and hands the own tiler its new settings.
    func set(_ pin: MonitorPin?, for workspace: String) {
        guard pins[workspace] != pin else { return }
        keep(pin, for: [workspace])
        Task {
            do {
                try await tiler.settingsChanged(block.block)
                lastError = nil
            } catch {
                lastError = String(describing: error)
                wslog.error("workspace monitors: \(self.lastError ?? "", privacy: .public)")
            }
        }
    }

    /// Workspaces just added open on the main display until another is picked (Sven 2026-10-09); one pinned keeps its
    /// pin. Saved only: WorkspaceList hands the tiler the new list and pins at once.
    func openOnMain(_ added: [String]) {
        let unpinned = added.filter { pins[$0] == nil }
        if !unpinned.isEmpty { keep(.main, for: unpinned) }
    }

    /// Each pin under its workspace's new number (Sven's Q233): the deleted one's goes, so the number freed at the end
    /// starts on Main when it is added again. Saved only, as openOnMain.
    func renumber(_ r: WorkspaceRenumber) {
        pins = r.rekeyed(pins)
        tiler.pins = pins
        WorkspaceMonitors.save(pins, in: defaults)
        wslog.notice("workspace monitors renumbered: \(r.renamed.filter { $0.key != $0.value }.map { "\($0.key)→\($0.value)" }.sorted().joined(separator: " "), privacy: .public)")
    }

    private func keep(_ pin: MonitorPin?, for workspaces: [String]) {
        for workspace in workspaces { pins[workspace] = pin }
        tiler.pins = pins
        WorkspaceMonitors.save(pins, in: defaults)
        wslog.notice("workspace \(workspaces.joined(separator: ", "), privacy: .public) monitor: \(pin.map { String(describing: $0) } ?? "any", privacy: .public)")
    }
}
