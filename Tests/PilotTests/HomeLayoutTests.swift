import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Story 167: Home's blocks, picked and placed by the person, with a good default; P91: on a grid of cells (model A).
@MainActor
@Suite("Home layout")
struct HomeLayoutTests {
    static func defaults() -> UserDefaults { UserDefaults(suiteName: NSTemporaryDirectory() + "pilot.home-layout.\(UUID().uuidString)")! }

    /// Sven's Home as 1.0.2 saved it (his screenshot, 2026-11-02): Workspaces, Clipboard, Most used and Now playing small in
    /// the column; the keyboard and This Mac large, Weather and AI usage medium side by side on the board; the rest hidden.
    static let svensLanes = #"{"rows":[{"id":"workspaces","shown":true},{"id":"keyboard","shown":true},{"id":"clipboard","shown":true},"#
        + #"{"id":"mostUsed","shown":true},{"id":"ext:now-playing","shown":true,"size":"small"},{"id":"thisMac","shown":true},"#
        + #"{"id":"ext:weather","shown":true},{"id":"ext:ai-usage","shown":true},{"id":"pilot","shown":false},{"id":"quickActions","shown":false},"#
        + #"{"id":"ext:obsidian-search","shown":false},{"id":"ext:ssh-hosts","shown":false},{"id":"ext:pomodoro","shown":false,"size":"icon"}]}"#
    /// The extensions his Home lists.
    static let svensExtensions = ["now-playing", "weather", "ai-usage", "obsidian-search", "ssh-hosts", "pomodoro"]

