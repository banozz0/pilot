import Foundation
import Testing
@testable import PilotCore

/// Update (story 85; SPEC.md, the Update part of the Install line; wireframe wo-nZ-ZEKkY section 13): what would upgrade,
/// from which version to which, by category, one row or Update all at a time. Pure: fixtures in `brew outdated --json=v2` and
/// `uv tool list --outdated`'s shapes, captured read-only on 2026-10-05.
@Suite("Update list")
struct UpdateListTests {
    /// `brew outdated --json=v2`: brew itself leaves self-updating casks out.
    static let plain = Data("""
    {"formulae": [{"name": "atuin", "installed_versions": ["18.22.0"], "current_version": "18.23.0", "pinned": false, "pinned_version": null},
                  {"name": "beads", "installed_versions": ["1.1.0"], "current_version": "1.3.1", "pinned": true, "pinned_version": "1.1.0"}],
     "casks": [{"name": "zed", "installed_versions": ["0.205.4"], "current_version": "0.206.0"}]}
    """.utf8)
    /// The same with `--greedy-auto-updates`: the self-updating casks join.
    static let greedy = Data("""
    {"formulae": [{"name": "atuin", "installed_versions": ["18.22.0"], "current_version": "18.23.0", "pinned": false, "pinned_version": null},
                  {"name": "beads", "installed_versions": ["1.1.0"], "current_version": "1.3.1", "pinned": true, "pinned_version": "1.1.0"}],
     "casks": [{"name": "zed", "installed_versions": ["0.205.4"], "current_version": "0.206.0"},
               {"name": "ghostex", "installed_versions": ["5.5.0"], "current_version": "10.12.0"}]}
    """.utf8)
    static let uv = """
    beads-mcp v1.3.0 [latest: 1.3.1]
    - beads-mcp
    scrapling v0.4.14 [latest: 0.4.15]
    - scrapling
    - scrapling-mcp
    """

    static func rows() throws -> [UpdateRow] { try UpdateList.parse(plain: plain, greedy: greedy) + UpdateList.parseUV(uv) }

