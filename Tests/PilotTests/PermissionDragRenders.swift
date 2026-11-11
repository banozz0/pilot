#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The drag panel beside System Settings' privacy lists (Sven, Build 71), through HUD.makePanel as Pilot shows it, for
/// Accessibility, Full Disk Access and Screen Recording (asking, then granted with Quit & Reopen) in Instrument dark and light and Toybox; a look of the test's own, no panel shown.
/// `PILOT_RENDER_DIR=<fresh dir> swift test --filter PermissionDragRenders`
extension SharedLook {
@MainActor
@Suite("Permission drag renders")
struct PermissionDragRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The drag panel for each list in each style", .enabled(if: env["PILOT_RENDER_DIR"] != nil))
    func render() throws {
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("permission-drag")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = PanelLookTests.look()
        let passes: [(String, PilotStyle, String)] = [
            ("instrument-dark", .instrument, "tokyo-night"), ("instrument-light", .instrument, "porcelain"), ("toybox", .toybox, "toybox"),
        ]
        for (tag, style, theme) in passes {
            look.style = style
            look.themeID = theme
            let models: [(String, PermissionDragPanel.Model)] = [
                ("accessibility", .init(list: .accessibility)), ("full-disk-access", .init(list: .fullDiskAccess)),
                ("screen-recording", .init(list: .screenRecording)), ("screen-recording-granted", .init(list: .screenRecording, granted: true)),
            ]
            for (name, model) in models {
                let panel = HUD.makePanel(PermissionDragView(model: model, close: {}, relaunch: {}).fixedSize(), look: look)
                defer { panel.close() }
                let content = try #require(panel.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                content.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(content, scale: 2))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name)-\(tag).png"))
            }
        }
    }
}
}
#endif
