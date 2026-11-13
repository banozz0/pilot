import Foundation
import PilotCore

extension SettingsSchema {
    /// The Look page's keys, on the Look the page binds to: a theme is picked as the page picks it (Ghostty follows). The
    /// focused window's border and Defocus are on Tiling's Focused window block (page map, Sven 2026-10-17), so their keys
    /// say page tiling, named as before. A theme Ghostty did not take answers bad-value with the line the page shows (the
    /// theme itself changed).
    func registerLook(_ look: Look) {
        let cursors = CursorSets.of(look), effects = CursorEffects.of(look)
        register([
            .choice("look.style", "Style", page: "look", PilotStyle.allCases, standard: .instrument,
                    read: { look.style }, write: { look.style = $0 }),
            .choice("look.theme", "Stock theme catalog; current style choices: pilot theme colours", page: "look", PilotTheme.designed.map(\.id), standard: PilotTheme.defaultID,
                    read: { look.themeID }, write: { id throws(ControlError) in
                        guard PilotTheme.named(id) != nil, look.shows(id), ThemeNativePalette.stock(id).compatible(with: look.style.rawValue) else { throw ControlError(.badValue, "unknown or incompatible stock theme; pilot theme colours lists current choices") }
                        look.pick(id)
                        if let error = look.lastError { throw ControlError(.badValue, error) }
                    }),
            .bool("look.glass", "Glass", page: "look", standard: false, read: { look.glass }, write: { look.glass = $0 }),
            .int("look.transparency", "Transparency, in percent", page: "look", range: 0...100, standard: 33,
                 read: { look.transparency }, write: { look.transparency = $0 }),
            .choice("look.glassBlur", "Glass blur", page: "look", GlassBlur.allCases, standard: .full,
                    read: { look.glassBlur }, write: { look.glassBlur = $0 }),
            .bool("look.windowBorder", "Border around the focused window", page: "tiling", standard: true,
                  read: { look.windowBorder }, write: { look.windowBorder = $0 }),
            .int("look.windowBorderWidth", "Border width, in points", page: "tiling", range: WindowBorder.widths,
                 standard: WindowBorder.defaultWidth, read: { look.windowBorderWidth }, write: { look.windowBorderWidth = $0 }),
            .colour("look.windowBorderColour", "Border colour", page: "tiling",
                    read: { look.windowBorderColour }, write: { look.windowBorderColour = $0 }),
            .int("look.defocusStrength", "Defocus blur, 0 is off", page: "tiling", range: Defocus.strengths, standard: Defocus.defaultStrength,
                 read: { look.defocusStrength }, write: { look.defocusStrength = $0 }),
            .int("look.defocusDim", "Defocus dim, in percent, 0 is off", page: "tiling", range: Defocus.dims, standard: Defocus.defaultDim,
                 read: { look.defocusDim }, write: { look.defocusDim = $0 }),
            .bool("look.defocusShake", "A mouse shake toggles Defocus", page: "tiling", standard: true,
                  read: { look.defocusShake }, write: { look.defocusShake = $0 }),
            .int("look.defocusShakeSwings", "Swings a shake needs", page: "tiling", range: ShakeDetector.swingsRange,
                 standard: ShakeDetector.defaultSwings, read: { look.defocusShakeSwings }, write: { look.defocusShakeSwings = $0 }),
            .number("look.defocusShakeWithin", "Seconds the swings fall within", page: "tiling", range: ShakeDetector.withinRange,
                    standard: ShakeDetector.defaultWithin, read: { look.defocusShakeWithin }, write: { look.defocusShakeWithin = $0 }),
            .choice("look.appsShowAs", "Apps show as", page: "look", AppsShowAs.allCases, standard: .standard,
                    read: { look.appsShowAs }, write: { look.appsShowAs = $0 }),
            .choice("look.windowLayout", "Window layout", page: "look", WindowShape.allCases, standard: .rail,
                    read: { look.windowShape }, write: { look.windowShape = $0 }),
            .choice("look.menuLayout", "Hyper+Space menu", page: "look", MenuLayoutStyle.allCases, standard: .line,
                    read: { look.menuLayout }, write: { look.menuLayout = $0 }),
            // Pilot drawing the cursor, its shape, size, colours or custom fill and outline change the system cursor
            // everywhere, so `pilot set` waits on Allow (P84). The page's offer to turn Accessibility's pointer colours off
            // first is the page's alone. Q112 split the old `look.cursor` (a set, or macOS) into the switch and Shape.
            .bool("look.cursorDrawn", "Pilot draws the cursor in its shape; off, macOS's own is back. Set here, it skips the page's check of Accessibility's pointer colours",
                  page: "look", standard: false, confirms: true, read: { cursors.drawn }, write: { cursors.drawn = $0 }),
            .choice("look.cursorShape", "Cursor shape Pilot draws: quiet, toybox, duo or classic; kept while Pilot draws none", page: "look",
                    CursorSetID.shapes, standard: .quiet, confirms: true, read: { cursors.shape }, write: { cursors.shape = $0 }),
            .choice("look.cursorSize", "Cursor size: small is macOS's 32 pt, medium 1.5x, large 2x, huge 2.5x; classic takes whole steps (medium draws it 2x, huge 3x)",
                    page: "look", CursorSize.allCases, standard: .small, confirms: true, read: { cursors.size }, write: { cursors.size = $0 }),
            .choice("look.cursorColours", "Cursor colours: the theme's, or custom's fill and outline", page: "look",
                    CursorColours.allCases, standard: .theme, confirms: true, read: { cursors.colours }, write: { cursors.colours = $0 }),
            // theme = the theme's own fill or outline for the set, until a colour is picked.
            .colour("look.cursorFill", "Cursor fill, while colours are custom", page: "look", confirms: true,
                    read: { cursors.fill }, write: { cursors.fill = $0 }),
            .colour("look.cursorOutline", "Cursor outline, while colours are custom", page: "look", confirms: true,
                    read: { cursors.outline }, write: { cursors.outline = $0 }),
            .choice("look.cursorTrail", "Cursor trail", page: "look", CursorTrail.allCases, standard: .off,
                    read: { effects.trail }, write: { effects.trail = $0 }),
            .bool("look.cursorRing", "Cursor halo: a ring on the pointer that grows with the cursor's size, hidden after 3 s still", page: "look", standard: false,
                  read: { effects.ring }, write: { effects.ring = $0 }),
            .bool("look.cursorRipple", "Cursor halo: a ripple on each click", page: "look", standard: false,
                  read: { effects.ripple }, write: { effects.ripple = $0 }),
            .colour("look.cursorEffectColour", "Cursor trail, ring and ripple colour; the right-click ripple keeps the theme's second", page: "look",
                    read: { effects.colour }, write: { effects.colour = $0 }),
            .bool("look.cursorSpotlight", "Cursor halo: Spotlight, shown while cursor.spotlight's key is held", page: "look", standard: false,
                  read: { effects.spotlight }, write: { effects.spotlight = $0 }),
        ])
    }
}
