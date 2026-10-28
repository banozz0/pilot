#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Instrument in the theme's colours (coordinator for Sven, 2026-10-08: the style decides shape, type, spacing and depth;
/// the theme decides colour everywhere): the whole window at 1440 by 900, frame and page, Home and Binds under Nightwatch
/// (the navy and purple of Sven's screenshot), Paper (light), Hearth (warm) and Graphite (closest to mockup A), and Setup,
/// a page not restyled yet, inside Instrument's frame under Nightwatch. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter InstrumentThemeRenders`
extension SharedLook {
@MainActor
@Suite("Instrument theme renders")
struct InstrumentThemeRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Instrument's frame and pages take the theme's colours", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        testApp()
        let engine = try ToyboxBindsRenders().engine()
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("instrument-themes")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DisplayFaces.directory = LookThemeTests.fonts
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.instrument.themes")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let saved = (Look.shared.themeID, Look.shared.style)
        defer { (Look.shared.themeID, Look.shared.style) = saved }
        Look.shared.style = .instrument
        let shots: [(String, [AppPage])] = [("nightwatch", [.home, .binds, .system]), ("paper", [.home, .binds]), ("hearth", [.home, .binds]),
                                            ("graphite", [.home, .binds])]
        for (theme, pages) in shots {
            Look.shared.themeID = theme
            AppWindowController.applyLook(.shared, to: window)
            for page in pages {
                window.setContentSize(NSSize(width: 1440, height: 900))
                model.go(AppPlace(page))
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                frame.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(frame, scale: 2))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("instrument-\(theme)-\(page.rawValue)-1440.png"))
            }
        }
    }
}
}
#endif
