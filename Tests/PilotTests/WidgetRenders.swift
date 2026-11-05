#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
import WebKit
@testable import Pilot

/// SwiftUI has a Widget of its own.
typealias Widget = PilotCore.Widget

extension SharedLook {
/// Desktop widgets (ADR 0016; spec pilot-1-1 T19, T21), opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-w PILOT_RENDER_DIR=/tmp/pilot-renders-w swift test --filter WidgetRenders`
/// - Pilot's ready widgets (This Mac, the clock and calendar, a note) on fixed readings, in each style, solid and glass.
/// - A locked HTML widget: its Trust to run card, and no page view made for it.
/// - The Launcher's tiles, Hyper+Space rows with an app's own icon or the row's glyph, each style, solid and glass:
///   `widgets/launcher.png`.
/// - The Repos widget on fixture repos made in the moved home's `code/` (changed, ahead and behind, an unpushed branch,
///   clean), read by git as the widget reads them, at three sizes in each style, solid and glass, then all clean and
///   none: `widgets/repos.png`.
/// - The GitHub widget on a fixture calendar: gh's answer parsed, a stand-in gh read and kept, its failures, then its four
///   classes in each style, solid and glass, and its failures and preview: `widgets/github.png`.
/// - Now playing on fixture tracks (playing, paused, no cover, nothing playing) at its four size classes, a sheet a style,
///   solid then glass: `widgets/now-playing-<style>.png`.
/// - The Folder widget on a fixture folder in the moved home: its read (hidden files and apps out, an app one item), its
///   watch, then its four classes, a subfolder with back lit, empty and unreadable, each style: `widgets/folder.png`.
/// - The Markets widget on a fixture answer, one symbol (1D and 1M) and several, at its four size classes in each style,
///   with no Markets extension installed: `widgets/markets-<style>.png`.
/// - With PILOT_RESOURCES=Packaging, every native ready widget beside two HTML desk widgets on the look kit, a sheet a theme.
/// - A made-here HTML widget's page loaded offscreen: what its scheme answers for its own files, `/__pilot/`, `%2e%2e`, a
///   link out of its folder, another widget's id and a locked widget, and that its main frame stays put; written to
///   `widgets/page-probe.txt`.
@MainActor
@Suite("Widget renders")
struct WidgetRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static func dir() throws -> URL {
        let home = try #require(env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to draw on Sven's data")
        let dir = URL(fileURLWithPath: try #require(env["PILOT_RENDER_DIR"])).appendingPathComponent("widgets")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A store of its own in the moved home, never Pilot's.
    static func store() throws -> WidgetStore {
        let root = URL(fileURLWithPath: try #require(env["CFFIXED_USER_HOME"])).appending(path: "widget-renders-\(UUID().uuidString)")
        let store = WidgetStore(root: root, passwords: false)
        try FileManager.default.createDirectory(at: store.widgets, withIntermediateDirectories: true)
        return store
    }

    /// A widget folder in `store`: its widget.json and files.
    static func make(_ store: WidgetStore, _ id: String, _ manifest: String, files: [String: String] = [:]) throws -> Widget {
        let folder = store.widgets.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: folder.appending(path: Widget.manifestName))
        for (path, text) in files {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return try Widget(folder: folder)
    }

    /// This Mac's and the clock's readings at a fixed moment.
    static let readings: [String: JSONValue] = [
        "cpu": .object(["percent": .number(23)]), "memory": .object(["percent": .number(64)]),
        "disk": .object(["percent": .number(61), "available": .number(212_000_000_000), "total": .number(494_000_000_000)]),
        "battery": .object(["present": .bool(true), "percent": .number(82), "charging": .bool(false), "phrase": .string("82 % · 3 h 10 min left")]),
        "clock": .object(["time": .string("21:04"), "date": .string("Wednesday 7 October")]),
        "calendar": .object(["access": .bool(true), "events": .array([
            .object(["title": .string("Stand-up"), "allDay": .bool(false), "start": .string("09:30")]),
            .object(["title": .string("Ship 1.0.2"), "allDay": .bool(true), "start": .string("00:00")]),
        ])]),
    ]

    /// Notes as a notes widget lists them: one pinned, the rest by date.
    static let notes = [
        Note(id: "groceries-a1.md", text: "# Groceries\n\n- oat milk\n- **coffee** beans\n- lemons", edited: Date().addingTimeInterval(-3600), pinned: false),
        Note(id: "pilot-1-0-2-b2.md", text: "# Pilot 1.0.2\n\nShip the widgets build, then the shelf.", edited: Date().addingTimeInterval(-86_400), pinned: true),
        Note(id: "call-the-bank-c3.md", text: "Call the bank before 4", edited: Date().addingTimeInterval(-7 * 86_400), pinned: false),
    ]

    /// Repos as the Repos widget reads them: one with files changed, one ahead and behind, an unpushed branch, a clean one.
    static let repos = [
        RepoStatus(name: "pilot", url: URL(filePath: "/var/empty/pilot"), branch: "main", changed: 3, ahead: 1),
        RepoStatus(name: "macroslip", url: URL(filePath: "/var/empty/macroslip"), branch: "main", ahead: 2, behind: 1),
        RepoStatus(name: "socialtools", url: URL(filePath: "/var/empty/socialtools"), branch: "feature/onboarding-flow", changed: 12, ahead: 4),
        RepoStatus(name: "agents", url: URL(filePath: "/var/empty/agents"), branch: "main"),
    ]

    /// The Launcher's default picks, titled as the registry names them.
    static let picked = [Widget.Button(title: "Clean this Mac", action: "apps.clean"), Widget.Button(title: "Update apps", action: "apps.update"),
                         Widget.Button(title: "Quick notes", action: "notes.toggle"), Widget.Button(title: "Install apps", action: "apps.install")]

    /// The Launcher's tiles: its default picks, then apps every Mac has and two of Hyper+Space's menus, as WidgetLauncher
    /// draws them (an app's own icon, else the row's glyph).
    static var tiles: [WidgetLauncher.Tile] {
        picked.map { WidgetLauncher.Tile(key: "action:\($0.action)", title: $0.title, symbol: DeskKit.symbol(forAction: $0.action), icon: nil) }
            + [("com.apple.Safari", "Safari"), ("com.apple.finder", "Finder"), ("com.apple.Notes", "Notes")].map {
                WidgetLauncher.Tile(key: "app:\($0.0)", title: $0.1, symbol: MenuIcon.app.symbol, icon: AppsModule.icon(bundle: $0.0))
            }
            + [MenuBranch.system, .capture].map { WidgetLauncher.Tile(key: "branch:\($0.rawValue)", title: $0.title, symbol: $0.look.symbol, icon: nil) }
    }

    static func blocks(_ widget: Widget, note: String = "") -> [Extension.Block] {
        switch widget.data {
        case .notes: return WidgetNotes.blocks(notes, picked: note).blocks
        case .repos: return WidgetRepos.blocks(repos)
        case .none, .github, .markets: return []
        case .ci: return WidgetCI.preview()
        case .reading(let readings):
            let data: JSONValue = readings.count == 1 ? Self.readings[readings[0].rawValue]!
                : .object(Dictionary(uniqueKeysWithValues: readings.map { ($0.rawValue, Self.readings[$0.rawValue]!) }))
            return WidgetReadings.blocks(readings, data)
        default:
            // The note draws its text setting as the desk does.
            return [.markdown("Call the bank before 4.\n\n**Ship** the widgets build.")]
        }
    }

    /// A tile on a wallpaper-like ground, so glass shows what is under it.
    static func write(_ model: WidgetTileModel, size: Widget.Size, look: Look, to url: URL) throws {
        let ground = LinearGradient(colors: [Color(red: 0.12, green: 0.32, blue: 0.48), Color(red: 0.55, green: 0.32, blue: 0.42)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
        let view = WidgetTile(model: model, look: look).styled(.hud).pilotTheme(look: look)
            .frame(width: size.width, height: size.height).padding(24).background(ground)
        let shot = try rendered(view)
        try #require(shot.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test("Pilot's ready widgets on fixed readings, each style, solid and glass", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func ready() throws {
        let dir = try Self.dir()
        testApp()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        look.themeID = "lagoon"
        #expect(ReadyWidgets.inCode.map(\.id) == [ReadyWidgets.thisMac, ReadyWidgets.clock, ReadyWidgets.note, ReadyWidgets.upkeep,
                                                  ReadyWidgets.launcher, ReadyWidgets.notes, ReadyWidgets.repos, ReadyWidgets.github, ReadyWidgets.ci, ReadyWidgets.nowPlaying, ReadyWidgets.folder, ReadyWidgets.markets])
        #expect(Widget.menuPicks(ReadyWidgets.widget(ReadyWidgets.launcher)?.menuField?.initial) == Self.picked.map { "action:\($0.action)" })
        // A Launcher placed before 1.0.2 kept bare action ids: they read as their rows.
        #expect(Widget.menuPicks(.array([.string("apps.clean"), .string("app:com.apple.Safari"), .string("apps.open:x"), .string("action:apps.clean")]))
                == ["action:apps.clean", "app:com.apple.Safari"])
        for style in PilotStyle.allCases {
            look.style = style
            for glass in [false, true] {
                look.glass = glass
                // The notes widget twice: every note, and one in full.
                for (widget, note) in ReadyWidgets.inCode.map({ ($0, "") }) + [(ReadyWidgets.widget(ReadyWidgets.notes)!, Self.notes[0].id)] {
                    let model = WidgetTileModel()
                    model.title = widget.title; model.icon = widget.icon; model.blocks = Self.blocks(widget, note: note); model.buttons = widget.buttons
                    if widget.menuField != nil { model.tiles = Self.tiles }
                    if widget.data == .github { model.contributions = .init(calendar: Self.contributions) }
                    if widget.data == .nowPlaying { model.nowPlaying = Self.playing() }
                    if widget.id == ReadyWidgets.folder { model.folder = WidgetFolder.sample() }
                    if case .markets = widget.data { model.markets = Self.board(Self.marketKeys) }
                    #expect(!model.blocks.isEmpty || !model.grid.isEmpty || !model.tiles.isEmpty || model.contributions != nil || model.nowPlaying != nil || model.folder != nil || model.markets != nil, "\(widget.id) draws nothing")
                    try Self.write(model, size: widget.size, look: look,
                                   to: dir.appending(path: "\(widget.id)\(note.isEmpty ? "" : "-one")-\(style.rawValue)-\(glass ? "glass" : "solid").png"))
                }
            }
        }
    }

    /// A size in each class for the size sheets, used where a widget's own size is in another class.
    static let classSizes: [(Widget.SizeClass, Widget.Size)] = [(.strip, .init(width: 340, height: 70)), (.square, .init(width: 170, height: 170)),
                                                                 (.wide, .init(width: 380, height: 165)), (.large, .init(width: 300, height: 260))]

    /// Every native ready widget, and the Weather page when PILOT_RESOURCES bundles it, at each size class (Sven, Q727/Q729),
    /// its own size in its own class's column (today's look), one sheet a style in Lagoon, solid: `widgets/sizes-<style>.png`.
    @Test("Each native ready widget, and the Weather page, at its four size classes, one sheet a style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func sizeSheets() async throws {
        let dir = try Self.dir()
        testApp()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        look.themeID = "lagoon"; look.glass = false
        let theme = look.theme
        for (size, box) in Self.classSizes { #expect(Widget.SizeClass(width: box.width, height: box.height) == size) }
        // Held near a line, either way: a drag never flickers.
        #expect(Widget.SizeClass(width: 300, height: 180, after: .large) == .large && Widget.SizeClass(width: 300, height: 180) == .wide)
        #expect(Widget.SizeClass(width: 300, height: 170, after: .large) == .wide)
        let size = { (widget: Widget, size: Widget.SizeClass) -> Widget.Size in
            Widget.SizeClass(width: widget.size.width, height: widget.size.height) == size ? widget.size : Self.classSizes.first { $0.0 == size }!.1
        }
        // The Weather page at each class, once: a page draws the same in every style.
        var weather: [Widget.SizeClass: NSImage] = [:]
        let store = Self.env["PILOT_RESOURCES"] == nil ? nil : try DeskWidgetRenders.store()
        if let store, let widget = store.widget("desk-weather") {
            for (sizeClass, _) in Self.classSizes {
                weather[sizeClass] = try await DeskWidgetRenders.shot(widget, store: store, data: DeskWidgetRenders.fixture("desk-weather"),
                                                                      theme: DeskWidgetRenders.theme(theme), size: size(widget, sizeClass))
            }
        }
        let text = theme.dark ? Color.white : Color.black
        for style in PilotStyle.allCases {
            look.style = style
            var rows: [NSBitmapImageRep] = []
            for widget in ReadyWidgets.inCode + (store?.widget("desk-weather").map { [$0] } ?? []) {
                let own = Widget.SizeClass(width: widget.size.width, height: widget.size.height)
                let tiles: [AnyView] = Self.classSizes.map { sizeClass, _ in
                    let box = size(widget, sizeClass)
                    let model = WidgetTileModel()
                    if widget.draw == .html {
                        model.page = true
                        return AnyView(WidgetTile(model: model, look: look).overlay { weather[sizeClass].map { Image(nsImage: $0).resizable() } }
                            .frame(width: box.width, height: box.height))
                    }
                    model.title = widget.title; model.icon = widget.icon; model.blocks = Self.blocks(widget); model.buttons = widget.buttons
                    if widget.menuField != nil { model.tiles = Self.tiles }
                    if widget.data == .github { model.contributions = .init(calendar: Self.contributions) }
                    if widget.data == .nowPlaying { model.nowPlaying = Self.playing() }
                    if widget.id == ReadyWidgets.folder { model.folder = WidgetFolder.sample() }
                    if case .markets = widget.data { model.markets = Self.board(Self.marketKeys) }
                    return AnyView(WidgetTile(model: model, look: look).frame(width: box.width, height: box.height))
                }
                let row = VStack(alignment: .leading, spacing: 8) {
                    Text("\(widget.title) · \(style.title) · its own \(Int(widget.size.width))×\(Int(widget.size.height)) is \(own.title)")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(text)
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(tiles.indices, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.classSizes[i].0.title + (Self.classSizes[i].0 == own ? " (its own size)" : "")).font(.system(size: 11)).foregroundStyle(text.opacity(0.7))
                                tiles[i]
                            }
                        }
                    }
                }
                .padding(20)
                .background(LinearGradient(colors: [Self.colour(theme.wallpaper.base), Self.colour(theme.wallpaper.glow).opacity(theme.dark ? 0.55 : 0.4),
                                                    Self.colour(theme.wallpaper.base)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .styled(.hud).pilotTheme(look: look)
                rows.append(try rendered(row))
            }
            try Self.stacked(rows).write(to: dir.appending(path: "sizes-\(style.rawValue).png"))
        }
    }

    /// The desk widgets set beside the natives: the clock beside the clock, the to-do list beside the notes list.
    static let kitPages = ["desk-clock", "desk-todo"]

    /// One sheet a theme (Sven, build 4: "new widgets dont look like the others"): every native ready widget, then two
    /// HTML desk widgets on the look kit, a row for each style, solid and glass, on the theme's wallpaper colours:
    /// `widgets/kit-<theme>.png`. `PILOT_RESOURCES=Packaging` bundles the desk widgets. `widgets/kit-probe.txt` says which
    /// mono face the pages' WebKit draws, which the native tiles match.
    @Test("Native ready widgets beside the kit's HTML ones, each style, solid and glass, in Lagoon and Porcelain",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_RESOURCES"] != nil))
    func kitSheet() async throws {
        let dir = try Self.dir()
        testApp()
        let store = try DeskWidgetRenders.store()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        let natives = ReadyWidgets.inCode.map { ($0, "") } + [(try #require(ReadyWidgets.widget(ReadyWidgets.notes)), Self.notes[0].id)]
        try await Self.fontProbe(try #require(store.widget("desk-todo")), store: store)
            .write(to: dir.appending(path: "kit-probe.txt"), atomically: true, encoding: .utf8)
        for themeID in ["lagoon", "porcelain"] {
            look.themeID = themeID
            let theme = look.theme
            var pages: [String: NSImage] = [:]
            for id in Self.kitPages {
                pages[id] = try await DeskWidgetRenders.shot(try #require(store.widget(id)), store: store, data: DeskWidgetRenders.fixture(id),
                                                             theme: DeskWidgetRenders.theme(theme))
            }
            var rows: [NSBitmapImageRep] = []
            for style in PilotStyle.allCases {
                for glass in [false, true] {
                    look.style = style; look.glass = glass
                    var tiles: [AnyView] = natives.map { widget, note in
                        let model = WidgetTileModel()
                        model.title = widget.title; model.icon = widget.icon; model.blocks = Self.blocks(widget, note: note); model.buttons = widget.buttons
                        if widget.menuField != nil { model.tiles = Self.tiles }
                        if widget.data == .github { model.contributions = .init(calendar: Self.contributions) }
                        if widget.id == ReadyWidgets.folder { model.folder = WidgetFolder.sample() }
                        if case .markets = widget.data { model.markets = Self.board(Self.marketKeys) }
                        return AnyView(WidgetTile(model: model, look: look).frame(width: widget.size.width, height: widget.size.height))
                    }
                    for id in Self.kitPages {
                        let widget = try #require(store.widget(id)), shot = try #require(pages[id])
                        let model = WidgetTileModel()
                        model.page = true
                        tiles.append(AnyView(WidgetTile(model: model, look: look).overlay { Image(nsImage: shot).resizable() }
                            .frame(width: widget.size.width, height: widget.size.height)))
                    }
                    let row = VStack(alignment: .leading, spacing: 10) {
                        Text("\(theme.name) · \(style.title) · \(glass ? "Glass" : "Solid")\(rows.isEmpty ? "   (natives, then desk-clock and desk-todo in HTML)" : "")")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.dark ? Color.white : Color.black)
                        HStack(alignment: .top, spacing: 24) { ForEach(tiles.indices, id: \.self) { tiles[$0] } }
                    }
                    .padding(24)
                    .background(LinearGradient(colors: [Self.colour(theme.wallpaper.base), Self.colour(theme.wallpaper.glow).opacity(theme.dark ? 0.55 : 0.4),
                                                        Self.colour(theme.wallpaper.base)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .styled(.hud).pilotTheme(look: look)
                    rows.append(try rendered(row))
                }
            }
            try Self.stacked(rows).write(to: dir.appending(path: "kit-\(themeID).png"))
        }
    }

    static func colour(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    /// The rows one under another, as a PNG.
    static func stacked(_ rows: [NSBitmapImageRep]) throws -> Data {
        let width = rows.map(\.pixelsWide).max() ?? 0, height = rows.reduce(0) { $0 + $1.pixelsHigh }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var top = height
        for row in rows {
            top -= row.pixelsHigh
            row.draw(in: NSRect(x: 0, y: top, width: row.pixelsWide, height: row.pixelsHigh))
        }
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// Which mono face a page's WebKit has: a face it lacks measures as the serif fallback after it.
    static func fontProbe(_ widget: Widget, store: WidgetStore) async throws -> String {
        let page = try #require(WidgetWebView(widget: widget, store: store))
        defer { page.end() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        page.view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        window.contentView = page.view
        for _ in 0..<100 where page.view.isLoading || page.view.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        let read = try await page.view.callAsyncJavaScript("""
            const c = document.createElement('canvas').getContext('2d')
            const m = (f) => { c.font = '20px ' + f; return Math.round(c.measureText('iiiiWWW0').width * 10) / 10 }
            return ['Geist Mono ' + m('"Geist Mono", serif'), 'SF Mono ' + m('"SF Mono", serif'), 'ui-monospace ' + m('ui-monospace, serif'),
                    'serif ' + m('serif'), 'body: ' + getComputedStyle(document.body).fontFamily].join('\\n')
            """, contentWorld: .page) as? String
        return (read ?? "none") + "\n"
    }

    @Test("The Launcher's tiles, each style, solid and glass", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func launcher() throws {
        let dir = try Self.dir()
        testApp()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        look.themeID = "lagoon"
        let widget = try #require(ReadyWidgets.widget(ReadyWidgets.launcher))
        var rows: [NSBitmapImageRep] = []
        for style in PilotStyle.allCases {
            for glass in [false, true] {
                look.style = style; look.glass = glass
                // Its default picks alone, at its own size, and every kind of tile on a bigger one.
                let tiles = [Array(Self.tiles.prefix(4)), Self.tiles].map { tiles in
                    let model = WidgetTileModel()
                    model.title = widget.title; model.icon = widget.icon; model.tiles = tiles
                    return WidgetTile(model: model, look: look)
                        .frame(width: tiles.count > 4 ? 360 : widget.size.width, height: tiles.count > 4 ? 250 : widget.size.height)
                }
                let row = VStack(alignment: .leading, spacing: 10) {
                    Text("\(style.title) · \(glass ? "Glass" : "Solid")").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    HStack(alignment: .top, spacing: 24) { tiles[0]; tiles[1] }
                }
                .padding(24)
                .background(WidgetPreview.ground(look.theme))
                .styled(.hud).pilotTheme(look: look)
                rows.append(try rendered(row))
            }
        }
        try Self.stacked(rows).write(to: dir.appending(path: "launcher.png"))
    }

    /// A fixture cover: a sunset in two bands with a disc, drawn here, so no picture is read from disk.
    static let cover = NSImage(size: NSSize(width: 480, height: 480), flipped: false) { box in
        NSGradient(colors: [NSColor(red: 0.98, green: 0.45, blue: 0.32, alpha: 1), NSColor(red: 0.42, green: 0.16, blue: 0.45, alpha: 1)])?
            .draw(in: box, angle: -90)
        NSColor(red: 1, green: 0.85, blue: 0.55, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 140, y: 170, width: 200, height: 200)).fill()
        NSColor(red: 0.12, green: 0.08, blue: 0.22, alpha: 0.9).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 480, height: 170)).fill()
        return true
    }

    /// What plays in the renders: a track with its cover, playing a third in, or as `playing` says, or `art` none.
    static func playing(_ playing: Bool = true, art: Bool = true, title: String = "Red Room", artist: String = "Nova Lights") -> NowPlaying {
        NowPlaying(track: .init(title: title, artist: artist, album: "Night Signals", app: "Spotify", playing: playing, duration: 221, elapsed: 72,
                                at: .now, art: art ? "cover" : nil), art: art ? cover : nil)
    }

    @Test("Now playing at its four size classes, playing, paused, without a cover and with nothing playing, each style, solid and glass",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func nowPlaying() throws {
        let dir = try Self.dir()
        testApp()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        look.themeID = "lagoon"
        let widget = try #require(ReadyWidgets.widget(ReadyWidgets.nowPlaying))
        #expect(widget.data == .nowPlaying && WidgetAsks.acts(widget) && Widget.SizeClass(width: widget.size.width, height: widget.size.height) == .square)
        #expect(NowPlaying.clock(72) == "1:12" && NowPlaying.clock(3729) == "1:02:09")
        let states: [(String, () -> NowPlaying)] = [
            ("Playing", { Self.playing() }), ("Paused", { Self.playing(false) }),
            ("No cover, a long title", { Self.playing(art: false, title: "Today is my birthday, and what better way to celebrate than a theme", artist: "Erik Johansson") }),
            ("Nothing playing", { NowPlaying() }),
        ]
        for style in PilotStyle.allCases {
            look.style = style
            var rows: [NSBitmapImageRep] = []
            for glass in [false, true] {
                look.glass = glass
                for (name, state) in states where !glass || name == "Playing" {
                    let tiles = Self.classSizes.map { sizeClass, box in
                        let model = WidgetTileModel()
                        model.title = widget.title; model.icon = widget.icon; model.nowPlaying = state()
                        return VStack(alignment: .leading, spacing: 4) {
                            Text(sizeClass.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                            WidgetTile(model: model, look: look).frame(width: box.width, height: box.height)
                        }
                    }
                    let row = VStack(alignment: .leading, spacing: 8) {
                        Text("Now playing · \(style.title) · \(glass ? "Glass" : "Solid") · \(name)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        HStack(alignment: .top, spacing: 24) { ForEach(tiles.indices, id: \.self) { tiles[$0] } }
                    }
                    .padding(20)
                    .background(WidgetPreview.ground(look.theme))
                    .styled(.hud).pilotTheme(look: look)
                    rows.append(try rendered(row))
                }
            }
            try Self.stacked(rows).write(to: dir.appending(path: "now-playing-\(style.rawValue).png"))
        }
    }

    @Test("The Repos widget on fixture repos, three sizes, each style, solid and glass", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func repos() async throws {
        let dir = try Self.dir()
        testApp()
        // Fixture repos in the moved home's code/, the remote outside it, made by a git that never reads Sven's config.
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: "repos-\(UUID().uuidString)", directoryHint: .isDirectory)
        let code = home.appending(path: "code", directoryHint: .isDirectory), remote = home.appending(path: "remote.git").path
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)
        let git = try #require(["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
                                "/Applications/Xcode.app/Contents/Developer/usr/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) })
        func run(_ folder: URL, _ words: String...) throws {
            let process = Process()
            process.executableURL = URL(filePath: git)
            process.arguments = ["-C", folder.path, "-c", "user.name=Pilot", "-c", "user.email=pilot@example.invalid", "-c", "commit.gpgsign=false",
                                 "-c", "init.defaultBranch=main"] + words
            process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            try #require(process.terminationStatus == 0, "git \(words.joined(separator: " ")) in \(folder.lastPathComponent)")
        }
        func commit(_ repo: URL, _ file: String) throws {
            try Data(file.utf8).write(to: repo.appending(path: file))
            try run(repo, "add", file); try run(repo, "commit", "-q", "-m", file)
        }
        try run(home, "init", "-q", "--bare", "-b", "main", remote)
        for name in ["clean", "dirty", "ahead", "branch"] {
            try run(code, "clone", "-q", remote, name)
            let repo = code.appending(path: name)
            if name == "clean" { try run(repo, "symbolic-ref", "HEAD", "refs/heads/main"); try commit(repo, "a.txt"); try run(repo, "push", "-q", "-u", "origin", "main") }
            else { try run(repo, "pull", "-q", "origin", "main"); try run(repo, "branch", "-q", "-u", "origin/main") }
        }
        let at = { (name: String) in code.appending(path: name) }
        try Data("changed".utf8).write(to: at("dirty").appending(path: "a.txt"))
        try Data("new".utf8).write(to: at("dirty").appending(path: "b.txt"))
        try commit(at("ahead"), "b.txt"); try commit(at("ahead"), "c.txt")
        try commit(at("clean"), "d.txt"); try run(at("clean"), "push", "-q")
        try run(at("ahead"), "fetch", "-q")
        try run(at("branch"), "switch", "-q", "-c", "feature/a-long-branch-name"); try commit(at("branch"), "e.txt")
        try run(at("clean"), "pull", "-q")
        // A worktree's folder (its .git a file) is not an own repo.
        try run(at("clean"), "worktree", "add", "-q", "--detach", code.appending(path: "clean-wt").path)

        let read = await Repos.statuses(Repos.list(home: home))
        #expect(read.map(\.name) == ["ahead", "branch", "clean", "dirty"])
        let by = Dictionary(uniqueKeysWithValues: read.map { ($0.name, $0) })
        #expect(by["dirty"]?.changed == 2 && by["dirty"]?.ahead == 0 && by["dirty"]?.problem == nil)
        #expect(by["ahead"]?.changed == 0 && by["ahead"]?.ahead == 2 && by["ahead"]?.behind == 1)
        #expect(by["branch"]?.branch == "feature/a-long-branch-name" && by["branch"]?.ahead == 1)
        #expect(by["clean"]?.clean == true)
        let rows = WidgetRepos.blocks(read)
        guard case .list(_, let items, _)? = rows.first else { Issue.record("no list: \(rows)"); return }
        #expect(items.map(\.title) == ["ahead · main", "branch · feature/a-long-branch-name", "dirty · main"])
        #expect(items.map(\.subtitle) == ["2 ahead · 1 behind", "1 ahead", "2 changed"])

        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        look.themeID = "lagoon"
        let widget = try #require(ReadyWidgets.widget(ReadyWidgets.repos))
        let sizes = [Widget.Size(width: 240, height: 150), widget.size, Widget.Size(width: 340, height: 300)]
        var sheet: [NSBitmapImageRep] = []
        for style in PilotStyle.allCases {
            for glass in [false, true] {
                look.style = style; look.glass = glass
                // The fixture read and Self.repos at each size, then all clean and no repos at its own size.
                let shown: [([Extension.Block], Widget.Size)] = sizes.map { (WidgetRepos.blocks(Self.repos + read), $0) }
                    + [(WidgetRepos.blocks(read.filter(\.clean)), widget.size), (WidgetRepos.blocks([]), Widget.Size(width: 240, height: 150))]
                let tiles = shown.map { blocks, size in
                    let model = WidgetTileModel()
                    model.title = widget.title; model.icon = widget.icon; model.blocks = blocks
                    return WidgetTile(model: model, look: look).frame(width: size.width, height: size.height)
                }
                let row = VStack(alignment: .leading, spacing: 10) {
                    Text("\(style.title) · \(glass ? "Glass" : "Solid")").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    HStack(alignment: .top, spacing: 24) { ForEach(tiles.indices, id: \.self) { tiles[$0] } }
                }
                .padding(24)
                .background(WidgetPreview.ground(look.theme))
                .styled(.hud).pilotTheme(look: look)
                sheet.append(try rendered(row))
            }
        }
        try Self.stacked(sheet).write(to: dir.appending(path: "repos.png"))
    }

    /// gh's answer for a year ending Sunday 1 November 2026, as GitHub sends it: 53 Sunday-first weeks, the last one day.
    static let githubAnswer: Data = {
        let end = Date(timeIntervalSince1970: 1_793_534_400)  // 2026-11-01 12:00 UTC, a Sunday
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let names = ["NONE", "FIRST_QUARTILE", "SECOND_QUARTILE", "THIRD_QUARTILE", "FOURTH_QUARTILE"]
        var weeks: [[String: Any]] = [], total = 0
        for week in 0..<53 {
            var days: [[String: Any]] = []
            for weekday in 0..<7 {
                let back = (52 - week) * 7 - weekday
                guard back >= 0, let date = calendar.date(byAdding: .day, value: -back, to: end) else { continue }
                // Busier on weekdays and in two bursts, none on some days.
                let burst = week > 30 || (12...20).contains(week) ? 2 : 1
                let count = (week * 7 + weekday) % 5 == 0 || (weekday == 0 && week % 3 != 0) ? 0 : ((week * 31 + weekday * 17) % 6 + 1) * burst
                total += count
                let level = count == 0 ? 0 : count <= 3 ? 1 : count <= 6 ? 2 : count <= 9 ? 3 : 4
                days.append(["date": formatter.string(from: date), "contributionCount": count, "contributionLevel": names[level], "weekday": weekday])
            }
            weeks.append(["contributionDays": days])
        }
        let answer: [String: Any] = ["data": ["user": ["login": "banozz0", "contributionsCollection": ["contributionCalendar": ["totalContributions": total, "weeks": weeks]]]]]
        return try! JSONSerialization.data(withJSONObject: answer)
    }()

    static let contributions = GitHubContributions(answer: githubAnswer, read: Date())!

    @Test("The GitHub widget: gh's answer, a stand-in gh read and kept, its failures, four classes, each style, solid and glass",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func github() async throws {
        let dir = try Self.dir()
        testApp()
        let calendar = Self.contributions
        #expect(calendar.login == "banozz0" && calendar.weeks.count == 53 && calendar.weeks.last?.count == 1 && calendar.weeks.first?.count == 7)
        #expect(calendar.weeks.joined().reduce(0) { $0 + $1.count } == calendar.total && calendar.weeks.last?.last?.date == "2026-11-01")
        #expect(Set(calendar.weeks.joined().map(\.level)) == [0, 1, 2, 3, 4])
        #expect(GitHubContributions.weekLevels(calendar.weeks).allSatisfy { (0...4).contains($0) } && GitHubContributions.weekLevels([[], []]) == [0, 0])
        #expect(GitHubContributions(answer: Data("{\"data\":{\"user\":null}}".utf8), read: Date()) == nil)
        // The login rides as a variable, never in the query's text; an empty one asks for gh's own user.
        #expect(GitHubContributions.arguments(user: "banozz0").suffix(2) == ["-f", "login=banozz0"])
        #expect(!GitHubContributions.arguments(user: "banozz0").contains { $0.hasPrefix("query=") && $0.contains("banozz0") })
        #expect(GitHubContributions.arguments(user: "").contains { $0.contains("viewer{login") })
        #expect(["banozz0", "a-b", "A1"].allSatisfy(GitHubContributions.isLogin) && !["", "-a", "a-", "a--b", "a b", "a\"){x}", String(repeating: "a", count: 40)].contains { GitHubContributions.isLogin($0) })
        #expect(WidgetGitHub.user(.string("  @banozz0 ")) == "banozz0" && WidgetGitHub.user(nil) == "")
        #expect(GitHubContributions.Failure(status: 4, said: "To get started with GitHub CLI, please run:  gh auth login", user: "") == .loggedOut)
        #expect(GitHubContributions.Failure(status: 1, said: "gh: Could not resolve to a User with the login of 'nobody-x'.", user: "nobody-x") == .noUser("nobody-x"))
        #expect(GitHubContributions.Failure(status: 1, said: "error connecting to api.github.com\ncheck your internet connection", user: "") == .failed("error connecting to api.github.com"))
        // The widget declares its source, its user setting and its Layout.
        let widget = try #require(ReadyWidgets.widget(ReadyWidgets.github))
        #expect(widget.data == .github && widget.data.label == "your GitHub contributions" && widget.offersLayout)
        #expect(widget.settings.map(\.name) == [WidgetGitHub.userName] && Widget.SizeClass(width: widget.size.width, height: widget.size.height) == .large)

        // A stand-in gh in the moved home: it prints the fixture and counts its runs. A read is kept, and a second within
        // the hour runs nothing; a kept read stays beside a failure.
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: "github-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let answer = home.appending(path: "answer.json"), runs = home.appending(path: "runs")
        try Self.githubAnswer.write(to: answer)
        func gh(_ name: String, _ body: String) throws -> String {
            let url = home.appending(path: name)
            try Data("#!/bin/sh\necho run >> '\(runs.path)'\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        let good = try gh("gh-good", "[ \"$1 $2\" = 'api graphql' ] || exit 9\ncat '\(answer.path)'")
        let out = try gh("gh-out", "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2\nexit 4")
        let file = home.appending(path: "WidgetData/github-banozz0.json")
        let first = await WidgetGitHub.fetch("banozz0", file: file, gh: good)
        #expect(first.problem == nil && first.calendar?.total == calendar.total && FileManager.default.fileExists(atPath: file.path))
        let again = await WidgetGitHub.fetch("banozz0", file: file, gh: good)
        let ran = try String(contentsOf: runs, encoding: .utf8).split(separator: "\n").count
        #expect(again.calendar?.total == calendar.total && ran == 1)
        #expect(WidgetGitHub.wait(again) > .seconds(3000))
        let me = home.appending(path: "WidgetData/github-me.json")
        let loggedOut = await WidgetGitHub.fetch("", file: me, gh: out)
        #expect(loggedOut == .init(problem: .loggedOut) && WidgetGitHub.wait(loggedOut) == WidgetGitHub.retry)
        #expect(await WidgetGitHub.fetch("", file: me, gh: nil) == .init(problem: .missing))
        #expect(await WidgetGitHub.fetch("bad name", file: me, gh: good) == .init(problem: .badLogin("bad name")))
        // An hour-old kept read is read again; a failure then keeps it.
        let old = GitHubContributions(login: calendar.login, total: calendar.total, weeks: calendar.weeks, read: Date().addingTimeInterval(-4000))
        try JSONEncoder().encode(old).write(to: file)
        let stale = await WidgetGitHub.fetch("banozz0", file: file, gh: out)
        #expect(stale.calendar == old && stale.problem == .loggedOut)

        // The layouts: Large holds more weeks than Wide at their default sizes, and Square fewer than both.
        let fits = [(540.0, 190.0, true), (380, 165, false), (170, 170, false)].map { width, height, large in
            GridFit(width: width - 28, height: height - 26 - 48, weeks: 53, days: large, months: large).weeks
        }
        #expect(fits[0] > fits[1] && fits[1] > fits[2])

        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        let shownSizes: [(String, Widget.Size)] = [("Large", widget.size), ("Wide", .init(width: 380, height: 165)), ("Square", .init(width: 170, height: 170)),
                                                    ("Strip", .init(width: 340, height: 70))]
        var sheet: [NSBitmapImageRep] = []
        for themeID in ["lagoon", "porcelain"] {
            look.themeID = themeID
            for style in PilotStyle.allCases {
                for glass in [false, true] {
                    look.style = style; look.glass = glass
                    let tile = { (shown: WidgetGitHub.Shown, size: Widget.Size) -> AnyView in
                        let model = WidgetTileModel()
                        model.title = widget.title; model.icon = widget.icon; model.contributions = shown
                        return AnyView(WidgetTile(model: model, look: look).frame(width: size.width, height: size.height))
                    }
                    let fresh = shownSizes.map { tile(.init(calendar: calendar), $0.1) }
                    let failing = [tile(.init(calendar: old, problem: .loggedOut), .init(width: 380, height: 165)), tile(.init(problem: .missing), .init(width: 260, height: 160)),
                                   tile(.init(problem: .noUser("nobody-x")), .init(width: 170, height: 170)), tile(.init(problem: .loggedOut), .init(width: 340, height: 70)),
                                   tile(.init(note: "Read by gh once placed"), .init(width: 380, height: 165))]
                    let ink = look.theme.dark ? Color.white : Color.black
                    let row = VStack(alignment: .leading, spacing: 10) {
                        Text("\(look.theme.name) · \(style.title) · \(glass ? "Glass" : "Solid")   (Large, Wide, Square, Strip; then a kept read beside a failure, gh missing, no such user, logged out, the preview)")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                        HStack(alignment: .top, spacing: 24) { ForEach(fresh.indices, id: \.self) { fresh[$0] } }
                        HStack(alignment: .top, spacing: 24) { ForEach(failing.indices, id: \.self) { failing[$0] } }
                    }
                    .padding(24)
                    .background(WidgetPreview.ground(look.theme))
                    .styled(.hud).pilotTheme(look: look)
                    sheet.append(try rendered(row))
                }
            }
        }
        try Self.stacked(sheet).write(to: dir.appending(path: "github.png"))
    }

    @Test("The Folder widget on a fixture folder: its read, its watch, its four classes and its states, each style, solid and glass",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func folder() async throws {
        let dir = try Self.dir()
        testApp()
        // A fixture folder in the moved home: files a day apart, a subfolder, an app, an app Hidden apps hides, a dotfile.
        let root = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: "folder-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default, now = Date()
        func make(_ name: String, _ text: String?, daysAgo: Double, bundle: String? = nil) throws {
            let url = root.appending(path: name)
            if let text { try Data(text.utf8).write(to: url) } else {
                try files.createDirectory(at: url.appending(path: bundle == nil ? "" : "Contents"), withIntermediateDirectories: true)
                if let bundle {
                    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundle, "CFBundleName": name], format: .xml, options: 0)
                        .write(to: url.appending(path: "Contents/Info.plist"))
                }
            }
            try files.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
        }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try make("Screenshots", nil, daysAgo: 3)
        try make("notes.md", "# Notes\n", daysAgo: 1)
        try make("Ticket.pdf", String(repeating: "x", count: 315_800), daysAgo: 2)
        try make("Fake.app", nil, daysAgo: 4, bundle: "dev.example.fake")
        try make("Hidden.app", nil, daysAgo: 0.5, bundle: "dev.example.hidden")
        try make(".secret", "dot", daysAgo: 0.1)
        try make("Screenshots/shot.png", "png", daysAgo: 3)
        // Its file written moved the folder's date: set again.
        try make("Screenshots", nil, daysAgo: 3)

        let byName = try FolderListing.list(root, sort: .name, hidden: ["dev.example.hidden"])
        #expect(byName.items.map(\.name) == ["Screenshots", "Fake.app", "notes.md", "Ticket.pdf"])
        #expect(byName.count == 4 && byName.free != nil)
        #expect(byName.items.first { $0.name == "Fake.app" }?.isFolder == false && byName.items.first?.isFolder == true)
        #expect(byName.items.first { $0.name == "Ticket.pdf" }?.size == 315_800)
        let newest = try FolderListing.list(root, sort: .modified)
        #expect(newest.items.map(\.name) == ["Hidden.app", "notes.md", "Ticket.pdf", "Screenshots", "Fake.app"])
        #expect(FolderListing.shown(root) == "~/" + root.lastPathComponent && FolderListing.folder("~/" + root.lastPathComponent) == root.standardizedFileURL)

        // In and back, up, and a folder that goes away.
        let model = WidgetFolderModel(.init(folder: root.path, favourites: ["~/code", "/tmp"]))
        model.take(.success(byName))
        #expect(model.folder == root.standardizedFileURL && !model.canGoBack && model.favourites.map(\.title) == ["code", "tmp"])
        let shots = root.appending(path: "Screenshots", directoryHint: .isDirectory)
        model.go(shots)
        #expect(model.canGoBack && model.folder == shots.standardizedFileURL)
        model.back()
        #expect(model.folder == root.standardizedFileURL && !model.canGoBack)
        model.up()
        #expect(model.folder == root.deletingLastPathComponent().standardizedFileURL && model.canGoBack)
        model.back()

        // The watch: a file written wakes it once, within its second's gathering; the folder removed says it is gone.
        let gone = root.appending(path: "Gone", directoryHint: .isDirectory)
        try files.createDirectory(at: gone, withIntermediateDirectories: true)
        var heard: [Bool] = []
        let watch = try #require(FolderChanges(root) { heard.append($0) }), goneWatch = try #require(FolderChanges(gone) { heard.append($0) })
        try make("new.txt", "new", daysAgo: 0)
        try make("newer.txt", "newer", daysAgo: 0)
        try files.removeItem(at: gone)
        for _ in 0..<40 where heard.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
        watch.cancel(); goneWatch.cancel()
        #expect(heard.sorted { !$0 && $1 } == [false, true], "heard \(heard)")

        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        look.themeID = "lagoon"
        let read = try FolderListing.list(root, sort: .name, hidden: ["dev.example.hidden"])
        func tile(_ size: Widget.Size, _ setUp: (WidgetFolderModel) -> Void = { _ in }) -> AnyView {
            let folder = WidgetFolderModel(.init(folder: root.path, favourites: ["~/code"]))
            folder.take(.success(read))
            setUp(folder)
            let model = WidgetTileModel()
            model.folder = folder
            return AnyView(WidgetTile(model: model, look: look).frame(width: size.width, height: size.height))
        }
        let widget = try #require(ReadyWidgets.widget(ReadyWidgets.folder))
        #expect(Widget.SizeClass(width: widget.size.width, height: widget.size.height) == .large)
        var sheet: [NSBitmapImageRep] = []
        for style in PilotStyle.allCases {
            for glass in [false, true] {
                look.style = style; look.glass = glass
                // Its own Large, Wide, Square and Strip; then in a subfolder (back lit), sorted by date with a row picked at
                // a narrow Large, empty, and a folder macOS keeps from Pilot.
                let classes = [widget.size] + Self.classSizes.filter { $0.0 != .large }.map(\.1)
                let inside = try FolderListing.list(shots, sort: .name)
                let states: [AnyView] = [
                    tile(.init(width: 460, height: 260)) { $0.go(shots); $0.take(.success(inside)) },
                    tile(.init(width: 420, height: 260)) {
                        $0.sort(by: .modified)
                        $0.take(.success(.init(items: FolderListing.sorted(read.items, by: .modified), count: read.count, free: read.free)))
                        $0.selected = read.items[2].id
                    },
                    tile(.init(width: 300, height: 200)) { $0.take(.success(.init(items: [], count: 0, free: read.free))) },
                    tile(.init(width: 300, height: 200)) { $0.take(.failure(CocoaError(.fileReadNoPermission))) },
                ]
                let row = VStack(alignment: .leading, spacing: 10) {
                    Text("\(style.title) · \(glass ? "Glass" : "Solid")").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    HStack(alignment: .top, spacing: 24) { ForEach(classes.indices, id: \.self) { tile(classes[$0]) } }
                    HStack(alignment: .top, spacing: 24) { ForEach(states.indices, id: \.self) { states[$0] } }
                }
                .padding(24)
                .background(WidgetPreview.ground(look.theme))
                .styled(.hud).pilotTheme(look: look)
                sheet.append(try rendered(row))
            }
        }
        try Self.stacked(sheet).write(to: dir.appending(path: "folder.png"))
    }

    /// The Markets extension's answer for its default symbols and SPX, as its `widget` command printed it on 2026-11-01
    /// (trimmed), and lines shaped like the ones it read: what the widget draws, never the network.
    static let marketKeys = ["pair:BITSTAMP:BTCUSD", "pair:BITSTAMP:ETHUSD", "stock:NASDAQ:NVDA", "stock:NASDAQ:AAPL", "pair:FX:EURUSD", "pair:SP:SPX"]
    static let marketQuotes: [String: JSONValue] = {
        func quote(_ name: String, _ price: Double, _ change: Double, _ percent: Double, _ high: Double, _ low: Double, _ currency: String?,
                   _ asset: String, _ type: String, month: (Double, Double, Double)) -> JSONValue {
            .object(["name": .string(name), "price": .number(price), "change": .number(change), "percent": .number(percent),
                     "high": .number(high), "low": .number(low), "currency": currency.map(JSONValue.string) ?? .null,
                     "asset": .string(asset), "type": .string(type),
                     "ranges": .object(["1M": .object(["percent": .number(month.0), "high": .number(month.1), "low": .number(month.2)])])])
        }
        return ["pair:BITSTAMP:BTCUSD": quote("Bitcoin / U.S. dollar", 77907.05, 482.3, 0.62, 78501.0, 76880.0, "USD", "coin", "spot", month: (-8.18, 86968.58, 76172.75)),
                "pair:BITSTAMP:ETHUSD": quote("Ethereum / U.S. dollar", 3402.18, -21.2, -0.62, 3460.0, 3381.5, "USD", "coin", "spot", month: (-4.1, 3790.0, 3320.0)),
                "stock:NASDAQ:NVDA": quote("NVIDIA Corporation", 142.36, 3.93, 2.84, 143.1, 138.2, "USD", "stocks", "stock", month: (6.2, 145.0, 128.4)),
                "stock:NASDAQ:AAPL": quote("Apple Inc.", 344.63, -4.29, -1.23, 349.19, 334.35, "USD", "stocks", "stock", month: (4.18, 351.73, 325.81)),
                "pair:FX:EURUSD": quote("Euro / U.S. Dollar", 1.11574, -0.0022, -0.2, 1.1189, 1.115, "USD", "forex", "forex", month: (-1.52, 1.12853, 1.11043)),
                "pair:SP:SPX": quote("S&P 500 Index", 7580.07, -140.4, -1.82, 7700.0, 7560.0, nil, "index", "index", month: (-1.42, 7844.52, 7527.56))]
    }()

    /// A walk from `start` to `end` in `count` steps, the same every run.
    static func walk(_ start: Double, _ end: Double, count: Int = 96, seed: UInt64) -> [Double] {
        var state = seed, value = start
        return (0..<count).map { i in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Double(state >> 33) / Double(1 << 31) - 0.5) * abs(end - start) * 0.35
            value += (end - value) / Double(count - i) + noise
            return i == count - 1 ? end : value
        }
    }

    /// A board for `keys` over `range` on the fixture answer, every symbol's line drawn but SPX's longer ranges (no free
    /// history), as WidgetMarkets.fill leaves it.
    static func board(_ keys: [String], range: WidgetMarkets.Range = .day) -> MarketsBoard {
        let board = MarketsBoard(symbols: keys.compactMap(WidgetMarkets.Symbol.init), range: range)
        board.loaded = Set(keys)
        for (i, key) in keys.enumerated() {
            guard let quote = marketQuotes[key].flatMap(WidgetMarkets.quote) else { continue }
            board.quotes[key] = quote
            let start = range == .day ? quote.previous ?? quote.price : quote.price / (1 + (quote.spans[range]?.percent ?? 0) / 100)
            if range == .day || key != "pair:SP:SPX" { board.lines[key] = walk(start, quote.price, seed: UInt64(i + 7)) }
        }
        return board
    }

    @Test("The Markets widget: one symbol and several at the four size classes, each style; no extension says so",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func markets() async throws {
        let dir = try Self.dir()
        testApp()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        look.themeID = "lagoon"
        let widget = try #require(ReadyWidgets.widget(ReadyWidgets.markets))
        #expect(widget.data == .markets("symbols") && WidgetAsks.acts(widget))
        #expect(WidgetMarkets.symbols(widget.settings.first { $0.name == WidgetMarkets.symbolsName }?.initial).count == 5)
        #expect(WidgetMarkets.symbols(.string("pair:FX:EURUSD, stock:NASDAQ:AAPL pair:FX:EURUSD bad stock:")).map(\.key) == ["pair:FX:EURUSD", "stock:NASDAQ:AAPL"])
        // A folder's widget may not run the Markets extension.
        #expect(throws: Widget.Problems.self) {
            try Widget(manifest: Data(#"{"id": "my-markets", "title": "M", "data": {"markets": "s"}, "settings": [{"name": "s", "type": "text"}]}"#.utf8),
                       folder: URL(filePath: "/var/empty/my-markets"))
        }
        // A click on a symbol opens its TradingView page.
        #expect(WidgetMarkets.symbols(.array(["pair:BITSTAMP:BTCUSD", "stock:NASDAQ:NVDA", "pair:FX:EURUSD", "pair:SP:SPX", "pair:CME_MINI:ES1!", "stock:NYSE:BRK.B", "pair:X:A/B"].map(JSONValue.string)))
            .compactMap(\.page?.absoluteString) == ["https://www.tradingview.com/symbols/BITSTAMP-BTCUSD/", "https://www.tradingview.com/symbols/NASDAQ-NVDA/",
                "https://www.tradingview.com/symbols/FX-EURUSD/", "https://www.tradingview.com/symbols/SP-SPX/", "https://www.tradingview.com/symbols/CME_MINI-ES1!/",
                "https://www.tradingview.com/symbols/NYSE-BRK.B/", "https://www.tradingview.com/symbols/X-A%2FB/"])
        let quote = try #require(Self.marketQuotes["stock:NASDAQ:AAPL"].flatMap(WidgetMarkets.quote))
        #expect(quote.moved(.month).percent == 4.18 && quote.moved(.day).high == 349.19 && quote.previous == 344.63 + 4.29)
        // No Markets extension in the moved home: the tile says what to install, and nothing ran.
        let missing = MarketsBoard(symbols: WidgetMarkets.symbols(.array([.string("pair:FX:EURUSD")])), range: .day)
        await WidgetMarkets.draw(missing)
        #expect(missing.message?.hasPrefix("Install Markets") == true, "\(missing.message ?? "nothing")")
        let one = ["stock:NASDAQ:AAPL"]
        let boards: [(String, MarketsBoard)] = [("One symbol, 1D", Self.board(one)), ("One symbol, 1M", Self.board(["pair:BITSTAMP:BTCUSD"], range: .month)),
                                                ("One symbol, 1M, no free history", Self.board(["pair:SP:SPX"], range: .month)),
                                                ("Several", Self.board(Self.marketKeys)), ("No extension", missing)]
        for style in PilotStyle.allCases {
            look.style = style
            var rows: [NSBitmapImageRep] = []
            for (title, board) in boards {
                let tiles = Self.classSizes.map { sizeClass, box in
                    let model = WidgetTileModel()
                    model.title = widget.title; model.markets = board
                    return VStack(alignment: .leading, spacing: 4) {
                        Text(sizeClass.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                        WidgetTile(model: model, look: look).frame(width: box.width, height: box.height)
                    }
                }
                let row = VStack(alignment: .leading, spacing: 8) {
                    Text("\(title) · \(style.title)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    HStack(alignment: .top, spacing: 24) { ForEach(tiles.indices, id: \.self) { tiles[$0] } }
                }
                .padding(20)
                .background(WidgetPreview.ground(look.theme))
                .styled(.hud).pilotTheme(look: look)
                rows.append(try rendered(row))
            }
            try Self.stacked(rows).write(to: dir.appending(path: "markets-\(style.rawValue).png"))
        }
    }

    @Test("Edit widget: the Launcher's tiles, the notes widget's note, a desktop placement's workspace", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func edit() throws {
        let dir = try Self.dir()
        testApp()
        let look = Look.shared
        let saved = look.themeID
        defer { look.themeID = saved }
        look.themeID = "lagoon"
        // What a button may run, as the live picker lists it from the registry: refused shapes never reach it.
        let picks = [("apps.clean", "Clean this Mac"), ("apps.update", "Update apps"), ("apps.install", "Install apps"), ("notes.toggle", "Quick notes"),
                     ("captures.area", "Capture area")].map { WidgetEditChoices.Pick(id: $0.0, title: $0.1, group: $0.0.split(separator: ".")[0].capitalized) }
        #expect(picks.allSatisfy { Widget.isActionID($0.id) })
        let notes = WidgetNotes.choices(Self.notes)
        // What the Launcher may pick, as Hyper+Space lists its rows.
        let rows = Self.tiles.map { WidgetEditChoices.Pick(id: $0.key, title: $0.title, group: $0.key.hasPrefix("app:") ? "Apps" : $0.key.hasPrefix("branch:") ? "Menus" : "Actions") }
            + [WidgetEditChoices.Pick(id: "action:captures.area", title: "Capture area", group: "Trigger")]
        let choices = WidgetEditChoices(notes: { notes }, actions: { picks }, menu: { rows })
        let cases: [(String, String, Widget.Placement)] = [
            (ReadyWidgets.launcher, "launcher", Widget.Placement(widget: ReadyWidgets.launcher, screen: nil, x: 0.1, y: 0.1, width: 300, height: 170)),
            (ReadyWidgets.notes, "notes", Widget.Placement(widget: ReadyWidgets.notes, screen: nil, x: 0, y: 0, width: 280, height: 260, home: true)),
            (ReadyWidgets.thisMac, "this-mac", Widget.Placement(widget: ReadyWidgets.thisMac, screen: nil, x: 0, y: 0, width: 260, height: 230, workspace: "3")),
            (ReadyWidgets.markets, "markets", Widget.Placement(widget: ReadyWidgets.markets, screen: nil, x: 0, y: 0, width: 300, height: 240)),
        ]
        for (id, name, placement) in cases {
            let widget = try #require(ReadyWidgets.widget(id))
            var values = (try Self.store()).values(of: widget, placement: placement)
            if id == ReadyWidgets.notes { values["note"] = .string(Self.notes[1].id) }
            let sheet = WidgetEditSheet(widget: widget, placement: placement, values: values, workspaces: ["1", "2", "3", "4"], choices: choices,
                                        notes: notes, save: { _, _, _ in }, cancel: {})
                .pilotTheme(look: look).background(Theme.background)
            try #require(rendered(sheet).representation(using: .png, properties: [:])).write(to: dir.appending(path: "edit-\(name).png"))
        }
    }

    @Test("A locked HTML widget shows its Trust to run card and makes no page view", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func lockedPage() throws {
        let dir = try Self.dir()
        testApp()
        let store = try Self.store()
        let widget = try Self.make(store, "weather-page", """
            {"id": "weather-page", "title": "Weather page", "icon": "🌦️", "draw": "html",
             "data": {"command": ["./feed.sh", "--city", "Valletta"], "every": 600}, "hosts": ["api.open-meteo.com"]}
            """, files: ["index.html": "<p>weather</p>", "feed.sh": "#!/bin/sh\necho '{}'\n"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: widget.folder.appending(path: "feed.sh").path)
        #expect(store.trust(of: widget) == .locked)
        let made = WidgetWebView.made
        #expect(WidgetWebView(widget: widget, store: store) == nil)
        #expect(WidgetWebView.made == made, "a locked widget made a page view")
        let model = WidgetTileModel()
        model.title = widget.title; model.icon = widget.icon; model.locked = widget
        #expect(model.takesClicks)
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        look.themeID = "lagoon"; look.glass = true
        for style in PilotStyle.allCases {
            look.style = style
            try Self.write(model, size: .init(width: 300, height: 220), look: look, to: dir.appending(path: "locked-card-\(style.rawValue).png"))
        }
        try "page views made for the locked widget: \(WidgetWebView.made - made)\n".write(to: dir.appending(path: "locked-page.txt"), atomically: true, encoding: .utf8)
    }

    @Test("A made-here page: its scheme serves only its own plain files, and its main frame stays put", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func pageProbe() async throws {
        let dir = try Self.dir()
        testApp()
        let store = try Self.store()
        let html = """
            <!doctype html><body style="background: transparent"><p id="got">none</p>
            <script>addEventListener('pilotdata', e => { window.got = e.detail; document.getElementById('got').textContent = JSON.stringify(e.detail) })</script>
            """
        let widget = try Self.make(store, "probe", #"{"id": "probe", "title": "Probe", "draw": "html"}"#,
                                   files: ["index.html": html, "sub/inner.txt": "inner", "__pilot/data": "FROM-THE-FOLDER"])
        // A file beside the Widgets folder, and a link to it from inside the widget's folder.
        try Data("SECRET-OUTSIDE".utf8).write(to: store.widgets.deletingLastPathComponent().appending(path: "secret.txt"))
        try FileManager.default.createSymbolicLink(atPath: widget.folder.appending(path: "link.txt").path, withDestinationPath: "../../secret.txt")
        try store.setTrust(.madeHere, for: widget)
        _ = try Self.make(store, "other", #"{"id": "other", "title": "Other", "draw": "html"}"#, files: ["index.html": "other"])
        try store.setTrust(.madeHere, for: try #require(store.widget("other")))

        var lines: [String] = []
        let handler = WidgetSchemeHandler(widget: try #require(store.widget("probe")), store: store)
        handler.latest = .object(["from": .string("pilot")])
        let asks = ["pilot-widget://probe/", "pilot-widget://probe/index.html", "pilot-widget://probe/sub/inner.txt",
                    "pilot-widget://probe/__pilot/data", "pilot-widget://probe/__pilot/other", "pilot-widget://probe/missing.txt",
                    "pilot-widget://probe/%2e%2e/%2e%2e/secret.txt", "pilot-widget://probe/sub/%2e%2e/index.html", "pilot-widget://probe/..%2f..%2fsecret.txt",
                    "pilot-widget://probe/link.txt", "pilot-widget://other/index.html", "https://probe/index.html"]
        let want = [200, 200, 200, 200, 404, 404, 403, 403, 403, 403, 403, 403]
        for (ask, status) in zip(asks, want) {
            let (got, body, _) = handler.answer(URL(string: ask)!)
            lines.append("\(got) \(ask)\(got == 200 ? " (\(body.count) bytes)" : "")")
            #expect(got == status, "\(ask)")
            #expect(!String(decoding: body, as: UTF8.self).contains("SECRET"), "\(ask) served the outside file")
        }
        #expect(handler.answer(URL(string: "pilot-widget://probe/__pilot/data")!).1 == Data(#"{"from":"pilot"}"#.utf8))
        try store.setTrust(.locked, for: widget)
        let locked = handler.answer(URL(string: "pilot-widget://probe/index.html")!).0
        lines.append("\(locked) pilot-widget://probe/index.html once the widget is locked")
        #expect(locked == 403)
        try store.setTrust(.madeHere, for: widget)

        // The page itself, offscreen: it loads, hears its data, cannot leave, and opens no window.
        let page = try #require(WidgetWebView(widget: widget, store: store))
        defer { page.end() }
        for _ in 0..<100 where page.view.isLoading || page.view.url == nil { try await Task.sleep(for: .milliseconds(100)) }
        lines.append("page loaded: \(page.view.url?.absoluteString ?? "none"); see-through: \(page.seeThrough)")
        page.send(.object(["hello": .string("world")]))
        try await Task.sleep(for: .milliseconds(300))
        let heard = try await page.view.callAsyncJavaScript("return window.got ? window.got.hello : null", contentWorld: .page) as? String
        lines.append("pilotdata heard: \(heard ?? "nothing")")
        #expect(heard == "world")
        for path in ["__pilot/data", "%2e%2e/%2e%2e/secret.txt", "link.txt", "sub/inner.txt"] {
            let status = try await page.view.callAsyncJavaScript("try { return (await fetch(u)).status } catch (e) { return -1 }",
                                                                arguments: ["u": "pilot-widget://probe/\(path)"], contentWorld: .page)
            lines.append("page fetch /\(path): \(status.map { "\($0)" } ?? "nil")")
        }
        let opened = try await page.view.callAsyncJavaScript("return window.open('https://example.com/') === null", contentWorld: .page) as? Bool
        lines.append("window.open gave no window: \(opened == true)")
        #expect(opened == true)
        _ = try await page.view.callAsyncJavaScript("location.href = 'https://example.com/'; return 1", contentWorld: .page)
        try await Task.sleep(for: .milliseconds(800))
        lines.append("main frame after leaving for example.com: \(page.view.url?.absoluteString ?? "none")")
        #expect(page.view.url?.scheme == WidgetWebView.scheme)
        try lines.joined(separator: "\n").appending("\n").write(to: dir.appending(path: "page-probe.txt"), atomically: true, encoding: .utf8)
    }
}
}
#endif
