import Foundation

/// The Workspaces page's edits (card agent-bo-95423003): each workspace shown in the editor's look, one draft per
/// workspace kept while another shows, so a half-made change is not lost by looking elsewhere. A draft that matches
/// what is saved again is no edit at all.
public struct WorkspacePageDrafts: Equatable, Sendable {
    private var edits: [String: WorkspacePresetDraft] = [:]

    public init() {}

    /// What a workspace has saved, as a draft: its preset, else a fresh one from its layout row.
    public static func baseline(_ workspace: String, saved: WorkspacePreset?, row: WorkspaceLayout?) -> WorkspacePresetDraft {
        saved.map { WorkspacePresetDraft($0, workspace: workspace, row: row) } ?? .fresh(workspace: workspace, row: row)
    }

    /// The draft the page shows: the edit, else what is saved.
    public func draft(_ workspace: String, saved: WorkspacePreset?, row: WorkspaceLayout?) -> WorkspacePresetDraft {
        edits[workspace] ?? Self.baseline(workspace, saved: saved, row: row)
    }

    public mutating func set(_ draft: WorkspacePresetDraft, for workspace: String, saved: WorkspacePreset?, row: WorkspaceLayout?) {
        edits[workspace] = draft == Self.baseline(workspace, saved: saved, row: row) ? nil : draft
    }

    public func isEdited(_ workspace: String) -> Bool { edits[workspace] != nil }

    /// The workspaces with an edit not written yet, in name order.
    public var edited: [String] { edits.keys.sorted() }

    public mutating func revert(_ workspace: String) { edits[workspace] = nil }

    /// What an autosave does with a draft (Sven 2026-10-17: every change saves at once).
    public enum Save: Equatable, Sendable {
        /// The preset, given to the workspace, with Keep this layout.
        case preset(WorkspacePreset, keepLayout: Bool)
        /// No app placed and no name: the layout row alone, and the preset the workspace had taken off it.
        case layout(WorkspaceLayout, removePreset: Bool)
        /// Not saved, in the editor's words.
        case refused(String)
    }

    /// A draft with no name of its own saves as "Workspace 3"; a named one keeps its preset with no app in it, so taking
    /// the last app off never loses the name.
    public static func save(_ draft: WorkspacePresetDraft, workspace: String, hadPreset: Bool) -> Save {
        if let preset = draft.autosaved(workspace: workspace) { return .preset(preset, keepLayout: draft.keepsLayout) }
        // Own sizes leave the row no preset to rebuild, so it keeps Keep this layout as set (WorkspaceLayout.saving).
        if draft.apps.isEmpty { return .layout(WorkspaceLayout(preset: draft.layout, auto: draft.keepLayout), removePreset: hadPreset) }
        return .refused(draft.sizesProblem ?? "")
    }
}
