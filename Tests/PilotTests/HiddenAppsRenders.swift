#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Install › Hidden apps (Q713) in each style under Lagoon, from seeded rows, on a store of its own that flags nothing,
/// so no app of this Mac is touched. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=<fresh dir under /tmp> PILOT_RENDER_DIR=<fresh dir> PILOT_RESOURCES=Packaging swift test --filter HiddenAppsRenders`
extension SharedLook {
@MainActor
@Suite("Hidden apps renders")
struct HiddenAppsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let rows = [
        HiddenApps.Row(bundle: "com.apple.ActivityMonitor", name: "Activity Monitor", place: HiddenApps.builtIn),
        HiddenApps.Row(bundle: "com.apple.Chess", name: "Chess", place: HiddenApps.builtIn),
        HiddenApps.Row(bundle: "com.apple.dt.Xcode", name: "Xcode", place: "Pilot only: Finder's flag needs an admin, as root owns the app"),
        HiddenApps.Row(bundle: "com.spotify.client", name: "Spotify", place: HiddenApps.both),
    ]

    @Test("Hidden apps renders in each style", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's apps")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("hidden-apps")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let store = HiddenApps(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.themeID = "lagoon"
        for style in PilotStyle.allCases {
            look.style = style
            let page = MonitorsGround { HiddenAppsBlock(store: store, rows: Self.rows, choices: []) }
                .styled(.page(.install)).frame(width: 1000, height: 700).pilotTheme(look: look)
            try RestyledRenders.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("hidden-apps-\(style.rawValue).png"))
        }
    }
}
}
#endif
