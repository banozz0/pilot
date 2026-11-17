import Foundation
import Observation
import PilotCore

/// Personal labels only, by display identity (LiveDisplay.key), so a name outlasts a UUID macOS hands out anew; one saved
/// before identities is read by its UUID. Hardware names and connection bindings stay original.
@Observable @MainActor
final class DisplayNicknames {
    static let shared = DisplayNicknames()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let unreadable: Bool
    private(set) var names: [String: String]
    private static let key = "displays.nicknames"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        let saved = defaults.object(forKey: Self.key)
        names = saved as? [String: String] ?? [:]
        unreadable = saved != nil && !(saved is [String: String])
    }

    func nickname(for displayUUID: String?) -> String? {
        displayUUID.flatMap(UUID.init(uuidString:)).flatMap { names.first(of: LiveDisplay.keys(forUUID: $0.uuidString)) }
    }

    func label(systemName: String, displayUUID: String?) -> String {
        nickname(for: displayUUID) ?? systemName
    }

    /// Empty or whitespace-only text clears; all other text is kept verbatim. No raw display handle is accepted.
    func set(_ name: String, for displayUUID: String) throws {
        guard let uuid = UUID(uuidString: displayUUID) else {
            throw ConnectionFailure.refused("That display has no stable identity for a personal name")
        }
        guard !unreadable else { throw ConnectionFailure.refused("Pilot's display names could not be read; saved names were left unchanged") }
        // Under the display's identity, the UUID's own entry from before identities gone.
        let key = LiveDisplay.key(forUUID: uuid.uuidString)
        names[uuid.uuidString] = nil
        names[key] = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        defaults.set(names, forKey: Self.key)
    }
}
