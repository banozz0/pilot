#if DEBUG
import AppKit
import Foundation
import Metal
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot
import QuartzCore

/// The shelf renders' windows and sheets: mock windows drawn at Sven's 1x as ScreenCaptureKit would hand them over (their
/// own size, corners clear), and the sheets the columns are laid on.
enum ShelfRenderKit {
    nonisolated static let vars = ProcessInfo.processInfo.environment

    /// The render folder's `shelf` directory, in a moved home only.
    @MainActor static func dir() throws -> URL {
        let home = try #require(vars["CFFIXED_USER_HOME"])
        try #require((NSHomeDirectory() as NSString).resolvingSymlinksInPath == (home as NSString).resolvingSymlinksInPath,
                     "the home directory did not move; refusing to draw on Sven's data")
        let dir = URL(fileURLWithPath: try #require(vars["PILOT_RENDER_DIR"])).appendingPathComponent("shelf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The wallpaper under the shelf: PILOT_SHELF_WALLPAPER's bottom-left (Sven's flow field), else a dark wash.
    static let wallpaper: NSImage? = vars["PILOT_SHELF_WALLPAPER"].flatMap { NSImage(contentsOfFile: $0) }

    enum Kind: CaseIterable { case chrome, github, docs, pilot, notes, finder, ghostex }

    /// The shelf's sample windows: id, app, bundle, title, size in points.
    static let windows: [(id: Int, kind: Kind, app: String, bundle: String, title: String, size: CGSize)] = [
        (11, .pilot, "Pilot", "dev.banozz.pilot", "Settings", CGSize(width: 1480, height: 940)),
        (21, .docs, "Google Chrome", "com.google.Chrome", "Docs", CGSize(width: 1700, height: 1060)),
        (22, .github, "Google Chrome", "com.google.Chrome", "GitHub", CGSize(width: 1700, height: 1060)),
        (23, .chrome, "Google Chrome", "com.google.Chrome", "Pilot 1.0.2 test build", CGSize(width: 1700, height: 1060)),
        (31, .notes, "Notes", "com.apple.Notes", "Shelf ideas", CGSize(width: 1100, height: 760)),
        (41, .finder, "Finder", "com.apple.finder", "Downloads", CGSize(width: 1200, height: 760)),
        (42, .ghostex, "Ghostex", "com.mitchellh.ghostty", "pilot", CGSize(width: 1500, height: 960)),
    ]

    static func aero(_ id: Int, minimized: Bool = false, group: Int? = nil) -> AeroWindow {
        let w = windows.first { $0.id == id }!
        var window = AeroWindow(id: id, appName: w.app, bundleId: w.bundle, pid: Int32(id), workspace: id >= 41 ? "1" : "4",
                                monitorId: 1, layout: minimized ? "macos_native_minimized" : "h_stage", title: w.title)
        window.shelved = minimized ? nil : true
        window.group = group
        return window
    }

    /// Workspace 4's shelf: Pilot alone, Chrome's three windows joined, Notes minimized; workspace 1 folded below.
    static let screen = ShelfScreen(monitorName: "CU34G4Z", displayUUID: "render", workspace: "4",
                                    items: [ShelfItem(windows: [aero(11)]), ShelfItem(windows: [aero(21, group: 21), aero(22, group: 21), aero(23, group: 21)]),
                                            ShelfItem(windows: [aero(31, minimized: true)])],
                                    others: [ShelfWorkspace(name: "1", windows: [aero(42), aero(41)])], staged: [99])

    /// Each window drawn once at 1x, its corners clear, as ScreenCaptureKit hands one over without its shadow.
    @MainActor static let sources: [Int: CGImage] = {
        var out: [Int: CGImage] = [:]
        for w in windows {
            let view = MockWindow(kind: w.kind, title: w.title).frame(width: w.size.width, height: w.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let image = snapshot(drawing: view, scale: 1)?.cgImage { out[w.id] = image }
        }
        return out
    }()

    /// `image` scaled to `width` pixels in one pass with bilinear filtering: how a GPU scaler shrinks a frame, the stand-in
    /// for ScreenCaptureKit's own scaling (which a test cannot run).
    static func onePass(_ image: CGImage, width: Int) -> CGImage {
        let height = max(1, Int((CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)).rounded()))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// The sheet: each rendered column side by side, a caption strip over each.
    @MainActor static func sheet(_ columns: [(caption: String, rep: NSBitmapImageRep)], scale: Int) -> NSBitmapImageRep {
        let gap = 8 * scale, head = 22 * scale
        let width = columns.map(\.rep.pixelsWide).reduce(0, +) + gap * (columns.count + 1)
        let height = (columns.map(\.rep.pixelsHigh).max() ?? 0) + head + gap
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var x = gap
        for column in columns {
            column.rep.draw(in: NSRect(x: x, y: 0, width: column.rep.pixelsWide, height: column.rep.pixelsHigh))
            (column.caption as NSString).draw(at: NSPoint(x: x + 2 * scale, y: column.rep.pixelsHigh + 5 * scale),
                                              withAttributes: [.font: NSFont.systemFont(ofSize: CGFloat(12 * scale), weight: .medium),
                                                               .foregroundColor: NSColor.white])
            x += column.rep.pixelsWide + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// `view` drawn by ImageRenderer at `scale`: it keeps the cards' 3D turn, which cacheDisplay flattens (every turned
    /// layer lands at the origin).
    @MainActor static func draw(_ view: some View, scale: CGFloat) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    /// Waits until each window in `ids` has a picture, two seconds at most.
    @MainActor static func settle(_ pictures: ShelfPictures, _ ids: [Int]) async throws {
        for _ in 0..<100 where ids.contains(where: { pictures.image(of: $0) == nil }) { try await Task.sleep(for: .milliseconds(20)) }
        try #require(ids.allSatisfy { pictures.image(of: $0) != nil }, "the stills never arrived")
    }

    static func write(_ rep: NSBitmapImageRep, _ url: URL) throws {
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

/// A plausible window: a title bar, a sidebar or tabs, text and a picture, so a shrunk copy shows what scaling does to
/// lines and type.
struct MockWindow: View {
    let kind: ShelfRenderKit.Kind
    let title: String

    private var dark: Bool { kind == .pilot || kind == .ghostex || kind == .github }
    private var ground: Color { dark ? Color(red: 0.07, green: 0.09, blue: 0.12) : Color(white: 0.98) }
    private var ink: Color { dark ? Color(white: 0.88) : Color(white: 0.12) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 13, height: 13) }
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(ink.opacity(0.8)).padding(.leading, 16)
                Spacer()
            }
            .padding(.horizontal, 18).frame(height: 52).background(dark ? Color(white: 0.13) : Color(white: 0.93))
            HStack(spacing: 0) {
                if kind != .ghostex && kind != .chrome && kind != .docs {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<14, id: \.self) { i in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 4).fill(i == 2 ? Color.blue : ink.opacity(0.35)).frame(width: 18, height: 18)
                                Text(["Home", "Binds", "Workspaces", "Tiling", "Shelf", "Menu bar", "Clipboard", "Captures", "Notes", "Widgets", "Look", "AI", "General", "About"][i])
                                    .font(.system(size: 15)).foregroundStyle(ink.opacity(0.85))
                            }
                        }
                        Spacer()
                    }
                    .padding(22).frame(width: 260).frame(maxHeight: .infinity, alignment: .top)
                    .background(dark ? Color(white: 0.1) : Color(white: 0.95))
                }
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(ground)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .ghostex:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<34, id: \.self) { i in
                    Text(i % 5 == 0 ? "~/code/pilot ❯ swift test --filter ShelfRenders" : "[\(700 + i * 3)/773] Compiling Pilot ShelfView.swift ShelfPictures.swift")
                        .font(.system(size: 15, design: .monospaced)).foregroundStyle(i % 5 == 0 ? Color.green : ink.opacity(0.8))
                }
            }.padding(24)
        case .chrome, .docs, .github:
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Capsule().fill(ink.opacity(0.1)).frame(height: 34)
                        .overlay(alignment: .leading) { Text("127.0.0.1:8742/pilot-1.0.2-test").font(.system(size: 14)).foregroundStyle(ink.opacity(0.6)).padding(.leading, 18) }
                }
                if kind != .github {
                    LinearGradient(colors: [.purple, .pink, .orange], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 620, height: 150).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text(kind == .github ? "banozz0 / pilot" : "Pilot 1.0.2 test build").font(.system(size: 40, weight: .bold)).foregroundStyle(ink)
                ForEach(0..<11, id: \.self) { i in
                    Text("Widgets, the shelf and the clipboard: hold Hyper and press Space, pick a card on the shelf and it flies to the stage. \(i + 1).")
                        .font(.system(size: 17)).foregroundStyle(ink.opacity(0.75))
                }
            }.padding(32)
        case .notes:
            VStack(alignment: .leading, spacing: 14) {
                Text("Shelf ideas").font(.system(size: 30, weight: .bold)).foregroundStyle(ink)
                ForEach(0..<12, id: \.self) { i in
                    Text("• Cards turn 10°, fly to the stage, the old window flies back \(i + 1)").font(.system(size: 17)).foregroundStyle(ink.opacity(0.8))
                }
            }.padding(30).background(Color(red: 1, green: 0.97, blue: 0.86))
        case .finder:
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(130)), count: 6), spacing: 26) {
                ForEach(0..<18, id: \.self) { i in
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 8).fill([Color.blue, .teal, .orange, .indigo][i % 4].opacity(0.75)).frame(width: 72, height: 60)
                        Text("Pilot-\(i).dmg").font(.system(size: 13)).foregroundStyle(ink.opacity(0.8))
                    }
                }
            }.padding(30)
        case .pilot:
            VStack(alignment: .leading, spacing: 18) {
                Text("Shelf").font(.system(size: 30, weight: .bold)).foregroundStyle(ink)
                ForEach(0..<8, id: \.self) { i in
                    HStack {
                        Text(["Window pictures", "Show minimized", "Turn", "Fly", "Other workspaces", "Width", "Icons", "Labels"][i]).font(.system(size: 16)).foregroundStyle(ink)
                        Spacer()
                        Capsule().fill(i % 2 == 0 ? Color.cyan : ink.opacity(0.25)).frame(width: 44, height: 24)
                    }
                    .padding(16).background(ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(30)
        }
    }
}

