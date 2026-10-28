import Foundation
import PilotCore
import Testing
@testable import Pilot

/// `pilot config` and the `configs` and `instructions` collections (CLI W17), asked through the registry the socket
/// answers from, over a home folder of the tests' own: Sven's dotfiles are never read, no editor opens, Finder never shows.
@MainActor
@Suite("Collections configs")
struct CollectionsConfigsTests {
    @MainActor final class Rig {
        let home = FileManager.default.temporaryDirectory.appending(path: "pilot-cli-configs-\(UUID().uuidString)")
        let verbs = ControlVerbs()
        let app = ControlConfigs()
        var opened: [(path: String, editor: String)] = []
        var revealed: [String] = []
        var installed = true

        init() throws {
            try write(".zshrc", "# shell\nexport PATH=/bin\n\nexport OPENAI_API_KEY=sk-ab12\nalias g=git\n")
            // Neovim's config as a link into a dotfiles folder: the card's dotfiles chip and real file.
            try write("dotfiles/nvim/init.lua", "vim.o.number = true\n")
            try FileManager.default.createDirectory(at: home.appending(path: ".config/nvim"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: home.appending(path: ".config/nvim/init.lua"),
                                                       withDestinationURL: home.appending(path: "dotfiles/nvim/init.lua"))
            try write(".hammerspoon/init.lua", "hs.alert('hi')\n")
            try write(".hermes/profiles/harry/config.yaml", "model: x\ntoken: hush12\n")
            try write(".hermes/profiles/harry/SOUL.md", "# Harry\n")
            try write(".claude/CLAUDE.md", "# Operating contract\n")
            try write("code/pilot/AGENTS.md", "# pilot\n")
            try Data([0, 1, 2]).write(to: home.appending(path: ".tmux.conf"))
            app.home = home
            app.editor = { "com.example.editor" }
            app.open = { [unowned self] url, editor in
                opened.append((url.path, editor))
                return installed
            }
            app.reveal = { [unowned self] in revealed.append($0.path) }
            verbs.registerConfigs(app)
        }

        func write(_ path: String, _ text: String) throws {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        func ask(_ verb: String, _ args: String...) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil)
        }

        func rows(_ collection: String) async -> [[String: JSONValue]] {
            CollectionsConfigsTests.array(await ask("list", collection).result).map { CollectionsConfigsTests.object($0) }
        }

        func real(_ path: String) -> String { home.appending(path: path).resolvingSymlinksInPath().path }
    }

    static func object(_ value: JSONValue?) -> [String: JSONValue] { ControlActivityTests.object(value) }
    static func array(_ value: JSONValue?) -> [JSONValue] { ControlActivityTests.array(value) }
    static func strings(_ value: JSONValue?) -> [String] { array(value).compactMap { if case .string(let s) = $0 { s } else { nil } } }

    @Test("list configs gives each card's fields in the page's group order, secrets as dots, then the known ones not here")
    func listConfigs() async throws {
        let rig = try Rig()
        let rows = await rig.rows("configs")
        let present = rows.filter { $0["present"] == .bool(true) }
        #expect(present.map { $0["id"] } == ["zsh", "tmux", "hammerspoon", "neovim"].map(JSONValue.string),
                "Terminal and shell, Windows and keys, Code, as the page groups them; agents' configs are on Agents")
        let zsh = try #require(present.first)
        #expect(zsh["name"] == .string("zsh") && zsh["group"] == .string("Terminal and shell") && zsh["path"] == .string("~/.zshrc"))
        #expect(zsh["inDotfiles"] == .bool(false) && zsh["changed"] == .string("just now"))
        let head = Self.strings(zsh["head"])
        #expect(head == ["# shell", "export PATH=/bin", "export OPENAI_API_KEY=••••••", "alias g=git"], "\(head)")
        #expect(!"\(rows)".contains("sk-ab12") && !"\(rows)".contains("hush12"), "no secret in any row")

        let neovim = try #require(present.first { $0["id"] == .string("neovim") })
        #expect(neovim["path"] == .string("~/.config/nvim/init.lua") && neovim["real"] == .string("~/dotfiles/nvim/init.lua"))
        #expect(neovim["inDotfiles"] == .bool(true))
        #expect(present.first { $0["id"] == .string("tmux") }?["head"] == .array([]), "not text: no glimpse")

