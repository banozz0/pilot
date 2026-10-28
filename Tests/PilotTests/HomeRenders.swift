#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Home as direction B of the approved mockup vg74ARspzoo (card agent-bo-95422992), opt-in like the other renders: the
/// whole window at 1440, 1000 and 760 in Lagoon, then the page alone in its four states (Working, Key
/// clicked on Hyper+B, Hyper off, Needs you with the tiler stopped) at 1440, Key clicked and Hyper off at 1000 and 760
/// too. Seeded in a moved home: the mockup's workspaces with their names and windows, binds with the mockup's apps on T,
/// B, G, I, Z and M, today's presses, Stats' readings and a last copy (fakes; nothing reaches the tiler or the
/// clipboard). Hyper off is the engine's own session switch turned off around those
/// renders; the test never starts the tap it would reach.
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-992b PILOT_RENDER_DIR=/tmp/pilot-renders-992b swift test --filter HomeRenders`
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
        contents.assign(WorkspacePreset(name: "Work", apps: [app("com.madda.ghostex.gpui", "Ghostex"), app("com.mitchellh.ghostty", "Ghostty")], layout: .columns), to: "1")
        contents.assign(WorkspacePreset(name: "Chat", apps: [app("com.tdesktop.Telegram", "Telegram"), app("app.zen-browser.zen", "Zen")], layout: .mainStack), to: "2")
        contents.assign(WorkspacePreset(name: "Music", apps: [app("rocks.spotifast.Spotifast", "Spotify")], layout: nil), to: "4")
        try FileManager.default.createDirectory(at: WorkspacePresetStore.standard.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspacePresetStore.standard.save(contents)
    }

    @Test("Home renders as mockup B at 1440, 1000 and 760, in its four states", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
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
        SharedLook.StatsRenders.seed(SystemSampler.shared)
        SharedLook.StatsRenders.pickMockup(BarItemsStore.shared)
        let suite = testSuite()
        var sources = HomeSources()
        sources.lastCopied = { HomeCopy(text: "bd show agent-bo-95422987", at: Date().addingTimeInterval(-125), count: 48) }
        sources.pages = { [] }

        // PILOT_RENDER_ONLY narrows the renders to the file names holding it.
        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map(name.contains) ?? true }

        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.home")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model)
            .environment(engine).environment(\.homeSources, sources)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        Look.shared.themeID = "lagoon"
        defer { Look.shared.themeID = PilotTheme.defaultID }
        for width in [1440, 1000, 760] where wanted("window-\(width)") {
            window.setContentSize(NSSize(width: CGFloat(width), height: width == 760 ? 3200 : 2200))
            model.go(AppPlace(.home))
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            try RestyledRenders.writeTrimmed(try #require(snapshot(frame, scale: 2)), from: 207,
                                             to: dir.appendingPathComponent("window-\(width).png"))
        }

        // The page alone at the window's page width (right of the window's 207 pt sidebar), in each state.
        let b = try #require(KeyNames.code(for: "B"))
        func page(_ state: String, _ engine: Engine, width: Int, picked: Int64? = nil) throws {
            guard wanted("page-\(width)-\(state)") else { return }
            let view = HomePage(onScreen: false, start: .init(picked: picked)) { _ in }
                .environment(engine).environment(\.homeSources, sources)
                .frame(width: CGFloat(width - 207), height: width == 760 ? 3200 : 2200).pilotTheme(look: .shared).background(Theme.background)
            try RestyledRenders.writeTrimmed(rendered(view, wait: 0.9), from: 0,
                                             to: dir.appendingPathComponent("page-\(width)-\(state).png"))
        }
        try page("1-working", engine, width: 1440)
        try page("2-key-clicked", engine, width: 1440, picked: b)
        try page("2-key-clicked", engine, width: 1000, picked: b)
        try page("2-key-clicked", engine, width: 760, picked: b)
        engine.hyperSwitch.toggle()
        try #require(!engine.hyperSwitch.isOn)
        for width in [1440, 1000, 760] { try page("3-hyper-off", engine, width: width) }
        engine.hyperSwitch.toggle()
        engine.observers.tiler.seed(focused: nil, occupied: [], windows: [])
        try page("4-needs-you", engine, width: 1440)
    }
}
}
#endif
