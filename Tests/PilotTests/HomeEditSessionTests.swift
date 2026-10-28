import Foundation
import Observation
import Testing
@testable import Pilot

/// Home edit mode, seam 1 (spec home-edit, T2): the edit session decides every layout a drop, a chip, the tray, undo,
/// Done and Cancel give, driven with no view. Checks 1 to 6 of the spec's notes.
@MainActor
@Suite("HomeEditSession")
struct HomeEditSessionTests {
    typealias Place = HomeEditSession.Place

    static func defaults() -> UserDefaults { UserDefaults(suiteName: testSuite())! }

    static func lanes(_ layout: HomeLayout, extensions: [String] = []) -> HomeLayout.Lanes {
        HomeLayout.lanes(layout.shown(extensions: extensions), size: layout.size, across: 2)
    }

    static func layout(_ sizes: [String: HomeLayout.Size]) -> HomeLayout {
        var layout = HomeLayout.standard
        for (id, size) in sizes { layout.set(id, size: size) }
        return layout
    }

    /// Picks `id` up, hovers `place` and drops it.
    static func drag(_ session: HomeEditSession, _ id: String, to place: Place?) {
        session.pickUp(id)
        session.hover(place)
        session.drop()
    }

    @Test("Check 1: the lane sets the size: column small, icon row icon, board medium, a large between board rows stays large")
    func dropSizes() {
        let session = HomeEditSession(layout: .standard, extensions: [])
        Self.drag(session, "keyboard", to: .column(before: "clipboard"))
        #expect(session.draft.size(of: "keyboard") == .small)
        #expect(Self.lanes(session.draft).column == ["workspaces", "keyboard", "clipboard", "mostUsed"])
        Self.drag(session, "clipboard", to: .icons(before: nil))
        #expect(session.draft.size(of: "clipboard") == .icon && Self.lanes(session.draft).icons == ["clipboard"])
        Self.drag(session, "workspaces", to: .board(before: "thisMac"))
        #expect(session.draft.size(of: "workspaces") == .medium && Self.lanes(session.draft).board == [["workspaces"], ["thisMac"]])
        // A large dropped between board rows stays large.
        Self.drag(session, "thisMac", to: .board(before: "workspaces"))
        #expect(session.draft.size(of: "thisMac") == .large && Self.lanes(session.draft).board == [["thisMac"], ["workspaces"]])
        // From the tray onto the board: shown, medium.
        Self.drag(session, "pilot", to: .board(before: nil))
        #expect(session.draft.shown(extensions: []).contains("pilot") && session.draft.size(of: "pilot") == .medium)
    }

    @Test("Check 1: dropped beside a lone medium a block becomes medium and pairs with it, on either half")
    func beside() {
        // The keyboard a lone medium: This Mac, large, follows it.
        let session = HomeEditSession(layout: Self.layout(["keyboard": .medium]), extensions: [])
        #expect(Self.lanes(session.draft).board == [["keyboard"], ["thisMac"]])
        Self.drag(session, "clipboard", to: .beside("keyboard", trailing: true))
        #expect(session.draft.size(of: "clipboard") == .medium && Self.lanes(session.draft).board == [["keyboard", "clipboard"], ["thisMac"]])
        session.undo()
        // A large dropped on its left half turns medium.
        Self.drag(session, "thisMac", to: .beside("keyboard", trailing: false))
        #expect(session.draft.size(of: "thisMac") == .medium && Self.lanes(session.draft).board == [["thisMac", "keyboard"]])
    }

    @Test("Check 1: a medium dropped in front of a pair pairs with its first, as the lanes pair forward; the second takes a row")
    func pairsForward() {
        let session = HomeEditSession(layout: Self.layout(["keyboard": .medium, "thisMac": .medium]), extensions: ["git"])
        Self.drag(session, "ext:git", to: .board(before: "keyboard"))
        #expect(Self.lanes(session.draft, extensions: ["git"]).board == [["ext:git", "keyboard"], ["thisMac"]])
    }

