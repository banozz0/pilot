import Testing
@testable import PilotCore

/// The workspace editor's rules (story 108, card agent-bo-95422779): what the draft holds, when Save is allowed, and what
/// saving does to the workspace's layout row. Pure: nothing is stored or laid out.
@Suite("Workspace editor")
struct WorkspacePresetDraftTests {
    static func draft(_ apps: [String]) -> WorkspacePresetDraft {
        var draft = WorkspacePresetDraft(nil, workspace: "2")
        for app in apps { draft.add(bundleId: "com.apple.\(app.lowercased())", name: app) }
        return draft
    }

    @Test("A new draft is named after its workspace, holds no app, and lays out at own sizes")
    func new() {
        let draft = WorkspacePresetDraft(nil, workspace: "2")
        #expect(draft.name == "Workspace 2" && draft.apps.isEmpty && draft.layout == nil)
        #expect(draft.problem == "Add at least one app" && draft.preset == nil)
    }

    @Test("Adding or removing an app splits the sizes evenly again; an app already in the list is not added twice")
    func evenSplit() {
        var draft = Self.draft(["Chrome", "Spotify", "X"])
        #expect(draft.apps.map(\.percent) == [34, 33, 33])
        draft.add(bundleId: "com.apple.chrome", name: "Chrome")
        #expect(draft.apps.count == 3)
        draft.remove(at: 2)
        #expect(draft.apps.map(\.percent) == [50, 50])
    }

    @Test("Own sizes save only when they total 100: 90 is refused with the total named, 100 saves the preset as shown")
    func total() {
        var draft = Self.draft(["Chrome", "Spotify", "X"])
        draft.setPercent(50, at: 0)
        draft.setPercent(25, at: 1)
        draft.setPercent(15, at: 2)
        #expect(draft.total == 90)
        #expect(draft.problem == "Sizes add up to 90 %, not 100 %" && draft.preset == nil)
        draft.setPercent(25, at: 2)
        #expect(draft.problem == nil)
        #expect(draft.preset == WorkspacePreset(name: "Workspace 2", apps: [
            .init(bundleId: "com.apple.chrome", name: "Chrome", percent: 50), .init(bundleId: "com.apple.spotify", name: "Spotify", percent: 25),
            .init(bundleId: "com.apple.x", name: "X", percent: 25),
        ], layout: nil))
    }

    @Test("A ready layout ignores the sizes; an empty name is refused; a size stays between 1 and 100")
    func readyLayoutAndName() {
        var draft = Self.draft(["Chrome", "Spotify"])
        draft.setPercent(10, at: 0)
        #expect(draft.problem != nil)
        draft.layout = .grid
        #expect(draft.problem == nil && draft.preset?.layout == .grid)
        draft.name = "  "
        #expect(draft.problem == "Name the preset" && draft.preset == nil)
        draft.setPercent(0, at: 0)
        draft.setPercent(250, at: 1)
        #expect(draft.apps.map(\.percent) == [1, 100])
    }

    @Test("Moving an app up or down reorders it; a move past either end does nothing")
    func move() {
        var draft = Self.draft(["Chrome", "Spotify", "X"])
        draft.move(from: 2, to: 1)
        #expect(draft.apps.map(\.name) == ["Chrome", "X", "Spotify"])
        draft.move(from: 0, to: -1)
        draft.move(from: 2, to: 3)
        #expect(draft.apps.map(\.name) == ["Chrome", "X", "Spotify"])
    }

    @Test("A saved preset opens as the draft it was, under its own name")
    func fromPreset() {
        let preset = WorkspacePreset(name: "Work", apps: [.init(bundleId: "a", name: "A", percent: 70), .init(bundleId: "b", name: "B", percent: 30)],
                                     layout: nil)
        let draft = WorkspacePresetDraft(preset, workspace: "3")
        #expect(draft.preset == preset)
    }

    @Test("Saving a ready layout sets the workspace's layout row to it, auto kept; own sizes take the preset off, so auto has nothing to rebuild, and keep auto")
    func layoutRow() {
        let row = WorkspaceLayout(preset: .columns, auto: true)
        let ready = WorkspacePreset(name: "w", apps: [], layout: .grid)
        #expect(row.saving(ready) == WorkspaceLayout(preset: .grid, auto: true))
        let own = WorkspacePreset(name: "w", apps: [], layout: nil)
        #expect(row.saving(own, auto: false) == WorkspaceLayout(preset: nil, auto: true))
    }
}