/// The Window shelf's Deck (Q704, Q705, Q708), opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=<fresh> PILOT_RENDER_DIR=<fresh> [PILOT_SHELF_WALLPAPER=<png>] swift test --filter ShelfRenders`
/// - The shelf column (ShelfColumn) at 1x, Sven's screens, and 2x, in Instrument on Lagoon (Solid and Glass) and
///   Porcelain, and Toybox on Toybox Night and Toybox; then every theme in both styles at 1x. ImageRenderer draws them:
///   cacheDisplay flattens the cards' 3D turn.
/// - The stills: the same window as the code before this change asked for it (one scaling pass to 204 px, a bilinear
///   stand-in for ScreenCaptureKit's) beside ShelfStill's, magnified, with the pipeline's time and each still's bytes.
/// - The Fly on a 1440 × 900 mock desktop: ShelfFly's own layers rendered by CARenderer at 30 frames a second, a contact
///   sheet and, with ffmpeg on PATH, an MP4.
extension SharedLook {
@MainActor
@Suite("Shelf renders")
struct ShelfRenders {
    /// ScreenCaptureKit as the shelf asks it: the window scaled once to ShelfStill.captureWidth (the stand-in), then
    /// ShelfStill's own pass; or, `today`, one pass straight to the width asked, as before this change.
    struct MockCapture: ShelfCapturing {
        let sources: [Int: CGImage]
        func allowed() -> Bool { true }
        func stills(_ ids: [Int], width: Int) async -> (images: [Int: ShelfStill], refused: Bool) {
            var out: [Int: ShelfStill] = [:]
            for id in ids {
                guard let source = sources[id] else { continue }
                let captured = ShelfRenderKit.onePass(source, width: ShelfStill.captureWidth(width, window: source.width))
                out[id] = ShelfStill(capture: captured, width: width)
            }
            return (out, false)
        }
        @MainActor func live(_ id: Int, width: Int, frame: @escaping @MainActor (CGImage) -> Void,
                             ended: @escaping @MainActor () -> Void) async -> ShelfLiveStart { .failed }
    }

