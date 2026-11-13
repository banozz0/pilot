#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// public-repo-catalogue T22 (Sven's pick C of T21's three, 2026-11-11): Look › Catalogue as Pilot draws it, the real
/// gallery (ThemeCatalogueGallery) under the Look bar with its parts as AppPage.look lists them, every tile state shown:
/// In use, Apply, Get, Update, Remove, working and failed. The tiles are a fixed fixture: made-up pack names over Pilot's
/// own palettes and wallpapers, authors that are plainly examples, nothing read from the network or Pilot's themes. The
/// rail is the window's own, drawn by AppWindowView at Look. Instrument in Lagoon and Porcelain, Toybox in Toybox, at
/// 1000 by 660. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter ThemeCatalogueRenders`
extension SharedLook {
@MainActor
@Suite("Theme catalogue renders")
struct ThemeCatalogueRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let size = CGSize(width: 1000, height: 660)

    @Test("Look › Catalogue's gallery, in Instrument dark and light and in Toybox",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("theme-catalogue")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()

        let engine = try SharedLook.HomeRenders.engine()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }

        let looks: [(name: String, style: PilotStyle, theme: String)] = [
            ("instrument-dark", .instrument, "lagoon"), ("instrument-light", .instrument, "porcelain"), ("toybox", .toybox, "toybox"),
        ]
        for (name, style, theme) in looks {
            look.style = style
            look.themeID = theme
            AppWindowController.applyLook(look, to: window)
            window.setContentSize(Self.size)
            model.go(AppPlace(.look))
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            frame.layoutSubtreeIfNeeded()
            let chrome = try #require(snapshot(frame, scale: 2))
            let rail: CGFloat = style == .toybox ? 78 : 73
            let cg = try #require(chrome.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: Int(rail) * 2, height: Int(Self.size.height) * 2)))
            let railImage = NSImage(cgImage: cg, size: NSSize(width: rail, height: Self.size.height))
            let view = HStack(spacing: 0) {
                Image(nsImage: railImage).resizable().frame(width: rail, height: Self.size.height)
                CatalogueColumn(tiles: style == .toybox ? Fixture.toybox : Fixture.instrument, look: look)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(engine)
            .pilotWindowStyles()
            .pilotTheme(look: look)
            try MoreTabRenders.hosted(view, size: Self.size) { host in
                let rep = try #require(snapshot(host, scale: 2))
                try #require(rep.representation(using: .png, properties: [:]))
                    .write(to: dir.appendingPathComponent("gallery-\(name).png"))
            }
        }
    }
}
}

// MARK: - The fixture

@MainActor
private enum Fixture {
    static let instrument: [ThemeCatalogueTile] = [
        tile("kiln", "Kiln", base: "garnet", by: "example-author", .update),
        tile("lagoon", "Lagoon", base: "tokyo-night", by: nil, .builtIn, applied: true),
        tile("paper-lantern", "Paper Lantern", base: "folio", by: "example-handle", .installed),
        tile("harbour-fog", "Harbour Fog", base: "nord", by: "example-user", .get, busy: "Getting 3 of 5…"),
        tile("orchid", "Orchid", base: "wisteria", by: nil, .builtIn),
        tile("moss-station", "Moss Station", base: "jade", by: "example-author", .get),
        tile("night-market", "Night Market", base: "retro-82", by: "example-handle", .get,
             failure: "Night Market was not installed: wallpapers/night-market.heic did not match the catalogue's sha256"),
        tile("chalk-garden", "Chalk Garden", base: "celadon", by: "example-user", .get),
    ]

    /// Toybox lists a Toybox-only pack in Night Market's place.
    static let toybox: [ThemeCatalogueTile] = instrument.map {
        $0.id == "night-market" ? tile("gumdrop", "Gumdrop", base: "toybox-night", by: "example-handle", .get, toyboxOnly: true) : $0
    }

    static func tile(_ id: String, _ name: String, base: String, by author: String?, _ standing: ThemeCatalogueModel.Standing,
                     applied: Bool = false, toyboxOnly: Bool = false, busy: String? = nil, failure: String? = nil) -> ThemeCatalogueTile {
        let t = PilotTheme.designed.first { $0.id == base }!
        let theme = PilotTheme(id: id, name: name, tagline: t.tagline, source: t.source, dark: t.dark, ground: t.ground, sidebar: t.sidebar,
                               surface: t.surface, raised: t.raised, line: t.line, line2: t.line2, text: t.text, text2: t.text2, text3: t.text3,
                               accent: t.accent, second: t.second, third: t.third, good: t.good, amber: t.amber, problem: t.problem,
                               graphs: t.graphs, selection: t.selection, onAccent: t.onAccent, focus: t.focus, radius: t.radius,
                               face: t.face, wallpaper: t.wallpaper)
        return ThemeCatalogueTile(id: id, theme: theme, author: author, standing: standing, applied: applied, toyboxOnly: toyboxOnly,
                                  busy: busy, failure: failure, picture: wallpaper(base))
    }

    /// The first wide wallpaper of Pilot's own pack `base`, from the repo's catalogue copy, made small as the model makes it.
    static func wallpaper(_ base: String) -> NSImage? {
        (try? SharedLook.LookRenders.shippedPicture(base)).flatMap { WallpaperScreen.thumbnail($0, size: 480) }
    }
}

// MARK: - The page column

/// The bar with Catalogue picked, then the gallery, on the window's ground.
private struct CatalogueColumn: View {
    let tiles: [ThemeCatalogueTile]
    let look: Look

    var body: some View {
        let parts = AppPage.look.tabs
        VStack(spacing: 0) {
            Bar(parts: parts.map(\.title), picked: parts.firstIndex { $0.value == .themeCatalogue } ?? 0)
                .styled(.window, look: look)
            ThemeCatalogueGallery(tiles: tiles, load: .loaded)
            .styled(.page(.look), look: look)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .styled(.window, look: look)
        .background { Ground().styled(.window, look: look) }
    }
}

private struct Ground: View {
    @Environment(\.style) private var style
    var body: some View {
        if style.kind == .toybox { style.color(\.canvas) } else { Theme.windowFill(style.color(\.canvas)) }
    }
}

/// The page's bar as InstrumentToolbar and ToyPageHeader draw a page with parts, `picked` lit.
private struct Bar: View {
    @Environment(\.style) private var style
    let parts: [String]
    let picked: Int

    var body: some View {
        let options = parts.enumerated().map { (value: $0.offset, title: $0.element) }
        let selection = Binding.constant(picked)
        if style.kind == .toybox {
            HStack(alignment: .center, spacing: 16) {
                PageTitle(text: "Look").lineLimit(1).fixedSize()
                ToySegments(selection: selection, options: options, label: "Look parts")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Toy.gutter).padding(.top, 24).padding(.bottom, 14)
        } else {
            VStack(spacing: 0) {
                InstrumentPageBar(title: "Look") {
                    HStack(spacing: 10) {
                        InstrumentSegments(options: options, selection: selection).fixedSize()
                        Text(RailLayout.partsHint).styleText(\.key).foregroundStyle(style.color(\.text3)).fixedSize()
                    }
                    .padding(.leading, 8)
                    Spacer(minLength: 8)
                }
                InstrumentRule()
            }
        }
    }
}
#endif
