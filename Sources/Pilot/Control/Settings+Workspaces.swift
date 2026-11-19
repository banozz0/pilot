import Foundation
import PilotCore

extension SettingsSchema {
    /// The Workspaces page's keys: how many workspaces Pilot keeps, changed one at a time as its Add does and as Delete on
    /// the highest (its windows move to the one before it). The swipe (Settings+Tiling) sits on this page too; `pilot
    /// remove workspaces <n>` deletes any one.
    func registerWorkspaces(list: WorkspaceList) {
        register([
            .int("workspaces.count", "Workspaces", page: "workspaces", range: 1...Workspaces.all.count, standard: Workspaces.all.count,
                 read: { list.count }, write: { n in
                     while list.count < n { list.add() }
                     while list.count > n { list.remove() }
                 }),
        ])
    }
}
