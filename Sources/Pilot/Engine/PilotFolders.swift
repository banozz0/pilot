import Foundation
import Observation
import PilotCore

/// Launcher › Abilities, under lazygit and Stickers and GIFs (story 160; on Defaults until C3, Menu › Folders until the page map): where lazygit's repo picker looks (~/code) and the GIFs folder
/// Stickers and GIFs lists (Pilot's own in Application Support, hidden in Library), and the most GIPHY's search there may
/// show (story 164). Its own store, so the block renders without an engine.
@Observable @MainActor
final class PilotFolders {
    static let shared = PilotFolders()

    static let standardRepos = NSHomeDirectory() + "/code"
    static var standardGIFs: String { Stickers.standardFolder.path }

    /// The folder whose subfolders lazygit's picker lists.
    var repos: String {
        didSet { defaults.set(repos == Self.standardRepos ? nil : repos, forKey: Self.reposKey) }
    }
    /// The folder Stickers and GIFs lists and opens.
    var gifs: String {
        didSet {
            defaults.set(gifs == Self.standardGIFs ? nil : gifs, forKey: Self.gifsKey)
            publish()
        }
    }
    /// GIPHY's highest rating Stickers and GIFs lists; PG-13 unless picked.
    var giphyRating: Giphy.Rating {
        didSet { defaults.set(giphyRating == .standard ? nil : giphyRating.rawValue, forKey: Self.ratingKey) }
    }
    @ObservationIgnored private let defaults: UserDefaults
    private static let reposKey = "folders.repos", gifsKey = "folders.gifs", ratingKey = "giphy.rating"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        repos = defaults.string(forKey: Self.reposKey) ?? Self.standardRepos
        gifs = defaults.string(forKey: Self.gifsKey) ?? Self.standardGIFs
        giphyRating = defaults.string(forKey: Self.ratingKey).flatMap(Giphy.Rating.init(rawValue:)) ?? .standard
        publish()
    }

    /// Hands the GIFs folder to Stickers, which the menu reads off the main thread; a test's own store hands nothing.
    private func publish() {
        guard defaults.isApp else { return }
        Stickers.picked = gifs == Self.standardGIFs ? nil : URL(filePath: gifs)
    }

    var reposURL: URL { URL(filePath: repos) }
}
