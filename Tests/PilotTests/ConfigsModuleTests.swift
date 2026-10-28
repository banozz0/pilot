import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95422841: Hyper+Space › Config › <app> opens that config's real file in the main editor, never in Ghostty.
@MainActor
final class Opened { var calls: [(URL, String)] = [] }

@MainActor
@Suite("Configs")
struct ConfigsModuleTests {
    @Test("The Config branch lists one configs.edit row per config found, and a pick opens its real file with the editor")
    func openInEditor() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-configs-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let real = home.appendingPathComponent("code/dotfiles/zshrc")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("alias g=git\n".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".zshrc"), withDestinationURL: real)

        let rows = ConfigsModule.menuRows(home: home)
        #expect(rows.map(\.id) == ["configs.edit:zsh"])
        #expect(rows.map(\.label) == ["zsh config"])

        let opened = Opened()
        let action = try #require(ConfigsModule.dynamic("configs.edit:zsh", home: home, editor: { "dev.zed.Zed" }) { opened.calls.append(($0, $1)); return true })
        action.run()
        #expect(opened.calls.count == 1)
        #expect(opened.calls.first?.0 == real && opened.calls.first?.1 == "dev.zed.Zed")
        #expect(ConfigsModule.dynamic("configs.edit:tmux", home: home, editor: { "x" }) { _, _ in true } != nil)
        #expect(ConfigsModule.dynamic("apps.editor", home: home, editor: { "x" }) { _, _ in true } == nil)
    }

    @Test("Entries list the Config branch's rows under it; Config is an extra row, off by default")
    func branch() {
        let row = BindsPage.ActionInfo(id: "configs.edit:zsh", label: "zsh config", module: "apps")
        let entries = MenuEntries.build(apps: [], actions: [], store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher",
                                        openID: { $0 }, running: [], extras: [.config: [row]])
        let target = MenuEntry.Target.action("configs.edit:zsh")
        #expect(entries.contains { $0.target == target && $0.home == .config })
        #expect(!MenuBranch.top.contains(.config) && MenuRoot.extraRows.contains { $0.target == .branch(.config) })
    }

    @Test("A Config row wears its app's own icon, the first of its apps installed, as other app rows do; a shell's a terminal (S2)")
    func icons() throws {
        let karabiner = try #require(AppConfigs.known.first { $0.id == "karabiner" })
        #expect(ConfigsModule.icon(karabiner) { $0 == "org.pqrs.Karabiner-Elements.Preferences" }.bundle == "org.pqrs.Karabiner-Elements.Preferences")
        #expect(ConfigsModule.icon(karabiner) { _ in false }.bundle == nil, "none installed: the glyph")
        let zsh = try #require(AppConfigs.known.first { $0.id == "zsh" })
        #expect(ConfigsModule.icon(zsh).bundle == nil && ConfigsModule.icon(zsh).symbol == "terminal")
        let finder = MenuIcon.glyph("terminal", .neutral).app(bundle: "com.apple.finder")
        let row = BindsPage.ActionInfo(id: "configs.edit:x", label: "X config", module: "apps", icon: finder)
        let entries = MenuEntries.build(apps: [], actions: [], store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher",
                                        openID: { $0 }, running: [], extras: [.config: [row]])
        let entry = try #require(entries.first { $0.target == .action("configs.edit:x") })
        #expect(entry.icon?.bundle == "com.apple.finder", "the row keeps the icon it was read with")
        guard case .icon? = entry.art(tiled: true) else { Issue.record("Finder's own icon, not a glyph"); return }
    }
}
