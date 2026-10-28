import Foundation
import Testing
@testable import PilotCore

/// The menu's icons by meaning (card agent-bo-95423004; Sven, 2026-10-07: "you put same icons on everything ... for
/// apps use their own logo"): Remove, Install, Update and Clean each give their rows an app's own icon or a glyph of
/// what they are. Pure; the GUI test draws them.
@Suite("Menu icons")
struct MenuIconTests {
    func icons(_ rows: [MenuEntry]) -> [String: MenuIcon] {
        Dictionary(rows.compactMap { r in r.icon.map { (r.title, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    @Test("Remove: an app and a cask's app wear their own icon by path, a formula a terminal, a font its letters, a web app its own by bundle")
    func remove() throws {
        var rows = try RemoveListTests.rows()
        rows.append(RemoveRow(source: .package(try #require(Package(.cask, "font-jetbrains-mono"))), name: "JetBrains Mono"))
        RemoveList.addApps(&rows, paths: ["/Applications/Cap.app"], skipping: [])
        let got = icons(RemoveList.entries(rows))
        #expect(got["Zed"]?.appPath == "/Applications/Zed.app")
        #expect(got["Cap"]?.appPath == "/Applications/Cap.app")
        #expect(got["hello"] == .formula)
        #expect(got["hello"]?.symbol == "terminal")
        #expect(got["JetBrains Mono"]?.symbol == "textformat")
        #expect(got["X"]?.bundle == "dev.banozz.pilot.webapp.x")
        let categories = RemoveList.entries(rows).filter { if case .branch = $0.target { true } else { false } }
        #expect(Set(categories.compactMap(\.icon?.symbol)).count == categories.count, "each category wears its own glyph (card agent-bo-95423022)")
    }

    @Test("Install: every shipped category its own glyph, never the download arrow; a tool a terminal, a font its letters, an app by bundle")
    func install() throws {
        let entries = try InstallCatalogue.parse(Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Packaging/install-catalogue.json")))
        let rows = MenuEntries.install(entries, installed: [])
        let categories = rows.filter { if case .branch(.category) = $0.target { true } else { false } }
        #expect(categories.count == InstallCatalogue.categories(entries).count)
        let symbols = categories.compactMap(\.icon?.symbol)
        #expect(symbols.count == categories.count)
        #expect(Set(symbols).count == symbols.count, "two categories share a glyph: \(symbols)")
        #expect(!symbols.contains("arrow.down.circle"))
        for e in entries {
            let icon = MenuIcon.catalogue(e)
            if e.category == "Fonts" { #expect(icon.symbol == "textformat", "\(e.name)") }
            if let p = e.method.package, p.kind == .formula { #expect(icon.symbol == "terminal", "\(e.name)") }
            if case .bundle(let id) = e.check { #expect(icon.bundle == id, "\(e.name)") }
        }
    }

    @Test("Update: a formula a terminal, an App Store app its own icon by name, macOS the Apple; the run, setting and mas rows differ")
    func update() throws {
        let hello = try #require(Package(.formula, "hello"))
        #expect(MenuIcon.updatable(.package(hello)).symbol == "terminal")
        #expect(MenuIcon.updatable(.appStore(id: "1", name: "Xcode")).appPath == "/Applications/Xcode.app")
        #expect(MenuIcon.updatable(.macOS(label: "a", title: "b", restart: false)).symbol == "apple.logo")
        let rows = UpdateList.entries([], includeSelfUpdating: false, masInstalled: false)
        let symbols = rows.compactMap(\.icon?.symbol)
        #expect(symbols.count == rows.count && Set(symbols).count == symbols.count)
    }

    @Test("Clean: a browser's cache, a developer tool's, logs and the Trash each their own glyph, and the clean, Disk usage and Install Mole too")
    func clean() {
        #expect(MenuIcon.clean(title: "Chrome cache", section: "Browsers").symbol == "safari")
        #expect(MenuIcon.clean(title: "Xcode DerivedData", section: "Developer tools").symbol == "hammer")
        #expect(MenuIcon.clean(title: "User app logs", section: "User essentials").symbol == "doc.plaintext")
        #expect(MenuIcon.clean(title: "Trash", section: "User essentials").symbol == "trash")
        let preview = CleanPreview(items: [.init(section: "Browsers", title: "Chrome cache", detail: "1 GB")], total: "1 GB", systemSkipped: true)
        let symbols = CleanMenu.entries(preview, mole: true).compactMap(\.icon?.symbol)
        #expect(Set(symbols).count == symbols.count, "\(symbols)")
        #expect(CleanMenu.entries(nil, mole: false).first?.icon != nil)
    }
}