    @Test("Update all says what it updates in a few words, its command kept whole beside them (Moody vzACUY1p1lU: Instrument cut it mid-word)")
    func summary() {
        let rows = [UpdateRow(item: .package(Package(.cask, "zed")!), from: "1", to: "2"), UpdateRow(item: .package(Package(.cask, "arc")!), from: "1", to: "2"),
                    UpdateRow(item: .package(Package(.formula, "ripgrep")!), from: "1", to: "2"),
                    UpdateRow(item: .package(Package(.formula, "beads")!), from: "1", to: "2", pinned: true),
                    UpdateRow(item: .package(Package(.uv, "ruff")!), from: "1", to: "2"), UpdateRow(item: .appStore(id: "1", name: "Xcode"), from: "1", to: "2"),
                    UpdateRow(item: .macOS(label: "macOS 26.1", title: "macOS 26.1", restart: true), from: "26.0", to: "26.1")]
        #expect(UpdateList.summary(rows, includeSelfUpdating: false) == "2 casks · 1 formula · 1 uv tool · 1 App Store app",
                "a pinned formula and macOS do not go with Update all")
        let all = UpdateList.entries(rows, includeSelfUpdating: false).first { $0.target == .update(.all) }
        #expect(all?.short == "2 casks · 1 formula · 1 uv tool · 1 App Store app")
        #expect(all?.detail == UpdateList.all(rows, includeSelfUpdating: false), "the command stays the detail")
        #expect(UpdateList.summary([], includeSelfUpdating: false) == nil)
    }

    @Test("A formula, a cask and a self-updating cask parse with their versions; the self-updating one is marked")
    func parse() throws {
        let rows = try UpdateList.parse(plain: Self.plain, greedy: Self.greedy)
        #expect(rows.map(\.item.key) == ["formula:atuin", "formula:beads", "cask:zed", "cask:ghostex"])
        #expect(rows.map(\.from) == ["18.22.0", "1.1.0", "0.205.4", "5.5.0"])
        #expect(rows.map(\.to) == ["18.23.0", "1.3.1", "0.206.0", "10.12.0"])
        #expect(rows.map(\.selfUpdating) == [false, false, false, true])
        #expect(rows.map(\.pinned) == [false, true, false, false])
    }

    @Test("uv's outdated tools parse from its text: name, installed and latest version")
    func parseUV() {
        let rows = UpdateList.parseUV(Self.uv)
        #expect(rows.map(\.item.key) == ["uv:beads-mcp", "uv:scrapling"])
        #expect(rows.map(\.from) == ["1.3.0", "0.4.14"])
        #expect(rows.map(\.to) == ["1.3.1", "0.4.15"])
    }

    @Test("Self-updating casks stay out unless the setting includes them; the list is then exactly brew outdated's plus uv's")
    func visible() throws {
        let rows = try Self.rows()
        #expect(UpdateList.visible(rows, includeSelfUpdating: false).map(\.item.name) == ["atuin", "beads", "zed", "beads-mcp", "scrapling"])
        #expect(UpdateList.visible(rows, includeSelfUpdating: true).count == 6)
    }

    @Test("Every shown row upgrades but a pinned formula; one row alone runs only its own command")
    func command() throws {
        let rows = try Self.rows()
        #expect(UpdateList.command(rows, includeSelfUpdating: false)
                == "brew upgrade --formula atuin && brew upgrade --cask zed && uv tool upgrade beads-mcp scrapling")
        #expect(UpdateList.command(rows, includeSelfUpdating: true)
                == "brew upgrade --formula atuin && brew upgrade --cask --greedy zed ghostex && uv tool upgrade beads-mcp scrapling")
        #expect(UpdateList.command([rows[4]], includeSelfUpdating: true) == "uv tool upgrade beads-mcp")
        #expect(UpdateList.command([rows[1]], includeSelfUpdating: true) == nil, "beads is pinned")
    }

    @Test("Update lists Update all, then a category per kind with something outdated, then the self-updating switch; each row sits in its category (card agent-bo-95423022)")
    func entries() throws {
        let e = UpdateList.entries(try Self.rows(), includeSelfUpdating: false)
        #expect(e.first?.title == "Update all")
        #expect(e.first?.target == .update(.all))
        #expect(e.first?.detail == "brew upgrade --formula atuin && brew upgrade --cask zed && uv tool upgrade beads-mcp scrapling")
        #expect(e.filter { $0.home == .update }.map(\.title) == ["Update all", "Apps", "Command-line tools", "Apps that update themselves: Off", "Reports"])
        #expect(e[1].target == .branch(.category("Apps", in: .update)))
        #expect(e[1].detail == "zed")
        #expect(e[2].detail == "atuin, beads, beads-mcp, scrapling")
        func row(_ name: String) -> MenuEntry? { e.first { $0.title == name } }
        #expect(row("atuin")?.detail == "18.22.0 → 18.23.0 · formula")
        #expect(row("atuin")?.home == .category("Command-line tools", in: .update))
        #expect(row("beads")?.detail == "1.1.0 → 1.3.1 · formula · pinned by you · Return unpins")
        #expect(row("beads")?.target == .update(.unpin("formula:beads")))
        #expect(row("zed")?.target == .update(.row("cask:zed")))
        #expect(row("zed")?.home == .category("Apps", in: .update))
        #expect(row("ghostex") == nil, "a self-updating cask stays out while the switch is off")
        #expect(e.allSatisfy { $0.target.key == nil || $0.kind == .branch })
        var nav = MenuNavigator(entries: e, branch: .update)
        nav.query = "scrap"
        #expect(nav.rows.map(\.title) == ["scrapling"], "a search in Update finds every category's rows")
    }

    @Test("Nothing outdated: Update all says so and no category is listed")
    func upToDate() {
        let e = UpdateList.entries([], includeSelfUpdating: false)
        #expect(e.map(\.title) == ["Update all", "Apps that update themselves: Off", "Reports"])
        #expect(e.first?.detail == "everything is up to date")
        let macOS = UpdateList.entries(Self.more().filter { $0.category == .macOS }, includeSelfUpdating: false)
        #expect(macOS.first?.detail == "only macOS updates or pinned formulae left, pick each one", "macOS is listed, so Update all does not say up to date")
    }

    /// Card agent-bo-95422979: a formula Sven pinned with brew pin (beads) has a way out from Update itself.
    @Test("A pinned formula's way out is brew unpin; any other row has none")
    func unpin() throws {
        let rows = try Self.rows()
        let beads = try #require(rows.first { $0.item.key == "formula:beads" })
        #expect(UpdateList.unpin(beads) == "brew unpin beads")
        #expect(rows.filter { $0.item.key != "formula:beads" }.allSatisfy { UpdateList.unpin($0) == nil })
        // brew pins only formulae: a pinned row of any other kind keeps its own row, never an unpin that does nothing.
        let pinnedCask = UpdateRow(item: .package(try #require(Package(.cask, "zed"))), from: "1", to: "2", pinned: true)
        #expect(UpdateList.unpin(pinnedCask) == nil)
        #expect(UpdateList.entries([pinnedCask], includeSelfUpdating: true).last?.target == .update(.row("cask:zed")))
    }

    // MARK: macOS, App Store, npm, bun and cargo (card agent-bo-95422882)

    /// `softwareupdate --list` in the man page's shape, with a macOS update that restarts.
    static let softwareUpdate = """
    Software Update Tool

    Finding available software
    Software Update found the following new or updated software:
    * Label: macOS Tahoe 26.1-25B78
    \tTitle: macOS Tahoe 26.1, Version: 26.1, Size: 7012345KiB, Recommended: YES, Action: restart,
    * Label: Safari26.1TahoeAuto-26.1
    \tTitle: Safari, Version: 26.1, Size: 182000KiB, Recommended: YES,
    """
    /// `mas outdated`: id, name, from and to.
    static let mas = """
    497799835 Xcode (26.0 -> 26.1)
    1475387142 Tailscale (1.88.1 -> 1.90.0)
    """
    /// `npm outdated -g --json` from both trees on Sven's Mac, 2026-10-06 (the Homebrew one with its own npm).
    static let npmLocal = Data("""
    {"@anthropic-ai/claude-code": {"current": "2.1.288", "wanted": "2.1.291", "latest": "2.1.291", "dependent": "global",
      "location": "/Users/ada/.local/lib/node_modules/@anthropic-ai/claude-code"}}
    """.utf8)
    static let npmHomebrew = Data("""
    {"agent-browser": {"current": "0.28.0", "wanted": "0.38.2", "latest": "0.38.2", "dependent": "global",
      "location": "/opt/homebrew/lib/node_modules/agent-browser"},
     "npm": {"current": "11.19.1", "wanted": "12.2.0", "latest": "12.2.0", "dependent": "global",
      "location": "/opt/homebrew/lib/node_modules/npm"}}
    """.utf8)
    /// `bun outdated -g`, in bun's documented table.
    static let bun = """
    bun outdated v1.4.2 (50a8a8387)
    ┌──────────────┬─────────┬────────┬────────┐
    │ Package      │ Current │ Update │ Latest │
    ├──────────────┼─────────┼────────┼────────┤
    │ typescript   │ 5.5.3   │ 5.6.2  │ 5.6.2  │
    ├──────────────┼─────────┼────────┼────────┤
    │ esbuild (dev)│ 0.21.5  │ 0.21.5 │ 0.24.0 │
    └──────────────┴─────────┴────────┴────────┘
    """
    /// `cargo install --list` on Sven's Mac, 2026-10-06: a path crate and a registry one.
    static let cargoList = """
    lumen-cli v0.1.0 (/Users/ada/code/lumen/crates/lumen-cli):
        lumen
    wasm-bindgen-cli v0.2.125:
        wasm-bindgen
        wasm-bindgen-test-runner
    """

    static func more() -> [UpdateRow] {
        UpdateList.parseSoftwareUpdate(softwareUpdate, macOS: "26.0.1") + UpdateList.parseMas(mas)
            + UpdateList.parseNPM(npmLocal) + UpdateList.parseNPM(npmHomebrew) + UpdateList.parseBun(bun)
            + [UpdateRow(item: .cargo("wasm-bindgen-cli"), from: "0.2.125", to: "0.2.126")]
    }

    @Test("macOS updates parse by label, from the running macOS to the update's version; one that restarts says so")
    func parseSoftwareUpdate() {
        let rows = UpdateList.parseSoftwareUpdate(Self.softwareUpdate, macOS: "26.0.1")
        #expect(rows.map(\.item) == [.macOS(label: "macOS Tahoe 26.1-25B78", title: "macOS Tahoe 26.1", restart: true),
                                    .macOS(label: "Safari26.1TahoeAuto-26.1", title: "Safari", restart: false)])
        #expect(rows.map(\.from) == ["26.0.1", ""])
        #expect(rows.map(\.to) == ["26.1", "26.1"])
        #expect(UpdateList.parseSoftwareUpdate("Software Update Tool\n\nFinding available software\nNo new software available.\n",
                                               macOS: "26.0.1").isEmpty)
    }

    @Test("App Store apps, global npm packages per tree, bun's table and cargo's registry crates parse from → to")
    func parseMore() {
        #expect(UpdateList.parseMas(Self.mas).map(\.item) == [.appStore(id: "497799835", name: "Xcode"), .appStore(id: "1475387142", name: "Tailscale")])
        #expect(UpdateList.parseMas(Self.mas).map(\.to) == ["26.1", "1.90.0"])
        let npm = UpdateList.parseNPM(Self.npmLocal) + UpdateList.parseNPM(Self.npmHomebrew)
        #expect(npm.map(\.item) == [.npm("@anthropic-ai/claude-code", prefix: "/Users/ada/.local"), .npm("agent-browser", prefix: "/opt/homebrew")])
        #expect(npm.map(\.from) == ["2.1.288", "0.28.0"])
        #expect(npm.map(\.to) == ["2.1.291", "0.38.2"])
        // A package npm cannot find on the registry has no latest; the rest still list.
        #expect(UpdateList.parseNPM(Data(#"{"gone": {"current": "1.0.0", "location": "/opt/homebrew/lib/node_modules/gone"}, "agent-browser": {"current": "0.28.0", "latest": "0.38.2", "location": "/opt/homebrew/lib/node_modules/agent-browser"}}"#.utf8)).map(\.item.name) == ["agent-browser"])
        #expect(UpdateList.parseBun(Self.bun).map(\.item) == [.bun("typescript"), .bun("esbuild")])
        #expect(UpdateList.parseBun(Self.bun).map(\.to) == ["5.6.2", "0.24.0"])
        #expect(UpdateList.cargoCrates(Self.cargoList).map(\.name) == ["wasm-bindgen-cli"])
        #expect(UpdateList.cargoCrates(Self.cargoList).map(\.version) == ["0.2.125"])
        #expect(UpdateList.cargoLatest("wasm-bindgen-cli = \"0.2.126\"    # Command-line interface\nwasm-bindgen = \"0.2.126\"",
                                       crate: "wasm-bindgen-cli") == "0.2.126")
        #expect(UpdateList.cargoLatest("wasm-bindgen = \"0.2.126\"", crate: "wasm-bindgen-cli") == nil)
    }

    @Test("Update all runs every kind but macOS's updates, which are each the user's own pick; they list under macOS")
    func allLeavesMacOS() {
        let all = UpdateList.all(Self.more(), includeSelfUpdating: false) ?? ""
        #expect(!all.contains("softwareupdate"))
        #expect(all.contains("mas upgrade 497799835 1475387142"))
        #expect(Self.more().filter { $0.category == .macOS }.count == 2)
    }

    @Test("Each kind runs its own command, each npm tree through its own npm, macOS last")
    func moreCommand() {
        let rows = Self.more().filter { ![.bun("esbuild"), .appStore(id: "1475387142", name: "Tailscale")].contains($0.item) }
        #expect(UpdateList.command(rows, includeSelfUpdating: false) == [
            "'/Users/ada/.local/bin/npm' install -g --prefix '/Users/ada/.local' @anthropic-ai/claude-code@2.1.291",
            "'/opt/homebrew/bin/npm' install -g --prefix '/opt/homebrew' agent-browser@0.38.2",
            "bun update -g --latest typescript",
            "cargo install wasm-bindgen-cli",
            "mas upgrade 497799835",
            "softwareupdate -i 'macOS Tahoe 26.1-25B78' 'Safari26.1TahoeAuto-26.1'",
        ].joined(separator: " && "))
    }

    @Test("Each new row shows its name, versions and kind; a macOS update that restarts says so; mas missing offers Install mas")
    func moreEntries() {
        let e = UpdateList.entries(Self.more(), includeSelfUpdating: false, masInstalled: false, home: "/Users/ada")
        #expect(e.first?.title == "Update all")
        #expect(e.first { $0.title == "macOS Tahoe 26.1" }?.detail == "26.0.1 → 26.1 · macOS · restarts the Mac")
        #expect(e.first { $0.title == "Safari" }?.detail == "→ 26.1 · macOS")
        #expect(e.first { $0.title == "Xcode" }?.detail == "26.0 → 26.1 · App Store")
        #expect(e.first { $0.title == "Xcode" }?.home == .category("Apps", in: .update))
        #expect(e.first { $0.title == "@anthropic-ai/claude-code" }?.detail == "2.1.288 → 2.1.291 · npm in ~/.local")
        let mas = e.first { $0.target == .update(.installMas) }
        #expect(mas?.title == "App Store apps: install mas")
        #expect(mas?.home == .update)
        #expect(mas?.detail == "brew install mas")
        #expect(!UpdateList.entries(Self.more(), includeSelfUpdating: false, masInstalled: true).contains { $0.target == .update(.installMas) })
        #expect(Set(e.compactMap { if case .update(.row(let k)) = $0.target { k } else { nil } }).count == Self.more().count)
    }

    @Test("With Recommend apps off, mas missing offers no Install mas; the updates stay (card agent-bo-95423241)")
    func noMasOfferWithoutRecommendations() {
        let e = UpdateList.entries(Self.more(), includeSelfUpdating: false, masInstalled: false, recommend: false)
        #expect(!e.contains { $0.target == .update(.installMas) })
        #expect(e.count == UpdateList.entries(Self.more(), includeSelfUpdating: false, masInstalled: true).count)
    }

    @Test("A tool that exits 1 when it lists something, as npm outdated does, is still read when 1 counts as success")
    func exitOne() async throws {
        let script = "printf listed; exit 1"
        #expect(try await ChildProcess.run("/bin/sh", ["-c", script], success: [0, 1]) == "listed")
        await #expect(throws: ChildProcess.Failure.self) { try await ChildProcess.run("/bin/sh", ["-c", script]) }
    }
}
