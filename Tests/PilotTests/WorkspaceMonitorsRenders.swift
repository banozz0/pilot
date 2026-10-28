#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Monitor picks on Workspaces (N7; on Tiling until Sven's Q207 page map), opt-in like the other renders: the tab in Instrument and Toybox under
/// Lagoon, with Sven's three displays: 1 and 2 on Main, 3 and 4 on the LG, which is
/// drawn once plugged in and once unplugged (its picks then say "unplugged"), 5 to 9 on Any. Nothing reaches an engine.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter WorkspaceMonitorsRenders`
extension SharedLook {
@MainActor
@Suite("Workspace monitors renders")
struct WorkspaceMonitorsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let displays = [ConnectedDisplay(name: "CU34G4Z", id: "A"), ConnectedDisplay(name: "LG ULTRAFINE", id: "B"),
                           ConnectedDisplay(name: "24G1WG4", id: "C")]

    @Test("Workspaces' Monitors block renders in every style, the LG plugged in and unplugged",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("workspace-monitors")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        WorkspaceMonitors.save(["1": .main, "2": .main, "3": Self.displays[1].pin, "4": Self.displays[1].pin], in: defaults)
        let tiler = EngineObservers().tiler
        let block = PilotBlockStore(tiler: tiler, defaults: defaults)
        let monitors = WorkspaceMonitorStore(tiler: tiler, block: block, defaults: defaults)

        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.themeID = "lagoon"
        for style in PilotStyle.allCases {
            look.style = style
            for (state, displays) in [("plugged", Self.displays), ("unplugged", [Self.displays[0], Self.displays[2]])] {
                let page = MonitorsGround { WorkspaceMonitorsBlock(monitors: monitors, displays: displays) }
                    .styled(.page(.workspaces)).frame(width: 1000, height: 2100).pilotTheme(look: look)
                try RestyledRenders.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("tiling-\(style.rawValue)-\(state).png"))
            }
        }
    }
}

/// A page on its style's ground, as the window's frame lays it (Tiling's here, Workspaces' in WorkspacesPageRenders).
struct MonitorsGround<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.styleLayout().background(ink.background) }
}
}
#endif
