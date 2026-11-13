import Foundation
import PilotCore

extension SettingsSchema {
    /// The menu's settings: Files' hidden files, and Passwords and Folders with its GIPHY key and rating, which sit under their
    /// abilities on Launcher › Abilities (page map, Sven 2026-10-17), so `page: "menu"` still. The never-index folders and
    /// the root's order are lists (collections), not keys.
    func registerMenu(files: FileSearchSettings, passwords: PasswordSettings, folders: PilotFolders, giphy: any StoredKey,
                      dropdown: DropdownLayoutStore = .forSettings) {
        registerDropdown(dropdown)
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

    /// The tall Pilot menu's arrangement (spec desktop-controls T4), as Menu bar › Pilot menu edits it, Instrument only:
    /// `dropdown.order` names the blocks to lead, the rest following in their first order; `dropdown.hidden` and
    /// `dropdown.pinned` are sets; `dropdown.extensions` the extensions the Extensions card lists. Blocks: status,
    /// workspaces, switches, extensions, running, sound, connections, display, media, stats, commands. Status can't be
    /// hidden; extensions, sound, connections, display, media and stats are hidden until shown.
    func registerDropdown(_ store: DropdownLayoutStore) {
        let all = Dropdown.Layout.arrangeable
        func listed(_ blocks: [Dropdown.Block]) -> String { blocks.isEmpty ? "none" : Dropdown.Layout.names(blocks) }
        register([
            .text("dropdown.order", "Pilot menu's block order, comma-separated (the rest follow)", page: "pilotMenu", standard: listed(all),
                  read: { listed(store.layout.order) }, write: { typed throws(ControlError) in try store.setOrder(Self.blocks(typed, key: "dropdown.order")) }),
            .text("dropdown.hidden", "Pilot menu's hidden blocks, comma-separated or none (status always shows)", page: "pilotMenu",
                  standard: listed(all.filter(Dropdown.Layout.optional.contains)), read: { listed(all.filter(store.layout.hidden.contains)) },
                  write: { typed throws(ControlError) in try store.setHidden(Set(Self.blocks(typed, key: "dropdown.hidden"))) }),
            .text("dropdown.pinned", "Pilot menu's blocks pinned above its scroll, comma-separated or none", page: "pilotMenu", standard: "none",
                  read: { listed(all.filter(store.layout.pinned.contains)) },
                  write: { typed throws(ControlError) in try store.setPinned(Set(Self.blocks(typed, key: "dropdown.pinned"))) }),
            .text("dropdown.extensions", "The extensions' bar items in the Pilot menu's Extensions card, ids comma-separated or none",
                  page: "pilotMenu", standard: "none",
                  read: { store.layout.extensions.isEmpty ? "none" : store.layout.extensions.joined(separator: ",") },
                  write: { typed throws(ControlError) in try store.setExtensions(Self.words(typed, lowercased: false)) }),
        ])
    }

    static func blocks(_ typed: String, key: String) throws(ControlError) -> [Dropdown.Block] {
        try named(typed, key: key, noun: "block", from: Dropdown.Layout.arrangeable)
    }

    /// A typed list: words, comma-separated and trimmed, or none for an empty list.
    static func words(_ typed: String, lowercased: Bool = true) -> [String] {
        let words = typed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { lowercased ? $0.lowercased() : $0 }
        return words.map { $0.lowercased() } == ["none"] ? [] : words
    }

    /// Names as typed (the Pilot menu's blocks, the pill's views): a word list; an unknown name is refused with the
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
