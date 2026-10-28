import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Story 160: the settings that had no UI. Apps for keys, Folders and Passwords keep their picks; the blocks drawn
/// offscreen and read back; PILOT_RENDER_DIR keeps the PNGs.
@MainActor
@Suite("Setup gaps")
struct SetupGapsTests {
    static func defaults() -> UserDefaults { UserDefaults(suiteName: testSuite())! }

    @Test("A role's pick wins while installed, is kept, and Automatic comes back on nil or once the app is gone")
    func rolePicks() {
        let store = Self.defaults()
        var installed: Set<String> = ["com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.apple.Terminal", "com.apple.Notes"]
        let picks = AppRolePicks(defaults: store) { installed.contains($0) }
        #expect(picks.app(.terminal) == nil)
        #expect(picks.choices(.terminal) == ["com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.apple.Terminal"])
        picks.set(.terminal, "net.kovidgoyal.kitty")
        picks.set(.notes, "com.example.Other")
        #expect(picks.app(.terminal) == "net.kovidgoyal.kitty")
        #expect(picks.app(.notes) == nil, "a pick not installed is Automatic")
        #expect(picks.choices(.notes) == [AppRolePicks.pilot, "com.apple.Notes", "com.example.Other"], "Pilot, then an Other app… pick")
        #expect(!picks.choices(.terminal).contains(AppRolePicks.pilot), "Pilot is a choice for Notes alone")
        picks.set(.notes, AppRolePicks.pilot)
        #expect(picks.app(.notes) == AppRolePicks.pilot, "Pilot's quick notes need no install")
        picks.set(.notes, "com.example.Other")
        let again = AppRolePicks(defaults: store) { installed.contains($0) }
        #expect(again.app(.terminal) == "net.kovidgoyal.kitty")
        installed.remove("net.kovidgoyal.kitty")
        #expect(again.app(.terminal) == nil)
        again.set(.terminal, nil)
        #expect(AppRolePicks(defaults: store).picks[.terminal] == nil)
    }

    @Test("Folders start on ~/code and Pilot's GIFs folder, keep a change and forget it on Reset; a test store leaves Stickers alone")
    func folders() {
        let store = Self.defaults()
        let folders = PilotFolders(defaults: store)
        #expect(folders.repos == NSHomeDirectory() + "/code" && folders.gifs == Stickers.standardFolder.path)
        folders.repos = "/Volumes/Work/src"
        folders.gifs = "/Users/ada/Pictures/GIFs"
        #expect(Stickers.picked == nil)
        let again = PilotFolders(defaults: store)
        #expect(again.repos == "/Volumes/Work/src" && again.gifs == "/Users/ada/Pictures/GIFs")
        again.repos = PilotFolders.standardRepos
        #expect(store.string(forKey: "folders.repos") == nil)
    }

    @Test("Passwords start at 20 with symbols and 90 s; bw is asked for what is set; a stray value reads the default")
    func passwords() {
        let store = Self.defaults()
        let settings = PasswordSettings(defaults: store)
        #expect(settings.arguments == Bitwarden.generateArguments && settings.clearAfter == 90)
        settings.length = 32
        settings.symbols = false
        settings.clearAfter = 30
        let again = PasswordSettings(defaults: store)
        #expect(again.arguments == ["generate", "-uln", "--length", "32"] && again.clearAfter == 30)
        store.set(3, forKey: "passwords.length")
        store.set(45, forKey: "passwords.clearAfter")
        let stray = PasswordSettings(defaults: store)
        #expect(stray.length == 20 && stray.clearAfter == 90)
    }

    @Test("The three blocks name each role, folder and password setting")
    func renders() throws {
        let installed: Set<String> = ["com.mitchellh.ghostty", "com.apple.Terminal", "com.apple.Notes", "com.apple.Passwords", "com.apple.Music"]
        let picks = AppRolePicks(defaults: Self.defaults()) { installed.contains($0) }
        picks.set(.passwords, "com.apple.Passwords")
        let folders = PilotFolders(defaults: Self.defaults())
        folders.repos = NSHomeDirectory() + "/src/projects"
        let passwords = PasswordSettings(defaults: Self.defaults())
        passwords.length = 28
        let look = try LookPageTests().look().0
        // The styles' own faces, as the app draws them: without, this drew the system face alone and the styles' faces
        // only after another suite had pointed DisplayFaces at them, so Vision read two different pictures.
        DisplayFaces.directory = LookThemeTests.fonts
        for (name, style) in [("instrument", PilotStyle.instrument), ("toybox", .toybox)] {
            look.style = style
            let view = VStack(spacing: 12) {
                AppRolesBlock(picks: picks) { $0 == .terminal ? "com.mitchellh.ghostty" : $0.appleApp }
                // As Launcher › Abilities draws them: in a group's block, set in under their abilities (page map, 2026-10-17).
                KitBlock(title: "Apps", symbol: "square.grid.2x2") {
                    FoldersBlock(.repos, folders: folders, giphy: SettingsSchemaTests.FakeKey()).padding(.leading, AbilitiesList.settingsInset)
                    FoldersBlock(.gifs, folders: folders, giphy: SettingsSchemaTests.FakeKey()).padding(.leading, AbilitiesList.settingsInset)
                    PasswordsBlock(settings: passwords).padding(.leading, AbilitiesList.settingsInset)
                }
            }
            .padding(10).frame(width: 760).styled(.page(.openWith)).background(Theme.background).pilotTheme(look: look)
            var text = ""
            try LookPageTests().hosted(view.frame(width: 1000, height: 1300), height: 1300) { host in
                let rep = try #require(snapshot(host, scale: 2))
                if let dir = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] {
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "setup-gaps-\(name).png"))
                }
                // Vision reads a path in the styles' faces with a space after its slash ("~/ src"), and its tilde as * or •.
                text = try recognisedText(in: rep).map(\.text).joined(separator: "\n").replacing("/ ", with: "/")
            }
            for line in ["Apps for keys", "Terminal", "Automatic", "Notes", "Passwords", "Music", "Repos", "src/projects",
                         "GIFs and pictures", "Change", "Length", "28", "Symbols", "Clear after", "90 seconds"] {
                #expect(text.localizedCaseInsensitiveContains(line), "\(name): \(line) missing, read: \(text)")
            }
        }
    }
}
