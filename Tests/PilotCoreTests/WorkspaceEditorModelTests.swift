import CoreGraphics
import Foundation
import Testing
@testable import PilotCore

/// The workspace editor popup as mockup E (card agent-bo-95422980): the stored fields it adds (At login per app, open
/// what is missing per preset), swapping and dragging apps, the divider between own sizes, the preview's tiles, and
/// opening At login apps once per login session. Fakes only: nothing is stored, launched or laid out for real.
@Suite("Workspace editor popup")
@MainActor
struct WorkspaceEditorModelTests {
    typealias Fake = WorkspacePresetTests

    static func draft(_ apps: [String], layout: LayoutPreset? = nil) -> WorkspacePresetDraft {
        var draft = WorkspacePresetDraft(nil, workspace: "1")
        // Placed under a ready layout first: under Your widths each app would take one of the three empty spots.
        draft.layout = .columns
        for app in apps { draft.add(bundleId: "com.apple.\(app.lowercased())", name: app) }
        draft.layout = layout
        return draft
    }

    @Test("A preset saved before this card loads with every app's At login off and open what is missing on, and saves both fields")
    func oldFile() throws {
        let old = #"{"name":"Work","apps":[{"bundleId":"a","name":"A","percent":100}],"layout":"columns"}"#
        let preset = try JSONDecoder().decode(WorkspacePreset.self, from: Data(old.utf8))
        #expect(preset.openMissing && preset.apps.map(\.atLogin) == [false] && preset.layout == .columns)
        var changed = preset
        changed.openMissing = false
        changed.apps[0].atLogin = true
        let back = try JSONDecoder().decode(WorkspacePreset.self, from: JSONEncoder().encode(changed))
        #expect(back == changed)
    }

    @Test("Clicking a placed app and picking another swaps it in place, same spot and percent; picking one already placed swaps the two")
    func replace() {
        var draft = Self.draft(["Ghostty", "Zen", "Telegram"])
        draft.setAtLogin(true, at: 1)
        draft.replace(at: 1, bundleId: "com.apple.code", name: "Code")
        #expect(draft.apps.map(\.name) == ["Ghostty", "Code", "Telegram"] && draft.apps.map(\.percent) == [34, 33, 33])
        #expect(draft.apps[1].atLogin == false)
        draft.replace(at: 0, bundleId: "com.apple.telegram", name: "Telegram")
        #expect(draft.apps.map(\.name) == ["Telegram", "Code", "Ghostty"])
    }

    @Test("Dragging a row reorders the apps; each keeps its size and At login")
    func drag() {
        var draft = Self.draft(["Ghostty", "Zen", "Telegram"])
        draft.setAtLogin(true, at: 2)
        draft.move(from: 2, to: 0)
        #expect(draft.apps.map(\.name) == ["Telegram", "Ghostty", "Zen"])
        #expect(draft.apps.map(\.percent) == [33, 34, 33] && draft.apps[0].atLogin)
    }

    @Test("Dragging the divider moves only the two apps beside it, the total stays 100, and neither goes under 5 %")
    func divider() {
        var draft = Self.draft(["Ghostty", "Zen", "Telegram"])
        draft.resize(divider: 0, to: 50)
        #expect(draft.apps.map(\.percent) == [50, 17, 33] && draft.total == 100)
        draft.resize(divider: 0, to: 80)
        #expect(draft.apps.map(\.percent) == [62, 5, 33])
        draft.resize(divider: 1, to: 1)
        #expect(draft.apps.map(\.percent) == [62, 5, 33])
        draft.resize(divider: 2, to: 50)
        #expect(draft.total == 100)
    }

