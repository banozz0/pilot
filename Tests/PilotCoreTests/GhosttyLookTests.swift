import Foundation
import Testing
@testable import PilotCore

/// The Ghostty bridge (card agent-bo-95422790): Omarchy's palettes, the include Pilot owns, and the one marked block
/// in Ghostty's config that loads it. Every file here lives in a temp folder; nothing touches Sven's Ghostty setup.
@Suite("Ghostty bridge")
struct GhosttyLookTests {
    static let shipped = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/themes.json")

    static let themes = try! OmarchyThemes.parse(Data(contentsOf: shipped))
    static func theme(_ id: String) throws -> OmarchyTheme { try #require(themes.named(id)) }

    /// A temp folder with a config like Sven's: comments, a theme line, a font, and a trailing newline; `link` puts the
    /// config behind a symlink as the dotfiles one is.
    static func folder(link: Bool = false) throws -> (dir: URL, files: GhosttyFiles, original: String) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-ghostty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = "# Shared by Ghostty.app and Ghostex.\ntheme = Ayu Tokyo Night\n\n# Font\nfont-family = JetBrains Mono\nfont-size = 17\n"
        let config = dir.appending(path: "config")
        if link {
            let real = dir.appending(path: "dotfiles-config")
            try original.write(to: real, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: config, withDestinationURL: real)
        } else {
            try original.write(to: config, atomically: true, encoding: .utf8)
        }
        let files = GhosttyFiles(config: config.path, include: dir.appending(path: "pilot.conf").path, backup: dir.appending(path: "backup/ghostty-config").path)
        return (dir, files, original)
    }

