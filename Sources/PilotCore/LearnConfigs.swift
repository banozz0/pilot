import Foundation

/// Where a Learn row comes from (Q87): the front app's menu, zsh, Ghostty, git, Neovim and tmux, each a branch of
/// Learn beside Keybindings.
public enum LearnSource: String, CaseIterable, Sendable {
    case thisApp, shell, ghostty, git, neovim, tmux

    public var title: String {
        switch self {
        case .thisApp: "This app"
        case .shell: "Shell"
        case .ghostty: "Ghostty"
        case .git: "Git"
        case .neovim: "Neovim"
        case .tmux: "tmux"
        }
    }
}

/// One key or name another config owns: the chord ("⌃R", "prefix C", "<Space>ff") or the name ("gs"), what it does
/// as the config says it, where it comes from, and what Return does on it (Q102).
public struct LearnRow: Equatable, Sendable {
    public enum Return: Equatable, Sendable {
        /// Press the menu item: a drive route id (DriveRoute.menu).
        case press(String)
        /// Copy this text: an alias's or a function's name.
        case copy(String)
        /// Nothing to run: the row only shows.
        case show
    }

    public var key: String, does: String, source: LearnSource
    /// The kind or table it lives in when the source has several: "alias", "function", "n", "copy-mode-vi".
    public var detail: String?
    public var onReturn: Return

    public init(key: String, does: String, source: LearnSource, detail: String? = nil, onReturn: Return = .show) {
        self.key = key; self.does = does; self.source = source; self.detail = detail; self.onReturn = onReturn
    }
}

/// Learn's parsers for other apps' keys (story 8 of the Omarchy ideas notes; Q87): text a reader captured in, rows out.
/// Pure, never reading a file or running a child; each returns no rows for text it does not recognise.
public enum LearnConfigs {
    /// What the zsh reader runs in `zsh -i -c` (Q98): aliases, the main keymap, then function names after a marker
    /// line, so a word printed by `.zshrc` is never read as a function.
    public static let shellScript = "alias -L; bindkey -L; print -r -- \(functionsMarker); print -l ${(ok)functions}"
    static let functionsMarker = "--pilot-learn-functions--"

    /// What `nvim --headless` runs (Q99): normal, visual and insert maps as one JSON array of mode, lhs, rhs and desc,
    /// written to stdout. A map with a Lua callback has no rhs; the callback is never encoded.
    public static let neovimScript = """
        local out = {} \
        for _, mode in ipairs({'n', 'v', 'i'}) do \
          for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do \
            out[#out + 1] = {mode = mode, lhs = m.lhs, rhs = m.rhs or '', desc = m.desc or ''} \
          end \
        end \
        io.stdout:write(vim.json.encode(out))
        """

    // MARK: zsh

    /// `shellScript`'s output: `alias -L` lines, `bindkey -L` lines (ranges and self-insert left out) and function
    /// names, `_` helpers left out. Return copies an alias's or a function's name.
    public static func shell(_ dump: String) -> [LearnRow] {
        var rows: [LearnRow] = [], inFunctions = false
        for line in dump.split(whereSeparator: \.isNewline) {
            if line == functionsMarker { inFunctions = true; continue }
            if inFunctions {
                let name = line.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.hasPrefix("_"), !name.contains(where: \.isWhitespace) else { continue }
                rows.append(LearnRow(key: name, does: "function", source: .shell, detail: "function", onReturn: .copy(name)))
            } else if line.hasPrefix("alias "), let words = words(line) {
                let flags = words.dropFirst().prefix { $0.hasPrefix("-") && !$0.contains("=") }
                guard let pair = words.dropFirst(1 + flags.count).first, let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
                let name = String(pair[..<eq]), value = String(pair[pair.index(after: eq)...])
                let kind = flags.contains("-g") ? "global alias" : flags.contains("-s") ? "suffix alias" : "alias"
                rows.append(LearnRow(key: flags.contains("-s") ? "*.\(name)" : name, does: value, source: .shell, detail: kind,
                                     onReturn: .copy(name)))
            } else if line.hasPrefix("bindkey "), let words = words(line), words.count == 3 {
                let widget = words[2]
                guard !widget.hasPrefix("self-insert"), widget != "undefined-key" else { continue }
                rows.append(LearnRow(key: zshChord(words[1]), does: widget, source: .shell, detail: "bindkey"))
            }
        }
        return rows
    }

    /// Terminal sequences zsh binds that name one key.
    private static let zshKeys = ["^[[A": "↑", "^[OA": "↑", "^[[B": "↓", "^[OB": "↓", "^[[C": "→", "^[OC": "→", "^[[D": "←", "^[OD": "←",
                                  "^[[H": "Home", "^[OH": "Home", "^[[F": "End", "^[OF": "End", "^[[3~": "⌦", "^[[5~": "Page Up",
                                  "^[[6~": "Page Down", "^[[1;5C": "⌃→", "^[[1;5D": "⌃←", "^[[1;3C": "⌥→", "^[[1;3D": "⌥←", "^[[Z": "⇧⇥", "^[[200~": "Paste", " ": "Space", "^?": "⌫", "^I": "⇥", "^M": "↩", "^[": "Esc"]

