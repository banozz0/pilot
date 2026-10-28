#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Binds › Mouse (Q184, Q223, Q257), opt-in like the other renders: the labelled drawing, the box beside it and a row per
/// button, with Sven's HyperX and three mouse binds, in each state of the one flow, in every style; the default window's
/// page (928 pt) and the narrowest (688 pt, the box under the drawing).
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter MouseButtonsRenders`
extension SharedLook {
@MainActor
@Suite("Mouse buttons renders")
struct MouseButtonsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Binds › Mouse renders each state of the flow in every style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("mouse-buttons")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()

        let engine = try SharedLook.HomeRenders.engine()
        let core = MouseKeys.Device(vendor: 1008, product: 3471, name: "HyperX Pulsefire Core")
        engine.binds.setMouse(MouseKeys.button(2), to: "media.playPause")   // Sven's binds.json: Mouse 3, Play or pause
        engine.binds.setMouse(MouseKeys.media(17), to: "media.next", device: core, button: 5)   // Forward sends Next
        engine.binds.setMouse(MouseKeys.media(7), to: "media.mute", device: core)   // caught with Other button…
        // With Hyper held (P51): Hyper + the wheel click, Hyper + Forward's Next from the mouse, Hyper + scroll up.
        engine.binds.setMouse(MouseKeys.underHyper(MouseKeys.button(2)), to: "windows.close")
        engine.binds.setMouse(MouseKeys.underHyper(MouseKeys.media(17)), to: "media.previous", device: core, button: 5)
        engine.binds.setMouse(MouseKeys.scrollUp, to: "media.volumeUp")
        defer { for b in engine.binds.store.mouseBinds { engine.binds.setMouse(b.trigger, to: nil) } }
        let pulsefire = MouseButtons.Found(mice: [core], buttons: (2...4).map { MouseKeys.button($0) })
        let seven = MouseButtons.Found(mice: [MouseKeys.Device(vendor: 1, product: 2, name: "A seven-button mouse")],
                                       buttons: (2...6).map { MouseKeys.button($0) })
        let logitech = MouseKeys.Device(vendor: 1133, product: 45108, name: "Logitech MX Master 3S")
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.themeID = "lagoon"

        typealias S = MouseButtonsPage.Shown
        let states: [(name: String, shown: S, mice: MouseButtons.Found, spot: Int?)] = [
            ("rest", S(learn: .idle, target: nil), pulsefire, nil),
            ("waiting", S(learn: .listening, target: 4), pulsefire, 4),
            ("waiting-keyboard", S(learn: .listening, target: 4, note: MouseKeys.Catch.keyboard(press: "Back"), left: 5), pulsefire, 4),
            ("waiting-locked", S(learn: .listening, target: 4, note: MouseKeys.Catch.locked("Play key"), askAccess: true, left: 3), pulsefire, 4),
            ("quiet", S(learn: .quiet, target: 4), pulsefire, 4),
            ("other-shared", S(learn: .got(MouseKeys.button(2), device: nil), target: nil), pulsefire, nil),   // Q309
            ("quiet-vendor", S(learn: .quiet, target: nil, vendorReport: "report 6: 06 01 02 00"), pulsefire, nil),   // P57
            ("caught", S(learn: .got(MouseKeys.media(16), device: core), target: 4), pulsefire, 4),
            ("caught-button", S(learn: .got(MouseKeys.button(3), device: nil), target: 4), pulsefire, 4),
            ("caught-key", S(learn: .got(MouseKeys.key(53), device: core), target: 4), pulsefire, 4),   // NGenuity's Esc on Back
            ("other-mouse", S(learn: .got(MouseKeys.media(16), device: logitech), target: 4), pulsefire, 4),
            ("bound", S(learn: .idle, target: nil), pulsefire, 5),
            ("change", S(learn: .got(MouseKeys.media(17), device: core), target: 5), pulsefire, 5),
            ("other-button", S(learn: .listening, target: nil, left: 7), pulsefire, nil),
            ("hyper-waiting", S(learn: .listening, target: 4, hyper: true), pulsefire, 4),
            ("hyper-scroll", S(learn: .got(MouseKeys.scrollDown, device: nil), target: nil, hyper: true), pulsefire, nil),
            ("extras", S(learn: .idle, target: nil), seven, nil),
        ]
        for style in PilotStyle.allCases {
            look.style = style
            for (name, shown, mice, spot) in states {
                for width in style == .instrument && ["rest", "caught"].contains(name) ? [928.0, 688] : [928] {
                    let page = MouseButtonsPage(shown: shown, mice: mice, spot: spot)
                        .styleLayout().background(Color(nsColor: .windowBackgroundColor))
                        .styled(.page(.binds)).environment(engine).frame(width: width, height: 1500).pilotTheme(look: look)
                    let suffix = width == 928 ? "" : "-\(Int(width))"
                    try writeRender(page, to: dir.appendingPathComponent("\(name)-\(style.rawValue)\(suffix).png"))
                }
            }
        }
    }
}
}
#endif
