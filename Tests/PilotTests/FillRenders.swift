#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Workspaces, Binds and Home's editor popup in the whole window (card agent-bo-95423003, Sven 2026-10-07: "half the
/// screen is empty"): at 1440, 1000 and 760 wide, each 4:3 as Sven's 1600 × 1200 window, plus that window itself, in
/// Tokyo Night. Presets, rules, layouts and a snapshot are seeded in a moved home; nothing reaches the tiler.
/// The Binds board reads the Mac's keyboard layout (read only). Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter FillRenders`
extension SharedLook {
@MainActor
@Suite("Fill renders")
struct FillRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static func app(_ name: String, _ bundle: String, percent: Int = 0, atLogin: Bool = false) -> WorkspacePreset.App {
        var app = WorkspacePreset.App(bundleId: bundle, name: name, percent: percent)
        app.atLogin = atLogin
        return app
    }

    @Test("Workspaces, Binds and Home's popup fill the window at 1440, 1000, 760 and 1600", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move (\(NSHomeDirectory())); refusing to touch Sven's presets")
        try #require(WorkspacePresetStore.standard.url.path.hasPrefix(home), "the presets file is not in the moved home")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent(Self.env["PILOT_RENDER_TAG"] ?? "fill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        var block = PilotBlock()
        block.rules = [.init(appId: "com.mitchellh.ghostty", workspace: "1"), .init(appId: "app.zen-browser.zen", workspace: "2")]
        UserDefaults.standard.set(try JSONEncoder().encode(block), forKey: "pilotBlock")
        var contents = WorkspacePresetStore.Contents()
        contents.assign(WorkspacePreset(name: "Work", apps: [Self.app("Ghostty", "com.mitchellh.ghostty", percent: 34, atLogin: true),
                                                             Self.app("Zen", "app.zen-browser.zen", percent: 33),
                                                             Self.app("Telegram", "com.tdesktop.Telegram", percent: 33, atLogin: true)], layout: .mainStack), to: "1")
        contents.assign(WorkspacePreset(name: "Chat", apps: [Self.app("Blip", "net.blip.macos", percent: 34), Self.app("Cardinal X", "com.madda.cardinalx", percent: 33),
                                                             Self.app("ChatGPT", "com.openai.codex", percent: 33)], layout: .grid), to: "2")
        contents.assign(WorkspacePreset(name: "Notes", apps: [Self.app("Obsidian", "md.obsidian", percent: 60), Self.app("Zen", "app.zen-browser.zen", percent: 40)],
                                        layout: nil), to: "4")
        try WorkspacePresetStore.standard.save(contents)
        WorkspaceLayout.save(["1": .init(preset: .mainStack, auto: true), "2": .init(preset: .grid, auto: false), "4": .init(preset: nil, auto: false)], to: .standard)
        let snapshots = """
        {"1": {"workspace": "1", "layout": "h_tiles", "savedAt": "\(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-7200)))",
               "windows": [{"bundleId": "com.mitchellh.ghostty", "appName": "Ghostty", "title": "zsh", "floating": false, "frame": [[0, 0], [700, 900]]}]}}
        """
        try FileManager.default.createDirectory(at: SnapshotStore.standard.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(snapshots.utf8).write(to: SnapshotStore.standard.url)

        let engine = Engine()
        engine.observers.tiler.seed(focused: "1", occupied: [OccupiedWorkspace(name: "1", apps: ["Ghostty", "Zen", "Telegram"]),
                                                                 OccupiedWorkspace(name: "2", apps: ["Blip", "ChatGPT"])])
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.fill")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)

        let only = Self.env["PILOT_RENDER_ONLY"]
        Look.shared.themeID = "tokyo-night"
        let sizes = [CGSize(width: 1440, height: 1080), CGSize(width: 1000, height: 750), CGSize(width: 760, height: 570), CGSize(width: 1600, height: 1200)]
        for size in sizes {
            window.setContentSize(size)
            for (page, place) in [("workspaces", AppPlace(.workspaces)), ("binds", AppPlace(.binds))] {
                let name = "\(page)-\(Int(size.width))"
                guard only.map(name.contains) ?? true else { continue }
                model.editingWorkspace = nil
                model.go(place)
                RunLoop.main.run(until: Date().addingTimeInterval(0.9))
                frame.layoutSubtreeIfNeeded()
                let png = try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:]))
                try png.write(to: dir.appendingPathComponent("\(name).png"))
            }
            // Home's popup on workspace 2 with the mouse over a placed app: its Replace and Remove.
            let name = "home-popup-\(Int(size.width))"
            if only.map(name.contains) ?? true {
                model.go(AppPlace(.home))
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                model.editingWorkspace = EditedWorkspace(name: "2", start: .init(hovered: 2, apps: []))
                RunLoop.main.run(until: Date().addingTimeInterval(0.9))
                frame.layoutSubtreeIfNeeded()
                let png = try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:]))
                try png.write(to: dir.appendingPathComponent("\(name).png"))
                model.editingWorkspace = nil
            }
        }
        Look.shared.themeID = PilotTheme.defaultID
    }
}
}
#endif
