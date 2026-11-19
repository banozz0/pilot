#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Tiling's Focused window block as presets (pilot-ui-redesign T16, S1 B, round 1 shot 1b): the front with Border and Dim
/// other windows on Soft, on Strong, and on Custom, and Tiling's More with the exact rows a Custom mix holds, in the 780 by
/// 560 panel, Instrument in Tokyo Night and Porcelain. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter FocusedWindowRenders`
extension SharedLook {
@MainActor
@Suite("Focused window renders")
struct FocusedWindowRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let looks: [(name: String, theme: String)] = [("dark", "tokyo-night"), ("light", "porcelain")]

    @Test("Focused window renders Soft, Strong and Custom in Tokyo Night and Porcelain", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("focused-window")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()

        let engine = try HomeRenders.engine()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style, look.windowBorder, look.windowBorderWidth, look.windowBorderColour, look.defocusStrength,
                     look.defocusDim, look.defocusShake)
        defer {
            (look.themeID, look.style, look.windowBorder, look.windowBorderWidth, look.windowBorderColour, look.defocusStrength,
             look.defocusDim, look.defocusShake) = saved
        }
        look.style = .instrument
        look.defocusShake = true
        window.setContentSize(AppWindowController.size)

        func set(_ border: BorderLook, _ dim: DimLook) {
            look.windowBorder = border.on; look.windowBorderWidth = border.width; look.windowBorderColour = border.colour
            look.defocusStrength = dim.blur; look.defocusDim = dim.dim
        }
        // The front lands on the block (a place on it, as a link does), which sits under Gaps at the panel's width.
        func shot(_ file: String, _ place: AppPlace) throws {
            model.go(place)
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
        }
        let start = BorderLook(on: true, width: 2, colour: .theme)
        for (name, theme) in Self.looks {
            look.themeID = theme
            AppWindowController.applyLook(look, to: window)
            for preset in [FocusPreset.soft, .strong] {
                set(try #require(BorderLook.picked(preset, from: start)), try #require(DimLook.picked(preset)))
                #expect(BorderLook(on: look.windowBorder, width: look.windowBorderWidth, colour: look.windowBorderColour).preset == preset)
                try shot("\(name)-\(preset.rawValue)", AppPlace(.focusedWindow))
            }
            // Custom: rows no pick writes (shot 1b's Dim other windows · Custom), on the front and on More.
            set(BorderLook(on: true, width: 3, colour: .custom(0xC62828)), DimLook(blur: 3, dim: 40))
            #expect(DimLook(blur: look.defocusStrength, dim: look.defocusDim).preset == .custom)
            try shot("\(name)-custom", AppPlace(.focusedWindow))
            try shot("\(name)-custom-more", AppPlace(.tilingMore))
        }
    }
}
}
#endif
