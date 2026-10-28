#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Aliases (card agent-bo-95423037) for Sven and Moody. Defaults › Aliases alone at the page widths of a 1000 and a 760
/// window, Lagoon and Workshop: six aliases, the mouse over Ghostty, Ghostty open in the editor, Safari
/// refused Ghostty's alias, Finder asked for by the menu (new), the menu's ask on an empty list, and empty; then the
/// whole page as the menu opens it, 900 pt high over mockup D's configs, the asked editor brought into view. The menu with alias chips: a root
/// search for an alias (its row first and current, another aliased row at rest) and the root's quiet list with Install
/// current. Each book lives in a temporary folder, in a moved home. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter AliasesRenders`
extension SharedLook {
@MainActor
@Suite("Aliases renders")
struct AliasesRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let saved: [Alias] = [
        Alias(key: "action:apps.webApp", alias: "wa", title: "Make a web app"), Alias(key: "app:com.mitchellh.ghostty", alias: "gh", title: "Ghostty"),
        Alias(key: "app:com.apple.Safari", alias: "sf", title: "Safari"), Alias(key: "branch:install", alias: "in", title: "Install"),
        Alias(key: "package:cask:zed", alias: "z", title: "Zed"), Alias(key: "action:apps.clipboard", alias: "cb", title: "Clipboard history"),
    ]

    @Test("Defaults › Aliases and the menu's alias chips render in Lagoon and Workshop",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("aliases")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        Look.shared.glass = false
        // Mockup D's twelve configs, so the page runs past 900 pt and the asked editor must be brought into view.
        try RestyledRenders.seedConfigs(home: URL(fileURLWithPath: home))
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-render-aliases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func book(_ aliases: [Alias] = Self.saved) throws -> AliasBook {
            let book = AliasBook(store: AliasesStore(url: folder.appending(path: "\(UUID().uuidString)/aliases.json")))
            for alias in aliases { try #require(book.set(alias.alias, for: alias.key, title: alias.title) == nil) }
            return book
        }

        let ghostty = Self.saved[1], finder = Alias(key: "app:com.apple.finder", alias: "", title: "Finder")
        let states: [(name: String, start: AliasesList.Start, aliases: [Alias], asked: Alias?)] = [
            ("list", .init(), Self.saved, nil), ("hover", .init(hovered: ghostty.key), Self.saved, nil),
            ("edit", .init(editing: ghostty), Self.saved, nil),
            ("refused", .init(editing: Alias(key: "app:com.apple.Safari", alias: "gh", title: "Safari"), saved: true), Self.saved, nil),
            ("asked", .init(), Self.saved, finder), ("asked-first", .init(), [], finder), ("empty", .init(), [], nil),
        ]
        let only = Self.env["PILOT_RENDER_ONLY"]
        defer { Look.shared.themeID = PilotTheme.defaultID; Look.shared.glass = false }
        for theme in ["lagoon", "workshop"] {
            Look.shared.themeID = theme
            for width in [1000, 760] {
                for state in states {
                    let name = "\(theme)-\(width)-\(state.name)"
                    guard only.map(name.contains) ?? true else { continue }
                    // The page's own margins round the section, beside Instrument's sidebar and hairline.
                    let section = AliasesList(book: try book(state.aliases), asked: .constant(state.asked), start: state.start)
                        .padding(20).padding(.top, -14)
                        .frame(width: LookRenders.page(CGFloat(width)))
                        .pilotTheme(look: .shared).background(Theme.background)
                    try writeRender(section, to: dir.appendingPathComponent("\(name).png"))
                }
            }
            // The whole page as Set alias… opens it: 900 pt high, the asked editor scrolled into view.
            let page = "\(theme)-1000-page-asked"
            if only.map(page.contains) ?? true {
                let view = MenuPage(section: .aliases, editAlias: .constant(finder), aliases: try book())
                    .frame(width: LookRenders.page(1000), height: 900).pilotTheme(look: .shared).background(Theme.background)
                try writeRender(view, to: dir.appendingPathComponent("\(page).png"), wait: 1.2)
            }
            for (name, nav) in [("menu-search", Self.search()), ("menu-root", Self.root())] {
                let file = "\(theme)-\(name)"
                guard only.map(file.contains) ?? true else { continue }
                let png = try ClipboardTabsRenders.render(MenuView(model: MenuModel(nav: nav))).representation(using: .png, properties: [:])
                try #require(png).write(to: dir.appendingPathComponent("\(file).png"))
            }
        }
    }

    /// The aliases as the menu reads them.
    static let aliases = Aliases(saved + [Alias(key: "action:system.wallpaper", alias: "wp", title: "Wallpaper"),
                                          Alias(key: "branch:system", alias: "sys", title: "System")])

    /// "wa" typed at the root: Make a web app first by its alias and current, Wallpaper (aliased wp) at rest.
    static func search() -> MenuNavigator {
        let entries = [MenuEntry(title: "Make a web app", target: .action("apps.webApp"), home: .apps),
                       MenuEntry(title: "Wallpaper", target: .action("system.wallpaper"), home: .system),
                       MenuEntry(title: "Safari", target: .app("com.apple.Safari"), home: .apps)]
        var nav = MenuNavigator(entries: entries, aliases: aliases)
        nav.query = "wa"
        return nav
    }

    /// The root's quiet list with Install current: its chip on the selection, System's at rest.
    static func root() -> MenuNavigator {
        var nav = MenuNavigator(entries: [], aliases: aliases)
        for _ in 0..<12 where nav.selected?.target != .branch(.install) { _ = nav.handle(.down) }
        return nav
    }
}
}
#endif