    @Test("Omarchy's 22 palettes ship, each with every role Ghostty and Pilot read, Tokyo Night as Omarchy has it")
    func palettes() throws {
        // Pilot's own three (P105) and the line-up of 18's added sources sit beside Omarchy's in the same table.
        let themes = Self.themes.filter { !["folio", "celadon", "wisteria", "jade-horse", "akane", "ayu-dark", "dracula"].contains($0.id) }
        #expect(themes.count == 22)
        #expect(themes.first { $0.id == "tokyo-night" }?.colors["background"] == "#1a1b26")
        #expect(themes.first { $0.id == "tokyo-night" }?.name == "Tokyo Night")
        #expect(themes.filter { !$0.dark }.map(\.id).sorted() == ["catppuccin-latte", "flexoki-light", "lupine", "rose-pine", "white"])
        for theme in themes { #expect(OmarchyTheme.roles.allSatisfy { theme.colors[$0] != nil }, "\(theme.id)") }
        let missing = try JSONSerialization.data(withJSONObject: ["themes": [["id": "x", "name": "X", "dark": true, "colors": ["background": "#000000"]]]])
        // The first role missing, in OmarchyTheme.roles' order.
        #expect(throws: OmarchyThemes.Problem.missingRole(theme: "x", role: "dark_background")) { try OmarchyThemes.parse(missing) }
        let bad = try JSONSerialization.data(withJSONObject: ["themes": [["id": "x", "name": "X", "dark": true,
            "colors": Dictionary(uniqueKeysWithValues: OmarchyTheme.roles.map { ($0, $0 == "red" ? "red" : "#000000") })]]])
        #expect(throws: OmarchyThemes.Problem.notAColour(theme: "x", role: "red")) { try OmarchyThemes.parse(bad) }
    }

    @Test("The include sets Omarchy's Ghostty mapping, no font, and credits Omarchy")
    func includeText() throws {
        let tokyo = try Self.theme("tokyo-night")
        let text = GhosttyLook(theme: tokyo).text
        let lines = text.components(separatedBy: "\n")
        #expect(lines.contains("background = #1a1b26"))
        #expect(lines.contains("foreground = #a9b1d6"))
        #expect(lines.contains("cursor-color = #c0caf5"))
        #expect(lines.contains("selection-background = #292e42"))
        #expect(lines.contains("palette = 0=#1a1b26") && lines.contains("palette = 8=#414868") && lines.contains("palette = 15=#c0caf5"))
        #expect(lines.filter { $0.hasPrefix("palette = ") }.count == 16)
        #expect(!text.contains("font-"))
        #expect(text.contains("Omarchy"))
        // No theme: Ghostty keeps its own colours.
        let none = GhosttyLook(theme: nil).text
        #expect(!none.contains("background =") && !none.contains("palette ="))
    }

    @Test("Apply backs the config up once, writes the include and adds one marked block that loads it; a second apply updates in place")
    func applyTwice() throws {
        let (dir, files, original) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokyo = try Self.theme("tokyo-night")
        #expect(try files.apply(GhosttyLook(theme: tokyo)))
        let config = try String(contentsOfFile: files.config, encoding: .utf8)
        #expect(config.hasPrefix(original))
        #expect(config.components(separatedBy: "\n").filter { $0 == "config-file = ?\(files.include)" }.count == 1)
        #expect(try String(contentsOfFile: files.backup, encoding: .utf8) == original)
        #expect(try String(contentsOfFile: files.include, encoding: .utf8) == GhosttyLook(theme: tokyo).text)
        // The same look again changes nothing; another look rewrites only the include.
        #expect(try !files.apply(GhosttyLook(theme: tokyo)))
        let gruvbox = try Self.theme("gruvbox")
        #expect(try files.apply(GhosttyLook(theme: gruvbox)))
        #expect(try String(contentsOfFile: files.config, encoding: .utf8) == config)
        #expect(try String(contentsOfFile: files.backup, encoding: .utf8) == original)
        #expect(try String(contentsOfFile: files.include, encoding: .utf8).contains("Gruvbox"))
    }

    @Test("A theme pick keeps the font lines the include already has, exactly and in order, and never adds one (Sven, 2026-10-09)")
    func keepsFont() throws {
        let (dir, files, _) = try Self.folder(link: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokyo = try Self.theme("tokyo-night"), gruvbox = try Self.theme("gruvbox")
        // No include yet: no font line is written.
        try files.apply(GhosttyLook(theme: tokyo))
        #expect(try !String(contentsOfFile: files.include, encoding: .utf8).contains("font-"))
        // An include the font picker wrote: its font lines survive the next pick, and the same pick again changes nothing.
        let font = ["font-family = \"\"", "font-family = Iosevka Nerd Font Mono", "font-size = 13"]
        try (GhosttyLook(theme: tokyo).text + font.joined(separator: "\n") + "\n").write(toFile: files.include, atomically: true, encoding: .utf8)
        #expect(try files.apply(GhosttyLook(theme: gruvbox)))
        let written = try String(contentsOfFile: files.include, encoding: .utf8)
        #expect(written.contains("Gruvbox") && GhosttyLook.fontLines(in: written) == font)
        #expect(try !files.apply(GhosttyLook(theme: gruvbox)))
    }

    @Test("A symlinked config stays a symlink, written through in place; taking Pilot out gives back the exact bytes and drops the include")
    func symlinkAndRemove() throws {
        let (dir, files, original) = try Self.folder(link: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokyo = try Self.theme("tokyo-night")
        try files.apply(GhosttyLook(theme: tokyo))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: files.config).hasSuffix("dotfiles-config"))
        #expect(try String(contentsOfFile: dir.appending(path: "dotfiles-config").path, encoding: .utf8).contains("config-file = ?"))
        #expect(try files.remove())
        #expect(try String(contentsOfFile: files.config, encoding: .utf8) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: files.config).hasSuffix("dotfiles-config"))
        #expect(!FileManager.default.fileExists(atPath: files.include))
        // The backup stays, in case; removing again changes nothing.
        #expect(FileManager.default.fileExists(atPath: files.backup))
        #expect(try !files.remove())
    }

    @Test("The backup keeps the config as it was before Pilot's first change, through a hand edit, a removal and a second apply")
    func backupNeverOverwritten() throws {
        let (dir, files, original) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokyo = try Self.theme("tokyo-night")
        try files.apply(GhosttyLook(theme: tokyo))
        let edited = try String(contentsOfFile: files.config, encoding: .utf8) + "font-size = 18\n"
        try InPlaceFile.overwrite(files.config, with: edited)
        try files.remove()
        #expect(try files.apply(GhosttyLook(theme: tokyo)))
        #expect(try String(contentsOfFile: files.backup, encoding: .utf8) == original)
    }

    @Test("A stale block, with the user's lines after it, is replaced where it stands and the lines after it stay")
    func staleBlockReplaced() throws {
        let (dir, files, _) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = "theme = x\n\n\(GhosttyConfigBlock.block(include: "/old/pilot.conf"))\n\n# added later by hand\nfont-size = 18\n"
        try stale.write(toFile: files.config, atomically: true, encoding: .utf8)
        #expect(try files.apply(GhosttyLook(theme: try Self.theme("nord"))))
        let expected = "theme = x\n\n\(GhosttyConfigBlock.block(include: files.include))\n\n# added later by hand\nfont-size = 18\n"
        #expect(try String(contentsOfFile: files.config, encoding: .utf8) == expected)
    }

    @Test("A block a hand edit broke (doubled or missing marker) is refused, and nothing is written")
    func brokenMarkers() throws {
        let (dir, files, _) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = "theme = x\n\(GhosttyConfigBlock.begin)\nconfig-file = ?/x\n"
        try broken.write(toFile: files.config, atomically: true, encoding: .utf8)
        let tokyo = try Self.theme("tokyo-night")
        #expect(throws: GhosttyConfigBlock.Problem.brokenMarkers) { try files.apply(GhosttyLook(theme: tokyo)) }
        #expect(try String(contentsOfFile: files.config, encoding: .utf8) == broken)
        #expect(!FileManager.default.fileExists(atPath: files.include))
    }
}
