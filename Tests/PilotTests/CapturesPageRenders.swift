#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Tools › Captures' Capture, Recording and More tabs (pilot-ui-redesign T18, S1 B), in Instrument under Tokyo Night and
/// Porcelain, at the panel's page width (780 less the 156 pt page list), on a store of its own in a moved home, so nothing
/// of Sven's is read. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter CapturesPageRenders`
extension SharedLook {
@MainActor
@Suite("Captures page renders")
struct CapturesPageRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Captures renders its Capture, Recording and More tabs in both themes", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let store = CaptureSettingsStore(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.style = .instrument
        let width = AppWindowController.size.width - InstrumentFrame.listWidth
        for theme in ["tokyo-night", "porcelain"] {
            look.themeID = theme
            // Each tab holds its own blocks (pages-fill, Sven 2026-11-25): Captures' More went.
            for (tab, recording) in [("capture", false), ("recording", true)] {
                let page = MonitorsGround { CapturesPage(store: store, recording: recording) }
                    .styled(.page(.captures)).frame(width: width, height: 1400).pilotTheme(look: look)
                try RestyledRenders.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("captures-\(tab)-\(theme).png"))
            }
        }
    }
}
}
#endif
