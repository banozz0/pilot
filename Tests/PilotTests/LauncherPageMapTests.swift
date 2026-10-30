import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The page map on Launcher and System (Sven 2026-10-17): Translate's pair on Launcher › Your menu, Folders and Passwords
/// under the abilities they configure, and the settings' new pages and words.
@MainActor
@Suite("Launcher page map")
struct LauncherPageMapTests {
    @Test("The translate pair is on Launcher's page; the brightness keys and bind nudges carry their pages' words")
    func pages() throws {
        let schema = SettingsSchemaTests.Rig().schema
        for key in ["translate.home", "translate.other", "passwords.length", "folders.repos", "folders.gifs", "giphy.key", "giphy.rating"] {
            #expect(try schema.setting(key).page == "menu", "\(key)")
        }
        #expect(try schema.setting("displays.brightnessKeys").page == "system")
        #expect(try schema.setting("displays.brightnessKeys").label == "Brightness keys follow the focused window")
        #expect(try schema.setting("general.bindNudges").label == "Show an app's bind after you open it")
    }

    @Test("A search by a setting's words keeps the ability it sits under: repos lazygit, length a password, GIPHY Stickers and GIFs")
    func searchKeepsSettings() {
        let engine = Engine()
        let actions = engine.allBindActions.map(AbilitiesList.withSettingWords)
        let store = BindStore(defaults: engine.registry.defaults)
        func found(_ search: String) -> [String] {
            Abilities.groups(actions: actions, store: store, menu: AppsModule.menuID, search: search).flatMap(\.abilities).map(\.id)
        }
        #expect(found("repos").contains("apps.lazygit"))
        #expect(found("length").contains("apps.generatePassword"))
        #expect(found("giphy").contains("typed.stickers") && found("gifs folder").contains("typed.stickers"))
        #expect(Abilities.typed.contains { $0.id == "typed.stickers" && $0.name == "Stickers and GIFs" && $0.typing != nil })
        // Not added, lazygit and Generate a password wait under More abilities, where their settings show too: found there by
        // the same words.
        func more(_ search: String) -> [String] {
            Abilities.addable(actions: actions, listed: { _ in false }, has: { _ in true }, search: search).map(\.id)
        }
        #expect(more("repos") == ["apps.lazygit"] && more("clear after") == ["apps.generatePassword"])
    }

    @Test("Your menu shows Translate's pair under the root rows; the GIPHY row names and opens Launcher › Abilities")
    func translateBlock() throws {
        let rig = SettingsSchemaTests.Rig()
        rig.settings.translatePair = TranslatePair(home: "en", other: "es")!
        let look = LookPageTests().look().0
        let view = TranslateBlock(settings: rig.settings).padding(20)
            .frame(width: 760, height: 220, alignment: .top).background(Theme.background).pilotTheme(look: look)
        var text = ""
        try LookPageTests().hosted(view, height: 220) { host in
            let rep = try #require(snapshot(host, scale: 2))
            if let dir = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "launcher-translate.png"))
            }
            text = try recognisedText(in: rep).map(\.text).joined(separator: "\n")
        }
        for line in ["Translate", "Translate into", "English", "English goes into", "Spanish"] {
            #expect(text.contains(line), "\(line) missing, read: \(text)")
        }
        let key = Giphy.keyRow(refused: false, query: "")
        #expect(key.subtitle == "Launcher › Abilities" && key.target == .openPage(AppPlace(.menu, .abilities)))
    }
}