    @Test("Check 2: a drop in a block's own lane keeps its size; its order follows the slot")
    func ownLane() {
        let session = HomeEditSession(layout: Self.layout(["workspaces": .icon, "clipboard": .icon, "keyboard": .medium]), extensions: [])
        Self.drag(session, "mostUsed", to: .column(before: nil))
        Self.drag(session, "clipboard", to: .icons(before: "workspaces"))
        Self.drag(session, "keyboard", to: .board(before: nil))
        #expect(session.draft.size(of: "mostUsed") == .small && session.draft.size(of: "clipboard") == .icon && session.draft.size(of: "keyboard") == .medium)
        #expect(Self.lanes(session.draft) == HomeLayout.Lanes(icons: ["clipboard", "workspaces"], column: ["mostUsed"], board: [["thisMac"], ["keyboard"]]))
        // Large stays large between board rows.
        Self.drag(session, "thisMac", to: .board(before: nil))
        #expect(session.draft.size(of: "thisMac") == .large && Self.lanes(session.draft).board == [["keyboard"], ["thisMac"]])
    }

    @Test("Hovering previews the drop without editing; off every slot the block goes back unchanged")
    func hover() {
        let session = HomeEditSession(layout: .standard, extensions: [])
        session.pickUp("keyboard")
        session.hover(.column(before: nil))
        #expect(session.draft == .standard && session.carried == "keyboard" && session.target == .column(before: nil))
        #expect(session.preview.size(of: "keyboard") == .small)
        session.hover(nil)
        session.drop()
        #expect(session.draft == .standard && session.carried == nil && !session.canUndo)
        // A drop where it already is takes no undo step.
        Self.drag(session, "clipboard", to: .column(before: "mostUsed"))
        #expect(!session.canUndo)
        // A block not listed is never picked up; with nothing carried, hover and drop do nothing.
        session.pickUp("ext:gone")
        session.hover(.board(before: nil))
        session.drop()
        #expect(session.carried == nil && session.target == nil && session.draft == .standard)
    }

    @Test("Check 3: Done saves the draft; a new store reads it back")
    func doneSaves() {
        let defaults = Self.defaults()
        let store = HomeLayoutStore(defaults: defaults)
        let session = HomeEditSession(layout: store.layout, extensions: [])
        Self.drag(session, "thisMac", to: .board(before: "keyboard"))
        session.done(store)
        #expect(store.layout == session.draft && HomeLayoutStore(defaults: defaults).layout == session.draft)
        #expect(Self.lanes(HomeLayoutStore(defaults: defaults).layout).board == [["thisMac"], ["keyboard"]])
    }

    @Test("Check 3: a layout Home draws as the default saves as nothing, even with rows the edits took in")
    func doneDefault() {
        let defaults = Self.defaults()
        let store = HomeLayoutStore(defaults: defaults)
        store.save(Self.layout(["keyboard": .medium]))
        let session = HomeEditSession(layout: store.layout, extensions: ["git"])
        session.size("keyboard", .large)
        // Clipboard to the column's end and back takes in the extension's row, hidden: not the default's rows, but Home
        // draws the same.
        Self.drag(session, "clipboard", to: .column(before: nil))
        Self.drag(session, "clipboard", to: .column(before: "mostUsed"))
        #expect(session.draft != .standard && session.draft.isStandard(extensions: ["git"]))
        session.done(store)
        #expect(defaults.data(forKey: HomeLayoutStore.key) == nil && store.layout == .standard)
    }

    @Test("Check 3: Escape and Cancel give back the entry layout exactly; a carried block goes back on the first Escape")
    func escape() {
        let entry = Self.layout(["clipboard": .icon])
        let session = HomeEditSession(layout: entry, extensions: ["git"])
        Self.drag(session, "ext:git", to: .board(before: nil))
        session.hide("workspaces")
        session.pickUp("keyboard")
        session.hover(.column(before: nil))
        let edited = session.draft
        #expect(session.escape() == false)
        #expect(session.carried == nil && session.draft == edited)
        #expect(session.escape() == true)
        #expect(session.draft == entry && !session.canUndo)
        session.size("keyboard", .medium)
        session.cancel()
        #expect(session.draft == entry)
    }

