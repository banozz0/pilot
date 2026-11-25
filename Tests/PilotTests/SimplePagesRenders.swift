#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Dock and Clipboard, simpler (pilot-ui-redesign T17, S1 B), each one page (Clipboard's More went back onto its page,
/// Sven 2026-11-23; the Dock's with pages-fill, 2026-11-25), in the 780 by 560 panel, Instrument in Tokyo Night and
/// Porcelain; and a search result for a look's row (Dock's Magnification), ringed in the look's column. Clipboard's Recent seeded as the fill renders seed
/// it. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter SimplePagesRenders`
extension SharedLook {
@MainActor
@Suite("Simple pages renders")
struct SimplePagesRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let looks: [(name: String, theme: String)] = [("dark", "tokyo-night"), ("light", "porcelain")]

    @Test("Dock and Clipboard render their pages in Tokyo Night and Porcelain", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("simple-pages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()

        let clips = try PageFillRenders.seedClips(home: URL(fileURLWithPath: home))
        ClipboardHistory.shared.useStore(clips)
        defer { ClipboardHistory.shared.useStore(nil) }

        let engine = try HomeRenders.engine()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.style = .instrument
        window.setContentSize(AppWindowController.size)

        func shot(_ file: String, _ place: AppPlace, ring key: String? = nil) throws {
            model.go(place)
            if let key { model.ring(key) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
        }
        for (name, theme) in Self.looks {
            look.themeID = theme
            AppWindowController.applyLook(look, to: window)
            try shot("\(name)-dock-front", AppPlace(.dock))
            try shot("\(name)-clipboard-front", AppPlace(.clipboard))
        }
        // A search result for a look's row (on More until pages-fill): the page, the row ringed in the look's column.
        look.themeID = Self.looks[0].theme
        AppWindowController.applyLook(look, to: window)
        try shot("dark-dock-ring-magnify", AppPlace(.dock), ring: "dock.magnify")
        #expect(model.section(of: .dock) == nil, "a ringed look row stays on the page")
    }
}
}
#endif
