#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The pages split (Sven, 2026-11-15): the window at the pages it moved, at 1000 and 760 by 660, and the rail at the least
/// size, 760 by 520, with the Developer pages switch on, in Instrument and the Toolbar tabs layout; run on main
/// for the before and on the branch for the after. Seeded as WindowPagesRenders is.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter PagesSplitRenders`
extension SharedLook {
@MainActor
@Suite("Pages split renders")
struct PagesSplitRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let places: [(String, AppPlace)] = [
        ("workspaces", AppPlace(.workspaces)), ("tiling", AppPlace(.tiling)), ("menubar", AppPlace(.menuBar)),
        ("look", AppPlace(.look)), ("fonts", AppPlace(.fonts)), ("openwith", AppPlace(.openWith)), ("configs", AppPlace(.configs)),
        ("launcher", AppPlace(.menu)), ("extensions", AppPlace(.extensions)),
    ]

    @Test("The split pages and the rail", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("pages-split")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()

        let engine = try SharedLook.HomeRenders.engine()
        SharedLook.StatsRenders.seed(SystemSampler.shared)
        // The window reads the Developer switch from the app's own settings: the engine's stand in for this run.
        let live = PilotSettings.live
        PilotSettings.live = engine.settings
        engine.settings.developer = true
        defer { engine.settings.developer = false; PilotSettings.live = live }
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style, look.windowShape)
        defer { (look.themeID, look.style, look.windowShape) = saved }

        func shoot(_ file: String, _ place: AppPlace, _ size: NSSize) throws {
            window.setContentSize(size)
            model.go(place)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            frame.layoutSubtreeIfNeeded()
            try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
        }

        look.style = .instrument
        look.themeID = "nightwatch"
        AppWindowController.applyLook(look, to: window)
        for width in [1000.0, 760.0] {
            for (name, place) in Self.places { try shoot("\(name)-\(Int(width))", place, NSSize(width: width, height: 660)) }
        }
        try shoot("rail-instrument-760x520", AppPlace(.home), NSSize(width: 760, height: 520))
        look.windowShape = .tabs
        try shoot("tabs-760", AppPlace(.workspaces), NSSize(width: 760, height: 660))
        try shoot("tabs-1000", AppPlace(.look), NSSize(width: 1000, height: 660))
    }
}
}
#endif