    nonisolated static let enabled = ShelfRenderKit.vars["PILOT_RENDER_DIR"] != nil && ShelfRenderKit.vars["CFFIXED_USER_HOME"] != nil
    static let ids = [11, 21, 22, 23, 41, 42]

    /// A shelf column over the wallpaper's bottom-left, `height` points tall, centred as the panel centres it.
    struct Column: View {
        let pictures: ShelfPictures
        var height: CGFloat = 900
        var face: (Int, CGRect, Bool) -> Void = { _, _, _ in }
        var body: some View {
            ShelfColumn(shown: ShelfRenderKit.screen, pictures: pictures, face: face)
                .padding(.leading, 14)
                .frame(width: CGFloat(PilotBlock.shelfWidth), height: height, alignment: .leading)
                .background {
                    if let w = ShelfRenderKit.wallpaper {
                        Image(nsImage: w).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: CGFloat(PilotBlock.shelfWidth), height: height, alignment: .bottomLeading).clipped()
                    } else { Color(white: 0.06) }
                }
                .styled(.hud)
                .pilotTheme()
        }
    }

    static func pictures() async throws -> ShelfPictures {
        let defaults = UserDefaults(suiteName: "pilot.renders.shelf.\(UUID().uuidString)")!
        let pictures = ShelfPictures(defaults: defaults, capture: MockCapture(sources: ShelfRenderKit.sources))
        pictures.follow([ShelfRenderKit.screen])
        try await ShelfRenderKit.settle(pictures, ids)
        return pictures
    }

