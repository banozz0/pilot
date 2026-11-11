import Foundation

public enum ThemeApps {
    public static let schemeName = ThemeAppKind.schemeName
    public static let colourKey = "workbench.colorCustomizations"
    private static let begin = GhosttyThemeAdapter.begin, end = GhosttyThemeAdapter.end
    private static let editors: [(ThemeAppKind, String)] = [(.vscode, "Code"), (.cursor, "Cursor"), (.windsurf, "Windsurf")]

    /// Each app's bundle name in an Applications folder.
    private static let bundles: [ThemeAppKind: String] = [.vscode: "Visual Studio Code.app", .cursor: "Cursor.app", .windsurf: "Windsurf.app",
                                                           .kitty: "kitty.app", .alacritty: "Alacritty.app", .wezterm: "WezTerm.app", .iterm2: "iTerm.app"]

    /// Each installed app: its config folder, its config file (WezTerm's ~/.wezterm.lua), or its bundle in one of
    /// `applications`. A folder that isn't there yet is where the app's docs put it, and Apply makes it. A folder name is
    /// taken as it is on disk, because a differing case fails the canonical path check.
    public static func detect(home: String, applications: [String]) -> [ThemeAppBinding] {
        let files = FileManager.default
        func folder(_ path: String) -> Bool {
            var isFolder: ObjCBool = false
            return files.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
        }
        func installed(_ kind: ThemeAppKind) -> Bool { applications.contains { folder($0 + "/" + bundles[kind]!) } }
        let support = home + "/Library/Application Support"
        let names = (try? files.contentsOfDirectory(atPath: support)) ?? []
        func onDisk(_ name: String) -> String { names.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name }
        var found: [ThemeAppBinding] = []
        for (kind, name) in editors {
            let root = "\(support)/\(onDisk(name))/User"
            if folder(root) || installed(kind) { found.append(.init(kind: kind, root: root, config: "settings.json", generated: nil)) }
        }
        let config = home + "/.config"
        if folder(config + "/kitty") || installed(.kitty) { found.append(.init(kind: .kitty, root: config + "/kitty", config: "kitty.conf", generated: "pilot-theme.conf")) }
        if folder(config + "/alacritty") || installed(.alacritty) { found.append(.init(kind: .alacritty, root: config + "/alacritty", config: "alacritty.toml", generated: "pilot-theme.toml")) }
        // WezTerm reads its colour schemes from ~/.config/wezterm/colors wherever its wezterm.lua is (its docs, Colors & Appearance).
        if folder(config + "/wezterm") || files.fileExists(atPath: home + "/.wezterm.lua") || installed(.wezterm) {
            found.append(.init(kind: .wezterm, root: config + "/wezterm", config: nil, generated: "colors/\(schemeName).toml"))
        }
        let iterm = "\(support)/\(onDisk("iTerm2"))"
        if folder(iterm) || installed(.iterm2) { found.append(.init(kind: .iterm2, root: iterm, config: nil, generated: "DynamicProfiles/pilot-theme.json")) }
        return found
    }

    /// The folders an app's files may wait on: its root and anything below it, made by Apply.
    public static func roots(home: String) -> [String] {
        let support = home + "/Library/Application Support"
        return editors.map { "\(support)/\($0.1)/User" } + ["kitty", "alacritty", "wezterm"].map { home + "/.config/" + $0 } + ["\(support)/iTerm2"]
    }

    /// Whether this path is an app's own config, the one file dotfiles users link. Decided from fixed shapes, never a journal.
    public static func linkable(root: String, path: String, home: String) -> Bool {
        let support = (home + "/Library/Application Support/").lowercased(), lower = root.lowercased()
        if path == "settings.json", lower.hasPrefix(support), lower.hasSuffix("/user") { return editors.contains { lower == support + $0.1.lowercased() + "/user" } }
        return (root == home + "/.config/kitty" && path == "kitty.conf") || (root == home + "/.config/alacritty" && path == "alacritty.toml")
    }

    public static func valid(_ selector: ThemeSelector, path: String, app: ThemeAppBinding) -> Bool {
        switch selector {
        case .file: return path == app.generated
        case .jsonValue(let keys): return path == app.config && keys == [colourKey] && app.generated == nil
        case .block(let b, let e, let prefix): return path == app.config && b == begin && e == end && (0...2).contains(prefix)
        case .blockAfter(let anchor, let b, let e): return app.kind == .alacritty && path == app.config && anchor == "[general]" && b == begin && e == end
        case .jsonMembership: return false
        }
    }

    private static func ansi(_ pack: ThemePack) -> [String] {
        GhosttyLook.palette.map { pack.ghostty[role: $0] }
    }

