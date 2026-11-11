#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Defaults › Quicklinks (card agent-bo-95423030) for Sven and Moody: the section alone at the page widths of a 1000 and a
/// 760 window, Tokyo Night and Folio: as it opens on the shipped four, the mouse over GitHub, GitHub open
/// in the editor, a new link refused for GitHub's keyword, and empty; RestyledRenders draws it on the whole page. Each book
/// lives in a temporary folder, in a moved home; nothing opens a URL. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter QuicklinksRenders`
extension SharedLook {
@MainActor
@Suite("Quicklinks renders")
struct QuicklinksRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Defaults › Quicklinks renders in Tokyo Night and Folio", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("quicklinks")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-render-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        /// `unreadable`: a quicklinks.json that does not decode, so Save refuses every link (Moody, Nq1swKUORHA).
        func book(_ links: [Quicklink]? = nil, unreadable: Bool = false) throws -> QuicklinkBook {
            let url = folder.appending(path: "\(UUID().uuidString)/quicklinks.json")
            if unreadable {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("{".utf8).write(to: url)
            }
            let book = QuicklinkBook(store: QuicklinksStore(url: url))
            if let links { book.links = links }
            return book
        }

        let gh = Quicklink.shipped[0]
        let states: [(name: String, start: QuicklinksList.Start, links: [Quicklink]?)] = [
            ("list", .init(), nil), ("hover", .init(hovered: gh.id), nil), ("edit", .init(editing: gh), nil),
            ("refused", .init(editing: Quicklink(name: "GitHub issues", keyword: "gh", url: "https://github.com/issues?q={query}"), saved: true), nil),
            ("empty", .init(), []),
            ("unreadable", .init(editing: Quicklink(name: "Vercel", keyword: "vc", url: "https://vercel.com"), saved: true), nil),
        ]
        let only = Self.env["PILOT_RENDER_ONLY"]
        defer { Look.shared.themeID = PilotTheme.defaultID }
        for theme in ["tokyo-night", "folio"] {
            Look.shared.themeID = theme
            for width in [1000, 760] {
                for state in states {
                    let name = "\(theme)-\(width)-\(state.name)"
                    guard only.map(name.contains) ?? true else { continue }
                    // The page's own margins round the section, beside Instrument's sidebar and hairline.
                    let section = QuicklinksList(book: try book(state.links, unreadable: state.name == "unreadable"), start: state.start)
                        .padding(20).padding(.top, -14)
                        .frame(width: LookRenders.page(CGFloat(width)))
                        .pilotTheme(look: .shared).background(Theme.background)
                    try writeRender(section, to: dir.appendingPathComponent("\(name).png"))
                }
            }
        }
    }
}
}
#endif
