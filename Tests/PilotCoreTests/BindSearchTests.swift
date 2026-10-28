import Foundation
import Testing
@testable import PilotCore

/// The bind editor's one search (design A, Sven 2026-10-12): every thing a key can run in one field, grouped, with the
/// kinds listed while it is empty and typed intents (a site, an app URL, a shell command) offered as rows.
@Suite("Bind search")
struct BindSearchTests {
    static let catalogue = try! DriveCatalogue(json: Data(contentsOf: DriveCatalogueTests.shipped))
    static let sources = BindSearch.Sources(
        apps: [("Ghostty", "com.mitchellh.ghostty"), ("Ghostex", "dev.ghostex.app"), ("Zen", "app.zen-browser.zen"),
               ("ChatGPT", "com.openai.chat"), ("Notes", "com.apple.Notes")],
        browsers: [("Zen", "app.zen-browser.zen"), ("Safari", "com.apple.Safari")],
        actions: [.init(id: "windows.close", label: "Close window", module: "windows"),
                  .init(id: "looks.ghostty", label: "Ghostty: use Pilot's look", module: "look"),
                  // Bound ones the engine lists among its actions: their own source's row stands for them.
                  .init(id: "apps.open:com.mitchellh.ghostty", label: "Ghostty", module: "apps"),
                  .init(id: "scripts.run:kill-port.sh", label: "Kill port", module: "drive")],
        catalogue: catalogue,
        scripts: [.init(id: "scripts.run:kill-port.sh", label: "Kill port", module: "drive")],
        extensions: [.init(id: "ext.pomodoro.focus", label: "Focus", module: "drive", keywords: "Pomodoro")],
        quicklinks: BindSearch.quicklinks([Quicklink(name: "GitHub", keyword: "gh", url: "https://github.com/search?q={query}")]),
        configs: [.init(id: "configs.edit:zed", label: "Zed config", module: "apps")],
        soundOutputs: [.init(id: "system.output:73", label: "Play through AirPods Pro", module: "system")],
        focusPresets: [.init(id: "focus.session:Deep work", label: "Deep work", module: "focus")],
        shortcuts: ["Morning routine"])

    static func rows(_ query: String, scope: BindSearch.Kind? = nil, suggest: String? = nil,
                     trigger: (String) -> Key? = { _ in nil }) -> [BindSearch.Row] {
        guard case .rows(let rows) = BindSearch.list(query, scope: scope, in: sources, suggest: suggest, trigger: trigger) else { return [] }
        return rows
    }

    /// The groups in the order they list, each once.
    static func groups(_ rows: [BindSearch.Row]) -> [BindSearch.Group] {
        rows.map(\.group).reduce(into: []) { if $0.last != $1 { $0.append($1) } }
    }

    @Test("gho lists Apps, then Pilot actions with the catalogue's Ghostty actions, then the shell row last")
    func gho() {
        let rows = Self.rows("gho")
        #expect(Self.groups(rows) == [.apps, .actions, .shell])
        #expect(rows.filter { $0.group == .apps }.map(\.id) == ["apps.open:com.mitchellh.ghostty", "apps.open:dev.ghostex.app"])
        let actions = rows.filter { $0.group == .actions }
        #expect(actions.contains { $0.id == "looks.ghostty" })
        #expect(actions.contains { $0.id == "drive.menu:com.mitchellh.ghostty:View > Quick Terminal" && $0.subtitle == "App action · Ghostty" })
        // A bound app is listed once, as its app.
        #expect(rows.filter { $0.id == "apps.open:com.mitchellh.ghostty" }.count == 1)
        #expect(rows.last?.id == "drive.shell:gho")
        #expect(rows.last?.title == "Run gho as a shell command")
    }

