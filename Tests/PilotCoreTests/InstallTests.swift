import Foundation
import Testing
@testable import PilotCore

/// The Install catalogue, its commands, the visible-terminal script and the record of Pilot's installs (stories 81,
/// 88, 97, 99, 100; SPEC.md, Install catalogue). Pure: nothing here installs anything.
@Suite("Install catalogue")
struct InstallCatalogueTests {
    static let shipped = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/install-catalogue.json")

    static func entry(_ drop: String? = nil, _ change: [String: Any] = [:]) -> Data {
        var e: [String: Any] = ["id": "hello", "name": "Hello", "category": "Command-line tools", "formula": "hello",
                 "path": "/opt/homebrew/bin/hello", "vendor": "https://www.gnu.org/software/hello/", "checked": "2026-10-05"]
        if let drop { e[drop] = nil }
        e.merge(change) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: ["entries": [e]])
    }

    static let categories = ["Featured", "AI agents", "AI", "ADEs", "Services", "Chat", "Development", "Editors", "Fonts", "Gaming", "Browsers", "Terminals", "Productivity", "Utilities",
                             "Command-line tools", "Media"]

    /// Sven 2026-10-09, each by its real route: easy-cd from his tap (its command is ecd), Videorc's sign-in download page
    /// (no Homebrew cask, no GitHub release), Hermes Context's own install script from its latest release.
    @Test("The user's additions install their own way: easy-cd from banozz0's tap, Videorc's download page, Hermes Context's install script")
    func additions() throws {
        let entries = try InstallCatalogue.parse(Data(contentsOf: Self.shipped))
        func entry(_ id: String) throws -> CatalogueEntry { try #require(entries.first { $0.id == id }) }
        #expect(try entry("easy-cd").method == .package(Package(.cask, "banozz0/tap/easy-cd")!))
        #expect(try entry("easy-cd").check == .command("ecd"))
        #expect(try entry("videorc").method == .download("https://www.videorc.com/account/download"))
        #expect(try entry("videorc").check == .bundle("dev.theorcdev.videorc"))
        let hermes = try entry("hermes-context")
        #expect(hermes.method.scriptCommand == "curl -fsSL 'https://github.com/banozz0/hermes-context/releases/latest/download/install.sh' | sh")
        #expect(hermes.method.label == "install script")
        #expect(MenuEntries.install([hermes], installed: []).last?.detail == "install script")
    }

    /// Sven 2026-10-10: Empryo recommended under AI agents (no cask: its download page), Hermes Context moved to Utilities,
    /// and ten everyday apps and tools, each name checked with brew info.
    @Test("The user's 2026-10-10 picks sit in their groups under their Homebrew names; Empryo is its download page")
    func picks() throws {
        let entries = try InstallCatalogue.parse(Data(contentsOf: Self.shipped))
        func entry(_ id: String) throws -> CatalogueEntry { try #require(entries.first { $0.id == id }) }
        #expect(try entry("empryo").method == .download("https://empryo.com/download"))
        #expect(try entry("empryo").check == .bundle("dev.empryo.desktop"))
        #expect(try entry("hermes-context").category == "Utilities")
        let picks: [(String, String, Package.Kind, String)] = [
            ("keka", "Utilities", .cask, "keka"), ("appcleaner", "Utilities", .cask, "appcleaner"),
            ("localsend", "Utilities", .cask, "localsend"), ("obsidian", "Productivity", .cask, "obsidian"), ("iina", "Media", .cask, "iina"),
            ("orbstack", "Development", .cask, "orbstack"), ("lazygit", "Command-line tools", .formula, "lazygit"),
            ("gh", "Command-line tools", .formula, "gh"), ("btop", "Command-line tools", .formula, "btop"),
        ]
        for (id, category, kind, name) in picks {
            #expect(try entry(id).category == category, "\(id)")
            #expect(try entry(id).method == .package(Package(kind, name)!), "\(id)")
        }
    }

    @Test("A script is a GitHub release's .sh only; anything else is refused")
    func scripts() throws {
        func parse(_ url: String) throws -> CatalogueEntry.Method? {
            try InstallCatalogue.parse(Self.entry("formula", ["script": url])).first?.method
        }
        #expect(try parse("https://github.com/o/r/releases/latest/download/install.sh") == .script("https://github.com/o/r/releases/latest/download/install.sh"))
        for bad in ["https://example.com/install.sh", "https://github.com/o/r/raw/main/install.sh", "http://github.com/o/r/releases/x.sh"] {
            #expect(throws: InstallCatalogue.Problem.malformed(entry: "hello", field: "script")) { try parse(bad) }
        }
    }

    @Test("The shipped catalogue parses: every entry has a method, an installed-check, a vendor URL and a date")
    func shipped() throws {
        let entries = try InstallCatalogue.parse(Data(contentsOf: Self.shipped))
        #expect(entries.count == 113)
        // Omarchy's Install › Style › Font list as Nerd Font casks (card agent-bo-95422792), its default JetBrains Mono first,
        // then more coding fonts as Nerd Fonts and three interface fonts (Sven, 2026-11-01).
        #expect(entries.filter { $0.category == "Fonts" }.map(\.name) == ["JetBrains Mono", "Cascadia Mono", "Meslo LG Mono", "Fira Code",
                                                                         "Victor Mono", "Iosevka", "Cascadia Code", "Hack", "Source Code Pro",
                                                                         "IBM Plex Mono", "Geist Mono", "Monaspace", "Commit Mono", "Maple Mono",
                                                                         "Recursive Mono", "Inter", "Geist", "IBM Plex Sans"])
        #expect(entries.first { $0.id == "font-iosevka" }?.method == .package(Package(.cask, "font-iosevka-nerd-font")!))
        #expect(entries.first { $0.id == "font-iosevka" }?.check == .paths(["~/Library/Fonts/IosevkaNerdFont-Regular.ttf"]))
        #expect(InstallCatalogue.categories(entries) == Self.categories)
        #expect(entries.first?.name == "Ghostex")
        // Sven's own apps featured first (Q622), then Omarchy's install picks mapped to Mac packages (card agent-bo-95422789).
        #expect(entries.filter { $0.category == "AI agents" }.map(\.name) == ["Claude Code", "Codex", "Antigravity CLI", "opencode"])
        // Omarchy's own order within a category, Sven's earlier picks and the Mac additions around it.
        #expect(entries.filter { $0.category == "AI" }.map(\.name) == ["ChatGPT", "Claude", "Hermes Desktop", "LM Studio", "Ollama", "OpenClaw", "Perplexity"])
        #expect(entries.filter { $0.category == "Development" }.map(\.id).prefix(5) == ["ruby", "node", "bun", "deno", "go"])
        #expect(entries.filter { $0.category == "ADEs" }.map(\.name) == ["Herdr", "T3 Code", "Orca"])
        #expect(entries.filter { $0.category == "Browsers" }.map(\.name) == ["Google Chrome", "Microsoft Edge", "Brave", "Firefox", "Zen"])
        #expect(entries.first { $0.id == "easy-cd" }?.method == .package(Package(.cask, "banozz0/tap/easy-cd")!))
        #expect(entries.first { $0.id == "telegram-tools" }?.method == .package(Package(.uv, "telegram-tools")!))
        #expect(entries.first { $0.id == "opencode" }?.method == .package(Package(.formula, "opencode")!))
        #expect(entries.first { $0.id == "coteditor" }?.check == .bundle("com.coteditor.CotEditor"))
        // Claude Code's own installer puts it in ~/.local/bin, Homebrew's cask in /opt/homebrew/bin: either is installed.
        #expect(entries.first { $0.id == "claude-code" }?.check == .command("claude"))
    }

    @Test("Every entry's id and package appear once, so a row never stands for two installs")
    func unique() throws {
        let entries = try InstallCatalogue.parse(Data(contentsOf: Self.shipped))
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(Set(entries.map(\.key)).count == entries.count)
    }

    @Test("A command is installed in Homebrew's folders or a vendor installer's (~/.local/bin), never by macOS's own /usr/bin copy; several paths are met by any one")
    func installedChecks() throws {
        let home = { (path: String) in NSString(string: path).expandingTildeInPath }
        let claude = CatalogueEntry.Check.command("claude")
        #expect(claude.isMet(bundleInstalled: { _ in false }, fileExists: { $0 == home("~/.local/bin/claude") }))
        #expect(claude.isMet(bundleInstalled: { _ in false }, fileExists: { $0 == "/usr/local/bin/claude" }))
        #expect(!CatalogueEntry.Check.command("ruby").isMet(bundleInstalled: { _ in true }, fileExists: { $0 == "/usr/bin/ruby" }))
        let paths = CatalogueEntry.Check.paths(["~/.opencode/bin/opencode", "/opt/homebrew/bin/opencode"])
        #expect(paths.isMet(bundleInstalled: { _ in false }, fileExists: { $0 == home("~/.opencode/bin/opencode") }))
        #expect(!paths.isMet(bundleInstalled: { _ in false }, fileExists: { _ in false }))
        #expect(CatalogueEntry.Check.bundle("a.b").isMet(bundleInstalled: { $0 == "a.b" }, fileExists: { _ in false }))
        #expect(try InstallCatalogue.parse(Self.entry("path", ["paths": ["/a", "/b"]])).first?.check == .paths(["/a", "/b"]))
        #expect(try InstallCatalogue.parse(Self.entry("path", ["command": "hello"])).first?.check == .command("hello"))
    }

    @Test("An empty paths list counts as no check; two kinds of check on one entry are refused")
    func badChecks() {
        #expect(throws: InstallCatalogue.Problem.missing(entry: "hello", field: "installed-check")) {
            try InstallCatalogue.parse(Self.entry("path", ["paths": [String]()]))
        }
        #expect(throws: InstallCatalogue.Problem.malformed(entry: "hello", field: "installed-check")) {
            try InstallCatalogue.parse(Self.entry(nil, ["command": "hello"]))
        }
    }

    @Test("An entry missing its method, installed-check, vendor URL or date is refused by name", arguments: [
        ("formula", "method"), ("path", "installed-check"), ("vendor", "vendor"), ("checked", "checked"),
    ])
    func broken(drop: String, field: String) {
        #expect(throws: InstallCatalogue.Problem.missing(entry: "hello", field: field)) { try InstallCatalogue.parse(Self.entry(drop)) }
    }

    @Test("A date that is not a day, a vendor that is not a web address and an unsafe package name are refused")
    func malformed() {
        #expect(throws: InstallCatalogue.Problem.malformed(entry: "hello", field: "checked")) {
            try InstallCatalogue.parse(Self.entry(nil, ["checked": "today"]))
        }
        #expect(throws: InstallCatalogue.Problem.malformed(entry: "hello", field: "vendor")) {
            try InstallCatalogue.parse(Self.entry(nil, ["vendor": "gnu.org"]))
        }
        #expect(throws: InstallCatalogue.Problem.malformed(entry: "hello", field: "method")) {
            try InstallCatalogue.parse(Self.entry(nil, ["formula": "hello; rm -rf ~"]))
        }
    }

    @Test("Each method has its install command and a package key; a download has neither")
    func commands() {
        #expect(Package(.cask, "coteditor")?.install == "brew install --cask coteditor")
        #expect(Package(.formula, "hello")?.install == "brew install hello")
        #expect(Package(.uv, "telegram-tools")?.install == "uv tool install telegram-tools")
        #expect(Package(.cask, "banozz0/tap/easy-cd")?.key == "cask:banozz0/tap/easy-cd")
        #expect(Package(key: "formula:hello") == Package(.formula, "hello"))
        #expect(Package(.formula, "a b") == nil)
        #expect(Package(.formula, "-v") == nil)
        #expect(Package(key: "nope") == nil)
        #expect(CatalogueEntry.Method.download("https://x.dev/app.dmg").package == nil)
    }

    @Test("Install lists the categories in order, each naming its apps; a category lists its entries, installed marked")
    func menuRows() throws {
        let entries = try InstallCatalogue.parse(Data(contentsOf: Self.shipped))
        let rows = MenuEntries.install(entries, installed: ["coteditor"])
        var nav = MenuNavigator(entries: rows, branch: .install)
        #expect(nav.rows.map(\.title) == Self.categories)
        #expect(nav.rows[0].detail == "Ghostex, Videorc, Empryo")
        nav = MenuNavigator(entries: rows, branch: .category("Editors"))
        #expect(nav.rows.map(\.title) == ["CotEditor", "Visual Studio Code", "Cursor", "Zed", "Sublime Text", "Helix", "MacVim", "Emacs", "Neovim"])
        #expect(nav.rows[0].detail == "cask · installed")
        #expect(nav.rows[0].target == .package("cask:coteditor"))
        #expect(nav.path == [.install, .category("Editors")])
        #expect(nav.handle(.escape) == .handled)
        #expect(nav.branch == .install)
        #expect(nav.selected?.title == "Editors")
    }
}