    @Test("The Deck in both styles, Solid and Glass, at 1x and 2x, and every theme", .enabled(if: enabled))
    func deck() async throws {
        let dir = try ShelfRenderKit.dir()
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let pictures = try await Self.pictures()
        print("SHELF-STILL width=\(pictures.image(of: 23)!.width) corner=\(pictures.corner(of: 23))")
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        defer { (look.style, look.themeID, look.glass) = saved }
        let looks: [(String, PilotStyle, String, Bool)] = [
            ("Instrument · Lagoon", .instrument, "lagoon", false), ("Instrument · Lagoon · Glass", .instrument, "lagoon", true),
            ("Instrument · Porcelain", .instrument, "porcelain", false), ("Toybox · Night", .toybox, "toybox-night", false),
            ("Toybox · light", .toybox, "toybox", false),
        ]
        for scale in [1, 2] {
            var columns: [(caption: String, rep: NSBitmapImageRep)] = []
            for (caption, style, theme, glass) in looks {
                (look.style, look.themeID, look.glass) = (style, theme, glass)
                columns.append((caption, try ShelfRenderKit.draw(Column(pictures: pictures), scale: CGFloat(scale))))
            }
            try ShelfRenderKit.write(ShelfRenderKit.sheet(columns, scale: scale), dir.appendingPathComponent("after-\(scale)x.png"))
        }
        look.glass = false
        var themes: [(caption: String, rep: NSBitmapImageRep)] = []
        for style in PilotStyle.allCases {
            for theme in PilotTheme.designed {
                (look.style, look.themeID) = (style, theme.id)
                themes.append(("\(style == .toybox ? "T" : "I") · \(theme.name)", try ShelfRenderKit.draw(Column(pictures: pictures, height: 760), scale: 1)))
            }
        }
        try ShelfRenderKit.write(ShelfRenderKit.sheet(themes, scale: 1), dir.appendingPathComponent("themes-1x.png"))
    }

