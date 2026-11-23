import Foundation
import PilotCore

extension SettingsSchema {
    /// Look › Font's two rows (Sven, Q711; on Look since 2026-11-23): Pilot's words and its mono, an installed family's
    /// name, or `default` for the style's own.
    func registerFonts(_ fonts: PilotFonts) {
        func key(_ part: PilotFonts.Part, _ label: String) -> SettingKey {
            let key = part.rawValue
            return .text(key, label, page: "look", standard: nil, read: { fonts.family(part) }, write: { word throws(ControlError) in
                do { try fonts.set(part, word.lowercased() == "default" ? nil : word) } catch {
                    throw ControlError(.badValue, "\(key) is an installed font family or default, not \(word)")
                }
            })
        }
        register([
            key(.ui, "Pilot's words font, a family; default is the style's own"),
            key(.mono, "Pilot's mono font, a family; default is the style's own"),
        ])
    }
}
