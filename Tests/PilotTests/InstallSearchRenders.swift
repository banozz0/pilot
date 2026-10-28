import AppKit
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Install finds anything (N9) and its pictures (C5), drawn offscreen: a search's results grouped by source under the
/// catalogue's matches, each saying how it installs, and the Recommend apps switch on the page. The groups are made
/// here, pictures off, so nothing reaches the network. PILOT_RENDER_DIR keeps the PNG.
@MainActor
@Suite("Install search renders")
struct InstallSearchRenders {
    static let groups: [InstallSearch.Group] = [
        .init(source: .homebrew, results: [.init(title: "rectangle", via: "Homebrew app", detail: "Move and resize windows", source: .homebrew,
                                                 method: .package(Package(.cask, "rectangle")!))]),
        .init(source: .appStore, results: [.init(title: "Billiards 8-Ball Pool Master", via: "App Store · iPhone and iPad app", source: .appStore,
                                                 method: .page(URL(string: "macappstore://apps.apple.com/app/id6504484102")!))]),
        .init(source: .github, results: [.init(title: "videorc", via: "GitHub · opens the repo", source: .github,
                                               method: .page(URL(string: "https://github.com/TheOrcDev/videorc")!))],
              trouble: .limited(until: nil)),
        .init(source: .web, results: [.init(title: "Search the web for “rectangle”", via: "Google", source: .web,
                                            method: .page(URL(string: "https://www.google.com/search?q=rectangle")!))]),
    ]

    @Test("A search lists each source under its heading in order, how each result installs, and the Recommend apps switch")
    func grouped() throws {
        RemoteIcons.shared.enabled = false
        let entries = [CatalogueEntry(id: "rectangle-pro", name: "Rectangle Pro", category: "Window manager",
                                      method: .package(Package(.cask, "rectangle-pro")!), check: .bundle("x.none"),
                                      vendor: "https://rectangleapp.com/", checked: "2026-10-09")]
        let page = CataloguePage(entries: entries, query: "rectangle", found: Self.groups)
        let look = try LookPageTests().look().0   // its other parts vary by branch; only the look is needed
        var lines: [(text: String, box: CGRect)] = []
        try LookPageTests().hosted(page.frame(width: 1000, height: 1100).pilotTheme(look: look)) { host in
            let rep = try #require(snapshot(host, scale: 2))
            if let dir = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "install-search.png"))
            }
            lines = try recognisedText(in: rep)
        }
        let text = lines.map(\.text).joined(separator: "\n")
        // The rows stand top to bottom in the sources' order (Vision's boxes rise from the bottom).
        let heights = ["Rectangle Pro", "Billiards", "videorc", "Search the web"].map { title in
            lines.first { $0.text.hasPrefix(title) }?.box.midY
        }
        #expect(heights.allSatisfy { $0 != nil }, "read: \(text)")
        #expect(heights.compactMap(\.self) == heights.compactMap(\.self).sorted(by: >), "the sources' order, read: \(text)")
        for line in ["App Store", "opens the repo", "Recommend apps", "busy", "Open", "Install"] {
            #expect(text.contains(line), "\(line) missing, read: \(text)")
        }
    }

    @Test("A catalogue entry not on this Mac wears its shipped picture in the menu and on the page; a font keeps its glyph")
    func catalogueIcons() throws {
        let packaging = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Packaging/catalogue-icons")
        let shipped = try FileManager.default.contentsOfDirectory(atPath: packaging.path).filter { $0.hasSuffix(".png") }
        #expect(shipped.count >= 60)
        let catalogue = try InstallCatalogue.parse(Data(contentsOf: packaging.deletingLastPathComponent().appending(path: "install-catalogue.json")))
        // Every app has its picture; only fonts and four command-line tools with no logo of their own keep their glyph.
        let bare = catalogue.filter { !shipped.contains("\($0.id).png") }.map(\.id)
        #expect(bare.allSatisfy { $0.hasPrefix("font-") || ["telegram-tools", "discord-tools-cli", "easy-cd", "lazygit"].contains($0) }, "\(bare)")
        let spotify = try #require(catalogue.first { $0.id == "spotify" })
        #expect(MenuIcon.catalogue(spotify).bundled == "spotify")
        #expect(MenuEntries.install(catalogue, installed: []).first { $0.title == "Spotify" }?.icon?.bundled == "spotify",
                "the menu's Install row carries the same picture")
    }
}
