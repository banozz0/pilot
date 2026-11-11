#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Workspaces › Tiling without its Scrolling block (spec scrolling-layout T8, Sven's Q43: hidden, its keys still decode),
/// opt-in like the other renders: the tab in Instrument and Toybox under Tokyo Night, once with the defaults and once with a
/// changed scrolling block saved (widths 1/4, 1/2 and full, new 1/2, a 12 pt sliver, Instant), which loads and shows no
/// row. Nothing reaches an engine.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter TilingScrollingRenders`
extension SharedLook {
@MainActor
@Suite("Tiling scrolling renders")
struct TilingScrollingRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Tiling renders no Scrolling rows in every style, with the default or a changed scrolling block saved",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("tiling-scrolling")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let changed = PilotBlock.Scrolling(widths: [.quarter, .half, .full], newWidth: .half, sliver: 12, speed: .instant)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.themeID = "tokyo-night"
        for (state, scrolling) in [("defaults", PilotBlock.Scrolling()), ("changed", changed)] {
            let defaults = try #require(UserDefaults(suiteName: testSuite()))
            defaults.set(try JSONEncoder().encode(PilotBlock(gaps: .init(inner: 8, outer: 12), scrolling: scrolling)), forKey: "pilotBlock")
            let block = PilotBlockStore(tiler: EngineObservers().tiler, defaults: defaults)
            #expect(block.block.scrolling == scrolling, "the hidden keys still decode")
            let settings = PilotSettings(defaults: defaults, loginItem: SwipeWorkspacesTests.item)
            for style in PilotStyle.allCases {
                look.style = style
                let page = MonitorsGround { TilingBody(block: block, settings: settings, apps: []) }
                    .styled(.page(.workspaces)).frame(width: 1000, height: 1500).pilotTheme(look: look)
                try RestyledRenders.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("tiling-\(style.rawValue)-\(state).png"))
            }
        }
    }
}
}
#endif
