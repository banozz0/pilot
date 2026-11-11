#if DEBUG
import AppKit
@testable import Clipboard
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Toybox's window frame and Home beside mockup B (card agent-bo-95423182; home-dark.png, home-light.png, binds-dark.png),
/// opt-in like the other renders: the whole window at 1440 by 900 on Home in Toybox dark and light, at 1000 and 760 dark
/// (900 high, then tall enough for the whole page), on Binds (the rail) dark and light, on Look, and Home with the tiler
/// stopped (the nudge).
/// Seeded in a moved home as HomeRenders does, with the mockup's four workspaces (Zen and Claude on 2, focused) and three
/// copies (fakes; nothing reaches the tiler or the clipboard).
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter ToyboxHomeRenders`
extension SharedLook {
@MainActor
@Suite("Toybox Home renders")
struct ToyboxHomeRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// The mockup's workspaces: Ghostty and Ghostex on 1, Zen and Claude on 2, Obsidian, Notes and Reminders on 3,
    /// Telegram, Vesktop and Spotify on 4.
    static let windows: String = {
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

    @Test("Toybox's frame and Home render beside mockup B", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("toybox-home")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let engine = try SharedLook.HomeRenders.engine()
        let windows = try AeroWindow.parse(Self.windows)
        engine.observers.tiler.seed(focused: "2", occupied: OccupiedWorkspace.list(windows), windows: windows)
        SharedLook.StatsRenders.seed(SystemSampler.shared)
        var sources = HomeSources()
        sources.lastCopied = { HomeCopy(text: "pilot://open?page=binds", at: Date().addingTimeInterval(-125), count: 214) }
        sources.recentCopies = {
            [StoredClip(id: 1, kind: .link, text: "pilot://open?page=binds", sourceApp: "com.mitchellh.ghostty", copiedAt: Date().addingTimeInterval(-125), pinned: false),
             StoredClip(id: 2, kind: .colour, text: "#FFC933", sourceApp: "app.zen-browser.zen", copiedAt: Date().addingTimeInterval(-9 * 60), pinned: false),
             StoredClip(id: 3, kind: .image, text: "", sourceApp: "cc.ffitch.shottr", copiedAt: Date().addingTimeInterval(-14 * 60), pinned: false)]
        }
        sources.pages = { [] }

        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map(name.contains) ?? true }

        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model)
            .environment(engine).environment(\.homeSources, sources)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        look.themeID = "tokyo-night"
        defer { look.themeID = PilotTheme.defaultID; look.style = .instrument }

        func shot(_ name: String, style: PilotStyle, dark: Bool = true, page: AppPage = .home, width: Int = 1440, height: Int = 900) throws {
            guard wanted(name) else { return }
            look.style = style
            window.setContentSize(NSSize(width: CGFloat(width), height: CGFloat(height)))
            model.go(AppPlace(page))
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }

        try shot("window-toybox-dark-1440-home", style: .toybox)
        try shot("window-toybox-light-1440-home", style: .toybox, dark: false)
        try shot("window-toybox-dark-1440-home-whole", style: .toybox, height: 1900)
        try shot("window-toybox-dark-1000-home", style: .toybox, width: 1000)
        try shot("window-toybox-dark-1000-home-whole", style: .toybox, width: 1000, height: 1500)
        try shot("window-toybox-dark-760-home", style: .toybox, width: 760)
        try shot("window-toybox-dark-760-home-whole", style: .toybox, width: 760, height: 1500)
        try shot("window-toybox-dark-1440-binds", style: .toybox, page: .binds)
        try shot("window-toybox-light-1440-binds", style: .toybox, dark: false, page: .binds)
        try shot("window-toybox-dark-1440-look", style: .toybox, page: .look)

        // The tiler stopped: the one nudge, and the workspaces say so.
        engine.observers.tiler.seed(focused: nil, occupied: [], windows: [])
        try shot("window-toybox-dark-1440-home-needs-you", style: .toybox)
        try shot("window-toybox-light-1000-home-needs-you", style: .toybox, dark: false, width: 1000)
    }
}
}
#endif
