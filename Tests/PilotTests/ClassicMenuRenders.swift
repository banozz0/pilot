#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Hyper+Space menu as Classic draws it (menu Rail and Classic T8, frames D1–D8), Lagoon and Porcelain, through
/// HUD.makePanel as Pilot shows it: the root with Waiting, Tab at the empty root onto Windows, a search across kinds, the calculator, translation and colour cards, no match and Install. The sizes, the face and the cards are
/// checked always; the pictures are opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-rh PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter ClassicMenuRenders`
extension SharedLook {
@MainActor
@Suite("Classic menu renders")
struct ClassicMenuRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Classic is 750 wide (Q130); its root at most 650 tall, which fits the ten branches; lists at most 582")
    func sizes() throws {
        let states = try Dictionary(uniqueKeysWithValues: Self.states())
        let root = try #require(states["D1-root"])
        #expect(root.layout == .classic && root.atRoot)
        #expect(root.instrumentSize.width == MenuPanelSize.width)
        #expect(root.instrumentSize.height <= MenuPanelSize.classicTallest)
        // Unscrolled: the prompt line, the ten branches under their rule heading, no recents (Sven 2026-10-20), the status line.
        #expect(root.nav.rows.count == 10)
        let drawn = 58 + 12 + MenuPanelSize.classicRootHeading + 10 * MenuPanelSize.classicRow
            + MenuPanelSize.classicStatus
        #expect(drawn <= root.instrumentSize.height && drawn <= MenuPanelSize.classicTallest, "\(drawn) > \(root.instrumentSize.height)")
        for name in ["D2-tab-windows", "D3-search", "D4-calculator", "D5-translate", "D6-colour", "D7-no-match", "D8-install"] {
            let model = try #require(states[name])
            #expect(model.instrumentSize.width == MenuPanelSize.width, "\(name)")
            #expect(model.instrumentSize.height <= MenuPanelSize.s(540), "\(name)")
        }
        // Trigger keeps today's short list at the one width.
        let trigger = MenuModel(nav: MenuNavigator(entries: try RailMenuRenders.built(), branch: .trigger))
        #expect(trigger.shape == .narrow && trigger.instrumentSize.width == MenuPanelSize.width)
    }

    @Test("An answer draws its card in Classic too, with room for it unscrolled; the Ask row stays a row")
    func cards() throws {
        let states = try Dictionary(uniqueKeysWithValues: Self.states())
        for name in ["D4-calculator", "D5-translate", "D6-colour"] {
            let model = try #require(states[name])
            let rows = model.nav.rows
            try #require(rows.count >= 2, "\(name): \(rows.map(\.title))")
            #expect(model.answerCard(rows[0], at: 0) != nil, "\(name)")
            #expect(model.answerCard(rows[1], at: 1) == nil && rows[1].title == "Ask AI", "\(name)")
            let card: CGFloat = name == "D6-colour" ? 118 + 8 + 16 + 24 : 158
            let chrome = MenuPanelSize.classicChrome - 12
            #expect(chrome + MenuPanelSize.instrumentHeading + card + 10 + MenuPanelSize.classicWideRow + 12 <= model.instrumentSize.height, "\(name)")
        }
    }

    @Test("Every type role but the line icons is JetBrains Mono; keys read in capitals")
    func face() throws {
        let tokens = ClassicMenu.face(StyleTokens.unstyled.scaled(PilotStyle.scale))
        let roles: [KeyPath<StyleTypography, TypeRole>] = [\.body, \.strong, \.caption, \.small, \.title, \.pageTitle, \.display, \.mono,
                                                            \.eyebrow, \.key, \.search, \.row, \.keyName]
        for role in roles {
            guard case .bundled(let face) = tokens.type[keyPath: role].face else { Issue.record("a role is the system's"); continue }
            #expect(face.family == "JetBrains Mono")
        }
        #expect(tokens.type.search.size == 18 && tokens.type.row.size == 15)
        #expect(tokens.scale == PilotStyle.scale && tokens.colors == StyleTokens.unstyled.colors)
        #expect(ClassicRowCaps.caps("Hyper+Shift+N") == "HYPER + ⇧ + N")
        #expect(ClassicRowCaps.caps("Hyper+Return") == "HYPER + ↵")
    }

