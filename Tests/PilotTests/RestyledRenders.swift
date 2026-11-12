#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Offscreen renders of Workspaces (and its Tiling tab), Install (Catalogue and Web apps) and Defaults (card
/// agent-bo-95422897) for Moody beside the approved artifact 5sh21HWjCjsWYAwWKTibcE: the whole window in Tokyo Night and
/// Folio, on an engine in a moved home with app rules, floats, layouts and two snapshots seeded; Defaults
/// again with All kinds open. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter RestyledRenders`
extension SharedLook {
@MainActor
@Suite("Restyled renders")
struct RestyledRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Workspaces, Install and Defaults render in Tokyo Night and Folio", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("restyled")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        // Seeded in the moved home's defaults and files before the engine reads them; nothing reaches the tiler.
        var block = PilotBlock()
        block.rules = [.init(appId: "com.mitchellh.ghostty", workspace: "1"), .init(appId: "app.zen-browser.zen", workspace: "2"),
                       .init(appId: "md.obsidian", workspace: "3"), .init(appId: "com.spotify.client", workspace: "4")]
        block.floatApps = ["Finder", "System Settings"]
        block.floatTitles = ["Preferences"]
        block.gaps = .init(inner: 10, outer: 14)
        UserDefaults.standard.set(try JSONEncoder().encode(block), forKey: "pilotBlock")
        WorkspaceLayout.save(["1": .init(preset: .mainStack, auto: true), "2": .init(preset: .columns, auto: false)], to: .standard)
        let snapshots = """
        {"1": {"workspace": "1", "layout": "h_tiles", "savedAt": "\(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-7200)))",
               "windows": [{"bundleId": "com.mitchellh.ghostty", "appName": "Ghostty", "title": "zsh", "floating": false, "frame": [[0, 0], [700, 900]]}]},
         "3": {"workspace": "3", "layout": "h_tiles", "savedAt": "\(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-86400 * 3)))",
               "windows": [{"bundleId": "md.obsidian", "appName": "Obsidian", "title": "Vault", "floating": false, "frame": [[0, 0], [1400, 900]]}]}}
        """
        try FileManager.default.createDirectory(at: SnapshotStore.standard.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(snapshots.utf8).write(to: SnapshotStore.standard.url)

        let engine = Engine()
        try #require(engine.snapshots.saved.count == 2, "the seeded snapshots did not load")
        engine.observers.tiler.seed(focused: "2", occupied: [OccupiedWorkspace(name: "1", apps: ["Ghostty"]), OccupiedWorkspace(name: "2", apps: ["Zen"])])
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.restyled")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        let frame = try #require(window.contentView?.superview)
        let places = [AppPlace(.workspaces), AppPlace(.tiling), AppPlace(.install, .catalogue), AppPlace(.install, .webApps), AppPlace(.openWith), AppPlace(.configs)]
        for theme in ["tokyo-night", "folio"] {
            Look.shared.themeID = theme
            for place in places {
                model.go(place)
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                frame.layoutSubtreeIfNeeded()
                let name = place.section.map { "\(place.page.rawValue)-\($0.rawValue)" } ?? place.page.rawValue
                let png = try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:]))
                try png.write(to: dir.appendingPathComponent("\(theme)-\(name).png"))
            }
            // The catalogue on the shipped file (the test bundle has no app Resources): suggested, a category, a search.
            let entries = try InstallCatalogue.parse(Data(contentsOf: RestyledPagesTests.shipped))
            for (name, page) in [("suggested", CataloguePage(entries: entries)), ("category", CataloguePage(entries: entries, category: entries[0].category)),
                                 ("search", CataloguePage(entries: entries, query: "code"))] {
                try writeRender(page.frame(width: 900, height: 900).pilotTheme(look: .shared).background(Theme.background),
                                to: dir.appendingPathComponent("\(theme)-catalogue-\(name).png"))
            }
            // Open with's All kinds open, the page alone at the window's page width.
            let page = OpenWithPage(allKinds: true).environment(engine).frame(width: 900, height: 1100).pilotTheme(look: .shared).background(Theme.background)
            try writeRender(page, to: dir.appendingPathComponent("\(theme)-defaults-allkinds.png"))
        }
        Look.shared.themeID = PilotTheme.defaultID
        window.close()
    }

    /// Defaults as mockup D (card agent-bo-95422980) at the window widths 1440, 1000 and 760, in Tokyo Night: the whole window
    /// as it opens, then the page alone (beside the window's 206 pt sidebar and hairline) as it opens, with the mouse over
    /// AeroSpace, with Ghostty's preview open and filtered for "nvim". The configs are seeded in the moved home with the
    /// mockup's dates, eight in a dotfiles folder; defaults and the editor are fakes. Each PNG is trimmed below the page's
    /// last line.
    @Test("Defaults renders as mockup D at 1440, 1000 and 760", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderDefaults() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("defaults")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        try Self.seedConfigs(home: URL(fileURLWithPath: home))
        let began = Date.now

        let engine = Engine()
        let suite = "pilot.renders.defaults"
        UserDefaults().removePersistentDomain(forName: suite)
        let editor = EditorChoice(defaults: UserDefaults(suiteName: suite)!, installed: { _ in true }, handler: { _ in "com.microsoft.VSCode" })
        func kinds() -> DefaultAppsModel { DefaultAppsModel(system: RenderDefaultApps(), forget: { _ in }) }

        // PILOT_RENDER_ONLY narrows the renders to the file names holding it, for a quick look at one state.
        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map(name.contains) ?? true }
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.restyled")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        Look.shared.themeID = "tokyo-night"
        for width in [1440, 1000, 760] {
            // The whole window, tall enough for the whole page; trimmed under the page's end.
            let tall = CGFloat(width == 760 ? 3300 : 2700)
            if wanted("window-\(width)") {
                window.setContentSize(NSSize(width: CGFloat(width), height: tall))
                model.go(AppPlace(.configs))
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                frame.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(frame, scale: 2))
                try Self.writeTrimmed(rep, from: 207, to: dir.appendingPathComponent("window-\(width).png"))
            }

            // The seeded home, its ages counted from when the renders began.
            let seeded = URL(fileURLWithPath: home)
            for (state, start) in [("page", ConfigsList.Start(home: seeded, now: began)), ("hover", ConfigsList.Start(hovered: "aerospace", home: seeded, now: began)),
                                   ("preview", ConfigsList.Start(previewing: "ghostty", home: seeded, now: began)),
                                   ("empty", ConfigsList.Start(query: "nvim", home: seeded, now: began))]
                where wanted("page-\(width)-\(state)") {
                let page = ConfigsPage(editor: editor, configs: start).environment(engine)
                    .frame(width: CGFloat(width - 207), height: tall).pilotTheme(look: .shared).background(Theme.background)
                try Self.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("page-\(width)-\(state).png"))
            }
        }
        // All kinds folded out, at the least width and the widest, where the groups sit side by side.
        for width in [760, 1440] where wanted("page-\(width)-allkinds") {
            let page = OpenWithPage(allKinds: true, kinds: kinds(), editor: editor).environment(engine)
                .frame(width: CGFloat(width - 207), height: 4400).pilotTheme(look: .shared).background(Theme.background)
            try Self.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("page-\(width)-allkinds.png"))
        }
        Look.shared.themeID = PilotTheme.defaultID
    }

    /// Open with with All kinds folded out (Sven 2026-11-12, "open with isnt well aligned"): the page alone beside the
    /// window's sidebar at the first window width (1000) and a wide one (1440), in Instrument and Toybox, on fake defaults
    /// that pick QuickTime Player for video, the longest app name the cards show. Output: `open-with/<style>-<width>.png`.
    @Test("Open with renders with All kinds open in Instrument and Toybox", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderOpenWith() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("open-with")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let engine = Engine()
        let suite = "pilot.renders.open-with"
        UserDefaults().removePersistentDomain(forName: suite)
        let editor = EditorChoice(defaults: UserDefaults(suiteName: suite)!, installed: { _ in true }, handler: { _ in "com.microsoft.VSCode" })
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.themeID = "nightwatch"
        for style in [PilotStyle.instrument, .toybox] {
            look.style = style
            for width in [1000, 1440] {
                let page = OpenWithPage(allKinds: true, kinds: DefaultAppsModel(system: RenderDefaultApps(), forget: { _ in }), editor: editor)
                    .environment(engine).frame(width: CGFloat(width - 207), height: 2400).pilotTheme(look: look).background(Theme.background)
                try Self.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("\(style.rawValue)-\(width).png"))
            }
        }
    }

    /// `rep` cut 16 pt under the last row whose pixels right of `x` (in points) differ from the bottom row's: the page's end.
    /// A page that reaches the bottom was cut by the render's height, which fails.
    static func writeTrimmed(_ rep: NSBitmapImageRep, from x: Int, to url: URL) throws {
        let scale = rep.pixelsWide / max(1, Int(rep.size.width))
        let data = try #require(rep.bitmapData), row = rep.bytesPerRow, start = x * scale * rep.bitsPerPixel / 8, bottom = rep.pixelsHigh - 1
        let last = stride(from: bottom, through: 0, by: -1).first { memcmp(data + $0 * row + start, data + bottom * row + start, row - start) != 0 } ?? bottom
        try #require(last < bottom - 16 * scale, "the page is taller than the render: \(url.lastPathComponent)")
        let image = try #require(rep.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: last + 16 * scale)))
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }

    /// Mockup D's twelve configs in `home`, eight linked into ~/code/dotfiles, each dated as the mockup shows it; Ghostty's
    /// holds the mockup's lines at their line numbers. Any other known config is removed, so nine are not on this Mac.
    static func seedConfigs(home: URL) throws {
        let fm = FileManager.default
        for config in AppConfigs.known { for path in config.paths { try? fm.removeItem(at: home.appending(path: path)) } }
        try? fm.removeItem(at: home.appending(path: "code/dotfiles"))
        let calendar = Calendar.current, now = Date.now, year = calendar.component(.year, from: now)
        func day(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))! }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let filler = ["", "# Window", "window-padding-x = 12", "window-padding-y = 10", "window-decoration = auto", "macos-titlebar-style = hidden",
                      "", "# Keys", "keybind = cmd+t=new_tab", "keybind = cmd+w=close_surface", "copy-on-select = clipboard", "cursor-style = block",
                      "shell-integration = zsh", "", "mouse-hide-while-typing = true", "confirm-close-surface = false"]
        var ghostty = (0..<66).map { filler[$0 % filler.count] }
        for (n, line) in [(1, "# Shared by Ghostty.app and Ghostex — both load this file."), (23, "theme = Ayu Tokyo Night"),
                          (33, "font-family = Iosevka Nerd Font"), (34, "font-size = 13"), (36, "font-feature = calt"),
                          (44, "font-thicken = true"), (64, "background-opacity = 0.80")] { ghostty[n - 1] = line }
        ghostty[49] = "api-key = xxxx"
        let seeds: [(id: String, dotfiles: String?, changed: Date, text: String)] = [
            ("ghostty", "workstation/ghostty/config", yesterday, ghostty.joined(separator: "\n") + "\n"),
            ("zsh", "shell/zsh/zshrc", day(9, 21), "export EDITOR=code\n"), ("zshenv", "shell/zsh/zshenv", day(9, 15), "export LANG=en_GB.UTF-8\n"),
            ("fish", nil, yesterday, "set -g fish_greeting\n"),
            ("aerospace", "workstation/aerospace.toml", now.addingTimeInterval(-35 * 60), "start-at-login = true\n"),
            ("hammerspoon", "workstation/hammerspoon/init.lua", day(9, 6), "-- Hammerspoon\n"),
            ("karabiner", nil, day(9, 15), "{}\n"), ("skhd", "workstation/skhd/skhdrc", day(10, 4), "# skhd\n"),
            ("yabai", "workstation/yabai/yabairc", day(9, 24), "# yabai\n"), ("git", "git/gitconfig", day(9, 15), "[user]\n\tname = Alex\n"),
            ("lazygit", nil, day(8, 6), "gui:\n  theme: {}\n"), ("vscode", nil, day(10, 5), "{\n  \"editor.fontSize\": 13\n}\n"),
        ]
        for seed in seeds {
            let config = try #require(AppConfigs.known.first { $0.id == seed.id })
            let path = home.appending(path: config.paths[0])
            let real = seed.dotfiles.map { home.appending(path: "code/dotfiles/\($0)") } ?? path
            try fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(seed.text.utf8).write(to: real)
            try fm.setAttributes([.modificationDate: seed.changed], ofItemAtPath: real.path)
            if real != path {
                try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: path, withDestinationURL: real)
            }
        }
    }
}

