import Foundation
import PilotCore

/// `pilot theme catalogue|get` (public-repo spec T20): the catalogue's theme packs, read through the model the
/// Extensions page shares (one index, kept ten minutes), installed into your themes by ThemeInstaller after Allow, every
/// file held to the index's sha256. A pack is data: installing applies nothing; `theme delete` takes one out.
extension ControlVerbs {
    /// `theme catalogue [refresh]`: each theme the catalogue offers, with where it stands in your themes, as Look ›
    /// Catalogue's tiles show it (ThemeCatalogueModel, public-repo T22).
    static func themeCatalogue(refresh: Bool, _ owner: ThemeCoordinator) async throws(ControlError) -> JSONValue {
        let model = try await themeModel(refresh: refresh)
        return .object(["count": .number(Double(model.themes.count)), "themes": .array(model.themes.map { theme in
            let standing = model.standing(of: theme)
            // A shipped theme's catalogue copy only brings its pictures, on Apply (ShippedWallpapers): never installed.
            let button = switch standing {
            case .builtIn: model.pictured.contains(theme.id) ? "Built in: apply it for its wallpapers" : "Built in"
            case .get: "Install"
            case .installed: "Installed"
            case .update: "Update"
            }
            var o: [String: JSONValue] = [
                "id": .string(theme.id), "title": .string(theme.title), "dark": .bool(theme.dark), "styles": .array(theme.styles.map(JSONValue.string)),
                "standing": .string(standing.word), "button": .string(button), "applied": .bool(model.applied == theme.id),
                "files": .number(Double(theme.files.count)), "size": .number(Double(theme.size)), "digest": .string(theme.digest),
            ]
            o["preview"] = theme.preview.map(JSONValue.string)
            o["author"] = theme.author.map(JSONValue.string)
            return .object(o)
        })])
    }

    /// `theme get <id>`: installs a catalogue theme, or replaces the pack with its id in your themes, after Allow, through
    /// the model Look › Catalogue's Get and Update use.
    static func getTheme(_ id: String, _ owner: ThemeCoordinator, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let model = try await themeModel(refresh: false)
        guard let theme = model.catalogue.index?.theme(id) else {
            throw ControlError(.badValue, ExtensionCatalogue.Problem.themeNotListed(id).reason + " pilot theme catalogue lists them.")
        }
        let had = model.installed[id]
        guard had != theme.digest else { return .object(["installed": .string(id), "changed": .bool(false)]) }
        if let why = model.refusal(theme) { throw ControlError(.badValue, why + " Nothing asked.") }
        let folder = owner.store.writableRoot + "/" + id
        return try await AllowPrompt.gate.allow(themeAsk(theme, replacing: had != nil, into: folder), peer: peer) { () throws(ControlError) in
            let loaded: ThemePackStore.Loaded
            do { loaded = try await model.install(theme, expecting: had) } catch {
                throw ControlError(.badValue, "\(theme.title) was not \(had == nil ? "installed" : "updated"): \(ExtensionCatalogue.Problem.reason(error))")
            }
            log.notice("theme get: \(id, privacy: .public) from the catalogue, from the pilot command")
            return .object(["installed": .string(id), "title": .string(loaded.pack.title), "changed": .bool(true), "replaced": .bool(had != nil),
                            "folder": .string(loaded.folder), "revision": .string(loaded.revision), "images": .number(Double(loaded.images.count))])
        }
    }

    /// The tab's model, its index read (or kept) and each theme's standing read again; a failed read is the command's error.
    private static func themeModel(refresh: Bool) async throws(ControlError) -> ThemeCatalogueModel {
        let model = ThemeCatalogueModel.shared
        await model.open(refresh: refresh)
        if case .failed(let why) = model.load { throw ControlError(.notReady, "\(why) Try again: pilot theme catalogue refresh") }
        return model
    }

    /// A catalogue theme's question, from the index entry every file is checked against: where it comes from, where it
    /// goes, every file, and what it replaces.
    static func themeAsk(_ theme: ExtensionCatalogue.Theme, replacing: Bool, into folder: String) -> ControlGate.Ask {
        let size = ByteCountFormatter.string(fromByteCount: Int64(theme.size), countStyle: .file)
        let verb = replacing ? "Update" : "Install"
        return ControlGate.Ask("\(verb) theme", lines: [
            "\(theme.id) (\(theme.title)) from Pilot's catalogue, \(ExtensionCatalogue.home)",
            "into \(folder)",
            "files: \(theme.files.map(\.path).joined(separator: ", ")); \(theme.files.count) in all, \(size)",
            replacing ? "replaces the pack \(theme.id) in your themes, which goes to the Trash" : "replaces nothing: no pack \(theme.id) is in your themes",
            "runs nothing: a theme is data, and installing applies nothing",
        // Named by id, as every summary is (ExtensionTools.titled): a pack's title is its author's words.
        ]).summed("\(verb) theme \(theme.id)?", [replacing ? "The pack in your themes goes to the Trash; nothing runs" : "Nothing runs, and nothing is applied",
                                                    "From Pilot's catalogue: \(ExtensionCatalogue.home)"])
    }
}
