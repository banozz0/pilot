#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Home in the panel (pilot-ui-redesign T6, round 2's shots 7c-home and 7c-search), opt-in like the other renders: the
/// window at the panel's 780 by 560 in Tokyo Night and Porcelain, on Home at rest (the four switches and Jump back in),
/// on Home searching "border" (the grouped results with their values), Tools › Captures with the same words in its
/// field's drop (⌘F on any tab), and Tools › Captures after Return on "After a capture", its row ringed. Seeded in a moved home: the mockup's
/// workspaces and binds (fakes; nothing reaches the tiler or the clipboard), a schema on the render's own engine, and
/// two settings changed last. Its `engine()` and `seedPresets()` seed the other renders too.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter HomeRenders`
extension SharedLook {
@MainActor
@Suite("Home renders")
struct HomeRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// A clock the renders' timer reads.
    final class Clock: @unchecked Sendable { var now = Date() }

    /// The mockup's windows: Ghostex and Ghostty side by side on 1, Telegram and Zen on 2, Spotify on 4.
    static let windows = """
    [{"window-id": 1, "app-name": "Ghostex", "app-bundle-id": "com.madda.ghostex.gpui", "app-pid": 1, "workspace": "1", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "pilot · Home and Stats mockups"},
     {"window-id": 2, "app-name": "Ghostty", "app-bundle-id": "com.mitchellh.ghostty", "app-pid": 2, "workspace": "1", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "~/code/pilot"},
     {"window-id": 3, "app-name": "Telegram", "app-bundle-id": "com.tdesktop.Telegram", "app-pid": 3, "workspace": "2", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "Telegram"},
     {"window-id": 4, "app-name": "Zen", "app-bundle-id": "app.zen-browser.zen", "app-pid": 4, "workspace": "2", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "GitHub"},
     {"window-id": 5, "app-name": "Spotify", "app-bundle-id": "rocks.spotifast.Spotifast", "app-pid": 5, "workspace": "4", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "Spotify"}]
    """

    /// Ten windows across workspaces 1 to 4, Sven's apps, as the page renders seed the tiler (from the Toybox Home renders,
    /// gone with Home's blocks in pilot-ui-redesign T6).
    static let tenWindows: String = {
        let rows: [(String, String, String)] = [
            ("Ghostty", "com.mitchellh.ghostty", "1"), ("Ghostex", "com.madda.ghostex.gpui", "1"),
            ("Zen", "app.zen-browser.zen", "2"), ("Claude", "com.anthropic.claudefordesktop", "2"),
            ("Obsidian", "md.obsidian", "3"), ("Notes", "com.apple.Notes", "3"), ("Reminders", "com.apple.reminders", "3"),
            ("Telegram", "com.tdesktop.Telegram", "4"), ("Vesktop", "dev.vencord.vesktop", "4"), ("Spotify", "rocks.spotifast.Spotifast", "4"),
        ]
        return "[" + rows.enumerated().map { i, row in
            """
            {"window-id": \(i + 1), "app-name": "\(row.0)", "app-bundle-id": "\(row.1)", "app-pid": \(i + 1), "workspace": "\(row.2)", \
            "monitor-id": 1, "window-layout": "h_tiles", "window-title": "\(row.0)"}
            """
        }.joined(separator: ",") + "]"
    }()

