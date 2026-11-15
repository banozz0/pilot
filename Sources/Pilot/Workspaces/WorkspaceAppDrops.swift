import Foundation
import PilotCore

/// Makes a WorkspaceAppDrop, the Workspaces page's drop and `pilot workspace move` alike: the tiler's windows read now
/// (none while it is not running), the drafts saved as the editor saves them, the rules changed, then the windows moved.
@MainActor
struct WorkspaceAppDrops {
    let presets: WorkspacePresets
    let layouts: WorkspaceLayouts
    let block: PilotBlockStore
    let tiler: TilerService

    /// `app` from workspace `from` dropped on `to`, on `onto`'s tile when given; `draft` reads a workspace's draft as the
    /// page shows it (the saved one for the command). `planned` hears the plan before anything is written, so the page
    /// drops its own edits of the workspaces it saves.
    @discardableResult
    func drop(_ app: String, from: String, to: String, onto: String? = nil, draft: (String) -> WorkspacePresetDraft,
              planned: (WorkspaceAppDrop) -> Void = { _ in }) async throws(WorkspaceAppDrop.Refused) -> WorkspaceAppDrop {
        let windows = await listed()
        let plan = try WorkspaceAppDrop.plan(app: app, from: from, to: to, onto: onto, draft: draft, windows: windows, rules: block.block.rules)
        planned(plan)
        for (workspace, draft) in plan.drafts.sorted(by: { $0.key < $1.key }) where !presets.write(draft, to: workspace, layouts: layouts) {
            throw WorkspaceAppDrop.Refused(presets.lastError ?? "workspace \(workspace) not saved: \(draft.sizesProblem ?? "refused")")
        }
        try await carry(plan, "\(plan.kind.rawValue):\(app)")
        return plan
    }

    /// A row of Always lands here from `from` dropped on workspace `to`.
    @discardableResult
    func dropRule(_ app: String, from: String, to: String) async throws(WorkspaceAppDrop.Refused) -> WorkspaceAppDrop {
        let plan = try WorkspaceAppDrop.rule(app: app, from: from, to: to, windows: await listed())
        try await carry(plan, "rule:\(app)")
        return plan
    }

    private func listed() async -> [AeroWindow] { (try? await tiler.runner.windows(.all)) ?? [] }

    /// The rules, one edit for them all, then the tiler calls in order; the dropdown's and Home's lists read again after.
    private func carry(_ plan: WorkspaceAppDrop, _ what: String) async throws(WorkspaceAppDrop.Refused) {
        if !plan.rules.isEmpty {
            let rules = plan.rules
            let written = await withCheckedContinuation { done in
                block.edit({ block in
                    for rule in rules { if let i = block.rules.firstIndex(where: { $0.appId == rule.appId }) { block.rules[i] = rule } }
                }, done: { done.resume(returning: $0) })
            }
            if !written { throw WorkspaceAppDrop.Refused("app rules not changed: \(block.lastError ?? "the tiler refused them")") }
        }
        guard !plan.commands.isEmpty else { return }
        // A window closed since the list was read stops nothing after it.
        await tiler.perform("workspaces.drop.\(what)") { runner in
            for command in plan.commands {
                do { try await runner.run(command) } catch where tiler.isRunning {
                    wslog.error("workspaces.drop: \(command.arguments.joined(separator: " "), privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        await tiler.refreshOccupied()
    }
}
