import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Story 167: Home's blocks, picked and ordered by the person, with a good default.
@MainActor
@Suite("Home layout")
struct HomeLayoutTests {
    static func defaults() -> UserDefaults { UserDefaults(suiteName: NSTemporaryDirectory() + "pilot.home-layout.\(UUID().uuidString)")! }

    @Test("The default is direction 2: Workspaces, Clipboard and Most used in the column, the keyboard and This Mac on the board")
    func standard() {
        let layout = HomeLayout.standard
        #expect(layout.shown(extensions: []) == ["workspaces", "keyboard", "clipboard", "mostUsed", "thisMac"])
        #expect(layout.resolved(extensions: []).map(\.id) == ["workspaces", "keyboard", "clipboard", "mostUsed", "thisMac", "pilot", "quickActions"])
        #expect(HomeLayout.lanes(layout.shown(extensions: []), size: layout.size, across: 2)
                == HomeLayout.Lanes(column: ["workspaces", "clipboard", "mostUsed"], board: [["keyboard"], ["thisMac"]]))
        #expect(!layout.resolved(extensions: []).contains { $0.id.contains("timer") })
        #expect(HomeLayoutStore(defaults: Self.defaults()).layout == .standard)
    }

    @Test("Hiding and showing a block")
    func hide() {
        var layout = HomeLayout.standard
        layout.set("keyboard", shown: false)
        layout.set("pilot", shown: true)
        #expect(layout.shown(extensions: []) == ["workspaces", "clipboard", "mostUsed", "thisMac", "pilot"])
    }

    @Test("Up and down move a block among the listed ones; the ends stay put")
    func reorder() {
        var layout = HomeLayout.standard
        let listed = layout.resolved(extensions: []).map(\.id)
        layout.move("keyboard", by: -1, listed: listed)
        #expect(layout.shown(extensions: []) == ["keyboard", "workspaces", "clipboard", "mostUsed", "thisMac"])
        layout.move("keyboard", by: -1, listed: layout.resolved(extensions: []).map(\.id))
        #expect(layout.shown(extensions: []).first == "keyboard")
        layout.move("workspaces", by: 1, listed: layout.resolved(extensions: []).map(\.id))
        #expect(layout.shown(extensions: []) == ["keyboard", "clipboard", "workspaces", "mostUsed", "thisMac"])
        // Within a lane, as Edit Home lists it: Most used up past Clipboard.
        layout.move("mostUsed", by: -1, listed: ["clipboard", "workspaces", "mostUsed"])
        #expect(layout.shown(extensions: []) == ["keyboard", "clipboard", "mostUsed", "workspaces", "thisMac"])
        let last = layout.resolved(extensions: []).map(\.id)
        layout.move("quickActions", by: 1, listed: last)
        #expect(layout.resolved(extensions: []).map(\.id) == last)
    }

    @Test("A drop puts the block in front of the one it lands on")
    func drop() {
        var layout = HomeLayout.standard
        layout.move("thisMac", before: "workspaces", listed: layout.resolved(extensions: []).map(\.id))
        #expect(layout.shown(extensions: []) == ["thisMac", "workspaces", "keyboard", "clipboard", "mostUsed"])
    }

    @Test("Moved after a block, a block lands right behind it; after the last, at the end")
    func dropAfter() {
        var layout = HomeLayout.standard
        layout.move("thisMac", after: "workspaces", listed: layout.resolved(extensions: []).map(\.id))
        #expect(layout.shown(extensions: []) == ["workspaces", "thisMac", "keyboard", "clipboard", "mostUsed"])
        layout.move("workspaces", after: "ext:git", listed: layout.resolved(extensions: ["git"]).map(\.id))
        #expect(layout.rows.map(\.id).suffix(2) == ["ext:git", "workspaces"])
        let same = layout
        layout.move("keyboard", after: "keyboard", listed: [])
        #expect(layout == same)
    }

    @Test("A layout Home draws as the default is the default, rows taken in or not; an uninstalled extension's row is not")
    func isStandard() {
        var layout = HomeLayout.standard
        layout.move("clipboard", before: "mostUsed", listed: layout.resolved(extensions: ["git"]).map(\.id))
        #expect(layout != .standard && layout.isStandard(extensions: ["git"]))
        layout.move("keyboard", before: "workspaces", listed: layout.resolved(extensions: ["git"]).map(\.id))
        #expect(!layout.isStandard(extensions: ["git"]))
        var gone = HomeLayout.standard
        gone.rows.append(HomeLayout.Row(id: "ext:gone", shown: false))
        #expect(!gone.isStandard(extensions: []) && gone.isStandard(extensions: ["gone"]))
    }

    @Test("An extension page joins hidden; shown, it keeps its place, and uninstalled it is kept but not drawn")
    func extensions() {
        var layout = HomeLayout.standard
        #expect(layout.resolved(extensions: ["git"]).last == HomeLayout.Row(id: "ext:git", shown: false))
        layout.set("ext:git", shown: true)
        layout.move("ext:git", before: "keyboard", listed: layout.resolved(extensions: ["git"]).map(\.id))
        #expect(layout.shown(extensions: ["git"]) == ["workspaces", "ext:git", "keyboard", "clipboard", "mostUsed", "thisMac"])
        #expect(layout.shown(extensions: []) == ["workspaces", "keyboard", "clipboard", "mostUsed", "thisMac"])
        #expect(layout.rows.contains { $0.id == "ext:git" })
        #expect(HomeLayout.extensionID("ext:git") == "git" && HomeLayout.extensionID("keyboard") == nil)
    }

    @Test("Saved, a new store reads the same blocks; reset gives the default back and saves nothing")
    func persist() throws {
        let defaults = Self.defaults()
        var layout = HomeLayout.standard
        layout.set("mostUsed", shown: false)
        layout.set("ext:ai-usage", shown: true)
        layout.move("ext:ai-usage", before: "workspaces", listed: layout.resolved(extensions: ["ai-usage"]).map(\.id))
        HomeLayoutStore(defaults: defaults).save(layout)
        let again = HomeLayoutStore(defaults: defaults)
        #expect(again.layout == layout)
        #expect(again.layout.shown(extensions: ["ai-usage"]) == ["ext:ai-usage", "workspaces", "keyboard", "clipboard", "thisMac"])
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
    }

    @Test("The sizes go up a lane step at a time: icon and small in the column, medium half the board, large all of it")
    func scale() {
        #expect(HomeLayout.Size.allCases == [.icon, .small, .medium, .large])
        #expect(HomeLayout.Size.allCases.map(\.lane) == [.column, .column, .board, .board])
        #expect(HomeLayout.Size.allCases.map(\.place) == ["a tab in the column", "a card in the column", "half the board", "the whole board"])
        // Every size reads back as itself, so a saved layout and the pilot command keep their words.
        for size in HomeLayout.Size.allCases { #expect(HomeLayout.Size(rawValue: size.rawValue) == size) }
    }

    @Test("Every block has a size: the column's lists small, the keyboard and This Mac large, an extension's page medium")
    func standardSizes() {
        let layout = HomeLayout.standard
        for id in ["workspaces", "mostUsed", "clipboard", "pilot", "quickActions"] { #expect(layout.size(of: id) == .small) }
        #expect(layout.size(of: "keyboard") == .large && layout.size(of: "thisMac") == .large)
        #expect(layout.size(of: "ext:lazygit") == .medium)
        #expect(layout.rows.allSatisfy { $0.size == nil })
    }

    @Test("Lanes keep each block's order; a medium pairs with the next board block when that is medium, else takes the row")
    func lanes() {
        let sizes: [String: HomeLayout.Size] = ["ext:git": .icon, "ext:weather": .icon, "ext:pomodoro": .small, "ext:ai-usage": .medium,
                                                "thisMac": .medium, "mostUsed": .medium, "keyboard": .large]
        let size = { (id: String) in sizes[id] ?? .standard(id) }
        let ids = ["ext:git", "workspaces", "ext:ai-usage", "clipboard", "thisMac", "keyboard", "ext:weather", "mostUsed", "ext:pomodoro"]
        let lanes = HomeLayout.lanes(ids, size: size, across: 2)
        #expect(lanes.icons == ["ext:git", "ext:weather"])
        // Clipboard, between the two mediums, stays in its place in the column.
        #expect(lanes.column == ["workspaces", "clipboard", "ext:pomodoro"])
        #expect(lanes.board == [["ext:ai-usage", "thisMac"], ["keyboard"], ["mostUsed"]])
        // A medium before a large takes the row; one board column, each takes its own.
        #expect(HomeLayout.lanes(["mostUsed", "keyboard", "thisMac"], size: size, across: 2).board == [["mostUsed"], ["keyboard"], ["thisMac"]])
        #expect(HomeLayout.lanes(["ext:ai-usage", "thisMac"], size: size, across: 1).board == [["ext:ai-usage"], ["thisMac"]])
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
        // The rows a height holds: whole rows, three at least; Home's one column shows five.
        #expect(HomeFold.fits(height: 300, row: 30) == 10)
        #expect(HomeFold.fits(height: 299.6, row: 30) == 10)
        #expect(HomeFold.fits(height: 40, row: 30) == 3)
        #expect(HomeFold.fits(height: 40, row: 30, least: 1) == 1)
        #expect(HomeFold.stacked == 5)
        // The column shares its height: each card its least, then even shares up to its whole list, the last the rest.
        #expect(HomeColumn.share(600, least: [100, 100, 100], most: [150, 400, .infinity]) == [150, 225, 225])
        #expect(HomeColumn.share(250, least: [100, 100, 100], most: [150, 400, .infinity]) == [100, 100, 100])
        // Four workspaces need 30 more and the even share is 23: they show whole, the others share the rest.
        #expect(HomeColumn.share(370, least: [100, 100, 100], most: [130, 400, .infinity]) == [130, 120, 120])
    }

    @Test("The column sits beside the board while the board keeps its least width")
    func widths() {
        #expect(HomeNow.sideBySide(inner: 1076, gap: 16))
        #expect(!HomeNow.sideBySide(inner: 1075, gap: 16))
        // Stacked, the small cards go as many to a row as keep 280 pt: one at a phone's width, four at most.
        #expect([300, 604, 864, 944, 1284, 2000].map { HomeNow.across(inner: $0, gap: 16) } == [1, 2, 2, 3, 4, 4])
    }

    @Test("Edit mode's wiggle: each corner sways 1 pt, at most 1.5°; each block's period within 8 % of 260 ms, the same every time")
    func wiggle() {
        // A 300 pt card turns 1 / 150 rad; a 52 pt tab would turn 2.2°, held to 1.5°.
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

    @Test("A right-click's Size or Hide at rest turns edit mode on with the change in its draft: nothing is saved until Done, and ⌘Z or Escape takes it back (Moody on T4)")
    func rightClickStages() throws {
        let defaults = Self.defaults()
        let store = HomeLayoutStore(defaults: defaults)
        // At rest: Size › Medium on the keyboard. Edit mode starts on the saved layout, the draft holds the change, the store none.
        let mode = HomeEditMode.staging({ $0.size("keyboard", .medium) }, in: nil, layout: store.layout, extensions: [])
        #expect(mode.session.entry == .standard && mode.session.draft.size(of: "keyboard") == .medium && mode.session.canUndo)
        #expect(store.layout == .standard && defaults.data(forKey: HomeLayoutStore.key) == nil, "saved before Done")
        // In edit mode the next one joins the same draft: Hide This Mac.
        #expect(HomeEditMode.staging({ $0.hide("thisMac") }, in: mode, layout: store.layout, extensions: []) === mode)
        #expect(!mode.session.draft.shown(extensions: []).contains("thisMac") && store.layout == .standard)
        // ⌘Z takes the hide back; Escape throws the rest away, the store untouched.
        mode.session.undo()
        #expect(mode.session.draft.shown(extensions: []).contains("thisMac") && mode.session.draft.size(of: "keyboard") == .medium)
        #expect(mode.session.escape() && mode.session.draft == .standard && defaults.data(forKey: HomeLayoutStore.key) == nil)
        // Staged again and Done: saved.
        let again = HomeEditMode.staging({ $0.size("keyboard", .medium) }, in: nil, layout: store.layout, extensions: [])
        again.session.done(store)
        #expect(HomeLayoutStore(defaults: defaults).layout.size(of: "keyboard") == .medium)
    }

    @Test("A size chip under the pointer previews the block where the new size puts it, at that size's width")
    func sizePreview() {
        // Beside the board: Workspaces and Clipboard cards in the column, the keyboard large and This Mac a lone medium.
        let blocks = ["workspaces", "clipboard", "keyboard", "thisMac"]
        let sizes: [String: HomeLayout.Size] = ["workspaces": .small, "clipboard": .small, "keyboard": .large, "thisMac": .medium]
        let shape = HomeNow.Shape(wide: true, across: 2, gap: 16)
        let drawn = HomeFrames.Drawn(shape: shape, lanes: HomeLayout.lanes(blocks, size: { sizes[$0]! }, across: 2))
        let rects: [HomeFrames.Key: CGRect] = [
            .lane(.column): CGRect(x: 28, y: 22, width: 300, height: 600), .lane(.board): CGRect(x: 344, y: 22, width: 900, height: 600),
            .block("workspaces"): CGRect(x: 28, y: 160, width: 300, height: 200), .block("clipboard"): CGRect(x: 28, y: 376, width: 300, height: 246),
            .block("keyboard"): CGRect(x: 344, y: 22, width: 900, height: 340), .block("thisMac"): CGRect(x: 344, y: 378, width: 900, height: 244),
        ]
        func frame(_ id: String, _ size: HomeLayout.Size, _ rects: [HomeFrames.Key: CGRect] = rects) -> CGRect? {
            HomeEditPreview.frame(of: id, at: size, blocks: blocks, sizes: { sizes[$0]! }, drawn: drawn, rects: rects)
        }
        // The keyboard medium pairs with This Mac: the first row's left half, at its own height.
        #expect(frame("keyboard", .medium) == CGRect(x: 344, y: 22, width: 442, height: 340))
        // This Mac large: its own row, across the board.
        #expect(frame("thisMac", .large) == CGRect(x: 344, y: 378, width: 900, height: 244))
        // This Mac small goes to the column's end, a well high.
        #expect(frame("thisMac", .small) == CGRect(x: 28, y: 638, width: 300, height: HomeNow.well))
        // Workspaces large: the board's first row, across it, a well high.
        #expect(frame("workspaces", .large) == CGRect(x: 344, y: 22, width: 900, height: HomeNow.well))
        // An icon: a tab where the icon row's well is; none measured, no preview.
        #expect(frame("clipboard", .icon) == nil)
        var withWell = rects
        withWell[.well(.icons)] = CGRect(x: 28, y: 100, width: 300, height: 52)
        #expect(frame("clipboard", .icon, withWell) == CGRect(x: 28, y: 100, width: 52, height: 52))
    }

    @Test("A size picked is kept and saved; picking the default again leaves the default layout")
    func pickSize() throws {
        var layout = HomeLayout.standard
        layout.set("ext:lazygit", size: .icon)
        layout.set("keyboard", size: .medium)
        #expect(layout.size(of: "ext:lazygit") == .icon && layout.size(of: "keyboard") == .medium)
        #expect(layout.rows.compactMap { row in row.size.map { "\(row.id) \($0)" } } == ["keyboard medium", "ext:lazygit icon"])
        let defaults = Self.defaults()
        HomeLayoutStore(defaults: defaults).save(layout)
        #expect(HomeLayoutStore(defaults: defaults).layout.size(of: "ext:lazygit") == .icon)
        // An extension's row picked before it is shown joins hidden.
        #expect(layout.rows.contains(HomeLayout.Row(id: "ext:lazygit", shown: false, size: .icon)))
        layout.set("keyboard", size: .large)
        layout.set("ext:lazygit", size: .medium)
        layout.rows.removeAll { $0.id == "ext:lazygit" }
        #expect(layout == .standard)
    }

    @Test("A layout saved before sizes loads as it was, every block its default size")
    func oldLayout() throws {
        let defaults = Self.defaults()
        let old = #"{"rows":[{"id":"ext:ai-usage","shown":true},{"id":"workspaces","shown":true},{"id":"keyboard","shown":false}]}"#
        defaults.set(Data(old.utf8), forKey: HomeLayoutStore.key)
        let layout = HomeLayoutStore(defaults: defaults).layout
        #expect(layout.shown(extensions: ["ai-usage"]) == ["ext:ai-usage", "workspaces"])
        #expect(layout.size(of: "ext:ai-usage") == .medium && layout.size(of: "workspaces") == .small)
        // Saved again, a default size writes nothing.
        let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
        #expect(!json.contains("size"))
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