    @Test("The preview's tiles: main + stack puts the first app left and stacks the rest, own sizes are columns at their percents")
    func tiles() {
        let area = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(Self.draft(["A", "B", "C"], layout: .mainStack).tiles(in: area) == [
            CGRect(x: 0, y: 0, width: 150, height: 200), CGRect(x: 150, y: 0, width: 150, height: 100), CGRect(x: 150, y: 100, width: 150, height: 100),
        ])
        var own = Self.draft(["A", "B"])
        own.resize(divider: 0, to: 70)
        #expect(own.tiles(in: CGRect(x: 0, y: 0, width: 200, height: 100)) == [CGRect(x: 0, y: 0, width: 140, height: 100), CGRect(x: 140, y: 0, width: 60, height: 100)])
        // The next app's spot: the layout drawn for one more app, the last tile the dashed one.
        #expect(Self.draft(["A", "B"], layout: .columns).tiles(in: area, next: true).map(\.width) == [100, 100, 100])
        #expect(WorkspacePresetDraft(nil, workspace: "1").tiles(in: area).isEmpty)
    }

    /// Scrolling layout spec: the preview draws the strip, three columns a third wide each, the rest peeking in at the
    /// right edge; one alone fills the screen.
    @Test("The preview's strip: columns a third wide, the rest 8 % peeks at the right edge, one app the whole screen, the next spot the next column")
    func scrollingTiles() {
        let area = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(Self.draft(["A", "B", "C"], layout: .scrolling).tiles(in: area) == [
            CGRect(x: 0, y: 0, width: 100, height: 200), CGRect(x: 100, y: 0, width: 100, height: 200), CGRect(x: 200, y: 0, width: 100, height: 200),
        ])
        #expect(Self.draft(["A"], layout: .scrolling).tiles(in: area) == [area])
        // Two apps: the next spot is the third column.
        let two = Self.draft(["A", "B"], layout: .scrolling).preview(in: area, strip: 40)
        #expect(two.apps.map(\.width) == [100, 100] && two.next == CGRect(x: 200, y: 0, width: 100, height: 200))
        // Four apps: the fourth and the next spot peek in at the right edge.
        let four = Self.draft(["A", "B", "C", "D"], layout: .scrolling).preview(in: area, strip: 40)
        #expect(four.apps.map(\.width) == [84, 84, 84, 24] && four.next == CGRect(x: 276, y: 0, width: 24, height: 200))
        // One app: the strip runs down the right, as for columns.
        let one = Self.draft(["A"], layout: .scrolling).preview(in: area, strip: 40)
        #expect(one.apps == [CGRect(x: 0, y: 0, width: 260, height: 200)] && one.next == CGRect(x: 260, y: 0, width: 40, height: 200))
    }