    /// zsh's caret notation as key caps: "^X^E" is "⌃X ⌃E", Escape then a key is Option with it ("^[b" is "⌥B", "^[B" is "⌥⇧B").
    static func zshChord(_ sequence: String) -> String {
        if let key = zshKeys[sequence] { return key }
        var caps: [String] = [], rest = Substring(sequence), option = false
        while let c = rest.first {
            if rest.hasPrefix("^["), rest.count > 2 { option = true; rest = rest.dropFirst(2); continue }
            if rest.hasPrefix("\\M-") { option = true; rest = rest.dropFirst(3); continue }
            var mods = option ? ["alt"] : [], key = String(c)
            if c == "^", rest.count > 1 { mods.append("ctrl"); key = String(rest.dropFirst().prefix(1)); rest = rest.dropFirst(2) }
            else { if c.isUppercase { mods.append("shift") }; rest = rest.dropFirst() }
            caps.append(cap(modifiers: mods, key: key, names: modifierNames)); option = false
        }
        return caps.joined(separator: " ")
    }

    // MARK: Ghostty

    /// `ghostty +list-keybinds --plain`: `keybind = super+shift+,=reload_config`, a sequence's steps split by `>`, a
    /// prefix such as `global:` kept as the row's detail.
    public static func ghostty(_ text: String) -> [LearnRow] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> LearnRow? in
            guard line.hasPrefix("keybind = ") else { return nil }
            let bind = line.dropFirst("keybind = ".count)
            // The trigger ends at the first "=" that is not its own key: "super+==…" binds "=", "super++=…" binds "+".
            var eq: Substring.Index?, before: (Character?, Character?) = (nil, nil)
            for i in bind.indices {
                if bind[i] == "=", before.1 != nil, before.1 != "+" || before.0 == "+" { eq = i; break }
                before = (before.1, bind[i])
            }
            guard let eq, case let action = bind[bind.index(after: eq)...], !action.isEmpty else { return nil }
            var trigger = bind[..<eq], prefixes: [String] = []
            for flag in triggerFlags where trigger.hasPrefix(flag) {
                prefixes.append(String(flag.dropLast())); trigger = trigger.dropFirst(flag.count)
            }
            let steps = trigger.split(separator: ">").map { step -> String in
                var parts = step.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
                // "super++" is super with the plus key.
                if parts.count > 1, parts.last == "", parts[parts.count - 2] == "" { parts.removeLast(2); parts.append("+") }
                return cap(modifiers: parts.dropLast(), key: parts.last ?? "", names: modifierNames)
            }
            guard !steps.contains("") else { return nil }
            return LearnRow(key: steps.joined(separator: " "), does: String(action), source: .ghostty,
                            detail: prefixes.isEmpty ? nil : prefixes.joined(separator: " "))
        }
    }

    private static let triggerFlags = ["all:", "global:", "unconsumed:", "performable:"]
    private static let modifierNames = ["ctrl": "⌃", "control": "⌃", "alt": "⌥", "opt": "⌥", "option": "⌥", "shift": "⇧", "super": "⌘",
                                      "cmd": "⌘", "command": "⌘"]
    private static let namedKeys = ["arrow_up": "↑", "up": "↑", "arrow_down": "↓", "down": "↓", "arrow_left": "←", "left": "←",
                                    "arrow_right": "→", "right": "→", "page_up": "Page Up", "ppage": "Page Up", "page_down": "Page Down",
                                    "npage": "Page Down", "home": "Home", "end": "End", "enter": "↩", "return": "↩", "tab": "⇥",
                                    "backspace": "⌫", "bspace": "⌫", "delete": "⌦", "dc": "⌦", "escape": "Esc", "space": "Space", "grave_accent": "`"]

    private static let appleOrder = ["⌃", "⌥", "⇧", "⌘"], tmuxModifiers = ["c": "⌃", "m": "⌥", "s": "⇧"]

    /// Modifiers in Apple's order before the key, "⌃⇧⌘T"; nil names a modifier `names` does not know.
    private static func cap(modifiers: some Collection<String>, key: String, names: [String: String]) -> String {
        let glyphs = modifiers.compactMap { names[$0.lowercased()] }
        guard glyphs.count == modifiers.count, !key.isEmpty else { return "" }
        let key = namedKeys[key.lowercased()] ?? (key.count == 1 ? key.uppercased() : key)
        return appleOrder.filter(glyphs.contains).joined() + key
    }

    // MARK: git

    /// `git config --get-regexp '^alias\.'`: `alias.co checkout`, one per line. Return copies the alias's name.
    public static func git(_ text: String) -> [LearnRow] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> LearnRow? in
            guard line.hasPrefix("alias."), let space = line.firstIndex(of: " ") else { return nil }
            let name = String(line[..<space].dropFirst("alias.".count)), value = line[space...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { return nil }
            return LearnRow(key: name, does: value, source: .git, detail: "alias", onReturn: .copy(name))
        }
    }

    // MARK: Neovim

    private struct NeovimMap: Decodable { var mode: String, lhs: String, rhs: String?, desc: String? }

    /// `neovimScript`'s JSON: a row per map, its desc or else its rhs as what it does, `<Plug>` maps left out (plugins'
    /// internals, never typed). A space in the lhs (a space leader) reads as `<Space>`.
    public static func neovim(_ json: String) -> [LearnRow] {
        guard let maps = try? JSONDecoder().decode([NeovimMap].self, from: Data(json.utf8)) else { return [] }
        return maps.compactMap { map in
            guard !map.lhs.isEmpty, !map.lhs.hasPrefix("<Plug>") else { return nil }
            let does = [map.desc, map.rhs].compactMap { $0 }.first { !$0.isEmpty } ?? "Lua function"
            return LearnRow(key: map.lhs.replacingOccurrences(of: " ", with: "<Space>"), does: does, source: .neovim, detail: map.mode)
        }
    }

    // MARK: tmux

    /// `tmux list-keys` or a `tmux.conf` (Q103): every `bind`/`bind-key` line, its table as the detail (`-n` is root,
    /// none is prefix), a prefix-table key read "prefix c". Comments and `\` continuations as tmux reads them.
    public static func tmux(_ text: String) -> [LearnRow] {
        text.replacingOccurrences(of: "\\\n", with: " ").split(whereSeparator: \.isNewline).compactMap { line -> LearnRow? in
            guard let words = words(line), let first = words.first, first == "bind" || first == "bind-key" else { return nil }
            var table = "prefix", i = 1
            while i < words.count, words[i].hasPrefix("-"), words[i].count > 1 {
                switch words[i] {
                case "-n": table = "root"
                case "-T": i += 1; if i < words.count { table = words[i] }
                case "-N": i += 1
                default: break
                }
                i += 1
            }
            guard i + 1 < words.count else { return nil }
            let key = tmuxKey(words[i])
            return LearnRow(key: table == "prefix" ? "prefix \(key)" : key, does: words[(i + 1)...].joined(separator: " "), source: .tmux,
                            detail: table)
        }
    }

    /// tmux's "C-M-Up" as "⌃⌥↑"; a key with no modifier keeps its name ("MouseDown1Pane").
    static func tmuxKey(_ key: String) -> String {
        var mods: [String] = [], rest = Substring(key)
        while rest.count > 2, let c = rest.first, "CMS".contains(c), rest.dropFirst().first == "-" {
            mods.append(String(c)); rest = rest.dropFirst(2)
        }
        guard !mods.isEmpty || namedKeys[rest.lowercased()] != nil else { return key }
        return cap(modifiers: mods, key: String(rest), names: tmuxModifiers)
    }

    // MARK: This app

    /// The front app's menu bar as AXMenuItems reads it: a row per item with a shortcut, disabled ones too (Copy with
    /// nothing selected is still a key you own), what it does as its path "File › Save". Return presses the item.
    public static func menuItems(_ bar: [MenuItemNode], bundle: String) -> [LearnRow] {
        func rows(_ nodes: [MenuItemNode], _ path: [String]) -> [LearnRow] {
            nodes.flatMap { node -> [LearnRow] in
                let title = node.title.trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty, !title.contains(DriveRoute.pathSeparator) else { return [] }
                if !node.children.isEmpty { return rows(node.children, path + [node.title]) }
                guard !path.isEmpty, let key = node.key else { return [] }
                return [LearnRow(key: key, does: DriveRoute.title(path + [title]), source: .thisApp,
                                 onReturn: .press(DriveRoute.menu(bundle: bundle, path: path + [node.title]).id))]
            }
        }
        return rows(bar, [])
    }

    // MARK: Words

    /// A line split into words as a shell (and tmux) splits it: quotes and backslashes removed, a `$'…'` read as
    /// '…', an unquoted `#` starting a word ending the line (not tmux's `#{`); nil for an unclosed quote.
    static func words(_ line: some StringProtocol) -> [String]? {
        var words: [String] = [], word = "", inWord = false, quote: Character?
        var chars = Substring(line)
        while let c = chars.popFirst() {
            if let q = quote {
                if c == q { quote = nil }
                else if c == "\\", q == "\"", let next = chars.first, "\"\\$`".contains(next) { word.append(chars.removeFirst()) }
                else { word.append(c) }
            } else if c.isWhitespace {
                if inWord { words.append(word); word = ""; inWord = false }
            } else if c == "#", !inWord, chars.first != "{" {
                break
            } else {
                inWord = true
                if c == "'" || c == "\"" { quote = c }
                else if c == "$", chars.first == "'" { quote = chars.removeFirst() }
                else if c == "\\" { if let next = chars.popFirst() { word.append(next) } }
                else { word.append(c) }
            }
        }
        guard quote == nil else { return nil }
        if inWord { words.append(word) }
        return words
    }
}
