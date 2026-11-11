#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Offscreen renders of the Snippets page (card agent-bo-95423044): the empty page, then four snippets (Commit
/// message with {cursor} and ;cm, Greeting with {argument}, Fix with ;cm again so the keywords clash, Address with no
/// keyword) with Commit message, Fix and Address picked in turn, then Greeting in the narrowest window; Tokyo Night and
/// Folio, the page at the window's width beside its sidebar, trimmed under its end. Per theme, one sheet stacks them. The library is a temp file and the theme is previewed, never saved. Opt-in like the
/// other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter SnippetsRenders`
extension SharedLook {
@MainActor
@Suite("Snippets renders")
struct SnippetsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let snippets: [Snippet] = [
        SnippetsEditorTests.commit,
        Snippet(name: "Greeting", keyword: ";hi", text: "Hi {argument},\n\nThanks for the quick reply. I'll look at it tonight and send notes."),
        SnippetsEditorTests.fix,
        SnippetsEditorTests.address,
    ]

    @Test("The snippets editor renders empty and with each kind of keyword picked, in Tokyo Night and Folio",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("snippets")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { Look.shared.preview(PilotTheme.defaultID) }

        let (empty, emptyStore) = try SnippetsEditorTests.library()
        let (full, fullStore) = try SnippetsEditorTests.library(Self.snippets)
        defer { for store in [emptyStore, fullStore] { try? FileManager.default.removeItem(at: store.url) } }
        // The window's default width, then its least (760), where the page stacks the editor under the list.
        let states: [(name: String, title: String, narrow: Bool, page: () -> SnippetsSettingsView)] = [
            ("01-empty", "No snippets yet", false, { SnippetsSettingsView(library: empty) }),
            ("02-cursor", "Commit message picked: {cursor}, and ;cm higher than Fix's", false, { SnippetsSettingsView(library: full, selected: Self.snippets[0].id) }),
            ("03-clash", "Fix picked: its ;cm never expands", false, { SnippetsSettingsView(library: full, selected: Self.snippets[2].id) }),
            ("04-no-keyword", "Address picked: no keyword", false, { SnippetsSettingsView(library: full, selected: Self.snippets[3].id) }),
            ("05-narrow", "Greeting picked: {argument}, the window at its least width", true, { SnippetsSettingsView(library: full, selected: Self.snippets[1].id) }),
        ]
        for theme in ["tokyo-night", "folio"] {
            Look.shared.preview(theme)
            var shots: [(String, NSBitmapImageRep)] = []
            for state in states {
                let page = state.page()
                    .frame(width: (state.narrow ? 760 : 1000) - 207, height: 1900).pilotTheme().background(Theme.background)
                let url = dir.appendingPathComponent("\(theme)-\(state.name).png")
                try RestyledRenders.writeTrimmed(rendered(page, wait: 0.4), from: 0, to: url)
                shots.append((state.title, try #require(NSBitmapImageRep(data: Data(contentsOf: url)))))
            }
            try ClipboardTabsRenders.sheet(shots, dark: Look.shared.theme.dark).write(to: dir.appendingPathComponent("sheet-\(theme).png"))
        }
    }
}
}
#endif
