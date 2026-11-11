import Foundation

/// Palette-only snippet. Vault and config-folder authority comes exclusively from local selection.
public enum ObsidianThemeAdapter {
    public static let element = "pilot-theme"
    public static let membershipPath = ["enabledCssSnippets"]
    public static func binding(root: String, configDir: String) throws -> ThemeBinding {
        guard root.hasPrefix("/"), URL(fileURLWithPath: root).standardizedFileURL.path == root,
              !root.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              configDir.hasPrefix("."), configDir.count > 1, !configDir.contains("/"), ThemeFiles.relative(configDir),
              !configDir.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ThemeFailure("unsafe explicit Obsidian vault/config folder") }
        return ThemeBinding(root: root, config: configDir + "/appearance.json", generated: configDir + "/snippets/pilot-theme.css")
    }

    // Semantic colour variables only; no font, geometry, base scheme or cssTheme selection.
    private static let roles = [
        "background-primary": "background", "background-primary-alt": "lighter_background",
        "background-secondary": "dark_background", "background-secondary-alt": "darker_background",
        "background-modifier-border": "muted", "background-modifier-border-focus": "accent",
        "text-normal": "foreground", "text-muted": "muted", "text-faint": "dark_foreground",
        "text-accent": "accent", "text-accent-hover": "accent", "text-on-accent": "background",
        "interactive-accent": "accent", "interactive-accent-hover": "accent", "text-selection": "selection",
        "text-success": "green", "text-warning": "yellow", "text-error": "red",
        "color-red": "red", "color-yellow": "yellow", "color-green": "green", "color-cyan": "cyan",
        "color-blue": "blue", "color-purple": "magenta", "code-normal": "foreground", "code-comment": "muted",
        "code-function": "blue", "code-keyword": "magenta", "code-string": "green", "code-value": "yellow",
        "code-operator": "accent", "code-punctuation": "dark_foreground"]

    /// Roles Obsidian draws as text on its four backgrounds.
    private static let textRoles: Set<String> = ["text-normal", "text-muted", "text-faint", "text-accent", "text-accent-hover",
        "text-success", "text-warning", "text-error", "color-red", "color-yellow", "color-green", "color-cyan", "color-blue", "color-purple",
        "code-normal", "code-comment", "code-function", "code-keyword", "code-string", "code-value", "code-operator", "code-punctuation"]
    private static let grounds = ["background", "lighter_background", "dark_background", "darker_background"]

    /// A role's colour, moved toward the text colour where it would read below 4.5:1 as text, and the text on an accent
    /// button readable on that accent.
    public static func colour(_ role: String, in palette: [String: String]) -> String {
        let value = palette[roles[role]!]!, ink = palette["foreground"]!
        if role == "text-on-accent" { return Contrast.readable(value, on: [palette["accent"]!], toward: ink) }
        guard textRoles.contains(role) else { return value }
        return Contrast.readable(value, on: grounds.compactMap { palette[$0] }, toward: ink)
    }

    public static func asset(_ pack: ThemePack) throws -> Data {
        _ = try ThemePack.decode(ThemeDigest.encoded(pack))
        var variants = pack.variants ?? [:]; variants[pack.dark ? "dark" : "light"] = pack.palette
        // The theme shows in either of Obsidian's modes, so macOS's Dark mode never hides a light theme: one rule for both
        // when they share a palette, so the snippet (and every plan that carries it) stays as small as before.
        func rule(_ selector: String, _ palette: [String: String]) -> String {
            selector + " {\n" + roles.keys.sorted().map { "  --\($0): \(colour($0, in: palette));" }.joined(separator: "\n") + "\n}\n"
        }
        guard let dark = variants["dark"], let light = variants["light"], dark != light else {
            return Data(rule(".theme-dark, .theme-light", pack.palette).utf8)
        }
        return Data((rule(".theme-dark", dark) + rule(".theme-light", light)).utf8)
    }

    /// An existing reserved asset is shown in preview and backed up, but unknown/executable CSS is never adopted.
    public static func validateExisting(_ bytes: Data?) throws {
        guard let bytes else { return }
        guard var text = String(data: bytes, encoding: .utf8) else { throw ThemeFailure("Obsidian snippet is not UTF-8") }
        text = text.replacingOccurrences(of: "\u{feff}", with: "")
        let comments = try NSRegularExpression(pattern: "/\\*[^*]*\\*+(?:[^/*][^*]*\\*+)*/")
        text = comments.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        let rule = try NSRegularExpression(pattern: "\\s*\\.theme-(?:dark|light)(?:\\s*,\\s*\\.theme-(?:dark|light))?\\s*\\{([^{}]*)\\}\\s*")
        let declaration = try NSRegularExpression(pattern: "\\s*--([a-z-]+)\\s*:\\s*#[0-9a-fA-F]{6}\\s*;\\s*")
        var rest = text[...]
        while !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let chunk = String(rest), range = NSRange(chunk.startIndex..., in: chunk)
            guard let match = rule.firstMatch(in: chunk, options: .anchored, range: range), let bodyRange = Range(match.range(at: 1), in: chunk) else { throw ThemeFailure("unsupported/malformed Obsidian snippet; reserved asset must be colour-only") }
            var body = String(chunk[bodyRange]), seen = Set<String>()
            while !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let item = declaration.firstMatch(in: body, options: .anchored, range: NSRange(body.startIndex..., in: body)),
                      let keyRange = Range(item.range(at: 1), in: body), roles[String(body[keyRange])] != nil,
                      seen.insert(String(body[keyRange])).inserted, let consumed = Range(item.range, in: body) else { throw ThemeFailure("unsupported/malformed Obsidian colour declaration") }
                body.removeSubrange(consumed)
            }
            guard let consumed = Range(match.range, in: chunk) else { throw ThemeFailure("invalid CSS span") }
            rest = chunk[consumed.upperBound...]
        }
    }

    public static let warnings = [
        "Obsidian: reload it to see the theme",
        "Obsidian: other CSS, themes, plugins or snippets can still override these colours",
        "Obsidian: your base scheme, theme, fonts, notes and plugins stay. Only this pack's dark and light colours are added"]
}
