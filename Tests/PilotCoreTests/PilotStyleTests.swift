import Foundation
import PilotCore
import Testing

/// The app's styles as data (story 137, ADR 0008, card agent-bo-95423180): Instrument's and Toybox's tokens equal the
/// approved mockups' CSS custom properties, dark and light (Fixtures/style-mockup-palette.json, read out of each mockup's
/// src/common.css), so a value typed wrong here fails against the page Sven approved.
@Suite("Pilot styles")
struct PilotStyleTests {
    typealias Mockup = [String: [String: [String: String]]]
    static let mockup = try! JSONDecoder().decode(Mockup.self, from: Data(contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().appending(path: "Fixtures/style-mockup-palette.json")))

    /// A CSS colour as a Paint: #RRGGBB, or rgba(r, g, b, a).
    static func paint(_ css: String) throws -> Paint {
        if css.hasPrefix("#") { return Paint(try #require(UInt32(css.dropFirst(), radix: 16))) }
        let parts = css.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        try #require(parts.count == 4, "not a colour: \(css)")
        let rgb = try parts.prefix(3).map { try #require(UInt32($0)) }
        return Paint(rgb[0] << 16 | rgb[1] << 8 | rgb[2], try #require(Double(parts[3])))
    }

    /// Each style's colour role beside the mockup's custom property it is.
    nonisolated(unsafe) static let roles: [PilotStyle: [(KeyPath<StyleColors, Paint>, String)]] = [
        .instrument: [(\.canvas, "--canvas"), (\.sidebar, "--sidebar"), (\.panel, "--panel"), (\.raised, "--raised"), (\.sunken, "--sunken"),
                      (\.line, "--line"), (\.line2, "--line-2"), (\.line3, "--line-3"), (\.text, "--t1"), (\.text2, "--t2"), (\.text3, "--t3"),
                      (\.text4, "--t4"), (\.accent, "--accent"), (\.accentText, "--accent-text"), (\.onAccent, "--accent-ink"),
                      (\.accentSoft, "--accent-soft"), (\.accentLine, "--accent-line"), (\.inverse, "--inverse"), (\.onInverse, "--inverse-ink"),
                      (\.imageOutline, "--img-outline")],
        .toybox: [(\.canvas, "--bg"), (\.sidebar, "--surface-sunk"), (\.panel, "--surface"), (\.raised, "--key"), (\.sunken, "--surface-sunk"),
                  (\.outline, "--line"), (\.text, "--text"), (\.text2, "--text-2"), (\.text3, "--text-3"), (\.accent, "--accent"),
                  (\.accentEdge, "--accent-edge"), (\.onAccent, "--on-accent"), (\.accentSoft, "--m-pilot-soft"), (\.good, "--ok"),
                  (\.key, "--key"), (\.keyFree, "--key-free"), (\.scrim, "--scrim")],
    ]

    @Test("Toybox's colours are its mockup's, dark and light; Instrument's mockup palette stays the reference its theme rule is held to", arguments: [PilotStyle.toybox], [true, false])
    func colours(_ style: PilotStyle, dark: Bool) throws {
        let css = try #require(Self.mockup[style.rawValue]?[dark ? "dark" : "light"])
        let colors = Self.tokens(style, dark: dark).colors
        for (role, name) in try #require(Self.roles[style]) {
            #expect(colors[keyPath: role] == (try Self.paint(try #require(css[name], "\(name) missing"))), "\(style) \(dark) \(name)")
        }
        if style == .toybox {
            let modules = ["apps", "windows", "workspaces", "captures", "system", "pilot"]
            #expect(colors.modules == (try modules.map { try Self.paint(try #require(css["--m-\($0)"])) }))
            #expect(colors.moduleSoft == (try modules.map { try Self.paint(try #require(css["--m-\($0)-soft"])) }))
        }
    }

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

    @Test("Binds' bound keys wear a group colour whose ink reads on it in both styles and every theme, Void's near-white accent included; Instrument's six all different (Q252)", arguments: PilotTheme.designed)
    func groupColours(_ theme: PilotTheme) {
        for style in PilotStyle.allCases {
            let c = StyleTokens.of(style, theme: theme).colors
            #expect(c.groups.count == BindsKeyboard.modules.count, "\(style) \(theme.id)")
            // Toybox's are its theme's module colours, which a theme may repeat.
            if style == .instrument { #expect(Set(c.groups.map(\.rgb)).count == c.groups.count, "\(theme.id)") }
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

    /// A style's mockup tokens: Instrument's own, Toybox's mockup palette (its theme-following tokens are below).
    static func tokens(_ style: PilotStyle, dark: Bool) -> StyleTokens {
        style == .toybox ? .toyboxMockup(dark: dark) : .of(style, theme: .designed[0])
    }

    @Test("Toybox follows the theme: its colours and dark or light are the theme's, its shape the mockup's, its words readable")
    func toyboxFollowsTheme() {
        for theme in PilotTheme.designed where !StyleTokens.toyboxThemes.contains(theme.id) {
            let toybox = StyleTokens.of(.toybox, theme: theme), c = toybox.colors
            #expect(toybox.dark == theme.dark, "\(theme.id): the theme decides dark or light")
            #expect(c.canvas == Paint(theme.ground) && c.sidebar == Paint(theme.sidebar) && c.panel == Paint(theme.surface), "\(theme.id)")
            #expect(c.text == Paint(theme.text) && c.accent == Paint(theme.accent) && c.modules == theme.modules.map { Paint($0) }, "\(theme.id)")
            #expect(toybox.type == StyleTokens.toyboxMockup(dark: theme.dark).type && toybox.depth == StyleTokens.toyboxMockup(dark: theme.dark).depth)
            #expect(Contrast.ratio(c.accentText.rgb, c.panel.rgb) >= 4.5, "\(theme.id): the accent as words")
        }
    }

    @Test("The Toybox themes draw Toybox's mockup palette exactly, dark and light")
    func toyboxThemes() throws {
        for (id, dark) in [("toybox", false), ("toybox-night", true)] {
            let theme = try #require(PilotTheme.named(id))
            #expect(theme.dark == dark)
            #expect(StyleTokens.of(.toybox, theme: theme) == StyleTokens.toyboxMockup(dark: dark), "\(id)")
        }
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

        let toybox = StyleTokens.toyboxMockup(dark: false)
        #expect(toybox.type.display == TypeRole(face: .bundled(StyleTokens.fredoka(600)), size: 44))
        #expect(toybox.type.body == TypeRole(face: .bundled(StyleTokens.nunito(600)), size: 14))
        #expect(toybox.type.mono == TypeRole(face: .bundled(StyleTokens.jetBrainsMono(500)), size: 12))
        #expect([toybox.radii.control, toybox.radii.key, toybox.radii.chip, toybox.radii.card] == [14, 12, 8, 22])
        // Toybox's depth: a 2 px outline and a solid bottom edge in the outline's colour, never a blurred shadow.
        #expect([toybox.depth.card.outline, toybox.depth.card.edge] == [2, 5])
        #expect([toybox.depth.control.outline, toybox.depth.control.edge] == [2, 4])
        #expect(toybox.depth.card.shadows.isEmpty && toybox.depth.pop.shadows.isEmpty)
        // binds.html: the keyboard case's 30 px corner and 7 px edge, its keys' 5 px edge (deeper than a chip's 4), and the
        // case in the Windows grape, a deep indigo in the dark.
        #expect(toybox.radii.board == 30 && [toybox.depth.board.outline, toybox.depth.board.edge] == [2, 7])
        #expect([toybox.depth.boardKey.outline, toybox.depth.boardKey.edge] == [2, 5] && toybox.depth.boardKey.edge > toybox.depth.key.edge)
        #expect(toybox.colors.board == toybox.colors.modules[1])
        #expect(StyleTokens.toyboxMockup(dark: true).colors.board == Paint(0x3A3270))
        #expect(toybox.density.row > instrument.density.row, "Toybox is the roomier of the two")
    }

    @Test("Every style has a sidebar tile colour per page; Toybox's are all different, the mockup's where its pages kept them")
    func pageTiles() {
        for style in PilotStyle.allCases {
            let tiles = StyleTokens.of(style, theme: .designed[0]).colors.pageTiles
            #expect(tiles.count == AppPage.allCases.count, "\(style)")
        }
        let toybox = StyleTokens.toyboxMockup(dark: true).colors
        #expect(Set(toybox.pageTiles.map(\.rgb)).count == AppPage.allCases.count, "two pages share a tile colour")
        // Home sun, Binds grape, Workspaces mint, Menu bar sky, as src/common.js's NAV draws them; Menu took Stats' pink (C3).
        let tile = { (page: AppPage) in toybox.pageTiles[AppPage.allCases.firstIndex(of: page)!] }
        #expect([tile(.home), tile(.binds), tile(.workspaces), tile(.menuBar), tile(.menu)]
                == [toybox.modules[5], toybox.modules[1], toybox.modules[2], toybox.modules[0], toybox.modules[4]])
        #expect(toybox.pageTiles == StyleTokens.toyboxMockup(dark: false).colors.pageTiles, "the tiles are the same candy in dark and light")
    }

    @Test("Two styles; a saved Current (removed 2026-10-11, Sven) or anything unknown loads as Instrument, the default")
    func saved() {
        #expect(PilotStyle.allCases == [.instrument, .toybox])
        #expect(PilotStyle(saved: "current") == .instrument && PilotStyle(saved: nil) == .instrument && PilotStyle(saved: "nope") == .instrument)
        #expect(PilotStyle(saved: "instrument") == .instrument && PilotStyle(saved: "toybox") == .toybox)
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

    @Test("Every page is a surface, and the window's frame, eight panels, bars and popovers, onboarding and an extension's detail")
    func surfaces() {
        #expect(StyleSurface.allCases.count == AppPage.allCases.count + 11)
    }

    @Test("The bundled faces are the five OFL files the styles draw with")
    func faces() {
        #expect(Set(StyleTokens.faces.map(\.file)) == ["Geist", "GeistMono", "Fredoka", "Nunito", "JetBrainsMono"])
    }
}
