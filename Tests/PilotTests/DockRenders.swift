#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Pilot's dock, look A (design round 2, Sven 2026-11-13, Q207): the pill at the foot of a 3440-wide ultrawide and a
/// 1512-wide laptop screen, with sixteen apps and with forty (shrunk to 32 pt, then scrolling), hovered (magnified), on
/// Glass and on Solid, on Dracula and Porcelain. Native glass draws nothing offscreen (Memory/Mac
/// liquid-glass-no-offscreen-check), so a Glass pill stands on a stand-in: what is under it blurred, in the bar's glass
/// tint; Solid draws the app's own ground. Opt-in, in a moved home; PILOT_DOCK_WALL=<png> puts a wallpaper behind it:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter DockRenders`
@MainActor
@Suite("Dock renders")
struct DockRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    nonisolated static let ultrawide = CGSize(width: 3440, height: 1440), laptop = CGSize(width: 1512, height: 982)

    static func path(_ name: String) -> String {
        ["/Applications/\(name).app", "/System/Applications/\(name).app", "/System/Applications/Utilities/\(name).app",
         "/System/Library/CoreServices/\(name).app"].first { FileManager.default.fileExists(atPath: $0) } ?? "/System/Library/CoreServices/Finder.app"
    }

    static func app(_ name: String, windows: Int = 0, running: Bool = false, pinned: Bool = true, front: Bool = false) -> DockApp {
        DockApp(bundleID: name.lowercased(), url: URL(filePath: path(name)).resolvingSymlinksInPath(), name: name, pinned: pinned,
                pid: running || windows > 0 ? 1 : nil, windows: windows, front: front)
    }

    static let names = ["Finder", "Mail", "System Settings", "Safari", "Notes", "Calendar", "Music", "Photos", "Maps", "Messages",
                        "Preview", "Terminal", "Reminders", "Books", "News", "Podcasts", "TV", "Weather", "Clock", "Calculator",
                        "Freeform", "Shortcuts", "Contacts", "FaceTime", "Home", "Stocks", "Tips", "Font Book", "Chess", "Stickies",
                        "TextEdit", "Image Capture", "Screenshot", "Passwords", "Journal", "Games", "Phone", "Voice Memos", "Mission Control", "Automator"]

    /// Sixteen apps, Music in front, a few running; forty for the crowded dock.
    static func apps(_ count: Int) -> [DockApp] {
        names.prefix(count).enumerated().map { i, name in
            app(name, windows: i % 3 == 0 ? 1 + i % 2 : 0, running: i == 4, pinned: i < count - 2, front: name == "Music")
        }
    }

    /// The six widgets on by default (round 3), as DockWidgetRenders maps them.
    static var widgets: [(DockWidget, DockWidgetBody)] { DockWidgetRenders.bodies().filter { DockWidget.defaults.contains($0.0) } }

    @Test("The dock on two screens: fitted, crowded, hovered, Glass and Solid", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try ClockRenders.dir("dock")
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let wall = Self.env["PILOT_DOCK_WALL"].flatMap(NSImage.init(contentsOfFile:))
        let look = Look.shared
        let was = (look.style, look.themeID, look.glass, look.transparency)
        defer { (look.style, look.themeID, look.glass, look.transparency) = was }
        (look.style, look.transparency) = (.instrument, 33)

        for theme in ["dracula", "porcelain"] {
            look.themeID = theme
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            let tint = Color(nsColor: TopBarColour.tint(.theme, style: tokens, look: look))
            // Round 4: the dock's own Style, the top bar's three (Sven on build 2467), each over the wallpaper.
            let cases: [(String, CGSize, Int, Int?, TopBarBackground)] = theme == "dracula"
                ? [("ultrawide", Self.ultrawide, 16, nil, .glass), ("ultrawide-hover", Self.ultrawide, 16, 6, .glass), ("ultrawide-solid", Self.ultrawide, 16, nil, .solid),
                   ("ultrawide-clear", Self.ultrawide, 16, nil, .clear), ("laptop", Self.laptop, 16, nil, .glass), ("laptop-solid", Self.laptop, 16, nil, .solid),
                   ("laptop-clear", Self.laptop, 16, nil, .clear), ("laptop-forty", Self.laptop, 40, nil, .glass)]
                : [("ultrawide", Self.ultrawide, 16, nil, .glass), ("ultrawide-solid", Self.ultrawide, 16, nil, .solid), ("ultrawide-clear", Self.ultrawide, 16, nil, .clear)]
            for (name, screen, count, hover, style) in cases {
                let desk = Desk(wall: wall, screen: screen, size: CGSize(width: min(screen.width, 1640), height: 150))
                let strip = DockStrip(size: .medium, apps: Self.apps(count), hasWidgets: true, maxWidth: screen.width - 2 * DockPill.sideMargin, style: style,
                                      backing: { AnyView($0.modifier(GlassStandIn(desk: desk, tint: tint))) }, hoverApp: hover) {
                    ForEach(Array(Self.widgets.enumerated()), id: \.offset) { _, pair in DockWidgetBodyView(widget: pair.0, shown: pair.1) }
                    DockWidgetBodyView(title: "Tailscale", symbol: "puzzlepiece.extension", shown: DockWidgetRenders.tailscale())
                }
                // Item colours on, the bar's default (Q251): the alert gauge in the theme's red, as DockView passes it.
                try writeRender(desk.scene(strip.environment(\.inTopBar, true).environment(\.barItemColours, true), look: look), to: dir.appendingPathComponent("dock-\(theme)-\(name).png"), wait: 1.2)
            }
        }
    }

    /// The Dock page (round 4) with the markets extension and Tailscale installed in a throwaway folder: as it opens, and
    /// with Stocks and crypto's settings open under its row (the extension's own, shared with its top bar item), at the
    /// window's default width beside the sidebar.
    @Test("The Dock page and a widget's settings", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func page() async throws {
        let dir = try ClockRenders.dir("dock")
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let was = (look.style, look.themeID)
        defer { (look.style, look.themeID) = was }
        (look.style, look.themeID) = (.instrument, "dracula")
        let folder = FileManager.default.temporaryDirectory.appending(path: "dock-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalogue = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "catalogue/extensions")
        for id in ["markets", "tailscale"] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: catalogue.appending(path: id), to: folder.appending(path: id))
        }
        let engine = Engine()
        engine.dock.settings.widgets = DockSlot.defaults + [.widget(.markets)]
        let prefs = ExtensionsSettings(folder: folder)
        await prefs.load()
        for (name, editing) in [("page", nil), ("page-markets", DockSlot.widget(.markets)), ("page-system", .widget(.system))] as [(String, DockSlot?)] {
            let focus = DockPageFocus()
            focus.editing = editing
            let page = ScrollView { DockPage(folder: folder, focus: focus, prefs: prefs).environment(engine) }.pilotTheme()
            try writeRender(page.frame(width: 1000 - 232, height: editing == nil ? 1100 : 1500), to: dir.appendingPathComponent("dock-\(name).png"), wait: 1.5)
        }
    }

    /// The foot of a screen with its wallpaper (or a dusk gradient) filled as macOS fills it, the dock centred above it.
    struct Desk {
        let wall: NSImage?
        let screen: CGSize
        let size: CGSize

        var backdrop: some View {
            Group {
                if let wall {
                    Image(nsImage: wall).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [Color(red: 0.20, green: 0.16, blue: 0.30), Color(red: 0.78, green: 0.46, blue: 0.30)], startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: screen.width, height: screen.height)
            .frame(width: size.width, height: size.height, alignment: .bottom).clipped()
        }

        @MainActor func scene(_ dock: some View, look: Look) -> some View {
            ZStack(alignment: .bottom) {
                backdrop
                dock.styled(.topBar, look: look).pilotTheme(look: look).padding(.bottom, DockSize.margin)
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(.named("desk"))
        }
    }

    /// Glass's stand-in: the desk under the pill, blurred, in the bar's glass tint.
    struct GlassStandIn: ViewModifier {
        let desk: Desk
        let tint: Color

        func body(content: Content) -> some View {
            content.background {
                GeometryReader { g in
                    let f = g.frame(in: .named("desk"))
                    desk.backdrop.blur(radius: 22, opaque: true).offset(x: -f.minX, y: -f.minY)
                        .frame(width: f.width, height: f.height, alignment: .topLeading)
                        .overlay(tint)
                        .clipShape(RoundedRectangle(cornerRadius: DockPill.radius, style: .continuous))
                }
            }
        }
    }
}
}
#endif
