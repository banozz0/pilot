import CoreGraphics
import Foundation
import Testing
@testable import PilotCore

/// Desktop icons out of captures (Q189, the survey's item 5): Finder's icon-level windows only, never the wallpaper or a
/// Finder window; off by default and saved like the other capture settings.
@Suite("Desktop icons")
struct DesktopIconsTests {
    @Test("Only Finder's windows at the desktop-icon level hold the icons")
    func rule() {
        let icon = Int(CGWindowLevelForKey(.desktopIconWindow)), desktop = Int(CGWindowLevelForKey(.desktopWindow))
        #expect(DesktopIcons.holdsIcons(bundle: "com.apple.finder", layer: icon))
        #expect(!DesktopIcons.holdsIcons(bundle: "com.apple.finder", layer: 0), "a Finder window")
        #expect(!DesktopIcons.holdsIcons(bundle: "com.apple.WindowManager", layer: desktop), "the wallpaper")
        #expect(!DesktopIcons.holdsIcons(bundle: "dev.banozz.pilot", layer: icon + 1))
    }

    @Test("Off by default; on, it is saved, and settings from before read it as off")
    func setting() throws {
        #expect(!CaptureSettings().hideDesktopIcons)
        let saved = try JSONDecoder().decode(CaptureSettings.self, from: JSONEncoder().encode(CaptureSettings(hideDesktopIcons: true)))
        #expect(saved.hideDesktopIcons)
        #expect(try !JSONDecoder().decode(CaptureSettings.self, from: Data(#"{"engine":"pilot"}"#.utf8)).hideDesktopIcons)
    }
}
