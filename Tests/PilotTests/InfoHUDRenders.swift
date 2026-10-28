#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The info HUD (story 188) in Instrument and Toybox, each in a dark theme, a light one and Toybox's own, through
/// HUD.makePanel as InfoHUD.show builds it: every reading, a Mac mini's (no battery), a charging laptop's, and the time
/// alone; per pass a sheet stacks them, so the fixed width shows. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter InfoHUDRenders`
/// `PILOT_RENDER_STYLES=instrument,toybox` and `PILOT_RENDER_THEME=lagoon,workshop,toybox` (the defaults) narrow it.
extension SharedLook {
@MainActor
@Suite("Info HUD renders")
struct InfoHUDRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let date = "Friday, 16 October 2026"

    static let states: [(name: String, model: InfoModel)] = [
        ("1-every-reading", InfoModel(time: "14:32", date: date, battery: .init(percent: 54, charging: false, minutesLeft: 190),
                                      weather: "☀️ 24°", wifi: "Medina Home")),
        ("2-mac-mini", InfoModel(time: "09:05", date: date, weather: "🌧️ 17°", wifi: "Medina Home")),
        ("3-charging", InfoModel(time: "23:59", date: "Wednesday, 30 September 2026",
                                 battery: .init(percent: 82, charging: true, pluggedIn: true, minutesLeft: 80))),
        ("4-time-alone", InfoModel(time: "07:00", date: date)),
    ]

    @Test("The info HUD renders in every style and theme, every set of readings, at one width",
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
                let dir = out.appendingPathComponent("info-\(tag)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var shots: [(String, NSBitmapImageRep)] = []
                var widths: Set<Int> = []
                for state in Self.states {
                    let rep = try Self.render(state.model)
                    try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(state.name).png"))
                    shots.append((state.name, rep))
                    widths.insert(rep.pixelsWide)
                }
                #expect(widths.count == 1, "\(tag): the HUD's width changed with its readings: \(widths.sorted())")
                try ClipboardTabsRenders.sheet(shots, dark: look.theme.dark).write(to: out.appendingPathComponent("info-\(tag).png"))
            }
        }
    }

    /// The HUD as InfoHUD.show builds its panel, its content drawn at Retina scale with the clear margins kept.
    static func render(_ model: InfoModel) throws -> NSBitmapImageRep {
        let panel = HUD.makePanel(InfoView(model: model).fixedSize())
        defer { panel.close() }
        let content = try #require(panel.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        content.layoutSubtreeIfNeeded()
        return try #require(snapshot(content, scale: 2))
    }
}
}
#endif
