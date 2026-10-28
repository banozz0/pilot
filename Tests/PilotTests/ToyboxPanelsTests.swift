import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The panels in Toybox (card agent-bo-95423182, batch 5): each panel draws Toybox, apart from Instrument, following the
/// theme (Toybox light, Toybox Night dark); HUD.makePanel puts a Toybox panel on its pop block with no blur and no window
/// shadow, while the menu keeps the block it draws itself.
extension SharedLook {
@MainActor
@Suite("Toybox panels")
struct ToyboxPanelsTests {
    typealias Case = InstrumentPanelsTests.Case

    /// Instrument's panel cases restyled in Toybox, with the top bar's dropdown and readings and Binds' bind editor.
    nonisolated static let cases = (InstrumentPanelsTests.cases + InstrumentPanelsTests.barCases).filter {
        ["tip", "rescue", "alert", "quick AI", "notes", "overlay", "clipboard", "readings", "dropdown", "bind editor"].contains($0.name)
    }

    @Test("Each panel draws Toybox, apart from Instrument, in the Toybox and Toybox Night themes", arguments: cases)
    func drawn(_ c: Case) throws {
        let (look, _) = LookPageTests().look()
        DisplayFaces.directory = LookThemeTests.fonts
        let style = StyleTests()
        func draw() throws -> Data { try style.pixels(c.view().styled(c.surface, look: look), look: look) }
        look.themeID = "toybox"
        look.style = .instrument
        let instrument = try draw()
        look.style = .toybox
        let toybox = try draw()
        #expect(toybox != instrument, "\(c.name): Toybox drew Instrument's")
        look.themeID = "toybox-night"
        #expect(try draw() != toybox, "\(c.name): Toybox did not follow the theme to Toybox Night")
    }

    @Test("A Toybox panel sits on its pop block: no margins, no window shadow, the theme's dark or light; the menu keeps its own block, shadowless")
    func chrome() throws {
        let (look, _) = LookPageTests().look()
        look.style = .toybox
        for (theme, dark) in [("toybox", false), ("toybox-night", true)] {
            look.themeID = theme
            let tip = HUD.makePanel(TipView(text: "Saved"), surface: .hud, look: look)
            defer { tip.close() }
            #expect(tip.margins.top == 0 && tip.margins.left == 0 && tip.margins.bottom == 0, "Toybox's pop block has no blur to hold")
            #expect(!tip.hasShadow, "the window server's shadow would blur the ink edge")
            #expect(tip.appearance?.name == (dark ? .darkAqua : .aqua), "\(theme): the panel left the theme's dark or light")
            let menu = HUD.makePanel(Text("menu"), surface: .menu, look: look)
            defer { menu.close() }
            #expect(!menu.hasShadow, "the menu draws no window shadow round its own block (ToyMenuFrame; B5, Sven 2026-10-09)")
        }
    }
}
}
