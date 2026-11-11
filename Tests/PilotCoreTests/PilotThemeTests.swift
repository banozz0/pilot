import Foundation
import PilotCore
import Testing

/// Pilot's themes as data. Design round 15 (artifact Eh93LMpjwRxNRWnc8VHN47, Sven 2026-10-08) replaced round 4's twelve with
/// eight new ones beside Toybox's two: their roles equal that artifact's table (Fixtures/design-round15-themes.json). The
/// maths stay round 4's (card agent-bo-95422890, artifact 5sh21HWjCjsWYAwWKTibcE): the roles applyTheme() derives and
/// matVals()'s material floor, checked on round 4's table run through that artifact's own functions in node
/// (Fixtures/design-round4-themes.json), so a formula typed wrong here fails against the page Sven approved.
@Suite("Pilot themes")
struct PilotThemeTests {
    struct Row: Decodable {
        let id, name, sub, src: String
        let dark: Int
        let g, g2, s, s2, l, l2, t, t2, t3, a, a2, a3, ok, wn, bd: String
        let c: [String]
        let sel: String?
        let bt: String
        let r: Double
        let worst: [Worst]
        let derived: Derived
        let mats: [String: Mat]
        enum Worst: Decodable { case colour(String), amount(Double)
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .colour(s) } else { self = .amount(try c.decode(Double.self)) }
            }
        }
        struct Derived: Decodable { let ai, al, kb: String }
        struct Mat: Decodable { let ma, ms: Int; let cr: Double; let raised: Bool }
    }

    /// Design round 15's table: ground, sidebar, surface, raised, text and the three accents of each new theme.
    struct Round15: Decodable { let id, name, tagline, source, ground, sidebar, surface, raised, text, accent, second, third: String }

    static func fixture<T: Decodable>(_ name: String) -> T {
        try! JSONDecoder().decode(T.self, from: Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)")))
    }
    static let rows: [Row] = fixture("design-round4-themes.json")
    static let round15: [Round15] = fixture("design-round15-themes.json")
    static let omarchy = try! OmarchyThemes.parse(Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../Packaging/themes.json")))

    static func hex(_ s: String) -> UInt32 { Contrast.hex(s) }

    /// A round 4 theme made from its row, for the maths: its roles, selection, focus, radius and wallpaper spot.
    static func made(_ row: Row) -> PilotTheme {
        guard case .colour(let glow) = row.worst[0], case .amount(let amount) = row.worst[1], case .colour(let base) = row.worst[2] else { fatalError(row.id) }
        return PilotTheme(id: row.id, name: row.name, tagline: row.sub, source: row.src, dark: row.dark == 1, ground: hex(row.g), sidebar: hex(row.g2),
                          surface: hex(row.s), raised: hex(row.s2), line: hex(row.l), line2: hex(row.l2), text: hex(row.t), text2: hex(row.t2),
                          text3: hex(row.t3), accent: hex(row.a), second: hex(row.a2), third: hex(row.a3), good: hex(row.ok), amber: hex(row.wn),
                          problem: hex(row.bd), graphs: row.c.map(hex), selection: row.sel == nil ? nil : Paint(0xD0A215, 0.24),
                          focus: FocusBorder(rawValue: row.bt)!, radius: row.r, face: .system,
                          wallpaper: WallpaperSpot(glow: hex(glow), amount: amount, base: hex(base)))
    }

    @Test("The line-up of 18 in Sven's order, Tokyo Night the default, the added ten first, then Void, Garnet, the four light ones, Toybox Night and Toybox; thirteen dark, five light")
    func designed() {
        #expect(PilotTheme.designed.map(\.id) == ["tokyo-night", "jade", "catppuccin", "gruvbox", "matte-black", "retro-82", "nord", "akane", "ayu-dark", "dracula",
                                                  "void", "garnet", "porcelain", "folio", "celadon", "wisteria", "toybox-night", "toybox"])
        #expect(PilotTheme.defaultID == "tokyo-night" && PilotTheme.standard.id == "tokyo-night")
        #expect(PilotTheme.designed.filter(\.dark).count == 13)
        #expect(PilotTheme.named("void")?.name == "Void" && PilotTheme.named("nope") == nil)
        for retired in PilotTheme.retired.keys { #expect(PilotTheme.named(retired) == nil, "\(retired) is gone") }
    }

    @Test("Every new theme's roles equal round 15's table; every theme's module colours are its accents")
    func roles() throws {
        // Round 15's that the line-up of 18 kept (Void, Garnet, Porcelain); its table stays as it was.
        for row in Self.round15 where PilotTheme.named(row.id) != nil {
            let t = try #require(PilotTheme.named(row.id), "\(row.id)")
            #expect(t.name == row.name && t.tagline == row.tagline && t.source == row.source, "\(row.id)")
            let pairs: [(UInt32, String)] = [(t.ground, row.ground), (t.sidebar, row.sidebar), (t.surface, row.surface), (t.raised, row.raised),
                                             (t.text, row.text), (t.accent, row.accent), (t.second, row.second), (t.third, row.third)]
            for (i, (have, want)) in pairs.enumerated() { #expect(have == Self.hex(want), "\(row.id) role \(i)") }
        }
        for t in PilotTheme.designed { #expect(t.modules == [t.accent, t.second, t.third, t.good, t.amber, t.problem], "\(t.id) modules") }
    }

    @Test("Each theme starts from an Omarchy palette Pilot ships, which Ghostty takes when it is picked")
    func sources() {
        for t in PilotTheme.designed { #expect(Self.omarchy.named(t.source) != nil, "\(t.id) starts from \(t.source)") }
    }

    @Test("Every theme reads: body text at 4.5:1 on its surface and ground, and the material floor holds in Solid and Glass")
    func reads() {
        for t in PilotTheme.designed {
            for ground in [t.surface, t.ground] {
                #expect(Contrast.ratio(t.text, ground) >= 4.5 && Contrast.ratio(t.text2, ground) >= 4.5, "\(t.id)")
            }
            for material in WindowMaterial.allCases {
                for strength in [40, 80, 100] {
                    let have = MaterialValues(theme: t, material: material, strength: strength)
                    #expect(have.contrast >= 4.5 || have.surfaceAlpha == 100, "\(t.id) \(material) \(strength) floor")
                }
            }
        }
    }

    @Test("A saved theme id from round 4 or round 15 becomes the kept theme closest to it; an unknown one the default")
    func migration() {
        // Sven's maps: round 4's (2026-10-08) carried to their final theme, and the line-up of 18's (2026-11-11).
        #expect(PilotTheme.retired == ["nightwatch": "ayu-dark", "ukiyo": "ayu-dark", "fjord": "ayu-dark", "teahouse": "ayu-dark",
                                       "understory": "ayu-dark", "crema": "garnet", "hearth": "void", "nocturne": "void",
                                       "boardwalk": "dracula", "graphite": "void", "paper": "folio", "petal": "porcelain",
                                       "lagoon": "ayu-dark", "orchid": "dracula", "phosphor": "ayu-dark", "cyanotype": "retro-82",
                                       "verdigris": "ayu-dark", "workshop": "folio", "cinder": "matte-black", "dusk": "void"])
        for (old, new) in PilotTheme.retired { #expect(PilotTheme.current(old) == new && PilotTheme.named(new) != nil, "\(old)") }
        for t in PilotTheme.designed { #expect(PilotTheme.current(t.id) == t.id) }
        #expect(PilotTheme.current(nil) == "tokyo-night" && PilotTheme.current("") == "tokyo-night" && PilotTheme.current("nope") == "tokyo-night")
        // A saved stock palette moves the same way; a pack or a kept id stays as it is.
        #expect(ThemeNativePalette.stock("lagoon").current == .stock("ayu-dark") && ThemeNativePalette.stock("void").current == .stock("void"))
    }

    @Test("Derived roles equal applyTheme()'s: text on the accent, accent text, key fill, selection")
    func derived() {
        for row in Self.rows {
            let t = Self.made(row)
            #expect(t.onAccent == Self.hex(row.derived.ai), "\(row.id) on accent")
            #expect(t.accentText == Self.hex(row.derived.al), "\(row.id) accent text")
            #expect(t.keyFill == Self.hex(row.derived.kb), "\(row.id) key fill")
            #expect(t.windowLine == (t.dark ? Paint(0xFFFFFF, 0.09) : Paint(0x000000, 0.12)), "\(row.id) window line")
            #expect(t.keyHighlight == (t.dark ? Paint(0xFFFFFF, 0.07) : Paint(0xFFFFFF, 0.9)), "\(row.id) key highlight")
            if let sel = row.sel {
                // Paper's highlighter: rgba(208,162,21,.24)
                #expect(sel == "rgba(208,162,21,.24)" && t.selection == Paint(0xD0A215, 0.24))
            } else {
                #expect(t.selection == Paint(t.accent, t.dark ? 0.16 : 0.14), "\(row.id) selection")
            }
        }
    }

    @Test("Solid and Glass give matVals()'s window and surface strength, contrast and floor for every theme")
    func materials() throws {
        for row in Self.rows {
            let t = Self.made(row)
            for material in WindowMaterial.allCases {
                for strength in [40, 80, 100] {
                    let want = try #require(row.mats["\(material.rawValue)\(strength)"])
                    let have = MaterialValues(theme: t, material: material, strength: strength)
                    #expect(have.windowAlpha == want.ma && have.surfaceAlpha == want.ms && have.raised == want.raised,
                            "\(row.id) \(material) \(strength): \(have) vs \(want)")
                    #expect(abs(have.contrast - want.cr) < 0.0001, "\(row.id) \(material) \(strength) contrast")
                    #expect(have.contrast >= 4.5 || have.surfaceAlpha == 100, "\(row.id) \(material) \(strength) floor")
                }
            }
        }
    }

    @Test("Solid has no strength: its values are the same at 40 and 100 (card agent-bo-95422896)")
    func solidHasNoStrength() {
        for theme in PilotTheme.designed {
            #expect(MaterialValues(theme: theme, material: .solid, strength: 40) == MaterialValues(theme: theme, material: .solid, strength: 100))
        }
    }

    @Test("A wallpaper brighter than the theme's own raises the floor; Increase contrast makes every surface solid")
    func floor() {
        let t = Self.made(Self.rows[0])   // round 4's Nightwatch, which a white wallpaper lifts
        let designed = MaterialValues(theme: t, material: .glass, strength: 40)
        let white = MaterialValues(theme: t, material: .glass, strength: 40, spot: [255, 255, 255])
        #expect(white.surfaceAlpha > designed.surfaceAlpha && white.raised)
        #expect(white.contrast >= 4.5 || white.surfaceAlpha == 100)
        let contrast = MaterialValues(theme: t, material: .glass, strength: 40, increaseContrast: true)
        #expect(contrast.surfaceAlpha == 100 && !contrast.raised)
        // Solid is the theme's surface straight, whatever the wallpaper.
        #expect(MaterialValues(theme: t, material: .solid, strength: 40, spot: [255, 255, 255]) == MaterialValues(theme: t, material: .solid, strength: 100))
    }

    @Test("A glyph on a solid tile is the theme's sidebar on a light colour in a dark theme, else white; the accent's ink is the same rule")
    func ink() throws {
        let night = try #require(PilotTheme.named("tokyo-night")), paper = try #require(PilotTheme.named("folio"))
        #expect(night.ink(on: night.good) == night.sidebar)
        #expect(night.ink(on: 0x205EA6) == 0xFFFFFF)
        #expect(paper.ink(on: paper.good) == 0xFFFFFF && paper.ink(on: 0xF2EFE4) == 0xFFFFFF)
        // The rule holds unless it reads below 4.5:1 on that accent (Garnet; Sven's themes round, P105).
        for theme in PilotTheme.designed where !StyleTokens.toyboxThemes.contains(theme.id) {
            #expect(Contrast.ratio(theme.onAccent, theme.accent) >= 4.5, "\(theme.id)")
            #expect(theme.onAccent == theme.ink(on: theme.accent) || Contrast.ratio(theme.ink(on: theme.accent), theme.accent) < 4.5, "\(theme.id)")
        }
        // Toybox's ink, never white, on its sun.
        #expect(PilotTheme.named("toybox")?.onAccent == 0x221E35 && Contrast.ratio(0x221E35, 0xFFC933) >= 4.5)
        // The neutral tile: in a dark theme the raised colour lifted 16 % toward white; else the second text.
        #expect(night.neutral == Contrast.hex(Contrast.mix([255, 255, 255], Contrast.rgb(night.raised), 0.16)))
        #expect(paper.neutral == paper.text2)
    }
}

