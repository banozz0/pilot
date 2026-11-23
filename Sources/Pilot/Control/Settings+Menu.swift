import Foundation
import PilotCore

extension SettingsSchema {
    /// The menu's settings: Files' hidden files, and Passwords and Folders with its GIPHY key and rating, which sit under their
    /// abilities on Launcher › Abilities (page map, Sven 2026-10-17), so `page: "menu"` still. The never-index folders and
    /// the root's order are lists (collections), not keys.
    /// `launcher.on` is one of Home's and the Pilot menu's four switches (spec pilot-ui-redesign T4): off, the launcher's
    /// key opens nothing.
    func registerMenu(files: FileSearchSettings, passwords: PasswordSettings, folders: PilotFolders, giphy: any StoredKey,
                      launcher: SessionSwitch = .launcher) {
        register([
            .bool("launcher.on", "Launcher on (its key, Hyper+Space, opens the Pilot menu; off, it opens nothing)", page: "home", standard: true,
                  read: { launcher.isOn }, write: { launcher.set($0) }),
            .bool("files.showHidden", "Files opens with hidden files shown", page: "files", standard: false,
                  read: { files.showHidden }, write: { files.showHidden = $0 }),
            .int("passwords.length", "Password length", page: "menu", range: PasswordSettings.lengths, standard: 20,
                 read: { passwords.length }, write: { passwords.length = $0 }),
            .bool("passwords.symbols", "Passwords have symbols", page: "menu", standard: true,
                  read: { passwords.symbols }, write: { passwords.symbols = $0 }),
            .choice("passwords.clearAfter", "Seconds a copied password stays", page: "menu",
                    PasswordSettings.clearChoices.map { String($0) }, standard: "90",
                    read: { String(passwords.clearAfter) }, write: { passwords.clearAfter = Int($0) ?? passwords.clearAfter }),
            .text("folders.repos", "Repos folder (Developer › Repos, its widgets, lazygit's picker)", page: "menu", standard: PilotFolders.standardRepos,
                  read: { folders.repos }, write: { path throws(ControlError) in folders.repos = try Self.folder(path) }),
            .text("folders.gifs", "GIFs folder", page: "menu", standard: PilotFolders.standardGIFs,
                  read: { folders.gifs }, write: { path throws(ControlError) in folders.gifs = try Self.folder(path) }),
            .secret("giphy.key", "GIPHY key", page: "menu", isSet: { giphy.exists() }, save: { try giphy.write($0) }),
            .choice("giphy.rating", "GIPHY's highest rating", page: "menu", Giphy.Rating.allCases.map(\.rawValue),
                    standard: Giphy.Rating.standard.rawValue, read: { folders.giphyRating.rawValue },
                    write: { folders.giphyRating = Giphy.Rating(rawValue: $0) ?? folders.giphyRating }),
        ])
    }

    /// A typed list: words, comma-separated and trimmed, or none for an empty list.
    static func words(_ typed: String, lowercased: Bool = true) -> [String] {
        let words = typed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { lowercased ? $0.lowercased() : $0 }
        return words.map { $0.lowercased() } == ["none"] ? [] : words
    }

    /// Names as typed (the pill's views): a word list; an unknown name is refused with the
    /// `options` there are.
    static func named<T: RawRepresentable<String>>(_ typed: String, key: String, noun: String, from options: [T]) throws(ControlError) -> [T] {
        var found: [T] = []
        for word in words(typed) {
            guard let value = T(rawValue: word) else {
                throw ControlError(.badValue, "\(key): no \(noun) \(word); the \(noun)s are \(options.map(\.rawValue).joined(separator: ",")), or none")
            }
            found.append(value)
        }
        return found
    }

    /// The Hyper+Space root's extra rows (Sven 2026-10-20), one switch each as Launcher › Your menu shows them, off by
    /// default: `menu.extra.<id>`, but for Bookmarks and History, which `menu.bookmarks` and `menu.browserHistory` list. The root's order and hidden branches stay the menu-root collection. `menu.fallbacks` is
    /// Your menu's When nothing matches.
    func registerMenuRoot(_ settings: MenuRootSettings) {
        register(MenuRoot.extraRows.filter { !MenuRoot.browserExtras.contains($0.id) }.map { extra -> SettingKey in
            .bool("menu.extra.\(extra.id)", "Hyper+Space root lists \(extra.title)", page: "menu", standard: false,
                  read: { settings.root.extras.contains(extra.id) }, write: { settings.root.show(extra: extra.id, $0) })
        } + [
            // Your fallbacks (spec launcher-best T4): ids in order, as Launcher › Your menu lists them; default is Pilot's own.
            .text("menu.fallbacks", "What a search that finds nothing offers, in order: \(MenuFallbacks.builtIn.map(\.id).joined(separator: ", ")), quicklinks.<keyword>, a script's id; default is Pilot's own",
                  page: "menu", standard: "default", read: { settings.fallbacks?.joined(separator: ",") ?? "default" },
                  write: { typed throws(ControlError) in settings.fallbacks = try Self.fallbacks(typed) }),
            // The browsers (spec launcher-best T9, Q328), on Launcher › More rows: bookmarks on, history off until switched on.
            .bool("menu.bookmarks", "Hyper+Space's root lists Bookmarks, your browsers' bookmarks by browser, and its search finds them (read with Full Disk Access)", page: "menu", standard: true,
                  read: { BrowserSettings.shared.bookmarks }, write: { BrowserSettings.shared.bookmarks = $0 }),
            .bool("menu.browserHistory", "Hyper+Space's root lists History, the pages you visited newest first, its search up to 3 of them, and hist <words> only those; off until you switch it on", page: "menu",
                  standard: false, read: { BrowserSettings.shared.history }, write: { BrowserSettings.shared.history = $0 }),
        ])
    }

    /// Typed fallbacks as kept: known ids in the order typed, once each; nil (Pilot's own) for default, none or nothing.
    @MainActor static func fallbacks(_ typed: String) throws(ControlError) -> [String]? {
        let picked = words(typed, lowercased: false)
        guard !picked.isEmpty, typed.trimmingCharacters(in: .whitespaces).lowercased() != "default" else { return nil }
        let options = MenuRootSettings.fallbackOptions()
        var kept: [String] = []
        for word in picked {
            // A script's id keeps its case as found; a word matches it in any case.
            guard let option = options.first(where: { $0.id.caseInsensitiveCompare(word) == .orderedSame }) else {
                throw ControlError(.badValue, "menu.fallbacks: no fallback \(word); they are \(options.map(\.id).joined(separator: ",")), or default")
            }
            if !kept.contains(option.id) { kept.append(option.id) }
        }
        return kept
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
