import Foundation
import PilotCore

extension ControlVerbs {
    private static let themeApps: [String: ThemeCoordinator.AppSwitch] = Dictionary(uniqueKeysWithValues: ThemeAppKind.allCases.map { ($0.rawValue, ThemeCoordinator.AppSwitch.app($0)) }).merging(["zed": .zed, "obsidian": .obsidian, "ghostex": .ghostex]) { _, new in new }

    /// Native controls call this coordinator too. There is no caller approval switch or executor verb.
    func registerThemes(_ coordinator: @escaping @MainActor @Sendable () throws -> ThemeCoordinator) {
        register(ControlVerb("theme", help: "Create, edit, duplicate, delete or transfer data-only local packs (delete takes only a pack you made or imported, never Pilot's own or the applied one), or install them from Pilot's catalogue (theme catalogue, get; every file checked against its sha256; a built-in theme's plan downloads its wallpapers from there); review exact changes before Apply/Restore. Zed, every Obsidian vault, Ghostex's window colour, VS Code, Cursor, Windsurf, Kitty, Alacritty, WezTerm, iTerm2, btop, lazygit, Neovim, fish and Vesktop follow when found, with switches to turn each off; custom mappings need local bindings and optional reloads ask separately. A theme changes everything it carries and Restore undoes it; follow mode personal keeps macOS Light or Dark as it is. Toybox colours stay scoped. Use pilot guide theme or /theme in Ask Pilot. Installed-app refresh and CSS precedence need checking in the target app.",
                             usage: "pilot theme list | list-all | colours | catalogue [refresh] | get <catalogue-id> | show <id> | check <id> | new <absolute-folder> | edit <id> <absolute-folder> <revision> | duplicate <source-id> <new-id> <title> | import <absolute-portable-file> [revision] | export <id> <absolute-new-file> | delete <id> | follow mode <pack|personal> | plan apply <id> | plan restore | apply <plan-id> | restore <plan-id> | save <source-id> <base64-manifest> [revision] | attach <id> <absolute-image-or-folder> <revision> | status | bind zed <absolute-config-root> | opt-out zed | bind obsidian <absolute-vault-root> <config-folder> | opt-out obsidian [absolute-vault-root] | follow <zed|obsidian|ghostex|vscode|cursor|windsurf|kitty|alacritty|wezterm|iterm2|btop|lazygit|neovim|fish|vesktop> <on|off> | follow vault <absolute-vault-root> <on|off> | bind custom <local-binding-json> | bind custom64 <base64-local-binding-json>", flags: []) { call throws(ControlError) in
            do {
                let owner = try coordinator(), words = call.words
                switch words.first {
                case "list" where words.count == 1: return try themeJSON(owner.store.list().filter { $0.compatible(with: owner.style()) })
                case "colours" where words.count == 1:
                    return .array(PilotTheme.designed(for: owner.style()).map {
                        .object(["id": .string($0.id), "title": .string($0.name)])
                    })
                case "list-all" where words.count == 1: return try themeJSON(owner.store.list())
                case "catalogue" where words.count == 1 || words == ["catalogue", "refresh"]:
                    return try await Self.themeCatalogue(refresh: words.count == 2, owner)
                case "get" where words.count == 2: return try await Self.getTheme(words[1], owner, peer: call.peer)
                case "new" where words.count == 2:
                    try owner.editorPath(words[1])
                    return try themeJSON(owner.saveDraft(ThemePackStore.readFolder(words[1])).pack)
                case "edit" where words.count == 4:
                    try owner.editorPath(words[2])
                    let draft = try ThemePackStore.readFolder(words[2])
                    guard draft.pack.id == words[1] else { throw ThemeFailure("edit identity differs; duplicate instead") }
                    return try themeJSON(owner.saveDraft(draft, replacing: words[3]).pack)
                case "save" where words.count == 3 || words.count == 4:
                    // The unchanged one-command grammar carries data as base64, never shell code.
                    guard let bytes = Data(base64Encoded: words[2]) else { throw ThemeFailure("invalid base64 manifest") }
                    let raw = try JSONDecoder().decode(JSONValue.self, from: bytes)
                    try ThemeLedger.validateFields(bytes, encoded: ThemeDigest.encoded(raw))
                    var draft = try owner.store.draft(words[1])
                    draft.pack = try ThemePack.decode(bytes)
                    draft.files = draft.files.filter { path, _ in
                        path == "PROVENANCE.md" || draft.pack.wallpapers.contains { path == $0 || path.hasPrefix($0 + "/") }
                    }
                    return try themeJSON(owner.saveDraft(draft, replacing: words.count == 4 ? words[3] : nil).pack)
                case "attach" where words.count == 4:
                    try owner.editorPath(words[2])
                    let draft = try ThemePackStore.attaching([words[2]], to: owner.store.draft(words[1]))
                    return try themeJSON(owner.saveDraft(draft, replacing: words[3]).pack)
                case "duplicate" where words.count == 4:
                    return try themeJSON(owner.duplicate(words[1], id: words[2], title: words[3]).pack)
                case "import" where words.count == 2 || words.count == 3:
                    try owner.editorPath(words[1])
                    return try themeJSON(owner.saveDraft(ThemePackStore.readPortable(words[1]), replacing: words.count == 3 ? words[2] : nil).pack)
                case "export" where words.count == 3:
                    try owner.export(words[1], to: words[2])
                    return .object(["exported": .string(words[2]), "applied": .bool(false)])
                case "delete" where words.count == 2:
                    try owner.delete(words[1])
                    return .object(["deleted": .string(words[1]), "applied": .bool(false)])
                case "follow" where words.count == 3 && Self.themeApps[words[1]] != nil && ["on", "off"].contains(words[2]):
                    return try themeJSON(owner.stageFollows(Self.themeApps[words[1]]!, on: words[2] == "on"))
                case "follow" where words.count == 4 && words[1] == "vault" && ["on", "off"].contains(words[3]):
                    return try themeJSON(owner.stageFollows(.vault(words[2]), on: words[3] == "on"))
                case "follow" where words.count == 3 && words[1] == "mode" && ["pack", "personal"].contains(words[2]):
                    return try themeJSON(owner.stageMode(follow: words[2] == "pack"))
                case "show" where words.count == 2, "check" where words.count == 2:
                    let loaded = try owner.store.load(words[1])
                    // Check includes adapter validation and ownership without changing files, but for a shipped pack's
                    // pictures, which its plan fetches from the catalogue (ShippedWallpapers).
                    if words[0] == "check" { _ = try await owner.plan(words[1]) }
                    return .object(["pack": try themeJSON(loaded.pack), "revision": .string(loaded.revision), "factory": .bool(loaded.factory), "images": try themeJSON(loaded.images), "valid": .bool(true)])
                case "plan" where words.count == 3 && words[1] == "apply":
                    return try owner.describe(await owner.plan(words[2]))
                case "plan" where words.count == 2 && words[1] == "restore":
                    return try owner.describe(await owner.plan(nil))
                case "apply" where words.count == 2, "restore" where words.count == 2:
                    return try await owner.apply(words[1], peer: call.peer)
                case "bind" where words.count == 3 && words[1] == "zed":
                    return try await owner.bindZed(words[2], optOut: false, peer: call.peer)
                case "opt-out" where words == ["opt-out", "zed"]:
                    return try await owner.bindZed(nil, optOut: true, peer: call.peer)
                case "bind" where words.count == 4 && words[1] == "obsidian":
                    return try await owner.bindObsidian(words[2], configDir: words[3], optOut: false, peer: call.peer)
                case "bind" where words.count == 3 && ["custom", "custom64"].contains(words[1]):
                    let bytes: Data
                    if words[1] == "custom64" {
                        guard let decoded = Data(base64Encoded: words[2]) else { throw ThemeFailure("invalid base64 local binding") }
                        bytes = decoded
                    } else { bytes = Data(words[2].utf8) }
                    let binding = try JSONDecoder().decode(ThemeMappingBinding.self, from: bytes)
                    try ThemeLedger.validateFields(bytes, encoded: ThemeDigest.encoded(binding))
                    return try await owner.bindCustom(binding, peer: call.peer)
                case "opt-out" where (words.count == 2 || words.count == 3) && words[1] == "obsidian":
                    return try await owner.bindObsidian(words.count == 3 ? words[2] : nil, configDir: nil, optOut: true, peer: call.peer)
                case "status" where words.count == 1:
                    return .object(["apps": try themeJSON(owner.appFollowing()), "selected": try owner.selected().map(themeJSON) ?? .null, "owned": .bool(owner.ownsGhostty), "effects": .string(owner.effects.kind), "zed": try themeJSON(owner.zedSelection), "wallpaper": try owner.wallpaper.map { try themeJSON($0.read()) } ?? .null, "wallpaperOwned": try themeJSON(owner.wallpaperClaims()), "following": try themeJSON(owner.following()), "native": try owner.native.map { try themeJSON($0.read()) } ?? .null])
                case "fixture-press" where words.count == 2:
                    return try await owner.fixturePress(words[1] == "restore" ? nil : words[1])
                case "fixture-cycle" where words.count == 3:
                    return try await owner.fixtureCycle(display: words[1], selection: words[2])
                case "fixture-style" where words.count == 2:
                    return try owner.fixtureStyle(words[1])
                case "fixture-colour" where words.count == 2:
                    return try owner.fixtureColour(words[1])
                case "fixture-draft" where words.count > 1:
                    return try await owner.fixtureDraft(Array(words.dropFirst()))
                default: throw ThemeFailure("use pilot help theme")
                }
            } catch let error as ControlError { throw error }
            catch { throw ControlError(.badValue, String(describing: error)) }
        })
    }
}

