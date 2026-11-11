#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Hyper+Space › About (Q443) as Line draws it, in Tokyo Night, Porcelain and Toybox, from seeded facts (Sven's Mac mini as read
/// 2026-10-24), never this Mac's. Opt-in, offscreen:
/// `CFFIXED_USER_HOME=/tmp/pilot-rh PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter AboutRenders`
extension SharedLook {
@MainActor
@Suite("About renders")
struct AboutRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let facts = AboutFacts(
        hardware: [
            .init(label: "Mac", value: "Mac mini (2024)", note: "Mac16,10"),
            .init(label: "Chip", value: "Apple M4", note: "10 cores (4P + 6E)"),
            .init(label: "GPU", value: "10 cores", mono: true),
            .init(label: "Display", value: "3440×1440 in 34″, 240 Hz", note: "External · Main", mono: true),
            .init(label: "Display", value: "1080×1920 in 23″, 120 Hz", note: "External · Turned 90°", mono: true),
            .init(label: "Disk", value: "384.2 GB / 494.4 GB", note: "APFS", share: 0.78, mono: true),
            .init(label: "Memory", value: "19.8 GB / 24.0 GB", share: 0.83, mono: true),
            .init(label: "Swap", value: "2.1 GB / 3.0 GB", share: 0.71, mono: true),
        ],
        software: [
            .init(label: "macOS", value: "macOS 27.0.1", note: "26A434"),
            .init(label: "Pilot", value: "0.1.0", note: "build 1789", mono: true),
            .init(label: "Tiler", value: "Pilot tiler", note: "AeroSpace engine"),
            .init(label: "Terminal", value: "Ghostty 1.3.1", note: "libghostty in the bar drop"),
            .init(label: "Apps", value: "80", note: "in Applications", mono: true),
        ],
        age: [
            .init(label: "Mac age", value: "179 days", note: "set up 28 April 2026"),
            .init(label: "Uptime", value: "2 days, 21 hours, 58 mins"),
            .init(label: "Updated", value: "Saturday, 24 October 2026 at 13:57", note: "Pilot"),
        ])

    @Test("About renders in Tokyo Night, Porcelain and Toybox", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        AboutFacts.seed = Self.facts
        defer { AboutFacts.seed = nil }
        let look = Look.shared
        let (style, theme) = (look.style, look.themeID)
        defer { look.style = style; look.themeID = theme }
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("about")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, kind, themeID) in [("about-lagoon", PilotStyle.instrument, "tokyo-night"), ("about-porcelain", .instrument, "porcelain"),
                                      ("about-toybox", .toybox, "tokyo-night")] {
            look.style = kind
            look.themeID = themeID
            let model = MenuModel(nav: MenuNavigator(entries: try LineMenuRenders.built(), branch: .about))
            model.layout = .line
            model.ownKey = "Hyper+Space"
            #expect(model.showsAbout)
            try await LineMenuRenders.render(model, name, in: dir, wait: 0.3)
        }
    }
}
}
#endif
