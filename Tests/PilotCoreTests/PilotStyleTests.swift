import Foundation
import PilotCore
import Testing

/// The app's style as data (story 137, ADR 0008, card agent-bo-95423180): Instrument's tokens, from the theme, against the
/// approved mockup's type, corners and depth.
@Suite("Pilot styles")
struct PilotStyleTests {
    @Test("Instrument takes every colour from the theme, dark or light as the theme is, with one signal: the accent for Hyper, live and selected; no status or module colour; the sidebar a step off the ground (coordinator for Sven, 2026-10-08)", arguments: PilotTheme.designed)
    func instrumentFromTheme(_ theme: PilotTheme) {
        let tokens = StyleTokens.of(.instrument, theme: theme), c = tokens.colors
        #expect(tokens.dark == theme.dark, "\(theme.id): the style's dark or light is the theme's")
        #expect(c == StyleTokens.instrumentColors(theme))
        #expect(c.canvas == Paint(theme.ground) && c.panel == Paint(theme.surface) && c.raised == Paint(theme.raised))
        #expect(c.text == Paint(theme.text) && c.text2 == Paint(theme.text2) && c.text3 == Paint(theme.text3))
        #expect(c.accent == Paint(theme.accent) && c.accentText == Paint(theme.accentText) && c.onAccent == Paint(theme.onAccent))
        #expect([c.good, c.warn, c.problem, c.accentEdge].allSatisfy { $0 == c.accent }, "\(theme.id): a status colour beside the signal")
        #expect(Set(c.modules.map(\.rgb)) == [theme.text2] && Set(c.pageTiles.map(\.rgb)) == [theme.text2], "\(theme.id): a module colour")
        #expect(c.hyper.rgb == theme.accent && c.hyper.alpha < 1 && c.onHyper == c.accentText, "\(theme.id): Hyper's cap is the accent soft")
        #expect(c.key == c.raised && c.keyFree == c.sunken)
        #expect(c.sidebar != c.canvas && c.sunken != c.canvas, "\(theme.id): the sidebar or well is the ground itself")
    }

    @Test("Binds' bound keys wear a group colour whose ink reads on it in Instrument and every theme, Void's near-white accent included; Instrument's six all different (Q252)", arguments: PilotTheme.designed)
    func groupColours(_ theme: PilotTheme) {
        for style in PilotStyle.allCases {
            let c = StyleTokens.of(style, theme: theme).colors
            #expect(c.groups.count == BindsKeyboard.modules.count, "\(style) \(theme.id)")
            #expect(Set(c.groups.map(\.rgb)).count == c.groups.count, "\(theme.id)")
            for fill in c.groups {
                let second = Contrast.mix(Contrast.rgb(c.onGroup2.rgb), Contrast.rgb(fill.rgb), c.onGroup2.alpha)
                #expect(Contrast.ratio(c.onGroup.rgb, fill.rgb) >= 4.5, "\(style) \(theme.id) name on \(String(fill.rgb, radix: 16))")
                #expect(Contrast.ratio(second, Contrast.rgb(fill.rgb)) >= 3, "\(style) \(theme.id) legend on \(String(fill.rgb, radix: 16))")
            }
        }
    }

    @Test("A theme whose sidebar is its ground gets one a step darker")
    func instrumentSidebarStep() throws {
        let base = try #require(PilotTheme.named("tokyo-night"))
        let flat = PilotTheme(id: "flat", name: "Flat", tagline: "", source: "", dark: true, ground: base.ground, sidebar: base.ground,
                              surface: base.surface, raised: base.raised, line: base.line, line2: base.line2, text: base.text,
                              text2: base.text2, text3: base.text3, accent: base.accent, second: base.second, third: base.third,
                              good: base.good, amber: base.amber, problem: base.problem, graphs: base.graphs, focus: base.focus,
                              radius: base.radius, face: base.face, wallpaper: base.wallpaper)
        let sidebar = StyleTokens.instrumentColors(flat).sidebar
        #expect(sidebar != Paint(base.ground) && Contrast.luminance(Contrast.rgb(sidebar.rgb)) < Contrast.luminance(Contrast.rgb(base.ground)))
    }

    @Test("On a pure-black ground the sunk well and a flat sidebar step toward white, under the panel (Void, 2026-10-08)")
    func instrumentNearBlackWell() throws {
        let void = try #require(PilotTheme.named("void"))
        let c = StyleTokens.instrumentColors(void), lum = { (p: Paint) in Contrast.luminance(Contrast.rgb(p.rgb)) }
        #expect(lum(c.sunken) > lum(c.canvas) && lum(c.sunken) < lum(c.panel), "the well reads between the ground and the panel")
        let flat = PilotTheme(id: "flat", name: "Flat", tagline: "", source: "", dark: true, ground: void.ground, sidebar: void.ground,
                              surface: void.surface, raised: void.raised, line: void.line, line2: void.line2, text: void.text,
                              text2: void.text2, text3: void.text3, accent: void.accent, second: void.second, third: void.third,
                              good: void.good, amber: void.amber, problem: void.problem, graphs: void.graphs, focus: void.focus,
                              radius: void.radius, face: void.face, wallpaper: void.wallpaper)
        let sidebar = StyleTokens.instrumentColors(flat).sidebar
        #expect(lum(sidebar) > lum(c.canvas) && lum(sidebar) < lum(c.panel))
    }

