#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// public-repo-catalogue T21, Sven's pick C of three (2026-11-11): Look's Themes
/// catalogue as a Catalogue part beside Look and More, a gallery of desks (LookDesk), each pack acting from its own tile:
/// its name in its own face, who made it, Get, Update to, Installed and Remove, and From others filtering to packs not
/// made by Pilot. The design T22 builds from, not the build. The packs are a fixed fixture: made-up
/// names and authors over Pilot's own palettes and wallpapers, nothing read from the network. The rail is the window's
/// own, drawn by AppWindowView at Look. Instrument in Lagoon and Porcelain, Toybox in Toybox, at 1000 by 660.
/// Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter ThemeCatalogueRenders`
extension SharedLook {
@MainActor
@Suite("Theme catalogue renders")
struct ThemeCatalogueRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let size = CGSize(width: 1000, height: 660)

    @Test("The Themes catalogue gallery, in Instrument dark and light and in Toybox",
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

        // Each pack's desk on a Look of its own in the pack's palette, over its wallpaper.
        var desks: [String: Desk] = [:]
        for base in Set(Fixture.instrument.map(\.base) + Fixture.toybox.map(\.base)) {
            let own = Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), defaults: LookTests.defaults())
            own.themeID = base
            desks[base] = Desk(look: own, picture: Fixture.wallpaper(base))
        }

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
            let packs = style == .toybox ? Fixture.toybox : Fixture.instrument
            let view = HStack(spacing: 0) {
                Image(nsImage: railImage).resizable().frame(width: rail, height: Self.size.height)
                CatalogueColumn(packs: packs, desks: desks, look: look)
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

/// A pack's desk: its own Look and its wallpaper.
private struct Desk {
    let look: Look
    let picture: Image?
}

/// One pack in the catalogue: `author` nil for Pilot's own, a GitHub handle for someone else's.
private struct Pack: Identifiable {
    enum State: Equatable { case get, installed, update(String) }
    let theme: PilotTheme
    /// The designed theme whose palette and wallpaper it borrows.
    let base: String
    let author: String?
    let version: String
    let state: State
    var toyboxOnly = false
    var id: String { theme.id }
    var installed: Bool { state != .get }
}

@MainActor
private enum Fixture {
    /// Kiln, someone else's, installed with an update offered, is the one picked.
    static let picked = "kiln"

    static let instrument: [Pack] = [
        pack("kiln", "Kiln", "Banked embers, raw clay", base: "garnet", by: "tomasz-w", "1.0", .update("1.1")),
        pack("lagoon", "Lagoon", "Cold light, deep water", base: "tokyo-night", by: nil, "1.2", .installed),
        pack("paper-lantern", "Paper Lantern", "Warm paper, a red seal", base: "folio", by: "hiro-n", "2.0", .installed),
        pack("harbour-fog", "Harbour Fog", "Sea mist over steel", base: "nord", by: "mira-k", "1.0", .get),
        pack("orchid", "Orchid", "Violet after midnight", base: "wisteria", by: nil, "1.1", .get),
        pack("moss-station", "Moss Station", "Lichen on slate", base: "jade", by: "petrel", "0.3", .get),
        pack("night-market", "Night Market", "Lanterns after rain", base: "retro-82", by: "joon-p", "1.4", .get),
        pack("chalk-garden", "Chalk Garden", "Pale glaze, pine ink", base: "celadon", by: "lin-ha", "1.0", .get),
    ]

    /// Toybox lists a Toybox-only pack in Night Market's place.
    static let toybox: [Pack] = instrument.map {
        $0.id == "night-market" ? pack("gumdrop", "Gumdrop", "Sweets after bedtime", base: "toybox-night", by: "joon-p", "1.0", .get, toyboxOnly: true) : $0
    }

    static func pack(_ id: String, _ name: String, _ tagline: String, base: String, by author: String?, _ version: String,
                     _ state: Pack.State, toyboxOnly: Bool = false) -> Pack {
        let t = PilotTheme.designed.first { $0.id == base }!
        let theme = PilotTheme(id: id, name: name, tagline: tagline, source: t.source, dark: t.dark, ground: t.ground, sidebar: t.sidebar,
                               surface: t.surface, raised: t.raised, line: t.line, line2: t.line2, text: t.text, text2: t.text2, text3: t.text3,
                               accent: t.accent, second: t.second, third: t.third, good: t.good, amber: t.amber, problem: t.problem,
                               graphs: t.graphs, selection: t.selection, onAccent: t.onAccent, focus: t.focus, radius: t.radius,
                               face: t.face, wallpaper: t.wallpaper)
        return Pack(theme: theme, base: base, author: author, version: version, state: state, toyboxOnly: toyboxOnly)
    }

    /// The first wide wallpaper of Pilot's own pack `base`, from the repo's catalogue copy (the app ships it palette-only).
    static func wallpaper(_ base: String) -> Image? {
        (try? SharedLook.LookRenders.shippedPicture(base)).flatMap(NSImage.init(contentsOf:)).map(Image.init(nsImage:))
    }

    static func counts(_ packs: [Pack]) -> (all: Int, installed: Int, updates: Int, others: Int) {
        (packs.count, packs.filter(\.installed).count, packs.filter { if case .update = $0.state { true } else { false } }.count,
         packs.filter { $0.author != nil }.count)
    }

    static let others = "From others: packs not made by Pilot, sent as pull requests. Each was checked as data before it joined: no scripts, links or templates."
}

// MARK: - The page column

/// The bar with Catalogue picked, then the gallery, on the window's ground.
private struct CatalogueColumn: View {
    let packs: [Pack]
    let desks: [String: Desk]
    let look: Look

    var body: some View {
        VStack(spacing: 0) {
            Bar(parts: ["Look", "Catalogue", "More"], picked: 1)
                .styled(.window, look: look)
            Gallery(packs: packs, desks: desks)
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

// MARK: - Shared parts

/// Who made it: "Pilot" for Pilot's own; a person and the handle for someone else's, so only those carry a mark.
private struct Author: View {
    @Environment(\.ink) private var ink
    let pack: Pack
    var on = false
    var size: CGFloat = 11.5

    var body: some View {
        HStack(spacing: 4) {
            if let author = pack.author {
                Image(systemName: "person.crop.circle").font(ink.ui(size - 0.5)).accessibilityHidden(true)
                Text("by \(author)").lineLimit(1)
            } else {
                Text("Pilot").lineLimit(1)
            }
            if pack.toyboxOnly { Text("· Toybox only").lineLimit(1) }
        }
        .font(ink.ui(size))
        .foregroundStyle(on && !ink.isInstrument ? ink.rowQuiet(true) : ink.text2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pack.author.map { "By \($0), not by Pilot" } ?? "By Pilot")
    }
}

/// A pack's desk, clipped to a frame with the window's hairline.
private struct DeskFrame: View {
    @Environment(\.ink) private var ink
    let desk: Desk?
    var radius: CGFloat = 10

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(radius), style: .continuous)
        Group {
            if let desk { LookDesk(look: desk.look, picture: desk.picture) } else { ink.line }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(ink.line, lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

// MARK: - The gallery

/// Each pack its desk, its name in its own face, who made it, and its action on the tile; From others filters to packs not
/// made by Pilot.
private struct Gallery: View {
    @Environment(\.ink) private var ink
    let packs: [Pack]
    let desks: [String: Desk]

    var body: some View {
        let counts = Fixture.counts(packs)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Chip(text: "All", on: true, count: "\(counts.all)")
                Chip(text: "Installed", count: "\(counts.installed)")
                Chip(text: "Updates", count: "\(counts.updates)")
                Chip(text: "From others", count: "\(counts.others)")
                InfoMark(text: Fixture.others)
                Spacer(minLength: 12)
                SearchBox(prompt: "Search \(counts.all) themes", text: .constant("")).frame(maxWidth: 220)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            ink.line.frame(height: 1)
            ScrollView {
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    ForEach(Array(stride(from: 0, to: packs.count, by: 3)), id: \.self) { start in
                        GridRow {
                            ForEach(packs[start..<min(start + 3, packs.count)]) { tile($0) }
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private func tile(_ pack: Pack) -> some View {
        let shape = RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            DeskFrame(desk: desks[pack.base], radius: 6).frame(height: 150).padding(6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pack.theme.name).display(16, face: pack.theme.face).foregroundStyle(ink.text).lineLimit(1)
                    Spacer(minLength: 6)
                    switch pack.state {
                    case .get: Button("Get") {}.buttonStyle(.pilot)
                    case .installed: Label("Installed", systemImage: "checkmark").font(ink.ui(12)).foregroundStyle(ink.text2)
                    case .update(let to): Button("Update to \(to)") {}.buttonStyle(.pilotPrimary)
                    }
                }
                HStack(spacing: 6) {
                    Author(pack: pack)
                    Text("· \(pack.version)").font(ink.ui(11.5)).foregroundStyle(ink.text2)
                    Spacer(minLength: 6)
                    if pack.installed {
                        Button("Remove") {}.buttonStyle(.plain).font(ink.ui(11.5, .medium)).foregroundStyle(ink.text2)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 10)
        }
        .background(ink.raised, in: shape)
        .overlay { shape.strokeBorder(pack.id == Fixture.picked ? ink.accent : ink.line, lineWidth: pack.id == Fixture.picked ? 1.5 : 1) }
    }
}
#endif