/// The visible terminal's script (story 97): the command runs where Sven sees it, the window closes on exit 0 and stays
/// open otherwise. Run here with a harmless command and a fake success hook.
@Suite("Visible terminal")
struct VisibleRunTests {
    func run(_ command: String) throws -> (status: Int32, output: String, hooked: Bool, scriptGone: Bool) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "visible-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hook = dir.appending(path: "hooked")
        let script = dir.appending(path: "run.command")
        try VisibleRun.script(command: command, onSuccess: "touch '\(hook.path)'").write(to: script, atomically: true, encoding: .utf8)
        let p = Process(), out = Pipe()
        p.executableURL = URL(filePath: "/bin/zsh")
        p.arguments = [script.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, output, FileManager.default.fileExists(atPath: hook.path), !FileManager.default.fileExists(atPath: script.path))
    }

    @Test("Exit 0 runs the success hook and ends the script, so the window closes")
    func success() throws {
        let r = try run("echo installing")
        #expect(r.status == 0)
        #expect(r.hooked)
        #expect(r.scriptGone)
        #expect(r.output.contains("$ echo installing"))
        #expect(r.output.contains("installing"))
    }

    @Test("A failing command skips the hook and waits for Return, so the window stays open with the error")
    func failure() throws {
        let r = try run("echo boom >&2; (exit 3)")
        #expect(r.status == 3)
        #expect(!r.hooked)
        #expect(r.output.contains("boom"))
        #expect(r.output.contains("Failed with exit 3. Press Return to close."))
    }

    @Test("Without Ghostty, Terminal runs the script as the window's shell and closes the window only on a clean exit")
    func terminal() throws {
        let plist = try PropertyListSerialization.propertyList(from: VisibleRun.terminalSettings(script: "/tmp/a b.command"), format: nil)
        let d = try #require(plist as? [String: Any])
        #expect(d["CommandString"] as? String == "/bin/zsh '/tmp/a b.command'")
        #expect(d["RunCommandAsShell"] as? Bool == true)
        #expect(d["shellExitAction"] as? Int == 1)
        #expect(d["type"] as? String == "Window Settings")
    }

    @Test("Homebrew and uv's tools are on the script's PATH without a login shell")
    func path() {
        let s = VisibleRun.script(command: "true", onSuccess: "true")
        #expect(s.contains("export PATH=\"/opt/homebrew/bin:$HOME/.local/bin:$PATH\""))
    }
}

/// What Pilot installed (story 97, SPEC.md: "Install records what it installed in Pilot's store").
@Suite("Installed store")
struct InstalledStoreTests {
    @Test("A recorded install is listed by its package key; an absent file is none")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "installed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InstalledStore(url: dir.appending(path: "Pilot/installed.json"))
        #expect(try store.load().isEmpty)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try store.record(Package(.formula, "hello")!, at: at)
        #expect(try store.load() == ["formula:hello": at])
        try Data("x".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.record(Package(.formula, "hello")!, at: at) }
    }
}
