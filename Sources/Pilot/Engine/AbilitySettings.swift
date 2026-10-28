import Foundation
import Observation
import PilotCore

/// The optional abilities added (PilotCore's Abilities.optional; Sven 2026-10-10, abilities ship minimal): a string list
/// in Pilot's settings, so an id a later build drops is only a stale string. Its own store, as MenuRootSettings is.
@Observable @MainActor
final class AbilitySettings {
    static let shared = AbilitySettings()

    private(set) var added: Set<String> { didSet { defaults.set(added.sorted(), forKey: Self.key) } }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var found: [CatalogueEntry.Check: (has: Bool, at: Date)] = [:]
    private static let key = "abilities.added"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        added = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    /// Once, before the first bind load: a Mac that already ran Pilot (its binds.json is there) keeps every optional
    /// ability it listed, so Sven's own setup loses none; a new Mac starts with none added.
    func seed(existingUser: @autoclosure () -> Bool) {
        guard defaults.object(forKey: Self.key) == nil else { return }
        added = existingUser() ? Set(Abilities.optional.keys) : []
    }

    func add(_ id: String) { added.insert(id) }
    func remove(_ id: String) { added.remove(id) }

    /// Whether the app or file is on this Mac, asked again after 30 s: the menu lists actions on every open, and an app
    /// installed from Install shows up without a relaunch.
    func has(_ need: CatalogueEntry.Check) -> Bool {
        if let hit = found[need], hit.at.timeIntervalSinceNow > -30 { return hit.has }
        let has = need.isMet(bundleInstalled: AppsModule.isInstalled, fileExists: FileManager.default.fileExists(atPath:))
        found[need] = (has, Date())
        return has
    }
}
