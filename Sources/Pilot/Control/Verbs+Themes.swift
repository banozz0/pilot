import Foundation
import PilotCore

extension ControlVerbs {
    private static let themeApps: [String: ThemeCoordinator.AppSwitch] = Dictionary(uniqueKeysWithValues: ThemeAppKind.allCases.map { ($0.rawValue, ThemeCoordinator.AppSwitch.app($0)) }).merging(["zed": .zed, "obsidian": .obsidian, "ghostex": .ghostex]) { _, new in new }

    /// `theme set`'s `role=hex` words on `pack`. A bare role sets the palette, and the variant of the pack's own mode, which
    /// must equal it; `light.<role>` or `dark.<role>` sets that variant (the palette too when it is the pack's own mode). The
    /// hex goes without `#`, which the agent's shell gate refuses unquoted; one with it is taken too. A role the pack does
    /// not hold, or a word that is no six-digit hex, is refused before anything is saved.
    static func recoloured(_ pack: ThemePack, _ words: ArraySlice<String>) throws -> ThemePack {
        var pack = pack
        let own = pack.dark ? "dark" : "light"
        for word in words {
            let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ThemeFailure("\(word): give role=hex, as accent=FF9E64") }
            var (mode, role) = (own, parts[0])
            if let dot = role.firstIndex(of: "."), ["light", "dark"].contains(String(role[..<dot])) {
                (mode, role) = (String(role[..<dot]), String(role[role.index(after: dot)...]))
            }
            let hex = parts[1].hasPrefix("#") ? String(parts[1].dropFirst()) : parts[1]
            guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { throw ThemeFailure("\(parts[1]) is no colour: six hex digits, as FF9E64") }
            let colour = "#" + hex.uppercased()
            if mode == own {
                guard pack.palette[role] != nil else {
                    throw ThemeFailure("\(pack.id) has no role \(role); its roles: \(pack.palette.keys.sorted().joined(separator: ", "))")
                }
                pack.palette[role] = colour
                if pack.variants?[own] != nil { pack.variants?[own]?[role] = colour }
            } else {
                guard pack.variants?[mode]?[role] != nil else { throw ThemeFailure("\(pack.id) has no \(mode) variant with role \(role)") }
                pack.variants?[mode]?[role] = colour
            }
        }
        return pack
    }

    /// Native controls call this coordinator too. There is no caller approval switch or executor verb.
    func registerThemes(_ coordinator: @escaping @MainActor @Sendable () throws -> ThemeCoordinator) {
        register(ControlVerb("theme", help: "Create, edit, duplicate, delete or transfer data-only local packs (delete removes a pack you made or imported, or hides one of Pilot's own until theme get brings it back, never the theme in use or the last one), or install them from Pilot's catalogue (theme catalogue, get; every file checked against its sha256; a built-in theme's plan downloads its wallpapers from there); review exact changes before Apply/Restore. Zed, every Obsidian vault, Ghostex's window colour, VS Code, Cursor, Windsurf, Kitty, Alacritty, WezTerm, iTerm2, btop, lazygit, Neovim, fish and Vesktop follow when found, with switches to turn each off; custom mappings need local bindings and optional reloads ask separately. A theme changes everything it carries and Restore undoes it; follow mode personal keeps macOS Light or Dark as it is. Toybox colours stay scoped. Use pilot guide theme or /theme in Ask Pilot. Installed-app refresh and CSS precedence need checking in the target app.",
                             usage: "pilot theme list [--summary] | list-all | colours | catalogue [refresh] | get <catalogue-id> | show <id> | check <id> | new <absolute-folder> | edit <id> <absolute-folder> <revision> | duplicate <source-id> <new-id> <title> | import <absolute-portable-file> [revision] | export <id> <absolute-new-file> | delete <id> | publish <id> | follow mode <pack|personal> | plan apply <id> [--summary] | plan restore [--summary] | take <file> | apply <plan-id> | restore <plan-id> | set <id> <revision> <role>=<hex>… (light.<role>= or dark.<role>= for one variant) | save <source-id> <base64-manifest> [revision] | attach <id> <absolute-image-or-folder> <revision> | status | bind zed <absolute-config-root> | opt-out zed | bind obsidian <absolute-vault-root> <config-folder> | opt-out obsidian [absolute-vault-root] | follow <zed|obsidian|ghostex|vscode|cursor|windsurf|kitty|alacritty|wezterm|iterm2|btop|lazygit|neovim|fish|vesktop> <on|off> | follow vault <absolute-vault-root> <on|off> | bind custom <local-binding-json> | bind custom64 <base64-local-binding-json>",
                             flags: [.init("summary", help: "a plan's id, its apply command and what it changes, without the file bytes (Allow still shows every change); for list, a line a pack: id, title, dark, yours, wallpapers", takesValue: false)]) { call throws(ControlError) in
            do {
                // --summary is a plan's alone; the rest match on the words without it.
                let owner = try coordinator(), args = call.arguments(), summary = args.has("summary"), words = args.positional
                switch words.first {
                // A removed built-in theme (Look.hiddenThemes) is left out until theme get brings it back.
                case "list" where words.count == 1:
                    let look = Look.shared, packs = try owner.store.list().filter { $0.compatible(with: owner.style()) && look.shows($0.id) }
                    // --summary: a line a pack, for the agent, whose tool shows 30,000 characters whole (AgentTool.cut):
                    // every pack's whole manifest ran to 34 KB, and it could not name the user's own (skills-test).
                    guard summary else { return try themeJSON(packs) }
                    return .array(packs.map { pack in
                        .object(["id": .string(pack.id), "title": .string(pack.title), "dark": .bool(pack.dark),
                                 "yours": .bool(!owner.store.isPilots(pack.id)), "wallpapers": .number(Double(pack.wallpapers.count))])
                    })
                case "colours" where words.count == 1:
                    return .array(Look.shared.shownThemes(for: owner.style()).map {
                        .object(["id": .string($0.id), "title": .string($0.name)])
                    })
                case "list-all" where words.count == 1: return try themeJSON(owner.store.list())
                case "catalogue" where words.count == 1 || words == ["catalogue", "refresh"]:
                    return try await Self.themeCatalogue(refresh: words.count == 2, owner)
                case "get" where words.count == 2: return try await Self.getTheme(words[1], owner, peer: call.peer)
                case "publish" where words.count == 2:
                    // One of your packs, sent as ext publish sends an extension (public-repo T23); Pilot's own stay Pilot's.
                    let loaded = try owner.store.load(words[1])
                    guard !loaded.factory else { throw ThemeFailure("\(words[1]) is one of Pilot's own themes: duplicate it to make one of yours, then publish that") }
                    let plan = try await CataloguePublish.plan(.theme(loaded))
                    return try await AllowPrompt.gate.allow(plan.ask, peer: call.peer) { () throws(ControlError) in try await CataloguePublish.publish(plan) }
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
                case "set" where words.count >= 4:
                    // A palette edit by role, so the agent never hand-writes a base64 manifest (skills-test: one save was
                    // $1.91 and 230 s of thinking). The same validator as save, save's revision guard, nothing applied.
                    let id = words[1]
                    guard !owner.store.isPilots(id) else { throw ThemeFailure("\(id) is one of Pilot's own themes: pilot theme duplicate \(id) <new-id> <title> first, then set the copy") }
                    var draft = try owner.store.draft(id)
                    draft.pack = try Self.recoloured(draft.pack, words[3...])
                    let bytes = try ThemeDigest.encoded(draft.pack)
                    try ThemeLedger.validateFields(bytes, encoded: ThemeDigest.encoded(try JSONDecoder().decode(JSONValue.self, from: bytes)))
                    draft.pack = try ThemePack.decode(bytes)
                    let saved = try owner.saveDraft(draft, replacing: words[2])
                    return .object(["pack": .string(id), "revision": .string(saved.revision), "palette": try themeJSON(saved.pack.palette),
                                    "applied": .bool(false), "next": .string("pilot theme plan apply \(id) --summary shows what applying it changes")])
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
                    // Asks first, as deleting a preset does: a pack you made goes for good (skills-test: the agent deleted one
                    // with no Allow at all). One of Pilot's own is only hidden, and says how it comes back.
                    let id = words[1], title = (try? owner.store.load(id).pack.title) ?? id
                    let what = owner.store.isPilots(id) ? "\(title) leaves Look and the lists; pilot theme get \(id) brings it back"
                        : "\(title) (\(id)): its folder and pictures go, and cannot be brought back"
                    return try await AllowPrompt.gate.allow(ControlGate.Ask("Delete theme", lines: [what]), peer: call.peer) { () throws(ControlError) in
                        let hidden: Bool
                        do { hidden = try owner.delete(id) } catch { throw ControlError(.badValue, String(describing: error)) }
                        return .object(["deleted": .string(id), "applied": .bool(false), "hidden": .bool(hidden)])
                    }
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
                    return try owner.describe(await owner.plan(words[2]), summary: summary)
                case "plan" where words.count == 2 && words[1] == "restore":
                    return try owner.describe(await owner.plan(nil), summary: summary)
                case "apply" where words.count == 2, "restore" where words.count == 2:
                    return try await owner.apply(words[1], peer: call.peer)
                case "take" where words.count == 2:
                    return try await owner.take(words[1], peer: call.peer)
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
                case "fixture-folder" where words.count == 2:
                    let adopted = try owner.fixtureFolder(words[1] == "off" ? nil : words[1])
                    return .object(["adopted": .bool(adopted), "wallpaperOwned": try themeJSON(owner.wallpaperClaims())])
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
    /// A plan as `theme plan` answers it. Keys print sorted, so `apply`, the command that applies it with its id, comes
    /// second, before `changes`, whose before, after and proposed bytes run to 100 KB with many follower apps: an agent
    /// that sees only an answer's head still has the id. `summary` leaves those bytes out.
    func describe(_ plan: ThemePlan, summary: Bool = false) throws -> JSONValue {
        let operation = plan.packID == nil ? "restore" : "apply"
        func path(_ change: ThemeMutation) -> String { change.target.root + "/" + change.target.path }
        let head: [String: JSONValue] = ["id": .string(plan.id), "operation": .string(operation), "apply": .string("pilot theme \(operation) \(plan.id)"),
                                         "pack": plan.packID.map(JSONValue.string) ?? .null, "revision": plan.revision.map(JSONValue.string) ?? .null,
                                         "review": reviewJSON(plan), "warnings": .array(plan.warnings.map(JSONValue.string)), "applied": .bool(false)]
        if summary {
            var seen = Set<String>(), files: [JSONValue] = []
            for change in plan.mutations where seen.insert(path(change)).inserted { files.append(.string(path(change))) }
            func count(_ n: Int) -> JSONValue { .number(Double(n)) }
            return .object(head.merging(["files": .array(files), "native": .bool(appearanceChange(plan) != nil),
                                         "wallpapers": count(plan.wallpapers.count), "ghostex": count(plan.ghostex.count), "reloads": count(plan.reloads.count)]) { a, _ in a })
        }
        func text(_ bytes: Data?) -> JSONValue { bytes.map { .string(String(decoding: $0, as: UTF8.self)) } ?? .null }
        let changes: [JSONValue] = try plan.mutations.map { change in
            .object(["path": .string(path(change)), "selector": try themeJSON(change.selector), "before": text(change.before), "after": text(change.after),
                     "proposedBytes": text(change.replacement), "bindingID": change.bindingID.map(JSONValue.string) ?? .null])
        }
        let full: [String: JSONValue] = ["changes": .array(changes), "native": try appearanceChange(plan).map(themeJSON) ?? .null,
                                         "reloads": .array(try plan.reloads.map { try themeJSON($0.binding) }),
                                         "wallpapers": try themeJSON(plan.wallpapers), "ghostex": try themeJSON(plan.ghostex)]
        return .object(head.merging(full) { a, _ in a })
    }
}
