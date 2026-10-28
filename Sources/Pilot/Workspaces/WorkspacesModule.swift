import Foundation
import PilotCore

/// Workspace actions (SPEC.md stories 62 to 64) through Pilot's tiler, on the old tiler's keys in My binds. Next and
/// previous have no key there (Hyper+Tab is the window ring). The gaps toggle (story 96) keeps Omarchy's key.
@MainActor
enum WorkspacesModule {
    static func register(into registry: inout ActionRegistry, tiler: TilerService, block: PilotBlockStore, layouts: WorkspaceLayouts) {
        do {
            // A removed workspace's keys stay Pilot's and only say so: they never reach the app in front.
            try Workspaces.register(into: &registry, kept: { tiler.workspaces }, removed: { name in
                wslog.notice("workspace \(name, privacy: .public) is removed")
                HUD.tip("Workspace \(name) is removed. Add it back on the Workspaces page.")
            }, go: { name in
                Task { await tiler.perform("workspaces.go:\(name)") { try await $0.run(.workspace(name)) } }
            }, move: { name, follow in
                Task {
                    await tiler.perform("workspaces.\(follow ? "moveFollow" : "move"):\(name)") {
                        try await $0.run(.moveWindow(id: tiler.frontWindow($0).id, toWorkspace: name, follow: follow))
                    }
                }
            })
        } catch { wslog.error("workspaces go and move: \(String(describing: error), privacy: .public)") }
        add(&registry, tiler, "next", "Next workspace", nil) { try await $0.run(.workspaceNext) }
        add(&registry, tiler, "previous", "Previous workspace", nil) { try await $0.run(.workspacePrevious) }
        add(&registry, tiler, "former", "Former workspace", Key("`")) { try await $0.run(.workspaceBackAndForth) }
        // Changes Pilot's block, which the tiler takes as its settings.
        do {
            try registry.register(Action(id: "workspaces.toggleGaps", label: "Gaps on or off", module: .workspaces,
                                         defaultKey: Key("delete", shift: true), tier: .v1) { block.toggleGaps() })
        } catch { wslog.error("workspaces.toggleGaps: \(String(describing: error), privacy: .public)") }
        // Story 107: no key in My binds, where Hyper+L focuses right; the Omarchy preset puts it there.
        do {
            try registry.register(Action(id: "workspaces.cycleLayout", label: "Cycle layout", module: .workspaces, tier: .v1) { layouts.cycle() })
        } catch { wslog.error("workspaces.cycleLayout: \(String(describing: error), privacy: .public)") }
    }

    private static func add(_ registry: inout ActionRegistry, _ tiler: TilerService, _ id: String, _ label: String, _ key: Key?,
                            body: @escaping @Sendable @MainActor (any TilerRunning) async throws -> Void) {
        let id = "workspaces.\(id)"
        do { try registry.register(Action(id: id, label: label, module: .workspaces, defaultKey: key, tier: .v1) { Task { await tiler.perform(id, body) } }) }
        catch { wslog.error("\(id, privacy: .public): \(String(describing: error), privacy: .public)") }
    }
}
