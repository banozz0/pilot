import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The front app's own menus as a top bar item (card agent-bo-95423015), on a fake menu bar: nothing is read from or
/// pressed in a real app, and the activation notification is posted on the test's own centre.
@MainActor
@Suite("App menus")
struct AppMenusTests {
    static let textEdit: pid_t = 20, finder: pid_t = 11

    static func menuBar(_ titles: [String]) -> [MenuExtrasRaw] {
        titles.map { MenuExtrasRaw(title: $0, description: nil, help: nil, handle: MenuItemHandle($0 as NSString)) }
    }

    static func fake() -> MenuAppsTests.FakeExtras {
        let fake = MenuAppsTests.FakeExtras()
        // As Accessibility lists TextEdit's AXMenuBar: the Apple menu first, then the app's own menu.
        fake.trees = [textEdit: menuBar(["Apple", "TextEdit", "File", "Edit", "Format", "View", "Window", "Help"]),
                      finder: menuBar(["Apple", "Finder", "File", "Edit", "View", "Go", "Window", "Help"])]
        return fake
    }

    final class Front { var pid: pid_t? = 20 }

    @Test("TextEdit in front: its menus in order, its own menu first, never the Apple menu")
    func titles() async {
        let menus = AppMenus(reader: Self.fake(), front: { Front().pid }, center: NotificationCenter())
        await menus.refresh().value
        #expect(menus.list.map(\.label) == ["TextEdit", "File", "Edit", "Format", "View", "Window", "Help"])
        #expect(!menus.list.map(\.label).contains("Apple"))
    }

    /// Presses by title path, as AXMenu would in the app.
    final class Presses: @unchecked Sendable { var paths: [(pid_t, [String])] = [] }

    @Test("A click on Edit reads Edit's own items, never pressing the hidden menu bar's title; a pick presses its path in TextEdit (Sven on build 21)")
    func press() async throws {
        let fake = Self.fake(), presses = Presses()
        let edit = [MenuItemNode(title: "Undo", enabled: true, char: "Z", modifiers: 0), MenuItemNode(title: "", enabled: false),
                    MenuItemNode(title: "Copy", enabled: true, char: "C", modifiers: 0)]
        let menus = AppMenus(reader: fake, front: { Front().pid }, center: NotificationCenter(),
                             readMenu: { ($0.element as? String) == "Edit" ? edit : [] }, pressPath: { presses.paths.append(($0, $1)); return true })
        await menus.refresh().value
        let menu = try #require(menus.list.first { $0.label == "Edit" })
        #expect(await menus.items(of: menu) == edit)
        #expect(await menus.press(["Copy"], in: menu).value)
        #expect(presses.paths.count == 1 && presses.paths[0].0 == Self.textEdit && presses.paths[0].1 == ["Edit", "Copy"])
        #expect(fake.pressed.isEmpty, "the menu bar item itself was pressed: its menu opens at the screen's left edge")
        #expect(edit[1].isSeparator && !edit[0].isSeparator)
    }

    @Test("An app coming forward redraws the titles from its notification alone, no wait and no timer; stopped, it is not followed")
    func activation() async throws {
        let front = Front(), center = NotificationCenter()
        let menus = AppMenus(reader: Self.fake(), front: { front.pid }, center: center)
        menus.start()
        await menus.reading?.value
        #expect(menus.list.first?.label == "TextEdit")
        front.pid = Self.finder
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        let reading = try #require(menus.reading)
        await reading.value
        #expect(menus.list.map(\.label) == ["Finder", "File", "Edit", "View", "Go", "Window", "Help"])
        menus.stop()
        front.pid = Self.textEdit
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await menus.reading?.value
        #expect(menus.list.first?.label == "Finder")
    }

    @Test("An app that does not answer in time, or has no menu bar, shows no menus rather than the last app's")
    func timeout() async {
        let fake = Self.fake(), front = Front()
        let menus = AppMenus(reader: fake, front: { front.pid }, center: NotificationCenter())
        await menus.refresh().value
        fake.timesOut = [Self.finder]
        front.pid = Self.finder
        await menus.refresh().value
        #expect(menus.list.isEmpty)
    }

    @Test("Pilot in front: its own menus are never read through Accessibility, which ran AppKit's NSMenu off the main thread and crashed Pilot (Sven on build 23)")
    func ownMenus() async {
        let own = ProcessInfo.processInfo.processIdentifier, fake = Self.fake(), front = Front()
        fake.trees[own] = Self.menuBar(["Apple", "Pilot", "Edit", "Window"])
        let menus = AppMenus(reader: fake, front: { front.pid }, center: NotificationCenter())
        await menus.refresh().value
        #expect(menus.list.first?.label == "TextEdit")
        front.pid = own
        await menus.refresh().value
        #expect(menus.list.isEmpty, "Pilot's own menu bar was read: \(menus.list.map(\.label))")
    }

    @Test("App menus: off by default, top bar only, on the left after the focused app, and its reader runs no timer")
    func item() {
        let s = BarSettings.defaults
        #expect(!s.entry(.appMenus).on && s.entry(.appMenus).placement == .topBar)
        #expect(BarKind.appMenus.title == "App menus" && BarKind.appMenus.topBarOnly)
        var on = s
        on.set(.appMenus, on: true)
        #expect(on.slots(in: .topBar, topBarOn: true, side: .left).map(\.kinds).contains([.appMenus]))
        #expect(!on.shows(.appMenus, in: .menuBar, topBarOn: false))
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: SetupKeepAwakeTests.FakeSources()),
                                   appMenus: AppMenus(reader: Self.fake(), front: { nil }, center: NotificationCenter()),
                                   readBattery: { nil }, readWiFi: { nil }, watchStats: { _ in Task {} })
        readings.hold(.appMenus)
        defer { readings.release(.appMenus) }
        #expect(readings.liveTimers == 0)
        #expect(readings.appMenus.isFollowing)
    }
}
