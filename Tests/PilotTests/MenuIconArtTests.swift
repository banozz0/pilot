import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The menu's icons drawn (card agent-bo-95423004): an app's path gives its own icon, a missing app its glyph; every
/// glyph Pilot names is a real SF Symbol; and the actions' table gives each its own.
@MainActor
@Suite("Menu icon art")
struct MenuIconArtTests {
    @Test("An app's path draws that app's own icon; an app not on the Mac draws its glyph")
    func appPath() {
        let calculator = MenuIcon.app.app(path: "/System/Applications/Calculator.app")
        guard case .icon(_, let badge) = MenuEntry.art(calculator, tiled: true) else {
            Issue.record("Calculator.app drew no icon"); return
        }
        #expect(badge == nil)
        let gone = MenuIcon.cask.app(path: "/Applications/Not Here.app")
        guard case .tile(let symbol, _) = MenuEntry.art(gone, tiled: true) else { Issue.record("no tile"); return }
        #expect(symbol == "shippingbox")
    }

    @Test("A Remove row for an app draws its own icon through the row's art")
    func removeRowArt() {
        let rows = [RemoveRow(source: .app(path: "/System/Applications/Calculator.app"), name: "Calculator", app: "/System/Applications/Calculator.app")]
        let entry = RemoveList.entries(rows)[1]
        guard case .icon? = entry.art(tiled: true) else { Issue.record("the Remove row drew no app icon"); return }
    }

    @Test("Every glyph the menu names is an SF Symbol this Mac draws")
    func symbolsExist() throws {
        let entries = try InstallCatalogue.parse(Data(contentsOf: RestyledPagesTests.shipped))
        var symbols = InstallCatalogue.categories(entries).map { MenuIcon.category($0).symbol }
        symbols += [MenuIcon.formula, .font, .cask, .uv, .npm, .bun, .cargo, .appStore, .macOS, .webApp, .app, .download].map(\.symbol)
        symbols += ["Chrome cache", "Xcode", "logs", "Trash", "Downloads", "Slack", "Spotify", "System", "App leftovers", "other"]
            .map { MenuIcon.clean(title: $0, section: "").symbol }
        symbols += MenuEntry.tabledActions.compactMap(MenuEntry.actionSymbol)
        symbols += ["workspaces.go:3", "workspaces.move:3", "windows.focusLeft", "windows.moveRight", "windows.resizeUp"].compactMap(MenuEntry.actionSymbol)
        symbols += MenuBranch.allCases.map(\.look.symbol)
        for symbol in Set(symbols) { #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol) is not an SF Symbol") }
    }

    @Test("No two actions in the table share a glyph")
    func actionsDistinct() {
        let symbols = MenuEntry.tabledActions.compactMap(MenuEntry.actionSymbol)
        let shared = Dictionary(grouping: MenuEntry.tabledActions, by: { MenuEntry.actionSymbol($0) ?? "" }).filter { $0.value.count > 1 }
        #expect(shared.isEmpty, "shared glyphs: \(shared)")
        #expect(symbols.count == MenuEntry.tabledActions.count)
    }

    @Test("Learn's app opens each wear their own glyph, never the Apps module's grid (Moody, menu-learn.jpg)")
    func learnAppActions() {
        let ids = ["apps.editor", "apps.files", "apps.passwords", "apps.terminal"]
        let symbols = ids.map(MenuEntry.actionSymbol)
        #expect(!symbols.contains(nil), "an app open wears the module grid: \(zip(ids, symbols).filter { $0.1 == nil }.map(\.0))")
        #expect(Set(symbols.compactMap(\.self)).count == ids.count)
    }
}