    @Test("Classic Shell (Q139): the status line names the mode and steps the kinds with Tab; its words and mode block read at 4.5:1")
    func status() throws {
        let states = try Dictionary(uniqueKeysWithValues: Self.states())
        let modes = ["D1-root": "GO", "D2-tab-windows": "WINDOWS", "D3-search": "SEARCH", "D8-install": "INSTALL", "trigger": "TRIGGER"]
        for (name, mode) in modes { #expect(ClassicStatus(model: try #require(states[name])).mode == mode, "\(name)") }
        let calculator = try #require(states["D4-calculator"])
        let card = try #require(calculator.answerCard(calculator.nav.rows[0], at: 0))
        #expect(ClassicStatus(model: calculator).mode == card.eyebrow.uppercased())
        let search = ClassicStatus(model: try #require(states["D3-search"])).hints
        #expect(search.first?.key == "Tab" && search.first?.label == "kind" && !search.contains { $0.key == "⇧Tab" }, "\(search)")
        #expect(ClassicStatus.sign("Tab") == "⇥" && ClassicStatus.sign("Esc") == "esc")
        for id in ["lagoon", "porcelain"] {
            let colors = StyleTokens.instrumentColors(try #require(PilotTheme.named(id)))
            #expect(Contrast.ratio(colors[keyPath: ClassicStatus.quiet(colors)].rgb, colors.sunken.rgb) >= 4.5, "\(id) quiet")
            #expect(Contrast.ratio(colors.text2.rgb, colors.sunken.rgb) >= 4.5, "\(id) text2")
            #expect(Contrast.ratio(colors.onAccent.rgb, colors.accent.rgb) >= 4.5, "\(id) mode block")
            #expect(Contrast.ratio(colors.accentText.rgb, colors.raised.rgb) >= 4.5, "\(id) key on the cursorline")
        }
    }

    @Test("Classic renders in Lagoon and Porcelain, frames D1–D8", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let (style, theme) = (look.style, look.themeID)
        defer { look.style = style; look.themeID = theme }
        look.style = .instrument
        let only = Self.env["PILOT_RENDER_ONLY"]
        for themeID in ["lagoon", "porcelain"] {
            look.themeID = themeID
            let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"]))
                .appendingPathComponent("menu-classic-\(themeID == "lagoon" ? "dark" : "light")")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, model) in try Self.states() where only.map(name.contains) ?? true {
                try InstrumentMenuRenders.render(MenuView(model: model), name, in: dir)
            }
        }
    }

    /// Every state, named for its frame on the design page.
    static func states() throws -> [(String, MenuModel)] {
        let windows = try AeroWindow.parse(InstrumentMenuRenders.windows)
        let built = try RailMenuRenders.built()
        let day = Date(timeIntervalSince1970: 1_791_028_800), home = NSHomeDirectory()
        func model(_ nav: MenuNavigator) -> MenuModel {
            let m = MenuModel(nav: nav)
            m.layout = .classic
            m.windows = windows
            m.ownKey = "Hyper+Space"
            m.waiting = MenuModel.waiting(updates: 3, clean: "2.1 GB")
            return m
        }
        func withWindows(_ nav: inout MenuNavigator) { nav.provide(.window, MenuEntries.windows(windows, excluding: nil)) }
        func answer(_ query: String) -> MenuNavigator {
            var nav = MenuNavigator(entries: built)
            nav.query = query
            nav.provide(.answer, RootAnswers.entries(for: query, now: day))
            return nav
        }
        var states: [(String, MenuModel)] = [("D1-root", model(MenuNavigator(entries: built)))]

        var tabWindows = MenuNavigator(entries: built)
        withWindows(&tabWindows)
        for _ in 0..<2 { _ = tabWindows.handle(.tab) }
        _ = tabWindows.handle(.down)
        states.append(("D2-tab-windows", model(tabWindows)))

        var search = MenuNavigator(entries: built)
        search.query = "ghost"
        withWindows(&search)
        search.provide(.package, [MenuEntry(title: "Ghostty", target: .package("cask:ghostty"), detail: "1.2.0 → 1.2.1", icon: .cask)])
        search.provide(.file, MenuEntries.files([(home + "/.config/ghostty/config", day),
                                                 (home + "/.claude/memory/ghostty-spawns-fullscreen.md", day)], home: home))
        states.append(("D3-search", model(search)))
        var searchActions = search
        _ = searchActions.handle(.commandK)
        states.append(("D3-search-actions", model(searchActions)))

        states.append(("D4-calculator", model(answer("22 km to mi"))))
        // At the root, as Sven types it (acceptance check 5) and MenuPanel.translate provides it.
        var translate = MenuNavigator(entries: built)
        translate.query = "tr buenos días"
        translate.provide(.answer, home: .translate, [AnswerCardRenders.translation])
        states.append(("D5-translate", model(translate)))
        states.append(("D6-colour", model(answer("#2bc4f0"))))

        var none = MenuNavigator(entries: built)
        none.query = "zzqxv"
        states.append(("D7-no-match", model(none)))
        states.append(("D8-install", model(MenuNavigator(entries: built, branch: .install))))
        states.append(("trigger", model(MenuNavigator(entries: built, branch: .trigger))))
        var power = MenuNavigator(entries: built, branch: MenuLayout.system("Power"))
        for _ in 0..<6 where power.selected?.target != .action("system.keepAwake") { _ = power.handle(.down) }
        states.append(("system-power", model(power)))
        return states
    }
}
}
#endif