    /// What this app's files become. Throws why the app cannot take the theme, which skips it with that reason.
    public static func prepare(_ pack: ThemePack, app: ThemeAppBinding, snapshots: [ThemeSnapshot], claims: [ThemeClaim]) throws -> (changes: [ThemeMutation], notes: [String]) {
        func snapshot(_ path: String) throws -> ThemeSnapshot {
            guard let found = snapshots.first(where: { $0.path == path }) else { throw ThemeFailure("missing \(path)") }
            return found
        }
        func asset(_ path: String, _ bytes: Data) throws -> ThemeMutation {
            let target = try snapshot(path)
            guard target.bytes == nil || claims.contains(where: { $0.path == path && $0.selector == .file }) else { throw ThemeFailure("a file named \(URL(fileURLWithPath: path).lastPathComponent) from somewhere else is already there") }
            return ThemeMutation(target: target, selector: .file, before: target.bytes, after: bytes, replacement: bytes)
        }
        switch app.kind {
        case .vscode, .cursor, .windsurf:
            let target = try snapshot(app.config!)
            let value = try ThemeDigest.encoded(colours(pack))
            let selector = ThemeSelector.jsonValue(path: [colourKey])
            let change = try block(selector, target, text: value)
            return ([change], change.before != nil && claims.isEmpty ? ["\(app.kind.name): your own \(colourKey) comes back on Restore"] : [])
        case .kitty:
            let generated = app.root + "/" + app.generated!
            var lines = ["foreground \(pack.palette["foreground"]!)", "background \(pack.palette["background"]!)",
                         "selection_background \(pack.palette["selection"]!)", "selection_foreground \(pack.palette["foreground"]!)",
                         "cursor \(pack.palette["bright_foreground"]!)"]
            lines += ansi(pack).enumerated().map { "color\($0.offset) \($0.element)" }
            return ([try asset(app.generated!, Data((lines.joined(separator: "\n") + "\n").utf8)), try loader(snapshot(app.config!), claims, line: "include \(generated)")], [])
        case .alacritty:
            let path = app.root + "/" + app.generated!
            // Alacritty takes the first config it finds, ~/.config/alacritty/alacritty.toml before ~/.alacritty.toml (its docs).
            let home = URL(fileURLWithPath: app.root).deletingLastPathComponent().deletingLastPathComponent().path
            if try snapshot(app.config!).bytes == nil, FileManager.default.fileExists(atPath: home + "/.alacritty.toml") {
                throw ThemeFailure("its config is ~/.alacritty.toml, and a new ~/.config/alacritty/alacritty.toml would hide it. Move it there for Pilot to follow")
            }
            let c = ansi(pack), names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
            func table(_ title: String, _ colours: ArraySlice<String>) -> String { "[\(title)]\n" + zip(names, colours).map { "\($0) = \"\($1)\"" }.joined(separator: "\n") + "\n" }
            let text = "[colors.primary]\nbackground = \"\(pack.palette["background"]!)\"\nforeground = \"\(pack.palette["foreground"]!)\"\n\n" + table("colors.normal", c[0..<8]) + "\n" + table("colors.bright", c[8..<16])
            return ([try asset(app.generated!, Data(text.utf8)), try alacrittyLoader(snapshot(app.config!), claims, path: path)], ["Alacritty: colours set in alacritty.toml itself still win"])
        case .wezterm:
            let c = ansi(pack)
            func list(_ values: ArraySlice<String>) -> String { "[" + values.map { "\"\($0)\"" }.joined(separator: ", ") + "]" }
            let text = """
            [colors]
            foreground = "\(pack.palette["foreground"]!)"
            background = "\(pack.palette["background"]!)"
            cursor_bg = "\(pack.palette["bright_foreground"]!)"
            cursor_fg = "\(pack.palette["background"]!)"
            cursor_border = "\(pack.palette["bright_foreground"]!)"
            selection_fg = "\(pack.palette["foreground"]!)"
            selection_bg = "\(pack.palette["selection"]!)"
            ansi = \(list(c[0..<8]))
            brights = \(list(c[8..<16]))

            [metadata]
            name = "\(schemeName)"

            """
            return ([try asset(app.generated!, Data(text.utf8))], ["WezTerm: only the colour scheme file is written; your wezterm.lua stays as it is"])
        case .iterm2:
            func colour(_ hex: String) -> JSONValue {
                let value = Int(hex.dropFirst(), radix: 16) ?? 0
                return .object(["Red Component": .number(Double((value >> 16) & 255) / 255), "Green Component": .number(Double((value >> 8) & 255) / 255),
                                "Blue Component": .number(Double(value & 255) / 255), "Alpha Component": .number(1), "Color Space": .string("sRGB")])
            }
            var profile: [String: JSONValue] = ["Name": .string(schemeName), "Guid": .string("7C2E9A54-6B1D-4F0E-9B65-3D8E1C7A2F10"),
                "Background Color": colour(pack.palette["background"]!), "Foreground Color": colour(pack.palette["foreground"]!),
                "Bold Color": colour(pack.palette["bright_foreground"]!), "Cursor Color": colour(pack.palette["bright_foreground"]!),
                "Cursor Text Color": colour(pack.palette["background"]!), "Selection Color": colour(pack.palette["selection"]!),
                "Selected Text Color": colour(pack.palette["foreground"]!)]
            for (index, value) in ansi(pack).enumerated() { profile["Ansi \(index) Color"] = colour(value) }
            return ([try asset(app.generated!, try ThemeDigest.encoded(JSONValue.object(["Profiles": .array([.object(profile)])])))], ["iTerm2: appears as a profile to pick; your default profile stays"])
        }
    }

