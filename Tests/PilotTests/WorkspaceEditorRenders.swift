#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The workspace editor as mockup E (card agent-bo-95422980), inline on the Workspaces page, in the window at 1440 × 900,
/// the panel's 780 × 560 and the mockup's own 990 × 940, in Tokyo Night: the page on workspace 4, the strip, in its card
/// and inline, and on 5, the empty main + stack. Its popup over the window went with Home's board (pilot-ui-redesign T6).
/// Presets and layouts are seeded in a moved home; the picker's apps are fakes (icons are the Mac's own, read only).
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter WorkspaceEditorRenders`
extension SharedLook {
@MainActor
@Suite("Workspace editor renders")
struct WorkspaceEditorRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// The picker's apps: mockup E's, installed apps by name, then two web apps with their sites.
    static let apps: [WorkspaceEditor.AppChoice] = [
        .init(name: "Ghostty", bundle: "com.mitchellh.ghostty"), .init(name: "Google Chrome", bundle: "com.google.Chrome"),
        .init(name: "Obsidian", bundle: "md.obsidian"), .init(name: "Telegram", bundle: "com.tdesktop.Telegram"),
        .init(name: "Vesktop", bundle: "dev.vencord.vesktop"), .init(name: "Visual Studio Code", bundle: "com.microsoft.VSCode"),
        .init(name: "WhatsApp", bundle: "net.whatsapp.WhatsApp"), .init(name: "Zen", bundle: "app.zen-browser.zen"),
        .init(name: "Spotify", bundle: "rocks.spotifast.Spotifast", host: "open.spotify.com"), .init(name: "X", bundle: "com.pilot.webapp.x-com", host: "x.com"),
    ]

    static func app(_ name: String, percent: Int = 0, atLogin: Bool = false) -> WorkspacePreset.App {
        let choice = apps.first { $0.name == name }!
        var app = WorkspacePreset.App(bundleId: choice.bundle, name: name, percent: percent)
        app.atLogin = atLogin
        return app
    }

    @Test("The workspace editor renders inline on the Workspaces page as mockup E", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's presets")
        try #require(WorkspacePresetStore.standard.url.path.hasPrefix(home), "the presets file is not in the moved home")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("workspace-editor")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        // Workspace 1 "Work": main + stack, Ghostty and Telegram at login; 2 "Write": own sizes 55 / 45; 3 none; 4 "Read":
        // scrolling, four apps so one peeks in; "Chat" saved.
        var contents = WorkspacePresetStore.Contents()
        contents.assign(WorkspacePreset(name: "Work", apps: [Self.app("Ghostty", percent: 34, atLogin: true), Self.app("Zen", percent: 33),
                                                             Self.app("Telegram", percent: 33, atLogin: true)], layout: .mainStack), to: "1")
        contents.assign(WorkspacePreset(name: "Write", apps: [Self.app("Ghostty", percent: 55, atLogin: true), Self.app("Zen", percent: 45)], layout: nil), to: "2")
        contents.assign(WorkspacePreset(name: "Read", apps: [Self.app("Zen", percent: 25), Self.app("Obsidian", percent: 25),
                                                             Self.app("Visual Studio Code", percent: 25), Self.app("Ghostty", percent: 25)],
                                        layout: .scrolling), to: "4")
        contents.presets["Chat"] = WorkspacePreset(name: "Chat", apps: [Self.app("Telegram", percent: 50), Self.app("WhatsApp", percent: 50)], layout: .scrolling)
        // 5: main + stack with nothing in it, Sven's 2026-10-30 screenshot; 6: main + stack with one app. Both draw the
        // layout's empty spots.
        contents.assign(WorkspacePreset(name: "Solo", apps: [Self.app("Ghostty", percent: 100)], layout: .mainStack), to: "6")
        try WorkspacePresetStore.standard.save(contents)
        WorkspaceLayout.save(["1": .init(preset: .mainStack, auto: true), "2": .init(preset: nil, auto: false), "4": .init(preset: .scrolling, auto: true),
                              "5": .init(preset: .mainStack, auto: true), "6": .init(preset: .mainStack, auto: true)],
                             to: .standard)

        let engine = Engine()
        try #require(engine.presets.contents == contents, "the seeded presets did not load")
        let occupied = [OccupiedWorkspace(name: "1", apps: ["Ghostty", "Zen", "Telegram"]), OccupiedWorkspace(name: "2", apps: ["Ghostty", "Zen"])]
        engine.observers.tiler.seed(focused: "1", occupied: occupied)
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.workspace-editor")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)

        // PILOT_RENDER_ONLY narrows the renders to the file names holding it.
        let only = Self.env["PILOT_RENDER_ONLY"]
        Look.shared.themeID = "tokyo-night"
        model.go(AppPlace(.workspaces))
        for size in [CGSize(width: 1440, height: 900), AppWindowController.size, CGSize(width: 990, height: 940)] {
            window.setContentSize(size)
            // The page itself with workspace 4 on screen: its card's small screen and the editor inline draw the strip,
            // the Scrolling block under it; with 5 on screen the empty main + stack, and no Scrolling block.
            for (focused, suffix) in [("4", ""), ("5", "-mainstack")] {
            let page = "\(Int(size.width))-page\(suffix)"
            if only.map(page.contains) ?? true {
                engine.observers.tiler.seed(focused: focused, occupied: occupied)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                frame.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(frame, scale: 2))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("window-\(page).png"))
                engine.observers.tiler.seed(focused: "1", occupied: occupied)
            }
            }
        }
        Look.shared.themeID = PilotTheme.defaultID
    }
}
}
#endif