    static func cell(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> HomeCell { HomeCell(x: x, y: y, w: w, h: h) }

    /// His goal (P91's page, frame 4): a big keyboard, This Mac, Weather and AI usage small on the right.
    static var svensGoal: HomeLayout {
        var layout = HomeLayout(lanes: try! JSONDecoder().decode(HomeLayout.self, from: Data(svensLanes.utf8)))
        for (id, cell) in [("keyboard", cell(5, 0, 14, 9)), ("thisMac", cell(19, 0, 4, 3)), ("ext:weather", cell(19, 3, 4, 2)), ("ext:ai-usage", cell(19, 5, 4, 4))] {
            layout.set(id, cell: cell)
        }
        return layout
    }

    @Test("The default is direction 2 on the grid: the greeting, Workspaces, Clipboard and Most used down the left, the keyboard and This Mac beside them")
    func standard() {
        let layout = HomeLayout.standard
        #expect(layout.shown(extensions: []) == ["greeting", "workspaces", "keyboard", "clipboard", "mostUsed", "thisMac"])
        #expect(layout.resolved(extensions: []).map(\.id) == ["greeting", "workspaces", "keyboard", "clipboard", "mostUsed", "thisMac", "pilot", "quickActions"])
        #expect(layout.cells(layout.shown(extensions: [])) == ["greeting": Self.cell(0, 0, 5, 2), "workspaces": Self.cell(0, 2, 5, 3),
                                                              "clipboard": Self.cell(0, 5, 5, 3), "mostUsed": Self.cell(0, 8, 5, 3),
                                                              "keyboard": Self.cell(5, 0, 18, 6), "thisMac": Self.cell(5, 6, 18, 5)])
        #expect(layout.isValid && layout.grid == HomeLayout.version && layout.rows.allSatisfy { $0.size == nil && $0.layout == nil })
        #expect(HomeLayoutStore(defaults: Self.defaults()).layout == .standard)
    }

    @Test("Hiding a block keeps its cells; the blocks under it float up, and shown again it takes its cells back")
    func hide() {
        var layout = HomeLayout.standard
        let drawn = { (l: HomeLayout) in l.shown(extensions: []) }
        layout.set("keyboard", shown: false)
        layout.place(drawn(layout))
        #expect(layout.cell(of: "keyboard") == Self.cell(5, 0, 18, 6) && layout.cell(of: "thisMac") == Self.cell(5, 0, 18, 5))
        layout.set("keyboard", shown: true)
        layout.place(drawn(layout), subject: "keyboard")
        #expect(layout.cell(of: "keyboard") == Self.cell(5, 0, 18, 6) && layout.cell(of: "thisMac") == Self.cell(5, 6, 18, 5))
        // Shown with no cells of its own: at the grid's foot at its own size.
        layout.set("pilot", shown: true)
        #expect(layout.cells(drawn(layout))["pilot"] == Self.cell(0, 11, 18, 3))
    }

    @Test("A block put on another's cells takes them: the blocks in its way move down, those under freed space float up, none overlap")
    func settle() {
        var layout = HomeLayout.standard
        let drawn = layout.shown(extensions: [])
        // The keyboard's corner to 14 × 9 (P91 frame 2): This Mac moves down out of its way.
        layout.set("keyboard", cell: Self.cell(5, 0, 14, 9))
        layout.place(drawn, subject: "keyboard")
        #expect(layout.cell(of: "thisMac") == Self.cell(5, 9, 18, 5))
        // This Mac into the room on the right (frame 3): its width is cut to the 4 columns left, and it floats to the top.
        layout.set("thisMac", cell: Self.cell(19, 7, 18, 5).clamped)
        layout.place(drawn, subject: "thisMac")
        #expect(layout.cell(of: "thisMac") == Self.cell(19, 0, 4, 5))
        #expect(HomeGrid.valid(drawn.compactMap(layout.cell(of:))))
        // Workspaces onto Clipboard's cells: it takes them, Clipboard goes under it, and the gap it left closes.
        layout.set("workspaces", cell: Self.cell(0, 5, 5, 3))
        layout.place(drawn, subject: "workspaces")
        #expect(layout.cell(of: "workspaces") == Self.cell(0, 2, 5, 3) && layout.cell(of: "clipboard") == Self.cell(0, 5, 5, 3))
        // Dragged down, it passes Clipboard once its bottom is past Clipboard's middle, not before.
        layout.set("workspaces", cell: Self.cell(0, 3, 5, 3))
        layout.place(drawn, subject: "workspaces", from: Self.cell(0, 2, 5, 3))
        #expect(layout.cell(of: "workspaces") == Self.cell(0, 2, 5, 3))
        layout.set("workspaces", cell: Self.cell(0, 4, 5, 3))
        layout.place(drawn, subject: "workspaces", from: Self.cell(0, 2, 5, 3))
        #expect(layout.cell(of: "clipboard") == Self.cell(0, 2, 5, 3) && layout.cell(of: "workspaces") == Self.cell(0, 5, 5, 3))
    }

    @Test("A drop in the list puts the block in front of the one it lands on (the tray's and the CLI's order)")
    func drop() {
        var layout = HomeLayout.standard
        layout.move("thisMac", before: "workspaces", listed: layout.resolved(extensions: []).map(\.id))
        #expect(layout.shown(extensions: []) == ["greeting", "thisMac", "workspaces", "keyboard", "clipboard", "mostUsed"])
        let same = layout
        layout.move("keyboard", before: "keyboard", listed: [])
        #expect(layout == same)
    }

    @Test("The grid: 23 columns that stretch with the window, rows 56 pt with 8 between; a frame snaps to the nearest cells")
    func grid() {
        // Sven's window and the default one (the page's 1496 and 856 pt grids): cells 57 and 30 pt wide.
        #expect(abs(HomeGrid.cellWidth(1496) - 57.39) < 0.01 && abs(HomeGrid.cellWidth(856) - 29.57) < 0.01)
        // The column 5 cells (319 pt), the board 18 beside it.
        let board = HomeGrid.rect(Self.cell(5, 0, 18, 6), inner: 1496), column = HomeGrid.rect(Self.cell(0, 2, 5, 3), inner: 1496)
        #expect(abs(board.minX - 326.96) < 0.01 && abs(board.width - 1169.04) < 0.01 && board.minY == 0 && board.height == 376)
        #expect(column.minX == 0 && column.minY == 128 && abs(column.width - 318.96) < 0.01 && column.height == 184)
        #expect(HomeGrid.height([Self.cell(0, 0, 5, 2), Self.cell(5, 0, 18, 6)]) == 376 && HomeGrid.height([]) == 0)
        #expect(HomeGrid.cell(nearest: CGRect(x: 330, y: 70, width: 900, height: 560), inner: 1496) == Self.cell(5, 1, 14, 9))
        // Past the right edge the width is cut; a cell needs one column and one row.
        #expect(Self.cell(20, 0, 9, 5).clamped == Self.cell(20, 0, 3, 5) && Self.cell(-2, -1, 0, 0).clamped == Self.cell(0, 0, 1, 1))
        #expect(HomeCell(words: "19,0,4,3") == Self.cell(19, 0, 4, 3) && HomeCell(words: "4,3") == nil)
        // A top edge dragged up stops at 40 rows; it never turns into a move.
        #expect(Self.cell(0, 50, 5, 40).resized(.top, dx: 0, dy: -5) == Self.cell(0, 50, 5, 40))
        #expect(Self.cell(0, 50, 5, 38).resized(.top, dx: 0, dy: -5) == Self.cell(0, 48, 5, 40))
    }

    @Test("A block's class by its points, as the desktop widgets pick theirs; one row is always a Strip; its Layout keeps one")
    func classes() {
        // At Sven's window: the goal's This Mac and Weather Wide, AI usage and the keyboard Large, the column's cards Wide.
        let at = { (cell: HomeCell, inner: CGFloat) in HomeGrid.sizeClass(cell, inner: inner, pin: nil) }
        #expect(at(Self.cell(19, 0, 4, 3), 1496) == .wide && at(Self.cell(19, 3, 4, 2), 1496) == .wide)
        #expect(at(Self.cell(19, 5, 4, 4), 1496) == .large && at(Self.cell(5, 0, 14, 9), 1496) == .large && at(Self.cell(0, 2, 5, 3), 1496) == .wide)
        // At the default window the cells shrink: they all draw Square but the keyboard (frame 5).
        for cell in [Self.cell(19, 0, 4, 3), Self.cell(19, 3, 4, 2), Self.cell(19, 5, 4, 4), Self.cell(0, 2, 5, 3)] { #expect(at(cell, 856) == .square) }
        #expect(at(Self.cell(5, 0, 14, 9), 856) == .large)
        // One row, even two cells at 760 pt (19 pt each): a Strip. A Layout kept wins.
        #expect(at(Self.cell(0, 0, 2, 1), 680) == .strip && at(Self.cell(0, 0, 1, 1), 1496) == .strip)
        #expect(HomeGrid.sizeClass(Self.cell(0, 0, 5, 3), inner: 1496, pin: .square) == .square)
    }

    @Test("A layout Home draws as the default is the default; moved, or with an uninstalled extension's row, it is not")
    func isStandard() {
        var layout = HomeLayout.standard
        layout.move("clipboard", before: "mostUsed", listed: layout.resolved(extensions: ["git"]).map(\.id))
        #expect(layout.isStandard(extensions: ["git"]))
        layout.set("keyboard", cell: Self.cell(5, 0, 18, 5))
        #expect(!layout.isStandard(extensions: ["git"]))
        var gone = HomeLayout.standard
        gone.rows.append(HomeLayout.Row(id: "ext:gone", shown: false))
        #expect(!gone.isStandard(extensions: []) && gone.isStandard(extensions: ["gone"]))
    }

    @Test("An extension page joins hidden; shown, it goes to the grid's foot at half the board, and uninstalled it is kept but not drawn")
    func extensions() {
        var layout = HomeLayout.standard
        #expect(layout.resolved(extensions: ["git"]).last == HomeLayout.Row(id: "ext:git", shown: false))
        layout.set("ext:git", shown: true)
        #expect(layout.shown(extensions: ["git"]) == ["greeting", "workspaces", "keyboard", "clipboard", "mostUsed", "thisMac", "ext:git"])
        #expect(layout.cells(layout.shown(extensions: ["git"]))["ext:git"] == Self.cell(0, 11, 9, 5))
        #expect(layout.shown(extensions: []) == ["greeting", "workspaces", "keyboard", "clipboard", "mostUsed", "thisMac"])
        #expect(layout.rows.contains { $0.id == "ext:git" })
        #expect(HomeLayout.extensionID("ext:git") == "git" && HomeLayout.extensionID("keyboard") == nil)
    }

    @Test("Saved, a new store reads the same blocks and cells; reset gives the default back and saves nothing")
    func persist() throws {
        let defaults = Self.defaults()
        var layout = HomeLayout.standard
        layout.set("mostUsed", shown: false)
        layout.set("ext:ai-usage", shown: true)
        layout.set("ext:ai-usage", cell: Self.cell(19, 0, 4, 4))
        layout.place(layout.shown(extensions: ["ai-usage"]), subject: "ext:ai-usage")
        HomeLayoutStore(defaults: defaults).save(layout)
        let again = HomeLayoutStore(defaults: defaults)
        #expect(again.layout == layout && again.layout.cell(of: "ext:ai-usage") == Self.cell(19, 0, 4, 4))
        #expect(again.layout.cell(of: "keyboard") == Self.cell(5, 4, 18, 6), "the keyboard moved down out of AI usage's way")
        again.reset()
        #expect(again.layout == .standard)
        #expect(defaults.data(forKey: HomeLayoutStore.key) == nil)
        #expect(HomeLayoutStore(defaults: defaults).layout == .standard)
    }

    @Test("Each style draws what it can; in Toybox the Pilot block comes first while something needs you")
    func drawn() {
        let shown = ["keyboard", "workspaces", "quickActions", "ext:git"]
        #expect(HomeLayout.drawn(shown, style: .instrument, needsYou: true) == ["keyboard", "workspaces", "ext:git"])
        #expect(HomeLayout.drawn(shown + ["pilot"], style: .instrument, needsYou: false) == ["keyboard", "workspaces", "ext:git"])
        #expect(HomeLayout.drawn(shown, style: .toybox, needsYou: true) == ["pilot", "keyboard", "workspaces", "ext:git"])
        #expect(HomeLayout.drawn(shown, style: .toybox, needsYou: false) == ["keyboard", "workspaces", "ext:git"])
        // Toybox's Pilot block, drawn for what needs you, takes the top of the board; the keyboard and This Mac move down.
        let cells = HomePage.cells(.standard, blocks: HomeLayout.drawn(HomeLayout.standard.shown(extensions: []), style: .toybox, needsYou: true),
                                   shown: HomeLayout.standard.shown(extensions: []))
        #expect(cells["pilot"] == Self.cell(5, 0, 18, 3) && cells["keyboard"] == Self.cell(5, 3, 18, 6))
    }

    @Test("Sven's Home from 1.0.2 converts to the same look in cells: the column 5 wide, the board 18, a medium 9, heights in whole rows")
    func convertsSvens() throws {
        let old = try JSONDecoder().decode(HomeLayout.self, from: Data(Self.svensLanes.utf8))
        #expect(old.grid == nil && old.row("ext:now-playing")?.size == .small)
        let layout = HomeLayout(lanes: old)
        let cells = layout.cells(layout.shown(extensions: Self.svensExtensions))
        #expect(cells == ["greeting": Self.cell(0, 0, 5, 2), "workspaces": Self.cell(0, 2, 5, 3), "clipboard": Self.cell(0, 5, 5, 3),
                          "mostUsed": Self.cell(0, 8, 5, 3), "ext:now-playing": Self.cell(0, 11, 5, 3), "keyboard": Self.cell(5, 0, 18, 6),
                          "thisMac": Self.cell(5, 6, 18, 5), "ext:weather": Self.cell(5, 11, 9, 5), "ext:ai-usage": Self.cell(14, 11, 9, 5)])
        // Each keeps the lane size 1.0.2 read, so going back draws Home as before.
        #expect(layout.isValid && layout.row("ext:now-playing")?.size == .small && layout.row("ext:pomodoro")?.size == .icon)
        #expect(layout.row("keyboard")?.size == nil && layout.row("ext:weather")?.size == nil)
        // Hidden blocks keep no cells and stay in the tray, in their order.
        #expect(layout.resolved(extensions: Self.svensExtensions).filter { !$0.shown }.map(\.id)
                == ["pilot", "quickActions", "ext:obsidian-search", "ext:ssh-hosts", "ext:pomodoro"])
        // Icon tabs become one-row Strips at the top of the left side; a lone medium spans the board; with nothing in the
        // column the greeting and the board take the whole width.
        let icons = HomeLayout(lanes: HomeLayout(rows: [.init(id: "ext:a", shown: true, size: .icon), .init(id: "workspaces", shown: true),
                                                        .init(id: "ext:b", shown: true), .init(id: "keyboard", shown: true)], grid: nil))
        #expect(icons.cell(of: "ext:a") == Self.cell(0, 2, 5, 1) && icons.cell(of: "workspaces") == Self.cell(0, 3, 5, 3))
        #expect(icons.cell(of: "ext:b") == Self.cell(5, 0, 18, 5) && icons.cell(of: "keyboard") == Self.cell(5, 5, 18, 6))
        let board = HomeLayout(lanes: HomeLayout(rows: [.init(id: "keyboard", shown: true), .init(id: "ext:a", shown: true), .init(id: "ext:b", shown: true)], grid: nil))
        #expect(board.cell(of: "greeting") == Self.cell(0, 0, 23, 2) && board.cell(of: "keyboard") == Self.cell(0, 2, 23, 6))
        #expect(board.cell(of: "ext:a") == Self.cell(0, 8, 11, 5) && board.cell(of: "ext:b") == Self.cell(11, 8, 12, 5))
    }

    @Test("A list shows the rows that fit; the last becomes N more, never 1 more")
    func fold() {
        #expect(HomeFold.rows(total: 4, fits: 5) == (4, 0))
        #expect(HomeFold.rows(total: 5, fits: 5) == (5, 0))
        // Six in room for five: four rows and "2 more", never five and "1 more".
        #expect(HomeFold.rows(total: 6, fits: 5) == (4, 2))
        #expect(HomeFold.rows(total: 48, fits: 8) == (7, 41))
        #expect(HomeFold.rows(total: 0, fits: 3) == (0, 0))
        for total in 0...30 { for fits in 1...12 { #expect(HomeFold.rows(total: total, fits: fits).more != 1) } }
        // The rows a height holds: whole rows, three at least.
        #expect(HomeFold.fits(height: 300, row: 30) == 10)
        #expect(HomeFold.fits(height: 299.6, row: 30) == 10)
        #expect(HomeFold.fits(height: 40, row: 30) == 3)
        #expect(HomeFold.fits(height: 40, row: 30, least: 1) == 1)
    }

    @Test("Edit mode's wiggle: each corner sways 1 pt, at most 1.5°; each block's period within 8 % of 260 ms, the same every time")
    func wiggle() {
        // A 300 pt card turns 1 / 150 rad; a 52 pt block would turn 2.2°, held to 1.5°.
        #expect(abs(HomeMotion.wiggle(width: 300) - 0.382) < 0.001)
        #expect(HomeMotion.wiggle(width: 52) == 1.5 && HomeMotion.wiggle(width: 0) == 0)
        let ids = HomeLayout.Block.allCases.map(\.rawValue) + ["ext:lazygit", "ext:weather"]
        for id in ids {
            let rhythm = HomeMotion.rhythm(id)
            #expect(rhythm.period >= 0.26 * 0.92 - 1e-9 && rhythm.period <= 0.26 * 1.08 + 1e-9 && rhythm.phase >= 0 && rhythm.phase <= rhythm.period)
            #expect(HomeMotion.rhythm(id) == rhythm)
        }
        #expect(Set(ids.map { HomeMotion.rhythm($0).phase }).count > ids.count / 2, "blocks sway out of step")
    }

    @Test("A right-click's Layout or Hide at rest turns edit mode on with the change in its draft: nothing is saved until Done, and ⌘Z or Escape takes it back (Moody on T4)")
    func rightClickStages() throws {
        let defaults = Self.defaults()
        let store = HomeLayoutStore(defaults: defaults)
        let make = { HomeEditSession(layout: store.layout, extensions: []) }
        // At rest: Layout › Square on the keyboard. Edit mode starts on the saved layout, the draft holds the change, the store none.
        let mode = HomeEditMode.staging({ $0.layout("keyboard", .square) }, in: nil, make: make)
        #expect(mode.session.entry == .standard && mode.session.draft.layout(of: "keyboard") == .square && mode.session.canUndo)
        #expect(store.layout == .standard && defaults.data(forKey: HomeLayoutStore.key) == nil, "saved before Done")
        // In edit mode the next one joins the same draft: Hide This Mac.
        #expect(HomeEditMode.staging({ $0.hide("thisMac") }, in: mode, make: make) === mode)
        #expect(!mode.session.draft.shown(extensions: []).contains("thisMac") && store.layout == .standard)
        // ⌘Z takes the hide back; Escape throws the rest away, the store untouched.
        mode.session.undo()
        #expect(mode.session.draft.shown(extensions: []).contains("thisMac") && mode.session.draft.layout(of: "keyboard") == .square)
        #expect(mode.session.escape() && mode.session.draft == .standard && defaults.data(forKey: HomeLayoutStore.key) == nil)
        // Staged again and Done: saved.
        let again = HomeEditMode.staging({ $0.layout("keyboard", .square) }, in: nil, make: make)
        again.session.done(store)
        #expect(HomeLayoutStore(defaults: defaults).layout.layout(of: "keyboard") == .square)
    }

    @Test("A Layout picked is kept and saved; Auto again leaves the default layout")
    func pickLayout() throws {
        var layout = HomeLayout.standard
        layout.set("ext:lazygit", layout: .strip)
        layout.set("keyboard", layout: .wide)
        #expect(layout.layout(of: "ext:lazygit") == .strip && layout.layout(of: "keyboard") == .wide)
        let defaults = Self.defaults()
        HomeLayoutStore(defaults: defaults).save(layout)
        #expect(HomeLayoutStore(defaults: defaults).layout.layout(of: "ext:lazygit") == .strip)
        #expect(String(decoding: try JSONEncoder().encode(layout), as: UTF8.self).contains(#""layout":"wide""#))
        // An extension's row picked before it is shown joins hidden.
        #expect(layout.rows.contains(HomeLayout.Row(id: "ext:lazygit", shown: false, layout: .strip)))
        layout.set("keyboard", layout: nil)
        layout.rows.removeAll { $0.id == "ext:lazygit" }
        #expect(layout == .standard)
    }

    @Test("A layout saved before the grid converts once as it loads, its bytes kept under home.blocks.lanes, and 1.0.2 still reads it as it was; two rows of one block draw the default, bytes untouched; saved cells that overlap draw packed")
    func oldLayout() throws {
        let defaults = Self.defaults()
        defaults.set(Data(Self.svensLanes.utf8), forKey: HomeLayoutStore.key)
        let layout = HomeLayoutStore(defaults: defaults).layout
        #expect(layout.grid == HomeLayout.version && layout.cell(of: "ext:weather") == Self.cell(5, 11, 9, 5))
        #expect(defaults.data(forKey: HomeLayoutStore.lanesKey) == Data(Self.svensLanes.utf8), "the old layout is kept as it was")
        // Saved converted: the next launch reads the cells, the kept copy untouched.
        let json = String(decoding: try #require(defaults.data(forKey: HomeLayoutStore.key)), as: UTF8.self)
        #expect(json.contains(#""grid":1"#))
        // Going back to 1.0.2, which reads only each row's id, shown and size: Home as it was. Moved, a block's lane size
        // follows its cells: This Mac to the right-hand four columns reads as half the board, the keyboard at 14 across
        // stays the whole board.
        struct Lanes: Decodable { struct Row: Decodable, Equatable { let id: String; let shown: Bool; let size: String? }; let rows: [Row] }
        let back = try JSONDecoder().decode(Lanes.self, from: try #require(defaults.data(forKey: HomeLayoutStore.key)))
        let then = try JSONDecoder().decode(Lanes.self, from: Data(Self.svensLanes.utf8))
        #expect(back.rows.filter { $0.id != "greeting" } == then.rows)
        var moved = layout
        moved.set("thisMac", cell: Self.cell(19, 0, 4, 3))
        moved.set("keyboard", cell: Self.cell(5, 0, 14, 9))
        moved.set("ext:now-playing", cell: Self.cell(0, 11, 5, 1))
        #expect(moved.row("thisMac")?.size == .medium && moved.row("keyboard")?.size == .large && moved.row("ext:now-playing")?.size == .icon)
        // The lane size is not part of the layout Home draws: the default with other sizes is still the default.
        var sized = HomeLayout.standard
        for i in sized.rows.indices { sized.rows[i].size = .icon }
        #expect(sized != .standard && sized.isStandard(extensions: []), "the lane size counted as part of the layout Home draws")
        #expect(HomeLayoutStore(defaults: defaults).layout == layout && defaults.data(forKey: HomeLayoutStore.lanesKey) == Data(Self.svensLanes.utf8))
        // A layout saved before sizes converts too, every block its old default size.
        let older = Self.defaults()
        older.set(Data(#"{"rows":[{"id":"ext:ai-usage","shown":true},{"id":"workspaces","shown":true},{"id":"keyboard","shown":false}]}"#.utf8), forKey: HomeLayoutStore.key)
        let converted = HomeLayoutStore(defaults: older).layout
        #expect(converted.cell(of: "workspaces") == Self.cell(0, 2, 5, 3) && converted.cell(of: "ext:ai-usage") == Self.cell(5, 0, 18, 5))
        // Two rows of one block: the default draws, and the saved bytes stay as they were.
        let doubled = Self.defaults()
        let twice = Data(#"{"rows":[{"id":"keyboard","shown":true},{"id":"keyboard","shown":true,"size":"small"}]}"#.utf8)
        doubled.set(twice, forKey: HomeLayoutStore.key)
        #expect(HomeLayoutStore(defaults: doubled).layout == .standard && doubled.data(forKey: HomeLayoutStore.key) == twice)
        // Its copy is kept first, and only once: a later load, or a Done that saves the default (nothing), never touches it.
        #expect(doubled.data(forKey: HomeLayoutStore.lanesKey) == twice)
        HomeEditSession(layout: HomeLayoutStore(defaults: doubled).layout, extensions: []).done(HomeLayoutStore(defaults: doubled))
        doubled.set(Data(Self.svensLanes.utf8), forKey: HomeLayoutStore.key)
        _ = HomeLayoutStore(defaults: doubled)
        #expect(doubled.data(forKey: HomeLayoutStore.lanesKey) == twice, "the kept copy was written again")
        // Cells that overlap are drawn packed, the later block under the earlier one.
        let broken = Self.defaults()
        let bad = #"{"rows":[{"id":"workspaces","shown":true,"cell":{"x":0,"y":0,"w":5,"h":3}},{"id":"keyboard","shown":true,"cell":{"x":2,"y":1,"w":5,"h":3}}],"grid":1}"#
        broken.set(Data(bad.utf8), forKey: HomeLayoutStore.key)
        #expect(HomeLayoutStore(defaults: broken).layout.cells(["workspaces", "keyboard"])["keyboard"] == Self.cell(2, 3, 5, 3), "drawn packed")
    }

    @Test("A medium extension card keeps the first figures and three rows of the first list; a small card its first figure and list")
    func mediumCard() {
        let rows = (1...5).map { Extension.Item(title: "repo \($0)", actions: []) }
        let page: [Extension.Block] = [
            .markdown("intro"),
            .section(title: "Repos", subtitle: nil, blocks: [.stats([.init(label: "Changed", value: "4", tone: .warn)]), .list(title: "~/code", items: rows)]),
            .buttons([Extension.Item.Action(kind: .run(command: "fetch", context: nil), title: "Fetch all")]),
        ]
        let medium = HomeVariant.medium(page)
        #expect(medium.count == 2)
        if case .list(let title, let items, _) = medium[1] { #expect(title == "~/code" && items.map(\.title) == ["repo 1", "repo 2", "repo 3"]) } else { Issue.record("no list") }
        #expect(HomeVariant.figure(page)?.value == "4" && HomeVariant.figure(page)?.label == "Changed")
        #expect(HomeVariant.list(page)?.count == 5 && HomeVariant.list([.markdown("only words")]) == nil)
        // No list: the figures and the buttons; a meter's figure is its value or its percent.
        let timer: [Extension.Block] = [.meter(.init(label: "Focus", percent: 40, note: nil)), .buttons([Extension.Item.Action(kind: .run(command: "pause", context: nil), title: "Pause")])]
        #expect(HomeVariant.medium(timer).count == 2)
        #expect(HomeVariant.figure(timer)?.value == "40 %")
        #expect(HomeVariant.medium([.markdown("only words")]).count == 1)
        #expect(HomeVariant.figure([.markdown("only words")]) == nil)
    }
}
