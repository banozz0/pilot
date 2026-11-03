import Foundation
import Observation
import Testing
@testable import Pilot

/// Home edit mode, seam 1 (spec home-edit, T2; P91's grid): the edit session decides every layout a drop, a handle, the
/// Layout chip, the tray, undo, Done and Cancel give, driven with no view. Checks 1 to 6 of the spec's notes.
@MainActor
@Suite("HomeEditSession")
struct HomeEditSessionTests {
    static func defaults() -> UserDefaults { UserDefaults(suiteName: testSuite())! }

    static func cell(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> HomeCell { HomeCell(x: x, y: y, w: w, h: h) }

    /// The cells Home draws the draft at.
    static func cells(_ session: HomeEditSession) -> [String: HomeCell] { session.cells(session.draft) }

    /// Picks `id` up, hovers `cell` and drops it.
    static func drag(_ session: HomeEditSession, _ id: String, to cell: HomeCell?) {
        session.pickUp(id)
        session.hover(cell)
        session.drop()
    }

    @Test("Check 1: a drop takes the cells under it at the block's own size; the blocks in its way move down, those under the space it left float up")
    func dropCells() {
        let session = HomeEditSession(layout: .standard, extensions: [])
        // This Mac onto the keyboard's top: it takes the cells, the keyboard goes under it.
        Self.drag(session, "thisMac", to: Self.cell(5, 0, 18, 5))
        #expect(Self.cells(session)["thisMac"] == Self.cell(5, 0, 18, 5) && Self.cells(session)["keyboard"] == Self.cell(5, 5, 18, 6))
        // Most used onto This Mac's top left: This Mac and the keyboard move down; dropped low, a block floats up to the
        // block over it.
        Self.drag(session, "mostUsed", to: Self.cell(5, 0, 5, 3))
        #expect(Self.cells(session)["mostUsed"] == Self.cell(5, 0, 5, 3) && Self.cells(session)["thisMac"] == Self.cell(5, 3, 18, 5))
        Self.drag(session, "workspaces", to: Self.cell(0, 30, 5, 3))
        #expect(Self.cells(session)["workspaces"] == Self.cell(0, 5, 5, 3) && Self.cells(session)["clipboard"] == Self.cell(0, 2, 5, 3))
        #expect(HomeGrid.valid(Array(Self.cells(session).values)))
        // From the tray: shown on the cells it is dropped on.
        Self.drag(session, "pilot", to: Self.cell(0, 0, 5, 2))
        #expect(session.draft.shown(extensions: []).contains("pilot") && Self.cells(session)["pilot"] == Self.cell(0, 0, 5, 2))
        #expect(Self.cells(session)["greeting"] == Self.cell(0, 2, 5, 2))
    }

    @Test("Check 1: a handle resizes by whole cells; the blocks in the way move down and float back as it shrinks")
    func resize() {
        let session = HomeEditSession(layout: .standard, extensions: [])
        // The keyboard's corner, as the pointer leaves it 14 × 9 (P91 frame 2).
        Self.drag(session, "keyboard", to: Self.cell(5, 0, 14, 9))
        #expect(Self.cells(session)["keyboard"] == Self.cell(5, 0, 14, 9) && Self.cells(session)["thisMac"] == Self.cell(5, 9, 18, 5))
        // Its bottom edge back up to 6 rows: This Mac floats up under it.
        Self.drag(session, "keyboard", to: Self.cell(5, 0, 14, 6))
        #expect(Self.cells(session)["thisMac"] == Self.cell(5, 6, 18, 5))
        // Shift-arrows: one cell at a time, never past the columns or under one cell.
        session.resize("keyboard", dw: 1, dh: -1)
        #expect(Self.cells(session)["keyboard"] == Self.cell(5, 0, 15, 5))
        for _ in 0..<20 { session.resize("keyboard", dw: 1, dh: 0) }
        #expect(Self.cells(session)["keyboard"] == Self.cell(5, 0, 18, 5))
        for _ in 0..<20 { session.resize("workspaces", dw: -1, dh: -1) }
        #expect(Self.cells(session)["workspaces"] == Self.cell(0, 2, 1, 1))
    }

    @Test("Check 1: Sven's Home from 1.0.2 reaches his goal by a corner, three drops and three bottom edges (P91 frames 1 to 4)")
    func svensGoal() throws {
        let old = try JSONDecoder().decode(HomeLayout.self, from: Data(HomeLayoutTests.svensLanes.utf8))
        let session = HomeEditSession(layout: HomeLayout(lanes: old), extensions: HomeLayoutTests.svensExtensions)
        Self.drag(session, "keyboard", to: Self.cell(5, 0, 14, 9))
        // Each drop at its own size, cut to the four columns left; then its bottom edge.
        for (id, at, rows) in [("thisMac", Self.cell(19, 0, 18, 5), 3), ("ext:weather", Self.cell(19, 3, 9, 5), 2), ("ext:ai-usage", Self.cell(19, 5, 9, 5), 4)] {
            Self.drag(session, id, to: at.clamped)
            let cell = try #require(Self.cells(session)[id])
            Self.drag(session, id, to: Self.cell(cell.x, cell.y, cell.w, rows))
        }
        let cells = Self.cells(session)
        #expect(cells["keyboard"] == Self.cell(5, 0, 14, 9) && cells["thisMac"] == Self.cell(19, 0, 4, 3))
        #expect(cells["ext:weather"] == Self.cell(19, 3, 4, 2) && cells["ext:ai-usage"] == Self.cell(19, 5, 4, 4))
        #expect(cells == HomeLayoutTests.svensGoal.cells(HomeLayoutTests.svensGoal.shown(extensions: HomeLayoutTests.svensExtensions)))
        #expect(HomeGrid.valid(Array(cells.values)))
    }

    @Test("Check 2: the Layout chip keeps a class or Auto; the same Layout again takes no undo step")
    func layoutChip() {
        let session = HomeEditSession(layout: .standard, extensions: [])
        session.layout("keyboard", .square)
        #expect(session.draft.layout(of: "keyboard") == .square && session.canUndo)
        session.layout("keyboard", .square)
        session.layout("keyboard", nil)
        session.undo()
        #expect(session.draft.layout(of: "keyboard") == .square)
        session.undo()
        #expect(session.draft == .standard && !session.canUndo)
    }

    @Test("Hovering previews the drop without editing; off the grid the block goes back unchanged")
    func hover() {
        let session = HomeEditSession(layout: .standard, extensions: [])
        session.pickUp("keyboard")
        // Down three rows its bottom passes This Mac's middle: This Mac rises over it.
        session.hover(Self.cell(5, 3, 18, 6))
        #expect(session.draft == .standard && session.carried == "keyboard" && session.target == Self.cell(5, 3, 18, 6))
        #expect(session.cells(session.preview)["thisMac"] == Self.cell(5, 0, 18, 5) && session.cells(session.preview)["keyboard"] == Self.cell(5, 5, 18, 6))
        // Down two, not yet: the preview is Home as it is.
        session.hover(Self.cell(5, 2, 18, 6))
        #expect(session.cells(session.preview) == session.cells(session.draft))
        session.hover(nil)
        session.drop()
        #expect(session.draft == .standard && session.carried == nil && !session.canUndo)
        // A drop where it already is takes no undo step.
        Self.drag(session, "clipboard", to: Self.cell(0, 5, 5, 3))
        #expect(!session.canUndo)
        // A block not listed is never picked up; with nothing carried, hover and drop do nothing.
        session.pickUp("ext:gone")
        session.hover(Self.cell(0, 0, 1, 1))
        session.drop()
        #expect(session.carried == nil && session.target == nil && session.draft == .standard)
    }

    @Test("Check 3: Done saves the draft; a new store reads it back")
    func doneSaves() {
        let defaults = Self.defaults()
        let store = HomeLayoutStore(defaults: defaults)
        let session = HomeEditSession(layout: store.layout, extensions: [])
        Self.drag(session, "thisMac", to: Self.cell(5, 0, 18, 5))
        session.done(store)
        #expect(store.layout == session.draft && HomeLayoutStore(defaults: defaults).layout == session.draft)
        #expect(HomeLayoutStore(defaults: defaults).layout.cell(of: "keyboard") == Self.cell(5, 5, 18, 6))
    }

    @Test("Check 3: a layout Home draws as the default saves as nothing, even after edits that came back to it")
    func doneDefault() {
        let defaults = Self.defaults()
        let store = HomeLayoutStore(defaults: defaults)
        var saved = HomeLayout.standard
        saved.set("keyboard", layout: .wide)
        store.save(saved)
        let session = HomeEditSession(layout: store.layout, extensions: ["git"])
        session.layout("keyboard", nil)
        // Clipboard down past Most used and back.
        Self.drag(session, "clipboard", to: Self.cell(0, 9, 5, 3))
        Self.drag(session, "clipboard", to: Self.cell(0, 5, 5, 3))
        #expect(session.draft.isStandard(extensions: ["git"]))
        session.done(store)
        #expect(defaults.data(forKey: HomeLayoutStore.key) == nil && store.layout == .standard)
    }

    @Test("Check 3: Escape and Cancel give back the entry layout exactly; a carried block goes back on the first Escape")
    func escape() {
        var entry = HomeLayout.standard
        entry.set("clipboard", layout: .strip)
        let session = HomeEditSession(layout: entry, extensions: ["git"])
        Self.drag(session, "ext:git", to: Self.cell(0, 20, 9, 5))
        session.hide("workspaces")
        session.pickUp("keyboard")
        session.hover(Self.cell(0, 0, 5, 3))
        let edited = session.draft
        #expect(session.escape() == false)
        #expect(session.carried == nil && session.draft == edited)
        #expect(session.escape() == true)
        #expect(session.draft == entry && !session.canUndo)
        session.layout("keyboard", .square)
        session.cancel()
        #expect(session.draft == entry)
    }

    @Test("Check 3: ⌘Z undoes one step at a time, back to the entry layout; while carrying it only puts the block back")
    func undo() {
        let session = HomeEditSession(layout: .standard, extensions: [])
        Self.drag(session, "keyboard", to: Self.cell(5, 0, 14, 9))
        let one = session.draft
        session.layout("thisMac", .wide)
        let two = session.draft
        session.hide("mostUsed")
        session.pickUp("clipboard")
        session.hover(Self.cell(10, 10, 5, 3))
        session.undo()
        #expect(session.carried == nil && session.draft.shown(extensions: []).contains("mostUsed") == false)
        session.undo()
        #expect(session.draft == two)
        session.undo()
        #expect(session.draft == one)
        session.undo()
        #expect(session.draft == .standard && !session.canUndo)
        session.undo()
        #expect(session.draft == .standard)
        // Reset is a step too.
        session.layout("keyboard", .square)
        session.reset()
        session.undo()
        #expect(session.draft.layout(of: "keyboard") == .square)
    }

    @Test("Check 3: a view showing only canUndo (the edit bar's undo) is told when an edit or an undo changes it")
    func undoObserved() {
        let session = HomeEditSession(layout: .standard, extensions: [])
        nonisolated(unsafe) var fired = 0
        withObservationTracking { _ = session.canUndo } onChange: { fired += 1 }
        session.layout("keyboard", .square)
        #expect(fired == 1 && session.canUndo)
        withObservationTracking { _ = session.canUndo } onChange: { fired += 1 }
        session.undo()
        #expect(fired == 2 && !session.canUndo)
    }

    @Test("Check 4: a hidden block keeps its cells and Layout; a tray click shows it there, the blocks there moving down")
    func hideAndShow() {
        var start = HomeLayout.standard
        start.set("keyboard", layout: .wide)
        let session = HomeEditSession(layout: start, extensions: [])
        let before = Self.cells(session)
        session.hide("keyboard")
        #expect(!session.draft.shown(extensions: []).contains("keyboard") && session.draft.layout(of: "keyboard") == .wide)
        #expect(session.draft.cell(of: "keyboard") == Self.cell(5, 0, 18, 6) && Self.cells(session)["thisMac"] == Self.cell(5, 0, 18, 5))
        session.show("keyboard")
        #expect(Self.cells(session) == before)
        // Hidden while carried (a drop on the tray): no longer carried, hidden on its cells.
        session.pickUp("clipboard")
        session.hover(Self.cell(10, 10, 5, 3))
        session.hide("clipboard")
        #expect(session.carried == nil && session.draft.cell(of: "clipboard") == Self.cell(0, 5, 5, 3))
        session.show("clipboard")
        #expect(Self.cells(session) == before)
    }

    @Test("Check 5: a saved row of an uninstalled extension keeps its place and cells through every edit and is saved")
    func uninstalled() {
        let defaults = Self.defaults()
        var saved = HomeLayout.standard
        saved.rows.insert(HomeLayout.Row(id: "ext:gone", shown: true, cell: Self.cell(5, 0, 9, 5)), at: 1)
        let store = HomeLayoutStore(defaults: defaults)
        store.save(saved)
        let session = HomeEditSession(layout: store.layout, extensions: ["git"])
        Self.drag(session, "keyboard", to: Self.cell(0, 0, 18, 6))
        Self.drag(session, "ext:git", to: Self.cell(5, 2, 9, 5))
        session.layout("clipboard", .strip)
        session.hide("mostUsed")
        session.show("mostUsed")
        session.undo()
        #expect(session.draft.rows.map(\.id).filter { $0 != "ext:git" } == saved.rows.map(\.id))
        #expect(session.draft.rows.first { $0.id == "ext:gone" } == HomeLayout.Row(id: "ext:gone", shown: true, cell: Self.cell(5, 0, 9, 5)))
        session.done(store)
        #expect(HomeLayoutStore(defaults: defaults).layout.rows.contains { $0.id == "ext:gone" })
        // Otherwise the default, it is still saved: saving nothing would lose its place.
        var only = HomeLayout.standard
        only.rows.append(HomeLayout.Row(id: "ext:gone", shown: false))
        HomeEditSession(layout: only, extensions: []).done(store)
        #expect(HomeLayoutStore(defaults: defaults).layout == only)
    }

    @Test("Check 6: layouts saved by build 42 and before sizes convert to cells once; Done with no edit writes the converted layout and the old bytes stay kept")
    func oldLayouts() throws {
        let build42 = #"{"rows":[{"id":"ext:ai-usage","shown":true,"size":"icon"},{"id":"keyboard","shown":true,"size":"medium"},"#
            + #"{"id":"thisMac","shown":true},{"id":"workspaces","shown":false,"size":"large"},{"id":"ext:gone","shown":true}]}"#
        let presize = #"{"rows":[{"id":"ext:ai-usage","shown":true},{"id":"workspaces","shown":true},{"id":"keyboard","shown":false}]}"#
        for json in [build42, presize] {
            let defaults = Self.defaults()
            defaults.set(Data(json.utf8), forKey: HomeLayoutStore.key)
            let store = HomeLayoutStore(defaults: defaults)
            let converted = store.layout
            HomeEditSession(layout: store.layout, extensions: ["ai-usage"]).done(store)
            #expect(HomeLayoutStore(defaults: defaults).layout == converted)
            #expect(defaults.data(forKey: HomeLayoutStore.lanesKey) == Data(json.utf8))
        }
        let defaults = Self.defaults()
        defaults.set(Data(build42.utf8), forKey: HomeLayoutStore.key)
        let layout = HomeLayoutStore(defaults: defaults).layout
        // The icon a Strip atop the column, the lone medium keyboard across the board (six rows, as the keyboard always
        // converts), This Mac and the lone medium under it; the large but hidden Workspaces keeps no cells.
        #expect(layout.cell(of: "ext:ai-usage") == Self.cell(0, 2, 5, 1) && layout.cell(of: "keyboard") == Self.cell(5, 0, 18, 6))
        #expect(layout.cell(of: "thisMac") == Self.cell(5, 6, 18, 5) && layout.cell(of: "ext:gone") == Self.cell(5, 11, 18, 5))
        #expect(layout.cell(of: "workspaces") == nil)
        #expect(layout.shown(extensions: ["ai-usage"]) == ["greeting", "ext:ai-usage", "keyboard", "thisMac"])
    }

    // MARK: Keyboard, VoiceOver and Reduce Motion (T6)

    /// Home's default as drawn.
    static let blocks = HomeLayout.standard.shown(extensions: [])

    /// A mode on `layout`, the keyboard on `focus`.
    static func mode(_ layout: HomeLayout = .standard, focus: String? = nil) -> HomeEditMode {
        let mode = HomeEditMode(session: HomeEditSession(layout: layout, extensions: []))
        mode.focus = focus
        return mode
    }

    @discardableResult
    static func press(_ mode: HomeEditMode, _ keys: HomeEditMode.Key...) -> Bool {
        keys.map { mode.press($0, blocks: blocks) }.last ?? false
    }

    @Test("Check 11: Tab walks the blocks in reading order, by row then column; past either end it leaves them for the bar")
    func keyboardFocus() {
        let mode = Self.mode()
        #expect(!mode.keyed && Self.press(mode, .tab) && mode.focus == "greeting" && mode.keyed)
        #expect(mode.order(Self.blocks) == ["greeting", "keyboard", "workspaces", "clipboard", "thisMac", "mostUsed"])
        Self.press(mode, .tab, .tab)
        #expect(mode.focus == "workspaces")
        Self.press(mode, .backTab)
        #expect(mode.focus == "keyboard")
        mode.focus = "greeting"
        #expect(!Self.press(mode, .backTab) && mode.focus == "greeting")
        mode.focus = "mostUsed"
        #expect(!Self.press(mode, .tab) && mode.focus == "mostUsed")
        // Moves, sizes, Layouts and ⌫ need a focused block; nothing changes without one, but an arrow takes the first.
        #expect(!Self.press(Self.mode(), .resize(dw: 1, dh: 0)) && !Self.press(Self.mode(), .layout(.strip)) && !Self.press(Self.mode(), .hide))
        let fresh = Self.mode()
        #expect(Self.press(fresh, .move(dx: 1, dy: 0)) && fresh.focus == "greeting" && fresh.session.draft == .standard)
    }

    @Test("Check 11: the arrows move the focused block a cell, past the block it meets; Shift-arrows size it; 1 to 4 and 0 its Layout; ⌫ hides")
    func keyboardEdits() {
        let mode = Self.mode(focus: "clipboard")
        // Up: past Workspaces, which goes under it; right: one column.
        Self.press(mode, .move(dx: 0, dy: -1))
        #expect(Self.cells(mode.session)["clipboard"] == Self.cell(0, 2, 5, 3) && Self.cells(mode.session)["workspaces"] == Self.cell(0, 5, 5, 3))
        Self.press(mode, .move(dx: 1, dy: 0))
        #expect(Self.cells(mode.session)["clipboard"]?.x == 1)
        // Down twice: past Workspaces, then past Most used; at the bottom it goes nowhere.
        Self.press(mode, .move(dx: -1, dy: 0), .move(dx: 0, dy: 1), .move(dx: 0, dy: 1))
        #expect(HomeLayout.reading(Self.cells(mode.session)).filter { ["workspaces", "mostUsed", "clipboard"].contains($0) } == ["workspaces", "mostUsed", "clipboard"])
        let low = mode.session.draft
        Self.press(mode, .move(dx: 0, dy: 1))
        #expect(mode.session.draft == low)
        // Shift-arrows: one cell wider, one row shorter.
        Self.press(mode, .resize(dw: 1, dh: -1))
        #expect(Self.cells(mode.session)["clipboard"].map { ($0.w, $0.h) } ?? (0, 0) == (6, 2))
        // 1 to 4 and 0: the Layout chip.
        Self.press(mode, .layout(.square))
        #expect(mode.session.draft.layout(of: "clipboard") == .square)
        Self.press(mode, .layout(nil))
        #expect(mode.session.draft.layout(of: "clipboard") == nil)
        // ⌫: the ✕, the focus on to the block after it.
        let order = mode.order(Self.blocks)
        Self.press(mode, .hide)
        #expect(!mode.session.draft.shown(extensions: []).contains("clipboard"))
        #expect(mode.focus == order.filter { $0 != "clipboard" }.last)
    }

    @Test("Check 11: Escape throws the edit away; ⌘Z takes one key's edit back")
    func keyboardEscape() {
        let mode = Self.mode(focus: "keyboard")
        Self.press(mode, .resize(dw: -4, dh: 3))
        let edited = mode.session.draft
        Self.press(mode, .layout(.wide))
        mode.undo()
        #expect(mode.session.draft == edited)
        #expect(mode.escape() == true)
        #expect(mode.session.draft == .standard)
    }

    @Test("Check 12: VoiceOver offers each block the moves and sizes that change it, every other Layout and Hide, each as its key does")
    func voiceOver() {
        let mode = Self.mode()
        #expect(mode.actions(for: "workspaces").map(\.name)
            == ["Move right", "Move up", "Move down", "Wider", "Narrower", "Taller", "Shorter",
                "Layout Strip", "Layout Square", "Layout Wide", "Layout Large", "Hide"])
        #expect(mode.actions(for: "keyboard").map(\.name).prefix(4) == ["Move left", "Move down", "Narrower", "Taller"])
        // Nothing under Most used: Move down would change nothing, so it is not offered; nor Taller at the most rows.
        #expect(!mode.actions(for: "mostUsed").map(\.name).contains("Move down"))
        mode.session.put("mostUsed", HomeCell(x: 0, y: 8, w: 5, h: HomeCell.tallest))
        #expect(!mode.actions(for: "mostUsed").map(\.name).contains("Taller") && mode.actions(for: "mostUsed").map(\.name).contains("Shorter"))
        // Each action against its key, from the default.
        let twins: [(id: String, name: String, key: HomeEditMode.Key)] = [
            ("clipboard", "Move up", .move(dx: 0, dy: -1)), ("clipboard", "Move right", .move(dx: 1, dy: 0)),
            ("keyboard", "Narrower", .resize(dw: -1, dh: 0)), ("thisMac", "Taller", .resize(dw: 0, dh: 1)),
            ("thisMac", "Layout Square", .layout(.square)),
        ]
        for twin in twins {
            let mode = Self.mode(), keyed = Self.mode(focus: twin.id)
            let action = mode.actions(for: twin.id).first { $0.name == twin.name }
            #expect(action != nil, "\(twin.id) offers no \(twin.name)")
            guard let action else { continue }
            mode.perform(action.edit, on: twin.id)
            Self.press(keyed, twin.key)
            #expect(mode.session.draft == keyed.session.draft && mode.session.draft != .standard, "\(twin.id) \(twin.name)")
            #expect(mode.session.carried == nil && mode.session.canUndo, "\(twin.id) \(twin.name)")
        }
        let hidden = Self.mode()
        hidden.perform(.hide, on: "thisMac")
        #expect(!hidden.session.draft.shown(extensions: []).contains("thisMac"))
        // Edit mode is announced.
        #expect(HomeEditMode.entered.hasPrefix("Editing Home."))
    }

    @Test("Check 13: Reduce Motion: no rotation, no lift or rest scale, no spring; changes fade 150 ms")
    func reduceMotion() {
        #expect(HomeMotion.wiggle(width: 300) > 0 && HomeMotion.wiggle(width: 300, reduce: true) == 0)
        #expect(HomeMotion.liftScale(reduce: false) == 1.03 && HomeMotion.liftScale(reduce: true) == 1)
        #expect(HomeMotion.enterScale(reduce: false) == 0.98 && HomeMotion.enterScale(reduce: true) == 1)
        #expect(HomeMotion.settle(reduce: false) == HomeMotion.settle && HomeMotion.settle(reduce: true) == HomeMotion.fade)
        #expect(HomeMotion.keyed(reduce: false) == Kit.change && HomeMotion.keyed(reduce: true) == HomeMotion.fade)
        let mode = Self.mode()
        #expect(mode.settle == HomeMotion.settle)
        mode.reduceMotion = true
        #expect(mode.settle == HomeMotion.fade)
    }
}
