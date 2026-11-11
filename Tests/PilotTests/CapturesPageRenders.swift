#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Tools › Captures' two tabs (page map, Sven 2026-10-17), Capture and Recording, in each style under Tokyo Night, on a store of
/// its own in a moved home, so Recent lists nothing of Sven's. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter CapturesPageRenders`
extension SharedLook {
@MainActor
@Suite("Captures page renders")
struct CapturesPageRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Captures renders its Capture and Recording tabs in each style", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
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
        look.themeID = "tokyo-night"
        for style in PilotStyle.allCases {
            look.style = style
            for recording in [false, true] {
                let page = MonitorsGround { CapturesPage(store: store, recording: recording) }
                    .styled(.page(.captures)).frame(width: 1000, height: 1400).pilotTheme(look: look)
                try RestyledRenders.writeTrimmed(rendered(page), from: 0,
                                                 to: dir.appendingPathComponent("captures-\(recording ? "recording" : "capture")-\(style.rawValue).png"))
            }
        }
    }
}
}
#endif
