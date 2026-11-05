#if DEBUG
import AppKit
import Foundation
import ImageIO
import ImageScale
@testable import PilotCore
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Pilot

/// The "What's new in 1.1" clip's Pilot frames (T62, Sven 2026-11-05, Q854, Q864, Q868): its four beats in the film's
/// look, Instrument in `ExplainerFilmRenders.theme`, from the 1.1 suites' own builders. Look › Cursor per set and on Custom,
/// each set's arrow, the three trails, the Ring, Ripple and Spotlight; Pilot Files with folder sizes, a picture grid, a new
/// file, a cut and paste, the path bar, a Trash and its undo, each state on Glass and on Solid (offscreen glass draws no
/// material: the film lays its blur under the Glass copy); folder designs by kind for Downloads, Pictures and Projects; the
/// launcher typing `tr hello`, `bw generate password`, `em funny` and `gif cat`. Made-up files, copies and windows, never
/// this Mac's; GIPHY's previews are the pictures in PILOT_FILM_GIFS (else tinted squares) and Pictures holds
/// PILOT_FILM_PICTURES; nothing reaches the network. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> PILOT_RESOURCES=Packaging swift test --filter WhatsNewFilmRenders`
extension SharedLook {
@MainActor
@Suite("What's new film renders")
struct WhatsNewFilmRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// The folder `name` under whats-new, with the film's look on the shared Look; refuses Sven's own home.
    static func prepare(_ name: String) throws -> URL {
        let home = try #require(env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        (look.style, look.themeID, look.glass) = (.instrument, ExplainerFilmRenders.theme, false)
        let dir = URL(fileURLWithPath: try #require(env["PILOT_RENDER_DIR"])).appendingPathComponent("whats-new/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func png(_ image: CGImage, to url: URL) throws {
        try #require(ImageFormat.png.encode(image)).write(to: url)
    }

    // MARK: Cursors

    /// Comet's trail, frame by frame at 30 a second, along a sweep across a 1200 by 500 point area (top left origin),
    /// with the pointer's place per frame in `trail.json` so the film draws the set's arrow on it.
    static let trailArea = CGSize(width: 1200, height: 500)
    /// Custom's fill, the trail's colour too: the clip's own colours beat.
    static let lime: UInt32 = 0xC6F432
    static func trailPoint(_ k: Double) -> CGPoint {
        let e = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2  // a hand's ease in and out
        return CGPoint(x: 120 + 960 * e, y: 330 - 170 * sin(e * .pi) + 40 * sin(e * 3 * .pi))
    }

    @Test("Cursors: Look › Cursor on each set and on Custom; each set's arrow; the three trails, the Ring, Ripple and Spotlight",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func cursors() throws {
        let dir = try Self.prepare("cursors")
        let width = LookRenders.page(1200)
        let pages: [(String, CursorSetID, CursorColours)] = [("quiet", .quiet, .theme), ("toybox", .toybox, .own), ("duo", .duo, .theme),
                                                              ("classic", .classic, .own), ("custom", .classic, .custom)]
        for (name, set, colours) in pages {
            let (look, _) = try LookRenders.setUp()
            look.themeID = ExplainerFilmRenders.theme
            let cursors = CursorSets.of(look), effects = CursorEffects.of(look)
            cursors.set = set  // a render's store never applies (`mayApply`)
            cursors.colours = colours
            effects.colour = .theme
            if colours == .custom {
                (cursors.fill, cursors.outline) = (.custom(Self.lime), .custom(0x101114))
                (effects.trail, effects.colour) = (.comet, .custom(Self.lime))
            }
            try LookRenders.shot(look, to: dir.appending(path: "look-\(name).png"), width: width, height: 2300)
            LookRenders.resetShared()
            Look.shared.themeID = ExplainerFilmRenders.theme
        }
        // Each set's arrow at 2x, the first frame, in the colours its page shows; its hotspot beside it.
        let catalogue = try #require(CursorCatalogue.load(CursorRenders.packaging))
        var hotspots: [String: [Double]] = [:]
        for (name, set, colours) in pages {
            let art = try #require(catalogue.sets[set.rawValue]), arrow = try #require(art.cursors["arrow"])
            let custom = CursorCustom(set: set, fill: .custom(Self.lime), outline: .custom(0x101114))
            let palette = art.palette(colours, theme: ExplainerFilmRenders.theme, custom: custom)
            let sheet = try #require(CursorArt.sheet(CursorRenders.packaging.appending(path: "\(set.rawValue)@2x.png")))
            let px = catalogue.canvasPoints * 2
            let strip = try #require(CursorCatalogue.strip(sheet, cursor: arrow, palette: palette, px: px))
            try Self.png(try #require(strip.cropping(to: CGRect(x: 0, y: 0, width: px, height: px))), to: dir.appending(path: "arrow-\(name).png"))
            hotspots[name] = arrow.hotspot
        }
        // The effects in Custom's lime, frame by frame at 30 a second on a transparent area (top left origin), each with the
        // pointer's place per frame in effects.json: the three trails on one sweep, the Ring following a short move with a
        // click's squeeze, a left and a right click's ripples, and Spotlight dimming the screen round the pointer.
        let colours = CursorEffectColours.of(ExplainerFilmRenders.theme, colour: .custom(Self.lime))
        func frame(_ name: String, _ size: CGSize, _ draw: (CGContext) -> Void) throws {
            let ctx = try #require(CGContext(data: nil, width: Int(size.width) * 2, height: Int(size.height) * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.scaleBy(x: 2, y: 2)
            ctx.translateBy(x: 0, y: size.height)  // the area's top left is the origin, as the film places it
            ctx.scaleBy(x: 1, y: -1)
            draw(ctx)
            try Self.png(try #require(ctx.makeImage()), to: dir.appending(path: "\(name).png"))
        }
        var meta: [String: Any] = ["area": [Self.trailArea.width, Self.trailArea.height], "fps": 30, "hotspots": hotspots]
        let sweep = 1.0, frames = 36
        for trail in [CursorTrail.thread, .comet, .dots] {
            var state = CursorEffectState()
            (state.trail, state.pointer, state.lastMove) = (trail, Self.trailPoint(0), 0)
            var fed = 0.0, places: [[Double]] = []
            for f in 0..<frames {
                let now = Double(f) / 30
                while fed + 0.005 <= min(now, sweep) {  // an event every 5 ms while the pointer moves
                    fed += 0.005
                    state.move(to: Self.trailPoint(fed / sweep), at: fed)
                }
                let at = Self.trailPoint(min(now, sweep) / sweep)
                places.append([Double(at.x), Double(at.y)])
                state.prune(now)
                try frame(String(format: "trail-%@-%02d", trail.rawValue, f), Self.trailArea) {
                    CursorEffectPainter.draw(state, colours, now: max(now, 0.001), ring: false, in: $0)
                }
            }
            meta["trail-\(trail.rawValue)"] = places
        }
        // The Ring: a short arc in 0.8 s, a click at 0.9 s that squeezes it, 1.3 s in all.
        var ring = CursorEffectState()
        ring.ring = true
        func arc(_ k: Double) -> CGPoint { CGPoint(x: 420 + 360 * k, y: 300 - 120 * sin(k * .pi)) }
        ring.pointer = arc(0)
        var ringPlaces: [[Double]] = []
        var fed = 0.0
        for f in 0..<39 {
            let now = Double(f) / 30
            while fed + 0.01 <= min(now, 0.8) { fed += 0.01; ring.move(to: arc(fed / 0.8), at: fed) }
            if f == 27 { ring.click(at: ring.pointer, right: false, at: now) }
            ring.prune(now)
            ringPlaces.append([Double(ring.pointer.x), Double(ring.pointer.y)])
            let state = ring
            try frame(String(format: "ring-%02d", f), Self.trailArea) { CursorEffectPainter.draw(state, colours, now: max(now, 0.001), in: $0) }
        }
        meta["ring"] = ringPlaces
        // Ripple: a left click at 0.1 s, a right click at 0.6 s a little further on, 1.2 s in all.
        var ripple = CursorEffectState()
        ripple.ripple = true
        let clicks = [(0.1, CGPoint(x: 520, y: 260), false), (0.6, CGPoint(x: 700, y: 260), true)]
        var ripplePlaces: [[Double]] = []
        ripple.pointer = clicks[0].1
        for f in 0..<36 {
            let now = Double(f) / 30
            for (t, p, right) in clicks where t <= now && t > now - 1.0 / 30 { ripple.click(at: p, right: right, at: t) }
            if now > 0.35 && now < 0.6 { ripple.pointer = CGPoint(x: 520 + 180 * (now - 0.35) / 0.25, y: 260) }
            ripple.prune(now)
            ripplePlaces.append([Double(ripple.pointer.x), Double(ripple.pointer.y)])
            let state = ripple
            try frame(String(format: "ripple-%02d", f), Self.trailArea) { CursorEffectPainter.draw(state, colours, now: max(now, 0.001), in: $0) }
        }
        meta["ripple"] = ripplePlaces
        // Spotlight: the whole 1920 by 1080 screen dims round the pointer, eased in over 0.3 s, then held.
        let screen = CGSize(width: 1920, height: 1080), lit = CGPoint(x: 1240, y: 560)
        for f in 0..<12 {
            let k = min(1, Double(f) / 9), level = CGFloat(k * k * (3 - 2 * k))
            try frame(String(format: "spot-%02d", f), screen) {
                CursorEffectPainter.spotlight(at: lit, level: level, screen: CGRect(origin: .zero, size: screen), in: $0)
            }
        }
        meta["spot"] = [Double(lit.x), Double(lit.y)]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appending(path: "effects.json"))
    }

    // MARK: Pilot Files

    @Test("Pilot Files on glass: folder sizes, a picture grid with real thumbnails, Cmd+K, a new file, Cmd+X then Cmd+V, the path bar, a Trash and its undo",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func files() async throws {
        let dir = try Self.prepare("files")
        let home = NSHomeDirectory()
        let projects = try FilesWindowRenders.fixture(home + "/Projects", [
            ("pilot", nil, 2), ("site", nil, 6), ("film", nil, 20), ("invoice-oct-2026.pdf", 182_000, 30), ("launch-notes.md", 4_800, 1),
            ("cover.png", -1, 50), ("budget.numbers", 96_000, 70)])
        for (folder, bytes) in [("pilot", 3_400_000), ("site", 1_150_000), ("film", 6_200_000)] {
            try Data(count: bytes).write(to: projects.appending(path: "\(folder)/data.bin"))
        }
        // The notes and the invoice hold words, so their previews show a page, not a blank one.
        let notes = projects.appending(path: "launch-notes.md")
        try "# Launch notes\n\n- Record the 1.1 clip\n- Write the post\n- Ship on Tuesday, morning in Europe\n\nAnswer every comment the first day.\n"
            .write(to: notes, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: notes.path)
        let invoice = projects.appending(path: "invoice-oct-2026.pdf")
        var page = CGRect(x: 0, y: 0, width: 420, height: 594)
        let pdf = try #require(CGContext(invoice as CFURL, mediaBox: &page, nil))
        pdf.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
        let ink: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black]
        NSAttributedString(string: "Invoice", attributes: [.font: NSFont.boldSystemFont(ofSize: 28)]).draw(at: CGPoint(x: 40, y: 520))
        for (i, line) in ["Northwind Studio · October 2026", "", "Design review, 6 hours      €540.00", "Pilot film, 1.1 clip      €320.00",
                          "", "Total      €860.00"].enumerated() {
            NSAttributedString(string: line, attributes: ink).draw(at: CGPoint(x: 40, y: 470 - Double(i) * 22))
        }
        NSGraphicsContext.restoreGraphicsState()
        pdf.endPDFPage()
        pdf.closePDF()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 3600)], ofItemAtPath: invoice.path)
        // Pictures of the film's own (PILOT_FILM_PICTURES: its wallpapers and the GIF beat's cats), else the fixture's.
        let pictures = try FilesWindowRenders.fixture(home + "/Pictures", [])
        if let folder = Self.env["PILOT_FILM_PICTURES"] {
            for (i, name) in try FileManager.default.contentsOfDirectory(atPath: folder).sorted().enumerated() where !name.hasPrefix(".") {
                let to = pictures.appending(path: name)
                try FileManager.default.copyItem(at: URL(filePath: folder).appending(path: name), to: to)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(i + 1) * 3600)], ofItemAtPath: to.path)
            }
        }
        // A throwaway Trash in the moved home (FilesWindowRenders.powerFeatures' own) and a clipboard of the test's own.
        let bin = URL(filePath: home + "/.t62-trash", directoryHint: .isDirectory)
        let ops = FileOps(trash: { url in
            let into = bin.appending(path: String(UUID().uuidString.prefix(8)), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
            let went = into.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: went)
            return went
        }, trashFolder: { _ in bin.appending(path: "XXXXXXXX", directoryHint: .isDirectory) })
        let cut = FilesCut.shared
        let board = NSPasteboard(name: .init("dev.banozz.pilot.test.T62.\(UUID().uuidString)"))
        cut.board = board
        defer { cut.clear(); cut.board = .general; board.releaseGlobally() }
        // FilesWindowRenders.model's fixed sidebar and devices, with QuickLook's real thumbnails and NSWorkspace's real icons.
        func model(_ folder: URL) -> FilesModel {
            let fixed = FilesWindowRenders.model(folder, home: home)
            fixed.close()
            let tb: Int64 = 1_000_000_000_000
            let devices = [FilesModel.Device(name: "Macintosh HD", symbol: "internaldrive", url: URL(filePath: "/"), free: 1_400 * tb / 1000, total: 2 * tb),
                           FilesModel.Device(name: "T7 Shield", symbol: "externaldrive", url: URL(filePath: "/Volumes/T7 Shield"), free: 612 * tb / 1000, total: 2 * tb)]
            let sources = FilesModel.Sources(hidden: { [] }, favourites: { ["file:" + home + "/Projects", "file:" + home + "/Pictures"] }, devices: { devices },
                                             search: { _, reply in reply([]) }, make: FileThumbnails.quickLook)
            let m = FilesModel(folder: folder, home: home, sources: sources)
            m.start()
            return m
        }
        // Each state on glass: Pilot Files' own material is drawn by the window server, so the film lays its blur under the
        // render (offscreen glass draws none); the solid copy beside it is the same state on Solid.
        let look = Look.shared
        func shoot(_ m: FilesModel, _ name: String) async throws {
            for glass in [true, false] {
                look.glass = glass
                try await Self.render(m, glass ? "\(name)-glass" : name, in: dir)
            }
            look.glass = false
        }
        let list = model(projects)
        list.ops = ops
        try await FilesWindowRenders.settle(list)
        try await FilesWindowRenders.until { !list.sizingFolders && list.folderSizes.count == 3 }
        list.sort = .size
        list.selected = projects.appending(path: "invoice-oct-2026.pdf").path
        try await shoot(list, "f1-sizes")
        let grid = model(pictures)
        grid.mode = .grid
        try await FilesWindowRenders.settle(grid)
        grid.selected = grid.items.first?.id
        try await Task.sleep(for: .seconds(1.5))  // QuickLook's thumbnails arrive after the first pass
        try await shoot(grid, "g1-grid")
        grid.close()
        list.newFile(FileTemplate.builtIn[1])
        try await FilesWindowRenders.idle(list)
        #expect(list.renaming == projects.appending(path: "untitled.md").path)
        try await shoot(list, "f2-new-file")
        list.renaming = nil
        // Cmd+X on the notes, then Cmd+V in film moves them; Cmd+Z puts them back.
        list.selected = projects.appending(path: "launch-notes.md").path
        list.cut()
        #expect(cut.paths == [projects.appending(path: "launch-notes.md").path])
        try await shoot(list, "x1-cut")
        list.go(projects.appending(path: "film", directoryHint: .isDirectory))
        try await FilesWindowRenders.until { list.loaded && list.folder.lastPathComponent == "film" }
        list.paste(moving: false)
        try await FilesWindowRenders.idle(list)
        #expect(FileManager.default.fileExists(atPath: projects.appending(path: "film/launch-notes.md").path))
        try await shoot(list, "x2-pasted")
        list.undo()
        try await FilesWindowRenders.idle(list)
        #expect(FileManager.default.fileExists(atPath: projects.appending(path: "launch-notes.md").path), "Cmd+Z puts the cut file back")
        list.dismissNotice()
        list.go(projects)
        try await FilesWindowRenders.until { list.loaded && list.folder.path == projects.path && !list.sizingFolders }
        // Cmd+L: the path bar as a field, its path typed from ~.
        list.editingPath = true
        try await shoot(list, "p1-path")
        list.editingPath = false
        let cover = try #require(list.items.first { $0.name == "cover.png" })
        list.selected = cover.id
        list.trash(cover)
        try await FilesWindowRenders.idle(list)
        #expect(!FileManager.default.fileExists(atPath: projects.appending(path: "cover.png").path))
        try await shoot(list, "f3-trashed")
        list.undo()
        try await FilesWindowRenders.idle(list)
        #expect(FileManager.default.fileExists(atPath: projects.appending(path: "cover.png").path), "Cmd+Z puts it back")
        try await shoot(list, "f4-undone")
        list.close()
        // Cmd+K on a file: its actions, the list Hyper + right-click gives, as Line draws the picker.
        var actions = MenuNavigator(list: FileActionsMenu.rows(FileAction.list(for: [.pdf])), title: "invoice-oct-2026.pdf")
        try await LineMenuRenders.render(ExplainerFilmRenders.line(actions), "k0", in: dir, wait: 0.4)
        for step in 1...3 {
            _ = actions.handle(.down)
            try await LineMenuRenders.render(ExplainerFilmRenders.line(actions), "k\(step)", in: dir, wait: 0.3)
        }
    }

    /// FilesWindowRenders.render without closing the model, so one state is shot on glass and on Solid and the next state
    /// carries on from it (a closed model drops its folder sizes).
    static func render(_ model: FilesModel, _ name: String, in dir: URL) async throws {
        let host = NSHostingView(rootView: FilesView(model: model).styled(.window).pilotTheme())
        host.frame.size = FilesWindows.size
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(800))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(snapshot(host, scale: 2))
        try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }

    // MARK: Folder designs

    @Test("Folder designs by kind: Downloads', Pictures' and Projects' pickers, each kind's designs first, and the first one's art",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_RESOURCES"] != nil))
    func folders() async throws {
        let dir = try Self.prepare("folders")
        for name in ["Downloads", "Pictures", "Projects"] {
            let folder = URL(filePath: NSHomeDirectory()).appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let nav = MenuNavigator(list: FolderDesignSource([folder], inGit: []).rows(), title: "1 folder")
            try await LineMenuRenders.render(ExplainerFilmRenders.line(nav), "pick-\(name.lowercased())", in: dir, wait: 0.6)
            // The first suggested design, as the folder wears it, at 512 px on no ground.
            guard case .action(let action) = try #require(nav.rows.first).target else { Issue.record("no design row"); continue }
            let id = String(action.dropFirst("folders.design:".count))
            let rep = try FolderDesignsRenders.strip([(try #require(FolderDesigns.art(id)), 512)], ground: .clear, gap: 0)
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("art-\(name.lowercased()).png"))
        }
    }

    // MARK: Launcher

    /// GIPHY's previews for `gif cat`: the pictures in PILOT_FILM_GIFS (cat-0.png …), one frame each, else tinted squares.
    static func cats() throws -> [(WebGIF, Data)] {
        let titles = ["Cat Typing GIF", "Yawning Kitten GIF by Pets", "Peeking Cat GIF"]
        return try titles.enumerated().map { i, title in
            let gif = WebGIF(id: "t62-cat-\(i)", title: title, preview: URL(string: "https://media.giphy.com/media/t62-\(i)/giphy-preview.gif")!,
                             full: URL(string: "https://media.giphy.com/media/t62-\(i)/giphy-downsized.gif")!)
            guard let folder = env["PILOT_FILM_GIFS"],
                  let source = CGImageSourceCreateWithURL(URL(filePath: folder).appending(path: "cat-\(i).png") as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return (gif, try GiphyRenders.gif(CGFloat(i) * 0.3)) }
            let data = NSMutableData()
            let dest = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            try #require(CGImageDestinationFinalize(dest))
            return (gif, data as Data)
        }
    }

    @Test("The launcher's alias words, typed key by key: tr hello, bw generate password, em funny, gif cat",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func launcher() async throws {
        let root = try Self.prepare("launcher")
        let built = try LineMenuRenders.built()
        let windows = try AeroWindow.parse(ExplainerFilmRenders.windows(["1", "1"]))
        let day = Date(timeIntervalSince1970: 1_791_028_800)
        func menu(_ nav: MenuNavigator) -> MenuModel {
            var nav = nav
            if nav.branch == nil { nav.provide(.window, MenuEntries.windows(windows, excluding: nil)) }
            let m = MenuModel(nav: nav)
            m.layout = .line
            m.windows = windows
            m.ownKey = "Hyper+Space"
            return m
        }
        func typed(_ name: String, _ query: String, _ model: (String) throws -> MenuModel) async throws {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let chars = Array(query)
            for i in 0...chars.count {
                try await LineMenuRenders.render(try model(String(chars[..<i])), String(format: "k%02d", i), in: dir, wait: 0.3)
            }
        }
        // tr and words: the translation alone, first (T40), as LineMenuRenders' L30 gives it once the words are typed.
        try await typed("tr", "tr hello") { q in
            var nav = MenuNavigator(entries: built + MenuEntries.quicklinks(Quicklink.shipped))
            nav.query = q
            nav.provide(.answer, RootAnswers.entries(for: q, now: day, links: Quicklink.shipped))
            if q == "tr hello" {
                nav.provide(.answer, home: .translate, [MenuEntry(title: "hola", target: .copy("hola"), home: .translate,
                                                                  detail: "English → Spanish · Return copies", isAnswer: true)])
            }
            return menu(nav)
        }
        // An app's alias and words: that app's actions alone, its menu bar read once (L31).
        func node(_ menu: String, _ items: [String]) -> MenuItemNode {
            MenuItemNode(title: menu, enabled: true, children: items.map { MenuItemNode(title: $0, enabled: true) })
        }
        let aliased = Aliases(Alias.starters + [Alias(key: "app:com.bitwarden.desktop", alias: "bw", title: "Bitwarden")])
        let bar = [node("File", ["New item", "New folder"]), node("View", ["Search vault", "Password generator", "Generate password"]),
                   node("Account", ["Lock all vaults"])]
        try await typed("bw", "bw generate password") { q in
            var nav = MenuNavigator(entries: built, aliases: aliased)
            nav.query = q
            nav.provide(.menuItem, MenuItemSearch.entries(bar, bundle: "com.bitwarden.desktop", app: "Bitwarden"))
            return menu(nav)
        }
        // em and words: the emoji it finds, best first (T37), as MenuPanel provides them.
        let emoji = try EmojiSearch.parse(Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/emoji.json")))
        try await typed("em", "em funny") { q in
            var nav = MenuNavigator(entries: built, aliases: Aliases(Alias.starters))
            nav.query = q
            nav.provide(.emoji, EmojiSearch.entries(for: nav.emojiWords ?? q, in: emoji))
            return menu(nav)
        }
        // gif and words open Stickers and GIFs searching them (T39): the root typed to "gif ", then the branch typing "cat".
        let cats = try Self.cats()
        AppsModule.keepWebThumbnails(Dictionary(uniqueKeysWithValues: cats.map { ($0.0.id, $0.1) }))
        try await typed("gif", "gif ") { q in
            var nav = MenuNavigator(entries: built, aliases: Aliases(Alias.starters))
            nav.query = q
            return menu(nav)
        }
        let branch = root.appendingPathComponent("gif-branch")
        try FileManager.default.createDirectory(at: branch, withIntermediateDirectories: true)
        for (i, q) in ["c", "ca", "cat"].enumerated() {
            var nav = MenuNavigator(entries: built, aliases: Aliases(Alias.starters))
            nav.go(to: MenuNavigator.Spot(branch: .stickers, query: q, rooted: .stickers))
            nav.provide(.file, home: .stickers, [Stickers.folderRow])
            nav.provide(.sticker, home: .stickers, q == "cat" ? Giphy.entries(cats.map(\.0), query: q) : [])
            let m = menu(nav)
            m.giphyKind = .gifs
            try await LineMenuRenders.render(m, String(format: "k%02d", i + 1), in: branch, wait: 0.6)
        }
    }
}
}
#endif