    /// A style's mockup tokens: Instrument's own.
    static func tokens(_ style: PilotStyle, dark: Bool) -> StyleTokens {
        .of(style, theme: .designed[0])
    }

    @Test("Each style's type, corners, depth and density are the mockups'")
    func shape() {
        let instrument = StyleTokens.of(.instrument, theme: .designed[0])
        #expect(instrument.type.body == TypeRole(face: .bundled(StyleTokens.geist(400)), size: 13))
        #expect(instrument.type.eyebrow == TypeRole(face: .bundled(StyleTokens.geistMono(500)), size: 10.5, tracking: 0.08, uppercase: true))
        #expect(instrument.type.display == TypeRole(face: .bundled(StyleTokens.geist(500)), size: 38, tracking: -0.03))
        // menu.html's search and row titles.
        #expect(instrument.type.search == TypeRole(face: .bundled(StyleTokens.geist(450)), size: 18, tracking: -0.01))
        #expect(instrument.type.row == TypeRole(face: .bundled(StyleTokens.geist(500)), size: 13.5))
        // topbar.html's reading labels, the app's name, the clock and the focus countdown.
        #expect(instrument.type.barLabel == TypeRole(face: .bundled(StyleTokens.geistMono(500)), size: 9.5, tracking: 0.06, uppercase: true))
        #expect(instrument.type.barStrong == TypeRole(face: .bundled(StyleTokens.geist(600)), size: 12))
        #expect(instrument.type.barTime == TypeRole(face: .bundled(StyleTokens.geistMono(500)), size: 12))
        #expect([instrument.radii.control, instrument.radii.card, instrument.radii.pop] == [6, 10, 14])
        // Instrument's depth is one hairline ring, never an outline or a solid edge.
        #expect(instrument.depth.card.outline == 0 && instrument.depth.card.edge == 0 && instrument.depth.card.ring != nil)
    }

    @Test("Every style has a sidebar tile colour per page")
    func pageTiles() {
        for style in PilotStyle.allCases {
            let tiles = StyleTokens.of(style, theme: .designed[0]).colors.pageTiles
            #expect(tiles.count == AppPage.allCases.count, "\(style)")
        }
    }

    @Test("One style; a saved Current (removed 2026-10-11, Sven), Toybox (removed 2026-11-19) or anything unknown loads as Instrument, the default")
    func saved() {
        #expect(PilotStyle.allCases == [.instrument])
        #expect(PilotStyle(saved: "current") == .instrument && PilotStyle(saved: nil) == .instrument && PilotStyle(saved: "nope") == .instrument)
        #expect(PilotStyle(saved: "instrument") == .instrument && PilotStyle(saved: "toybox") == .instrument)
    }

    @Test("Every style's body text reads at 4.5:1 on its panel and canvas")
    func contrast() {
        for style in PilotStyle.allCases {
            for dark in [true, false] {
                let c = Self.tokens(style, dark: dark).colors
                for ground in [c.panel, c.canvas] {
                    #expect(Contrast.ratio(c.text.rgb, ground.rgb) >= 4.5, "\(style) \(dark)")
                    #expect(Contrast.ratio(c.text2.rgb, ground.rgb) >= 4.5, "\(style) \(dark) second text")
                }
            }
        }
    }

    @Test("The app window and the menu draw one step bigger (C3, Sven 2026-10-10): every size, row and control of theirs, nothing else")
    func scale() {
        #expect(PilotStyle.scale == 14.0 / 13.0)
        for surface in StyleSurface.allCases {
            let big: Bool = switch surface { case .page, .window, .menu, .extensionDetail: true; default: false }
            #expect(surface.scale == (big ? PilotStyle.scale : 1), "\(surface)")
        }
        for style in PilotStyle.allCases {
            let tokens = StyleTokens.of(style, theme: .standard), big = tokens.scaled(PilotStyle.scale)
            #expect(tokens.scale == 1 && big.scale == PilotStyle.scale && tokens.scaled(1) == tokens)
            // Body text a point up, to the nearest half point, and every role with it; the colours and corners stay.
            #expect(big.type.body.size == ((tokens.type.body.size * PilotStyle.scale) * 2).rounded() / 2 && big.type.body.size > tokens.type.body.size)
            #expect(big.type.pageTitle.size > tokens.type.pageTitle.size && big.type.key.size > tokens.type.key.size)
            #expect(big.density.row == (tokens.density.row * PilotStyle.scale).rounded() && big.density.control > tokens.density.control)
            #expect(big.colors == tokens.colors && big.radii == tokens.radii && big.depth == tokens.depth)
        }
        #expect(StyleTokens.of(.instrument, theme: .standard).scaled(PilotStyle.scale).type.body.size == 14)
    }

    @Test("Every page is a surface, and the window's frame, eight panels, bars, popovers and drops, onboarding and an extension's detail")
    func surfaces() {
        #expect(StyleSurface.allCases.count == AppPage.allCases.count + 12)
    }

    @Test("The bundled faces are the five OFL files the styles draw with")
    func faces() {
        #expect(Set(StyleTokens.faces.map(\.file)) == ["Geist", "GeistMono", "Fredoka", "Nunito", "JetBrainsMono"])
    }
}
