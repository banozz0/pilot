import Foundation
import Testing
@testable import PilotCore

/// Sven's test 2026-10-09: Update › Apps listed codex and zen with no icon. Every app row in Update and Remove wears its
/// real icon: a cask's app on disk (brew outdated does not name it, so `brew info --cask` does), else the Install
/// catalogue's (its app once installed, else its shipped picture), else its kind's glyph. Fixtures only.
@Suite("App row icons")
struct AppRowIconsTests {
    /// `brew info --json=v2 --cask zen codex`, trimmed: Zen names its app, Codex (a command-line cask) a binary only.
    static let info = Data("""
    {"formulae": [], "casks": [
      {"full_token": "zen", "name": ["Zen"], "artifacts": [{"app": ["Zen.app"]}], "installed": "1.21.16b"},
      {"full_token": "codex", "name": ["Codex"], "artifacts": [{"binary": ["codex"], "target": "/opt/homebrew/bin/codex"}], "installed": "0.161.0"}
    ]}
    """.utf8)

    static let zen = UpdateRow(item: .package(Package(.cask, "zen")!), from: "1.21.16b", to: "1.23.2b")
    static let codex = UpdateRow(item: .package(Package(.cask, "codex")!), from: "0.161.0", to: "0.162.0")
    static let atuin = UpdateRow(item: .package(Package(.formula, "atuin")!), from: "18.0", to: "18.1")

    @Test("Update asks brew info for its outdated casks only, and a cask that names an app gets it")
    func caskApps() {
        #expect(UpdateList.caskTokens([Self.zen, Self.atuin, Self.codex]) == ["zen", "codex"])
        let rows = UpdateList.withApps([Self.zen, Self.codex, Self.atuin], info: Self.info)
        #expect(rows.map(\.app) == ["/Applications/Zen.app", nil, nil])
        #expect(UpdateList.withApps([Self.zen], info: Data("not json".utf8)).map(\.app) == [nil], "an unreadable answer changes nothing")
    }

    @Test("An Update row wears its cask's app, else the catalogue's icon, else its kind's glyph")
    func updateIcons() {
        let catalogue = MenuIcon.glyph("shippingbox", .amber).app(bundle: "x")
        var withCatalogue = MenuIcon.cask
        withCatalogue.bundled = "codex"
        let rows = UpdateList.withApps([Self.zen, Self.codex, Self.atuin], info: Self.info)
        let entries = UpdateList.entries(rows, includeSelfUpdating: true, icons: ["cask:codex": withCatalogue, "cask:zen": catalogue])
        func icon(_ title: String) -> MenuIcon? { entries.first { $0.title == title }?.icon }
        #expect(icon("zen")?.appPath == "/Applications/Zen.app", "the app on disk beats the catalogue")
        #expect(icon("codex")?.bundled == "codex", "a command-line cask wears the catalogue's picture")
        #expect(icon("atuin") == MenuIcon.formula)
    }

    @Test("A Remove row with an app wears it; one without (a command-line cask) wears the catalogue's picture")
    func removeIcons() {
        let rows = (try? RemoveList.parse(Self.info)) ?? []
        var picture = MenuIcon.cask
        picture.bundled = "codex"
        let entries = RemoveList.entries(rows, icons: ["cask:codex": picture, "cask:zen": .formula])
        #expect(entries.first { $0.title == "Zen" }?.icon?.appPath == "/Applications/Zen.app")
        #expect(entries.first { $0.title == "Codex" }?.icon?.bundled == "codex")
    }
}