/// Mockup D's defaults: web links in Google Chrome, plain text and Markdown in Visual Studio Code. Never LaunchServices.
@MainActor
private struct RenderDefaultApps: DefaultAppsSystem {
    func current(_ handler: DefaultHandler) -> String? {
        switch handler {
        case .url(let url): url.hasPrefix("mailto") ? "com.apple.mail" : "com.google.Chrome"
        case .contentType(let id):
            ["image", "png", "jpeg", "heic", "gif", "webp", "pdf"].contains(where: id.contains) ? "com.apple.Preview"
                : ["mpeg-4", "quicktime"].contains(where: id.contains) && !id.contains("audio") ? "com.apple.QuickTimePlayerX"
                : ["mp3", "audio", "flac"].contains(where: id.contains) ? "com.apple.Music"
                : id.contains("archive") ? "com.apple.archiveutility" : "com.microsoft.VSCode"
        }
    }
    func choices(_ handlers: [DefaultHandler]) -> [(name: String, bundle: String)] {
        [("Visual Studio Code", "com.microsoft.VSCode"), ("TextEdit", "com.apple.TextEdit"), ("Google Chrome", "com.google.Chrome"), ("Preview", "com.apple.Preview"),
         ("QuickTime Player", "com.apple.QuickTimePlayerX"), ("Music", "com.apple.Music"), ("Archive Utility", "com.apple.archiveutility"), ("Mail", "com.apple.mail")]
    }
    func name(_ bundle: String) -> String { bundle }
    func setDefault(_ bundle: String, for handler: DefaultHandler) async throws {}
}
}
#endif
