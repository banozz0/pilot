#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Binds › Abilities and a page with ⓘ tips (story 155), opt-in like the other renders: the window on Abilities in
/// Instrument and Toybox under Lagoon at 1440 by 900, Instrument at 760 too; the list searched for "wallpaper", and for
/// "bitwarden" (More abilities); Binds' own bar with its Abilities button; Clipboard in Instrument with its tips
/// (Pomodoro's page, the other, left Pilot on 2026-10-10).
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter AbilitiesRenders`
extension SharedLook {
@MainActor
@Suite("Abilities renders")
struct AbilitiesRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Abilities renders in every style, searched, and a page shows its tips",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("abilities")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let engine = try SharedLook.HomeRenders.engine()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.themeID = "lagoon"

        func shoot(_ place: AppPlace, _ name: String, width: Int = 1440) throws {
            window.setContentSize(NSSize(width: CGFloat(width), height: 900))
            model.go(place)
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }

        for style in PilotStyle.allCases {
            let name = style.rawValue
            look.style = style
            AppWindowController.applyLook(look, to: window)
            try shoot(AppPlace(.abilities), "window-\(name)")
            // Binds' own bar carries an Abilities button in place of the frame's tabs.
            try shoot(AppPlace(.binds), "binds-bar-\(name)")
            if style == .instrument {
                try shoot(AppPlace(.abilities), "window-\(name)-760", width: 760)
                try shoot(AppPlace(.clipboard), "tips-clipboard-\(name)")
            }
            let page = AbilitiesList(query: "wallpaper") { _ in }
                .styleLayout().background(Color(nsColor: .windowBackgroundColor))
                .styled(.page(.binds)).environment(engine).frame(width: 1000, height: 420).pilotTheme(look: look)
            try writeRender(page, to: dir.appendingPathComponent("search-\(name).png"))
            // Abilities ship minimal (2026-10-10): this fresh home added none, so Bitwarden's wait under More abilities.
            if style == .instrument {
                let more = AbilitiesList(query: "bitwarden") { _ in }
                    .styleLayout().background(Color(nsColor: .windowBackgroundColor))
                    .styled(.page(.binds)).environment(engine).frame(width: 1000, height: 520).pilotTheme(look: look)
                try writeRender(more, to: dir.appendingPathComponent("more-\(name).png"))
            }
        }
        // An ability's settings under its row (page map, 2026-10-17): bound, lazygit and Generate a password are listed on
        // this fresh home, so a search for folder shows Repos and the GIFs under theirs, and one for password Passwords.
        look.style = .instrument
        engine.binds.replace("apps.lazygit", with: Key("l", .shift))
        engine.binds.replace("apps.generatePassword", with: Key("p", .shift))
        for query in ["folder", "password"] {
            let page = AbilitiesList(query: query) { _ in }
                .styleLayout().background(Color(nsColor: .windowBackgroundColor))
                .styled(.page(.binds)).environment(engine).frame(width: 1000, height: 900).pilotTheme(look: look)
            try writeRender(page, to: dir.appendingPathComponent("settings-\(query)-instrument.png"))
        }
    }
}
}
#endif
