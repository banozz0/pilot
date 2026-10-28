import AppKit
import PilotCore
import Testing
@testable import Pilot

/// Menu bar peek (card agent-bo-95423008): holding its bind drops Pilot's bar under the macOS menu bar, letting go
/// raises it again. Fakes only: no window is shown and no real key reaches the tap.
@MainActor
@Suite("Menu bar peek")
struct MenuBarPeekTests {
    static func registered(_ bar: TopBarController) throws -> Action {
        var registry = ActionRegistry()
        TopBarController.register(into: &registry, bar: bar)
        return try #require(registry.actions["bar.peekMenuBar"])
    }

    @Test("Key down puts every bar panel under the menu bar; key up raises them again at once, well inside 150 ms")
    func peek() throws {
        let panels = TopBarControllerTests.FakePanels()
        let action = try Self.registered(TopBarControllerTests.make(TopBarControllerTests.defaults(), panels: panels))
        #expect(panels.level == TopBarWindows.aboveMenuBar)
        let hold = try #require(action.hold)
        hold(true)
        #expect(panels.level < .mainMenu)
        hold(false)
        #expect(panels.level == TopBarWindows.aboveMenuBar)
        #expect(panels.level > .mainMenu)
    }

    @Test("Run from the menu, Home or pilot://run, with no key to come up, the peek lets go at once and never leaves the bars down")
    func runWithoutKey() throws {
        let panels = TopBarControllerTests.FakePanels()
        let action = try Self.registered(TopBarControllerTests.make(TopBarControllerTests.defaults(), panels: panels))
        action.run()
        #expect(panels.level == TopBarWindows.aboveMenuBar)
        action.with(label: "Renamed").run()
        #expect(panels.level == TopBarWindows.aboveMenuBar)
        #expect(action.with(label: "Renamed").hold != nil)
    }

    @Test("The Binds page lists the peek on Hyper+Shift+M, the first free M or B in the user's binds (plain M and B are theirs)")
    func listed() throws {
        let action = try Self.registered(TopBarControllerTests.make(TopBarControllerTests.defaults()))
        let store = BindStore(defaults: MyBinds.preset(registry: [action.id: try #require(action.defaultKey)]), actions: [action.id])
        let info = BindsPage.ActionInfo(id: action.id, label: action.label, module: action.module.rawValue)
        let row = try #require(BindsPage.rows(store: store, actions: [info], tab: .layer(.shift)).first)
        #expect(row.id == "bar.peekMenuBar" && row.key == "M")
        #expect(row.label == "Show the menu bar while held")
    }

    @Test("The tap hands back the key a bind ran when that key comes up, after the layer key or before it")
    func tapReleases() {
        let m: Int64 = 46
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        tap.isBound = { $0 == Key("m", .shift) }
        var ran: [Key] = [], released: [Key] = []
        tap.onRun = { key, _ in ran.append(key) }
        tap.onRelease = { released.append($0) }
        #expect(tap.route(.init(kind: .keyDown, keyCode: KeyCode.f18)))
        #expect(tap.route(.init(kind: .keyDown, keyCode: m, flags: KeyEvent.shiftMask)))
        #expect(tap.route(.init(kind: .keyDown, keyCode: m, flags: KeyEvent.shiftMask, autorepeat: true)))
        #expect(released.isEmpty)
        #expect(tap.route(.init(kind: .keyUp, keyCode: m)))
        #expect(released == [Key("m", .shift)])
        // The layer key first, M still held: its key up still ends the hold.
        #expect(tap.route(.init(kind: .keyDown, keyCode: m, flags: KeyEvent.shiftMask)))
        #expect(tap.route(.init(kind: .keyUp, keyCode: KeyCode.f18)))
        _ = tap.route(.init(kind: .keyUp, keyCode: m))
        #expect(released == [Key("m", .shift), Key("m", .shift)])
        #expect(ran.count == 3)
    }
}
