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
            .choice("look.theme", "Theme", page: "look", PilotTheme.designed.map(\.id), standard: PilotTheme.defaultID,
                    read: { look.themeID }, write: { id throws(ControlError) in
                        look.pick(id)
                        if let error = look.lastError { throw ControlError(.badValue, "the theme is now \(id), but \(error)") }
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
            // A set, its colours or its custom fill and outline change the system cursor everywhere, so `pilot set` waits on Allow (P84). The page's offer to turn
            // Accessibility's pointer colours off first is the page's alone.
            .choice("look.cursor", "Cursor set; macOS is the system's own. Set here, it skips the page's check of Accessibility's pointer colours",
                    page: "look", CursorSetID.allCases, standard: .macOS,
                    confirms: true, read: { cursors.set }, write: { cursors.set = $0 }),
            .choice("look.cursorColours", "Cursor colours: the theme's, the set's own, or custom's fill and outline", page: "look",
                    CursorColours.allCases, standard: .theme, confirms: true, read: { cursors.colours }, write: { cursors.colours = $0 }),
            // theme = the theme's own fill or outline for the set, until a colour is picked.
            .colour("look.cursorFill", "Cursor fill, while colours are custom", page: "look", confirms: true,
                    read: { cursors.fill }, write: { cursors.fill = $0 }),
            .colour("look.cursorOutline", "Cursor outline, while colours are custom", page: "look", confirms: true,
                    read: { cursors.outline }, write: { cursors.outline = $0 }),
            .choice("look.cursorTrail", "Cursor trail", page: "look", CursorTrail.allCases, standard: .off,
                    read: { effects.trail }, write: { effects.trail = $0 }),
            .bool("look.cursorRing", "Cursor halo: a ring on the pointer, hidden after 3 s still", page: "look", standard: false,
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
