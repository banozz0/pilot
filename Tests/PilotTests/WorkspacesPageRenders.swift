#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Workspaces page with Add and Delete (Sven 2026-10-17), opt-in like the other renders: nine workspaces in one row
/// (Sven's Q37), its More with workspace 2 picked while 1 is on screen (simplify-pages T18),
/// then five after 3 is deleted (4 and up moving down a number), then one with Delete off; workspace 2 named Chat, so it
/// shows its name alone; the Monitors and Swipe blocks on More. In Instrument and Toybox under Tokyo Night. Nothing
/// reaches an engine: the tiler is never started.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter WorkspacesPageRenders`
extension SharedLook {
@MainActor
@Suite("Workspaces page renders")
struct WorkspacesPageRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Workspaces renders at nine, six and one in every style", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("workspaces-page")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        WorkspaceMonitors.save(["1": .main], in: defaults)
        let tiler = TilerService(tip: { _ in })
        let observers = EngineObservers(tiler: tiler)
        let block = PilotBlockStore(tiler: tiler, defaults: defaults)
        let monitors = WorkspaceMonitorStore(tiler: tiler, block: block, defaults: defaults)
        let list = WorkspaceList(tiler: tiler, block: block, monitors: monitors, defaults: defaults)
        let presets = WorkspacePresets(observers: observers, defaults: defaults)
        presets.save(WorkspacePreset(name: "Chat", apps: [.init(bundleId: "com.apple.finder", name: "Finder", percent: 60),
                                                         .init(bundleId: "com.apple.Notes", name: "Notes", percent: 40)], layout: nil), to: "2")
        let settings = PilotSettings(defaults: defaults, loginItem: SwipeWorkspacesTests.item)
        let page = { (more: Bool, focused: String, picked: String?) in
            WorkspacesBody(block: block, layouts: WorkspaceLayouts(observers: observers, defaults: defaults), presets: presets,
                           snapshots: WorkspaceSnapshots(observers: observers, defaults: defaults), list: list, focused: focused,
                           start: .init(apps: []), settings: settings, monitors: monitors,
                           displays: [ConnectedDisplay(name: "LG ULTRAFINE", id: "B")], more: more, picked: picked)
        }
        let write = { (body: WorkspacesBody, file: String) throws in
            let view = MonitorsGround { body }.styled(.page(.workspaces)).frame(width: 1100, height: 1500).pilotTheme(look: Look.shared)
            // The page fills the window (its editor runs to the foot), so it is written whole, never trimmed.
            try #require(rendered(view).representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent(file))
        }

        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.themeID = "tokyo-night"
        for count in [9, 5, 1] {
            if count == 5 { while list.count > 6 { list.remove() }; list.remove("3") }
            while list.count > count { list.remove() }
            for style in PilotStyle.allCases {
                let name = style.rawValue
                look.style = style
                try write(page(false, "2", nil), "workspaces-\(count)-\(name).png")
                // More edits the workspace picked on the front, Chat (2) while 1 is on screen (simplify-pages T18).
                if count == 9 { try write(page(true, "1", "2"), "workspaces-9-more-picked-2-\(name).png") }
            }
        }
        #expect(list.names == ["1"])
    }

    /// Mid-drag (Sven, 2026-11-15): Notes picked up from workspace 2's card over workspace 4's card, which lights; then
    /// over Safari's tile on workspace 1's card, which lights to swap. Staged on the page's own drag (WorkspaceDrag.stage)
    /// once a render at rest has told it where the cards are. Instrument under Tokyo Night.
    @Test("Workspaces mid-drag", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderDrag() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("workspaces-page")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let tiler = TilerService(engine: WorkspaceListTests.FakeTiler(), tip: { _ in })
        let observers = EngineObservers(tiler: tiler)
        let block = PilotBlockStore(tiler: tiler, defaults: defaults)
        let monitors = WorkspaceMonitorStore(tiler: tiler, block: block, defaults: defaults)
        let list = WorkspaceList(tiler: tiler, block: block, monitors: monitors, defaults: defaults)
        let presets = WorkspacePresets(observers: observers, store: WorkspacePresetStore(url: PilotFolder.support.appending(path: "drag-presets-\(UUID().uuidString).json")),
                                       defaults: defaults)
        presets.save(WorkspacePreset(name: "Web", apps: [.init(bundleId: "com.apple.Safari", name: "Safari", percent: 50),
                                                        .init(bundleId: "com.mitchellh.ghostty", name: "Ghostty", percent: 50)], layout: .mainStack), to: "1")
        presets.save(WorkspacePreset(name: "Chat", apps: [.init(bundleId: "com.apple.finder", name: "Finder", percent: 60),
                                                         .init(bundleId: "com.apple.Notes", name: "Notes", percent: 40)], layout: nil), to: "2")
        let drag = WorkspaceDrag()
        let layouts = WorkspaceLayouts(observers: observers, defaults: defaults), snapshots = WorkspaceSnapshots(observers: observers, defaults: defaults)
        let page = {
            WorkspacesBody(block: block, layouts: layouts, presets: presets, snapshots: snapshots, list: list, focused: "2",
                           start: .init(apps: []), monitors: monitors, displays: [], tiler: tiler, drag: drag)
        }
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        (look.themeID, look.style) = ("tokyo-night", .instrument)
        let write = { (file: String) throws in
            let view = MonitorsGround { page() }.styled(.page(.workspaces)).frame(width: 1100, height: 1500).pilotTheme(look: Look.shared)
            try #require(rendered(view).representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent(file))
        }
        try write("workspaces-drag-rest.png")
        let four = try #require(drag.cards["4"], "the cards reported no frames")
        let notes = WorkspaceDrag.Item.app(bundle: "com.apple.Notes", name: "Notes", from: "2")
        // Over workspace 4's card, clear of its (empty) screen's middle: the page's own hit says where it lands.
        let overFour = CGPoint(x: four.midX, y: four.maxY - 8)
        drag.stage(notes, at: overFour, over: drag.hit(notes, overFour))
        print("DRAG over 4: \(String(describing: drag.target))")
        #expect(drag.target == .workspace("4"))
        try write("workspaces-drag-move.png")
        let screen = try #require(drag.screens["1"])
        let safari = WorkspaceCard.tiles(presets.contents.preset(for: "1").map { WorkspacePresetDraft($0, workspace: "1") }!, in: screen.size)[0]
        let overSafari = CGPoint(x: screen.minX + safari.midX, y: screen.minY + safari.midY)
        drag.stage(notes, at: overSafari, over: drag.hit(notes, overSafari))
        print("DRAG over Safari: \(String(describing: drag.target))")
        #expect(drag.target == .tile(workspace: "1", bundle: "com.apple.Safari", name: "Safari"))
        try write("workspaces-drag-swap.png")
    }
}

}
#endif
