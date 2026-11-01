import Foundation

/// One of Omarchy's themes (github.com/basecamp/omarchy, MIT, credit kept): its name and colour roles as its
/// colors.toml names them, shipped in `Packaging/themes.json` (cards agent-bo-95422790, agent-bo-95422791).
public struct OmarchyTheme: Equatable, Sendable {
    public let id: String
    public let name: String
    public let dark: Bool
    /// Role (colors.toml key) to "#rrggbb".
    public let colors: [String: String]

    /// A role every theme has: a theme missing one never parses (OmarchyThemes.parse).
    public subscript(role role: String) -> String { colors[role]! }

    /// The roles every shipped theme has and Pilot reads; orange and brown are optional, as in Omarchy.
    public static let roles = ["background", "dark_background", "darker_background", "lighter_background", "foreground",
                               "dark_foreground", "light_foreground", "bright_foreground", "accent", "selection", "muted",
                               "red", "yellow", "green", "cyan", "blue", "magenta",
                               "bright_red", "bright_yellow", "bright_green", "bright_cyan", "bright_blue", "bright_magenta"]
}

public enum OmarchyThemes {
    public enum Problem: Error, Equatable {
        case notJSON
        case missingRole(theme: String, role: String)
        case notAColour(theme: String, role: String)
    }

    /// The file's themes in its order; a theme missing a role or holding anything but #rrggbb refuses the file.
    public static func parse(_ data: Data) throws(Problem) -> [OmarchyTheme] {
        struct Row: Decodable { let id, name: String; let dark: Bool; let colors: [String: String] }
        struct File: Decodable { let themes: [Row] }
        guard let rows = try? JSONDecoder().decode(File.self, from: data).themes else { throw .notJSON }
        return try rows.map { row throws(Problem) in
            for role in OmarchyTheme.roles where row.colors[role] == nil { throw .missingRole(theme: row.id, role: role) }
            for (role, value) in row.colors where !isColour(value) { throw .notAColour(theme: row.id, role: role) }
            return OmarchyTheme(id: row.id, name: row.name, dark: row.dark, colors: row.colors)
        }
    }

    static func isColour(_ value: String) -> Bool {
        value.count == 7 && value.hasPrefix("#") && value.dropFirst().allSatisfy(\.isHexDigit)
    }
}

/// What Pilot sets in Ghostty: a theme's colours through Omarchy's ghostty.conf.tpl mapping (MIT, basecamp/omarchy);
/// with no theme, Ghostty keeps its own colours. `text` is the include without a font: its font lines are Install's Use
/// fonts in pick (FontPlaces, Sven Q711), which GhosttyFiles carries over on every rewrite.
public struct GhosttyLook: Equatable, Sendable {
    public var theme: OmarchyTheme?

    public init(theme: OmarchyTheme?) { self.theme = theme }

    /// Omarchy's template: palette 0 to 15 from these roles in order.
    private static let palette = ["background", "red", "green", "yellow", "blue", "magenta", "cyan", "foreground",
                                  "muted", "bright_red", "bright_green", "bright_yellow", "bright_blue", "bright_magenta", "bright_cyan", "bright_foreground"]

