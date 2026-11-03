#if DEBUG
import AppKit
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Film v2 (Sven, 2026-10-29, Q578 to Q583): the pages the 1.0 film never showed, in Pilot's window at the film's size and
/// in its theme (ExplainerFilmRenders.theme, Void), on Pilot default's binds as a new install has them: Keys › Swap keys
/// with one swap made, Keys › Plain combos, Launcher › Quicklinks (the shipped four) and Launcher › Aliases (a few saved),
/// and Tools › Voice; and for the 1.0.3 film and its shorts (P89), the Gallery and the widgets, one at a time. Fakes
/// throughout, in a moved home: nothing is swapped at the HID level (the tap never runs here), no wallpaper is set, and
/// no model, network or this Mac's devices are read. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter FilmV2Renders`
extension SharedLook {
@MainActor
@Suite("Film v2 renders")
struct FilmV2Renders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let aliases: [Alias] = [
        Alias(key: "action:apps.webApp", alias: "wa", title: "Make a web app"), Alias(key: "app:com.apple.Safari", alias: "sf", title: "Safari"),
        Alias(key: "action:apps.clipboard", alias: "cb", title: "Clipboard history"), Alias(key: "package:cask:zed", alias: "z", title: "Zed"),
        Alias(key: "app:com.mitchellh.ghostty", alias: "t", title: "Ghostty"),
    ]

