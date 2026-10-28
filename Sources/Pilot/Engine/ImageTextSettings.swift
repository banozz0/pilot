import Foundation
import Observation
import PilotCore

/// Files › File search › Text in images (Homy-style Files, Sven 2026-10-12): whether Pilot reads the words in the images
/// of a few folders into its text index (ImageTextIndex), and which folders. Desktop, Downloads, Documents and Pictures
/// by default (~/Pictures/Screenshots with them); ~/code stays out, 1,095 repo images. The never-index list
/// applies on top. Switching it off clears the index, so the screenshots' words leave the Mac's disk with it. Its own
/// store, as FileSearchSettings is, so pages that render without an engine read it.
@Observable @MainActor
final class ImageTextSettings {
    static let shared = ImageTextSettings()

    static let standardFolders = ["~/Desktop", "~/Downloads", "~/Documents", "~/Pictures"]

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            onChange()
        }
    }
    /// The folders read, as Sven sees them: `~/Pictures`.
    private(set) var folders: [String] {
        didSet {
            defaults.set(folders == Self.standardFolders ? nil : folders, forKey: Self.foldersKey)
            onChange()
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let home: String
    /// The never-index list, which a folder added must not be on or inside.
    @ObservationIgnored private let excluded: () -> [String]
    /// Tells the reader: it clears the index when switched off and reads again otherwise; a test passes its own.
    @ObservationIgnored var onChange: () -> Void = { ImageTextReader.shared.settingsChanged() }
    private static let enabledKey = "files.imageText", foldersKey = "files.imageTextFolders"

    init(defaults: UserDefaults = .pilot(), home: String = NSHomeDirectory(),
         excluded: @escaping () -> [String] = { FileSearchSettings.shared.excluded }) {
        self.defaults = defaults
        self.home = home
        self.excluded = excluded
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        folders = defaults.stringArray(forKey: Self.foldersKey) ?? Self.standardFolders
    }

    /// The folders as absolute paths.
    var paths: [String] { folders.map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 } }

    /// Adds a folder in home, typed or picked; why not when it is refused, nil when it was added.
    func add(_ typed: String) -> String? {
        guard let entry = FileExclusions.entry(typed, home: home), entry.hasPrefix("~/") else {
            return "Pick a folder in your home, like ~/Pictures."
        }
        guard !folders.contains(entry) else { return "\(entry) is already read." }
        guard !ImageTextReader.leftOut(home + entry.dropFirst(), excluded: excluded(), home: home) else {
            return "\(entry) is on the never-index list, or inside a folder that is."
        }
        folders.append(entry)
        return nil
    }

    func remove(_ entry: String) { folders.removeAll { $0 == entry } }

    /// The shipped folders again.
    func reset() { if folders != Self.standardFolders { folders = Self.standardFolders } }
}
