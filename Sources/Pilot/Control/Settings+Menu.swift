import Foundation
import PilotCore

extension SettingsSchema {
    /// The menu's settings: Files' hidden files, and Passwords and Folders with its GIPHY key and rating, which sit under their
    /// abilities on Launcher › Abilities (page map, Sven 2026-10-17), so `page: "menu"` still. The never-index folders and
    /// the root's order are lists (collections), not keys.
    func registerMenu(files: FileSearchSettings, passwords: PasswordSettings, folders: PilotFolders, giphy: any StoredKey) {
        register([
            .bool("files.showHidden", "Files opens with hidden files shown", page: "files", standard: false,
                  read: { files.showHidden }, write: { files.showHidden = $0 }),
            .int("passwords.length", "Password length", page: "menu", range: PasswordSettings.lengths, standard: 20,
                 read: { passwords.length }, write: { passwords.length = $0 }),
            .bool("passwords.symbols", "Passwords have symbols", page: "menu", standard: true,
                  read: { passwords.symbols }, write: { passwords.symbols = $0 }),
            .choice("passwords.clearAfter", "Seconds a copied password stays", page: "menu",
                    PasswordSettings.clearChoices.map { String($0) }, standard: "90",
                    read: { String(passwords.clearAfter) }, write: { passwords.clearAfter = Int($0) ?? passwords.clearAfter }),
            .text("folders.repos", "Repos folder (lazygit's picker)", page: "menu", standard: PilotFolders.standardRepos,
                  read: { folders.repos }, write: { path throws(ControlError) in folders.repos = try Self.folder(path) }),
            .text("folders.gifs", "GIFs folder", page: "menu", standard: PilotFolders.standardGIFs,
                  read: { folders.gifs }, write: { path throws(ControlError) in folders.gifs = try Self.folder(path) }),
            .secret("giphy.key", "GIPHY key", page: "menu", isSet: { giphy.exists() }, save: { try giphy.write($0) }),
            .choice("giphy.rating", "GIPHY's highest rating", page: "menu", Giphy.Rating.allCases.map(\.rawValue),
                    standard: Giphy.Rating.standard.rawValue, read: { folders.giphyRating.rawValue },
                    write: { folders.giphyRating = Giphy.Rating(rawValue: $0) ?? folders.giphyRating }),
        ])
    }

    /// The Hyper+Space root's extra rows (Sven 2026-10-20), one switch each as Launcher › Your menu shows them, off by
    /// default: `menu.extra.<id>`. The root's order and hidden branches stay the menu-root collection.
    func registerMenuRoot(_ settings: MenuRootSettings) {
        register(MenuRoot.extraRows.map { extra in
            .bool("menu.extra.\(extra.id)", "Hyper+Space root lists \(extra.title)", page: "menu", standard: false,
                  read: { settings.root.extras.contains(extra.id) }, write: { settings.root.show(extra: extra.id, $0) })
        })
    }

    /// A folder as the page's picker gives it: a full path (or ~/…) to a folder that is there.
    static func folder(_ typed: String) throws(ControlError) -> String {
        let full = (typed as NSString).expandingTildeInPath
        let path = URL(filePath: full).standardizedFileURL.path(percentEncoded: false)
        var isFolder: ObjCBool = false
        guard full.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            throw ControlError(.badValue, "\(typed) is no folder: give the full path (or ~/…) of one that exists")
        }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