    @Test("Pilot's window on Pilot default: Swap keys, Plain combos, Quicklinks, Aliases and Voice",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func pages() throws {
        let dir = try ExplainerFilmRenders.prepare("v2-pages")
        try FileManager.default.createDirectory(at: PilotFolder.support, withIntermediateDirectories: true)
        try #require(PilotFolder.support.path.hasPrefix(NSHomeDirectory()), "Pilot's folder would land outside the moved home")
        try AliasesStore.standard.save(Aliases(Self.aliases))
        let engine = try HomeRenders.engine()
        // Pilot default, the preset a new install starts on.
        try Data(#"{"version": 3, "preset": "pilot", "binds": []}"#.utf8).write(to: engine.binds.fileURL)
        engine.binds.load()
        // A swap reaches the keyboard only through this hook and a running tap; the render never starts the tap, and the hook
        // goes quiet first so no swap can reach this Mac's keyboard.
        engine.settings.onKeySwapsChange = {}
        engine.settings.keySwaps = [KeySwap(.rightCommand, .rightOption)]
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close(); engine.settings.keySwaps = [] }
        let frame = try #require(window.contentView?.superview)
        AppWindowController.applyLook(Look.shared, to: window)
        for (place, name) in [(AppPlace(.keySwaps), "key-swaps"), (AppPlace(.plainCombos), "plain-combos"),
                              (AppPlace(.quicklinks), "quicklinks"), (AppPlace(.aliases), "aliases"), (AppPlace(.voice), "voice")] {
            window.setContentSize(NSSize(width: 1200, height: 780))
            model.go(place)
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    /// The 1.0.3 film (P89): the Gallery on the wallpaper folder, as the desktop menu's Change wallpaper… opens it, and on a
    /// folder of notes and pictures, in Pilot's own window at its own size. The wallpapers are copied from PILOT_FILM_WALLS
    /// when given, else made up; every file sits in the moved home, thumbnails are read with ImageIO
    /// (FileThumbnailRenders.fake), never QuickLook, and nothing is set as a wallpaper.
    @Test("The Gallery on the wallpapers and on a folder of notes and pictures",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func gallery() async throws {
        let dir = try ExplainerFilmRenders.prepare("v3-gallery")
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory), files = FileManager.default
        let walls = home.appending(path: "Pictures/Wallpapers"), trip = home.appending(path: "Documents/Lisbon weekend")
        for folder in [walls, trip] {
            try? files.removeItem(at: folder)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if let given = Self.env["PILOT_FILM_WALLS"] {
            for url in try files.contentsOfDirectory(at: URL(filePath: given), includingPropertiesForKeys: nil) where WallpaperCycle.isImage(url) {
                try files.copyItem(at: url, to: walls.appending(path: url.lastPathComponent))
            }
        } else {
            for (i, name) in ["dawn", "harbour", "moss", "night"].enumerated() {
                try Self.gradient(walls.appending(path: "\(name).png"), hue: Double(i) / 4)
            }
        }
        let pictures = try files.contentsOfDirectory(at: walls, includingPropertiesForKeys: nil).filter(WallpaperCycle.isImage).sorted { $0.path < $1.path }
        try #require(!pictures.isEmpty)
        for (i, url) in pictures.prefix(2).enumerated() {
            try files.copyItem(at: url, to: trip.appending(path: ["tram-28", "miradouro"][i] + "." + url.pathExtension))
        }
        for (name, text) in Self.tripNotes { try Data(text.utf8).write(to: trip.appending(path: name)) }

        for (folder, wallpaper, name) in [(walls, true, "wallpapers"), (trip, false, "folder")] {
            let model = GalleryModel(folder: folder)
            model.make = FileThumbnailRenders.fake
            model.cardWidth = 220
            model.show(folder, wallpaper: wallpaper, display: nil, sources: [folder])
            defer { model.close() }
            let host = NSHostingView(rootView: GalleryView(model: model).styled(.window).pilotTheme().pilotWindowStyles())
            let window = AppWindowController.makeWindow(content: host, size: GalleryWindow.size, minSize: GalleryWindow.minSize)
            window.title = "Gallery"
            defer { window.close() }
            AppWindowController.applyLook(Look.shared, to: window)
            let want = try files.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.count
            let deadline = Date().addingTimeInterval(4)
            while model.items.count < want, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(model.items.count == want, "\(name): \(model.items.count) of \(want) listed")
            try await Task.sleep(for: .milliseconds(1800))
            let frame = try #require(window.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("gallery-\(name).png"))
        }
    }

    /// The weekend folder's notes, made up.
    static let tripNotes: [(String, String)] = [
        ("plan.md", "# Lisbon weekend\n\n- Book the 9:40 train to Sintra\n- Lunch at the market\n- Ask Ana if she wants to come\n"),
        ("packing.md", "# Packing\n\n- [ ] Camera and the small lens\n- [ ] Rain jacket\n- [x] Adapters\n- [ ] Train tickets\n"),
        ("places.md", "# Places\n\nMiradouro da Graça at sunset. Tram 28 early, before the queues. Pastéis in Belém.\n"),
    ]

    /// A made-up wallpaper: a soft two-colour gradient, 1920 by 1080.
    static func gradient(_ url: URL, hue: Double) throws {
        let image = NSImage(size: NSSize(width: 1920, height: 1080), flipped: false) { rect in
            NSGradient(colors: [NSColor(hue: hue, saturation: 0.55, brightness: 0.35, alpha: 1),
                                NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.8, alpha: 1)])?
                .draw(in: rect, angle: 35)
            return true
        }
        let tiff = try #require(image.tiffRepresentation), rep = try #require(NSBitmapImageRep(data: tiff))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// The 1.0.3 film's widgets (P89): every native ready widget and every bundled desk widget, one PNG each, in the film's
    /// theme, Instrument, solid, on fixed readings (WidgetRenders' and DeskWidgetRenders' fixtures), never this Mac's.
    /// `PILOT_RESOURCES=Packaging` bundles the desk widgets.
    @Test("The ready and desk widgets, one at a time, in the film's theme",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_RESOURCES"] != nil))
    func widgets() async throws {
        let dir = try ExplainerFilmRenders.prepare("v3-widgets")
        let store = try DeskWidgetRenders.store()
        let look = Look.shared
        let natives = ReadyWidgets.inCode.map { ($0, "") } + [(try #require(ReadyWidgets.widget(ReadyWidgets.notes)), WidgetRenders.notes[0].id)]
        for (widget, note) in natives {
            let model = WidgetTileModel()
            model.title = widget.title; model.icon = widget.icon; model.blocks = WidgetRenders.blocks(widget, note: note); model.buttons = widget.buttons
            if widget.menuField != nil { model.tiles = WidgetRenders.tiles }
            if widget.data == .github { model.contributions = .init(calendar: WidgetRenders.contributions) }
            if widget.id == ReadyWidgets.folder { model.folder = WidgetFolder.sample() }
            if case .markets = widget.data { model.markets = WidgetRenders.board(WidgetRenders.marketKeys) }
            let tile = WidgetTile(model: model, look: look).frame(width: widget.size.width, height: widget.size.height)
            try writeRender(tile.styled(.hud).pilotTheme(look: look), to: dir.appendingPathComponent("\(widget.id).png"), wait: 0.8)
        }
        for id in DeskWidgetRenders.ids {
            let widget = try #require(store.widget(id))
            let shot = try await DeskWidgetRenders.shot(widget, store: store, data: DeskWidgetRenders.fixture(id), theme: DeskWidgetRenders.theme(look.theme))
            let model = WidgetTileModel()
            model.page = true
            let tile = WidgetTile(model: model, look: look).overlay { Image(nsImage: shot).resizable() }
                .frame(width: widget.size.width, height: widget.size.height)
            try writeRender(tile.styled(.hud).pilotTheme(look: look), to: dir.appendingPathComponent("\(id).png"), wait: 0.4)
        }
    }
}
}
#endif
