#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Story 154: Look's Apps show as is saved, every list's app row follows it, and the menu (Apps and Remove › Apps in each
/// style) and the Activity page render in all three modes. The renders are opt-in like the others:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter AppsShowAsRenders`
@MainActor
@Suite("Apps show as renders")
struct AppsShowAsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Apps show as is saved and read back, Icon and title on a fresh install")
    func saved() {
        let defaults = LookTests.defaults()
        let look = Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), defaults: defaults)
        #expect(look.appsShowAs == .both)
        look.appsShowAs = .icon
        #expect(Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), defaults: defaults).appsShowAs == .icon)
        defaults.set("bogus", forKey: "look.appsShowAs")
        #expect(Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), defaults: defaults).appsShowAs == .both)
    }

    @Test("An app's label is its icon alone, its name alone or both, as the setting says")
    func label() {
        testApp()
        let saved = Look.shared.appsShowAs
        defer { Look.shared.appsShowAs = saved }
        func width(_ mode: AppsShowAs) -> CGFloat {
            Look.shared.appsShowAs = mode
            return NSHostingView(rootView: AppLabel(name: "A long app name", bundle: "com.apple.finder", size: 18).fixedSize()).fittingSize.width
        }
        let icon = width(.icon), title = width(.title), both = width(.both)
        #expect(icon == 18, "Icon only is the icon alone")
        #expect(title > 60 && both == title + 18 + 8, "Icon and title is the icon, the gap and the name: \(title) \(both)")
    }

    @Test("The menu and the Activity page render in all three modes", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        let root = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("apps-show-as")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let saved = (look.style, look.appsShowAs, look.glass)
        defer { DisplayFaces.directory = faces; (look.style, look.appsShowAs, look.glass) = saved }
        look.glass = false
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }
        let engine = try SharedLook.HomeRenders.engine()
        ActivityMonitor.shared.seed(SharedLook.ActivityRenders.seeded, quitting: [])

        let apps = [("Finder", "com.apple.finder"), ("Safari", "com.apple.Safari"), ("TextEdit", "com.apple.TextEdit"),
                    ("Notes", "com.apple.Notes"), ("System Settings", "com.apple.systempreferences")]
            .map { MenuEntry(title: $0.0, target: .app($0.1), home: .apps) }
        for mode in AppsShowAs.allCases {
            look.appsShowAs = mode
            for style in PilotStyle.allCases {
                look.style = style
                try SharedLook.InstrumentMenuRenders.render(MenuView(model: MenuModel(nav: MenuNavigator(entries: apps, branch: .apps))),
                                                            "menu-apps-\(style.rawValue)-\(mode.rawValue)", in: root)
            }
            look.style = .instrument
            var remove = SharedLook.MenuBrowseRenders.remove()
            _ = remove.handle(.return)
            try SharedLook.InstrumentMenuRenders.render(MenuView(model: MenuModel(nav: remove)), "menu-remove-apps-\(mode.rawValue)", in: root)
            let page = ActivityPage(onScreen: false, start: SharedLook.ActivityRenders.states).styleLayout().background(Theme.background)
                .styled(.page(.activity)).environment(engine).frame(width: 1000, height: 1200).pilotTheme(look: look)
            try RestyledRenders.writeTrimmed(rendered(page), from: 0, to: root.appendingPathComponent("page-activity-\(mode.rawValue).png"))
        }
    }
}
}
#endif
