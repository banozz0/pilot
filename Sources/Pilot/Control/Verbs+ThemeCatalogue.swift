import Foundation
import PilotCore

/// `pilot theme catalogue|get|remove` (public-repo spec T20): the catalogue's theme packs, read through the model the
/// Extensions page shares (one index, kept ten minutes), installed into your themes by ThemeInstaller after Allow, every
/// file held to the index's sha256. A pack is data: installing applies nothing.
extension ControlVerbs {
    /// `theme catalogue [refresh]`: each theme the catalogue offers, with where it stands in your themes.
    static func themeCatalogue(refresh: Bool, _ owner: ThemeCoordinator) async throws(ControlError) -> JSONValue {
        let model = ExtensionCatalogueModel.shared
        try await readCatalogue(model, refresh: refresh)
        let themes = model.index?.themes ?? []
        let installer = themeInstaller(owner), ids = themes.map(\.id)
        let installed = await Task.detached { installer.installed(ids) }.value
        return .object(["count": .number(Double(themes.count)), "themes": .array(themes.map { theme in
            let standing = ExtensionCatalogue.standing(of: theme, installed: installed)
            var o: [String: JSONValue] = [
                "id": .string(theme.id), "title": .string(theme.title), "dark": .bool(theme.dark), "styles": .array(theme.styles.map(JSONValue.string)),
                "standing": .string(standing.word), "button": .string(standing.label),
                "files": .number(Double(theme.files.count)), "size": .number(Double(theme.size)), "digest": .string(theme.digest),
            ]
            o["preview"] = theme.preview.map(JSONValue.string)
            return .object(o)
        })])
    }

    /// `theme get <id>`: installs a catalogue theme, or replaces the pack with its id in your themes, after Allow.
    static func getTheme(_ id: String, _ owner: ThemeCoordinator, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let model = ExtensionCatalogueModel.shared
        try await readCatalogue(model, refresh: false)
        guard let theme = model.index?.theme(id) else {
            throw ControlError(.badValue, ExtensionCatalogue.Problem.themeNotListed(id).reason + " pilot theme catalogue lists them.")
        }
        let installer = themeInstaller(owner)
        let had = await Task.detached { installer.installed([id]) }.value[id]
        guard had != theme.digest else { return .object(["installed": .string(id), "changed": .bool(false)]) }
        // Its files are the applied theme's (wallpapers on the desktop now): replaced or removed only once another is applied.
        guard had == nil || !isApplied(id, owner) else {
            throw ControlError(.badValue, "\(id) is the theme applied now: apply another or restore first, then update it. Nothing asked.")
        }
        // An id Pilot's own themes or another pack root hold is refused before asking, so Allow never starts an install bound to fail.
        do { try installer.refuseTaken(id) } catch { throw ControlError(.badValue, ExtensionCatalogue.Problem.reason(error) + " Nothing asked.") }
        let folder = owner.store.writableRoot + "/" + id
        return try await AllowPrompt.gate.allow(themeAsk(theme, replacing: had != nil, into: folder), peer: peer) { () throws(ControlError) in
            let loaded: ThemePackStore.Loaded
            do { loaded = try await Task.detached { try await installer.install(theme, expecting: had) }.value } catch {
                throw ControlError(.badValue, "\(theme.title) was not \(had == nil ? "installed" : "updated"): \(ExtensionCatalogue.Problem.reason(error))")
            }
            log.notice("theme get: \(id, privacy: .public) from the catalogue, from the pilot command")
            return .object(["installed": .string(id), "title": .string(loaded.pack.title), "changed": .bool(true), "replaced": .bool(had != nil),
                            "folder": .string(loaded.folder), "revision": .string(loaded.revision), "images": .number(Double(loaded.images.count))])
        }
    }

    /// `theme remove <id>`: a pack in your themes to the Trash after Allow; never the one applied now, whose files are in use.
    static func removeTheme(_ id: String, _ owner: ThemeCoordinator, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let installer = themeInstaller(owner)
        guard let folder = installer.folder(id) else { throw ControlError(.badValue, ExtensionCatalogue.Problem.themeNotInstalled(id).reason) }
        guard !isApplied(id, owner) else { throw ControlError(.badValue, "\(id) is the theme applied now: apply another or restore first. Nothing asked.") }
        // Its manifest alone, for the title: a full load decodes every wallpaper.
        let title = (try? ThemeFiles.read(root: owner.store.writableRoot, path: id + "/manifest.json").bytes).flatMap { try? ThemePack.decode($0) }?.title ?? id
        let ask = ControlGate.Ask("Remove theme", lines: ["\(id) (\(title)) at \(folder.path) goes to the Trash"])
            .summed("Remove theme \(id)?", ["Its folder goes to the Trash"])
        return try await AllowPrompt.gate.allow(ask, peer: peer) { () throws(ControlError) in
            let removed = await Task.detached { Result { try installer.remove(id) } }.value
            if case .failure(let error) = removed { throw ControlError(.badValue, ExtensionCatalogue.Problem.reason(error)) }
            log.notice("theme remove: \(id, privacy: .public), from the pilot command")
            return .object(["removed": .string(id), "title": .string(title)])
        }
    }

    /// Whether `id` is the theme applied now; a ledger that does not read counts as yes, so nothing in use is replaced.
    private static func isApplied(_ id: String, _ owner: ThemeCoordinator) -> Bool {
        do { return try owner.selected()?.id == id } catch { return true }
    }

    /// The installer for your themes, reading the catalogue where the Extensions page does.
    private static func themeInstaller(_ owner: ThemeCoordinator) -> ThemeInstaller { ThemeInstaller(store: owner.store, source: CatalogueSource.live) }

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