private func themeJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: ThemeDigest.encoded(value))
}

extension ThemeCoordinator {
    private func reviewJSON(_ plan: ThemePlan) -> JSONValue {
        let words = review(plan, appearance: appearanceChange(plan))
        func strings(_ lines: [String]) -> JSONValue { .array(lines.map(JSONValue.string)) }
        return .object(["changes": strings(words.changes), "skipped": strings(words.skipped), "details": strings(words.details), "short": strings(words.short), "next": strings(words.next), "kept": strings(words.kept)])
    }
    func describe(_ plan: ThemePlan) throws -> JSONValue {
        .object(["id": .string(plan.id), "operation": .string(plan.packID == nil ? "restore" : "apply"),
                 "pack": plan.packID.map(JSONValue.string) ?? .null, "revision": plan.revision.map(JSONValue.string) ?? .null,
                 "review": reviewJSON(plan), "changes": .array(try plan.mutations.map { change in
                    .object(["path": .string(change.target.root + "/" + change.target.path), "selector": try themeJSON(change.selector),
                             "before": change.before.map { .string(String(decoding: $0, as: UTF8.self)) } ?? .null,
                             "after": change.after.map { .string(String(decoding: $0, as: UTF8.self)) } ?? .null,
                             "proposedBytes": change.replacement.map { .string(String(decoding: $0, as: UTF8.self)) } ?? .null,
                             "bindingID": change.bindingID.map(JSONValue.string) ?? .null])
                 }), "native": try appearanceChange(plan).map(themeJSON) ?? .null,
                 "reloads": .array(try plan.reloads.map { try themeJSON($0.binding) }),
                 "wallpapers": try themeJSON(plan.wallpapers), "ghostex": try themeJSON(plan.ghostex), "warnings": .array(plan.warnings.map(JSONValue.string)), "applied": .bool(false)])
    }
}
