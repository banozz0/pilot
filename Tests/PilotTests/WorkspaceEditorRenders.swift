#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The workspace editor popup as mockup E (card agent-bo-95422980) over the Workspaces page, in the whole window at
/// 1440 × 900, the window as it opens (1000 × 660), at its least (760 × 520) and the mockup's own 990 × 940, in Tokyo Night:
/// three apps with the mouse over the main one, the picker open on the dashed spot with "s" typed, own
/// sizes, a new workspace, scrolling's strip with the mouse on a column peeking in, the picker open on a placed app to swap it,
/// and at the least window the popup scrolled to its rules. Each state opens a fresh popup, and each is also cropped to
/// the popup, as the mockup frames it. At the window as it opens every state fits whole: nothing scrolls, so the rules
/// and the footer show. Then the page itself on workspace 4, the strip, in its card and inline.
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

    /// The rows, in points, of the popup's ground running up and down column `x` (points) from the window's middle, over
    /// the 1 pt rules across it: the popup's top to its bottom.
    static func groundRows(_ rep: NSBitmapImageRep, x: Int) throws -> Range<Int> {
        let ground = try #require(NSColor(Theme.background).usingColorSpace(.deviceRGB))
        func isGround(_ y: Int) -> Bool {
            guard y >= 0, y < rep.pixelsHigh, let c = rep.colorAt(x: x * 2, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return abs(c.redComponent - ground.redComponent) < 0.015 && abs(c.greenComponent - ground.greenComponent) < 0.015
                && abs(c.blueComponent - ground.blueComponent) < 0.015
        }
        let middle = rep.pixelsHigh / 2
        try #require(isGround(middle), "the popup's ground is not at the window's middle")
        /// The last ground pixel going `step` from the middle, stepping over up to 4 px that are not.
        func end(_ step: Int) -> Int {
            var last = middle, y = middle
            while abs(y - last) <= 4 { y += step; if isGround(y) { last = y } }
            return last
        }
        return end(-1) / 2..<end(1) / 2 + 1
    }

    static func app(_ name: String, percent: Int = 0, atLogin: Bool = false) -> WorkspacePreset.App {
        let choice = apps.first { $0.name == name }!
        var app = WorkspacePreset.App(bundleId: choice.bundle, name: name, percent: percent)
        app.atLogin = atLogin
        return app
    }

    @Test("The workspace editor popup renders as mockup E at 1440, 1000 and 760, whole at 1000 × 660", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
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
        contents.presets["Chat"] = WorkspacePreset(name: "Chat", apps: [Self.app("Telegram", percent: 50), Self.app("WhatsApp", percent: 50)], layout: .columns)
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

        typealias Start = WorkspaceEditor.Start
        let states: [(name: String, workspace: String, start: Start)] = [
            ("filled", "1", Start(hovered: 0, apps: Self.apps)),
            ("picker", "1", Start(picking: .open(0), query: "s", pickerHover: 1, apps: Self.apps)),
            ("custom", "2", Start(apps: Self.apps)),
            ("empty", "3", Start(apps: Self.apps)),
            // Scrolling's strip with the mouse on the fourth column, which peeks in at the right edge.
            ("scrolling", "4", Start(hovered: 3, apps: Self.apps)),
            ("swap", "1", Start(picking: .app(1), apps: Self.apps)),
            ("rules", "2", Start(apps: Self.apps, scrolled: true)),
            // A picked layout's shape before it is full: main + stack empty, with one app, and the picker on its last spot.
            ("slots", "5", Start(apps: Self.apps)),
            ("slots-one", "6", Start(apps: Self.apps)),
            ("slots-picker", "6", Start(picking: .open(1), apps: Self.apps)),
        ]
        // PILOT_RENDER_ONLY narrows the renders to the file names holding it.
        let only = Self.env["PILOT_RENDER_ONLY"]
        Look.shared.themeID = "tokyo-night"
        for size in [CGSize(width: 1440, height: 900), AppWindowController.size, AppWindowController.minSize, CGSize(width: 990, height: 940)] {
            window.setContentSize(size)
            for state in states where state.name != "rules" || size.width == 760 {
                let name = "\(Int(size.width))-\(state.name)"
                guard only.map(name.contains) ?? true else { continue }
                // Each state from a fresh popup: the one before is closed and the window laid out without it.
                model.editingWorkspace = nil
                model.go(AppPlace(.workspaces))
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                frame.layoutSubtreeIfNeeded()
                var start = state.start
                var overflows: Bool?
                start.overflows = { overflows = $0 }
                model.editingWorkspace = EditedWorkspace(name: state.workspace, start: start)
                RunLoop.main.run(until: Date().addingTimeInterval(0.9))
                frame.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(frame, scale: 2))
                if size == AppWindowController.size { #expect(overflows == false, "\(name) scrolls in the window as it opens") }
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("window-\(name).png"))
                // The popup and 18 pt round it, as the mockup's popup view: its width as the window gives it, its
                // height (which follows its parts) read off the render, where its solid ground runs down its left margin.
                let width = WorkspacePopup.size(in: size).width
                let rows = try Self.groundRows(rep, x: Int((size.width - width) / 2) + 9)
                let crop = CGRect(x: (size.width - width) / 2 - 18, y: CGFloat(rows.lowerBound) - 18,
                                  width: width + 36, height: CGFloat(rows.count) + 36).intersection(CGRect(origin: .zero, size: size))
                let image = try #require(rep.cgImage?.cropping(to: CGRect(x: crop.minX * 2, y: crop.minY * 2, width: crop.width * 2, height: crop.height * 2)))
                try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("popup-\(name).png"))
            }
            // The page itself with workspace 4 on screen: its card's small screen and the editor inline draw the strip,
            // the Scrolling block under it; with 5 on screen the empty main + stack, and no Scrolling block.
            for (focused, suffix) in [("4", ""), ("5", "-mainstack")] {
            let page = "\(Int(size.width))-page\(suffix)"
            if only.map(page.contains) ?? true {
                model.editingWorkspace = nil
                engine.observers.tiler.seed(focused: focused, occupied: occupied)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                frame.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(frame, scale: 2))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("window-\(page).png"))
                engine.observers.tiler.seed(focused: "1", occupied: occupied)
            }
            }
        }
        model.editingWorkspace = nil
        Look.shared.themeID = PilotTheme.defaultID
    }
}
}
#endif