    public var text: String {
        var lines = ["# Written by Pilot (its Look settings); Pilot rewrites this file, so change the look in Pilot."]
        if let c = theme {
            lines += [
                "# Colours: Omarchy's \(c.name) palette and Ghostty template (github.com/basecamp/omarchy, MIT, (c) David Heinemeier Hansson).",
                "background = \(c[role: "background"])",
                "foreground = \(c[role: "foreground"])",
                "cursor-color = \(c[role: "bright_foreground"])",
                "selection-background = \(c[role: "selection"])",
                "selection-foreground = \(c[role: "bright_foreground"])",
            ]
            lines += Self.palette.enumerated().map { "palette = \($0)=\(c[role: $1])" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The `font-` lines of an include (Use fonts in's, and the old font picker's until 2026-10-09), in order: kept as they
    /// are on every rewrite, so a theme pick never changes Ghostty's font.
    public static func fontLines(in include: String?) -> [String] {
        (include ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("font-") }
    }
}

/// Pilot's one marked block in Ghostty's config: a single `config-file` line that loads Pilot's include. Ghostty loads a
/// `config-file` after every default file (Config.zig, v1.3.1: loadDefaultFiles, then loadRecursiveFiles), so the include
/// wins over both of Sven's files; `?` keeps a missing include silent.
public enum GhosttyConfigBlock {
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case brokenMarkers
        public var description: String { "Pilot's block markers in Ghostty's config are missing, doubled or out of order; nothing written" }
    }

    public static let begin = "# >>> Pilot block: loads Pilot's theme and font, edits here are overwritten >>>"
    public static let end = "# <<< Pilot block <<<"
    static let marked = MarkedBlock(begin: begin, end: end)

    public static func block(include: String) -> String { [begin, "config-file = ?\(include)", end].joined(separator: "\n") }

    /// `file` with the block in place of the old one, or appended after one blank line when there is none.
    public static func splice(_ file: String, include: String) throws(Problem) -> String {
        var lines = file.components(separatedBy: "\n")
        switch marked.locate(lines) {
        case .absent: return MarkedBlock.appending(block(include: include), to: file)
        case .at(let b, let e):
            lines.replaceSubrange(b...e, with: [block(include: include)])
            return lines.joined(separator: "\n")
        case .broken: throw .brokenMarkers
        }
    }

    /// `file` without the block and the blank line `splice` put before it: the bytes before the first apply.
    public static func removing(from file: String) throws(Problem) -> String {
        if case .broken = marked.locate(file.components(separatedBy: "\n")) { throw .brokenMarkers }
        return marked.removing(from: file) ?? file
    }
}

/// The three files the bridge touches: Ghostty's config (written in place, through a symlink), Pilot's include, and a
/// one-time backup of the config taken before Pilot first changes it, never overwritten.
public struct GhosttyFiles: Sendable {
    public let config: String, include: String, backup: String

    public init(config: String, include: String, backup: String) { self.config = config; self.include = include; self.backup = backup }

    /// ~/.config/ghostty/config (on Sven's Mac a link into dotfiles), ~/.config/ghostty/pilot.conf, and the backup in
    /// Pilot's Application Support.
    public static let standard = GhosttyFiles(config: NSHomeDirectory() + "/.config/ghostty/config",
                                              include: NSHomeDirectory() + "/.config/ghostty/pilot.conf",
                                              backup: PilotFolder.support.appending(path: "ghostty-config-backup").path)

    /// Writes the include, its font lines kept as they were, and makes sure the config loads it. Returns whether anything
    /// changed, so Ghostty reloads only then. A broken block refuses before any write.
    @discardableResult
    public func apply(_ look: GhosttyLook) throws -> Bool {
        // Checked before the include is written, so a broken block leaves both files alone.
        _ = try GhosttyConfigBlock.splice(String(contentsOfFile: config, encoding: .utf8), include: include)
        let old = try? String(contentsOfFile: include, encoding: .utf8)
        let text = look.text + GhosttyLook.fontLines(in: old).map { $0 + "\n" }.joined()
        let includeChanged = old != text
        if includeChanged { try text.write(toFile: include, atomically: true, encoding: .utf8) }
        let configChanged = try InPlaceFile.update(config, backup: backup) { try GhosttyConfigBlock.splice($0, include: include) }
        return includeChanged || configChanged
    }

    /// Takes Pilot's look out: the block leaves the config and the include is deleted; the backup stays. Returns whether
    /// anything changed.
    @discardableResult
    public func remove() throws -> Bool {
        let configChanged = try InPlaceFile.update(config) { try GhosttyConfigBlock.removing(from: $0) }
        let hadInclude = FileManager.default.fileExists(atPath: include)
        if hadInclude { try FileManager.default.removeItem(atPath: include) }
        return hadInclude || configChanged
    }
}

extension [OmarchyTheme] {
    public func named(_ id: String) -> OmarchyTheme? { first { $0.id == id } }
}

/// Writes Ghostty's include: GhosttyFiles in tests, the app's bridge (which also reloads Ghostty) for real.
@MainActor public protocol GhosttyWriting {
    @discardableResult func apply(_ look: GhosttyLook) throws -> Bool
    /// Whether Pilot's look is in Ghostty now: false before the first apply and after Take Pilot's look out.
    var isApplied: Bool { get }
}

extension GhosttyFiles: GhosttyWriting {
    public var isApplied: Bool { FileManager.default.fileExists(atPath: include) }
}
