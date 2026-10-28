import OSLog
import PilotCore

private let dictationLog = Logger(subsystem: "dev.banozz.pilot", category: "dictation")

/// The Dictation module (story 43's slot): two bindable actions, no default keys until Sven picks them. Both drive
/// Pilot's own dictation (story 194, Q452: Pilot's alone), which says where to get a speech model when none is on disk.
@MainActor
enum DictationModule {
    static let toggleID = "dictation.toggle", holdID = "dictation.hold"

    static func register(into registry: inout ActionRegistry, dictation: PilotDictation = .shared) {
        let actions = [
            Action(id: toggleID, label: "Dictate on or off", module: .dictation) { dictation.toggle() },
            Action(id: holdID, label: "Dictate while held", module: .dictation, hold: { dictation.hold($0) }),
        ]
        for action in actions {
            do { try registry.register(action) } catch { dictationLog.error("\(action.id, privacy: .public): \(String(describing: error), privacy: .public)") }
        }
    }
}