    @Test("chatgpt.com offers the site in your browser, then in each browser, above the ChatGPT app")
    func website() {
        let rows = Self.rows("chatgpt.com")
        #expect(Self.groups(rows).first == .website)
        #expect(rows.filter { $0.group == .website }.map(\.id)
                == ["apps.web:https://chatgpt.com", "apps.url:app.zen-browser.zen:https://chatgpt.com", "apps.url:com.apple.Safari:https://chatgpt.com"])
        #expect(rows.first?.title == "Open chatgpt.com")
        #expect(Self.rows("https://chatgpt.com/c/1").first?.id == "apps.web:https://chatgpt.com/c/1")
        // A word with no dot is no site.
        #expect(!Self.rows("gho").contains { $0.group == .website })
    }

    @Test("$ ls gives one shell row; another scheme gives an App URL row")
    func typedIntents() {
        #expect(Self.rows("$ ls").map(\.id) == ["drive.shell:ls"])
        #expect(Self.rows("> open -g ~/Downloads").map(\.id) == ["drive.shell:open -g ~/Downloads"])
        let shottr = Self.rows("shottr://grab/area")
        #expect(shottr.first?.id == "drive.url:shottr://grab/area")
        #expect(shottr.first?.group == .appURL)
    }

    @Test("A config, sound output, focus preset, script, extension command, quicklink or Shortcut name gives its row first",
          arguments: [("zed", "configs.edit:zed", BindSearch.Group.configs), ("airpods", "system.output:73", .soundOutputs),
                      ("deep work", "focus.session:Deep work", .focusPresets), ("kill", "scripts.run:kill-port.sh", .scripts),
                      ("pomodoro", "ext.pomodoro.focus", .extensions), ("morning", "drive.shortcut:Morning routine", .shortcuts)])
    func source(query: String, id: String, group: BindSearch.Group) {
        let rows = Self.rows(query)
        #expect(rows.first?.id == id)
        #expect(rows.first?.group == group)
        // A bound one the engine also lists among its actions shows once.
        #expect(rows.filter { $0.id == id }.count == 1)
    }

    @Test("A quicklink is found by its name")
    func quicklink() {
        #expect(Self.rows("github").first?.id.hasPrefix(Quicklink.prefix) == true)
        #expect(Self.rows("github").first?.group == .quicklinks)
    }

    @Test("Empty lists the kinds, More last; a kind's scope with nothing typed lists all it holds")
    func empty() {
        guard case .kinds(let kinds) = BindSearch.list("  ", in: Self.sources) else { Issue.record("no kinds"); return }
        #expect(kinds.map(\.title) == ["Open an app", "Run a Pilot action", "Open a website", "Run a shell command",
                                       "Press a menu item", "Send keys to the app in front", "More"])
        #expect(kinds.last?.kinds == [.shortcut, .picker, .appURL])
        #expect(kinds.first?.count == 5)
        #expect(Self.rows("", scope: .app).count == 5)
        #expect(Self.groups(Self.rows("", scope: .shortcut)) == [.shortcuts])
        // A scope keeps to its groups.
        #expect(Self.groups(Self.rows("gho", scope: .app)) == [.apps])
        #expect(Self.rows("ls", scope: .shell).map(\.id) == ["drive.shell:ls"])
    }

    @Test("With an AI ready, Suggest with AI leads when only the shell row matched, else sits just above it; never for $ or a scope")
    func suggest() {
        let only = Self.rows("open youtube in chrome", suggest: "Claude")
        #expect(only.map(\.id) == [BindAI.rowID, "drive.shell:open youtube in chrome"])
        #expect(only.first?.title == "Suggest with AI: open youtube in chrome")
        #expect(only.first?.subtitle == "Sends these words and your app names to Claude")
        let gho = Self.rows("gho", suggest: "Claude")
        #expect(Self.groups(gho) == [.apps, .actions, .suggest, .shell])
        #expect(gho.dropLast().last?.id == BindAI.rowID)
        #expect(Self.rows("$ ls", suggest: "Claude").map(\.id) == ["drive.shell:ls"])
        #expect(!Self.rows("gho", scope: .app, suggest: "Claude").contains { $0.group == .suggest })
        // No AI ready, no row: today's list.
        #expect(Self.rows("open youtube in chrome").map(\.id) == ["drive.shell:open youtube in chrome"])
    }

    @Test("open youtube in safari is Safari on youtube.com at once, above the AI row; a browser not on the Mac or another sentence gives none")
    func siteInBrowser() {
        let rows = Self.rows("open YouTube in Safari", suggest: "Claude")
        #expect(rows.map(\.id) == ["apps.url:com.apple.Safari:https://youtube.com", BindAI.rowID, "drive.shell:open YouTube in Safari"])
        #expect(rows.first?.title == "Open youtube.com in Safari")
        #expect(Self.rows("open chatgpt.com in zen").first?.id == "apps.url:app.zen-browser.zen:https://chatgpt.com")
        for none in ["open youtube in firefox", "open my notes in zen", "open you-tube in zen", "close youtube in zen"] {
            #expect(!Self.rows(none).contains { $0.group == .website }, "\(none)")
        }
    }

    @Test("A row shows the key its action holds now")
    func currentKey() {
        let rows = Self.rows("ghostex") { $0 == "apps.open:dev.ghostex.app" ? Key("g") : nil }
        #expect(rows.first?.key == Key("g"))
    }
}
