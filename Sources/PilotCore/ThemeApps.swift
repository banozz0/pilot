import Foundation

public enum ThemeApps {
    public static let schemeName = ThemeAppKind.schemeName
    public static let colourKey = "workbench.colorCustomizations"
    private static let begin = GhosttyThemeAdapter.begin, end = GhosttyThemeAdapter.end
    private static let editors: [(ThemeAppKind, String)] = [(.vscode, "Code"), (.cursor, "Cursor"), (.windsurf, "Windsurf")]
    /// The line a block goes right after, for a config that cannot take it at the end.
    private static let anchors: [ThemeAppKind: String] = [.alacritty: "[general]", .lazygit: "gui:"]

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
        // btop makes ~/.config/btop on its first start (XDG_CONFIG_HOME aside) and has no app bundle: the folder is the sign.
        if folder(config + "/btop") { found.append(.init(kind: .btop, root: config + "/btop", config: "btop.conf", generated: "themes/\(btopTheme).theme")) }
        let iterm = "\(support)/\(onDisk("iTerm2"))"
        if folder(iterm) || installed(.iterm2) { found.append(.init(kind: .iterm2, root: iterm, config: nil, generated: "DynamicProfiles/pilot-theme.json")) }
        // lazygit and Neovim have no app bundle and their folder is made on first use, so the folder is the sign, as btop's.
        // lazygit on macOS reads Application Support unless XDG_CONFIG_HOME is set in its shell (`lazygit -cd`, its Config.md).
        let lazygit = "\(support)/\(onDisk("lazygit"))"
        if folder(lazygit) { found.append(.init(kind: .lazygit, root: lazygit, config: "config.yml", generated: nil)) }
        // Neovim reads ~/.config/nvim on macOS too. An init.vim alone is the config: a new init.lua beside it stops nvim starting.
        let nvim = config + "/nvim"
        if folder(nvim) {
            let vim = files.fileExists(atPath: nvim + "/init.vim") && !files.fileExists(atPath: nvim + "/init.lua")
            found.append(.init(kind: .neovim, root: nvim, config: vim ? "init.vim" : "init.lua", generated: "colors/\(neovimScheme).lua"))
        }
        return found
    }

    /// The folders an app's files may wait on: its root and anything below it, made by Apply.
    public static func roots(home: String) -> [String] {
        let support = home + "/Library/Application Support"
        return editors.map { "\(support)/\($0.1)/User" } + ["kitty", "alacritty", "wezterm", "btop", "nvim"].map { home + "/.config/" + $0 } + ["\(support)/iTerm2", "\(support)/lazygit"]
    }

    /// Whether this path is an app's own config, the one file dotfiles users link. Decided from fixed shapes, never a journal.
    public static func linkable(root: String, path: String, home: String) -> Bool {
        let support = (home + "/Library/Application Support/").lowercased(), lower = root.lowercased()
        if path == "settings.json", lower.hasPrefix(support), lower.hasSuffix("/user") { return editors.contains { lower == support + $0.1.lowercased() + "/user" } }
        return (root == home + "/.config/kitty" && path == "kitty.conf") || (root == home + "/.config/alacritty" && path == "alacritty.toml")
            || (root == home + "/.config/btop" && path == "btop.conf") || (root == home + "/.config/nvim" && ["init.lua", "init.vim"].contains(path))
            || (lower == support + "lazygit" && path == "config.yml")
    }

    public static func valid(_ selector: ThemeSelector, path: String, app: ThemeAppBinding) -> Bool {
        switch selector {
        case .file: return path == app.generated
        case .jsonValue(let keys): return editors.contains { $0.0 == app.kind } && path == app.config && keys == [colourKey]
        case .block(let b, let e, let prefix): return path == app.config && (b, e) == markers(app) && (0...2).contains(prefix)
        case .blockAfter(let anchor, let b, let e): return path == app.config && (b, e) == markers(app) && anchor == anchors[app.kind]
        case .jsonMembership: return false
        }
    }

    /// A config's comment mark, by its file's kind: Lua's, Vim script's, or the # of every other config here.
    private static func comment(_ path: String?) -> String {
        path?.hasSuffix(".lua") == true ? "--" : path?.hasSuffix(".vim") == true ? "\"" : "#"
    }

    /// Each app's block markers: Ghostty's, in its config's own comment mark.
    static func markers(_ app: ThemeAppBinding) -> (begin: String, end: String) {
        let mark = comment(app.config)
        return (mark + begin.dropFirst(), mark + end.dropFirst())
    }

    /// A config's lines with Pilot's block taken out, as the person wrote them.
    private static func linesWithoutBlock(_ target: ThemeSnapshot, _ markers: (begin: String, end: String)) throws -> [String] {
        let rest = try ThemeRegions.replacing(.block(begin: markers.begin, end: markers.end, prefix: 0), in: target.bytes, with: nil) ?? Data()
        guard let text = String(data: rest, encoding: .utf8) else { throw ThemeFailure("\(target.path) is not UTF-8") }
        return text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// The first line of a file Pilot writes whole, in that file's comment mark.
    private static func header(_ pack: ThemePack, _ mark: String) -> String {
        "\(mark) Written by Pilot from its theme \(pack.title.filter { !$0.isNewline }); Pilot rewrites this file, so change the look in Pilot."
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
        case .btop:
            // btop takes the last assignment of a key, so a block at the end wins over its own color_theme line. It
            // finds themes/pilot.theme by its stem. theme_background false leaves the terminal's own see-through ground.
            let block = "color_theme = \"\(btopTheme)\"\ntheme_background = false"
            return ([try asset(app.generated!, btop(pack)), try loader(snapshot(app.config!), claims, line: block)], [])
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
        case .lazygit:
            return ([try lazygitLoader(snapshot(app.config!), claims, pack)], [])
        case .neovim:
            let colours = try asset(app.generated!, neovim(pack)), target = try snapshot(app.config!), marks = markers(app)
            let lua = app.config == "init.lua", mark = comment(app.config)
            let code = try linesWithoutBlock(target, marks).filter { line in
                let text = line.trimmingCharacters(in: .whitespaces); return !text.isEmpty && !text.hasPrefix(mark)
            }
            // An init that loads the scheme itself needs no line of Pilot's.
            if !claims.contains(where: { $0.path == app.config }), code.contains(where: { $0.range(of: #"colorscheme[\s("'\[=]*pilot\b"#, options: .regularExpression) != nil }) {
                return ([colours], [])
            }
            // Lua takes nothing after a top-level return, so a line there would stop nvim starting.
            if lua, let last = code.last, last.range(of: #"^return\b"#, options: .regularExpression) != nil {
                throw ThemeFailure("its init.lua ends in a return, and nothing after it runs. Add vim.cmd.colorscheme(\"\(neovimScheme)\") above it yourself")
            }
            return ([colours, try loader(target, claims, line: lua ? "pcall(vim.cmd.colorscheme, \"\(neovimScheme)\")" : "silent! colorscheme \(neovimScheme)", markers: marks)], [])
        }
    }

    static let btopTheme = "pilot"

    /// Every colour btop v1.4.8 reads from a theme (its `Default_theme`), from the pack's roles as Omarchy's btop template
    /// maps them, with the four box outlines in the accent as Sven's reference shows. A key left out falls back to btop's own.
    static func btop(_ pack: ThemePack) -> Data {
        let p = pack.palette
        let keys: [(String, String)] = [
            ("main_bg", "background"), ("main_fg", "foreground"), ("title", "bright_foreground"), ("hi_fg", "accent"),
            ("selected_bg", "selection"), ("selected_fg", "bright_foreground"), ("inactive_fg", "muted"), ("graph_text", "light_foreground"),
            ("meter_bg", "lighter_background"), ("proc_misc", "light_foreground"),
            ("cpu_box", "accent"), ("mem_box", "accent"), ("net_box", "accent"), ("proc_box", "accent"), ("div_line", "muted"),
            ("temp_start", "green"), ("temp_mid", "yellow"), ("temp_end", "red"),
            ("cpu_start", "cyan"), ("cpu_mid", "blue"), ("cpu_end", "magenta"),
            ("free_start", "magenta"), ("free_mid", "blue"), ("free_end", "cyan"),
            ("cached_start", "blue"), ("cached_mid", "cyan"), ("cached_end", "magenta"),
            ("available_start", "yellow"), ("available_mid", "red"), ("available_end", "red"),
            ("used_start", "green"), ("used_mid", "cyan"), ("used_end", "blue"),
            ("download_start", "yellow"), ("download_mid", "red"), ("download_end", "red"),
            ("upload_start", "green"), ("upload_mid", "cyan"), ("upload_end", "blue"),
            ("process_start", "cyan"), ("process_mid", "blue"), ("process_end", "magenta"),
            ("proc_pause_bg", "red"), ("proc_follow_bg", "blue"), ("proc_banner_bg", "selection"), ("proc_banner_fg", "bright_foreground"),
            ("followed_bg", "blue"), ("followed_fg", "background")]
        let lines = [header(pack, "#")] + keys.map { "theme[\($0.0)]=\"\(p[$0.1]!)\"" }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static let neovimScheme = "pilot"

    /// A Neovim colour scheme from the pack's roles: the base syntax groups (Neovim links the rest and the tree-sitter
    /// groups to them), the editor's own interface, diagnostics and the terminal's 16 colours. `highlight clear` drops
    /// the scheme before it, and also unsets colors_name, so setting 'background' after it reloads nothing.
    static func neovim(_ pack: ThemePack) -> Data {
        let p = pack.palette
        let groups: [(String, String?, String?, String)] = [
            ("Normal", "foreground", "background", ""), ("NormalNC", "foreground", "background", ""),
            ("NormalFloat", "foreground", "dark_background", ""), ("FloatBorder", "muted", "dark_background", ""), ("FloatTitle", "accent", "dark_background", "bold = true"),
            ("Cursor", "background", "bright_foreground", ""), ("CursorLine", nil, "lighter_background", ""), ("CursorColumn", nil, "lighter_background", ""),
            ("ColorColumn", nil, "lighter_background", ""), ("CursorLineNr", "accent", nil, "bold = true"), ("LineNr", "muted", nil, ""),
            ("SignColumn", nil, "background", ""), ("FoldColumn", "muted", "background", ""), ("Folded", "muted", "dark_background", ""),
            ("WinSeparator", "muted", nil, ""), ("StatusLine", "foreground", "dark_background", ""), ("StatusLineNC", "muted", "dark_background", ""),
            ("WinBar", "foreground", nil, "bold = true"), ("WinBarNC", "muted", nil, ""),
            ("TabLine", "muted", "dark_background", ""), ("TabLineSel", "bright_foreground", "background", "bold = true"), ("TabLineFill", nil, "darker_background", ""),
            ("Pmenu", "foreground", "dark_background", ""), ("PmenuSel", "bright_foreground", "selection", "bold = true"),
            ("PmenuSbar", nil, "dark_background", ""), ("PmenuThumb", nil, "muted", ""),
            ("Visual", nil, "selection", ""), ("Search", "background", "yellow", ""), ("IncSearch", "background", "accent", ""), ("CurSearch", "background", "accent", ""),
            ("Substitute", "background", "red", ""), ("MatchParen", "accent", "selection", "bold = true"), ("QuickFixLine", nil, "selection", ""),
            ("LspReferenceText", nil, "lighter_background", ""), ("LspReferenceRead", nil, "lighter_background", ""), ("LspReferenceWrite", nil, "lighter_background", ""),
            ("NonText", "lighter_background", nil, ""), ("Whitespace", "lighter_background", nil, ""), ("SpecialKey", "muted", nil, ""), ("Conceal", "muted", nil, ""),
            ("Directory", "blue", nil, ""), ("Title", "accent", nil, "bold = true"), ("Question", "green", nil, ""), ("MoreMsg", "green", nil, ""),
            ("ModeMsg", "foreground", nil, "bold = true"), ("ErrorMsg", "red", nil, ""), ("WarningMsg", "yellow", nil, ""), ("WildMenu", "background", "accent", ""),
            ("Comment", "muted", nil, "italic = true"), ("Constant", "magenta", nil, ""), ("String", "green", nil, ""), ("Character", "green", nil, ""),
            ("Identifier", "foreground", nil, ""), ("Function", "blue", nil, ""), ("Statement", "magenta", nil, ""), ("Operator", "cyan", nil, ""),
            ("PreProc", "cyan", nil, ""), ("Type", "yellow", nil, ""), ("Special", "cyan", nil, ""), ("Delimiter", "light_foreground", nil, ""),
            ("Underlined", "blue", nil, "underline = true"), ("Error", "red", nil, ""), ("Todo", "background", "yellow", "bold = true"),
            ("@variable", "foreground", nil, ""),
            ("DiffAdd", "green", nil, ""), ("DiffChange", "yellow", nil, ""), ("DiffDelete", "red", nil, ""), ("DiffText", "blue", nil, "bold = true"),
            ("Added", "green", nil, ""), ("Changed", "yellow", nil, ""), ("Removed", "red", nil, ""),
            ("DiagnosticError", "red", nil, ""), ("DiagnosticWarn", "yellow", nil, ""), ("DiagnosticInfo", "blue", nil, ""),
            ("DiagnosticHint", "cyan", nil, ""), ("DiagnosticOk", "green", nil, "")]
        func spec(_ fg: String?, _ bg: String?, _ extra: String) -> String {
            ([fg.map { "fg = \"\(p[$0]!)\"" }, bg.map { "bg = \"\(p[$0]!)\"" }, extra.isEmpty ? nil : extra]).compactMap { $0 }.joined(separator: ", ")
        }
        var lines = [header(pack, "--"), "vim.cmd(\"highlight clear\")", "if vim.fn.exists(\"syntax_on\") == 1 then vim.cmd(\"syntax reset\") end",
                     "vim.o.background = \"\(pack.dark ? "dark" : "light")\"", "vim.g.colors_name = \"\(neovimScheme)\"", "local hl = vim.api.nvim_set_hl"]
        lines += groups.map { "hl(0, \"\($0.0)\", { \(spec($0.1, $0.2, $0.3)) })" }
        lines += [("Error", "red"), ("Warn", "yellow"), ("Info", "blue"), ("Hint", "cyan"), ("Ok", "green")].map { "hl(0, \"DiagnosticUnderline\($0.0)\", { undercurl = true, sp = \"\(p[$0.1]!)\" })" }
        lines += ansi(pack).enumerated().map { "vim.g.terminal_color_\($0.offset) = \"\($0.element)\"" }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// lazygit's gui.theme, each colour lazygit takes (its Config.md, Color Attributes), from the pack's roles.
    static func lazygitTheme(_ pack: ThemePack, indent: String) -> [String] {
        let p = pack.palette
        let keys: [(String, String, bold: Bool)] = [
            ("activeBorderColor", "accent", true), ("inactiveBorderColor", "muted", false), ("searchingActiveBorderColor", "yellow", true),
            ("optionsTextColor", "blue", false), ("selectedLineBgColor", "selection", false), ("inactiveViewSelectedLineBgColor", "lighter_background", false),
            ("cherryPickedCommitFgColor", "background", false), ("cherryPickedCommitBgColor", "cyan", false),
            ("markedBaseCommitFgColor", "background", false), ("markedBaseCommitBgColor", "yellow", false),
            ("unstagedChangesColor", "red", false), ("defaultFgColor", "foreground", false)]
        return keys.map { indent + $0.0 + ": [\"\(p[$0.1]!)\"" + ($0.bold ? ", \"bold\"]" : "]") }
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
    private static func loader(_ target: ThemeSnapshot, _ claims: [ThemeClaim], line: String, markers: (begin: String, end: String) = (begin, end)) throws -> ThemeMutation {
        let (begin, end) = markers
        let bytes = target.bytes ?? Data(), newline = bytes.contains(13) ? "\r\n" : "\n"
        let probe = ThemeSelector.block(begin: begin, end: end, prefix: 0)
        let hasBlock = try ThemeRegions.range(probe, in: target.bytes) != nil
        let prefix = claims.first { $0.path == target.path }.map { claim -> Int in if case .block(_, _, let count) = claim.selector { return count }; return 0 }
            ?? (!hasBlock && !bytes.isEmpty && bytes.last != 10 ? newline.utf8.count : 0)
        let selector = ThemeSelector.block(begin: begin, end: end, prefix: prefix)
        let text = Data(((prefix > 0 ? newline : "") + [begin, line, end].joined(separator: newline)).utf8)
        return try block(selector, target, text: text)
    }

    /// gui.theme in lazygit's config.yml. YAML takes no second gui key (lazygit stops on one), so under a gui of the person's
    /// the block goes right after its line, at its keys' indent; with none, a gui of Pilot's own goes at the end.
    private static func lazygitLoader(_ target: ThemeSnapshot, _ claims: [ThemeClaim], _ pack: ThemePack) throws -> ThemeMutation {
        let lines = try linesWithoutBlock(target, (begin, end))
        let gui = lines.indices.filter { lines[$0].range(of: #"^["']?gui["']?\s*:"#, options: .regularExpression) != nil }
        guard let at = gui.first else { return try loader(target, claims, line: (["gui:", "  theme:"] + lazygitTheme(pack, indent: "    ")).joined(separator: "\n")) }
        // The anchor is a whole line (another gui: line further in refuses it), so gui: must be alone on its line.
        guard gui.count == 1, lines[at].trimmingCharacters(in: .whitespaces) == "gui:" else {
            throw ThemeFailure("its gui line holds more than gui:, so Pilot won't edit around it. Add theme under gui yourself")
        }
        func indent(_ line: String) -> String { String(line.prefix { $0 == " " }) }
        let body = lines[(at + 1)...].prefix { line in let t = line.trimmingCharacters(in: .whitespaces); return t.isEmpty || t.hasPrefix("#") || !indent(line).isEmpty }
        let keys = body.filter { line in let t = line.trimmingCharacters(in: .whitespaces); return !t.isEmpty && !t.hasPrefix("#") }
        let inner = keys.first.map(indent) ?? "  "
        if keys.contains(where: { indent($0) == inner && $0.dropFirst(inner.count).range(of: #"^["']?theme["']?\s*:"#, options: .regularExpression) != nil }) {
            throw ThemeFailure("its config.yml sets gui.theme already. Take it out for Pilot to follow")
        }
        let block = "\n" + ([begin, inner + "theme:"] + lazygitTheme(pack, indent: inner + inner) + [end]).joined(separator: "\n")
        return try self.block(.blockAfter(anchor: anchors[.lazygit]!, begin: begin, end: end), target, text: Data(block.utf8))
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
            return try block(.blockAfter(anchor: anchors[.alacritty]!, begin: begin, end: end), target, text: Data(inner.utf8))
        }
        return try loader(target, claims, line: "[general]\nimport = [\(quoted)]")
    }
}