    private static func colours(_ pack: ThemePack) -> JSONValue {
        let p = pack.palette, c = ansi(pack)
        var map: [String: String] = [
            "editor.background": p["background"]!, "editor.foreground": p["foreground"]!,
            "sideBar.background": p["dark_background"]!, "sideBar.foreground": p["light_foreground"]!,
            "activityBar.background": p["dark_background"]!, "activityBar.foreground": p["foreground"]!,
            "statusBar.background": p["dark_background"]!, "statusBar.foreground": p["light_foreground"]!,
            "titleBar.activeBackground": p["dark_background"]!, "titleBar.activeForeground": p["foreground"]!,
            "tab.activeBackground": p["background"]!, "tab.inactiveBackground": p["dark_background"]!,
            "panel.background": p["dark_background"]!, "terminal.background": p["background"]!, "terminal.foreground": p["foreground"]!]
        let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        for (index, name) in names.enumerated() { map["terminal.ansi" + name] = c[index]; map["terminal.ansiBright" + name] = c[index + 8] }
        return .object(map.mapValues(JSONValue.string))
    }

    private static func block(_ selector: ThemeSelector, _ target: ThemeSnapshot, text: Data) throws -> ThemeMutation {
        ThemeMutation(target: target, selector: selector, before: try ThemeRegions.owned(selector, in: target.bytes), after: text,
                      replacement: try ThemeRegions.replacing(selector, in: target.bytes, with: text))
    }

    /// Our block at the end of a config, as Ghostty's: a newline goes first only when the file does not end in one.
    private static func loader(_ target: ThemeSnapshot, _ claims: [ThemeClaim], line: String) throws -> ThemeMutation {
        let bytes = target.bytes ?? Data(), newline = bytes.contains(13) ? "\r\n" : "\n"
        let probe = ThemeSelector.block(begin: begin, end: end, prefix: 0)
        let hasBlock = try ThemeRegions.range(probe, in: target.bytes) != nil
        let prefix = claims.first { $0.path == target.path }.map { claim -> Int in if case .block(_, _, let count) = claim.selector { return count }; return 0 }
            ?? (!hasBlock && !bytes.isEmpty && bytes.last != 10 ? newline.utf8.count : 0)
        let selector = ThemeSelector.block(begin: begin, end: end, prefix: prefix)
        let text = Data(((prefix > 0 ? newline : "") + [begin, line, end].joined(separator: newline)).utf8)
        return try block(selector, target, text: text)
    }

    /// `general.import` by plain lines: inside an existing [general] when there is one, otherwise a table of our own at the end.
    private static func alacrittyLoader(_ target: ThemeSnapshot, _ claims: [ThemeClaim], path: String) throws -> ThemeMutation {
        let quoted = "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let existing = claims.first { $0.path == target.path }
        let bytes = target.bytes ?? Data()
        guard let text = String(data: bytes, encoding: .utf8) else { throw ThemeFailure("alacritty.toml is not UTF-8") }
        var general = false, seenTable = false, inGeneral = false, inOurs = false
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let stop = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[cursor..<stop].trimmingCharacters(in: .whitespaces)
            if line == begin { inOurs = true } else if line == end { inOurs = false }
            else if !inOurs, !line.hasPrefix("#") {
                if line.hasPrefix("[") {
                    seenTable = true; inGeneral = line.hasPrefix("[general]") && !line.hasPrefix("[general.")
                    if inGeneral, line != "[general]" { throw ThemeFailure("its [general] line has a comment Pilot won't edit around. Add import = [\(quoted)] under it yourself") }
                    if inGeneral { general = true }
                }
                else if line.hasPrefix("general."), !seenTable {
                    throw ThemeFailure("alacritty.toml sets general options as dotted keys. Add general.import = [\(quoted)] yourself")
                }
                else if line.hasPrefix("general.import") || (line.hasPrefix("import") && (!seenTable || inGeneral) && line.dropFirst(6).trimmingCharacters(in: .whitespaces).hasPrefix("=")) {
                    throw ThemeFailure("alacritty.toml already has an import list. Add \(quoted) to it yourself")
                }
            }
            cursor = stop < text.endIndex ? text.index(after: stop) : stop
        }
        if general || existing.map({ if case .blockAfter = $0.selector { true } else { false } }) == true {
            let inner = "\n" + [begin, "import = [\(quoted)]", end].joined(separator: "\n")
            return try block(.blockAfter(anchor: "[general]", begin: begin, end: end), target, text: Data(inner.utf8))
        }
        return try loader(target, claims, line: "[general]\nimport = [\(quoted)]")
    }
}
