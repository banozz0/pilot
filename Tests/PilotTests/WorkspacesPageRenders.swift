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
/// shows its name alone; the Monitors and Swipe blocks on More. In Instrument and Toybox under Lagoon. Nothing
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
        look.themeID = "lagoon"
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
}

}
#endif