    @Test("Check 3: ⌘Z undoes one step at a time, back to the entry layout; while carrying it only puts the block back")
    func undo() {
        let session = HomeEditSession(layout: .standard, extensions: [])
        Self.drag(session, "keyboard", to: .column(before: nil))
        let one = session.draft
        session.size("thisMac", .medium)
        let two = session.draft
        session.hide("mostUsed")
        session.pickUp("clipboard")
        session.hover(.icons(before: nil))
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
        session.size("keyboard", .medium)
        session.reset()
        session.undo()
        #expect(session.draft.size(of: "keyboard") == .medium)
    }

    @Test("Check 3: a view showing only canUndo (the edit bar's undo) is told when an edit or an undo changes it")
    func undoObserved() {
        let session = HomeEditSession(layout: .standard, extensions: [])
        nonisolated(unsafe) var fired = 0
        withObservationTracking { _ = session.canUndo } onChange: { fired += 1 }
        session.size("keyboard", .medium)
        #expect(fired == 1 && session.canUndo)
        withObservationTracking { _ = session.canUndo } onChange: { fired += 1 }
        session.undo()
        #expect(fired == 2 && !session.canUndo)
    }

    @Test("Check 4: a hidden block keeps its place and size; a tray click shows it there")
    func hideAndShow() {
        let session = HomeEditSession(layout: Self.layout(["keyboard": .medium]), extensions: [])
        let before = Self.lanes(session.draft)
        session.hide("keyboard")
        #expect(!session.draft.shown(extensions: []).contains("keyboard") && session.draft.size(of: "keyboard") == .medium)
        session.show("keyboard")
        #expect(Self.lanes(session.draft) == before)
        // Hidden while carried (a drop on the tray): no longer carried, hidden in place.
        session.pickUp("clipboard")
        session.hover(.board(before: nil))
        session.hide("clipboard")
        #expect(session.carried == nil && session.draft.size(of: "clipboard") == .small)
        session.show("clipboard")
        #expect(Self.lanes(session.draft) == before)
    }

    @Test("Check 5: a saved row of an uninstalled extension keeps its place through every edit and is saved")
    func uninstalled() {
        let defaults = Self.defaults()
        var saved = HomeLayout.standard
        saved.rows.insert(HomeLayout.Row(id: "ext:gone", shown: true, size: .medium), at: 1)
        let store = HomeLayoutStore(defaults: defaults)
        store.save(saved)
        let session = HomeEditSession(layout: store.layout, extensions: ["git"])
        Self.drag(session, "keyboard", to: .column(before: "workspaces"))
        Self.drag(session, "ext:git", to: .board(before: "thisMac"))
        session.size("clipboard", .icon)
        session.hide("mostUsed")
        session.show("mostUsed")
        session.undo()
        let moved: Set = ["keyboard", "ext:git"]
        #expect(session.draft.rows.map(\.id).filter { !moved.contains($0) } == saved.rows.map(\.id).filter { !moved.contains($0) })
        #expect(session.draft.rows.first { $0.id == "ext:gone" } == HomeLayout.Row(id: "ext:gone", shown: true, size: .medium))
        session.done(store)
        #expect(HomeLayoutStore(defaults: defaults).layout.rows.contains { $0.id == "ext:gone" })
        // Otherwise the default, it is still saved: saving nothing would lose its place.
        var only = HomeLayout.standard
        only.rows.append(HomeLayout.Row(id: "ext:gone", shown: false))
        HomeEditSession(layout: only, extensions: []).done(store)
        #expect(HomeLayoutStore(defaults: defaults).layout == only)
    }

