#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The brightness level HUD (story 144, card agent-bo-95423314) in Instrument and Toybox, each in
/// a dark theme, a light one and Toybox's own, through HUD.makePanel as LevelHUD.show builds it: no level, a level, a full
/// one, a screen with no control, one still being read, and a long screen name; per pass a sheet stacks them, so the
/// fixed width shows. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter LevelHUDRenders`
/// `PILOT_RENDER_STYLES=instrument,toybox` and `PILOT_RENDER_THEME=tokyo-night,folio,toybox` (the defaults) narrow it.
extension SharedLook {
@MainActor
@Suite("Level HUD renders")
struct LevelHUDRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static func list(_ key: String, _ fallback: String) -> [String] {
        (env[key] ?? fallback).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Each reading the HUD shows, and the screen it shows it for.
    static let readings: [(name: String, screen: String, reading: LevelModel.Reading)] = [
        ("1-level-0", "CU34G4Z", .level(0)),
        ("2-level-56", "CU34G4Z", .level(0.56)),
        ("3-level-100", "CU34G4Z", .level(1)),
        ("4-no-control", "24G1WG4", .noControl),
        ("5-reading", "Studio Display", .reading),
        ("6-long-name", "LG Ultrafine 5K Thunderbolt Display", .level(0.5625)),
    ]

    @Test("The level HUD renders in every style and theme, every reading, at one width",
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

        for style in Self.list("PILOT_RENDER_STYLES", "instrument,toybox") {
            look.style = try #require(PilotStyle(rawValue: style))
            for theme in Self.list("PILOT_RENDER_THEME", "tokyo-night,folio,toybox") {
                look.themeID = theme
                let tag = "\(style)-\(theme)"
                let dir = out.appendingPathComponent("level-\(tag)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var shots: [(String, NSBitmapImageRep)] = []
                var widths: Set<Int> = []
                for state in Self.readings {
                    let rep = try Self.render(LevelModel(screen: state.screen, reading: state.reading))
                    try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(state.name).png"))
                    shots.append((state.name, rep))
                    widths.insert(rep.pixelsWide)
                }
                #expect(widths.count == 1, "\(tag): the HUD's width changed with its reading: \(widths.sorted())")
                try ClipboardTabsRenders.sheet(shots, dark: look.theme.dark).write(to: out.appendingPathComponent("level-\(tag).png"))
            }
        }
    }

    /// The HUD as LevelHUD.show builds its panel, its content drawn at Retina scale with the clear margins kept.
    static func render(_ model: LevelModel) throws -> NSBitmapImageRep {
        let panel = HUD.makePanel(LevelView(model: model).fixedSize())
        defer { panel.close() }
        let content = try #require(panel.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        content.layoutSubtreeIfNeeded()
        return try #require(snapshot(content, scale: 2))
    }
}
}
#endif
