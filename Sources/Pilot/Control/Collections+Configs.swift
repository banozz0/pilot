import Foundation
import PilotCore

extension ControlVerbs {
    /// Configs and Configs › Agents as read-only collections (CLI W17): each card's fields, so the page's
    /// filter and its All / In dotfiles chips are a filter on the rows.
    func registerConfigCollections(_ app: ControlConfigs) {
        register(ControlCollection("configs", help: "App configs Pilot found, by group (agents' are in instructions), Pilot's own binds.json and workspace-presets.json last (readOnly): path, real file, inDotfiles, changed, first lines (secrets as dots); known ones not on this Mac come last with present false. Read-only.",
                                   rowKey: "id", list: { app.rows(.configs) }))
        register(ControlCollection("instructions", help: "Configs › Agents: agents' settings (Claude Code, Codex, Hermes and each profile, Empryo, opencode; known ones not on this Mac last with present false), then their instruction files: Claude Code's CLAUDE.md, Codex's AGENTS.md, each Hermes SOUL.md (generated), ~/code's own brief and each top-level ~/code repo's AGENTS.md, else its CLAUDE.md (not oss or _ folders), each file once however many links reach it, with the configs' row fields. Read-only.",
                                   rowKey: "id", list: { app.rows(.instructions) }))
    }
}
