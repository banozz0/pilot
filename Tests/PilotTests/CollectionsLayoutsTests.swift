import Foundation
import PilotCore
import Testing
@testable import Pilot

/// CLI W20 (Sven's D3): Home's blocks as `pilot list|add|remove home-blocks`, each edit read back from the layout store
/// Home draws from, in a defaults suite of its own. Never the running Pilot's.
@MainActor
@Suite("Collections: Home blocks")
struct CollectionsLayoutsTests {
    let defaults = UserDefaults(suiteName: testSuite())!
    let store: HomeLayoutStore
    let verbs = ControlVerbs()
    final class Picked { var style = PilotStyle.instrument }
    let picked = Picked()

    init() {
        store = HomeLayoutStore(defaults: defaults)
        let (store, picked) = (store, picked)
        verbs.registerHomeBlocks(HomeBlockStores(layout: { store }, pages: { [ExtensionPages.Link(id: "pomo", title: "Pomodoro", icon: "🍅")] },
                                                 style: { picked.style }, widgets: { [] }))
    }

    func answer(_ verb: String, _ args: [String]) async -> ControlAnswer {
        await verbs.answer(ControlRequest(id: .number(1), verb: verb, args: args), peer: nil)
    }

    func rows() async -> [[String: JSONValue]] {
        guard case .array(let rows) = await answer("list", ["home-blocks"]).result else { Issue.record("list gave no rows"); return [] }
        return rows.compactMap { if case .object(let row) = $0 { row } else { nil } }
    }

    func blocks() async -> [String] { await rows().compactMap { if case .string(let b) = $0["block"] { b } else { nil } } }

    @Test("List: Edit Home's rows in its order, hidden ones and extension pages too, each with its cells and layout, without the blocks the style leaves out")
    func list() async {
        let all = await rows()
        #expect(await blocks() == ["greeting", "workspaces", "keyboard", "clipboard", "mostUsed", "thisMac", "ext:pomo"])
        #expect(all.first == ["block": .string("greeting"), "title": .string("Today"), "shown": .bool(true), "cells": .string("0,0,5,2"),
                              "layout": .string("auto"), "at": .number(0)])
        #expect(all[2]["cells"] == .string("5,0,18,6"))
        #expect(all.last == ["block": .string("ext:pomo"), "title": .string("Pomodoro"), "shown": .bool(false), "cells": .null,
                             "layout": .string("auto"), "at": .number(6)])
        #expect(!(await blocks()).contains("pilot"))
    }

    @Test("Add shows a block on the cells it names (the blocks there moving down), answering its row")
    func add() async {
        // Pomodoro on the keyboard's top right: it takes the cells, the keyboard moves down under it.
        let placed = await answer("add", ["home-blocks", "--block", "ext:pomo", "--cells", "19,0,4,4"])
        #expect(placed.result.flatMap { if case .object(let row) = $0 { row["cells"] } else { nil } } == .string("19,0,4,4"))
        #expect(store.layout.cell(of: "keyboard") == HomeCell(x: 5, y: 4, w: 18, h: 6))
    }

    @Test("Add --at places a block in the list, hidden rows counted, as a drop on the row there does")
    func at() async {
        var oracle = store.layout
        let listed = await blocks()
        oracle.set("ext:pomo", shown: true)
        oracle.move("ext:pomo", before: listed[4], listed: listed)
        oracle.place(oracle.shown(extensions: ["pomo"]), subject: "ext:pomo")
        let moved = await answer("add", ["home-blocks", "--block", "ext:pomo", "--at", "4"])
        #expect(moved.result.flatMap { if case .object(let row) = $0 { row["at"] } else { nil } } == .number(4))
        #expect(store.layout == oracle)
        #expect(await blocks() == ["greeting", "workspaces", "keyboard", "clipboard", "ext:pomo", "mostUsed", "thisMac"])
        _ = await answer("add", ["home-blocks", "--block", "workspaces", "--at", "99"])
        #expect(await blocks().last == "workspaces")
    }

    @Test("Remove hides a block; --reset puts the default back")
    func remove() async {
        let hidden = await answer("remove", ["home-blocks", "workspaces"])
        #expect(hidden.result.flatMap { if case .object(let row) = $0 { row["shown"] } else { nil } } == .bool(false))
        #expect(await answer("remove", ["home-blocks", "workspaces"]).error == ControlError(.badValue, "workspaces is already hidden"))
        #expect(store.layout != .standard)
        #expect(await answer("remove", ["home-blocks", "--reset"]).ok)
        #expect(store.layout == .standard && defaults.data(forKey: HomeLayoutStore.key) == nil)
    }

    @Test("Refusals: an unknown block, one the style leaves out, an extension not installed, a bad layout, cells or place, a stray flag")
    func refusals() async {
        let missing = "; pilot list home-blocks lists them"
        #expect(await answer("add", ["home-blocks", "--block", "nope"]).error == ControlError(.badValue, "no block nope" + missing))
        #expect(await answer("add", ["home-blocks", "--block", "quickActions"]).error
            == ControlError(.badValue, "quickActions is not drawn in this style" + missing))
        #expect(await answer("add", ["home-blocks", "--block", "pilot"]).error == ControlError(.badValue, "pilot is not drawn in this style" + missing))
        #expect(await answer("remove", ["home-blocks", "ext:gone"]).error
            == ControlError(.badValue, "no installed extension with a page is gone" + missing))
        #expect(await answer("add", ["home-blocks", "--block", "workspaces", "--layout", "huge"]).error?.message.hasPrefix("--layout: huge") == true)
        #expect(await answer("add", ["home-blocks", "--block", "workspaces", "--cells", "20,0,5,3"]).error?.message.hasPrefix("--cells: 20,0,5,3") == true)
        #expect(await answer("add", ["home-blocks", "--block", "workspaces", "--cells", "big"]).error?.message.hasPrefix("--cells: big") == true)
        #expect(await answer("add", ["home-blocks", "--block", "workspaces", "--at", "-1"]).error?.message.hasPrefix("--at: -1") == true)
        #expect(await answer("add", ["home-blocks", "--block", "workspaces", "--shown", "false"]).error?.code == .unknownFlag)
        #expect(await answer("remove", ["home-blocks", "--all"]).error?.code == .unknownFlag)
        #expect(store.layout == .standard, "nothing refused was saved")
    }

    @Test("Schema: the row key and add's fields, nothing waiting on Allow")
    func schema() throws {
        guard case .object(let entry) = try verbs.schema(collection: "home-blocks") else { Issue.record("no schema"); return }
        #expect(entry["rowKey"] == .string("block") && entry["asks"] == .array([]))
        guard case .array(let fields) = entry["fields"] else { Issue.record("no fields"); return }
        let names: [JSONValue?] = fields.map { if case .object(let f) = $0 { f["name"] } else { nil } }
        #expect(names == [.string("block"), .string("at"), .string("cells"), .string("layout")])
    }
}