    @Test("The stills: today's one pass against ShelfStill's, their cost", .enabled(if: enabled))
    func stills() throws {
        let dir = try ShelfRenderKit.dir()
        testApp()
        let source = try #require(ShelfRenderKit.sources[23])
        let today = ShelfRenderKit.onePass(source, width: 204)
        let width = ShelfPictures.width(scale: 1)
        let captured = ShelfRenderKit.onePass(source, width: ShelfStill.captureWidth(width, window: source.width))
        var times: [Double] = []
        var made: ShelfStill?
        for _ in 0..<12 {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            made = ShelfStill(capture: captured, width: width)
            times.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6)
        }
        let still = try #require(made)
        let retina = ShelfPictures.width(scale: 2)
        print("SHELF-COST source=\(source.width)x\(source.height) capture=\(captured.width)x\(captured.height) still=\(still.image.width)x\(still.image.height)"
              + " shrink-ms median=\(times.sorted()[times.count / 2]) corner=\(still.corner) (\(still.corner * CGFloat(source.width)) px)"
              + " stillKB 1x old=\(204 * today.height * 4 / 1024) new=\(still.image.width * still.image.height * 4 / 1024)"
              + " 2x old=\(408 * 408 * today.height / 204 * 4 / 1024) new=\(retina * retina * still.image.height / still.image.width * 4 / 1024)"
              + " captureKB 1x=\(captured.width * captured.height * 4 / 1024) 2x=\(ShelfStill.captureWidth(retina, window: 3400) * ShelfStill.captureWidth(retina, window: 3400) * source.height / source.width * 4 / 1024)")
        // The top-left of each, both at the card's 204 pt on a 1x screen, magnified four times without smoothing.
        func crop(_ image: CGImage) -> NSBitmapImageRep {
            let card = 204.0, zoom = 4.0, w = 110.0, h = 70.0
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * zoom), pixelsHigh: Int(h * zoom), bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.current = context
            // First to the card's size at 1x (high quality, as the compositor's minification), then up without smoothing.
            let small = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            small.interpolationQuality = .high
            let height = card * Double(image.height) / Double(image.width)
            small.draw(image, in: CGRect(x: 0, y: h - height, width: card, height: height))
            context.cgContext.interpolationQuality = .none
            context.cgContext.draw(small.makeImage()!, in: CGRect(x: 0, y: 0, width: w * zoom, height: h * zoom))
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        try ShelfRenderKit.write(ShelfRenderKit.sheet([("Before: one pass to 204 px", crop(today)), ("After: ShelfStill, \(width) px", crop(still.image))], scale: 1),
                                 dir.appendingPathComponent("stills-zoom.png"))
    }

    /// Waits for what CARenderer queued on `queue`: an empty buffer after it, waited for.
    static func drain(_ queue: any MTLCommandQueue) {
        guard let done = queue.makeCommandBuffer() else { return }
        done.commit()
        done.waitUntilCompleted()
    }

    @Test("The Fly: ShelfFly's layers through CARenderer, a frame every 1/30 s", .enabled(if: enabled))
    func fly() async throws {
        let dir = try ShelfRenderKit.dir().appendingPathComponent("fly")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let pictures = try await Self.pictures()
        let look = Look.shared
        let saved = (look.style, look.themeID)
        defer { (look.style, look.themeID) = saved }
        (look.style, look.themeID) = (.instrument, "lagoon")
        let size = CGSize(width: 1440, height: 900)
        // The shelf as drawn, and where its Chrome card's front window sits (its face, top-left coordinates).
        var faces: [Int: CGRect] = [:]
        let column = Column(pictures: pictures, face: { id, frame, _ in faces[id] = frame })
        _ = try ShelfRenderKit.draw(column, scale: 1)
        let shelf = try #require(try ShelfRenderKit.draw(column, scale: 2).cgImage)
        let card = try #require(faces[21], "the card never said where it is")
        let cardOnScreen = CGRect(x: card.minX, y: size.height - card.maxY, width: card.width, height: card.height)
        let stage = CGRect(x: 232 + 16, y: 16, width: size.width - 232 - 32, height: size.height - 32)
        let staged = try #require(ShelfRenderKit.sources[11]), incoming = try #require(pictures.still(of: 23))
        let leaving = try #require(ShelfStill(capture: ShelfRenderKit.onePass(staged, width: 1020), width: ShelfPictures.width(scale: 1)))
        let style = ShelfFlyLook(StyleTokens.of(.instrument, theme: look.theme))

        // The desktop: wallpaper, the shelf, the stage's window until the swap (0.1 s), then the new one under the flight.
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = NSColor(white: 0.05, alpha: 1).cgColor
        if let wall = ShelfRenderKit.wallpaper?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let w = CALayer()
            w.frame = root.bounds
            w.contents = wall
            w.contentsGravity = .resizeAspectFill
            root.addSublayer(w)
        }
        let strip = CALayer()
        strip.frame = CGRect(x: 0, y: 0, width: 232, height: 900)
        strip.contents = shelf
        strip.contentsGravity = .resize
        root.addSublayer(strip)
        let base = CACurrentMediaTime() + 1
        func window(_ image: CGImage, visible: (from: Double, to: Double)) {
            let layer = CALayer()
            layer.frame = stage
            layer.contents = image
            layer.contentsGravity = .resizeAspectFill
            layer.cornerRadius = 16
            layer.masksToBounds = true
            layer.opacity = 0
            let shown = CAKeyframeAnimation(keyPath: "opacity")
            shown.values = [0, 1, 1, 0]
            shown.keyTimes = [0, NSNumber(value: visible.from / 2), NSNumber(value: visible.to / 2), NSNumber(value: min(1, visible.to / 2 + 0.001))]
            shown.calculationMode = .discrete
            shown.duration = 2
            shown.beginTime = base
            shown.fillMode = .both
            shown.isRemovedOnCompletion = false
            layer.add(shown, forKey: "shown")
            root.addSublayer(layer)
        }
        window(staged, visible: (0, 0.1))
        window(try #require(ShelfRenderKit.sources[23]), visible: (0.15, 2))
        // The Fly's own layers: the card at once, the stage's window once its still is in (0.08 s).
        for leg in [ShelfLeg(still: incoming, from: cardOnScreen, to: stage, turnFrom: ShelfGroup<EmptyView>.turn, turnTo: 0),
                    ShelfLeg(still: leaving, from: stage, to: cardOnScreen, turnFrom: 0, turnTo: ShelfGroup<EmptyView>.turn, delay: 0.08)] {
            root.addSublayer(ShelfFly.layer(leg, origin: .zero, look: style, begin: base + leg.delay, reduceMotion: false))
        }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue as String: queue])
        renderer.layer = root
        renderer.bounds = root.bounds
        // CARenderer draws the committed tree: the layers made in this turn's implicit transaction, committed now.
        CATransaction.flush()
        var frames: [NSBitmapImageRep] = []
        let count = 22
        for i in 0..<count {
            renderer.beginFrame(atTime: base + Double(i) / 30, timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            Self.drain(queue)
            var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
            texture.getBytes(&bytes, bytesPerRow: Int(size.width) * 4, from: MTLRegionMake2D(0, 0, Int(size.width), Int(size.height)), mipmapLevel: 0)
            // CARenderer draws y-up into the texture, whose first row is the top: copied out, then turned the right way up.
            let image = try bytes.withUnsafeMutableBytes { raw in
                let context = try #require(CGContext(data: raw.baseAddress, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                                     bytesPerRow: Int(size.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
                let raw = try #require(context.makeImage())
                let upright = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                                     space: CGColorSpaceCreateDeviceRGB(),
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
                upright.translateBy(x: 0, y: size.height)
                upright.scaleBy(x: 1, y: -1)
                upright.draw(raw, in: CGRect(origin: .zero, size: size))
                return try #require(upright.makeImage())
            }
            let rep = NSBitmapImageRep(cgImage: image)
            try ShelfRenderKit.write(rep, dir.appendingPathComponent(String(format: "frame-%02d.png", i)))
            frames.append(rep)
        }
        // A contact sheet of six moments, each at a third.
        let picks = [0, 3, 6, 9, 12, 16]
        let thumbs = picks.map { i -> (caption: String, rep: NSBitmapImageRep) in
            let full = frames[i], w = 480, h = 300
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            full.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            return (String(format: "%.0f ms", Double(i) / 30 * 1000), rep)
        }
        try ShelfRenderKit.write(ShelfRenderKit.sheet(thumbs, scale: 1), dir.appendingPathComponent("../fly-sheet.png"))
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") {
            let ffmpeg = Process()
            ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            ffmpeg.arguments = ["-loglevel", "error", "-y", "-framerate", "30", "-i", dir.appendingPathComponent("frame-%02d.png").path,
                                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-vf", "scale=1440:-2", dir.appendingPathComponent("../fly.mp4").path]
            try ffmpeg.run()
            ffmpeg.waitUntilExit()
            print("SHELF-FLY mp4 exit=\(ffmpeg.terminationStatus)")
        }
        print("SHELF-FLY card=\(cardOnScreen) stage=\(stage) frames=\(count)")
    }
}
}
#endif
