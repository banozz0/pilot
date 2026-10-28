#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The bind hint's tips (story 122) in Instrument and Toybox, each in a dark theme, a light one and Toybox's own,
/// through HUD.makePanel as HUD.tip builds them: the offer with Set a key, the wait for a key, a refused key, the bound
/// key. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter BindHintRenders`
extension SharedLook {
@MainActor
@Suite("Bind hint renders")
struct BindHintRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let tips: [(name: String, text: String, action: String?)] = [
        ("1-offer", BindNudges.offer(for: "TextEdit"), BindNudges.setKey),
        ("2-waiting", BindNudges.capture(for: "TextEdit"), nil),
        ("3-taken", BindNudges.capture(for: "TextEdit", taken: ("Hyper+T", "Telegram")), nil),
        ("4-bound", BindNudges.text(for: "TextEdit", key: "Hyper+E"), nil),
    ]

    @Test("The bind hint's tips render in every style and theme",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        // Solid panels: the glass would show whatever sits behind the test window.
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"]))

        for style in LevelHUDRenders.list("PILOT_RENDER_STYLES", "instrument,toybox") {
            look.style = try #require(PilotStyle(rawValue: style))
            for theme in LevelHUDRenders.list("PILOT_RENDER_THEME", "lagoon,workshop,toybox") {
                look.themeID = theme
                let tag = "\(style)-\(theme)"
                let dir = out.appendingPathComponent("bind-hint-\(tag)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var shots: [(String, NSBitmapImageRep)] = []
                for tip in Self.tips {
                    let panel = HUD.makePanel(TipView(text: tip.text, action: tip.action.map { HUD.TipAction(title: $0) {} }).fixedSize(), shadow: false)
                    defer { panel.close() }
                    let content = try #require(panel.contentView)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    content.layoutSubtreeIfNeeded()
                    let rep = try #require(snapshot(content, scale: 2))
                    try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(tip.name).png"))
                    shots.append((tip.name, rep))
                }
                try ClipboardTabsRenders.sheet(shots, dark: look.theme.dark).write(to: out.appendingPathComponent("bind-hint-\(tag).png"))
            }
        }
    }
}
}
#endif