    /// The engine with the mockup's binds, workspaces and presses.
    static func engine() throws -> Engine {
        let engine = Engine()
        // Only the tiler's answer is left to need you: the test process has no Accessibility grant, and another app may
        // hold secure input.
        engine.gate.seed(trusted: true)
        engine.secureInput.seed(active: false)
        // My binds is listed only for a file that already holds it (SH8), as Sven's does.
        try Data(#"{"version": 3, "preset": "myBinds", "binds": []}"#.utf8).write(to: engine.binds.fileURL)
        engine.binds.load()
        for (bundle, key) in [("com.tdesktop.Telegram", "t"), ("app.zen-browser.zen", "b"), ("com.madda.ghostex.gpui", "g"),
                              ("cc.ffitch.shottr", "i"), ("dev.empryo.desktop", "z"), ("rocks.spotifast.Spotifast", "m")] {
            engine.binds.replace(AppsModule.openID(bundle: bundle), with: Key(key))
        }
        let windows = try AeroWindow.parse(Self.windows)
        engine.observers.tiler.seed(focused: "1", occupied: OccupiedWorkspace.list(windows), windows: windows)
        // Today: the mockup's busiest binds, pressed between 8 and 11.
        var today = TodayPresses()
        let midnight = Calendar.current.startOfDay(for: .now)
        let counts: [(String, Int)] = [("apps.terminal", 38), (AppsModule.openID(bundle: "app.zen-browser.zen"), 31), ("captures.area", 22),
                                       ("workspaces.go:1", 19), ("windows.close", 14), ("apps.clipboard", 8), ("windows.focusNext", 7),
                                       ("apps.launcher", 5)]
        let hours = [8, 9, 9, 9, 10, 10, 10, 10, 11, 11]
        var n = 0
        for (action, count) in counts {
            for _ in 0..<count {
                today.count(action, at: midnight.addingTimeInterval(Double(hours[n % hours.count]) * 3600 + Double(n % 50) * 60))
                n += 1
            }
        }
        engine.seedToday(today)
        return engine
    }

    /// The mockup's workspace names, in the moved home before the engine reads them.
    static func seedPresets() throws {
        var contents = WorkspacePresetStore.Contents()
        let app = { (bundle: String, name: String) in WorkspacePreset.App(bundleId: bundle, name: name, percent: 50) }
        contents.assign(WorkspacePreset(name: "Work", apps: [app("com.madda.ghostex.gpui", "Ghostex"), app("com.mitchellh.ghostty", "Ghostty")], layout: .scrolling), to: "1")
        contents.assign(WorkspacePreset(name: "Chat", apps: [app("com.tdesktop.Telegram", "Telegram"), app("app.zen-browser.zen", "Zen")], layout: .mainStack), to: "2")
        contents.assign(WorkspacePreset(name: "Music", apps: [app("rocks.spotifast.Spotifast", "Spotify")], layout: nil), to: "4")
        try FileManager.default.createDirectory(at: WorkspacePresetStore.standard.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspacePresetStore.standard.save(contents)
    }

    static let looks: [(name: String, theme: String)] = [("dark", "tokyo-night"), ("light", "porcelain")]

    /// The settings the render's Jump back in lists, newest first.
    static let recent = ["capture.afterCapture", "look.windowBorder"]

    /// The settings on the render's own engine, the stores in the moved home: Look, Captures and part 2 (Tiling's border
    /// among them), as the app's live schema registers them.
    static func schema(_ engine: Engine) -> SettingsSchema {
        let schema = SettingsSchema()
        schema.registerLook(.shared)
        schema.registerCaptures(.shared)
        schema.registerPart2(settings: engine.settings, list: engine.workspaceList, block: engine.pilotBlock, bar: .shared,
                             topBar: engine.topBar, wallpaper: .shared, pilotSwitch: engine.pilotSwitch,
                             notesIn: { _ in 0 }, changeNotes: { _ in })
        return schema
    }

    @Test("Home renders as shots 7c-home and 7c-search at 780 by 560, in Tokyo Night and Porcelain", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("home")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }
        try Self.seedPresets()
        try #require(WorkspacePresetStore.standard.url.path.hasPrefix(home), "the presets would land outside the moved home")

        let engine = try Self.engine()
        let schema = Self.schema(engine)
        var sources = HomeSources()
        // The shots' evening.
        let evening = Calendar.current.date(bySettingHour: 19, minute: 42, second: 0, of: .now) ?? .now
        sources.now = { _ in evening }
        sources.schema = { schema }
        sources.recent = { Self.recent }

        let look = Look.shared
        defer { look.themeID = PilotTheme.defaultID; look.style = .instrument }
        look.style = .instrument
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.home")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model)
            .environment(engine).environment(\.homeSources, sources)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        window.setContentSize(AppWindowController.size)
        func shot(_ file: String, _ place: AppPlace = AppPlace(.home), query: String = "") throws {
            model.go(place)
            model.query = query
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
        }
        for (name, theme) in Self.looks {
            look.themeID = theme
            AppWindowController.applyLook(look, to: window)
            try shot("\(name)-home")
            try shot("\(name)-home-searching-border", query: "border")
            // ⌘F on another tab: the same results in the drop under its field.
            try shot("\(name)-captures-searching-border", AppPlace(.captures), query: "border")
            // Return on "After a capture": Tools › Captures, its row rung for 2 s (shot within the first second).
            let hit = try #require(SearchHits("after capture", engine: engine, schema: schema).rows.first { $0.id == "setting:capture.afterCapture" })
            model.open(hit)
            try #require(model.page == .captures && model.ringed == "capture.afterCapture")
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            try #require(model.ringed == "capture.afterCapture", "the ring went before the shot")
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name)-captures-ringed.png"))
        }
        model.query = ""
    }
}
}
#endif
