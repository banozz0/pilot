#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The extension timer's popover and an extension's alert (Pomodoro as an extension, 2026-10-10) in Instrument and
/// Toybox: the popover with a focus timer 6 min 18 s in, held, and with none; the alert with two buttons and with OK
/// alone, through HUD.makePanel as ExtensionAlert.show builds it. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter ExtensionTimerRenders`
extension SharedLook {
@MainActor
@Suite("Extension timer renders")
struct ExtensionTimerRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The timer popover and the extension alert render in every style",
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
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("extension-timer")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let clock = ExtensionTimerTests.Clock()
        let running = ExtensionTimer(now: { clock.now }), held = ExtensionTimer(now: { clock.now }), none = ExtensionTimer(now: { clock.now })
        running.startFocus()
        clock.now += 25 * 60 - (18 * 60 + 42)
        running.tick()
        held.start(ExtensionTimerTests.focus(paused: true, seconds: 754), owner: ExtensionTimerTests.owner)
        defer { running.stop(); held.stop() }

        for (style, theme) in [(PilotStyle.instrument, "nightwatch"), (.toybox, "toybox")] {
            look.style = style
            look.themeID = theme
            let tokens = StyleTokens.of(style, theme: look.theme)
            for (name, timer) in [("running", running), ("held", held), ("none", none)] {
                try writeRender(TimerPopover(timer: timer).styled(.barPopovers, look: look).pilotTheme(look: look).padding(24)
                    .background(Color(tokens.colors.canvas)), to: out.appendingPathComponent("\(style.rawValue)-popover-\(name).png"), wait: 0.5)
            }
            for (name, alert) in [("alert", ExtensionTimerTests.alert), ("alert-ok", ExtensionTimerTests.plainAlert)] {
                let panel = HUD.makePanel(ExtensionAlertView(alert: alert), surface: .hud)
                defer { panel.close() }
                let content = try #require(panel.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                content.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(content, scale: 2))
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(style.rawValue)-\(name).png"))
            }
        }
    }
}
}
#endif
