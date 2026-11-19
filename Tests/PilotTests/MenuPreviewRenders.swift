#if DEBUG
import AppKit
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Launcher › Your menu with fourteen rows switched on, Files, Notes, Activity and Stats among them (Sven on build 2503: "Hyper+Space
/// shows" stopped at Extensions, the tenth): the preview lists every one in order, growing beside the list. The page as
/// Sven saw it, 1560 wide, three columns. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter MenuPreviewRenders`
extension SharedLook {
@MainActor
@Suite("Menu preview renders")
struct MenuPreviewRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Your menu's preview lists every row switched on", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try ClockRenders.dir("menu-preview")
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let was = (look.style, look.themeID, look.glass)
        defer { (look.style, look.themeID, look.glass) = was }
        (look.style, look.themeID, look.glass) = (.instrument, "dracula", false)
        let settings = MenuRootSettings.shared, saved = settings.root
        defer { settings.root = saved }
        for extra in ["files", "notes", "activity"] { settings.root.show(extra: extra, true) }
        let rows = settings.root.shownRows()
        print("PREVIEW rows \(rows.count): " + rows.map(\.title).joined(separator: ", "))
        let page = MenuPage(section: nil).frame(width: 1560, height: 1000).pilotTheme(look: look).background(Theme.background)
        try writeRender(page, to: dir.appendingPathComponent("your-menu-1560.png"), wait: 1.2)
    }
}
}
#endif
