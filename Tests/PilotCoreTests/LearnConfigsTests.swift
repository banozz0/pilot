import Foundation
import Testing
@testable import PilotCore

/// Learn's parsers for other configs (Omarchy ideas T6; Q87): each captured output in `Tests/Fixtures/learn` gives its
/// rows, and text none of them recognises gives none. The fixtures are made-up text, never a real config.
@Suite("Learn config parsers")
struct LearnConfigsTests {
    static let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../Fixtures/learn").standardizedFileURL

    static func data(_ name: String) throws -> Data { try Data(contentsOf: folder.appending(path: name)) }
    static func fixture(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }

    static func pairs(_ rows: [LearnRow]) -> [String] { rows.map { "\($0.key) = \($0.does)" } }

    @Test func zshGivesAliasesBindkeysAndFunctions() throws {
        let rows = LearnConfigs.shell(try Self.fixture("zsh.txt"))
        #expect(Self.pairs(rows) == [
            "- = cd -", "G = | grep", "gs = git status", "ll = ls -la", "say = echo 'hi there'", "*.md = glow",
            "⌃@ = set-mark-command", "⌃R = history-incremental-search-backward", "⌃X ⌃E = edit-command-line",
            "⌥B = backward-word", "↑ = up-line-or-search", "Space = magic-space",
            "mkcd = function", "take = function",
        ])
        #expect(rows.allSatisfy { $0.source == .shell })
        #expect(rows.map(\.detail) == ["alias", "global alias", "alias", "alias", "alias", "suffix alias"]
            + Array(repeating: "bindkey", count: 6) + ["function", "function"])
        // Q102: an alias or a function copies its name; a bindkey only shows.
        #expect(rows[2].onReturn == .copy("gs"))
        #expect(rows[6].onReturn == .show)
        #expect(rows.last?.onReturn == .copy("take"))
    }

    /// A word `.zshrc` prints before the marker is never read as a function.
    @Test func zshNamesNeedTheirMarker() {
        #expect(LearnConfigs.shell("mkcd\ntake\n").isEmpty)
    }

    /// Escape then a capital is Option and Shift; Escape then Control reads in Apple's order.
    @Test func zshChordsReadAsKeyCaps() {
        #expect(LearnConfigs.zshChord("^[B") == "⌥⇧B")
        #expect(LearnConfigs.zshChord("^[^X") == "⌃⌥X")
    }

    @Test func ghosttyGivesItsKeybinds() throws {
        let rows = LearnConfigs.ghostty(try Self.fixture("ghostty.txt"))
        #expect(Self.pairs(rows) == [
            "⇧⌘, = reload_config", "⌘= = increase_font_size:1", "⌘+ = increase_font_size:1", "⌘T = new_tab",
            "⌃A N = next_tab", "⌘` = toggle_quick_terminal", "⌘↑ = jump_to_prompt:-1", "copy = copy_to_clipboard",
        ])
        #expect(rows[5].detail == "global")
        #expect(rows.allSatisfy { $0.source == .ghostty && $0.onReturn == .show })
    }

    @Test func gitGivesItsAliases() throws {
        let rows = LearnConfigs.git(try Self.fixture("git.txt"))
        #expect(Self.pairs(rows) == ["co = checkout", "lg = log --graph --oneline --decorate", "wip = !git add -A && git commit -m wip"])
        #expect(rows.map(\.onReturn) == [.copy("co"), .copy("lg"), .copy("wip")])
    }

    @Test func neovimGivesItsMaps() throws {
        let rows = LearnConfigs.neovim(try Self.fixture("nvim.json"))
        #expect(Self.pairs(rows) == ["<Space>ff = Find files", "<C-W>d = <C-W>d", "gx = Lua function", "jk = Leave insert"])
        #expect(rows.map(\.detail) == ["n", "n", "n", "i"])
    }

    @Test func tmuxGivesListKeys() throws {
        let rows = LearnConfigs.tmux(try Self.fixture("tmux-keys.txt"))
        #expect(Self.pairs(rows) == [
            "v = send-keys -X begin-selection", "prefix c = new-window", "prefix \" = split-window",
            "prefix ⌥↑ = resize-pane -U 5", "MouseDown1Pane = select-pane -t = ; send-keys -M",
        ])
        #expect(rows.map(\.detail) == ["copy-mode-vi", "prefix", "prefix", "prefix", "root"])
    }

    /// No server runs: the conf's own bind lines (Q103), comments and continuations as tmux reads them.
    @Test func tmuxGivesItsConf() throws {
        let rows = LearnConfigs.tmux(try Self.fixture("tmux.conf"))
        #expect(Self.pairs(rows) == [
            "prefix c = new-window -c #{pane_current_path}", "⌃H = select-pane -L", "prefix H = resize-pane -L 5",
            "prefix r = source-file ~/.tmux.conf",
        ])
        #expect(rows[1].detail == "root")
    }

    @Test func menuItemsGiveTheirShortcuts() throws {
        let bar = try JSONDecoder().decode([MenuItemNode].self, from: try Self.data("menu.json"))
        let rows = LearnConfigs.menuItems(bar, bundle: "com.example.app")
        #expect(Self.pairs(rows) == ["⌘N = File › New Window", "⇧⌘S = File › Save As…", "⌥⇧⌘K = File › Open Recent › Clear Menu",
                                     "⌘C = Edit › Copy"])
        #expect(rows[0].onReturn == .press("drive.menu:com.example.app:File > New Window"))
        #expect(rows.allSatisfy { $0.source == .thisApp })
    }

    @Test func garbageGivesNone() throws {
        let garbage = try Self.fixture("garbage.txt")
        #expect(LearnConfigs.shell(garbage).isEmpty)
        #expect(LearnConfigs.ghostty(garbage).isEmpty)
        #expect(LearnConfigs.git(garbage).isEmpty)
        #expect(LearnConfigs.neovim(garbage).isEmpty)
        #expect(LearnConfigs.tmux(garbage).isEmpty)
        #expect(LearnConfigs.menuItems([MenuItemNode(title: "File", enabled: true, children: [MenuItemNode(title: "Close", enabled: true)])],
                                       bundle: "com.example.app").isEmpty)
        #expect(LearnConfigs.shell("").isEmpty)
        #expect(LearnConfigs.neovim("").isEmpty)
    }
}
