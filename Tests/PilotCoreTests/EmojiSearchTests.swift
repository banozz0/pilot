import Testing
import Foundation
@testable import PilotCore

/// Card agent-bo-95422931: emoji found by name or keyword at the menu's root, ranked by frecency.
@Suite("Emoji search")
struct EmojiSearchTests {
    static let packaging = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging")
    static let shipped = Self.packaging.appending(path: "emoji.json")
    static let all: [Emoji] = (try? EmojiSearch.parse(Data(contentsOf: shipped))) ?? []

    static func emoji(_ rows: [MenuEntry]) -> [String] {
        rows.compactMap { if case .emoji(let e) = $0.target { e } else { nil } }
    }

    @Test("The bundled list parses to gemoji's 1870 emoji, and gemoji's MIT notice ships beside it")
    func bundled() throws {
        #expect(Self.all.count == 1870)
        let licence = try String(contentsOf: Self.packaging.appending(path: "gemoji-LICENSE.txt"), encoding: .utf8)
        #expect(licence.contains("Copyright (c) 2019 GitHub, Inc.") && licence.contains("Permission is hereby granted, free of charge"))
    }

    @Test("A name, a keyword or two words find the emoji; one letter finds none")
    func matches() {
        #expect(Self.emoji(EmojiSearch.entries(for: "fire", in: Self.all)).first == "🔥")
        #expect(Self.emoji(EmojiSearch.entries(for: "burn", in: Self.all)).contains("🔥"))
        #expect(Self.emoji(EmojiSearch.entries(for: "red heart", in: Self.all)).first == "❤️")
        #expect(EmojiSearch.entries(for: "f", in: Self.all).isEmpty)
        #expect(EmojiSearch.entries(for: "zzqx", in: Self.all).isEmpty)
        #expect(EmojiSearch.entries(for: "a", in: Self.all).isEmpty)
    }

    /// The emoji the root lists for `query`, in the menu's order.
    static func listed(_ query: String, picks: Frecency = Frecency()) -> [String] {
        var nav = MenuNavigator(entries: [], frecency: picks)
        nav.query = query
        nav.provide(.emoji, EmojiSearch.entries(for: query, in: all))
        return emoji(nav.rows)
    }

    @Test("At the root the name comes first, a keyword-only hit stays listed, and a picked emoji comes first")
    func ranked() {
        #expect(Self.listed("fire").first == "🔥", "the menu's own ranking keeps the name above heart on fire")
        #expect(Self.listed("burn").contains("🔥"))
        #expect(Self.listed("fi").count > 1)
        #expect(Self.listed("fi").first != "🔥", "the test needs another emoji first before the pick")
        var picks = Frecency()
        picks.record("emoji:🔥", at: .now)
        #expect(Self.listed("fi", picks: picks).first == "🔥")
    }

    @Test("An app named like an emoji stays above it")
    func appsFirst() {
        let app = MenuEntry(title: "Rocket", target: .app("com.example.rocket"), home: .apps)
        var nav = MenuNavigator(entries: [app])
        nav.query = "rocket"
        nav.provide(.emoji, EmojiSearch.entries(for: "rocket", in: Self.all))
        #expect(nav.rows.first?.target == .app("com.example.rocket"))
        #expect(Self.emoji(nav.rows).contains("🚀"))
    }

    @Test("An emoji row is a pick under emoji:<the emoji>, and Return runs it")
    func pick() throws {
        let fire = try #require(EmojiSearch.entries(for: "fire", in: Self.all).first)
        #expect(fire.target.key == "emoji:🔥")
        var nav = MenuNavigator(entries: [])
        nav.query = "fire"
        nav.provide(.emoji, [fire])
        #expect(nav.handle(.return) == .run(fire))
    }
}
