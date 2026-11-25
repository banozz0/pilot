#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Design round pages-fill (Sven, 2026-11-25, combined-15 build 3216: "you know what we didnt fix, the half empty pages in
/// pilot. also menubar page can it be better organised?"): each option `PagesFill` holds, drawn in the whole window as
/// WidePagesRenders draws a page, at 1700 by 1290 and at the window's first size, in Tokyo Night and Porcelain, with
/// made-up data in the moved home (Update & Clean's four runs, ReportsPageRenders' seed). The Menu bar's options also run
/// the page's whole length (`tall-`). A new window per option: a page once built is kept, and the switches are read as it
/// builds. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter PagesFillRenders`
/// PILOT_RENDER_ONLY narrows the shots to file names holding one of its comma-separated words.
extension SharedLook {
@MainActor
@Suite("Pages fill renders")
struct PagesFillRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    struct Option {
        let name: String
        let places: [(String, AppPlace)]
        var tall = false
        let set: () -> Void
    }

    static let captures = ("captures", AppPlace(.captures)), upkeep = ("upkeep", AppPlace(.upkeep))
    static let rings = ("menu-rings", AppPlace(.rings)), folders = ("files-folders", AppPlace(.folders))
    static let dock = ("dock", AppPlace(.dock)), menuBar = ("menuBar", AppPlace(.menuBar))
    static let menuBarMore = ("menuBar-menuBarMore", AppPlace(.menuBarMore))

    static let options: [Option] = [
        // Update & Clean's More seeded too, for the ranking.
        Option(name: "more-tab", places: [captures, upkeep, ("upkeep-upkeepMore", AppPlace(.upkeepMore))]) {},
        Option(name: "more-whenTall", places: [captures, upkeep]) { PagesFill.more = .whenTall },
        Option(name: "more-folded", places: [captures, upkeep]) {
            PagesFill.more = .folded
            PagesFillDesign.foldedMore = [.capturesMore, .upkeepMore]
        },
        Option(name: "preview-asIs", places: [rings, folders]) {},
        Option(name: "preview-grows", places: [rings, folders]) { PagesFill.preview = .grows },
        Option(name: "preview-detail", places: [rings, folders]) { PagesFill.preview = .detail },
        Option(name: "dock-asIs", places: [dock]) {},
        Option(name: "dock-twoColumns", places: [dock]) { PagesFill.dock = .twoColumns },
        Option(name: "dock-lookBeside", places: [dock]) {
            PagesFill.dock = .lookBeside
            PagesFillDesign.foldedMore = [.dockMore]
        },
        Option(name: "menuBar-asIs", places: [menuBar], tall: true) {},
        Option(name: "menuBar-columns", places: [menuBar], tall: true) { PagesFill.menuBar = .columns },
        Option(name: "menuBar-more", places: [menuBar, menuBarMore], tall: true) {
            PagesFill.menuBar = .more
            PagesFillDesign.menuBarTab = "More"
        },
        Option(name: "menuBar-tabs", places: [menuBar, menuBarMore], tall: true) {
            PagesFill.menuBar = .tabs
            PagesFillDesign.menuBarTab = "Items"
        },
    ]

    static func reset() {
        PagesFill.more = .tab; PagesFill.preview = .asIs; PagesFill.dock = .asIs; PagesFill.menuBar = .asIs
        PagesFillDesign.foldedMore = []; PagesFillDesign.menuBarTab = nil
    }

    @Test("Each pages-fill option renders at 1700 by 1290 and at the window's first size, dark and light",
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
        // The page shows the top bar's strip, the bar Sven runs; the top bar itself stays off (no bar on this screen). A
        // render run's defaults are the test runner's own, kept across runs: the placement goes back after.
        let placement = BarItemsStore.shared.pagePlacement
        let stored = UserDefaults.standard.object(forKey: BarItemsStore.pagePlacementKey)
        defer {
            BarItemsStore.shared.pagePlacement = placement
            if stored == nil { UserDefaults.standard.removeObject(forKey: BarItemsStore.pagePlacementKey) }
        }
        BarItemsStore.shared.pagePlacement = .topBar
        defer { Self.reset() }
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.style = .instrument
        defer { look.endTrial() }
        let only = Self.env["PILOT_RENDER_ONLY"]?.split(separator: ",").map(String.init)
        let sizes: [(String, NSSize)] = [("1700", NSSize(width: 1700, height: 1290)), ("default", AppWindowController.size)]

        for option in Self.options {
            Self.reset()
            option.set()
            let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
            let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
            defer { window.close() }
            let frame = try #require(window.contentView?.superview)
            for (name, theme) in SharedLook.HomeRenders.looks {
                look.tryOn(id: theme, pack: nil)
                AppWindowController.applyLook(look, to: window)
                // The Menu bar's options also at the page's whole length.
                let shots = sizes + (option.tall ? [("tall1700", NSSize(width: 1700, height: 3600)), ("talldefault", NSSize(width: 1296, height: 3600))] : [])
                for (suffix, size) in shots {
                    window.setContentSize(size)
                    for (page, place) in option.places {
                        let file = "\(option.name)-\(name)-\(suffix)-\(page)"
                        guard only.map({ $0.contains { file.contains($0) } }) ?? true else { continue }
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
                }
            }
        }
    }
}
}
#endif
