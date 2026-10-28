#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Toybox's menu (card agent-bo-95423182) beside mockup B's launcher (pilot-redesign-B/menu-dark.png, menu-light.png),
/// with its answer cards (menu Rail and Classic T13: a sum, a translation and a colour): each state drawn through
/// HUD.makePanel as Pilot shows it, in Toybox dark and Toybox light, at 2x on a plain
/// canvas. Opt-in like the other renders, in a moved home; the rows are the live builder's on sample apps, windows,
/// files and a package (nothing reaches the tiler, Homebrew or the file index):
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-toy PILOT_RENDER_DIR=/tmp/pilot-renders-toy swift test --filter ToyboxMenuRenders`
extension SharedLook {
@MainActor
@Suite("Toybox menu renders")
struct ToyboxMenuRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The menu's states in Toybox dark and light", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("menu")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        let look = Look.shared
        let (style, glass, theme) = (look.style, look.glass, look.themeID)
        look.glass = false
        defer { (look.style, look.glass, look.themeID) = (style, glass, theme) }

        for (name, nav) in try Self.states() {
            for (variant, pick, isDark) in [("toybox-dark", PilotStyle.toybox, true), ("toybox-light", .toybox, false)] {
                look.style = pick
                // Toybox Night and Toybox, so the light file is light.
                look.themeID = isDark ? "toybox-night" : "toybox"
                let model = MenuModel(nav: nav)
                model.ownKey = "Hyper+Space"
                try Self.write(MenuView(model: model), canvas: StyleTokens.of(.toybox, theme: look.theme).colors.canvas,
                               to: dir.appendingPathComponent("\(name)-\(variant).png"))
            }
        }
    }

    /// The menu's states: the root, a search with every kind and its Cmd+K actions, the Files view, System, Trigger,
    /// Apps, a picker and an empty branch.
    static func states() throws -> [(String, MenuNavigator)] {
        let engine = Engine()
        let built = MenuEntries.build(
            apps: [("Ghostty", "com.mitchellh.ghostty"), ("Finder", "com.apple.finder"), ("Terminal", "com.apple.Terminal"),
                   ("TextEdit", "com.apple.TextEdit"), ("Calculator", "com.apple.calculator"), ("Safari", "com.apple.Safari")],
            actions: engine.bindActions,
            store: BindStore(defaults: ["system.lock": Key("escape"), "system.darkMode": Key("d", shift: true), "apps.terminal": Key("return"),
                                        "captures.menu": Key("c", .ctrl), "apps.emoji": Key("e", .ctrl)]),
            roleApps: [:], menu: AppsModule.menuID, openID: AppsModule.openID(bundle:), running: ["com.mitchellh.ghostty", "com.apple.finder"],
            extras: [MenuLayout.system("Sound"): [BindsPage.ActionInfo(id: "system.output:73", label: "Play through AirPods", module: "system")]],
            switches: ["system.darkMode": true, "system.keepAwake": false, "system.idleLock": true, "system.nightShift": false, "system.wifi": true])
        var search = MenuNavigator(entries: built)
        search.query = "term"
        search.provide(.window, [
            MenuEntry(title: "Ghostty — ~/code/pilot", target: .window(1), detail: "Space 1", app: "com.mitchellh.ghostty", subtitle: "Workspace 1"),
            MenuEntry(title: "Terminal — zsh", target: .window(2), detail: "Space 3", app: "com.apple.Terminal", subtitle: "Workspace 3"),
        ])
        let home = NSHomeDirectory(), day = Date(timeIntervalSince1970: 1_791_028_800)
        search.provide(.file, MenuEntries.files([(home + "/code/terminal-cards", day), (home + "/notes/terminal-notes.md", day)], home: home))
        search.provide(.package, [MenuEntry(title: "Warp", target: .package("cask:warp"), detail: "cask · not installed")])
        var actions = search
        _ = actions.handle(.commandK)
        var files = search
        for _ in 0..<3 { _ = files.handle(.tab) }
        // T13's answers at the root, as MenuPanel provides them: the answer, then its Ask row.
        var translate = MenuNavigator(entries: built)
        translate.query = "tr buenos días"
        translate.provide(.answer, home: .translate, [AnswerCardRenders.translation])
        var trigger = MenuNavigator(entries: built, branch: .trigger)
        _ = trigger.handle(.down)
        var system = MenuNavigator(entries: built, branch: .system)
        _ = system.handle(.down)
        let picker = MenuNavigator(list: ["~/code/pilot", "~/code/agents", "~/code/dotfiles"].map { MenuEntry(title: $0, target: .action($0)) },
                                   title: "lazygit · pick a repo")
        return [("01-root", MenuNavigator(entries: built)), ("02-search", search), ("03-search-actions", actions), ("04-files", files),
                ("05-system", system), ("06-trigger", trigger), ("07-apps", MenuNavigator(entries: built, branch: .apps)),
                ("08-picker", picker), ("09-empty", MenuNavigator(entries: built, branch: .homebrew)),
                ("10-clean-waiting", MenuNavigator(entries: [], branch: .clean)), ("10-update-reading", MenuNavigator(entries: [], branch: .update)),
                ("10-remove-reading", MenuNavigator(entries: [], branch: .remove)), ("10-install-searching", MenuBrowseRenders.installSearching()),
                ("11-calculator", answer("22 km to mi", built)), ("11-translate", translate), ("11-colour", answer("#2bc4f0", built))]
    }

    /// A root search for `query` with its answer and Ask row, as MenuPanel.answer provides them.
    static func answer(_ query: String, _ built: [MenuEntry]) -> MenuNavigator {
        var nav = MenuNavigator(entries: built)
        nav.query = query
        nav.provide(.answer, RootAnswers.entries(for: query, now: Date(timeIntervalSince1970: 1_791_028_800)))
        return nav
    }

    /// `view` as HUD.makePanel builds it for the menu, at 2x on a plain canvas 48 pt round it.
    static func write(_ view: some View, canvas: Paint, to url: URL) throws {
        let panel = HUD.makePanel(view, surface: .menu)
        defer { panel.close() }
        let content = try #require(panel.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        content.layoutSubtreeIfNeeded()
        let rep = try #require(snapshot(content, scale: 2))
        let margin = 48, size = NSSize(width: rep.pixelsWide + 4 * margin, height: rep.pixelsHigh + 4 * margin)
        let out = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor(Color(canvas)).setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(x: 2 * margin, y: 2 * margin, width: rep.pixelsWide, height: rep.pixelsHigh), from: .zero, operation: .sourceOver,
                 fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try #require(out.representation(using: .png, properties: [:])).write(to: url)
    }
}
}
#endif