    @Test("Check 6: layouts saved by build 42 and before sizes load unchanged, and Done with no edit writes the same JSON")
    func oldLayouts() throws {
        let build42 = #"{"rows":[{"id":"ext:ai-usage","shown":true,"size":"icon"},{"id":"keyboard","shown":true,"size":"medium"},"#
            + #"{"id":"thisMac","shown":true},{"id":"workspaces","shown":false,"size":"large"},{"id":"ext:gone","shown":true}]}"#
        let presize = #"{"rows":[{"id":"ext:ai-usage","shown":true},{"id":"workspaces","shown":true},{"id":"keyboard","shown":false}]}"#
        for json in [build42, presize] {
            let defaults = Self.defaults()
            defaults.set(Data(json.utf8), forKey: HomeLayoutStore.key)
            let store = HomeLayoutStore(defaults: defaults)
            HomeEditSession(layout: store.layout, extensions: ["ai-usage"]).done(store)
            let written = try #require(defaults.data(forKey: HomeLayoutStore.key))
            #expect(try JSONSerialization.jsonObject(with: written) as? NSDictionary == JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        }
        let defaults = Self.defaults()
        defaults.set(Data(build42.utf8), forKey: HomeLayoutStore.key)
        let layout = HomeLayoutStore(defaults: defaults).layout
        #expect(layout.size(of: "ext:ai-usage") == .icon && layout.size(of: "keyboard") == .medium && layout.size(of: "thisMac") == .large)
        #expect(layout.shown(extensions: ["ai-usage"]) == ["ext:ai-usage", "keyboard", "thisMac"])
    }

    // MARK: Keyboard, VoiceOver and Reduce Motion (T6)

    /// Home's default as drawn: Workspaces, Clipboard and Most used in the column, the keyboard and This Mac on the board.
    static let blocks = HomeLayout.standard.shown(extensions: [])

    /// A mode on `layout`, the keyboard on `focus`.
    static func mode(_ layout: HomeLayout = .standard, focus: String? = nil) -> HomeEditMode {
        let mode = HomeEditMode(session: HomeEditSession(layout: layout, extensions: []))
        mode.focus = focus
        return mode
    }

    @discardableResult
    static func press(_ mode: HomeEditMode, _ keys: HomeEditMode.Key...) -> Bool {
        keys.map { mode.press($0, blocks: blocks, across: 2) }.last ?? false
    }

    @Test("Check 11: Tab and the arrows walk the blocks in reading order; Tab past either end leaves them for the bar")
    func keyboardFocus() {
        let mode = Self.mode()
        #expect(!mode.keyed && Self.press(mode, .tab) && mode.focus == "workspaces" && mode.keyed)
        #expect(HomeEditMode.order(Self.blocks, size: HomeLayout.standard.size(of:), across: 2) == ["workspaces", "clipboard", "mostUsed", "keyboard", "thisMac"])
        Self.press(mode, .tab, .later)
        #expect(mode.focus == "mostUsed")
        Self.press(mode, .earlier, .backTab)
        #expect(mode.focus == "workspaces")
        #expect(!Self.press(mode, .backTab) && mode.focus == "workspaces")
        #expect(Self.press(mode, .earlier) && mode.focus == "workspaces")
        mode.focus = "thisMac"
        #expect(!Self.press(mode, .tab) && Self.press(mode, .later) && mode.focus == "thisMac")
        // Space, sizes and ⌫ need a focused block; nothing changes without one.
        #expect(!Self.press(Self.mode(), .space) && !Self.press(Self.mode(), .size(.icon)) && !Self.press(Self.mode(), .hide))
    }

    @Test("Check 11: Space picks up and drops, the arrows move it slot by slot as a drag would, 1 to 4 size, ⌫ hides")
    func keyboardEdits() {
        let mode = Self.mode(focus: "clipboard"), twin = HomeEditSession(layout: .standard, extensions: [])
        Self.press(mode, .space)
        #expect(mode.keyCarried == "clipboard" && mode.session.target == nil && mode.session.draft == .standard)
        // From where it is, one slot up (in front of Workspaces), then the icon row; it stops there.
        Self.press(mode, .earlier)
        #expect(mode.session.target == .column(before: "workspaces"))
        Self.press(mode, .earlier, .earlier)
        #expect(mode.session.target == .icons(before: nil) && mode.session.preview.size(of: "clipboard") == .icon)
        // Down the column and onto the board, between the keyboard and This Mac: every step draws a new Home.
        var seen = [Self.lanes(mode.session.preview)]
        for _ in 0..<5 {
            Self.press(mode, .later)
            #expect(!seen.contains(Self.lanes(mode.session.preview)))
            seen.append(Self.lanes(mode.session.preview))
        }
        #expect(mode.session.target == .board(before: "thisMac") && mode.session.draft == .standard)
        Self.press(mode, .space)
        Self.drag(twin, "clipboard", to: .board(before: "thisMac"))
        #expect(mode.keyCarried == nil && mode.focus == "clipboard" && mode.session.draft == twin.draft && mode.session.canUndo)
        #expect(Self.lanes(mode.session.draft).board == [["keyboard"], ["clipboard"], ["thisMac"]])
        // 1 to 4: the size chips.
        Self.press(mode, .size(.icon))
        twin.size("clipboard", .icon)
        #expect(mode.session.draft == twin.draft && Self.lanes(mode.session.draft).icons == ["clipboard"])
        // ⌫: the ✕, the focus on to the next block.
        Self.press(mode, .hide)
        twin.hide("clipboard")
        #expect(mode.session.draft == twin.draft && mode.focus == "workspaces")
        // Picked up and dropped where it is: no edit, no undo step.
        let still = Self.mode(focus: "thisMac")
        Self.press(still, .space, .later, .space)
        #expect(still.session.draft == .standard && !still.session.canUndo && still.keyCarried == nil)
        // A medium pair: one step back swaps it in front of its partner.
        let pair = Self.mode(Self.layout(["keyboard": .medium, "thisMac": .medium]), focus: "thisMac")
        Self.press(pair, .space, .earlier, .space)
        #expect(Self.lanes(pair.session.draft).board == [["thisMac", "keyboard"]])
    }

    @Test("Check 11: Escape puts a carried block back first, then throws the edit away; ⌘Z while carrying only puts it back")
    func keyboardEscape() {
        let mode = Self.mode(focus: "keyboard")
        Self.press(mode, .size(.medium))
        let edited = mode.session.draft
        Self.press(mode, .space, .earlier)
        mode.undo()
        #expect(mode.keyCarried == nil && mode.session.draft == edited)
        Self.press(mode, .space, .earlier)
        #expect(mode.escape() == false)
        #expect(mode.keyCarried == nil && mode.session.draft == edited)
        #expect(mode.escape() == true)
        #expect(mode.session.draft == .standard)
    }

    @Test("Check 12: VoiceOver offers each block its moves, sizes and Hide, and each edits the draft as its mouse twin does")
    func voiceOver() {
        let mode = Self.mode()
        #expect(mode.actions(for: "clipboard", blocks: Self.blocks, across: 2).map(\.name)
            == ["Move earlier", "Move later", "Move to the board", "Size Icon", "Size Medium", "Size Large", "Hide"])
        #expect(mode.actions(for: "thisMac", blocks: Self.blocks, across: 2).map(\.name)
            == ["Move earlier", "Move to the column", "Size Icon", "Size Small", "Size Medium", "Hide"])
        #expect(mode.actions(for: "keyboard", blocks: Self.blocks, across: 2).map(\.name)
            == ["Move later", "Move to the column", "Size Icon", "Size Small", "Size Medium", "Hide"])
        // Each action against its mouse twin, from the default.
        let twins: [(id: String, name: String, twin: (HomeEditSession) -> Void)] = [
            ("clipboard", "Move earlier", { Self.drag($0, "clipboard", to: .column(before: "workspaces")) }),
            ("clipboard", "Move later", { Self.drag($0, "clipboard", to: .column(before: nil)) }),
            ("clipboard", "Move to the board", { Self.drag($0, "clipboard", to: .board(before: nil)) }),
            ("clipboard", "Size Icon", { $0.size("clipboard", .icon) }),
            ("clipboard", "Size Large", { $0.size("clipboard", .large) }),
            ("clipboard", "Hide", { $0.hide("clipboard") }),
            ("thisMac", "Move earlier", { Self.drag($0, "thisMac", to: .board(before: "keyboard")) }),
            ("thisMac", "Move to the column", { Self.drag($0, "thisMac", to: .column(before: nil)) }),
            ("keyboard", "Move later", { Self.drag($0, "keyboard", to: .board(before: nil)) }),
        ]
        for twin in twins {
            let mode = Self.mode(), session = HomeEditSession(layout: .standard, extensions: [])
            let action = mode.actions(for: twin.id, blocks: Self.blocks, across: 2).first { $0.name == twin.name }
            #expect(action != nil, "\(twin.id) offers no \(twin.name)")
            guard let action else { continue }
            mode.perform(action.edit, on: twin.id)
            twin.twin(session)
            #expect(mode.session.draft == session.draft && mode.session.draft != .standard, "\(twin.id) \(twin.name)")
            #expect(mode.session.carried == nil && mode.session.canUndo, "\(twin.id) \(twin.name)")
        }
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
