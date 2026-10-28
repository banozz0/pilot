import Foundation
import Observation
import PilotCore

/// Defaults › File search (N5, Sven 2026-10-09): whether the Files view opens with hidden and system files shown, and
/// the never-index list (FileExclusions), which the file index skips entirely. A changed list stops the running helper,
/// so the next file search walks with it. Its own store, as Recommendations is, so pages that render without an engine
/// read it.
@Observable @MainActor
final class FileSearchSettings {
    static let shared = FileSearchSettings()

    /// The Files view opens with dot names and bundle insides shown; ⌘⇧. flips it for one menu.
    var showHidden: Bool { didSet { defaults.set(showHidden, forKey: Self.hiddenKey) } }
    /// The never-index list, as Sven sees it: `~/Library`, `node_modules`.
    private(set) var excluded: [String] {
        didSet {
            defaults.set(excluded, forKey: Self.excludedKey)
            onExcludedChange()
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let home: String
    /// Stops the running helper; a test passes its own.
    @ObservationIgnored var onExcludedChange: () -> Void = { FileIndex.shared.restart() }
    private static let hiddenKey = "files.showHidden", excludedKey = "files.excluded"

    init(defaults: UserDefaults = .pilot(), home: String = NSHomeDirectory()) {
        self.defaults = defaults
        self.home = home
        showHidden = defaults.bool(forKey: Self.hiddenKey)
        excluded = defaults.stringArray(forKey: Self.excludedKey) ?? FileExclusions.defaults
    }

    /// Adds a typed folder name or path; why not when it is refused, nil when it was added.
    func add(_ typed: String) -> String? {
        guard let entry = FileExclusions.entry(typed, home: home) else {
            return "Type a folder name, like node_modules, or a folder in your home, like ~/Movies."
        }
        guard !excluded.contains(entry) else { return "\(entry) is already left out." }
        excluded.append(entry)
        return nil
    }

    func remove(_ entry: String) { excluded.removeAll { $0 == entry } }

    /// The shipped list again.
    func reset() { if excluded != FileExclusions.defaults { excluded = FileExclusions.defaults } }
}
