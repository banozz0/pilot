#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Binds › Overlay and the overlay it picks for (story 56), opt-in like the other renders: the window on Binds › Overlay
/// in Instrument and Toybox under Tokyo Night at 1440 by 900, at Every bind and after a few switches; the page
/// searched; the overlay with 3, 40, 60 and 140 binds in each style, its foot's Edit what shows and "+ N more".
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter OverlayPicksRenders`
extension SharedLook {
@MainActor
@Suite("Overlay picks renders")
struct OverlayPicksRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Binds › Overlay and the overlay with few and many binds render in every style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("overlay-picks")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()

        let engine = try SharedLook.HomeRenders.engine()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.themeID = "tokyo-night"

        func shoot(_ name: String) throws {
            window.setContentSize(NSSize(width: 1440, height: 900))
            model.go(AppPlace(.overlay))
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }

        func rows(_ count: Int) -> [BindsPage.Row] {
            let modules = ["apps", "windows", "workspaces", "system", "media", "captures", "drive", "notes"]
            return (0..<count).map { i in
                BindsPage.Row(id: "\(i)", key: String(UnicodeScalar(UInt8(65 + i % 26))) + (i >= 26 ? "\(i / 26)" : ""), label: "Action \(i + 1)",
                              module: modules[i * modules.count / count], custom: false)
            }
        }
        let few = Array(InstrumentPanelsTests.overlayRows.prefix(3))

        for style in PilotStyle.allCases {
            let name = style.rawValue
            look.style = style
            AppWindowController.applyLook(look, to: window)
            engine.settings.overlayMode = .every
            try shoot("page-\(name)-every")
            for id in ["windows.close", "windows.fullscreen", "apps.clipboard"] { engine.settings.showInOverlay(id, false, shown: engine.overlayShown()) }
            try shoot("page-\(name)-picked")
            let page = KitPage { OverlayPicksBlocks(query: "window") }
                .styleLayout().background(Color(nsColor: .windowBackgroundColor))
                .styled(.page(.binds)).environment(engine).frame(width: 1000, height: 600).pilotTheme(look: look)
            try writeRender(page, to: dir.appendingPathComponent("search-\(name).png"))

            for (count, label) in [(3, "few"), (40, "40"), (60, "60"), (140, "140")] {
                let list = count == 3 ? few : rows(count)
                try InstrumentPanelsRenders.render(OverlayView(title: "Hyper", rows: list) {}, .overlay, "overlay-\(name)-\(label)", in: dir)
            }
        }
    }
}
}
#endif
