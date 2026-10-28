import Foundation
import PilotCore
import PilotTiler
import Testing
@testable import Pilot

/// Card agent-bo-95423010 in the app: a right-click on a macOS menu bar item opens its menu, whose picks change the bar or
/// run the item's action; scroll and the menu's workspace steps go through TilerService to Pilot's tiler. Fakes only: a
/// fake host, fake audio, a fake engine.
@MainActor
@Suite("Bar actions in the app")
struct BarActionsWiringTests {
    typealias Engine = TilerEnginePathTests.FakeEngine

    static func sources(_ engine: Engine, audio: SetupSoundTests.FakeAudio = .init()) -> BarSources {
        let tiler = TilerEnginePathTests().service(engine)
        return MenuBarStatusItemsTests.sources(SystemSamplerTests.sampler(SystemSamplerTests.Counter()), audio: audio,
                                               observers: EngineObservers(tiler: tiler))
    }

    static func waitFor(_ engine: Engine, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while engine.commands.count < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("Scroll and the menu step through the workspaces on Pilot's tiler, up the previous one, down the next")
    func workspaces() async throws {
        let engine = Engine()
        let sources = Self.sources(engine)
        BarScroll.perform(.workspaces, steps: 1, on: sources)
        BarScroll.perform(.workspaces, steps: -1, on: sources)
        sources.perform(.workspace(next: true), on: .workspaces, store: BarItemsStore(defaults: try MenuBarStatusItemsTests.defaults()) { [:] }) {}
        try await Self.waitFor(engine, count: 3)
        #expect(engine.commands == [.workspacePrevious, .workspaceNext, .workspaceNext])
    }

    @Test("A click anywhere on the clock opens its popover, never Calendar (SPEC story 168)")
    func clockOpensPopover() {
        var sources = Self.sources(Engine())
        var opened: [String] = []
        sources.openApp = { opened.append($0) }
        let parts = BarParts.parts(BarSettings.defaults.entry(.clock), BarInputs())!
        let targets = BarParts.targets([parts], click: BarSlot.item(BarSettings.defaults.entry(.clock)).click)
        #expect(targets.map(\.click) == [.popover])
        for target in targets { sources.perform(target.click) }
        #expect(opened.isEmpty)
    }

    @Test("Scroll on Volume sets the output 5 percent a step through the sound seam")
    func volume() {
        let audio = SetupSoundTests.FakeAudio()
        let sources = Self.sources(Engine(), audio: audio)
        sources.readings.sound.start()
        BarScroll.perform(.volume, steps: 2, on: sources)
        #expect(audio.setVolumeCalls.map { (($0.0 * 100).rounded(), $0.1) } .elementsEqual([(60, 10)]) { $0 == $1 })
        // The menu's Output picks a device by its name.
        sources.perform(.output("LG HDR 4K"), on: .volume, store: BarItemsStore(defaults: UserDefaults(suiteName: testSuite())!) { [:] }) {}
        #expect(audio.defaults[.output] == 11)
    }

    @Test("A right-click on a menu bar item opens its menu, without Move to; Remove from bar takes it off and a style is set")
    func menuBarRightClick() throws {
        let store = BarItemsStore(defaults: try MenuBarStatusItemsTests.defaults()) { [:] }
        store.settings.set(.storage, on: true)
        let host = MenuBarStatusItemsTests.Host()
        let items = MenuBarStatusItems(store: store, host: host)
        let sources = Self.sources(Engine())
        sources.readings.sound.start()
        items.start(sources)
        let content = StatusItemContent(kinds: [.storage], parts: [], isGroup: false)
        items.click(content, right: true)
        let menu = try #require(host.menus.last)
        #expect(menu.kinds == [.storage] && host.presented.isEmpty)
        #expect(menu.rows == store.settings.entry(.storage).menu(BarInputs(), in: .menuBar))
        // Volume's menu lists the outputs to pick.
        store.settings.set(.volume, on: true)
        items.click(StatusItemContent(kinds: [.volume], parts: [], isGroup: false), right: true)
        #expect(try #require(host.menus.last).rows.contains { if case .submenu("Output", let rows) = $0 { rows.count == 3 } else { false } })
        menu.perform(.edit(.style(.bar)))
        #expect(store.settings.entry(.storage).style == .bar)
        menu.perform(.edit(.remove))
        #expect(!store.settings.entry(.storage).on)
        // The group's menu is the Group's.
        items.click(StatusItemContent(kinds: [.cpu, .memory], parts: [], isGroup: true), right: true)
        #expect(host.menus.last?.kinds == [.cpu, .memory])
        host.menus.last?.perform(.edit(.remove))
        #expect(!store.settings.entry(.group).on && store.settings.entry(.cpu).on)
    }
}
