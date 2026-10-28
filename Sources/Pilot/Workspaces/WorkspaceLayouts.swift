import Foundation
import Observation
import PilotCore

/// Layout presets (story 107, card agent-bo-95422736): Cycle layout rebuilds the focused workspace as the next preset,
/// Settings › Workspaces picks one per workspace, and a workspace set to auto is rebuilt by Pilot's tiler itself whenever
/// a window comes or goes; a window dragged with the mouse lands on the screen and the side it was released on (cards
/// agent-bo-95422860, agent-bo-95422861).
@Observable @MainActor
final class WorkspaceLayouts {
    private(set) var layouts: [String: WorkspaceLayout] {
        didSet {
            WorkspaceLayout.save(layouts, to: defaults)
            tiler.layoutsChanged(layouts)
        }
    }
    @ObservationIgnored private let observers: EngineObservers
    private var tiler: TilerService { observers.tiler }
    @ObservationIgnored private let defaults: UserDefaults

    init(observers: EngineObservers, defaults: UserDefaults = .pilot()) {
        self.observers = observers
        self.defaults = defaults
        let loaded = WorkspaceLayout.load(defaults)
        layouts = loaded
        observers.tiler.layoutsChanged(loaded)
    }

    /// A workspace never set keeps its layout as windows come and go (Sven's Q229).
    func layout(_ workspace: String) -> WorkspaceLayout { layouts[workspace] ?? .unset }

    /// Settings › Workspaces: a picked preset is built at once.
    func set(_ workspace: String, _ layout: WorkspaceLayout) {
        // An autosave that leaves the row as it was writes nothing and tells the tiler nothing.
        guard layouts[workspace] != layout else { return }
        let rebuild = layout.preset != nil && layout.preset != self.layout(workspace).preset
        layouts[workspace] = layout
        guard rebuild, let preset = layout.preset else { return }
        Task { await tiler.perform("workspaces.layout:\(workspace):\(preset.rawValue)") { _ in try await build(workspace, preset) } }
    }

    /// Each workspace's layout row under its new number (Sven's Q233); the deleted workspace's goes.
    func renumber(_ r: WorkspaceRenumber) { layouts = r.rekeyed(layouts) }

    /// Cycle layout: the focused workspace's next preset, named in a tip.
    func cycle() {
        Task {
            await tiler.perform("workspaces.cycleLayout") { _ in
                guard let workspace = tiler.focused else { throw NoFocusedWorkspace() }
                var layout = layout(workspace)
                let preset = LayoutPreset.next(after: layout.preset)
                layout.preset = preset
                layouts[workspace] = layout
                HUD.tip(preset.label)
                try await build(workspace, preset)
            }
        }
    }

    /// Lays `workspace` out as `preset` in the tiler's tree, the focused window first.
    private func build(_ workspace: String, _ preset: LayoutPreset) async throws {
        try await tiler.engine.arrange(workspace, as: preset)
    }

    struct NoFocusedWorkspace: Error, CustomStringConvertible {
        var description: String { "The tiler names no focused workspace, nothing done" }
    }
}