        let ghostty = try #require(rows.first { $0["id"] == .string("ghostty") })
        #expect(ghostty["present"] == .bool(false) && Self.strings(ghostty["paths"]).first == "~/.config/ghostty/config")
        #expect(!rows.contains { $0["id"] == .string("claude") || $0["id"] == .string("hermes-harry") }, "agents' configs are on Agents")
    }

    @Test("list instructions gives Agents' cards: agents' settings, CLAUDE.md, each SOUL marked generated, each repo's AGENTS.md")
    func listInstructions() async throws {
        let rig = try Rig()
        let rows = await rig.rows("instructions"), present = rows.filter { $0["present"] == .bool(true) }
        #expect(present.map { $0["id"] } == ["hermes-harry", "claude-md", "soul-harry", "repo-pilot"].map(JSONValue.string))
        #expect(present[0]["group"] == .string("Agent settings"))
        #expect(present[2]["generated"] == .bool(true) && present[2]["group"] == .string("Hermes souls"))
        #expect(present[3]["path"] == .string("~/code/pilot/AGENTS.md") && Self.strings(present[3]["head"]) == ["# pilot"])
        let missing = rows.filter { $0["present"] == .bool(false) }.compactMap { if case .string(let id) = $0["id"] { id } else { nil } }
        #expect(missing == ["claude", "claude-local", "codex", "hermes", "empryo", "opencode"], "only agents' configs are ever missing: \(missing)")
    }

    @Test("config show answers the page's preview with secrets as dots, for configs and instructions alike")
    func show() async throws {
        let rig = try Rig()
        let zsh = Self.object(await rig.ask("config", "show", "zsh").result)
        #expect(zsh["text"] == .string("# shell\nexport PATH=/bin\n\nexport OPENAI_API_KEY=••••••\nalias g=git\n"))
        #expect(zsh["hides"] == .bool(true) && zsh["cut"] == .bool(false) && zsh["id"] == .string("zsh"))
        let harry = Self.object(await rig.ask("config", "show", "hermes-harry").result)
        #expect(harry["text"] == .string("model: x\ntoken: ••••••\n"))
        let soul = Self.object(await rig.ask("config", "show", "soul-harry").result)
        #expect(soul["text"] == .string("# Harry\n") && soul["hides"] == .bool(false))

        #expect(await rig.ask("config", "show", "tmux").error?.code == .badValue, "not text")
        let ghostty = await rig.ask("config", "show", "ghostty").error
        #expect(ghostty?.code == .badValue && ghostty?.message.contains("~/.config/ghostty/config") == true, "\(String(describing: ghostty))")
        #expect(await rig.ask("config", "show", "nope").error?.code == .badValue)
        #expect(await rig.ask("config", "show").error?.code == .badRequest)
        #expect(await rig.ask("config", "edit", "zsh").error?.code == .badValue)
        #expect(await rig.ask("config", "show", "zsh", "--raw").error?.code == .unknownFlag)
    }

    @Test("config open edits the real file in the main editor; reveal shows it in Finder")
    func openAndReveal() async throws {
        let rig = try Rig()
        let opened = Self.object(await rig.ask("config", "open", "neovim").result)
        #expect(opened["opened"] == .bool(true) && opened["real"] == .string("~/dotfiles/nvim/init.lua"))
        #expect(rig.opened.map(\.path) == [rig.real("dotfiles/nvim/init.lua")] && rig.opened.first?.editor == "com.example.editor")
        _ = await rig.ask("config", "open", "repo-pilot")
        #expect(rig.opened.last?.path == rig.real("code/pilot/AGENTS.md"), "an instruction file opens as found, as the page does")
        rig.installed = false
        #expect(await rig.ask("config", "open", "zsh").error?.code == .badValue, "no editor says so")

        let revealed = Self.object(await rig.ask("config", "reveal", "claude-md").result)
        #expect(revealed["revealed"] == .bool(true) && rig.revealed == [rig.real(".claude/CLAUDE.md")])
    }

    @Test("both collections are read-only with id as their row key; config declares its flags and help")
    func schema() async throws {
        let rig = try Rig()
        for name in ["configs", "instructions"] {
            let entry = Self.object(try rig.verbs.schema(collection: name))
            #expect(entry["rowKey"] == .string("id") && entry["add"] == .bool(false) && entry["remove"] == .bool(false) && entry["asks"] == .array([]))
            #expect(await rig.ask("remove", name, "zsh").error?.code == .badValue)
        }
        #expect(rig.verbs.verbs["config"]?.flags?.isEmpty == true)
        let entry = Self.array(Self.object(rig.verbs.schemaIndex)["verbs"]).map { Self.object($0) }.first { $0["name"] == .string("config") }
        #expect(Self.strings(Self.object(entry?["part"])["subcommands"]) == ["show", "open", "reveal"])
        let help = try rig.verbs.verbs["config"]?.detail?("show")
        #expect(help?.contains("dots") == true)
    }
}