    @Test("The preview keeps each placed app at its real size and draws the next app's spot as a strip where it joins: under its column, under rows, right of columns and own sizes")
    func previewStrip() {
        let area = CGRect(x: 0, y: 0, width: 300, height: 200)
        // Main + stack, three apps: the main keeps the whole height, the stack shrinks above the strip.
        let main = Self.draft(["A", "B", "C"], layout: .mainStack).preview(in: area, strip: 40)
        #expect(main.apps == [CGRect(x: 0, y: 0, width: 150, height: 200), CGRect(x: 150, y: 0, width: 150, height: 80),
                              CGRect(x: 150, y: 80, width: 150, height: 80)])
        #expect(main.next == CGRect(x: 150, y: 160, width: 150, height: 40))
        // One app under main + stack: the next one starts the stack, so the strip runs down the right.
        let one = Self.draft(["A"], layout: .mainStack).preview(in: area, strip: 40)
        #expect(one.apps == [CGRect(x: 0, y: 0, width: 260, height: 200)] && one.next == CGRect(x: 260, y: 0, width: 40, height: 200))
        let rows = Self.draft(["A", "B"], layout: .rows).preview(in: area, strip: 40)
        #expect(rows.apps == [CGRect(x: 0, y: 0, width: 300, height: 80), CGRect(x: 0, y: 80, width: 300, height: 80)])
        #expect(rows.next == CGRect(x: 0, y: 160, width: 300, height: 40))
        // Own sizes: each app keeps its percent of the space left of the strip.
        var own = Self.draft(["A", "B"])
        own.resize(divider: 0, to: 70)
        let sized = own.preview(in: area, strip: 40)
        #expect(sized.apps.map { $0.width.rounded() } == [182, 78] && sized.next == CGRect(x: 260, y: 0, width: 40, height: 200))
        // Grid, three apps: the fourth goes under the third, in its column.
        let grid = Self.draft(["A", "B", "C"], layout: .grid).preview(in: area, strip: 40)
        #expect(grid.apps[2] == CGRect(x: 150, y: 0, width: 150, height: 160) && grid.next == CGRect(x: 150, y: 160, width: 150, height: 40))
        // Nothing placed: the whole screen is the spot.
        let empty = WorkspacePresetDraft(nil, workspace: "1").preview(in: area, strip: 40)
        #expect(empty.apps.isEmpty && empty.next == area)
    }

    @Test("Where each app sits, in the editor's words: main and stack, left to right, top to bottom, a grid's corners, own sizes with their percent")
    func places() {
        func places(_ draft: WorkspacePresetDraft) -> [String] { draft.apps.indices.map(draft.place) }
        #expect(places(Self.draft(["A", "B", "C"], layout: .mainStack)) == ["main", "stack 1", "stack 2"])
        #expect(places(Self.draft(["A", "B"], layout: .columns)) == ["left", "right"])
        #expect(places(Self.draft(["A", "B", "C", "D"], layout: .columns)) == ["column 1", "column 2", "column 3", "column 4"])
        #expect(places(Self.draft(["A", "B", "C"], layout: .rows)) == ["top", "middle", "bottom"])
        #expect(places(Self.draft(["A", "B", "C"], layout: .grid)) == ["top left", "bottom left", "right"])
        #expect(places(Self.draft(["A", "B", "C", "D", "E", "F", "G", "H"], layout: .grid)).suffix(3) == ["column 3, bottom", "column 4, top", "column 4, bottom"])
        #expect(places(Self.draft(["A"], layout: .grid)) == ["whole screen"])
        #expect(places(Self.draft(["A", "B", "C"], layout: .scrolling)) == ["column 1", "column 2", "column 3"])
        #expect(places(Self.draft(["A"], layout: .scrolling)) == ["whole screen"])
        var own = Self.draft(["A", "B"])
        own.resize(divider: 0, to: 55)
        #expect(places(own) == ["left, 55 %", "right, 45 %"])
    }

    @Test("A workspace with no preset starts unnamed, on the workspace's own layout or Columns, Keep this layout from its auto")
    func fresh() {
        let draft = WorkspacePresetDraft.fresh(workspace: "3", row: WorkspaceLayout(preset: .rows, auto: false))
        #expect(draft.name.isEmpty && draft.apps.isEmpty && draft.layout == .rows && !draft.keepLayout)
        #expect(draft.problem == "Name the preset")
        #expect(WorkspacePresetDraft.fresh(workspace: "3", row: nil).layout == .columns)
        #expect(WorkspacePresetDraft.fresh(workspace: "3", row: nil).keepsLayout)
        // A row with no layout preset has no Auto to keep (the Workspaces page greys it out): Keep this layout starts on.
        #expect(WorkspacePresetDraft.fresh(workspace: "3", row: WorkspaceLayout(preset: nil, auto: false)).keepsLayout)
    }

    @Test("Keep this layout follows the workspace's auto, is off under own sizes, and saving sets the row's auto to it")
    func keepLayout() {
        var draft = WorkspacePresetDraft(nil, workspace: "1", row: WorkspaceLayout(preset: .columns, auto: true))
        #expect(draft.layout == nil && !draft.keepsLayout)
        draft.layout = .grid
        #expect(draft.keepsLayout)
        draft.keepLayout = false
        #expect(!draft.keepsLayout)
        let row = WorkspaceLayout(preset: .columns, auto: true)
        let ready = WorkspacePreset(name: "w", apps: [], layout: .grid)
        #expect(row.saving(ready, auto: false) == WorkspaceLayout(preset: .grid, auto: false))
        #expect(row.saving(ready) == WorkspaceLayout(preset: .grid, auto: true))
    }

    @Test("The draft carries open what is missing and At login into the preset it saves")
    func carried() {
        var draft = Self.draft(["Ghostty", "Zen"], layout: .columns)
        draft.openMissing = false
        draft.setAtLogin(true, at: 0)
        #expect(draft.preset?.openMissing == false && draft.preset?.apps.map(\.atLogin) == [true, false])
        #expect(WorkspacePresetDraft(draft.preset, workspace: "1").apps[0].atLogin)
    }

    @Test("With open what is missing off, a switch opens nothing, still pulls running windows in and lays them out")
    func openMissingOff() async throws {
        let tiler = Fake.FakeTiler(windows: [Fake.window(10, "Finder", workspace: "2"), Fake.window(11, "TextEdit", workspace: "1")], focused: "2")
        let opener = Fake.FakeOpener(tiler, lands: "2")
        var preset = WorkspacePreset(name: "Work", apps: [Fake.app("Finder"), Fake.app("TextEdit"), Fake.app("Notes")], layout: .columns)
        preset.openMissing = false
        let outcome = try await Fake.apply(preset, tiler, opener)
        #expect(opener.opened.isEmpty && outcome.opened.isEmpty && outcome.missing.isEmpty)
        #expect(tiler.moves == [.moveWindow(id: 11, toWorkspace: "2")])
        #expect(tiler.evals.last == LayoutPreset.columns.commands(workspace: "2", windows: [10, 11]))
    }

    static func contents() -> WorkspacePresetStore.Contents {
        var contents = WorkspacePresetStore.Contents()
        var work = WorkspacePreset(name: "Work", apps: [Fake.app("Ghostty"), Fake.app("Zen")], layout: .columns)
        work.apps[0].atLogin = true
        var chat = WorkspacePreset(name: "Chat", apps: [Fake.app("Telegram"), Fake.app("Ghostty")], layout: nil)
        chat.apps[0].atLogin = true
        chat.apps[1].atLogin = true
        contents.assign(work, to: "1")
        contents.assign(chat, to: "3")
        contents.presets["Unused"] = WorkspacePreset(name: "Unused", apps: [{ var a = Fake.app("Notes"); a.atLogin = true; return a }()], layout: nil)
        return contents
    }

    @Test("At login opens each marked app once, for the first workspace that has it; a preset no workspace takes opens nothing")
    func loginPlan() {
        let plan = WorkspaceLoginOpen.plan(Self.contents())
        #expect(plan.map(\.bundleId) == ["com.apple.ghostty", "com.apple.telegram"])
        #expect(plan.map(\.workspace) == ["1", "3"])
    }

    @Test("At login: a stopped app is opened and its first window moved to its workspace; a running one is left alone")
    func loginRun() async throws {
        let tiler = Fake.FakeTiler(windows: [Fake.window(10, "Ghostty", workspace: "2")], focused: "1")
        let opener = Fake.FakeOpener(tiler, lands: "1")
        let open = WorkspaceLoginOpen(plan: WorkspaceLoginOpen.plan(Self.contents()), tiler: tiler, apps: opener,
                                      timing: Fake.quick)
        let outcome = try await open.run()
        #expect(opener.opened == ["com.apple.telegram"])
        #expect(tiler.moves == [.moveWindow(id: 900, toWorkspace: "3")])
        #expect(outcome.opened == ["com.apple.telegram"] && outcome.missing.isEmpty)
    }

    @Test("At login runs once per login session: a Pilot restart in the same session opens nothing")
    func oncePerSession() {
        let session = Date(timeIntervalSince1970: 1_791_000_000)
        #expect(WorkspaceLoginOpen.due(session: session, last: nil))
        #expect(!WorkspaceLoginOpen.due(session: session, last: session.timeIntervalSince1970))
        #expect(WorkspaceLoginOpen.due(session: session.addingTimeInterval(3600), last: session.timeIntervalSince1970))
        #expect(!WorkspaceLoginOpen.due(session: nil, last: nil))
    }
}
