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

    /// AI usage's two gauges (OpenAI's in alert), the idle timer, the weather.
    static let widgets: [[[BarPart]]] = [
        [[.extensionItem(ExtensionBarFace(id: "ai-usage", title: "AI usage", answer: .init(text: "", tone: .alert, gauges: [
            .init(tone: .fine, icon: .claude, text: "94%"), .init(tone: .alert, icon: .openai, text: "67%")])))]],
        [[.symbol("timer")]],
        [[.extensionItem(ExtensionBarFace(id: "weather", title: "Weather", answer: .init(text: "☀ 24°")))]],
    ]

    @Test("The dock on two screens: fitted, crowded, hovered, Glass and Solid", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try ClockRenders.dir("dock")
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let wall = Self.env["PILOT_DOCK_WALL"].flatMap(NSImage.init(contentsOfFile:))
        let look = Look.shared
        let was = (look.style, look.themeID, look.glass)
        defer { (look.style, look.themeID, look.glass) = was }
        look.style = .instrument

        for theme in ["dracula", "porcelain"] {
            look.themeID = theme
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            let tint = Color(nsColor: TopBarColour.tint(.theme, style: tokens, look: look))
            let cases: [(String, CGSize, Int, Int?, Bool)] = theme == "dracula"
                ? [("ultrawide", Self.ultrawide, 16, nil, true), ("ultrawide-hover", Self.ultrawide, 16, 6, true), ("ultrawide-solid", Self.ultrawide, 16, nil, false),
                   ("laptop", Self.laptop, 16, nil, true), ("laptop-forty", Self.laptop, 40, nil, true)]
                : [("ultrawide", Self.ultrawide, 16, nil, true), ("ultrawide-solid", Self.ultrawide, 16, nil, false)]
            for (name, screen, count, hover, glass) in cases {
                look.glass = glass
                let desk = Desk(wall: wall, screen: screen, size: CGSize(width: min(screen.width, 1640), height: 150))
                let strip = DockStrip(size: .medium, apps: Self.apps(count), hasWidgets: true, maxWidth: screen.width - 2 * DockPill.sideMargin,
                                      backing: glass ? { AnyView($0.modifier(GlassStandIn(desk: desk, tint: tint))) } : nil, hoverApp: hover) {
                    ForEach(Array(Self.widgets.enumerated()), id: \.offset) { _, face in DockWidget(size: .medium) { BarPartsView(items: face) } }
                }
                // Item colours on, the bar's default (Q251): the alert gauge in the theme's red, as DockView passes it.
                try writeRender(desk.scene(strip.environment(\.inTopBar, true).environment(\.barItemColours, true), look: look), to: dir.appendingPathComponent("dock-\(theme)-\(name).png"), wait: 1.2)
            }
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
