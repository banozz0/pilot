import Foundation
import Testing
@testable import PilotCore

/// The menu's window and file providers (stories 76 and 77; SPEC.md, Menu; wireframe wo-nZ-ZEKkY sections 5 to 7):
/// pure, no GUI, no tiler and no file index.
@Suite("Menu search providers")
struct MenuSearchTests {
    static func window(_ id: Int, _ app: String, _ bundle: String, _ title: String, on workspace: String) -> AeroWindow {
        AeroWindow(id: id, appName: app, bundleId: bundle, pid: 1, workspace: workspace, monitorId: 1, layout: "h_tiles", title: title)
    }

    static let probe = window(41, "TextEdit", "com.apple.TextEdit", "probe", on: "4")
    static let apps = [MenuEntry(title: "TextEdit", target: .app("com.apple.TextEdit"), home: .apps),
                       MenuEntry(title: "Close window", target: .action("windows.close"))]

    @Test("A window row reads app, then title, with its workspace; Pilot's own windows are left out")
    func windowRows() {
        let rows = MenuEntries.windows([Self.probe, Self.window(7, "Zen", "app.zen-browser.zen", "", on: "2"),
                                        Self.window(9, "Pilot", "dev.banozz.pilot", "Pilot menu", on: "1")],
                                       excluding: "dev.banozz.pilot")
        #expect(rows.map(\.title) == ["TextEdit — probe", "Zen"])
        #expect(rows.map(\.detail) == ["workspace 4", "workspace 2"])
        #expect(rows.map(\.target) == [.window(41), .window(7)])
        #expect(rows.allSatisfy { $0.home == nil && $0.inSearch && $0.kind == .window })
    }

    @Test("A file row reads its name, its folder from home beside it and the day it was edited on the right")
    func fileRows() {
        let edited = DateComponents(calendar: .current, year: 2026, month: 9, day: 29).date!
        let rows = MenuEntries.files([("/Users/ada/code/dotfiles/keymap/keymap.toml", edited), ("/private/tmp/probe.txt", nil)],
                                     home: "/Users/ada")
        #expect(rows.map(\.title) == ["keymap.toml", "probe.txt"])
        #expect(rows[0].subtitle == "~/code/dotfiles/keymap")
        #expect(rows[0].detail == edited.formatted(.dateTime.day().month(.abbreviated)))
        #expect(rows[1].subtitle == "/private/tmp" && rows[1].detail == nil)
        #expect(rows[0].target == .file("/Users/ada/code/dotfiles/keymap/keymap.toml"))
        #expect(rows[0].kind == .file)
    }

    @Test("The file index is asked from the second typed character, the query trimmed and on one line")
    func fileQuery() {
        #expect(FileSearch.query(for: "p") == nil)
        #expect(FileSearch.query(for: " p ") == nil)
        #expect(FileSearch.query(for: " budget rep ") == "budget rep")
        #expect(FileSearch.query(for: "a\nb") == "a b")
    }

    @Test("The file index's answer becomes the menu's file rows; its ready line and a broken line are no answer")
    func fileAnswer() throws {
        let line = #"{"query":"keymap","files":[{"path":"/Users/ada/code/dotfiles/keymap/keymap.toml","modified":1759104000},"#
            + #"{"path":"/private/tmp/keymap.txt","modified":null}]}"#
        let answer = try #require(FileSearch.answer(line))
        #expect(answer.query == "keymap")
        #expect(answer.files.map(\.path) == ["/Users/ada/code/dotfiles/keymap/keymap.toml", "/private/tmp/keymap.txt"])
        #expect(answer.files.map(\.edited) == [Date(timeIntervalSince1970: 1_759_104_000), nil])
        let rows = MenuEntries.files(answer.files, home: "/Users/ada")
        #expect(rows.map(\.title) == ["keymap.toml", "keymap.txt"])
        #expect(rows.map(\.target) == [.file("/Users/ada/code/dotfiles/keymap/keymap.toml"), .file("/private/tmp/keymap.txt")])
        #expect(FileSearch.answer(#"{"query":"x(","files":[],"error":"Failed to parse query"}"#)?.files.isEmpty == true)
        #expect(FileSearch.answer(#"{"ready":true,"files":1013083,"walked":false,"ms":1164}"#) == nil)
        #expect(FileSearch.answer("not json") == nil)
    }

    @Test("Windows arrive after the menu opens and rank with the rest; files list only in the Files view")
    func provide() {
        var nav = MenuNavigator(entries: Self.apps)
        nav.query = "probe"
        #expect(nav.matched.isEmpty)
        nav.provide(.window, MenuEntries.windows([Self.probe], excluding: nil))
        nav.provide(.file, MenuEntries.files([("/Users/ada/scratch/probe-notes.md", nil)], home: "/Users/ada"))
        #expect(Set(nav.matched.map(\.kind)) == [.window])
        nav.query = "text"
        #expect(nav.matched.map(\.title) == ["TextEdit", "TextEdit — probe"])
        nav.provide(.file, [])
        nav.query = "probe"
        #expect(nav.matched.map(\.title) == ["TextEdit — probe"])
        #expect(nav.handle(.return) == .run(nav.rows[0]))
    }

    @Test("A late provider keeps the selected row selected")
    func keepsSelection() {
        var nav = MenuNavigator(entries: Self.apps)
        nav.query = "e"
        _ = nav.handle(.down)
        let picked = nav.selected
        nav.provide(.window, MenuEntries.windows([Self.window(3, "Notes", "com.apple.Notes", "e", on: "1")], excluding: nil))
        #expect(nav.selected == picked)
    }

    @Test("Windows and files are found only by typing at the root, never inside a branch")
    func rootOnly() {
        var nav = MenuNavigator(entries: Self.apps, branch: .apps)
        nav.provide(.window, MenuEntries.windows([Self.probe], excluding: nil))
        nav.query = "probe"
        #expect(nav.rows.isEmpty)
    }

    @Test("Tab narrows the root search in the wireframe's order: apps, windows, files, actions, then packages and every kind")
    func tab() {
        var nav = MenuNavigator(entries: Self.apps)
        nav.provide(.window, MenuEntries.windows([Self.probe], excluding: nil))
        nav.provide(.file, MenuEntries.files([("/Users/ada/text.md", nil)], home: "/Users/ada"))
        nav.query = "t"
        var seen: [MenuEntry.Kind?] = []
        for _ in 0..<6 { _ = nav.handle(.tab); seen.append(nav.only) }
        #expect(seen == [.app, .window, .file, .action, .package, nil])
    }

    @Test("⌘Return shows a file in Finder as it does an app; Return on a file or a window runs it")
    func fileKeys() {
        var nav = MenuNavigator(entries: [])
        nav.provide(.file, MenuEntries.files([("/Users/ada/probe.txt", nil)], home: "/Users/ada"))
        nav.query = "probe"
        nav.openFiles()
        #expect(nav.handle(.commandReturn) == .reveal(nav.rows[0]))
        #expect(nav.handle(.return) == .run(nav.rows[0]))
    }

    @Test("A window is focused by its id and is not a frecency pick; a file is one by its path")
    func commands() {
        #expect(AeroCommand.focusWindow(id: 41).arguments == ["focus", "--window-id", "41"])
        #expect(MenuEntry.Target.window(41).key == nil)
        #expect(MenuEntry.Target.file("/tmp/a b.txt").key == "file:/tmp/a b.txt")
    }
}
