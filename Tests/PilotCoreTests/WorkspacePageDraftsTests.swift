import Foundation
import Testing
@testable import PilotCore

/// The Workspaces page edits each workspace in the editor's look (card agent-bo-95423003): one draft per workspace, kept
/// while Sven looks at another, Save writing a preset, or the layout alone when no app is placed.
@Suite("Workspace page drafts")
struct WorkspacePageDraftsTests {
    static let work = WorkspacePreset(name: "Work", apps: [.init(bundleId: "a", name: "A", percent: 50), .init(bundleId: "b", name: "B", percent: 50)], layout: .columns)
    static let row = WorkspaceLayout(preset: .columns, auto: true)

    @Test("Untouched, a workspace shows its saved preset and is not edited; an edit sticks per workspace until it matches again")
    func edits() {
        var drafts = WorkspacePageDrafts()
        let saved = drafts.draft("1", saved: Self.work, row: Self.row)
        #expect(saved == WorkspacePresetDraft(Self.work, workspace: "1", row: Self.row))
        #expect(!drafts.isEdited("1"))
        var changed = saved
        changed.layout = .rows
        drafts.set(changed, for: "1", saved: Self.work, row: Self.row)
        #expect(drafts.isEdited("1") && !drafts.isEdited("2"))
        #expect(drafts.draft("1", saved: Self.work, row: Self.row).layout == .rows, "the edit is kept while another workspace shows")
        drafts.set(saved, for: "1", saved: Self.work, row: Self.row)
        #expect(!drafts.isEdited("1"), "set back to what is saved, it is not edited")
        drafts.set(changed, for: "1", saved: Self.work, row: Self.row)
        drafts.revert("1")
        #expect(!drafts.isEdited("1"))
    }

    @Test("A workspace with no preset starts fresh from its layout row")
    func fresh() {
        let drafts = WorkspacePageDrafts()
        #expect(drafts.draft("3", saved: nil, row: .init(preset: .rows, auto: false)) == .fresh(workspace: "3", row: .init(preset: .rows, auto: false)))
    }

    @Test("A save writes the preset, a named one even with no app left; with no app and no name it sets the layout alone and drops a preset that was there; a nameless preset saves as Workspace 3")
    func save() {
        var draft = WorkspacePresetDraft(Self.work, workspace: "1", row: Self.row)
        #expect(WorkspacePageDrafts.save(draft, workspace: "1", hadPreset: true) == .preset(Self.work, keepLayout: true))
        draft.remove(at: 1)
        draft.remove(at: 0)
        draft.layout = .rows
        // Taking the last app off keeps the name (Sven 2026-10-17: every change saves at once).
        #expect(WorkspacePageDrafts.save(draft, workspace: "1", hadPreset: true) == .preset(WorkspacePreset(name: "Work", apps: [], layout: .rows), keepLayout: true))
        draft.name = ""
        #expect(WorkspacePageDrafts.save(draft, workspace: "1", hadPreset: true) == .layout(.init(preset: .rows, auto: true), removePreset: true))
        var fresh = WorkspacePresetDraft.fresh(workspace: "3", row: nil)
        #expect(WorkspacePageDrafts.save(fresh, workspace: "3", hadPreset: false) == .layout(.init(preset: .columns, auto: true), removePreset: false))
        fresh.add(bundleId: "a", name: "A")
        #expect(WorkspacePageDrafts.save(fresh, workspace: "3", hadPreset: false)
                == .preset(WorkspacePreset(name: "Workspace 3", apps: [.init(bundleId: "a", name: "A", percent: 100)], layout: .columns), keepLayout: true))
        fresh.layout = nil
        fresh.setPercent(90, at: 0)
        #expect(WorkspacePageDrafts.save(fresh, workspace: "3", hadPreset: false) == .refused("Sizes add up to 90 %, not 100 %"))
    }

    @Test("A workspace's name: blank or Workspace and a number is no name, so the page shows the number; the edits waiting are listed")
    func names() {
        #expect(WorkspacePreset.isUnnamed("") && WorkspacePreset.isUnnamed(" Workspace 3 ") && WorkspacePreset.isUnnamed(WorkspacePreset.unnamed("7")))
        #expect(!WorkspacePreset.isUnnamed("Chat") && !WorkspacePreset.isUnnamed("Workspace") && !WorkspacePreset.isUnnamed("Workspace two"))
        var contents = WorkspacePresetStore.Contents()
        contents.assign(Self.work, to: "1")
        contents.assign(WorkspacePreset(name: "Workspace 2", apps: Self.work.apps, layout: nil), to: "2")
        #expect(contents.name(for: "1") == "Work" && contents.title(for: "1") == "Work")
        #expect(contents.name(for: "2") == nil && contents.title(for: "2") == "Workspace 2" && contents.title(for: "5") == "Workspace 5")
        var drafts = WorkspacePageDrafts()
        var changed = drafts.draft("2", saved: nil, row: nil)
        changed.layout = .grid
        drafts.set(changed, for: "2", saved: nil, row: nil)
        #expect(drafts.edited == ["2"])
    }
}
