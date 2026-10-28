import Foundation
import PilotCore
import Testing

/// Transparency (Sven, 2026-10-08, design round 15): one value maps to each surface role's strength, the contrast floor
/// lifts only the card, the Strength slider's saved value carries over, and only Instrument's tokens take the layers.
@Suite("Transparency")
struct TransparencyTests {
    /// Each role in percent, rounded: ground, sidebar, card, well, raised, free key.
    static func percents(_ l: Layers) -> [Int] {
        [l.ground, l.sidebar, l.card, l.well, l.raised, l.keyFree].map { Int(($0 * 100).rounded()) }
    }

    @Test("The table: every role whole at 0 %, the approved strengths at 50 % and 100 %")
    func table() {
        #expect(Self.percents(Layers(transparency: 0)) == [100, 100, 100, 100, 100, 100])
        #expect(Self.percents(Layers(transparency: 50)) == [71, 78, 68, 63, 59, 54])
        #expect(Self.percents(Layers(transparency: 100)) == [42, 55, 35, 25, 18, 8])
        #expect(Layers(transparency: -20) == .solid && Layers(transparency: 140) == Layers(transparency: 100))
        #expect(Layers.solid.highlight(dark: true) == nil && Layers(transparency: 1).highlight(dark: true) == Paint(0xFFFFFF, 0.04))
    }

    @Test("A saved Strength becomes the Transparency whose ground draws what it drew on Glass, and back for the panels")
    func migration() {
        for (strength, expected) in [(40, 100), (80, 97), (100, 78)] {
            let t = Layers.transparency(strength: strength)
            #expect(t == expected, "\(strength)")
            // Glass's ground then, against the table's at the carried-over Transparency.
            let today = Double(MaterialValues(theme: .standard, material: .glass, strength: strength).windowAlpha)
            let ground = Layers(transparency: t).ground * 100
            if t < 100 {
                #expect(abs(ground - today) <= 1, "\(strength): \(ground) against \(today)")
                #expect(Layers.strength(transparency: t) == strength, "\(strength) back")
            } else {
                // Thinner than the table's least: the least.
                #expect(today < ground && abs(ground - 42) < 0.001, "\(strength)")
            }
        }
        #expect(Layers.transparency(strength: 12) == 100 && Layers.transparency(strength: 140) == 78)
    }

    @Test("On a white wallpaper at 100 %, the floor keeps body text at 4.5 : 1 by lifting the card alone")
    func floorOnWhite() {
        let white: [Double] = [255, 255, 255]
        let table = Layers(transparency: 100)
        for t in PilotTheme.designed {
            let l = Layers(transparency: 100, text: t.text2, card: t.surface, ground: t.ground, spot: white)
            #expect(l.contrast >= MaterialValues.floor, "\(t.id) \(l.contrast)")
            #expect(l.card >= table.card && [l.ground, l.sidebar, l.well, l.raised, l.keyFree]
                == [table.ground, table.sidebar, table.well, table.raised, table.keyFree], "\(t.id) lifted more than the card")
        }
        // Increase contrast: every surface in the window solid, the ground still see-through.
        let t = PilotTheme.standard
        let contrast = Layers(transparency: 100, text: t.text2, card: t.surface, ground: t.ground, spot: white, increaseContrast: true)
        #expect([contrast.card, contrast.well, contrast.raised, contrast.keyFree] == [1, 1, 1, 1] && contrast.ground < 1 && !contrast.lifted)
    }

    @Test("Instrument's tokens take the layers; the signal and the canvas stay whole, soft shadows go, muted text steps up")
    func instrument() throws {
        let tokens = StyleTokens.of(.instrument, theme: .standard)
        #expect(tokens.seeThrough(.solid) == tokens)
        let layers = Layers(transparency: 100)
        let see = tokens.seeThrough(layers)
        let (c, s) = (tokens.colors, see.colors)
        #expect(s.panel == Paint(c.panel.rgb, c.panel.alpha * layers.card) && s.sidebar.alpha == c.sidebar.alpha * layers.sidebar)
        #expect(s.well.alpha == c.well.alpha * layers.well && s.tile.alpha == c.tile.alpha * layers.raised
            && s.keyFree.alpha == c.keyFree.alpha * layers.keyFree)
        #expect(s.canvas == c.canvas && s.accent == c.accent && s.text == c.text && s.text2 == c.text2 && s.hyper == c.hyper)
        // Over glass the muted text steps up one level (Q356).
        #expect(s.text3 == c.text2 && s.text4 == c.text3)
        // A light card's 1 px soft shadow, the one soft shadow Instrument draws.
        let light = StyleTokens.of(.instrument, theme: try #require(PilotTheme.named("porcelain")))
        // No soft shadow over glass (Sven, Q356: "remove those shadows").
        try #require(light.depth.card.shadows.contains { $0.radius > 0 })
        #expect(!light.seeThrough(layers).depth.card.shadows.contains { $0.radius > 0 })
        // The key cap's solid edge is not a soft shadow: it stays.
        #expect(see.depth.key.shadows == tokens.depth.key.shadows)
        #expect(see.depth.card.highlight == Paint(0xFFFFFF, 0.04) && tokens.depth.card.highlight == nil)
        #expect(see.type == tokens.type && see.radii == tokens.radii && see.density == tokens.density)
    }

    @Test("Toybox's tokens come back as they are at any Transparency")
    func toyboxUnchanged() {
        for theme in [PilotTheme.standard, PilotTheme.named("porcelain")!, PilotTheme.named("toybox")!] {
            let tokens = StyleTokens.of(.toybox, theme: theme)
            #expect(tokens.seeThrough(Layers(transparency: 100)) == tokens, "\(theme.id)")
        }
    }
}
