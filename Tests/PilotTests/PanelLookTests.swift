import AppKit
import Clipboard
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Every panel Pilot shows (menu, picker, clipboard, overlay, each HUD) is built by HUD.makePanel, so the panels wear
/// the style from there (cards agent-bo-95422727, agent-bo-95422895): its theme's light or dark, on its own opaque face,
/// whatever the Mac's own appearance is.
/// Suites that preview a theme on the shared look run one at a time, so none sees another's theme.
@MainActor
@Suite("Shared look", .serialized)
enum SharedLook {}

extension SharedLook {
@MainActor
@Suite("Panel look")
struct PanelLookTests {
    /// A look of the test's own, defaults included, so no panel test reads another's settings.
    static func look() -> Look {
        Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), defaults: LookTests.defaults())
    }

    @Test("A panel draws its style's own face on an opaque backdrop, Glass on or off, in both styles")
    func backdrop() throws {
        testApp()
        let look = Self.look()
        func effect() throws -> NSView? {
            let panel = HUD.makePanel(Color.clear.frame(width: 120, height: 60), look: look)
            defer { panel.close() }
            return try #require(panel.contentView as? MaterialBackdrop).effect
        }
        for style in PilotStyle.allCases {
            look.style = style
            look.glass = false
            #expect(try effect() == nil, "\(style)")
            look.glass = true
            #expect(try effect() == nil, "\(style) over Glass")
        }
    }

    @Test("A colour clip's preview spells it the menu colour card's five ways")
    func colourValues() {
        // The menu's colour card's five (menu Rail and Classic T10).
        #expect(StoredClip.colourValues(0x4FD6C6) == ColourAnswer.formats(0x4FD6C6))
        #expect(StoredClip.colourValues(0x808080).prefix(3) == ["#808080", "rgb(128, 128, 128)", "hsl(0, 0%, 50%)"])
        #expect(StoredClip.colourValues(0xFF0000).count == 5)
    }

    @Test("A panel follows the theme's light or dark whatever the Mac's appearance")
    func appearance() {
        testApp()
        let look = Self.look()
        let dark = HUD.makePanel(Color.clear.frame(width: 120, height: 60), look: look)
        defer { dark.close() }
        #expect(dark.appearance?.name == .darkAqua)
        look.pick("workshop")
        let light = HUD.makePanel(Color.clear.frame(width: 120, height: 60), look: look)
        defer { light.close() }
        #expect(light.appearance?.name == .aqua)
    }

}
}
