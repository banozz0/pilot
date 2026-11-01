import Foundation
import PilotCore

extension SettingsSchema {
    /// The Look page's keys, on the Look the page binds to: a theme is picked as the page picks it (Ghostty follows). The
    /// focused window's border and Defocus are on Tiling's Focused window block (page map, Sven 2026-10-17), so their keys
    /// say page tiling, named as before. A theme Ghostty did not take answers bad-value with the line the page shows (the
    /// theme itself changed).
    func registerLook(_ look: Look) {
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
        ])
    }
}
