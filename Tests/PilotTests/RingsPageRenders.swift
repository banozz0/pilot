#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Launcher › Rings in the whole window (B48): in the 780 by 560 panel, where the three columns once ran off the right
/// edge at 760 (also 1100 tall, the whole page). Instrument on Tokyo Night, solid, in a moved home whose rings.json the run
/// reads as Pilot would. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter RingsPageRenders`
extension SharedLook {
@MainActor
@Suite("Rings page renders")
struct RingsPageRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Rings fits the panel, and its whole page 1100 tall",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func rings() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.style = .instrument
        look.themeID = "tokyo-night"
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }

        let engine = Engine()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        AppWindowController.applyLook(look, to: window)
        let frame = try #require(window.contentView?.superview)
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("rings-page")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The panel's width again, tall enough to show the inspector the narrow layout puts under the ring.
        for size in [AppWindowController.size, NSSize(width: AppWindowController.size.width, height: 1100)] {
            window.setContentSize(size)
            model.go(AppPlace(.menu, .rings))
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            frame.layoutSubtreeIfNeeded()
            let name = "rings-\(Int(size.width))x\(Int(size.height)).png"
            try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent(name))
        }
    }
}
}
#endif
