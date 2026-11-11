import Foundation
import Testing
@testable import PilotCore

/// The hold-Hyper overlay (card agent-bo-95422448, stories 55 and 56): held 0.4 s with no other key it shows that
/// sublayer's binds, follows Shift and Ctrl, and closes on any key or on release.
@Suite("Hold-Hyper overlay")
struct HoldOverlayTests {
    @Test("Held 0.4 s with no other key, the Hyper page shows; not before")
    func showsAfterDelay() {
        var o = HoldOverlay()
        o.layerDown(at: 10)
        #expect(o.tick(at: 10.39) == .none)
        #expect(o.tick(at: 10.4) == .show(.hyper))
        #expect(o.tick(at: 10.6) == .none)
    }

    @Test("A key before 0.4 s means a bind, so the overlay never shows")
    func keyCancels() {
        var o = HoldOverlay()
        o.layerDown(at: 0)
        #expect(o.key() == .none)
        #expect(o.tick(at: 1) == .none)
    }

    @Test("Shift or Ctrl while held turns the page; a key or release closes it")
    func followsSublayerThenCloses() {
        var o = HoldOverlay()
        o.layerDown(at: 0)
        #expect(o.modifiers(.shift) == .none)
        #expect(o.tick(at: 0.5) == .show(.shift))
        #expect(o.modifiers([.shift, .ctrl]) == .redraw(.shiftCtrl))
        #expect(o.modifiers([.shift, .ctrl]) == .none)
        #expect(o.modifiers([]) == .redraw(.hyper))
        #expect(o.key() == .hide)
        #expect(o.tick(at: 2) == .none)
        o.layerDown(at: 3)
        #expect(o.tick(at: 3.5) == .show(.hyper))
        #expect(o.layerUp() == .hide)
        #expect(o.layerUp() == .none)
    }

    @Test("A modifier set with no page of its own keeps the page shown")
    func untabbedModifiers() {
        var o = HoldOverlay()
        o.layerDown(at: 0)
        _ = o.tick(at: 0.4)
        #expect(o.modifiers([.shift, .alt]) == .none)
    }
}

@Suite("Overlay page")
struct OverlayPageTests {
    let actions: [BindsPage.ActionInfo] = [
        .init(id: "a.terminal", label: "Terminal", module: "apps"), .init(id: "w.close", label: "Close window", module: "windows"),
        .init(id: "w.swap", label: "Swap window", module: "windows"), .init(id: "w.vim", label: "Vim focus", module: "windows"),
        .init(id: "w.idle", label: "Never pressed", module: "windows"),
    ]
    let store = BindStore(defaults: [
        "a.terminal": Key("return"), "w.close": Key("w"), "w.idle": Key("i"), "w.swap": Key("←", .shift),
        "w.vim": Key("h", .leftAlt, hyper: false),
    ])

    @Test("Every bind shows that sublayer's Hyper binds only, never a plain combo")
    func every() {
        let rows = OverlayPage.rows(store: store, actions: actions, sublayer: .hyper, mode: .every, presses: [:], picks: [])
        #expect(rows.map(\.label) == ["Terminal", "Close window", "Never pressed"])
        #expect(OverlayPage.rows(store: store, actions: actions, sublayer: .shift, mode: .every, presses: [:], picks: []).map(\.key) == ["←"])
    }

    @Test("Most used shows the pressed ones, most first, at most the limit; my pick shows the picked ones")
    func mostUsedAndPick() {
        let presses = ["w.close": 9, "a.terminal": 3, "w.vim": 50]
        let used = OverlayPage.rows(store: store, actions: actions, sublayer: .hyper, mode: .mostUsed, presses: presses, picks: [], limit: 1)
        #expect(used.map(\.label) == ["Close window"])
        let picked = OverlayPage.rows(store: store, actions: actions, sublayer: .hyper, mode: .pick, presses: [:], picks: ["w.idle"])
        #expect(picked.map(\.label) == ["Never pressed"])
    }

    @Test("Binds › More › Overlay lists every sublayer's bind by module with its whole key, never a plain combo, ticked as it shows; search narrows")
    func choices() {
        let shown = OverlayPage.shown(store: store, actions: actions, mode: .pick, presses: [:], picks: ["w.swap", "w.vim"])
        #expect(shown == ["w.swap"], "a picked plain combo never shows")
        let groups = OverlayPage.choices(store: store, actions: actions, shown: shown)
        #expect(groups.map(\.module) == ["apps", "windows"])
        #expect(groups[1].choices.map(\.label) == ["Close window", "Never pressed", "Swap window"])
        #expect(groups[1].choices.map(\.shown) == [false, false, true])
        #expect(groups[1].choices.last?.key == Key("←", .shift).label)
        #expect(OverlayPage.choices(store: store, actions: actions, shown: [], search: "shift").flatMap(\.choices).map(\.id) == ["w.swap"])
        #expect(OverlayPage.choices(store: store, actions: actions, shown: [], search: "apps").flatMap(\.choices).map(\.id) == ["a.terminal"])
    }

    @Test("A switch keeps what shows and moves the one bind: off from Every bind leaves every other, on adds it")
    func switching() {
        let every = OverlayPage.shown(store: store, actions: actions, mode: .every, presses: [:], picks: [])
        #expect(every == ["a.terminal", "w.close", "w.idle", "w.swap"])
        let off = OverlayPage.picks(switching: "w.close", on: false, shown: every)
        #expect(off == ["a.terminal", "w.idle", "w.swap"])
        #expect(OverlayPage.shown(store: store, actions: actions, mode: .pick, presses: [:], picks: off) == off)
        let used = OverlayPage.shown(store: store, actions: actions, mode: .mostUsed, presses: ["w.close": 2], picks: [])
        #expect(OverlayPage.picks(switching: "w.idle", on: true, shown: used) == ["w.close", "w.idle"])
    }

    @Test("The press counter counts per action and reads back what it wrote")
    func pressCounter() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-presses-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = PressCountStore(url: dir.appending(path: "presses.json"))
        var counts = try file.load()
        #expect(counts.counts.isEmpty)
        counts.count("w.close"); counts.count("w.close"); counts.count("a.terminal")
        try file.save(counts)
        #expect(try file.load().counts == ["w.close": 2, "a.terminal": 1])
    }
}
