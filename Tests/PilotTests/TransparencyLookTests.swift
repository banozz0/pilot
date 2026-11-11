import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Transparency on the theme's roles (Sven, 2026-10-08, design round 15): at the default settings (Solid) and at 0 %
/// every layered role is exactly the theme's colour; see-through, the roles take their layers.
extension SharedLook {
@MainActor
@Suite("Transparency look")
struct TransparencyLookTests {
    /// Every layered role against the theme's own colour, as today's Theme returned it, resolved in `env`.
    static func today(_ c: ThemeColors, in env: EnvironmentValues = EnvironmentValues()) -> Bool {
        let same = { (a: Color, b: Color) in a.resolve(in: env) == b.resolve(in: env) }
        return same(Theme.selected, c.raised) && same(Theme.keyFill, c.keyFill) && same(Theme.cardFill, c.surface)
            && Theme.windowFill(c.ground) == c.ground
    }

    /// The environment styled(_:) hands `surface`.
    static func environment(_ surface: StyleSurface, _ look: Look) -> EnvironmentValues {
        var env = EnvironmentValues()
        env.windowLayers = surface.layers(look)
        return env
    }

    @Test("The theme's roles at the default settings and at Transparency 0 % are exactly its colours; see-through, they take their layers")
    func rolesKeepTheirColours() {
        let look = Look.shared
        let saved = (look.glass, look.transparency, look.style)
        defer { look.glass = saved.0; look.transparency = saved.1; look.style = saved.2 }
        look.style = .instrument
        look.glass = false
        for id in ["tokyo-night", "porcelain"] {
            look.themeID = id
            #expect(Self.today(look.colors, in: Self.environment(.window, look)) && Self.today(look.colors), "\(id) solid")
        }
        look.themeID = PilotTheme.defaultID
        look.glass = true
        look.transparency = 0
        #expect(look.effectiveMaterial == .solid && Self.today(look.colors, in: Self.environment(.window, look)), "glass at 0 %")
        look.transparency = 100
        let layers = look.layers, window = Self.environment(.page(.home), look)
        #expect(Theme.selected.resolve(in: window) == look.colors.raised.opacity(layers.raised).resolve(in: window))
        #expect(Theme.cardFill.resolve(in: window) == look.colors.surface.opacity(layers.card).resolve(in: window))
        #expect(layers.highlight(dark: look.theme.dark) != nil && Theme.windowFill(look.colors.ground) == .clear)
        // The signal stays whole.
        #expect(Theme.accent == look.colors.accent && Theme.text == look.colors.text)
    }

    @Test("At Transparency 100 % the window and the glass panels (Q356) go see-through; the bar's and the other panels' roles stay whole")
    func seeThroughStaysInTheWindow() {
        let look = Look.shared
        let saved = (look.glass, look.transparency, look.style)
        defer { look.glass = saved.0; look.transparency = saved.1; look.style = saved.2 }
        (look.style, look.glass, look.transparency) = (.instrument, true, 100)
        let c = look.colors, window = Self.environment(.window, look)
        #expect(window.windowLayers == look.layers && Self.environment(.page(.workspaces), look).windowLayers == look.layers)
        // Glass everywhere (Sven, Q356): the menu, clipboard, notes and Quick AI take the window's layers on Glass.
        for surface in Look.glassPanels { #expect(Self.environment(surface, look).windowLayers == look.layers, "\(surface)") }
        for surface in [StyleSurface.topBar, .hud, .overlay, .onboarding] {
            let panel = Self.environment(surface, look)
            #expect(panel.windowLayers == nil, "\(surface)")
            #expect(Theme.selected.resolve(in: panel) == c.raised.resolve(in: panel) && Theme.keyFill.resolve(in: panel) == c.keyFill.resolve(in: panel))
            // A block keeps the window material's surface strength, as before Transparency.
            #expect(Theme.cardFill.resolve(in: panel) == c.surface.opacity(Double(look.materialValues.surfaceAlpha) / 100).resolve(in: panel))
        }
        #expect(Theme.selected.resolve(in: window).opacity < c.raised.resolve(in: window).opacity)
        #expect(Theme.keyFill.resolve(in: window).opacity < c.keyFill.resolve(in: window).opacity)
    }

    @Test("A popover, sheet or popup in the window draws solid; a see-through well and tile take the style's own")
    func floatingAndWorkspaces() {
        let look = Look.shared
        let saved = (look.glass, look.transparency, look.style)
        defer { look.glass = saved.0; look.transparency = saved.1; look.style = saved.2 }
        (look.style, look.glass, look.transparency) = (.instrument, true, 100)
        let solid = StyleTokens.of(.instrument, theme: look.theme)
        let seeThrough = solid.seeThrough(look.layers)
        #expect(seeThrough != solid && FloatingSurface.solid(seeThrough, layers: look.layers, look: look) == solid)
        #expect(Ink(style: seeThrough).well == seeThrough.color(\.well) && Ink(style: seeThrough).tile == seeThrough.color(\.tile))
    }
}
}
