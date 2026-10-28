#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// C3's page map (Sven, 2026-10-10): every page and tab in the whole window, Instrument in Nightwatch and Toybox in Lagoon
/// at 1000 and at the least width, 760, and the Hyper+Space menu's root in each, all one scale step bigger; and Home at the
/// window's first size, 1000 by 660. Seeded as InstrumentPagesRenders is (fakes; nothing reaches the tiler or the network). Opt-in, in
/// a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter WindowPagesRenders`
extension SharedLook {
@MainActor
@Suite("Window pages renders")
struct WindowPagesRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// Every page, and every tab past a page's first, by file name.
    static let places: [(String, AppPlace)] = AppPage.allCases.map { ($0.rawValue, AppPlace($0)) }
        + AppSection.allCases.filter(\.isTab).map { ("\($0.page.rawValue)-\($0.rawValue)", AppPlace($0)) }

    @Test("Every page renders in Instrument and Toybox at 1000 and 760", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("window-pages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()

        let engine = try SharedLook.HomeRenders.engine()
        SharedLook.StatsRenders.seed(SystemSampler.shared)
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        // PILOT_RENDER_ONLY narrows to the file names holding one of its comma-separated words.
        let only = Self.env["PILOT_RENDER_ONLY"]?.split(separator: ",").map(String.init)
        let looks: [(name: String, style: PilotStyle, theme: String, widths: [Int])] = [
            ("instrument", .instrument, "nightwatch", [1000, 760]), ("toybox", .toybox, "lagoon", [1000, 760]),
        ]
        for (name, style, theme, widths) in looks {
            look.style = style
            look.themeID = theme
            AppWindowController.applyLook(look, to: window)
            for width in widths {
                for (page, place) in Self.places {
                    let file = "\(name)-\(width)-\(page)"
                    guard only.map({ $0.contains { file.contains($0) } }) ?? true else { continue }
                    window.setContentSize(NSSize(width: CGFloat(width), height: width == 760 ? 620 : 760))
                    model.go(place)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.7))
                    frame.layoutSubtreeIfNeeded()
                    let rep = try #require(snapshot(frame, scale: 2))
                    try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
                }
            }
            // The window's first size: Instrument's and Toybox's sidebars keep their mockups' rows and footer and scroll
            // there; the renders show by how much.
            window.setContentSize(AppWindowController.size)
            model.go(AppPlace(.home))
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            frame.layoutSubtreeIfNeeded()
            try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("\(name)-660-sidebar.png"))
            // The menu's root and a search, as the panel draws them.
            for (state, nav) in [("root", AliasesRenders.root()), ("search", AliasesRenders.search())] {
                let file = "\(name)-menu-\(state)"
                guard only.map({ $0.contains { file.contains($0) } }) ?? true else { continue }
                let panel = HUD.makePanel(MenuView(model: MenuModel(nav: nav)).environment(engine), surface: .menu)
                defer { panel.close() }
                let content = try #require(panel.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                content.layoutSubtreeIfNeeded()
                try #require(snapshot(content, scale: 2)?.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
            }
        }
    }
}
}
#endif
