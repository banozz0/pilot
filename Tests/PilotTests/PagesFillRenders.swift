#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Pages-fill (Sven, 2026-11-25: "make sure that on the page theres only relevant stuff"): every page and tab the round
/// changed, drawn in the whole window as WidePagesRenders draws a page, at 1700 by 1290, 1630 by 1200 and the window's first size, in
/// Tokyo Night and Porcelain, with made-up data in the moved home (Update & Clean's four runs, ReportsPageRenders' seed);
/// then each once more in Tokyo Night at its whole length (`tall-`), and the Dock at the window's least size, where its
/// look's column stands over the widgets. The page shows the placement it had: nothing here writes the defaults a render
/// run shares. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter PagesFillRenders`
/// PILOT_RENDER_ONLY narrows the shots to file names holding one of its comma-separated words.
extension SharedLook {
@MainActor
@Suite("Pages fill renders")
struct PagesFillRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// The changed pages and tabs, by file name.
    static let places: [(String, AppPlace)] = [
        ("captures", AppPlace(.captures)), ("captures-recording", AppPlace(.recording)), ("upkeep", AppPlace(.upkeep)),
        ("binds", AppPlace(.binds)), ("install", AppPlace(.catalogue)), ("install-installMore", AppPlace(.installMore)),
        ("tiling", AppPlace(.tiling)), ("dock", AppPlace(.dock)), ("menu-rings", AppPlace(.rings)), ("files-folders", AppPlace(.folders)),
        ("menuBar", AppPlace(.menuBar)), ("menuBar-menuBarItems", AppPlace(.menuBarItems)),
    ]

    @Test("Every page pages-fill changed renders at 1700 by 1290 and at the window's first size, dark and light, and whole",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("pages-fill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        try SharedLook.HomeRenders.seedPresets()
        // Update & Clean's runs, as ReportsPageRenders seeds them, into the moved home's Reports.
        _ = try ReportsPageRenders.seed(ReportStore.standard.folder)
        let engine = try SharedLook.HomeRenders.engine()
        SharedLook.StatsRenders.seed(SystemSampler.shared)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.style = .instrument
        defer { look.endTrial() }
        let only = Self.env["PILOT_RENDER_ONLY"]?.split(separator: ",").map(String.init)
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)

        func shot(_ file: String, _ place: AppPlace, theme: String) throws {
            guard only.map({ $0.contains { file.contains($0) } }) ?? true else { return }
            // Built whole, as WidePagesRenders builds a page (no display link offscreen).
            model.go(place)
            model.ringed = "pages-fill.render"
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            model.ringed = nil
            if look.trialID != theme {
                look.tryOn(id: theme, pack: nil)
                AppWindowController.applyLook(look, to: window)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            }
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
        }

        // Sven's Tiling on build 3223 was about 1630 by 1200 (the Tiling pass).
        let sizes: [(String, NSSize)] = [("1700", NSSize(width: 1700, height: 1290)), ("1630", NSSize(width: 1630, height: 1200)),
                                         ("default", AppWindowController.size)]
        for (name, theme) in SharedLook.HomeRenders.looks {
            look.tryOn(id: theme, pack: nil)
            AppWindowController.applyLook(look, to: window)
            for (suffix, size) in sizes {
                window.setContentSize(size)
                for (page, place) in Self.places { try shot("\(name)-\(suffix)-\(page)", place, theme: theme) }
            }
        }
        // Whole pages, to read every block; and the Dock in the least window.
        let dark = SharedLook.HomeRenders.looks[0].theme
        look.tryOn(id: dark, pack: nil)
        AppWindowController.applyLook(look, to: window)
        window.setContentSize(NSSize(width: 1700, height: 3000))
        for (page, place) in Self.places { try shot("tall-dark-1700-\(page)", place, theme: dark) }
        window.setContentSize(AppWindowController.minSize)
        try shot("dark-min-dock", AppPlace(.dock), theme: dark)
        window.setContentSize(AppWindowController.size)
    }
}
}
#endif
